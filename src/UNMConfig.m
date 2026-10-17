//
//  UNMConfig.m
//

#import "UNMConfig.h"
#import "UNMLog.h"
#import "UNMUtil.h"

@implementation UNMConfig {
    NSDictionary *_raw;
    double _lastCheck;
}

+ (instancetype)shared {
    static UNMConfig *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[UNMConfig alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self applyDefaults];
        [self reload];
        [self writeTemplateIfMissing];
    }
    return self;
}

#pragma mark - Paths

- (NSString *)configPath {
    // 1) An explicit file dropped next to the app's documents.
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docs stringByAppendingPathComponent:@"unmios.plist"];
}

- (NSArray<NSString *> *)candidatePaths {
    NSString *home = NSHomeDirectory();
    NSMutableArray *paths = [NSMutableArray array];
    // Most specific last: later entries win during merge.
    [paths addObject:@"/var/mobile/Library/Preferences/com.hzeroer.unmios.plist"];
    [paths addObject:[home stringByAppendingPathComponent:@"Library/Preferences/com.hzeroer.unmios.plist"]];
    [paths addObject:[self configPath]];
    NSString *docs = [self.configPath stringByDeletingLastPathComponent];
    [paths addObject:[docs stringByAppendingPathComponent:@"unmios.json"]];
    return paths;
}

#pragma mark - Defaults

- (void)applyDefaults {
    _enabled = YES;
    _providerOrder = @[ @"migu", @"kuwo" ];
    _providerCookies = @{};
    _rewritePlayerURL = YES;
    _rewriteDownloadURL = YES;
    _rewritePrivilege = YES;
    _enableXRealIP = YES;
    _xRealIP = @"118.88.88.8";
    _lookupTimeoutMS = 2000;
    _totalTimeoutMS = 5500;
    _maxLookupsPerResponse = 3;
    _prefetchFromPrivilege = YES;
    _prefetchConcurrency = 2;
    _discoveryMode = NO;
    _extraHooks = @[];
    _matchThreshold = 0.60;
    _matchDurationTolerance = 6.0;
    _logLevel = UNMLogInfo;
    _neteaseDetailFallback = YES;
    _logEveryIntercept = NO;
    _cacheTTLHours = 24 * 7;
    _showFloatingButton = YES;    _enableShakeMenu = YES;
    _showNavBarEntry = NO;
    _forceUnblock = YES;
    _urlWaitMS = 2500;
    _rejectVariants = YES;
}

#pragma mark - Load

static BOOL UNMBool(NSDictionary *d, NSString *k, BOOL fallback) {
    id v = d[k];
    if (!v || v == NSNull.null) return fallback;
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static NSInteger UNMInt(NSDictionary *d, NSString *k, NSInteger fallback) {
    id v = d[k];
    if (!v || v == NSNull.null) return fallback;
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : fallback;
}

static double UNMDouble(NSDictionary *d, NSString *k, double fallback) {
    id v = d[k];
    if (!v || v == NSNull.null) return fallback;
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}

static NSString *UNMStr(NSDictionary *d, NSString *k, NSString *fallback) {
    id v = d[k];
    return [v isKindOfClass:NSString.class] ? v : fallback;
}

static NSArray<NSString *> *UNMStrArray(NSDictionary *d, NSString *k, NSArray *fallback) {
    NSArray *v = UNMAsArray(d[k]);
    if (!v) return fallback;
    NSMutableArray *out = [NSMutableArray array];
    for (id item in v) {
        if ([item isKindOfClass:NSString.class]) [out addObject:item];
    }
    return out.count ? out : fallback;
}

- (void)reload {
    // Throttle: reload() is called on every decision point, but the config file
    // is only re-read a couple of times per second at most.
    double now = CFAbsoluteTimeGetCurrent();
    if (_lastCheck != 0 && now - _lastCheck < 2.0) return;
    _lastCheck = now;

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSString *from = nil;

    for (NSString *path in [self candidatePaths]) {
        NSDictionary *file = [self readConfigAtPath:path];
        if (file.count) {
            [merged addEntriesFromDictionary:file];
            from = path;
        }
    }
    _loadedFrom = from;
    _raw = merged.count ? merged : nil;

    [self applyDefaults];
    if (!_raw) return;

    NSDictionary *d = _raw;
    if (d[@"enabled"]) _enabled = UNMBool(d, @"enabled", YES);
    _providerOrder = UNMStrArray(d, @"providerOrder", _providerOrder);

    // MiGu goes first, and is present even if the stored config left it out.
    //
    // It is the source that actually carries the studio recordings (verified: 稻香
    // from 魔杰座 resolves there as an 8.5 MB file), while KuWo was observed handing
    // back the *same* file for two different songs and serving Chinese-named files
    // that turn out to be something other than the requested track. A stored order
    // written by an older build -- or by hand, with MiGu switched off -- would
    // otherwise leave KuWo as the only source, which is exactly what was happening.
    {
        NSMutableArray<NSString *> *reordered = [_providerOrder mutableCopy] ?: [NSMutableArray array];
        [reordered removeObject:@"migu"];
        [reordered insertObject:@"migu" atIndex:0];
        _providerOrder = reordered;
    }
    NSDictionary *cookies = UNMAsDict(d[@"providerCookies"]);
    if (cookies.count) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        for (NSString *key in cookies) {
            if ([cookies[key] isKindOfClass:NSString.class]) clean[key.lowercaseString] = cookies[key];
        }
        _providerCookies = clean;
    }
    _rewritePlayerURL = UNMBool(d, @"rewritePlayerURL", _rewritePlayerURL);
    _rewriteDownloadURL = UNMBool(d, @"rewriteDownloadURL", _rewriteDownloadURL);
    _rewritePrivilege = UNMBool(d, @"rewritePrivilege", _rewritePrivilege);
    _enableXRealIP = UNMBool(d, @"enableXRealIP", _enableXRealIP);
    _xRealIP = UNMStr(d, @"xRealIP", _xRealIP);
    _lookupTimeoutMS = UNMInt(d, @"lookupTimeoutMS", _lookupTimeoutMS);
    _totalTimeoutMS = UNMInt(d, @"totalTimeoutMS", _totalTimeoutMS);
    _maxLookupsPerResponse = UNMInt(d, @"maxLookupsPerResponse", _maxLookupsPerResponse);
    _prefetchFromPrivilege = UNMBool(d, @"prefetchFromPrivilege", _prefetchFromPrivilege);
    _prefetchConcurrency = UNMInt(d, @"prefetchConcurrency", _prefetchConcurrency);
    _discoveryMode = UNMBool(d, @"discoveryMode", _discoveryMode);
    _extraHooks = UNMStrArray(d, @"extraHooks", _extraHooks);
    _matchThreshold = UNMDouble(d, @"matchThreshold", _matchThreshold);
    _matchDurationTolerance = UNMDouble(d, @"matchDurationTolerance", _matchDurationTolerance);
    _logLevel = UNMInt(d, @"logLevel", _logLevel);
    _neteaseDetailFallback = UNMBool(d, @"neteaseDetailFallback", _neteaseDetailFallback);
    _logEveryIntercept = UNMBool(d, @"logEveryIntercept", _logEveryIntercept);
    _cacheTTLHours = UNMInt(d, @"cacheTTLHours", _cacheTTLHours);
    _showFloatingButton = UNMBool(d, @"showFloatingButton", _showFloatingButton);
    _enableShakeMenu = UNMBool(d, @"enableShakeMenu", _enableShakeMenu);
    _forceUnblock = UNMBool(d, @"forceUnblock", _forceUnblock);
    if (d[@"urlWaitMS"]) _urlWaitMS = UNMInt(d, @"urlWaitMS", _urlWaitMS);
    _rejectVariants = UNMBool(d, @"rejectVariants", _rejectVariants);
    _showNavBarEntry = UNMBool(d, @"showNavBarEntry", _showNavBarEntry);

    UNMLogSetLevel((UNMLogLevel)_logLevel);
    UNMLogSetDiscovery(_discoveryMode);
}

- (void)forceReload {
    _lastCheck = 0;
    [self reload];
}

- (BOOL)persistValue:(id)value forKey:(NSString *)key {
    if (key.length == 0) return NO;

    NSMutableDictionary *dict =
        [[NSDictionary dictionaryWithContentsOfFile:self.configPath] mutableCopy];
    if (!dict) dict = [NSMutableDictionary dictionary];

    if (value == nil) {
        [dict removeObjectForKey:key];
    } else {
        dict[key] = value;
    }

    BOOL ok = [dict writeToFile:self.configPath atomically:YES];
    if (ok) {
        [self forceReload];
        UNMLogI(@"config updated: %@ = %@", key, value ?: @"<removed>");
    } else {
        UNMLogW(@"config write failed for %@", key);
    }
    return ok;
}

- (BOOL)rawBoolForKey:(NSString *)key {
    if (key.length == 0) return NO;
    // Read the file rather than _raw, so a value written moments ago is seen even
    // if the throttled reload has not run yet.
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:self.configPath];
    return UNMBool(dict ?: _raw, key, NO);
}

- (void)setRawBool:(BOOL)value forKey:(NSString *)key {
    [self persistValue:@(value) forKey:key];
}

- (NSDictionary *)readConfigAtPath:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;

    id obj = nil;
    if ([self isJSONPath:path]) {
        obj = UNMJSONParse(data);
    } else {
        obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:0
                                                        format:NULL
                                                         error:NULL];
        if (!obj) obj = UNMJSONParse(data);
    }
    NSDictionary *d = UNMAsDict(obj);
    if (d.count) {
        UNMLogI(@"config loaded from %@ (%lu keys)", path, (unsigned long)d.count);
    }
    return d;
}

- (BOOL)isJSONPath:(NSString *)path {
    return [path.pathExtension.lowercaseString isEqualToString:@"json"];
}

- (void)writeTemplateIfMissing {
    NSString *path = self.configPath;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;

    NSDictionary *tpl = @{
        @"enabled"               : @YES,
        @"providerOrder"         : @[ @"migu", @"kuwo" ],
        @"providerCookies"       : @{},
        @"rewritePlayerURL"      : @YES,
        @"rewriteDownloadURL"    : @YES,
        @"rewritePrivilege"      : @YES,
        @"enableXRealIP"         : @YES,
        @"xRealIP"               : @"118.88.88.8",
        @"lookupTimeoutMS"       : @2000,
        @"totalTimeoutMS"        : @5500,
        @"maxLookupsPerResponse" : @3,
        @"prefetchFromPrivilege" : @YES,
        @"prefetchConcurrency"   : @2,
        @"discoveryMode"         : @NO,
        @"logEveryIntercept"     : @NO,
        @"extraHooks"            : @[],
        @"matchThreshold"        : @0.60,
        @"matchDurationTolerance": @6.0,
        @"logLevel"              : @3,
        @"neteaseDetailFallback" : @YES,
        @"cacheTTLHours"         : @168,
        @"showFloatingButton"    : @YES,
        @"forceUnblock"          : @YES,
        @"urlWaitMS"            : @2500,
        @"rejectVariants"       : @YES,
        @"enableShakeMenu"       : @YES,
        @"showNavBarEntry"       : @NO,
    };
    BOOL ok = [tpl writeToFile:path atomically:YES];
    if (ok) {
        UNMLogI(@"config template written: %@", path);
    } else {
        UNMLogW(@"could not write config template at %@", path);
    }
}

- (NSString *)dump {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"enabled=%d", self.enabled];
    [s appendFormat:@" providers=%@", [self.providerOrder componentsJoinedByString:@","]];
    [s appendFormat:@" cookies=%lu", (unsigned long)self.providerCookies.count];
    [s appendFormat:@" playerURL=%d downloadURL=%d privilege=%d",
        self.rewritePlayerURL, self.rewriteDownloadURL, self.rewritePrivilege];
    [s appendFormat:@" xRealIP=%@(%d)", self.xRealIP, self.enableXRealIP];
    [s appendFormat:@" timeouts=%ld/%ldms", (long)self.lookupTimeoutMS, (long)self.totalTimeoutMS];
    [s appendFormat:@" maxLookups=%ld", (long)self.maxLookupsPerResponse];
    [s appendFormat:@" prefetch=%d x%ld", self.prefetchFromPrivilege, (long)self.prefetchConcurrency];
    [s appendFormat:@" threshold=%.2f", self.matchThreshold];
    [s appendFormat:@" discovery=%d logLevel=%ld", self.discoveryMode, (long)self.logLevel];
    [s appendFormat:@" hooks=%lu", (unsigned long)self.extraHooks.count];
    [s appendFormat:@" menu=%d/%d/%d", self.showFloatingButton, self.enableShakeMenu, self.showNavBarEntry];
    [s appendFormat:@" forceUnblock=%d", self.forceUnblock];
    [s appendFormat:@" urlWait=%ldms", (long)self.urlWaitMS];
    [s appendFormat:@" rejectVariants=%d", self.rejectVariants];
    [s appendFormat:@" from=%@", self.loadedFrom ?: @"<defaults>"];
    return s;
}

@end
