//
//  UNMConfig.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMConfig : NSObject

+ (instancetype)shared;

/// Re-read the config file if it changed. Cheap; call before every decision.
- (void)reload;

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly, copy) NSArray<NSString *> *providerOrder;
/// Optional per-source cookies, e.g. {"migu": "session=...", "kugou": "kg_mid=..."}.
/// MiGu and KuGou only hand out URLs to logged-in callers, so these are how
/// those two sources are made usable without shipping any hard-coded account.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *providerCookies;
@property (nonatomic, readonly) BOOL rewritePlayerURL;
@property (nonatomic, readonly) BOOL rewriteDownloadURL;
@property (nonatomic, readonly) BOOL rewritePrivilege;
@property (nonatomic, readonly) BOOL enableXRealIP;
@property (nonatomic, readonly, copy) NSString *xRealIP;
@property (nonatomic, readonly) NSInteger lookupTimeoutMS;
@property (nonatomic, readonly) NSInteger totalTimeoutMS;
@property (nonatomic, readonly) NSInteger maxLookupsPerResponse;
@property (nonatomic, readonly) BOOL prefetchFromPrivilege;
@property (nonatomic, readonly) NSInteger prefetchConcurrency;
@property (nonatomic, readonly) BOOL discoveryMode;
@property (nonatomic, readonly, copy) NSArray<NSString *> *extraHooks;
@property (nonatomic, readonly) double matchThreshold;
@property (nonatomic, readonly) double matchDurationTolerance;
@property (nonatomic, readonly) NSInteger logLevel;
@property (nonatomic, readonly) BOOL neteaseDetailFallback;
@property (nonatomic, readonly) BOOL logEveryIntercept;
@property (nonatomic, readonly) NSInteger cacheTTLHours;

#pragma mark - Menu entries

@property (nonatomic, readonly) BOOL showFloatingButton;
@property (nonatomic, readonly) BOOL enableShakeMenu;
@property (nonatomic, readonly) BOOL showNavBarEntry;

/// Force the client's own model to treat songs as playable, and deliver a
/// substitute URL through NMSongUrlInfo.
///
/// This is the only interception surface left: the play URL is not fetched by any
/// request the URL loading system can observe, so there is nothing on the response
/// path to rewrite. Defaults to on.
@property (nonatomic, readonly) BOOL forceUnblock;

/// How long the URL getter may wait for a source lookup before giving up.
///
/// A pure "warm cache only" policy turned out to be wrong: the player read
/// NMSongUrlInfo.url before the prefetch triggered from the privilege getter had
/// finished, so every read returned nil and nothing played. Waiting a moment on
/// this one path is the better trade -- it is the playback path, and the
/// alternative is a song that cannot start at all.
@property (nonatomic, readonly) NSInteger urlWaitMS;



/// Refuse a candidate outright when it is a different kind of recording from the
/// song being replaced (live / remix / instrumental / cover).
///
/// Scoring them down was not enough in practice: a remix that matches the title and
/// artist perfectly still scores well enough to be chosen once the right version is
/// missing or its URL will not resolve. With this on, a remix can never stand in for
/// a studio track -- the song simply reports that it cannot be played. Defaults to
/// on, because a wrong version is worse than silence.
@property (nonatomic, readonly) BOOL rejectVariants;

/// The device id sent to BoDian. KuWo unlocks paid tracks per device, server-side,
/// so this has to be an id that has already watched the unlocking advert. See the
/// provider for the measurement.
@property (nonatomic, copy, readonly) NSString *bodianDevid;

/// Substitute only songs the client itself considers unplayable.
///
/// The URL holder reads empty for every song on its first access, so replacing
/// there also hijacked licensed tracks and cloud-drive uploads. Defaults to on.
@property (nonatomic, readonly) BOOL onlyReplaceGrey;

/// Where the config was actually loaded from (nil when defaults are in use).
@property (nonatomic, readonly, copy, nullable) NSString *loadedFrom;
/// Where a template config was written / should be edited.
@property (nonatomic, readonly, copy) NSString *configPath;

- (NSString *)dump;

#pragma mark - Writing

/// Force the next reload() to actually re-read the file.
- (void)forceReload;

/// Persist one key into the highest-priority config file and reload.
/// Passing nil removes the key. Returns NO when the file could not be written.
///
/// Deliberately NOT named -setValue:forKey: -- that selector belongs to KVC and
/// redeclaring it with a BOOL return type would clash with NSObject.
- (BOOL)persistValue:(id _Nullable)value forKey:(NSString *)key;

/// Read a key straight from the config file, bypassing the typed properties.
/// Used for bookkeeping flags that the config object does not model.
- (BOOL)rawBoolForKey:(NSString *)key;
- (void)setRawBool:(BOOL)value forKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
