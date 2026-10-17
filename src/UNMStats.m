//
//  UNMStats.m
//

#import "UNMStats.h"
#import "UNMConfig.h"
#import "UNMInternal.h"
#import "UNMUtil.h"

static const NSUInteger kUNMEventRingSize = 200;

@implementation UNMStats {
    NSLock *_lock;
    NSMutableDictionary<NSString *, NSNumber *> *_providerAttempts;
    NSMutableDictionary<NSString *, NSNumber *> *_providerHits;
    NSMutableDictionary<NSString *, NSNumber *> *_providerMisses;
    NSMutableArray<NSString *> *_events;
    NSMutableArray<NSString *> *_seenPaths;
    NSMutableArray<NSString *> *_seenHosts;
    NSMutableArray<NSString *> *_requestPaths;
    NSMutableArray<NSString *> *_timeline;
    NSMutableDictionary<NSString *, NSNumber *> *_socketEndpoints;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_dnsNames;
    NSMutableDictionary<NSString *, NSString *> *_shapes;
}

+ (instancetype)shared {
    static UNMStats *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[UNMStats alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _providerAttempts = [NSMutableDictionary dictionary];
        _providerHits = [NSMutableDictionary dictionary];
        _providerMisses = [NSMutableDictionary dictionary];
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)bump:(NSUInteger *)counter by:(NSUInteger)amount {
    if (!counter) return;
    [_lock lock];
    *counter += amount;
    [_lock unlock];
}

- (void)bumpIntercept:(NSString *)label {
    [self bump:&_intercepts by:1];
    if (label.length) [self addEvent:[NSString stringWithFormat:@"拦截 %@", label]];
}

- (void)bumpPassthrough:(NSString *)label {
    [self bump:&_passthroughs by:1];
}

- (void)bumpRewrite:(NSString *)label {
    [self bump:&_rewrites by:1];
    if (label.length) [self addEvent:[NSString stringWithFormat:@"改写 %@", label]];
}

- (void)bumpResolveAttempt:(NSString *)provider {
    [self bump:&_resolveAttempts by:1];
    [_lock lock];
    _providerAttempts[provider] = @(_providerAttempts[provider].unsignedIntegerValue + 1);
    [_lock unlock];
}

- (void)bumpSessionTask:(NSString *)path {
    [self bump:&_sessionTasks by:1];
    if (path.length == 0) return;

    [_lock lock];
    if (!_seenPaths) _seenPaths = [NSMutableArray array];
    if (![_seenPaths containsObject:path]) {
        [_seenPaths addObject:path];
        while (_seenPaths.count > 60) [_seenPaths removeObjectAtIndex:0];
    }
    [_lock unlock];
}

- (NSArray<NSString *> *)seenPaths {
    [_lock lock];
    NSArray *copy = [_seenPaths copy];
    [_lock unlock];
    return copy ?: @[];
}

- (void)bumpSeenHost:(NSString *)host {
    if (host.length == 0) return;
    [_lock lock];
    if (!_seenHosts) _seenHosts = [NSMutableArray array];
    if (![_seenHosts containsObject:host]) {
        [_seenHosts addObject:host];
        while (_seenHosts.count > 40) [_seenHosts removeObjectAtIndex:0];
    }
    [_lock unlock];
}

- (NSArray<NSString *> *)seenHosts {
    [_lock lock];
    NSArray *copy = [_seenHosts copy];
    [_lock unlock];
    return copy ?: @[];
}

- (BOOL)noteRequestPath:(NSString *)path {
    if (path.length == 0) return NO;
    [_lock lock];
    if (!_requestPaths) _requestPaths = [NSMutableArray array];
    BOOL isNew = ![_requestPaths containsObject:path];
    if (isNew) {
        [_requestPaths addObject:path];
        while (_requestPaths.count > 40) [_requestPaths removeObjectAtIndex:0];
    }
    [_lock unlock];
    return isNew;
}

- (NSArray<NSString *> *)requestPaths {
    [_lock lock];
    NSArray *copy = [_requestPaths copy];
    [_lock unlock];
    return copy ?: @[];
}

- (void)noteTimeline:(NSString *)host path:(NSString *)path {
    if (host.length == 0) return;

    // Cached formatter: this runs on every intercepted request, and allocating an
    // NSDateFormatter each time is surprisingly expensive.
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
    });

    NSString *line = [NSString stringWithFormat:@"%@  %@%@",
                      [formatter stringFromDate:[NSDate date]], host, path ?: @""];

    [_lock lock];
    if (!_timeline) _timeline = [NSMutableArray array];
    [_timeline addObject:line];
    while (_timeline.count > 300) [_timeline removeObjectAtIndex:0];
    [_lock unlock];
}

- (NSArray<NSString *> *)timeline {
    [_lock lock];
    NSArray *copy = [_timeline copy];
    [_lock unlock];
    return copy ?: @[];
}

- (void)noteSocketEndpoint:(NSString *)endpoint {
    if (endpoint.length == 0) return;
    [self bump:&_socketConnects by:1];
    [_lock lock];
    if (!_socketEndpoints) _socketEndpoints = [NSMutableDictionary dictionary];
    _socketEndpoints[endpoint] = @([_socketEndpoints[endpoint] unsignedIntegerValue] + 1);
    [_lock unlock];
}

- (NSArray<NSString *> *)socketEndpoints {
    [_lock lock];
    NSArray *sorted = [_socketEndpoints.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger ca = [self->_socketEndpoints[a] unsignedIntegerValue];
        NSUInteger cb = [self->_socketEndpoints[b] unsignedIntegerValue];
        if (ca != cb) return ca > cb ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *endpoint in sorted) {
        [out addObject:[NSString stringWithFormat:@"%@ ×%@", endpoint, _socketEndpoints[endpoint]]];
    }
    [_lock unlock];
    return out;
}

- (void)noteShape:(NSString *)shape forPath:(NSString *)path {
    if (shape.length == 0 || path.length == 0) return;
    [_lock lock];
    if (!_shapes) _shapes = [NSMutableDictionary dictionary];
    _shapes[path] = shape;
    [_lock unlock];
}

- (NSDictionary<NSString *, NSString *> *)shapes {
    [_lock lock];
    NSDictionary *copy = [_shapes copy];
    [_lock unlock];
    return copy ?: @{};
}

- (void)noteDNSName:(NSString *)name addresses:(NSArray<NSString *> *)addresses {
    if (name.length == 0 || addresses.count == 0) return;
    [_lock lock];
    if (!_dnsNames) _dnsNames = [NSMutableDictionary dictionary];
    _dnsNames[name] = addresses;
    while (_dnsNames.count > 60) {
        [_dnsNames removeObjectForKey:_dnsNames.allKeys.firstObject];
    }
    [_lock unlock];
}

- (NSString *)hostnameForAddress:(NSString *)address {
    if (address.length == 0) return nil;
    [_lock lock];
    NSString *found = nil;
    for (NSString *name in _dnsNames) {
        if ([_dnsNames[name] containsObject:address]) { found = name; break; }
    }
    [_lock unlock];
    return found;
}

- (void)bumpResolveHit:(NSString *)provider {
    [self bump:&_resolveHits by:1];
    [_lock lock];
    _providerHits[provider] = @(_providerHits[provider].unsignedIntegerValue + 1);
    [_lock unlock];
}

- (void)bumpResolveMiss:(NSString *)provider {
    [self bump:&_resolveMisses by:1];
    [_lock lock];
    _providerMisses[provider] = @(_providerMisses[provider].unsignedIntegerValue + 1);
    [_lock unlock];
}

- (void)bumpFailure:(NSString *)label {
    [self bump:&_failures by:1];
    if (label.length) [self addEvent:[NSString stringWithFormat:@"失败 %@", label]];
}

- (void)addEvent:(NSString *)event {
    if (!event.length) return;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *stamped = [NSString stringWithFormat:@"%@  %@",
                         [fmt stringFromDate:[NSDate date]], event];

    [_lock lock];
    [_events addObject:stamped];
    while (_events.count > kUNMEventRingSize) [_events removeObjectAtIndex:0];
    [_lock unlock];
}

- (NSArray<NSString *> *)recentEvents {
    [_lock lock];
    NSArray *copy = [_events copy];
    [_lock unlock];
    return copy;
}

- (void)reset {
    [_lock lock];
    _intercepts = 0;
    _passthroughs = 0;
    _rewrites = 0;
    _sessionTasks = 0;
    _resolveAttempts = 0;
    _resolveHits = 0;
    _resolveMisses = 0;
    _failures = 0;
    [_providerAttempts removeAllObjects];
    [_providerHits removeAllObjects];
    [_providerMisses removeAllObjects];
    [_seenPaths removeAllObjects];
    [_seenHosts removeAllObjects];
    [_requestPaths removeAllObjects];
    [_timeline removeAllObjects];
    [_socketEndpoints removeAllObjects];
    [_dnsNames removeAllObjects];
    [_shapes removeAllObjects];
    _socketConnects = 0;
    [_events removeAllObjects];
    [_lock unlock];
}

- (NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *)providerCounters {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [_lock lock];
    NSMutableSet *keys = [NSMutableSet setWithArray:_providerAttempts.allKeys];
    [keys addObjectsFromArray:_providerHits.allKeys];
    [keys addObjectsFromArray:_providerMisses.allKeys];
    for (NSString *key in keys) {
        out[key] = @{
            @"attempt" : _providerAttempts[key] ?: @0,
            @"hit"     : _providerHits[key] ?: @0,
            @"miss"    : _providerMisses[key] ?: @0,
        };
    }
    [_lock unlock];
    return out;
}

- (NSString *)summary {
    return [NSString stringWithFormat:@"拦截 %lu | 改写 %lu | 换源命中 %lu/%lu",
            (unsigned long)self.intercepts, (unsigned long)self.rewrites,
            (unsigned long)self.resolveHits, (unsigned long)self.resolveAttempts];
}

- (NSString *)detailDump {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"协议拦截：  %lu\n", (unsigned long)self.intercepts];
    [s appendFormat:@"会话任务：  %lu  （在 NSURLSession 层看到的本 App 网易请求）\n",
        (unsigned long)self.sessionTasks];
    [s appendFormat:@"透传：      %lu\n", (unsigned long)self.passthroughs];
    [s appendFormat:@"改写：      %lu\n", (unsigned long)self.rewrites];
    [s appendFormat:@"换源尝试：  %lu\n", (unsigned long)self.resolveAttempts];
    [s appendFormat:@"换源命中：  %lu\n", (unsigned long)self.resolveHits];
    [s appendFormat:@"换源未命中：%lu\n", (unsigned long)self.resolveMisses];
    [s appendFormat:@"失败：      %lu\n", (unsigned long)self.failures];

    // Responses that passed through unchanged. Their structure is what the
    // rewriter needs to be taught next, so it belongs at the top of the report.
    NSDictionary<NSString *, NSString *> *shapes = [self shapes];
    if (shapes.count) {
        [s appendString:@"\n拦截到但没改写的响应结构（这就是下一步要针对的字段）：\n"];
        for (NSString *path in [shapes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [s appendFormat:@"  %@\n    %@\n", path, shapes[path]];
        }
    }

    NSDictionary *counters = [self providerCounters];
    if (counters.count) {
        [s appendString:@"\n音源：\n"];
        NSArray *keys = [counters.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *key in keys) {
            NSDictionary *c = counters[key];
            [s appendFormat:@"  %-8@ 尝试 %@  命中 %@  未中 %@\n", key,
             c[@"attempt"], c[@"hit"], c[@"miss"]];
        }
    }

    NSArray<NSString *> *paths = [self seenPaths];
    if (paths.count) {
        [s appendString:@"\n在会话层看到的网易接口：\n"];
        for (NSString *path in paths) [s appendFormat:@"  %@\n", path];
    }

    NSArray<NSString *> *hosts = [self seenHosts];
    if (hosts.count) {
        [s appendString:@"\n拦截器被咨询过的所有域名：\n"];
        for (NSString *host in hosts) [s appendFormat:@"  %@\n", host];
    }

    // The counters above exist to make the failure mode obvious without a second
    // round of questions.
    // Did the app ever ask the server about a song's availability at all?
    //
    // This is the one that matters most in practice: a client that has "this song
    // is not playable" cached locally simply never requests the URL, and then no
    // amount of interception or rewriting can help. Seeing the request paths makes
    // that unmistakable.
    BOOL sawSongEndpoint = NO;
    for (NSString *path in paths) {
        if ([path containsString:@"/song/enhance"] ||
            [path containsString:@"/song/detail"] ||
            [path containsString:@"/playlist/detail"] ||
            [path containsString:@"/song/url"]) {
            sawSongEndpoint = YES;
            break;
        }
    }

    // The timeline records host+path for *every* request, before any filtering, so
    // it also catches an API call that arrived on a host we would have rejected.
    BOOL sawApiInTimeline = NO;
    NSString *apiTimelineLine = nil;
    for (NSString *line in [self timeline]) {
        NSRange pathStart = [line rangeOfString:@"  "];
        NSString *rest = pathStart.location == NSNotFound
            ? line : [line substringFromIndex:NSMaxRange(pathStart)];
        NSRange slash = [rest rangeOfString:@"/"];
        NSString *pathOnly = slash.location == NSNotFound ? @"" : [rest substringFromIndex:slash.location];
        if (UNMPathLooksLikeNeteaseAPI(pathOnly)) {
            sawApiInTimeline = YES;
            apiTimelineLine = line;
            break;
        }
    }

    [s appendString:@"\n结论：\n"];
    if (self.resolveHits > 0 && self.rewrites == 0) {
        [s appendFormat:@"  ⚠️ 换源解析成功了 %lu 次，但一次都没投放到播放器（改写=0）。\n"
                        "     说明播放器没有读我们接管的那个 URL 字段。\n"
                        "     对照「模型层调用计数」：\n"
                        "       · 某字段读取次数为 0 → 播放器读的是别的字段，把那一页发给作者\n"
                        "       · 读取次数很多但仍然播不出来 → 说明投出去的地址被播放器拒了\n",
            (unsigned long)self.resolveHits];
    } else if (sawApiInTimeline && self.rewrites == 0) {
        [s appendFormat:@"  ✓ 时间线里出现了取链/权限类的接口请求，说明客户端确实会请求它：\n"
                        "     %@\n"
                        "     但一次都没改写成功。请把这一行连同整份报告发给作者 —— 域名如果不是\n"
                        "     *.music.163.com 而是裸 IP，说明客户端按 IP 直连 API。\n",
            apiTimelineLine ?: @""];
    } else if (paths.count > 0 && !sawSongEndpoint) {
        [s appendFormat:@"  ⚠️ 本窗口内 App 请求了 %lu 个网易接口，里面没有任何和歌曲有关的\n"
                        "     （/song/enhance、/song/detail、/playlist/detail、/search、/playlist/privilege）。\n\n"
                        "     请做对照实验：播一首【完全正常、能播】的歌。\n"
                        "       · 如果报告里出现了 /song/enhance/player/url → 客户端的取链请求是\n"
                        "         可以拦到的；灰歌之所以没有，是客户端在本地就拒了它。\n"
                        "         那下一步要解决的是「让列表先变白」，不是换音源。\n"
                        "       · 如果连正常歌也没有 → 客户端拿播放地址不经过 NSURLSession，\n"
                        "         要去更底层找拦截面。请把这份报告发给作者。\n",
            (unsigned long)paths.count];
    } else if (hosts.count == 0 && self.sessionTasks == 0 && self.intercepts == 0) {
        [s appendString:@"  ⚠️ 拦截器从来没被咨询过，会话层也没看到请求 —— 客户端的接口请求根本没经过\n"
                       "     URL Loading System（NSURLSession / NSURLConnection）。\n"
                       "     需要到它自己的网络层找 hook 点：点「抓取 30 秒诊断」，播一首灰歌，\n"
                       "     把结果发给作者。\n"];
    } else if (self.intercepts == 0) {
        [s appendString:@"  ⚠️ 能看到流量，但协议层一次都没拦到。对照上面「被咨询过的所有域名」：\n"
                       "     如果网易的 API 域名不在里面，就是域名白名单没覆盖到它 —— 把这份列表\n"
                       "     发给作者。\n"];
    } else if (self.rewrites == 0) {
        [s appendString:@"  ⚠️ 拦到请求但一次都没改写：说明拦到的不是需要改的接口。\n"
                       "     看上面「会话层看到的网易接口」列表，确认里面有没有\n"
                       "     /song/enhance/privilege 和 /song/enhance/player/url。\n"];
    } else if (self.rewrites > 0 && self.resolveHits == 0) {
        [s appendString:@"  ⚠️ 有改写但换源一次没命中：音源能连通（自检通过）但匹配不上。\n"
                       "     把匹配阈值调到 0.5 再试，或把日志发给作者看具体是哪首歌。\n"];
    } else if (self.rewrites > 0) {
        [s appendString:@"  ✓ 改写和换源都在工作。若界面仍显示灰色，那是客户端本地缓存，\n"
                       "     去 App「设置 → 清除缓存」后完全重启。\n"];
    } else {
        [s appendString:@"  还没有足够数据。播放一首灰色的歌，再回来看这一页。\n"];
    }

    NSArray<NSString *> *endpoints = [self socketEndpoints];
    if (endpoints.count) {
        [s appendFormat:@"\n底层 socket 外连（%lu 次，含 URLSession 自己的）：\n",
            (unsigned long)self.socketConnects];
        NSInteger shown = 0;
        for (NSString *entry in endpoints) {
            if (shown++ >= 40) break;
            // Annotate with the DNS answer when we saw one, so a bare address is
            // readable as the host it came from.
            NSRange colon = [entry rangeOfString:@":" options:NSBackwardsSearch];
            NSString *address = colon.location == NSNotFound ? entry : [entry substringToIndex:colon.location];
            NSString *hostname = [self hostnameForAddress:address];
            [s appendFormat:@"  %@%@\n", entry, hostname.length ? [NSString stringWithFormat:@"   (%@)", hostname] : @""];
        }
    }

    NSArray<NSString *> *timeline = [self timeline];
    if (timeline.count) {
        [s appendString:@"\n请求时间线（最后 90 条，含音频 CDN —— 顺序是关键）：\n"];
        NSInteger start = MAX(0, (NSInteger)timeline.count - 90);
        for (NSInteger i = start; i < (NSInteger)timeline.count; i++) {
            [s appendFormat:@"  %@\n", timeline[(NSUInteger)i]];
        }
    }

    NSArray<NSString *> *events = [self recentEvents];
    if (events.count) {
        [s appendString:@"\n最近事件：\n"];
        NSInteger start = MAX(0, (NSInteger)events.count - 40);
        for (NSInteger i = start; i < (NSInteger)events.count; i++) {
            [s appendFormat:@"  %@\n", events[(NSUInteger)i]];
        }
    }
    return s;
}

@end
