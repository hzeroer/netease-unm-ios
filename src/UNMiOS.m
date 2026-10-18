//
//  UNMiOS.m
//
//  Entry point of the dylib.
//
//  Design constraints that shaped everything here:
//    * TrollStore / TrollFools inject this into a *jailed* (non-jailbroken) app
//      copy, so it must not link substrate / libhooker / Orion. Only libobjc and
//      Foundation are used, and every hook goes through the in-house swizzler.
//    * No helper process, no local HTTP server, no CA certificate: the rewrite
//      happens inside the app process on already-decrypted responses, and the
//      substitute audio URLs come from direct calls to public music APIs.
//

#import <Foundation/Foundation.h>

#import <dlfcn.h>
#import <mach-o/dyld.h>

#import "UNMConfig.h"
#import "UNMCrashGuard.h"
#import "UNMHook.h"
#import "UNMLog.h"
#import "UNMMenu.h"
#import "UNMModelHook.h"
#import "UNMProvider.h"
#import "UNMRewriter.h"
#import "UNMStats.h"
#import "UNMStore.h"
#import "UNMURLProtocol.h"
#import "UNMUtil.h"
#import "UNMVersion.h"


/// Single source of truth for the version, shared with the crash guard.
///
/// Bump UNM_VERSION (UNMVersion.h) on every build: a changed version is what
/// makes the crash guard give a fixed build a clean slate instead of leaving it
/// disabled forever because an older build crashed.
const char *UNMVersionString(void) {
    return UNM_VERSION;
}

/// Defined by UNM_AUTHOR so the panel, the log banner and the packaging metadata
/// cannot drift apart.
NSString *UNMAuthorString(void) {
    return @UNM_AUTHOR;
}

/// Readable with `strings dist/UNMiOS.dylib | grep '^UNMiOS_VERSION='`.
///
/// tools/pack.sh uses it to refuse packaging a stale binary. Without a marker it
/// would have to guess which bare "x.y.z" string in the binary is the version --
/// and it guessed "3.9.0", a header value in the BoDian provider.
__attribute__((used)) const char *UNMiOSVersionMarker = "UNMiOS_VERSION=" UNM_VERSION;

#pragma mark - Provider declarations

// Declared here rather than in a shared header: nothing else needs to know the
// concrete classes, they are reached through the registry.
@interface UNMProviderMigu : NSObject <UNMProvider> @end
@interface UNMProviderBodian : NSObject <UNMProvider> @end

#pragma mark - Discovery helpers

/// Dump the app's own classes so a new client build can be mapped quickly.
/// Written to <sandbox>/Library/Caches/unmios/classes.txt.
static void UNMDumpDiscoveryInfo(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# UNMiOS %s discovery dump %@\n", UNMVersionString(), [NSDate date]];

    NSArray<NSString *> *classPatterns = @[
        @"^(NM|NEMusic|Orpheus|Netease|NetEase)",
        @"(Http|HTTP|Api|API|Request|Session|Network)",
        @"(Song|Music|Player|Audio|Url|URL|Play)",
    ];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *pattern in classPatterns) {
        for (NSString *name in UNMDumpClassesMatching(pattern)) {
            if ([seen containsObject:name]) continue;
            if (seen.count > 1200) break;
            [seen addObject:name];
        }
    }

    NSArray *sorted = [seen.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [out appendFormat:@"\n## classes (%lu)\n", (unsigned long)sorted.count];
    for (NSString *name in sorted) [out appendFormat:@"%@\n", name];

    // Full method lists only for the classes likely to own the URL pipeline.
    NSMutableArray *detailed = [NSMutableArray array];
    for (NSString *name in sorted) {
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"http"] || [lower containsString:@"api"] ||
            [lower containsString:@"player"] || [lower containsString:@"url"] ||
            [lower containsString:@"song"]) {
            [detailed addObject:name];
        }
        if (detailed.count >= 60) break;
    }

    for (NSString *name in detailed) {
        Class cls = UNMFindClass(name);
        if (!cls) continue;
        [out appendFormat:@"\n## %@\n", name];
        for (NSString *sig in UNMDumpMethods(cls)) [out appendFormat:@"%@\n", sig];
    }

    NSString *path = [[UNMLogFilePath() stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:@"classes.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    UNMLogI(@"discovery dump written: %@ (%lu classes)", path, (unsigned long)sorted.count);
}

#pragma mark - Generic escape hatch

/// `extraHooks` in the config lets a specific client build be supported without
/// recompiling: entries are "ClassName:selector" (prefix '+' for a class
/// method). Only zero-argument object-returning methods are accepted, because
/// forwarding a variadic call safely is not possible without libffi.
static void UNMInstallExtraHooks(NSArray<NSString *> *hooks) {
    for (NSString *entry in hooks) {
        if (![entry isKindOfClass:NSString.class] || entry.length == 0) continue;

        BOOL isClassMethod = [entry hasPrefix:@"+"];
        NSString *body = isClassMethod ? [entry substringFromIndex:1] : entry;
        if ([body hasPrefix:@"-"]) body = [body substringFromIndex:1];

        NSRange colon = [body rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            UNMLogW(@"extraHooks: malformed entry %@", entry);
            continue;
        }
        NSString *className = UNMTrim([body substringToIndex:colon.location]);
        NSString *selectorName = UNMTrim([body substringFromIndex:colon.location + 1]);

        Class cls = UNMFindClass(className);
        if (!cls) {
            UNMLogW(@"extraHooks: class %@ not found", className);
            continue;
        }

        SEL sel = NSSelectorFromString(selectorName);
        Class owner = Nil;
        Method m = UNMLookupMethod(cls, sel, isClassMethod, &owner);
        if (!m) {
            UNMLogW(@"extraHooks: %@ does not implement %@", className, selectorName);
            continue;
        }
        if (method_getNumberOfArguments(m) != 2) {
            UNMLogW(@"extraHooks: %@ takes arguments, skipped (only 0-arg is safe)",
                    selectorName);
            continue;
        }
        const char *ret = method_getTypeEncoding(m);
        if (!ret || ret[0] != '@') {
            UNMLogW(@"extraHooks: %@ does not return an object, skipped", selectorName);
            continue;
        }

        // Capture the original implementation before the block is built: an
        // imp_implementationWithBlock block is copied to the heap, and reading
        // the IMP through a byref cell afterwards would be fragile.
        IMP original = method_getImplementation(m);

        id (^block)(id) = ^id(id self_) {
            if (!original) return nil;
            id value = ((id (*)(id, SEL))original)(self_, sel);

            if ([value isKindOfClass:NSData.class]) {
                BOOL changed = NO;
                NSData *out = [UNMRewriter processLooseBody:(NSData *)value changed:&changed];
                return changed ? out : value;
            }
            if ([value isKindOfClass:NSDictionary.class]) {
                NSData *raw = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
                if (!raw) return value;
                BOOL changed = NO;
                NSData *out = [UNMRewriter processLooseBody:raw changed:&changed];
                if (!changed) return value;
                return [NSJSONSerialization JSONObjectWithData:out
                                                       options:NSJSONReadingMutableContainers
                                                         error:NULL] ?: value;
            }
            return value;
        };

        IMP replacement = imp_implementationWithBlock(block);
        BOOL ok = isClassMethod
            ? UNMHookCls(cls, sel, replacement, NULL)
            : UNMHookInst(cls, sel, replacement, NULL);
        UNMLogI(@"extraHooks: %@%@ %@ -> %s", isClassMethod ? @"+" : @"-",
                className, selectorName, ok ? "installed" : "failed");
    }
}

#pragma mark - Deferred installation

/// A dylib constructor runs while dyld is still wiring up the process, so the
/// networking classes are not guaranteed to be registered yet. Installing the
/// interceptor against a class that does not exist would silently produce a
/// tweak that loads, logs, and does absolutely nothing -- the worst failure mode
/// there is, because everything looks healthy.
static BOOL UNMFoundationReady(void) {
    return objc_getClass("NSURLSession") != NULL
        && objc_getClass("NSURLProtocol") != NULL
        && objc_getClass("NSURLSessionConfiguration") != NULL;
}

static void UNMInstallWhenReady(int attempt) {
    if (UNMFoundationReady()) {
        UNMInstallInterceptor();
        return;
    }
    if (attempt >= 40) {
        UNMLogE(@"NSURLSession 一直不可用，拦截层没能装上。请把这条日志反馈。");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UNMInstallWhenReady(attempt + 1);
    });
}

#pragma mark - Duplicate injection guard

/// YES when this dylib is the first UNMiOS image in the process.
///
/// TrollFools appends a load command each time it is used, so injecting twice
/// leaves two copies loaded. Two copies hook the same selectors, and the second
/// copy's "original implementation" is the first copy's hook -- mutual recursion,
/// which is a stack overflow. So exactly one copy is allowed to act; the others
/// log and stand down.
static BOOL UNMIsPrimaryTweakCopy(void) {
    Dl_info info;
    if (dladdr((const void *)&UNMIsPrimaryTweakCopy, &info) == 0 || info.dli_fname == NULL) {
        return YES;   // cannot tell; assume we are the only one
    }

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL || strstr(name, "UNMiOS") == NULL) continue;
        // Images are visited in load order, so the first match is the earliest.
        return strcmp(name, info.dli_fname) == 0;
    }
    return YES;
}

#pragma mark - Providers and menu wiring

static void UNMRegisterProvidersOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UNMRegisterProvider([UNMProviderMigu class]);
        UNMRegisterProvider([UNMProviderBodian class]);
        UNMLogI(@"sources: %@", [UNMRegisteredProviderKeys() componentsJoinedByString:@","]);
    });
}

/// Schedules the settings UI.
///
/// Called unconditionally, including when the tweak itself is switched off or in
/// safe mode: the panel is the only way back from either state, so nothing may
/// gate it. Several triggers are used because which one fires first varies by
/// client version, and the ball is only considered up once a window scene exists.
static void UNMInstallMenu(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

        [center addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            (void)note;
            [[UNMConfig shared] forceReload];
            [UNMMenu install];
            UNMLogI(@"app launched; store: %@", [[UNMStore shared] stats]);
            UNMLogI(@"菜单入口：%@（悬浮球）/ %@（摇一摇）/ %@（导航栏）",
                    [UNMConfig shared].showFloatingButton ? @"开" : @"关",
                    [UNMConfig shared].enableShakeMenu ? @"开" : @"关",
                    [UNMConfig shared].showNavBarEntry ? @"开" : @"关");
            UNMLogI(@"================================================================");
        }];

        [center addObserverForName:@"UIWindowDidBecomeKeyNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            (void)note;
            [UNMMenu install];
        }];

        // Ask immediately in case the process is already running its runloop.
        dispatch_async(dispatch_get_main_queue(), ^{
            [UNMMenu install];
        });

        // And keep retrying: the launch signals can fire before the app has a
        // window scene, and a retry costs nothing while a missing ball is
        // indistinguishable from a broken build.
        for (NSNumber *delay in @[ @0.3, @0.8, @1.5, @3.0, @6.0, @12.0, @20.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UNMMenu install];
            });
        }

        UNMLogI(@"菜单安装已排队（悬浮球=%@ 摇一摇=%@ 导航栏=%@）",
                [UNMConfig shared].showFloatingButton ? @"开" : @"关",
                [UNMConfig shared].enableShakeMenu ? @"开" : @"关",
                [UNMConfig shared].showNavBarEntry ? @"开" : @"关");
    });
}

#pragma mark - Entry point

__attribute__((constructor)) static void UNMiOSInit(void) {
    @autoreleasepool {
        // FIRST, before anything else can throw or fault: install the crash
        // reporter and decide whether this build is even allowed to run.
        [UNMCrashGuard installEarly];

        // Only the first copy may act. Two injected copies of this tweak would
        // hook each other and recurse; see the note on UNMIsPrimaryTweakCopy.
        if (!UNMIsPrimaryTweakCopy()) {
            UNMLogE(@"⚠️ 进程里加载了多份 UNMiOS，已停用后面这几份。"
                     "请到 TrollFools 删掉多余的注入项，只留一个。");
            return;
        }

        UNMConfig *cfg = [UNMConfig shared];
        [cfg reload];
        UNMLogSetLevel((UNMLogLevel)cfg.logLevel);
        UNMLogSetDiscovery(cfg.discoveryMode);

        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"<unknown>";
        UNMLogI(@"================================================================");
        UNMLogI(@"UNMiOS %s by %s loaded into %@", UNMVersionString(), UNM_AUTHOR, bundleID);
        UNMLogI(@"config: %@", [cfg dump]);
        UNMLogI(@"log:    %@", UNMLogFilePath());

        // `enabled` has exactly two writers: the settings panel's master switch and
        // safe mode. So if it is off and the user never touched that switch, safe
        // mode is what put it there -- and leaving it off would look like "the fix
        // didn't work" when in fact the tweak is simply switched off.
        if (!cfg.enabled && ![cfg rawBoolForKey:@"enabledTouchedByUser"]) {
            [cfg persistValue:@YES forKey:@"enabled"];
            [cfg forceReload];
            UNMLogI(@"检测到 enabled=false 不是用户关的（无 enabledTouchedByUser 标记），已自动恢复为 true");
        }

        if ([UNMCrashGuard safeModeEngaged]) {
            // Previous launches died early. Run with everything dangerous off, but
            // still bring up the settings panel: it is the only place the crash
            // report can be read and safe mode cleared from.
            [UNMCrashGuard markDisabledBySafeMode];
            [cfg persistValue:@NO forKey:@"enabled"];
            UNMLogE(@"⚠️ 上次启动连续闪退，已进入安全模式：所有 hook 和改写都已停用。");
            UNMLogE(@"   面板仍会打开，可在「工具」里退出安全模式。");

            NSString *report = [UNMCrashGuard lastCrashReport];
            if (report.length) UNMLogE(@"最后一次崩溃记录：\n%@", report);

            UNMRegisterProvidersOnce();
            UNMInstallMenu();
            return;
        }

        // Register the substitute sources.
        UNMRegisterProvidersOnce();

        // The menu is installed BEFORE the enabled check on purpose: it is how the
        // user turns the tweak back on, so it must never be gated behind the switch
        // it controls.
        UNMInstallMenu();

        if (!cfg.enabled) {
            UNMLogI(@"enabled=false：菜单已装，但解灰关闭。可在面板里打开「总开关」。");
            return;
        }

        // Install straight away rather than one main-queue turn later.
        //
        // A session only consults its configuration's protocol list when it is
        // created, so any NSURLSession the app builds during launch has to be
        // created *after* this runs -- otherwise nothing is intercepted for the
        // whole run, which is exactly the "no crash, no panel, songs still grey"
        // shape of failure. The earlier reason for deferring (a mistake inside
        // dyld kills the app before it can draw a frame) no longer applies: the
        // hook registry and the build-time undefined-symbol check removed both
        // ways that used to go wrong.
        UNMInstallWhenReady(0);

        // The model layer is the only interception surface left, since the play
        // URL never appears as an observable request. Installed unconditionally:
        // the getters gate on the config themselves, so the toggle works without
        // a restart.
        [UNMModelHook install];

        if (cfg.extraHooks.count) {
            UNMInstallExtraHooks(cfg.extraHooks);
        }

        if (cfg.discoveryMode) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    UNMDumpDiscoveryInfo();
                }
            });
        }

        // Survive long enough and the crash counter is cleared, so one bad
        // launch does not follow the user around forever.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UNMCrashGuard markBootHealthy];
        });

        UNMLogI(@"ready");
    }
}
