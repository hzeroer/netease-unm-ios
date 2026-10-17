//
//  UNMURLProtocol.m
//

#import "UNMURLProtocol.h"
#import "UNMConfig.h"
#import "UNMHook.h"
#import "UNMInternal.h"
#import "UNMLog.h"
#import "UNMRewriter.h"
#import "UNMStats.h"

/// Bodies above this size are streamed straight through instead of buffered,
/// so a huge playlist response can never balloon memory usage.
static const long long kUNMPassthroughThreshold = 3LL * 1024 * 1024;
/// Absolute ceiling for the rewrite buffer; beyond this we give up and stream.
static const NSUInteger kUNMBufferCeiling = 6 * 1024 * 1024;

/// Rewrites can block for a few seconds while a source is searched, so they run
/// off the session's delegate queue.
static dispatch_queue_t UNMRewriteQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,
                                                    QOS_CLASS_USER_INITIATED, 0);
        q = dispatch_queue_create("com.hzeroer.unmios.rewrite", attr);
    });
    return q;
}

#pragma mark - Forcing our protocol into every session

// Registering an NSURLProtocol subclass is not enough on its own:
//   * NSURLSession only consults the protocol classes listed in its
//     configuration, and
//   * the framework may read that configuration's ivar rather than calling
//     -protocolClasses, so swizzling the getter alone can silently do nothing.
//
// So all three surfaces are attacked: the getter, the setter, and every session
// creation entry point (where the configuration is still mutable, i.e. before the
// session snapshots it).

static BOOL UNMIsBackgroundConfiguration(NSURLSessionConfiguration *config) {
    NSString *className = NSStringFromClass(config.class);
    return [className containsString:@"Background"];
}

static NSURLSessionConfiguration *UNMEnsureProtocolInConfiguration(NSURLSessionConfiguration *config) {
    if (!config) return config;
    if (UNMIsBackgroundConfiguration(config)) return config;   // setting protocolClasses throws

    NSArray *current = nil;
    @try { current = config.protocolClasses; } @catch (__unused NSException *e) { return config; }
    if ([current containsObject:[UNMURLProtocol class]]) return config;

    NSMutableArray *merged = [NSMutableArray arrayWithObject:[UNMURLProtocol class]];
    for (id protocol in current ?: @[]) {
        if (protocol == [UNMURLProtocol class]) continue;
        [merged addObject:protocol];
    }
    @try { config.protocolClasses = merged; } @catch (__unused NSException *e) { }
    return config;
}

#pragma mark - Hook bodies

// Every hook body resolves its original implementation from the registry, keyed
// by the receiver. A shared global would be overwritten by a second hook on the
// same selector, and a hook whose "original" is itself recurses until the thread
// stack dies -- which is exactly what took the host app down once already.

static IMP gOrigSetProtocolClasses = NULL;
static IMP gOrigSessionWithConfigurationOnly = NULL;
static IMP gOrigSessionWithConfiguration = NULL;
static IMP gOrigInitWithConfiguration = NULL;
static IMP gOrigSetAdditionalHeaders = NULL;
static IMP gOrigProtocolClasses = NULL;
static IMP gOrigDataTaskWithRequest = NULL;
static IMP gOrigDataTaskWithRequestCompletion = NULL;

static void UNMHookedSetProtocolClasses(id self_, SEL _cmd, NSArray *protocols) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return;

    if (UNMIsBackgroundConfiguration(self_)) {
        ((void (*)(id, SEL, NSArray *))original)(self_, _cmd, protocols);
        return;
    }

    NSMutableArray *merged = [NSMutableArray arrayWithObject:[UNMURLProtocol class]];
    for (id protocol in protocols ?: @[]) {
        if (protocol == [UNMURLProtocol class]) continue;
        [merged addObject:protocol];
    }
    ((void (*)(id, SEL, NSArray *))original)(self_, _cmd, merged);
}

/// NOTE the arity. `+sessionWithConfiguration:` takes ONE argument, so it needs
/// its own hook: reusing the three-argument replacement here would read two
/// registers the caller never set and hand that garbage to the real
/// implementation as delegate / delegateQueue -- an instant crash in the host app.
static id UNMHookedSessionWithConfigurationOnly(id self_, SEL _cmd,
                                               NSURLSessionConfiguration *config) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return nil;
    config = UNMEnsureProtocolInConfiguration(config);
    return ((id (*)(id, SEL, id))original)(self_, _cmd, config);
}

static id UNMHookedSessionWithConfiguration(id self_, SEL _cmd,
                                           NSURLSessionConfiguration *config,
                                           id delegate, NSOperationQueue *queue) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return nil;
    config = UNMEnsureProtocolInConfiguration(config);
    return ((id (*)(id, SEL, id, id, id))original)(self_, _cmd, config, delegate, queue);
}

static id UNMHookedInitWithConfiguration(id self_, SEL _cmd,
                                        NSURLSessionConfiguration *config,
                                        id delegate, NSOperationQueue *queue) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return nil;
    config = UNMEnsureProtocolInConfiguration(config);
    return ((id (*)(id, SEL, id, id, id))original)(self_, _cmd, config, delegate, queue);
}

#pragma mark - Task-level observation (and a second rewrite surface)

// The protocol path only works for sessions whose configuration we managed to
// touch *before* the session snapshotted it. Any long-lived session the app
// builds during launch can slip past that, and then nothing gets rewritten for
// the whole run.
//
// These hooks sit on the session itself, so they see every request regardless of
// when the session was created. Two jobs:
//   * count and record the NetEase paths the app actually calls, which is what
//     turns "it doesn't work" into a specific answer;
//   * rewrite the response for completion-handler based tasks, which is a real
//     second interception surface.

static void UNMNoteSessionTask(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url || !UNMIsNeteaseAPIHost(url.host)) return;

    BOOL isNew = ![[UNMStats shared].seenPaths containsObject:url.path];
    [[UNMStats shared] bumpSessionTask:url.path];

    // INFO on purpose, and once per distinct path: this is the line that proves
    // the app's own requests reach us, and the default log level would otherwise
    // hide it (which cost a whole diagnostic round trip).
    if (isNew) {
        UNMLogI(@"[session] 首次看到 %@ %@%@", request.HTTPMethod, url.host, url.path);
    }
}

/// Rewrite a completion-handler task's response in place. Returns the data to
/// hand back to the caller, or the original when nothing changed.
static NSData *UNMRewriteCompletionData(NSData *data, NSURLRequest *request,
                                        NSURLResponse **responseInOut) {
    if (!data.length || !request) return data;

    // NOTE: this runs on whatever queue the app used for its completion handler,
    // which is the main queue for many libraries. The privilege prefetch usually
    // means the lookup is a cache hit; when it is not, the deadline in the config
    // caps how long the caller can be held up.
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    BOOL changed = NO;
    NSString *detail = nil;
    NSData *out = [UNMRewriter processBody:data
                                forRequest:mutableRequest
                                   changed:&changed
                                    detail:&detail];
    if (!changed || !out.length) return data;

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)*responseInOut;
    if ([http isKindOfClass:NSHTTPURLResponse.class]) {
        NSMutableDictionary *headers = [http.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in headers.allKeys) {
            NSString *lower = key.lowercaseString;
            if ([lower isEqualToString:@"content-encoding"] ||
                [lower isEqualToString:@"content-length"] ||
                [lower isEqualToString:@"transfer-encoding"]) {
                [headers removeObjectForKey:key];
            }
        }
        headers[@"Content-Length"] = @(out.length).stringValue;
        NSHTTPURLResponse *fixed = [[NSHTTPURLResponse alloc] initWithURL:http.URL
                                                               statusCode:http.statusCode
                                                              HTTPVersion:@"HTTP/1.1"
                                                             headerFields:headers];
        if (fixed) *responseInOut = fixed;
    }
    UNMLogI(@"[session rewrite] %@ (%lu -> %lu bytes)",
            request.URL.path, (unsigned long)data.length, (unsigned long)out.length);
    return out;
}

static NSURLSessionDataTask *UNMHookedDataTaskWithRequest(id self_, SEL _cmd,
                                                         NSURLRequest *request) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    UNMNoteSessionTask(request);
    if (!original) return nil;
    return ((id (*)(id, SEL, id))original)(self_, _cmd, request);
}

static NSURLSessionDataTask *UNMHookedDataTaskWithRequestCompletion(
        id self_, SEL _cmd, NSURLRequest *request,
        void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {

    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    UNMNoteSessionTask(request);

    NSURL *url = request.URL;
    if (!original) return nil;
    if (!completionHandler || !url || !UNMIsNeteaseAPIHost(url.host)) {
        return ((id (*)(id, SEL, id, id))original)(self_, _cmd, request, completionHandler);
    }

    NSURLRequest *captured = request;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data.length) {
                NSURLResponse *adjusted = response;
                NSData *out = UNMRewriteCompletionData(data, captured, &adjusted);
                completionHandler(out, adjusted, error);
                return;
            }
            completionHandler(data, response, error);
        };

    return ((id (*)(id, SEL, id, id))original)(self_, _cmd, request, wrapped);
}

#pragma mark - WebSocket surface

// A client that receives song data over a push channel would bypass NSURLSession's
// request path entirely. WebSocket tasks still go through the session, so they are
// cheap to observe, and seeing one to a NetEase host is the first hard evidence
// that a long-lived connection is carrying the data we are looking for.

static IMP gOrigWebSocketTaskWithURL = NULL;
static IMP gOrigWebSocketTaskWithRequest = NULL;

static NSURLSessionWebSocketTask *UNMHookedWebSocketTaskWithURL(id self_, SEL _cmd, NSURL *url) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return nil;
    if (url.host.length) {
        [[UNMStats shared] bumpSeenHost:url.host];
        if (UNMIsNeteaseHost(url.host)) {
            [[UNMStats shared] addEvent:[NSString stringWithFormat:@"WebSocket 连接 %@%@",
                                        url.host, url.path]];
            UNMLogE(@"⚠️ 检测到 WebSocket 长连接：%@%@", url.host, url.path);
        }
    }
    return ((id (*)(id, SEL, id))original)(self_, _cmd, url);
}

static NSURLSessionWebSocketTask *UNMHookedWebSocketTaskWithRequest(id self_, SEL _cmd,
                                                                   NSURLRequest *request) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return nil;
    NSURL *url = request.URL;
    if (url.host.length) {
        [[UNMStats shared] bumpSeenHost:url.host];
        if (UNMIsNeteaseHost(url.host)) {
            [[UNMStats shared] addEvent:[NSString stringWithFormat:@"WebSocket 连接 %@%@",
                                        url.host, url.path]];
            UNMLogE(@"⚠️ 检测到 WebSocket 长连接：%@%@", url.host, url.path);
        }
    }
    return ((id (*)(id, SEL, id))original)(self_, _cmd, request);
}

#pragma mark - URL cache surface

// A client that has "this song is not playable" cached locally never asks the
// server for the URL at all, and then nothing in the request path can help. The
// cached response is the last place those stale privileges can be corrected, so
// it gets its own hook.
//
// Lookups are disabled here on purpose: this runs on a thread the app cares
// about, and resolving a substitute URL can block for seconds. The privilege
// rewrite needs no network at all.

static IMP gOrigCachedResponseForRequest = NULL;

static NSCachedURLResponse *UNMHookedCachedResponseForRequest(id self_, SEL _cmd,
                                                             NSURLRequest *request) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return nil;

    NSCachedURLResponse *cached = ((id (*)(id, SEL, id))original)(self_, _cmd, request);
    if (!cached || !cached.data.length) return cached;

    NSURL *url = request.URL;
    if (!url || !UNMIsNeteaseAPIHost(url.host)) return cached;
    if (!UNMEndpointIsIngestable(UNMEndpointForPath(url.path))) return cached;

    UNMConfig *cfg = [UNMConfig shared];
    [cfg reload];
    if (!cfg.enabled) return cached;

    BOOL changed = NO;
    NSString *detail = nil;
    NSData *out = [UNMRewriter processBody:cached.data
                                forRequest:request
                                   changed:&changed
                                    detail:&detail
                              allowLookups:NO];
    if (!changed || !out.length) return cached;

    NSURLResponse *response = cached.response;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if ([http isKindOfClass:NSHTTPURLResponse.class]) {
        NSMutableDictionary *headers = [http.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in headers.allKeys) {
            NSString *lower = key.lowercaseString;
            if ([lower isEqualToString:@"content-encoding"] ||
                [lower isEqualToString:@"content-length"] ||
                [lower isEqualToString:@"transfer-encoding"]) {
                [headers removeObjectForKey:key];
            }
        }
        headers[@"Content-Length"] = @(out.length).stringValue;
        NSHTTPURLResponse *fixed = [[NSHTTPURLResponse alloc] initWithURL:http.URL
                                                               statusCode:http.statusCode
                                                              HTTPVersion:@"HTTP/1.1"
                                                             headerFields:headers];
        if (fixed) response = fixed;
    }

    UNMLogI(@"[urlCache] 改写了缓存的响应 %@", url.path);
    [[UNMStats shared] bumpRewrite:@"urlCache"];

    return [[NSCachedURLResponse alloc] initWithResponse:response
                                                    data:out
                                                userInfo:cached.userInfo
                                           storagePolicy:cached.storagePolicy];
}

#pragma mark - Captured session configuration headers

/// The app configures its sessions through -setHTTPAdditionalHeaders:. Those
/// headers (User-Agent, custom auth, cookies) are attached by NSURLSession at
/// send time, so a request object alone does not carry them. We record the most
/// recent set and re-apply it to our upstream request.
static NSDictionary<NSString *, NSString *> *gAdditionalHeaders = nil;

/// Thread-local re-entrancy guards.
///
/// With the hook registry in UNMHook these should never trip; if they ever do,
/// they turn "hook calls itself until the stack dies" into one logged no-op,
/// which is the difference between an unusable app and a support ticket.
static _Thread_local int gTSLGetterDepth = 0;
static _Thread_local int gTSLHeadersDepth = 0;

static void UNMHookedSetAdditionalHeaders(id self_, SEL _cmd, NSDictionary *headers) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (!original) return;

    if ([headers isKindOfClass:NSDictionary.class] && headers.count) {
        NSMutableDictionary *merged = [gAdditionalHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in headers) {
            if ([headers[key] isKindOfClass:NSString.class]) merged[key] = headers[key];
        }
        gAdditionalHeaders = [merged copy];
    }

    if (gTSLHeadersDepth > 0) {
        UNMLogE(@"setHTTPAdditionalHeaders: 检测到重入，已跳过（不应发生）");
        return;
    }
    gTSLHeadersDepth++;
    ((void (*)(id, SEL, NSDictionary *))original)(self_, _cmd, headers);
    gTSLHeadersDepth--;
}

static NSDictionary<NSString *, NSString *> *UNMCapturedAdditionalHeaders(void) {
    return gAdditionalHeaders ?: @{};
}

static NSArray *UNMHookedProtocolClasses(id self_, SEL _cmd) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    NSArray *current = original ? ((NSArray *(*)(id, SEL))original)(self_, _cmd) : @[];

    // A background session must never be handed a custom protocol: NSURLSession
    // raises when a task on such a session uses one, which would take the app
    // down at the first background request.
    if (UNMIsBackgroundConfiguration(self_)) return current;

    if ([current containsObject:[UNMURLProtocol class]]) return current;

    if (gTSLGetterDepth > 0) {
        UNMLogE(@"protocolClasses: 检测到重入，已跳过（不应发生）");
        return current;
    }
    gTSLGetterDepth++;

    NSMutableArray *merged = [NSMutableArray arrayWithObject:[UNMURLProtocol class]];
    for (id protocol in current ?: @[]) {
        if (protocol == [UNMURLProtocol class]) continue;
        [merged addObject:protocol];
    }

    gTSLGetterDepth--;
    return merged;
}

#pragma mark - Installation

static BOOL UNMTryHook(NSString *label, BOOL (^attempt)(void)) {
    @try {
        BOOL ok = attempt();
        UNMLogI(@"hook %-46s %@", label.UTF8String, ok ? @"ok" : @"skipped (方法不存在)");
        return ok;
    } @catch (NSException *e) {
        UNMLogE(@"hook %s 抛异常: %@", label.UTF8String, e.reason);
        return NO;
    }
}

void UNMInstallInterceptor(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            [NSURLProtocol registerClass:[UNMURLProtocol class]];

            // Sample live instances: NSURLSessionConfiguration and NSURLSession
            // are class clusters, so the implementations usually live on private
            // subclasses and hooking only the public class would find nothing.
            NSURLSessionConfiguration *sampleConfig = nil;
            NSURLSessionConfiguration *sampleEphemeral = nil;
            id sampleSession = nil;
            @try { sampleConfig = [NSURLSessionConfiguration defaultSessionConfiguration]; } @catch (__unused NSException *e) { }
            @try { sampleEphemeral = [NSURLSessionConfiguration ephemeralSessionConfiguration]; } @catch (__unused NSException *e) { }
            @try { sampleSession = [NSURLSession sharedSession]; } @catch (__unused NSException *e) { }

            UNMLogI(@"class cluster samples: config=%@/%@ session=%@",
                    sampleConfig ? NSStringFromClass(object_getClass(sampleConfig)) : @"nil",
                    sampleEphemeral ? NSStringFromClass(object_getClass(sampleEphemeral)) : @"nil",
                    sampleSession ? NSStringFromClass(object_getClass(sampleSession)) : @"nil");

            Class publicConfig = objc_getClass("NSURLSessionConfiguration");
            Class publicSession = objc_getClass("NSURLSession");

            // Hooking is idempotent per (class, selector), so trying the public
            // class and every sampled concrete class is safe: whichever classes
            // actually implement the method get hooked exactly once, each with
            // its own recorded original.
            UNMTryHook(@"config.protocolClasses (getter)", ^BOOL{
                BOOL a = publicConfig && UNMHookInst(publicConfig, @selector(protocolClasses),
                                                     (IMP)UNMHookedProtocolClasses, &gOrigProtocolClasses);
                BOOL b = UNMHookInstOnRuntimeClassIfOwned(sampleConfig, @selector(protocolClasses),
                                                          (IMP)UNMHookedProtocolClasses, &gOrigProtocolClasses);
                BOOL c = UNMHookInstOnRuntimeClassIfOwned(sampleEphemeral, @selector(protocolClasses),
                                                          (IMP)UNMHookedProtocolClasses, &gOrigProtocolClasses);
                return a || b || c;
            });
            UNMTryHook(@"config.setProtocolClasses:", ^BOOL{
                BOOL a = publicConfig && UNMHookInst(publicConfig, @selector(setProtocolClasses:),
                                                     (IMP)UNMHookedSetProtocolClasses, &gOrigSetProtocolClasses);
                BOOL b = UNMHookInstOnRuntimeClassIfOwned(sampleConfig, @selector(setProtocolClasses:),
                                                          (IMP)UNMHookedSetProtocolClasses, &gOrigSetProtocolClasses);
                BOOL c = UNMHookInstOnRuntimeClassIfOwned(sampleEphemeral, @selector(setProtocolClasses:),
                                                          (IMP)UNMHookedSetProtocolClasses, &gOrigSetProtocolClasses);
                return a || b || c;
            });
            UNMTryHook(@"config.setHTTPAdditionalHeaders:", ^BOOL{
                BOOL a = publicConfig && UNMHookInst(publicConfig, @selector(setHTTPAdditionalHeaders:),
                                                     (IMP)UNMHookedSetAdditionalHeaders, &gOrigSetAdditionalHeaders);
                BOOL b = UNMHookInstOnRuntimeClassIfOwned(sampleConfig, @selector(setHTTPAdditionalHeaders:),
                                                          (IMP)UNMHookedSetAdditionalHeaders, &gOrigSetAdditionalHeaders);
                return a || b;
            });

            // The decisive layer: inject while the configuration is still mutable.
            //
            // Class methods are hooked on the public class only: that is where a
            // call site like [NSURLSession sessionWithConfiguration:...] actually
            // dispatches, so hooking a private subclass would miss it.
            UNMTryHook(@"+sessionWithConfiguration:delegate:delegateQueue:", ^BOOL{
                return publicSession && UNMHookCls(publicSession,
                                                   @selector(sessionWithConfiguration:delegate:delegateQueue:),
                                                   (IMP)UNMHookedSessionWithConfiguration,
                                                   &gOrigSessionWithConfiguration);
            });
            UNMTryHook(@"+sessionWithConfiguration:", ^BOOL{
                return publicSession && UNMHookCls(publicSession, @selector(sessionWithConfiguration:),
                                                   (IMP)UNMHookedSessionWithConfigurationOnly,
                                                   &gOrigSessionWithConfigurationOnly);
            });
            UNMTryHook(@"-initWithConfiguration:delegate:delegateQueue:", ^BOOL{
                BOOL a = UNMHookInstOnRuntimeClassIfOwned(sampleSession,
                                                          @selector(initWithConfiguration:delegate:delegateQueue:),
                                                          (IMP)UNMHookedInitWithConfiguration,
                                                          &gOrigInitWithConfiguration);
                BOOL b = publicSession && UNMHookInst(publicSession,
                                                     @selector(initWithConfiguration:delegate:delegateQueue:),
                                                     (IMP)UNMHookedInitWithConfiguration,
                                                     &gOrigInitWithConfiguration);
                return a || b;
            });

            // Task level. Applied to the concrete session class so it also covers
            // sessions built before this ran; see the note further up.
            UNMTryHook(@"-dataTaskWithRequest:", ^BOOL{
                return UNMHookInstOnRuntimeClass(sampleSession, @selector(dataTaskWithRequest:),
                                                 (IMP)UNMHookedDataTaskWithRequest,
                                                 &gOrigDataTaskWithRequest);
            });
            UNMTryHook(@"-dataTaskWithRequest:completionHandler:", ^BOOL{
                return UNMHookInstOnRuntimeClass(sampleSession,
                                                 @selector(dataTaskWithRequest:completionHandler:),
                                                 (IMP)UNMHookedDataTaskWithRequestCompletion,
                                                 &gOrigDataTaskWithRequestCompletion);
            });
            UNMTryHook(@"-webSocketTaskWithURL:", ^BOOL{
                return UNMHookInstOnRuntimeClass(sampleSession, @selector(webSocketTaskWithURL:),
                                                 (IMP)UNMHookedWebSocketTaskWithURL,
                                                 &gOrigWebSocketTaskWithURL);
            });
            UNMTryHook(@"-webSocketTaskWithRequest:", ^BOOL{
                return UNMHookInstOnRuntimeClass(sampleSession, @selector(webSocketTaskWithRequest:),
                                                 (IMP)UNMHookedWebSocketTaskWithRequest,
                                                 &gOrigWebSocketTaskWithRequest);
            });

            BOOL anyLayer = (gOrigProtocolClasses != NULL) || (gOrigSetProtocolClasses != NULL)
                         || (gOrigSessionWithConfiguration != NULL);
            if (!anyLayer) {
                UNMLogE(@"三层拦截一个都没挂上，解灰不可能生效。请把上面的 hook 日志发出来。");
            } else {
                UNMLogI(@"拦截层就绪（getter=%s setter=%s session=%s task=%s）",
                        gOrigProtocolClasses ? "ok" : "no",
                        gOrigSetProtocolClasses ? "ok" : "no",
                        gOrigSessionWithConfiguration ? "ok" : "no",
                        gOrigDataTaskWithRequestCompletion ? "ok" : "no");
            }
        } @catch (NSException *e) {
            UNMLogE(@"安装拦截层时抛异常（已忽略，不改写任何东西）：%@", e.reason);
        }
    });
}

#pragma mark - Upstream session engine

@class UNMURLProtocol;

@interface UNMUpstreamEngine : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UNMURLProtocol *> *routes;
+ (instancetype)shared;
@end

#pragma mark - Interceptor

@interface UNMURLProtocol ()
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, strong, nullable) NSURLResponse *upstreamResponse;
@property (nonatomic, strong, nullable) NSMutableData *buffer;
@property (nonatomic) BOOL passthrough;
@property (nonatomic) BOOL stopped;
@end

@implementation UNMURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:UNMUpstreamKey inRequest:request]) return NO;

    NSURL *url = request.URL;
    if (!url) return NO;

    // Record every distinct host, and a timeline of (time, host, path), *before*
    // any filtering. This is the raw material that answers "what does the client
    // actually talk to, and in what order" -- including the audio CDN requests,
    // which prove that playback really happened inside the window.
    [[UNMStats shared] bumpSeenHost:url.host];
    [[UNMStats shared] noteTimeline:url.host path:url.path];

    UNMConfig *cfg = [UNMConfig shared];
    [cfg reload];
    if (!cfg.enabled) return NO;

    UNMEndpoint endpoint = UNMEndpointForPath(url.path);
    BOOL knownHost = UNMIsNeteaseAPIHost(url.host);
    BOOL apiShapedPath = UNMPathLooksLikeNeteaseAPI(url.path);

    if (!knownHost && !apiShapedPath) return NO;

    if (!knownHost && apiShapedPath) {
        // The client reaching the API without its name in the URL: it got server
        // addresses from its config endpoint and is talking to them directly. A
        // name-based whitelist misses all of this, which is exactly what made it
        // look like "the client never asks for a play URL".
        UNMLogE(@"⚠️ 未知域名但路径是网易接口：%@%@（已按路径放行）", url.host, url.path);
        [[UNMStats shared] addEvent:[NSString stringWithFormat:@"按路径放行（未知域名）%@%@",
                                    url.host, url.path]];
    }

    if (cfg.discoveryMode) {
        UNMLogI(@"[discovery] %@ %@%@", request.HTTPMethod, url.host, url.path);
        // Log a call stack once per distinct path. That is bounded (a few dozen
        // lines) and it is what identifies the code that issues a request when the
        // client turns out not to use the URL loading system the way we assumed.
        if ([[UNMStats shared] noteRequestPath:url.path]) {
            NSArray<NSString *> *frames = [NSThread callStackSymbols];
            NSUInteger limit = MIN(frames.count, (NSUInteger)16);
            for (NSUInteger i = 0; i < limit; i++) {
                UNMLogRaw([NSString stringWithFormat:@"    #%lu %@", (unsigned long)i, frames[i]]);
            }
        }
        return YES;
    }
    if (cfg.logEveryIntercept) {
        UNMLogD(@"intercept %@ %@ [%@]", request.HTTPMethod, url.path, UNMEndpointName(endpoint));
    }

    return UNMEndpointIsRewritable(endpoint) || UNMEndpointIsIngestable(endpoint);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

#pragma mark Lifecycle

- (void)startLoading {
    NSMutableURLRequest *request = [self.request mutableCopy];

    // NSURLProtocol loses the body of streamed POSTs; materialise it so the
    // upstream request is byte-identical to what the app intended to send.
    if (!request.HTTPBody && request.HTTPBodyStream) {
        NSData *body = [self drainStream:request.HTTPBodyStream];
        if (body) {
            request.HTTPBody = body;
            request.HTTPBodyStream = nil;
        }
    }

    UNMConfig *cfg = [UNMConfig shared];
    [cfg reload];
    if (cfg.enableXRealIP && cfg.xRealIP.length) {
        // Un-blocks the overseas region restriction: NetEase then treats the
        // request as originating from a mainland address.
        [request setValue:cfg.xRealIP forHTTPHeaderField:@"X-Real-IP"];
    }

    // Anything the app set through HTTPAdditionalHeaders (custom UA, auth
    // headers, cookies) lives on its session configuration, not on the request,
    // so it has to be re-applied here or the upstream call loses its identity.
    NSDictionary<NSString *, NSString *> *additional = UNMCapturedAdditionalHeaders();
    for (NSString *key in additional) {
        if ([request valueForHTTPHeaderField:key].length) continue;
        [request setValue:additional[key] forHTTPHeaderField:key];
    }

    [NSURLProtocol setProperty:@YES forKey:UNMUpstreamKey inRequest:request];

    self.buffer = [NSMutableData data];
    self.stopped = NO;

    UNMUpstreamEngine *engine = [UNMUpstreamEngine shared];
    NSURLSessionDataTask *task = [engine.session dataTaskWithRequest:request];
    self.task = task;

    // Register before resuming so no callback can arrive un-routed.
    engine.routes[@(task.taskIdentifier)] = self;

    UNMLogD(@"-> %@ %@%@", request.HTTPMethod, request.URL.host, request.URL.path);
    [[UNMStats shared] bumpIntercept:[NSString stringWithFormat:@"%@%@",
                                     request.HTTPMethod, request.URL.path]];
    [task resume];
}

- (void)stopLoading {
    self.stopped = YES;
    if (self.task) {
        UNMUpstreamEngine *engine = [UNMUpstreamEngine shared];
        [engine.routes removeObjectForKey:@(self.task.taskIdentifier)];
        [self.task cancel];
        self.task = nil;
    }
}

- (NSData *)drainStream:(NSInputStream *)stream {
    if (!stream) return nil;
    [stream open];

    NSMutableData *out = [NSMutableData data];
    uint8_t chunk[4096];
    NSInteger read = 0;
    while ((read = [stream read:chunk maxLength:sizeof(chunk)]) > 0) {
        [out appendBytes:chunk length:(NSUInteger)read];
        if (out.length > 4 * 1024 * 1024) break;   // sanity limit
    }
    [stream close];
    return out.length ? out : nil;
}

#pragma mark Upstream callbacks (invoked by the engine on its delegate queue)

- (void)upstreamDidReceiveResponse:(NSURLResponse *)response {
    self.upstreamResponse = response;

    if (response.expectedContentLength > kUNMPassthroughThreshold) {
        self.passthrough = YES;
        [[UNMStats shared] bumpPassthrough:self.request.URL.path];
        UNMLogD(@"passthrough (%.1f MB) %@",
                (double)response.expectedContentLength / 1048576.0, self.request.URL.path);

        NSURLResponse *passthrough = [self sanitizedResponseWithLength:-1];
        [self.client URLProtocol:self
              didReceiveResponse:passthrough ?: response
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    }
}

- (void)upstreamDidReceiveData:(NSData *)data {
    if (self.passthrough) {
        if (!self.stopped) [self.client URLProtocol:self didLoadData:data];
        return;
    }
    [self.buffer appendData:data];

    if (self.buffer.length > kUNMBufferCeiling) {
        // Give up on rewriting this one; flush what we have and stream the rest.
        UNMLogW(@"buffer ceiling on %@, streaming through", self.request.URL.path);
        self.passthrough = YES;
        NSData *pending = [self.buffer copy];

        if (!self.stopped) {
            NSURLResponse *resp = [self sanitizedResponseWithLength:-1];
            if (resp) {
                [self.client URLProtocol:self
                      didReceiveResponse:resp
                      cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            }
            [self.client URLProtocol:self didLoadData:pending];
        }
        [self.buffer setLength:0];
    }
}

- (void)upstreamDidCompleteWithError:(NSError *)error {
    if (error) {
        if (error.code == NSURLErrorCancelled) return;   // we cancelled it
        UNMLogW(@"upstream error %@ (%@)", self.request.URL.path, error.localizedDescription);
        if (!self.stopped) [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    if (self.passthrough) {
        if (!self.stopped) [self.client URLProtocolDidFinishLoading:self];
        return;
    }

    // Hand the rewrite to a worker: a cold source lookup blocks for up to the
    // configured timeout, and the session's delegate queue must stay free.
    NSData *body = [self.buffer copy];
    self.buffer = nil;
    NSURLRequest *request = self.request;

    dispatch_async(UNMRewriteQueue(), ^{
        if (self.stopped) return;

        BOOL changed = NO;
        NSString *detail = nil;
        NSData *out = [UNMRewriter processBody:body
                                    forRequest:request
                                       changed:&changed
                                        detail:&detail] ?: body;

        if (self.stopped) return;

        NSURLResponse *resp = [self sanitizedResponseWithLength:(NSInteger)out.length];
        if (resp) {
            [self.client URLProtocol:self
                  didReceiveResponse:resp
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }
        if (out.length) [self.client URLProtocol:self didLoadData:out];
        [self.client URLProtocolDidFinishLoading:self];
    });
}

#pragma mark Response fixing

/// NSURLSession hands us an already-decompressed body, so the original
/// Content-Encoding / Content-Length / Transfer-Encoding headers must not be
/// forwarded as-is. `length < 0` means "unknown", which is correct for the
/// stream-through case.
- (NSURLResponse *)sanitizedResponseWithLength:(NSInteger)length {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)self.upstreamResponse;
    NSURL *url = self.request.URL;

    NSDictionary *original = http.allHeaderFields ?: @{};
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *key in original) {
        NSString *lower = key.lowercaseString;
        if ([lower isEqualToString:@"content-encoding"]) continue;
        if ([lower isEqualToString:@"content-length"]) continue;
        if ([lower isEqualToString:@"transfer-encoding"]) continue;
        headers[key] = original[key];
    }
    if (length >= 0) headers[@"Content-Length"] = @(length).stringValue;

    NSInteger status = http ? http.statusCode : 200;

    NSHTTPURLResponse *out = [[NSHTTPURLResponse alloc] initWithURL:url
                                                         statusCode:status
                                                        HTTPVersion:@"HTTP/1.1"
                                                       headerFields:headers];
    if (out) return out;

    return [[NSURLResponse alloc] initWithURL:url
                                     MIMEType:@"application/json"
                        expectedContentLength:length
                             textEncodingName:@"utf-8"];
}

@end

#pragma mark - Engine

@implementation UNMUpstreamEngine

+ (instancetype)shared {
    static UNMUpstreamEngine *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[UNMUpstreamEngine alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _routes = [NSMutableDictionary dictionary];

        // NOTE: defaultSessionConfiguration, not ephemeral. An ephemeral session
        // gets a private cookie store, which would silently drop the app's login
        // cookies and make every authenticated endpoint return 401/无权限.
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        cfg.HTTPShouldSetCookies = YES;
        cfg.timeoutIntervalForRequest = 15;
        cfg.timeoutIntervalForResource = 60;
        cfg.HTTPShouldUsePipelining = NO;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;   // NSURLSession wants a serial queue
        queue.name = @"com.hzeroer.unmios.upstream";

        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:queue];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSMutableURLRequest *redirect = [request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:UNMUpstreamKey inRequest:redirect];
    completionHandler(redirect);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.routes[@(dataTask.taskIdentifier)] upstreamDidReceiveResponse:response];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.routes[@(dataTask.taskIdentifier)] upstreamDidReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    UNMURLProtocol *target = self.routes[@(task.taskIdentifier)];
    [self.routes removeObjectForKey:@(task.taskIdentifier)];
    [target upstreamDidCompleteWithError:error];
}

@end
