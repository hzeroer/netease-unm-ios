//
//  UNMStats.h
//
//  Runtime counters and a small event ring buffer.
//
//  This is the diagnostic backbone of the in-app menu: when something does not
//  work, the first question is always "did we even see the request?" and the
//  counters answer it without needing a log file.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMStats : NSObject

+ (instancetype)shared;

- (void)bumpIntercept:(NSString *)label;
- (void)bumpPassthrough:(NSString *)label;
- (void)bumpRewrite:(NSString *)label;
- (void)bumpSessionTask:(NSString *)path;
- (void)bumpResolveAttempt:(NSString *)provider;
- (void)bumpResolveHit:(NSString *)provider;
- (void)bumpResolveMiss:(NSString *)provider;
- (void)bumpFailure:(NSString *)label;

/// Ring buffer of the last N notable events, oldest first.
- (void)addEvent:(NSString *)event;
- (NSArray<NSString *> *)recentEvents;

- (void)reset;

@property (nonatomic, readonly) NSUInteger intercepts;
@property (nonatomic, readonly) NSUInteger passthroughs;
@property (nonatomic, readonly) NSUInteger rewrites;

/// NetEase requests seen at the NSURLSession task level, i.e. requests that
/// definitely belong to the host app. Comparing this with `intercepts` is what
/// separates "the app never talks to NetEase" from "the app does, but our
/// NSURLProtocol is not attached to the session that carries them".
@property (nonatomic, readonly) NSUInteger sessionTasks;

/// Distinct NetEase paths seen at the task level, newest last (capped).
- (NSArray<NSString *> *)seenPaths;

/// Every distinct host the URL loading system has asked us about, capped.
///
/// This is the diagnostic that answers "is the app even using NSURLSession, and
/// if so, what does it talk to?" without needing a second build: if the NetEase
/// API host the client actually uses is not in the list, the host filter is the
/// problem; if the list is empty, the app never reaches the URL loading system.
- (void)bumpSeenHost:(NSString *)host;
- (NSArray<NSString *> *)seenHosts;

/// Record a path that reached the NSURLProtocol layer. Returns YES the first time
/// this path is seen, which is when it is worth logging a call stack.
- (BOOL)noteRequestPath:(NSString *)path;

/// Chronological record of (time, host, path), capped.
///
/// Ordering is the point: it shows whether an audio CDN request was preceded by a
/// play-URL request, which is how "the client streamed audio without ever asking
/// for a URL" becomes visible instead of argued about.
- (void)noteTimeline:(NSString *)host path:(NSString *)path;
- (NSArray<NSString *> *)timeline;

#pragma mark - Raw socket observation

/// A completed outbound `connect()`, e.g. "112.16.240.41:443".
///
/// Anything that shows up here and has no corresponding entry in the request
/// timeline is traffic that does not use the URL loading system at all -- i.e. a
/// client's own network stack or a long-lived connection.
- (void)noteSocketEndpoint:(NSString *)endpoint;
- (NSArray<NSString *> *)socketEndpoints;
@property (nonatomic, readonly) NSUInteger socketConnects;

/// DNS answers seen, so a bare address in the socket list can be attributed.
- (void)noteDNSName:(NSString *)name addresses:(NSArray<NSString *> *)addresses;
- (NSString * _Nullable)hostnameForAddress:(NSString *)address;

/// The field structure of a response that passed through unchanged, once per
/// endpoint. Kept here rather than only in the log so it travels inside the
/// capture report the user already knows how to send.
- (void)noteShape:(NSString *)shape forPath:(NSString *)path;
- (NSDictionary<NSString *, NSString *> *)shapes;

@property (nonatomic, readonly) NSUInteger resolveAttempts;
@property (nonatomic, readonly) NSUInteger resolveHits;
@property (nonatomic, readonly) NSUInteger resolveMisses;
@property (nonatomic, readonly) NSUInteger failures;

/// Per-source counters: hit / miss / attempt.
- (NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *)providerCounters;

/// "拦截 12 | 改写 5 | 命中 5/9" — safe to call from the main thread.
- (NSString *)summary;

/// Human-readable multi-line dump for the diagnostics screen.
- (NSString *)detailDump;

@end

NS_ASSUME_NONNULL_END
