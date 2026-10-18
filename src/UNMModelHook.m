//
//  UNMModelHook.m
//

#import "UNMModelHook.h"
#import "UNMFavorite.h"
#import "UNMConfig.h"
#import "UNMHook.h"
#import "UNMLog.h"
#import "UNMStats.h"
#import "UNMStore.h"
#import "UNMUtil.h"

#import <objc/runtime.h>

// MARK: - Counters

// A hook being installed says nothing about whether the client ever calls it.
// These counters are what separate "the model was taken over" from "the client
// went down a different path entirely" -- e.g. NMSongUrlInfo.url never being read
// means the player never asked that object for a URL.
enum {
    UNMHookCtrPrivStatus = 0,
    UNMHookCtrPrivFee,
    UNMHookCtrSongCanPlay,
    UNMHookCtrPrivSynthesized,
    UNMHookCtrUrlInfoSynthesized,
    UNMHookCtrUrlGet,
    UNMHookCtrUrlEmpty,
    UNMHookCtrUrlDelivered,
    UNMHookCtrGenericUrlGet,
    UNMHookCtrMainThreadSkip,
    UNMHookCtrCount
};

static volatile int32_t gCounters[UNMHookCtrCount];

static void UNMCountHook(int index) {
    if (index < 0 || index >= UNMHookCtrCount) return;
    __atomic_fetch_add(&gCounters[index], 1, __ATOMIC_RELAXED);
}

static int32_t UNMCountRead(int index) {
    if (index < 0 || index >= UNMHookCtrCount) return 0;
    return __atomic_load_n(&gCounters[index], __ATOMIC_RELAXED);
}

// MARK: - Last attempt record

// The client says only "歌曲不存在". These fields capture, for the most recent
// song it tried, what every link in the chain actually saw -- so the failure stops
// being a guess between "no URL", "URL delivered but rejected", "playUrlInfo
// missing" and "privilege still restricted".
static NSLock *gLastLock = nil;
static NSString *gLastSongId = nil;
static CFAbsoluteTime gLastTime = 0;
static int gLastUrlReads = 0;
static int gLastUrlEmpty = 0;
static int gLastDelivered = 0;
static NSString *gLastDeliveredURL = nil;
static int gLastPlayUrlInfoReads = 0;
static int gLastPlayUrlInfoNil = 0;
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *gOrigPriv = nil;

static void UNMLastEnsure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLastLock = [[NSLock alloc] init];
        gOrigPriv = [NSMutableDictionary dictionary];
    });
}

static void UNMLastBegin(NSString *songId) {
    UNMLastEnsure();

    [gLastLock lock];
    BOOL changed = (gLastSongId == nil) || ![gLastSongId isEqualToString:songId];
    if (changed) {
        gLastSongId = [songId copy];
        gLastTime = CFAbsoluteTimeGetCurrent();
        gLastUrlReads = 0;
        gLastUrlEmpty = 0;
        gLastDelivered = 0;
        gLastDeliveredURL = nil;
        gLastPlayUrlInfoReads = 0;
        gLastPlayUrlInfoNil = 0;
    }
    gLastUrlReads++;
    [gLastLock unlock];
}


/// Reading the config on every getter would be wasteful: these getters run for
/// every row of every list. A coarse cache is enough, since a toggle takes effect
/// within a second.
static BOOL UNMModelHookEnabled(void) {
    static BOOL cached = NO;
    static CFAbsoluteTime lastCheck = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCheck > 1.0) {
        UNMConfig *cfg = [UNMConfig shared];
        cached = cfg.enabled && cfg.forceUnblock && cfg.injectModelURL;
        lastCheck = now;
    }
    return cached;
}

// The song the client last asked about, and when.
//
// Some clients ask for a URL on an object that carries no song id (the iPad HD
// build does). The song model is always read first, so the most recent id is a
// usable stand-in -- but only for a few seconds, because the player may move on.
static NSUInteger gExceptionCount = 0;
static void UNMCountException(void) { gExceptionCount++; }
static NSUInteger UNMExceptionCount(void) { return gExceptionCount; }

static long long gAskedSongID = 0;
static CFAbsoluteTime gAskedAt = 0;
static NSLock *gAskedLock = nil;

static void UNMNoteAskedSongID(NSString *songId) {
    if (songId.length == 0) return;
    long long value = songId.longLongValue;
    if (value == 0) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAskedLock = [[NSLock alloc] init]; });
    [gAskedLock lock];
    gAskedSongID = value;
    gAskedAt = CFAbsoluteTimeGetCurrent();
    [gAskedLock unlock];
}

static long long UNMRecentAskedSongID(void) {
    if (gAskedLock == nil) return 0;
    [gAskedLock lock];
    long long value = (CFAbsoluteTimeGetCurrent() - gAskedAt < 3.0) ? gAskedSongID : 0;
    [gAskedLock unlock];
    return value;
}

/// Calls through to the real implementation for this receiver. Returns NO/nil/0
/// when the registry has nothing, which means the hook was entered for a class we
/// never installed on -- in that case the caller must not invent a value.
typedef long long (*UNMLLGetFn)(id, SEL);
typedef BOOL (*UNMBoolGetFn)(id, SEL);
typedef id (*UNMObjGetFn)(id, SEL);

static long long UNMOriginalLL(id self_, SEL _cmd) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    return original ? ((UNMLLGetFn)original)(self_, _cmd) : 0;
}

static BOOL UNMOriginalBool(id self_, SEL _cmd) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    return original ? ((UNMBoolGetFn)original)(self_, _cmd) : NO;
}

static id UNMOriginalObject(id self_, SEL _cmd) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    return original ? ((UNMObjGetFn)original)(self_, _cmd) : nil;
}

// MARK: - Song identity

/// The song id carried by a model object, or nil.
///
/// KVC on a key the class does not have raises NSUnknownKeyException, which would
/// take the app down. So the selector is looked up first -- and an id attached
/// when the object was synthesised is accepted as a fallback, which is what lets
/// a synthesised NMSongCacheUrlInfo (whose real class may have no songId) still
/// resolve to a song.
static const void *UNMSongIdAssociation = &UNMSongIdAssociation;

static NSString *UNMSongIdOfObject(id object) {
    if (object == nil) return nil;

    id attached = objc_getAssociatedObject(object, UNMSongIdAssociation);
    if ([attached isKindOfClass:NSString.class] && [attached length]) return attached;

    Class cls = object_getClass(object);
    SEL sel = NSSelectorFromString(@"songId");
    if (UNMLookupMethod(cls, sel, NO, NULL) == NULL) return nil;

    id value = [object valueForKey:@"songId"];
    NSString *result = nil;
    if ([value isKindOfClass:NSString.class]) {
        result = value;
    } else if (value != nil) {
        result = [value description];
    }
    // Cache it: this runs on the hot path (every privilege read of every row), and
    // KVC is far slower than a hash lookup.
    if (result.length) {
        objc_setAssociatedObject(object, UNMSongIdAssociation, result,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return result;
}

// MARK: - Prefetch (batched)

// Prefetching one song per privilege read is what made a long playlist crawl:
// opening a 500-song list fired 500 lookups, each of which now costs several
// variant requests plus a validation probe. They are queued instead and flushed a
// few at a time, so opening a list costs a set insert per row, not a lookup.
static NSMutableOrderedSet<NSString *> *gPending = nil;
static NSMutableSet<NSString *> *gPrefetched = nil;
static NSLock *gPendingLock = nil;
static BOOL gFlushScheduled = NO;

static void UNMFlushPrefetch(void);

static void UNMQueuePrefetch(NSString *songId) {
    if (songId.length == 0) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPending = [NSMutableOrderedSet orderedSet];
        gPrefetched = [NSMutableSet set];
        gPendingLock = [[NSLock alloc] init];
    });

    BOOL schedule = NO;
    [gPendingLock lock];
    if (![gPrefetched containsObject:songId] && gPending.count < 40) {
        [gPending addObject:songId];
        [gPrefetched addObject:songId];
        if (gPrefetched.count > 600) [gPrefetched removeAllObjects];
        if (!gFlushScheduled) {
            gFlushScheduled = YES;
            schedule = YES;
        }
    }
    [gPendingLock unlock];

    if (schedule) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UNMFlushPrefetch();
        });
    }
}

static void UNMFlushPrefetch(void) {
    NSMutableArray<NSNumber *> *batch = [NSMutableArray array];
    NSUInteger remaining = 0;

    [gPendingLock lock];
    // Hand over in reasonable batches and let the store's own concurrency limit
    // the actual network load. The previous 4-per-0.8s throttle was the reason
    // only three of a thousand reads ever found a warm URL: the queue simply could
    // not keep up with the client reading ahead of it.
    NSInteger take = (NSInteger)MIN(gPending.count, (NSUInteger)3);
    for (NSInteger i = 0; i < take; i++) {
        NSString *songId = gPending.firstObject;
        [gPending removeObjectAtIndex:0];
        long long value = songId.longLongValue;
        if (value) [batch addObject:@(value)];
    }
    remaining = gPending.count;
    gFlushScheduled = (remaining > 0);
    [gPendingLock unlock];

    if (batch.count) {
        [[UNMStore shared] prefetchIDs:batch];
        UNMLogD(@"[model] 批量预取 %lu 首（队列剩 %lu）",
                (unsigned long)batch.count, (unsigned long)remaining);
    }
    if (remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UNMFlushPrefetch();
        });
    }
}

/// Move a song to the front of the queue.
///
/// A read that came back empty means the client wants that song *now*, so it is
/// worth resolving before the rest of the list. Without this, a thousand reads of
/// a hundred songs left the queue permanently behind and only three were served.
static void UNMPrioritizePrefetch(NSString *songId) {
    if (songId.length == 0) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (gPending == nil) gPending = [NSMutableOrderedSet orderedSet];
        if (gPrefetched == nil) gPrefetched = [NSMutableSet set];
        if (gPendingLock == nil) gPendingLock = [[NSLock alloc] init];
    });

    BOOL schedule = NO;
    [gPendingLock lock];
    if (gPending.count < 40) {
        // Only touch the ordered set when the song is not already queued: on a big
        // list this is called once per grey row, and remove+insert churn adds up.
        if (![gPending containsObject:songId]) {
            [gPending insertObject:songId atIndex:0];
            if (!gFlushScheduled) {
                gFlushScheduled = YES;
                schedule = YES;
            }
        }
    }
    [gPendingLock unlock];

    if (schedule) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UNMFlushPrefetch();
        });
    }
}

// MARK: - Ask tracking

// A list build reads each song's URL once; the player reads the same song's URL
// over and over. That difference decides whether a read may wait for a lookup:
// waiting on every row is what froze long playlists, while waiting on a repeated
// read is exactly what makes a song start.
static NSMutableDictionary<NSString *, NSNumber *> *gAskCounts = nil;
static NSLock *gAskLock = nil;
static BOOL gBlocking = NO;
static CFAbsoluteTime gLastBlockEnd = 0;

static NSInteger UNMNoteAsk(NSString *songId) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAskCounts = [NSMutableDictionary dictionary];
        gAskLock = [[NSLock alloc] init];
    });

    [gAskLock lock];
    NSInteger count = [gAskCounts[songId] integerValue] + 1;
    gAskCounts[songId] = @(count);
    if (gAskCounts.count > 800) [gAskCounts removeAllObjects];
    [gAskLock unlock];
    return count;
}

/// At most one blocking lookup at a time, and never back to back.
static BOOL UNMAcquireBlockSlot(void) {
    if (gAskLock == nil) UNMNoteAsk(@"");
    BOOL ok = NO;
    [gAskLock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!gBlocking && (now - gLastBlockEnd) > 0.8) {
        gBlocking = YES;
        ok = YES;
    }
    [gAskLock unlock];
    return ok;
}

static void UNMReleaseBlockSlot(void) {
    [gAskLock lock];
    gBlocking = NO;
    gLastBlockEnd = CFAbsoluteTimeGetCurrent();
    [gAskLock unlock];
}

// MARK: - NMSongPrivilege

// The API's `st`/`fee`/`pl`/`dl`/`fl` fields, as this client models them:
//   status  -> st   (negative means restricted)
//   fee     -> fee  (0 free, 1 VIP, 4 album, 8 low-bitrate trial)
//   payed   -> whether the account already owns it
//   playMaxbr / downloadMaxbr / maxBitrate -> the bitrate ceiling

/// The exact string the client shows when it refuses an action.
///
/// 《版权方要求该资源无法操作》 is not generated by the UI: it is this field, filled in
/// by the server for a restricted track and shown verbatim. Returning nil removes the
/// reason to refuse, so the favourite request is actually sent.
static IMP gOrig_PrivCopyRightText = NULL;
static id UNMHooked_PrivCopyRightText(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalObject(self_, _cmd);
    return nil;
}

static IMP gOrig_PrivHasCopyRight = NULL;
static BOOL UNMHooked_PrivHasCopyRight(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalBool(self_, _cmd);
    return YES;
}

static IMP gOrig_PrivHasFreeTrialNoCopyright = NULL;
static BOOL UNMHooked_PrivHasFreeTrialNoCopyright(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalBool(self_, _cmd);
    return NO;
}

static IMP gOrig_SongCopyrightText = NULL;
static id UNMHooked_SongCopyrightText(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalObject(self_, _cmd);
    return nil;
}

static IMP gOrig_SongHasFreeTrialNoCopyright = NULL;
static BOOL UNMHooked_SongHasFreeTrialNoCopyright(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalBool(self_, _cmd);
    return NO;
}

static IMP gOrig_PrivStatus = NULL;
static long long UNMHooked_PrivStatus(id self_, SEL _cmd) {
    UNMCountHook(UNMHookCtrPrivStatus);

    // Read the real value first: it is what the diagnostic reports, and it says
    // whether the source called this song restricted (negative) or merely paid.
    long long original = UNMOriginalLL(self_, _cmd);
    if (!UNMModelHookEnabled()) return original;

    NSString *songId = UNMSongIdOfObject(self_);
    UNMNoteAskedSongID(songId);
    if (songId.length) {
        SEL feeSel = NSSelectorFromString(@"fee");
        IMP feeIMP = UNMHookOriginalForReceiver(self_, feeSel);
        long long feeValue = feeIMP ? ((long long (*)(id, SEL))feeIMP)(self_, feeSel) : 0;

        UNMLastEnsure();
        [gLastLock lock];
        if (gOrigPriv == nil) gOrigPriv = [NSMutableDictionary dictionary];
        if (gOrigPriv[songId] == nil) {
            if (gOrigPriv.count > 400) [gOrigPriv removeAllObjects];
            gOrigPriv[songId] = @[ @(original), @(feeValue) ];
        }
        [gLastLock unlock];
    }

    // Warm the first few rows of the list.
    //
    // Reading the URL is synchronous on the main thread and must never wait, so an
    // unwarmed song always fails its first attempt and only plays on the retry,
    // which the user sees as "无法播放" followed by it working. Queueing a lookup
    // while the list is being built is what closes that gap -- and it is only
    // affordable now that MiGu answers in two requests rather than seven. The queue
    // is deliberately tiny (the top few rows) and drains at a low rate, because
    // flooding it is what made long playlists crawl in the first place.
    if (gPending == nil || gPending.count < 40) {
        UNMQueuePrefetch(songId);
    }

    // 200 is this model's "normal" -- it is NOT the API's `st` field.
    //
    // Measured: a plain studio track (稻香, 魔杰座) reports status=200 at this
    // layer, while the NetEase API reports "status":0 for the same song. They are
    // different fields with different meanings. Forcing 0 rewrote a healthy value
    // into an unfamiliar one, which is a plausible cause of both the "歌曲不存在"
    // popups and the share sheet misbehaving. So an abnormal value is corrected, and
    // it is corrected to what a healthy song actually reports.
    return original > 0 ? original : 200;
}

static IMP gOrig_PrivFee = NULL;
static long long UNMHooked_PrivFee(id self_, SEL _cmd) {
    UNMCountHook(UNMHookCtrPrivFee);
    return UNMModelHookEnabled() ? 0 : UNMOriginalLL(self_, _cmd);
}

static IMP gOrig_PrivPayed = NULL;
static long long UNMHooked_PrivPayed(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 1 : UNMOriginalLL(self_, _cmd);
}

static IMP gOrig_PrivFlag = NULL;
static long long UNMHooked_PrivFlag(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 0 : UNMOriginalLL(self_, _cmd);
}

static IMP gOrig_PrivPlayMaxbr = NULL;
static long long UNMHooked_PrivPlayMaxbr(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 999000 : UNMOriginalLL(self_, _cmd);
}

static IMP gOrig_PrivDownloadMaxbr = NULL;
static long long UNMHooked_PrivDownloadMaxbr(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 999000 : UNMOriginalLL(self_, _cmd);
}

static IMP gOrig_PrivMaxBitrate = NULL;
static long long UNMHooked_PrivMaxBitrate(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 999000 : UNMOriginalLL(self_, _cmd);
}

// Boolean getters. The macro takes the full base name so the same shape can be
// used for the privilege, song and URL models.
#define UNM_BOOL_PREDICATE(base, value)                          \
    static IMP gOrig_##base = NULL;                              \
    static BOOL UNMHooked_##base(id self_, SEL _cmd) {           \
        return UNMModelHookEnabled() ? (value) : UNMOriginalBool(self_, _cmd); \
    }

UNM_BOOL_PREDICATE(Priv_isVipSong, NO)
UNM_BOOL_PREDICATE(Priv_isLimitFree, NO)
UNM_BOOL_PREDICATE(Priv_isExclusiveSong, NO)
UNM_BOOL_PREDICATE(Priv_isPlayOnlySong, NO)
UNM_BOOL_PREDICATE(Priv_isFakePrivilege, NO)

static IMP gOrig_PrivIsNoCopyright = NULL;
static BOOL UNMHooked_PrivIsNoCopyright(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? NO : UNMOriginalBool(self_, _cmd);
}

// Sharing is gated by its own fields, and a synthesised privilege starts with all
// of them at zero -- which reads as "this track may not be shared" and leaves the
// share sheet doing nothing. Forcing the play fields without these is what broke
// sharing while fixing playback.
static IMP gOrig_PrivSharePrivilege = NULL;
static long long UNMHooked_PrivSharePrivilege(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalLL(self_, _cmd);
    long long original = UNMOriginalLL(self_, _cmd);
    return original > 0 ? original : 1;
}

UNM_BOOL_PREDICATE(Priv_canShare, YES)

// MARK: - NMSong

// These are the predicates the list and the player actually consult. Deliberately
// absent: canPlayLocally, which would send the client looking for a file that does
// not exist.
static NSMutableDictionary<NSString *, NSNumber *> *gPlayable = nil;
static NSLock *gPlayableLock = nil;

/// Remember whether the client itself considered this song playable, before the
/// tweak overrides that answer.
static void UNMRecordOriginalPlayable(NSString *songId, BOOL playable) {
    if (songId.length == 0) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPlayableLock = [[NSLock alloc] init]; });
    [gPlayableLock lock];
    if (gPlayable == nil) gPlayable = [NSMutableDictionary dictionary];
    if (gPlayable.count > 2000) [gPlayable removeAllObjects];
    gPlayable[songId] = @(playable);
    [gPlayableLock unlock];
}

/// nil when the client never told us -- then substituting is allowed.
static NSNumber *UNMOriginalPlayableForID(NSString *songId) {
    if (gPlayableLock == nil || songId.length == 0) return nil;
    [gPlayableLock lock];
    NSNumber *value = gPlayable[songId];
    [gPlayableLock unlock];
    return value;
}

static IMP gOrig_SongCanPlayMusic = NULL;
static BOOL UNMHooked_SongCanPlayMusic(id self_, SEL _cmd) {
    BOOL original = UNMOriginalBool(self_, _cmd);
    if (!UNMModelHookEnabled()) return original;
    UNMRecordOriginalPlayable(UNMSongIdOfObject(self_), original);
    return YES;
}
UNM_BOOL_PREDICATE(SongCanPlayOnline, YES)
UNM_BOOL_PREDICATE(SongCanEnableMusic, YES)
// Sharing is a separate permission from playback.
UNM_BOOL_PREDICATE(SongCanShareMusic, YES)

static IMP gOrig_SongIsUnavailable = NULL;
static BOOL UNMHooked_SongIsUnavailable(id self_, SEL _cmd) {
    BOOL original = UNMOriginalBool(self_, _cmd);
    if (!UNMModelHookEnabled()) return original;
    if (original) UNMRecordOriginalPlayable(UNMSongIdOfObject(self_), NO);
    return NO;
}

static IMP gOrig_SongIsPlayOnly = NULL;
static BOOL UNMHooked_SongIsPlayOnly(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? NO : UNMOriginalBool(self_, _cmd);
}

static IMP gOrig_SongIsFeeSong = NULL;
static BOOL UNMHooked_SongIsFeeSong(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? NO : UNMOriginalBool(self_, _cmd);
}

static IMP gOrig_SongHasFeeIssue = NULL;
static BOOL UNMHooked_SongHasFeeIssue(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? NO : UNMOriginalBool(self_, _cmd);
}

static IMP gOrig_SongPrivilege = NULL;
static id UNMHooked_SongPrivilege(id self_, SEL _cmd) {
    id original = UNMOriginalObject(self_, _cmd);

    if (UNMModelHookEnabled()) {
        // The song object already carries its own title and artist, so seeding the
        // resolver from it removes the NetEase metadata lookup from the critical
        // path. That lookup was the bulk of the delay between tapping a song and
        // having a URL ready -- which is what made the first attempt fail.
        NSString *songId = UNMSongIdOfObject(self_);
    UNMNoteAskedSongID(songId);
        long long value = songId.longLongValue;
        if (value != 0) {
            NSString *name = nil;
            NSString *artist = nil;
            double duration = -1;

            SEL nameSel = NSSelectorFromString(@"name");
            if (UNMLookupMethod(object_getClass(self_), nameSel, NO, NULL) != NULL) {
                id raw = [self_ valueForKey:@"name"];
                if ([raw isKindOfClass:NSString.class]) name = raw;
            }
            SEL artistSel = NSSelectorFromString(@"artistName");
            if (UNMLookupMethod(object_getClass(self_), artistSel, NO, NULL) != NULL) {
                id raw = [self_ valueForKey:@"artistName"];
                if ([raw isKindOfClass:NSString.class]) artist = raw;
            }
            SEL durationSel = NSSelectorFromString(@"duration");
            if (UNMLookupMethod(object_getClass(self_), durationSel, NO, NULL) != NULL) {
                id raw = [self_ valueForKey:@"duration"];
                if ([raw respondsToSelector:@selector(doubleValue)]) duration = [raw doubleValue];
            }
            // The album matters: a concert album's tracks are titled plainly, so the
            // album name is the only thing that says "this one is a live recording".
            NSString *album = nil;
            SEL albumSel = NSSelectorFromString(@"albumName");
            if (UNMLookupMethod(object_getClass(self_), albumSel, NO, NULL) != NULL) {
                id raw = [self_ valueForKey:@"albumName"];
                if ([raw isKindOfClass:NSString.class]) album = raw;
            }
            if (name.length) {
                [[UNMStore shared] seedMetaForID:value
                                            name:name
                                          artist:artist
                                           album:album
                                        duration:duration];
            }
        }
    }

    if (original) return original;
    if (!UNMModelHookEnabled()) return nil;
    // A grey song frequently carries no privilege object at all, and a nil one
    // cannot be forced playable -- so one is synthesised on demand.
    UNMCountHook(UNMHookCtrPrivSynthesized);
    @try {
        return [UNMModelHook synthesizedPrivilegeForSong:self_];
    } @catch (NSException *exception) {
        UNMCountException();
        UNMLogW(@"[model] 合成 privilege 失败：%@", exception.reason);
        return nil;
    }
}

/// Per-bitrate file entry. `_songFile`, `_lfile`, `_mfile`, `_hfile` and friends
/// are all of this type.
///
/// Deliberately a pass-through: synthesising one produced an object the client
/// then used for lookups it expected to succeed, and the visible result was
/// "歌曲不存在" followed by a wedged player page. The URL is read from real
/// NMSongUrlInfo objects, so there is nothing to gain from inventing these.
static IMP gOrig_SongSongFile = NULL;
static id UNMHooked_SongSongFile(id self_, SEL _cmd) {
    return UNMOriginalObject(self_, _cmd);
}

/// The URL model the player reads for the current song.
///
/// Synthesised only when a substitute URL is already known: returning nil is what
/// the client reports as "歌曲不存在", but inventing an object with no URL behind
/// it just moves the failure. With a warm URL there is something real to hand over.
static IMP gOrig_SongPlayUrlInfo = NULL;
static id UNMHooked_SongPlayUrlInfo(id self_, SEL _cmd) {
    id original = UNMOriginalObject(self_, _cmd);

    NSString *songId = UNMSongIdOfObject(self_);
    UNMNoteAskedSongID(songId);
    if (songId.length) {
        UNMLastEnsure();
        [gLastLock lock];
        gLastPlayUrlInfoReads++;
        if (original == nil) gLastPlayUrlInfoNil++;
        [gLastLock unlock];
    }

    if (original) return original;
    if (!UNMModelHookEnabled()) return nil;

    long long value = songId.longLongValue;
    if (value == 0) return nil;

    // Warm only. This getter can run during layout, so it must not wait.
    if ([[UNMStore shared] cachedURLForID:value].length == 0) {
        UNMPrioritizePrefetch(songId);
        return nil;
    }

    UNMCountHook(UNMHookCtrUrlInfoSynthesized);
    @try {
        return [UNMModelHook synthesizedUrlInfoForClassNamed:@"NMSongCacheUrlInfo" song:self_];
    } @catch (NSException *exception) {
        UNMCountException();
        UNMLogW(@"[model] 合成地址对象失败：%@", exception.reason);
        return nil;
    }
}


static IMP gOrig_SongSetPlayUrlInfo = NULL;
static void UNMHooked_SongSetPlayUrlInfo(id self_, SEL _cmd, id info) {
    NSString *songId = UNMSongIdOfObject(self_);
    if (songId.length) {
        NSString *name = nil;
        @try { name = [self_ valueForKey:@"name"]; } @catch (__unused NSException *e) { }
        [UNMFavorite rememberSongId:[songId longLongValue] name:name];
        UNMLogI(@"[fav] 当前歌曲：%@《%@》", songId, name ?: @"?");
    }
    if (gOrig_SongSetPlayUrlInfo) {
        ((void (*)(id, SEL, id))gOrig_SongSetPlayUrlInfo)(self_, _cmd, info);
    }
}

// MARK: - NMSongUrlInfo

static IMP gOrig_UrlGet = NULL;
static NSString *UNMHooked_UrlGet(id self_, SEL _cmd) {
    UNMCountHook(UNMHookCtrUrlGet);

    NSString *original = UNMOriginalObject(self_, _cmd);
    NSString *songId = UNMSongIdOfObject(self_);
    UNMNoteAskedSongID(songId);
    if (songId.length) UNMLastBegin(songId);

    if (!UNMModelHookEnabled()) return original;
    // Never touch a URL that already works: only the grey case is substituted.
    if (original.length) return original;
    UNMCountHook(UNMHookCtrUrlEmpty);

    // Let the client ask the server first.
    //
    // Answering the very first read made the client skip /song/enhance/player/url entirely:
    // no request, no response, and its play-log payload stayed {} -- which is why the
    // listening ranking never counted a substituted song. Returning nil here sends it to the
    // server, where the response rewriter supplies the substitute URL instead.
    if ([UNMConfig shared].responseFirst && songId.length) {
        NSInteger asks = UNMNoteAsk(songId);
        if (asks <= 2) {
            UNMLogI(@"[resp] 先让客户端自己请求 %@（第 %ld 次读空）", songId, (long)asks);
            return original;
        }
    }
    if (songId.length) {
        UNMLastEnsure();
        [gLastLock lock];
        gLastUrlEmpty++;
        [gLastLock unlock];
    }

    NSString *substitute = [UNMModelHook substituteURLForUrlInfo:self_];
    if (substitute.length) {
        UNMCountHook(UNMHookCtrUrlDelivered);
        [[UNMStats shared] bumpRewrite:@"model-url"];
        if (songId.length) {
            UNMLastEnsure();
            [gLastLock lock];
            gLastDelivered++;
            gLastDeliveredURL = [substitute copy];
            [gLastLock unlock];
        }
        return substitute;
    }
    return original;
}

/// Generic counterpart for the sibling classes: NMSongCacheUrlInfo and NMSongFile
/// hold a URL too, and the player may well read it from there instead.
static NSString *UNMHooked_GenericURLGet(id self_, SEL _cmd) {
    UNMCountHook(UNMHookCtrGenericUrlGet);

    NSString *original = UNMOriginalObject(self_, _cmd);
    if (!UNMModelHookEnabled()) return original;
    if (original.length) return original;

    NSString *substitute = [UNMModelHook substituteURLForUrlInfo:self_];
    if (substitute.length) {
        UNMCountHook(UNMHookCtrUrlDelivered);
        [[UNMStats shared] bumpRewrite:@"model-url-generic"];
        UNMLogI(@"[model] 通过 -%@ 投放替代直链", NSStringFromSelector(_cmd));
        return substitute;
    }
    return original;
}

/// Derived from the URL in hand, so the client's decoder never disagrees with the
/// container we actually handed it.
static IMP gOrig_UrlType = NULL;
static NSString *UNMHooked_UrlType(id self_, SEL _cmd) {
    NSString *original = UNMOriginalObject(self_, _cmd);
    if (!UNMModelHookEnabled()) return original;

    NSString *url = [[self_ valueForKey:@"url"] lowercaseString];
    if (!url.length) return original;
    if ([url containsString:@".flac"]) return @"flac";
    if ([url containsString:@".m4a"] || [url containsString:@".aac"]) return @"aac";
    if ([url containsString:@".wav"]) return @"wav";
    if ([url containsString:@".mp3"] || [url containsString:@"mp3"]) return @"mp3";
    return original;
}

static IMP gOrig_UrlFee = NULL;
static long long UNMHooked_UrlFee(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 0 : UNMOriginalLL(self_, _cmd);
}

static IMP gOrig_UrlPayed = NULL;
static long long UNMHooked_UrlPayed(id self_, SEL _cmd) {
    return UNMModelHookEnabled() ? 1 : UNMOriginalLL(self_, _cmd);
}

/// The container the URL in hand actually points at.
///
/// Needed because forcing playMaxbr high makes the client believe it is holding a
/// lossless slot, while the source usually hands back an mp3. If the decoder is
/// chosen from isFlac/isMP3 rather than from the URL, that mismatch produces a
/// song that has a URL and still makes no sound.
static NSString *UNMFormatFromURLInfo(id urlInfo) {
    id raw = [urlInfo valueForKey:@"url"];
    NSString *url = [raw isKindOfClass:NSString.class] ? [raw lowercaseString] : nil;
    if (url.length == 0) return nil;

    if ([url containsString:@".flac"]) return @"flac";
    if ([url containsString:@".wav"]) return @"wav";
    if ([url containsString:@".ape"]) return @"ape";
    if ([url containsString:@".m4a"] || [url containsString:@".aac"]) return @"aac";
    return @"mp3";   // KuWo hands out mp3 unless asked otherwise
}

#define UNM_FORMAT_PREDICATE(base, expected)                            \
    static IMP gOrig_##base = NULL;                                     \
    static BOOL UNMHooked_##base(id self_, SEL _cmd) {                  \
        if (!UNMModelHookEnabled()) return UNMOriginalBool(self_, _cmd);\
        NSString *format = UNMFormatFromURLInfo(self_);                 \
        if (format.length == 0) return UNMOriginalBool(self_, _cmd);    \
        return [format isEqualToString:(expected)];                     \
    }

UNM_FORMAT_PREDICATE(UrlIsFlac, @"flac")
UNM_FORMAT_PREDICATE(UrlIsMP3, @"mp3")
UNM_FORMAT_PREDICATE(UrlIsAAC, @"aac")
UNM_FORMAT_PREDICATE(UrlIsAPE, @"ape")
UNM_FORMAT_PREDICATE(UrlIsWAV, @"wav")

static IMP gOrig_UrlIsLossLess = NULL;
static BOOL UNMHooked_UrlIsLossLess(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalBool(self_, _cmd);
    NSString *format = UNMFormatFromURLInfo(self_);
    if (format.length == 0) return UNMOriginalBool(self_, _cmd);
    return [format isEqualToString:@"flac"] || [format isEqualToString:@"wav"] ||
           [format isEqualToString:@"ape"];
}

/// Bitrate follows the container too, for the same reason.
static IMP gOrig_UrlBitrate = NULL;
static long long UNMHooked_UrlBitrate(id self_, SEL _cmd) {
    long long original = UNMOriginalLL(self_, _cmd);
    if (!UNMModelHookEnabled()) return original;
    NSString *format = UNMFormatFromURLInfo(self_);
    if (format.length == 0) return original;
    return [format isEqualToString:@"flac"] ? 999000 : 320000;
}

/// Extended so a substituted URL is not considered stale and re-fetched (which
/// would replace it with the one the server refuses to give).
static IMP gOrig_UrlExpire = NULL;
static id UNMHooked_UrlExpire(id self_, SEL _cmd) {
    if (!UNMModelHookEnabled()) return UNMOriginalObject(self_, _cmd);
    return [NSDate dateWithTimeIntervalSinceNow:86400];
}

UNM_BOOL_PREDICATE(UrlIsFreeTrialURL, NO)
UNM_BOOL_PREDICATE(UrlIsFreeTrialSong, NO)
UNM_BOOL_PREDICATE(UrlCanUserFreeTrial, NO)

// MARK: - Installer

@implementation UNMModelHook {
    // One synthesis per song, so repeated getters return the same object.
    NSMutableDictionary<NSString *, id> *_privileges;
    NSMutableDictionary<NSString *, id> *_urlInfos;
    NSLock *_lock;
}

+ (instancetype)shared {
    static UNMModelHook *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[UNMModelHook alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _privileges = [NSMutableDictionary dictionary];
        _urlInfos = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

static BOOL UNMHookModel(NSString *clsName, NSString *selName, IMP newIMP,
                         IMP *oldIMP, NSMutableArray<NSString *> *report) {
    Class cls = UNMFindClass(clsName);
    if (cls == Nil) {
        if (report) [report addObject:[NSString stringWithFormat:@"%@ —— 类未加载", clsName]];
        return NO;
    }
    BOOL ok = UNMHookInst(cls, NSSelectorFromString(selName), newIMP, oldIMP);
    if (report) {
        [report addObject:[NSString stringWithFormat:@"%@ -%@ %@", clsName, selName,
                           ok ? @"ok" : @"skipped(方法不存在)"]];
    }
    return ok;
}

/// Hooks every zero-argument, object-returning getter whose name mentions "url"
/// on the given class.
///
/// Scan the runtime for classes that plausibly carry a play URL, and hook them too.
///
/// The three names above are from the iPhone client. The iPad HD build is a
/// separate app with its own model layer: un-greying works there (the privilege
/// class kept its name) but playback fails, which means the player reads the URL
/// from an object this tweak never touched. Instead of chasing names, look for
/// classes whose name suggests a URL holder and hook every object getter that
/// mentions "url" -- the same conservative rule used above, applied broadly.
/// Catch the toast that refuses the action, and print who decided it.


+ (void)installDiscoveredURLGetters:(NSMutableArray<NSString *> *)report {
    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)capacity);
    if (classes == NULL) return;
    capacity = objc_getClassList(classes, capacity);

    NSArray<NSString *> *patterns = @[ @"UrlInfo", @"SongUrl", @"PlayUrl",
                                      @"PlayInfo", @"MediaSource", @"SourceInfo" ];
    NSArray<NSString *> *already = @[ @"NMSongUrlInfo", @"NMSongCacheUrlInfo", @"NMSongFile" ];
    NSMutableArray<NSString *> *hooked = [NSMutableArray array];

    for (int i = 0; i < capacity; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (name.length == 0 || name.length > 40) continue;
        if (![name hasPrefix:@"NM"]) continue;          // NetEase's own classes only
        if ([already containsObject:name]) continue;

        BOOL matches = NO;
        for (NSString *pattern in patterns) {
            if ([name rangeOfString:pattern].location != NSNotFound) { matches = YES; break; }
        }
        if (!matches) continue;

        NSMutableArray<NSString *> *probe = [NSMutableArray array];
        [self installGenericURLGettersOnClassName:name report:probe];
        NSString *line = probe.firstObject;
        if (line.length && [line rangeOfString:@"(没有可接管的)"].location == NSNotFound) {
            [hooked addObject:name];
        }
    }
    free(classes);

    [report addObject:hooked.count
        ? [NSString stringWithFormat:@"额外接管 %lu 个地址类: %@", (unsigned long)hooked.count,
                                     [hooked componentsJoinedByString:@", "]]
        : @"未发现额外的地址类"];
}

/// The player may read the URL from NMSongCacheUrlInfo or NMSongFile rather than
/// from NMSongUrlInfo, and their exact member lists are not known ahead of time.
/// Restricting to zero-arg getters that return an object keeps this to real
/// accessors -- the `urlSource`/`urlInfoSource` integer fields are excluded by the
/// return type.
+ (void)installGenericURLGettersOnClassName:(NSString *)className
                                    report:(NSMutableArray<NSString *> *)report {
    Class cls = UNMFindClass(className);
    if (cls == Nil) {
        [report addObject:[NSString stringWithFormat:@"%@ —— 类未加载", className]];
        return;
    }

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods == NULL) return;

    NSMutableArray<NSString *> *hookedNames = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (sel == NULL) continue;
        NSString *name = NSStringFromSelector(sel);
        if ([name containsString:@":"]) continue;      // zero-arg getters only
        if ([name hasPrefix:@"set"]) continue;
        if ([name.lowercaseString rangeOfString:@"url"].location == NSNotFound) continue;

        char returnType[16] = {0};
        method_getReturnType(methods[i], returnType, sizeof(returnType));
        if (returnType[0] != '@') continue;            // objects only

        IMP previous = NULL;
        if (UNMHookInst(cls, sel, (IMP)UNMHooked_GenericURLGet, &previous)) {
            [hookedNames addObject:name];
        }
    }
    free(methods);

    [report addObject:[NSString stringWithFormat:@"%@ 的 URL 取值器: %@", className,
                       hookedNames.count
                           ? [hookedNames componentsJoinedByString:@", "]
                           : @"(没有可接管的)"]];
}

+ (void)install {
    // Not dispatch_once: the app's model classes may not all be registered yet
    // when the constructor runs, and a later retry is free because hooking the
    // same (class, selector) twice is a no-op.
    static BOOL installedAll = NO;
    if (installedAll) return;

    NSMutableArray<NSString *> *report = [NSMutableArray array];

        // ---- NMSongPrivilege
        UNMHookModel(@"NMSongPrivilege", @"status", (IMP)UNMHooked_PrivStatus, &gOrig_PrivStatus, report);
        UNMHookModel(@"NMSongPrivilege", @"fee", (IMP)UNMHooked_PrivFee, &gOrig_PrivFee, report);
        UNMHookModel(@"NMSongPrivilege", @"payed", (IMP)UNMHooked_PrivPayed, &gOrig_PrivPayed, report);
        UNMHookModel(@"NMSongPrivilege", @"flag", (IMP)UNMHooked_PrivFlag, &gOrig_PrivFlag, report);
        UNMHookModel(@"NMSongPrivilege", @"playMaxbr", (IMP)UNMHooked_PrivPlayMaxbr, &gOrig_PrivPlayMaxbr, report);
        UNMHookModel(@"NMSongPrivilege", @"downloadMaxbr", (IMP)UNMHooked_PrivDownloadMaxbr, &gOrig_PrivDownloadMaxbr, report);
        UNMHookModel(@"NMSongPrivilege", @"maxBitrate", (IMP)UNMHooked_PrivMaxBitrate, &gOrig_PrivMaxBitrate, report);
        UNMHookModel(@"NMSongPrivilege", @"isVipSong", (IMP)UNMHooked_Priv_isVipSong, &gOrig_Priv_isVipSong, report);
        UNMHookModel(@"NMSongPrivilege", @"isLimitFree", (IMP)UNMHooked_Priv_isLimitFree, &gOrig_Priv_isLimitFree, report);
        UNMHookModel(@"NMSongPrivilege", @"isExclusiveSong", (IMP)UNMHooked_Priv_isExclusiveSong, &gOrig_Priv_isExclusiveSong, report);
        UNMHookModel(@"NMSongPrivilege", @"isPlayOnlySong", (IMP)UNMHooked_Priv_isPlayOnlySong, &gOrig_Priv_isPlayOnlySong, report);
        UNMHookModel(@"NMSongPrivilege", @"isFakePrivilege", (IMP)UNMHooked_Priv_isFakePrivilege, &gOrig_Priv_isFakePrivilege, report);
        UNMHookModel(@"NMSongPrivilege", @"isNoOrNearlyNoCopyrightSong", (IMP)UNMHooked_PrivIsNoCopyright, &gOrig_PrivIsNoCopyright, report);
        UNMHookModel(@"NMSongPrivilege", @"sharePrivilege", (IMP)UNMHooked_PrivSharePrivilege, &gOrig_PrivSharePrivilege, report);
        UNMHookModel(@"NMSongPrivilege", @"canShare", (IMP)UNMHooked_Priv_canShare, &gOrig_Priv_canShare, report);

        // ---- Why the client refuses to favourite a grey song
        UNMHookModel(@"NMSongPrivilege", @"customCopyRightIssueText", (IMP)UNMHooked_PrivCopyRightText, &gOrig_PrivCopyRightText, report);
        UNMHookModel(@"NMSongPrivilege", @"nmdisc_hasCopyRight", (IMP)UNMHooked_PrivHasCopyRight, &gOrig_PrivHasCopyRight, report);
        UNMHookModel(@"NMSongPrivilege", @"hasFreeTrialSongAndNoCopyright", (IMP)UNMHooked_PrivHasFreeTrialNoCopyright, &gOrig_PrivHasFreeTrialNoCopyright, report);
        UNMHookModel(@"NMSong", @"copyrightText", (IMP)UNMHooked_SongCopyrightText, &gOrig_SongCopyrightText, report);
        UNMHookModel(@"NMSong", @"hasFreeTrialSongAndNoCopyright", (IMP)UNMHooked_SongHasFreeTrialNoCopyright, &gOrig_SongHasFreeTrialNoCopyright, report);

        // ---- NMSong
        UNMHookModel(@"NMSong", @"canPlayMusic", (IMP)UNMHooked_SongCanPlayMusic, &gOrig_SongCanPlayMusic, report);
        UNMHookModel(@"NMSong", @"canPlayOnline", (IMP)UNMHooked_SongCanPlayOnline, &gOrig_SongCanPlayOnline, report);
        UNMHookModel(@"NMSong", @"canEnableMusic", (IMP)UNMHooked_SongCanEnableMusic, &gOrig_SongCanEnableMusic, report);
        UNMHookModel(@"NMSong", @"canShareMusic", (IMP)UNMHooked_SongCanShareMusic, &gOrig_SongCanShareMusic, report);
        UNMHookModel(@"NMSong", @"isUnavailableMusic", (IMP)UNMHooked_SongIsUnavailable, &gOrig_SongIsUnavailable, report);
        UNMHookModel(@"NMSong", @"isPlayOnlySong", (IMP)UNMHooked_SongIsPlayOnly, &gOrig_SongIsPlayOnly, report);
        UNMHookModel(@"NMSong", @"isFeeSong", (IMP)UNMHooked_SongIsFeeSong, &gOrig_SongIsFeeSong, report);
        UNMHookModel(@"NMSong", @"hasFeeIssue", (IMP)UNMHooked_SongHasFeeIssue, &gOrig_SongHasFeeIssue, report);
        UNMHookModel(@"NMSong", @"privilege", (IMP)UNMHooked_SongPrivilege, &gOrig_SongPrivilege, report);
        UNMHookModel(@"NMSong", @"playUrlInfo", (IMP)UNMHooked_SongPlayUrlInfo, &gOrig_SongPlayUrlInfo, report);
        UNMHookModel(@"NMSong", @"songFile", (IMP)UNMHooked_SongSongFile, &gOrig_SongSongFile, report);
        UNMHookModel(@"NMSong", @"setPlayUrlInfo:", (IMP)UNMHooked_SongSetPlayUrlInfo,
                     &gOrig_SongSetPlayUrlInfo, report);

        // ---- NMSongUrlInfo: the delivery point for a substitute URL
        UNMHookModel(@"NMSongUrlInfo", @"url", (IMP)UNMHooked_UrlGet, &gOrig_UrlGet, report);
        UNMHookModel(@"NMSongUrlInfo", @"type", (IMP)UNMHooked_UrlType, &gOrig_UrlType, report);
        UNMHookModel(@"NMSongUrlInfo", @"fee", (IMP)UNMHooked_UrlFee, &gOrig_UrlFee, report);
        UNMHookModel(@"NMSongUrlInfo", @"payed", (IMP)UNMHooked_UrlPayed, &gOrig_UrlPayed, report);
        UNMHookModel(@"NMSongUrlInfo", @"expireTime", (IMP)UNMHooked_UrlExpire, &gOrig_UrlExpire, report);
        UNMHookModel(@"NMSongUrlInfo", @"isFreeTrialURL", (IMP)UNMHooked_UrlIsFreeTrialURL, &gOrig_UrlIsFreeTrialURL, report);
        UNMHookModel(@"NMSongUrlInfo", @"isFreeTrialSong", (IMP)UNMHooked_UrlIsFreeTrialSong, &gOrig_UrlIsFreeTrialSong, report);
        UNMHookModel(@"NMSongUrlInfo", @"canUserFreeTrial", (IMP)UNMHooked_UrlCanUserFreeTrial, &gOrig_UrlCanUserFreeTrial, report);

        // The container flags must agree with the URL we delivered, or the player
        // picks a decoder for a format it is not getting.
        UNMHookModel(@"NMSongUrlInfo", @"isFlac", (IMP)UNMHooked_UrlIsFlac, &gOrig_UrlIsFlac, report);
        UNMHookModel(@"NMSongUrlInfo", @"isMP3", (IMP)UNMHooked_UrlIsMP3, &gOrig_UrlIsMP3, report);
        UNMHookModel(@"NMSongUrlInfo", @"isAAC", (IMP)UNMHooked_UrlIsAAC, &gOrig_UrlIsAAC, report);
        UNMHookModel(@"NMSongUrlInfo", @"isAPE", (IMP)UNMHooked_UrlIsAPE, &gOrig_UrlIsAPE, report);
        UNMHookModel(@"NMSongUrlInfo", @"isWAV", (IMP)UNMHooked_UrlIsWAV, &gOrig_UrlIsWAV, report);
        UNMHookModel(@"NMSongUrlInfo", @"isLossLess", (IMP)UNMHooked_UrlIsLossLess, &gOrig_UrlIsLossLess, report);
        UNMHookModel(@"NMSongUrlInfo", @"bitrate", (IMP)UNMHooked_UrlBitrate, &gOrig_UrlBitrate, report);

        // Sibling classes that also carry a URL. The explicit hook above wins for
        // NMSongUrlInfo.url, since a (class, selector) pair is only ever hooked once.
        [self installGenericURLGettersOnClassName:@"NMSongUrlInfo" report:report];
        [self installGenericURLGettersOnClassName:@"NMSongCacheUrlInfo" report:report];
        [self installGenericURLGettersOnClassName:@"NMSongFile" report:report];
        [self installDiscoveredURLGetters:report];

        // Favouriting a grey song is refused by the client itself: it shows
        // "版权方要求该资源无法操作" and never sends the request, so nothing about the
        // play URL is involved. Whatever field carries that verdict is on the song or
        // its privilege, and this client version names it something we have not hooked.
        //
        // Rather than guess again, force every boolean on those classes whose name
        // says it is about copyright, favouriting, collecting or being unavailable,
        // and dump the selector list so the exact one can be identified if this is
        // still not enough.
        [self forceLicensingFlagsOnClassName:@"NMSong" report:report];
        [self forceLicensingFlagsOnClassName:@"NMSongPrivilege" report:report];
        // Only in discovery mode: walking the class list at launch forces classes to realise,
        // and a class whose +initialize has side effects takes the process down with it.


        UNMLogI(@"[model] 模型层 hook 安装完成");
        for (NSString *line in report) UNMLogI(@"[model]   %@", line);

        NSUInteger ok = 0;
        for (NSString *line in report) if ([line hasSuffix:@"ok"]) ok++;
        [[UNMStats shared] addEvent:[NSString stringWithFormat:@"模型层 hook 安装：%lu/%lu 成功",
                                     (unsigned long)ok, (unsigned long)report.count]];

        installedAll = (UNMFindClass(@"NMSong") != Nil) && (UNMFindClass(@"NMSongPrivilege") != Nil);
        if (!installedAll) {
            UNMLogW(@"[model] NMSong/NMSongPrivilege 还没注册，稍后重试");
        }
}

/// Force the "may this be liked / is it licensed" booleans on a model class.
///
/// The client refuses to favourite a grey song and says "版权方要求该资源无法操作"
/// without ever calling the API, so the gate is a field on the model. This version's
/// name for it is unknown, so every zero-argument BOOL whose selector mentions
/// copyright, favouriting, collecting, restriction or unavailability is forced to the
/// permissive answer, and the full selector list is dumped so the one that matters can
/// be pinned down if this is still not enough.
+ (void)forceLicensingFlagsOnClassName:(NSString *)className report:(NSMutableArray *)report {
    Class cls = UNMFindClass(className);
    if (cls == Nil) return;

    NSArray<NSString *> *denyWords = @[
        @"copyright", @"favorite", @"favourite", @"collect", @"restrict",
        @"unavailable", @"gray", @"grey", @"forbidden", @"ban", @"down",
    ];
    NSArray<NSString *> *allowWords = @[
        @"canplay", @"canfavor", @"canfavour", @"cancollect", @"canshare",
        @"isavailable", @"isplayable",
    ];

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    NSInteger forced = 0;

    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        [names addObject:name];

        if (sel_getName(sel) == NULL) continue;
        const char *types = method_getTypeEncoding(methods[i]);
        if (types == NULL || types[0] != 'B') continue;   // BOOL return only
        // The encoding always contains ':' because every method takes _cmd, so the
        // argument count has to come from the runtime, not from scanning the string.
        if (method_getNumberOfArguments(methods[i]) != 2) continue;

        NSString *lower = name.lowercaseString;
        BOOL deny = NO;
        for (NSString *word in denyWords) {
            if ([lower containsString:word]) { deny = YES; break; }
        }
        if (!deny) continue;

        BOOL allow = NO;
        for (NSString *word in allowWords) {
            if ([lower containsString:word]) { allow = YES; break; }
        }
        // "isUnavailable" style names must answer NO; "canCollect" style must answer YES.
        BOOL value = allow;
        if ([lower hasPrefix:@"isunavailable"] || [lower containsString:@"nocopyright"] ||
            [lower containsString:@"notcopyright"]) {
            value = NO;
        }

        IMP imp = imp_implementationWithBlock(^BOOL(id self_) {
            (void)self_;
            return value;
        });
        if (class_addMethod(cls, sel, imp, types)) {
            forced++;
        } else {
            Method existing = class_getInstanceMethod(cls, sel);
            if (existing) method_setImplementation(existing, imp);
            forced++;
        }
    }
    if (methods) free(methods);

    [report addObject:[NSString stringWithFormat:@"%@ 版权类布尔方法强制 %ld 个（共 %lu 个方法）",
                       className, (long)forced, (unsigned long)count]];
    UNMLogI(@"[model] %@ 的方法表：%@", className, [names componentsJoinedByString:@", "]);
}

+ (NSString *)statusText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray<NSArray *> *pairs = @[
        @[ @"NMSongPrivilege", @"status" ], @[ @"NMSongPrivilege", @"fee" ],
        @[ @"NMSongPrivilege", @"payed" ], @[ @"NMSongPrivilege", @"playMaxbr" ],
        @[ @"NMSong", @"canPlayMusic" ], @[ @"NMSong", @"canPlayOnline" ],
        @[ @"NMSong", @"privilege" ], @[ @"NMSong", @"playUrlInfo" ],
        @[ @"NMSongUrlInfo", @"url" ], @[ @"NMSongUrlInfo", @"type" ],
    ];
    for (NSArray *pair in pairs) {
        Class cls = UNMFindClass(pair[0]);
        if (cls == Nil) {
            [lines addObject:[NSString stringWithFormat:@"%@ —— 类未加载", pair[0]]];
            continue;
        }
        BOOL hooked = UNMHookIsInstalled(cls, NSSelectorFromString(pair[1]), NO);
        [lines addObject:[NSString stringWithFormat:@"%@ -%@  %@", pair[0], pair[1],
                          hooked ? @"已接管" : @"未接管"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// MARK: - Synthesis

+ (id)synthesizedPrivilegeForSong:(id)song {
    NSString *songId = UNMSongIdOfObject(song);
    if (songId.length == 0) return nil;

    UNMModelHook *shared = [self shared];
    [shared->_lock lock];
    id cached = shared->_privileges[songId];
    [shared->_lock unlock];
    if (cached) return cached;

    Class cls = UNMFindClass(@"NMSongPrivilege");
    if (cls == Nil) return nil;
    id privilege = [[cls alloc] init];
    if (!privilege) return nil;
    // Every field the model claims to have is forced at the getter level anyway;
    // the identity needs setting here, and the numeric fields are written directly
    // as well.
    //
    // The getters only cover code that asks the object for a value. The play-record
    // and favourite paths serialise the privilege instead, so a synthesised object
    // whose ivars are still zero looks like an unplayable song to them: the heart
    // stays disabled and the play is never reported to the listening ranking. Writing
    // the same values into the ivars makes the object coherent from both directions.
    if ([privilege respondsToSelector:NSSelectorFromString(@"setSongId:")]) {
        [privilege setValue:songId forKey:@"songId"];
    }
    UNMSetIvar(privilege, @"_songId", songId);

    long long maxBitrate = 320000;
    UNMSetIvarLongLong(privilege, @"_status", 200);          // st: 0 is "normal", 200 is this model's normal
    UNMSetIvarLongLong(privilege, @"_st", 0);
    UNMSetIvarLongLong(privilege, @"_fee", 0);
    UNMSetIvarLongLong(privilege, @"_payed", 1);
    UNMSetIvarLongLong(privilege, @"_flag", 0);
    UNMSetIvarLongLong(privilege, @"_playMaxbr", maxBitrate);
    UNMSetIvarLongLong(privilege, @"_downloadMaxbr", maxBitrate);
    UNMSetIvarLongLong(privilege, @"_maxBitrate", maxBitrate);
    UNMSetIvarLongLong(privilege, @"_pl", maxBitrate);
    UNMSetIvarLongLong(privilege, @"_dl", maxBitrate);
    UNMSetIvarLongLong(privilege, @"_fl", maxBitrate);
    UNMSetIvarLongLong(privilege, @"_cp", 1);
    UNMSetIvarLongLong(privilege, @"_subp", 1);

    [shared->_lock lock];
    if (!shared->_privileges) shared->_privileges = [NSMutableDictionary dictionary];
    if (shared->_privileges.count > 500) [shared->_privileges removeAllObjects];
    shared->_privileges[songId] = privilege;
    [shared->_lock unlock];

    UNMLogD(@"[model] 为 %@ 合成了一个 privilege 对象", songId);
    return privilege;
}

+ (id)synthesizedUrlInfoForClassNamed:(NSString *)className song:(id)song {
    NSString *songId = UNMSongIdOfObject(song);
    if (songId.length == 0) return nil;

    UNMModelHook *shared = [self shared];
    [shared->_lock lock];
    id cached = shared->_urlInfos[songId];
    [shared->_lock unlock];
    if (cached) return cached;

    Class cls = UNMFindClass(className);
    if (cls == Nil) return nil;
    id info = [[cls alloc] init];
    if (!info) return nil;

    // The class may have no songId at all (NMSongFile, for one), so the identity
    // is attached as well -- that is what substituteURLForUrlInfo: reads.
    SEL setter = NSSelectorFromString(@"setSongId:");
    if (UNMLookupMethod(cls, setter, NO, NULL) != NULL) {
        [info setValue:songId forKey:@"songId"];
    }
    objc_setAssociatedObject(info, UNMSongIdAssociation, songId,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Same reasoning as the privilege: the getters are hooked, the ivars are not, and
    // the code that reports a play reads the ivars.
    UNMSetIvar(info, @"_songId", songId);
    UNMSetIvarLongLong(info, @"_fee", 0);
    UNMSetIvarLongLong(info, @"_payed", 1);
    UNMSetIvarLongLong(info, @"_br", 320000);
    UNMSetIvarLongLong(info, @"_bitrate", 320000);
    UNMSetIvarLongLong(info, @"_size", 0);
    UNMSetIvar(info, @"_type", @"mp3");
    UNMSetIvar(info, @"_level", @"exhigh");
    UNMSetIvar(info, @"_encodeType", @"mp3");
    UNMSetIvar(info, @"_md5", @"");

    [shared->_lock lock];
    shared->_urlInfos[songId] = info;
    [shared->_lock unlock];

    UNMLogD(@"[model] 为 %@ 合成了一个 %@", songId, className);
    return info;
}

+ (NSString *)countersText {
    return [NSString stringWithFormat:
            @"生效音源顺序：%@\n"
            @"NMSongPrivilege.status 被调用：   %d\n"
            @"NMSongPrivilege.fee 被调用：      %d\n"
            @"NMSong.privilege 合成次数：       %d\n"
            @"NMSong.playUrlInfo 合成次数：     %d\n"
            @"NMSongUrlInfo.url 读取次数：      %d（其中原本为空 %d）\n"
            @"其他模型类的 URL 取值器：         %d\n"
            @"主线程读取（拒绝阻塞，已排队）：   %d\n"
            @"成功投放替代直链：                %d\n"
            @"替换过程抛出异常（已吞掉）：      %lu 次\n",
            [[UNMConfig shared].providerOrder componentsJoinedByString:@","],
            UNMCountRead(UNMHookCtrPrivStatus),
            UNMCountRead(UNMHookCtrPrivFee),
            UNMCountRead(UNMHookCtrPrivSynthesized),
            UNMCountRead(UNMHookCtrUrlInfoSynthesized),
            UNMCountRead(UNMHookCtrUrlGet),
            UNMCountRead(UNMHookCtrUrlEmpty),
            UNMCountRead(UNMHookCtrGenericUrlGet),
            UNMCountRead(UNMHookCtrMainThreadSkip),
            UNMCountRead(UNMHookCtrUrlDelivered),
            (unsigned long)UNMExceptionCount()];
}

// MARK: - Substitute URL

+ (NSString *)substituteURLForUrlInfo:(id)urlInfo {
    // Never let an exception escape into UIKit.
    //
    // These hooks sit between the client and its own model objects. An exception
    // raised here -- a missing KVC key on a class this tweak does not know, say --
    // propagates into whatever the client was doing, and a view controller that
    // throws while building its list gets dismissed. That is what a page vanishing
    // a second after opening looks like. Swallowing it costs one substitution;
    // letting it through costs the screen.
    @try {
        return [self unsafeSubstituteURLForUrlInfo:urlInfo];
    } @catch (NSException *exception) {
        UNMCountException();
        UNMLogW(@"[model] 替换过程抛出异常：%@ — %@", exception.name, exception.reason);
        return nil;
    }
}

+ (NSString *)unsafeSubstituteURLForUrlInfo:(id)urlInfo {
    NSString *songId = UNMSongIdOfObject(urlInfo);

    // Not every client's URL holder carries a song id.
    //
    // On the iPad HD build the privilege class kept its name (so un-greying works)
    // but the object the player asks for a URL either is not NMSongUrlInfo or does
    // not expose the id -- and with no id there is nothing to look up, so every
    // attempt fails. The player always reads the song model first, so fall back to
    // the song it just asked about, within a short window.
    if (songId.length == 0 || songId.longLongValue == 0) {
        long long recent = UNMRecentAskedSongID();
        if (recent != 0) {
            songId = [NSString stringWithFormat:@"%lld", recent];
            UNMLogD(@"[model] %@ 无 songId，改用最近询问的 %lld",
                    NSStringFromClass([urlInfo class]), recent);
        }
    }
    if (songId.length == 0) return nil;

    long long value = songId.longLongValue;
    if (value == 0) return nil;

    // Only replace what is actually unplayable.
    //
    // The URL this object holds is empty for *every* song the first time it is
    // read, including songs NetEase can serve itself and songs sitting in the
    // user's cloud drive. Substituting at that moment hijacked both: licensed
    // tracks came back as a substitute (often a different artist's version) and
    // cloud-drive uploads were replaced by a streaming copy. So if the client
    // itself reported the song as playable, leave it alone and let it fetch.
    if ([UNMConfig shared].onlyReplaceGrey) {
        NSNumber *playable = UNMOriginalPlayableForID(songId);
        if (playable != nil && playable.boolValue) {
            UNMLogD(@"[model] %lld 客户端自认可播，不替换", value);
            return nil;
        }
    }

    // Songs the sources genuinely do not have. Remembered for the session so a
    // song with no match never costs a second lookup on every single read.
    static NSMutableDictionary<NSString *, NSNumber *> *failed = nil;
    static NSLock *failedLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        failed = [NSMutableDictionary dictionary];
        failedLock = [[NSLock alloc] init];
    });
    // The negative cache expires: a lookup that failed once may well succeed a minute
// later (the source may have been slow, or the metadata may have arrived since).
// Treating it as permanent is how a song stayed unplayable for the whole session.
    [failedLock lock];
    NSNumber *failedAt = failed[songId];
    BOOL knownFailure = (failedAt != nil &&
                         CFAbsoluteTimeGetCurrent() - failedAt.doubleValue < 60.0);
    [failedLock unlock];
    if (knownFailure) return nil;

    // 1. Warm cache: instant, and the usual case once the prefetch has landed.
    //
    //    This used to consult matchForID:, whose entry holds provider/mediaId/
    //    title/artist and no url at all -- so the warm path could never deliver.
    //    Every read fell through to a blocking lookup instead, which usually ran
    //    out of budget, and a song with five working source links was reported as
    //    unplayable.
    NSString *warm = [[UNMStore shared] cachedURLForID:value];
    if (warm.length) {
        // No metaForID: lookup here: it hops the store's serial queue, and this
        // runs once per row while a list lays out.
        UNMLogI(@"[model] 投放替代直链（热）%lld", value);
        [[UNMStats shared] addEvent:[NSString stringWithFormat:@"投放直链(热) %@", songId]];
        return warm;
    }

    // 2. Cold. Whether this read may wait depends on who is asking.
    //
    //    Building a list reads each song once: waiting there is what made long
    //    playlists crawl, so those reads return immediately and only queue work.
    //    Playback reads the same song repeatedly, and that repetition is the
    //    signal that a song is actually being started -- worth waiting for.
    NSInteger asks = UNMNoteAsk(songId);

    // A read that arrives after a quiet moment is a person pressing play.
    //
    // While a list lays out, these reads come in bursts -- many within a hundred
    // milliseconds -- so waiting there is what froze the UI. A read that arrives
    // after the UI has been idle is a tap, and waiting a moment there is exactly
    // what turns "tap three times" into "tap once". The gap is the signal; the ask
    // count alone cannot tell them apart because a tap is only the first read.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    static CFAbsoluteTime lastRead = 0;
    static NSLock *readLock = nil;
    static dispatch_once_t readOnce;
    dispatch_once(&readOnce, ^{ readLock = [[NSLock alloc] init]; });

    [readLock lock];
    BOOL afterIdle = (now - lastRead) > 0.25;
    lastRead = now;
    [readLock unlock];

    if ([NSThread isMainThread]) {
        if (!afterIdle) {
            UNMCountHook(UNMHookCtrMainThreadSkip);
            UNMPrioritizePrefetch(songId);
            return nil;
        }
        if (!UNMAcquireBlockSlot()) {
            UNMPrioritizePrefetch(songId);
            return nil;
        }

        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSString *resolved = [[UNMStore shared] resolveID:value
                                                 deadline:start + 0.9];
        UNMReleaseBlockSlot();

        if (resolved.length) {
            UNMCountHook(UNMHookCtrUrlDelivered);
            [[UNMStats shared] bumpRewrite:@"model-url-tap"];
            UNMLogI(@"[model] 点击时等待 %.0fms 后投放 %lld",
                    (CFAbsoluteTimeGetCurrent() - start) * 1000.0, value);
            [[UNMStats shared] addEvent:[NSString stringWithFormat:@"点击投放 %@", songId]];
            return resolved;
        }
        UNMPrioritizePrefetch(songId);
        return nil;
    }

    // Off the main thread: only worth a lookup once the client has shown it really
    // wants this song. A tap is a single main-thread read, handled above.
    if (asks <= 1) {
        UNMQueuePrefetch(songId);
        return nil;
    }

    if (!UNMAcquireBlockSlot()) {
        UNMPrioritizePrefetch(songId);
        return nil;
    }
    UNMConfig *cfg = [UNMConfig shared];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    double deadline = start + (double)cfg.urlWaitMS / 1000.0;
    NSString *resolved = [[UNMStore shared] resolveID:value deadline:deadline];
    double elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    UNMReleaseBlockSlot();

    if (resolved.length) {
        UNMSongMeta *meta = [[UNMStore shared] metaForID:value];
        UNMLogI(@"[model] 投放替代直链（%.0fms，第 %ld 次询问）%lld 《%@》",
                elapsed, (long)asks, value, meta.name ?: @"?");
        [[UNMStats shared] addEvent:[NSString stringWithFormat:@"投放直链(%.0fms) %@",
                                     elapsed, songId]];
        return resolved;
    }

    UNMLogW(@"[model] %lld 无替代源（等了 %.0fms）", value, elapsed);
    [[UNMStats shared] addEvent:[NSString stringWithFormat:@"%@ 无源(%.0fms)", songId, elapsed]];
    [failedLock lock];
    if (failed.count > 400) [failed removeAllObjects];
    failed[songId] = @(CFAbsoluteTimeGetCurrent());
    [failedLock unlock];

    return nil;
}


+ (NSString *)lastAttemptText {
    if (gLastLock == nil || gLastSongId == nil) return @"(还没有读过任何歌曲的地址)";

    [gLastLock lock];
    NSString *songId = [gLastSongId copy];
    int reads = gLastUrlReads, empty = gLastUrlEmpty, delivered = gLastDelivered;
    NSString *deliveredURL = [gLastDeliveredURL copy];
    int pur = gLastPlayUrlInfoReads, pun = gLastPlayUrlInfoNil;
    NSArray<NSNumber *> *origPair = gOrigPriv[songId];
    double age = CFAbsoluteTimeGetCurrent() - gLastTime;
    [gLastLock unlock];

    NSMutableString *s = [NSMutableString string];
    // Name the song: the block always describes the *last* song whose URL was read,
    // which is easy to mistake for the one the user is complaining about.
    long long numericID = songId.longLongValue;
    UNMSongMeta *meta = numericID ? [[UNMStore shared] metaForID:numericID] : nil;
    if (meta.name.length) {
        [s appendFormat:@"最近一首：%@ 《%@》/%@（%.1f 秒前）\n", songId, meta.name,
         meta.album.length ? meta.album : @"?", age];
    } else {
        [s appendFormat:@"最近一首：%@（%.1f 秒前）\n", songId, age];
    }
    [s appendFormat:@"  地址读取 %d 次，其中为空 %d 次\n", reads, empty];
    [s appendFormat:@"  成功投放 %d 次", delivered];
    if (deliveredURL.length) {
        // Show the file's identifying part, not the authorisation query string.
        //
        // The tail of a MiGu URL is "&Tim=...&Key=...", which says nothing about
        // *which* recording it is. The path contains the catalogue number, and that
        // is what distinguishes the studio take from the remix.
        NSString *path = deliveredURL;
        NSRange q = [path rangeOfString:@"?"];
        if (q.location != NSNotFound) path = [path substringToIndex:q.location];

        NSString *catalogue = nil;
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"(\\d{10,})\\.(mp3|flac|m4a|wav|aac)" options:0 error:NULL];
        NSTextCheckingResult *match =
            [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
        if (match) catalogue = [path substringWithRange:[match rangeAtIndex:1]];

        NSString *lastComponent = path.lastPathComponent;
        if (lastComponent.length > 60) {
            lastComponent = [lastComponent substringFromIndex:lastComponent.length - 60];
        }
        [s appendFormat:@"\n    文件=%@", lastComponent];
        // The host is what identifies the source. Without it, a Chinese-named file
        // from MiGu's lossless tier looks exactly like a KuWo download link, and
        // that ambiguity cost two rounds of wrong conclusions.
        NSRange schemeEnd = [deliveredURL rangeOfString:@"://"];
        if (schemeEnd.location != NSNotFound) {
            NSString *afterScheme = [deliveredURL substringFromIndex:NSMaxRange(schemeEnd)];
            NSRange slash = [afterScheme rangeOfString:@"/"];
            NSString *host = slash.location == NSNotFound
                ? afterScheme : [afterScheme substringToIndex:slash.location];
            if (host.length) [s appendFormat:@"\n    主机=%@", host];
        }
        if (catalogue.length) [s appendFormat:@"\n    曲目编号=%@", catalogue];
    }
    [s appendString:@"\n"];
    [s appendFormat:@"  playUrlInfo 读取 %d 次，其中为 nil %d 次\n", pur, pun];
    if (origPair.count == 2) {
        [s appendFormat:@"  原始 privilege：status=%@  fee=%@（现在被强制成 0 / 0）\n",
            origPair[0], origPair[1]];
    } else {
        [s appendString:@"  原始 privilege：还没记录到\n"];
    }
    return s;
}

@end
