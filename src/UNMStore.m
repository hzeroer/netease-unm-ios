//
//  UNMStore.m
//

#import "UNMStore.h"
#import "UNMConfig.h"
#import "UNMHTTP.h"
#import "UNMInternal.h"
#import "UNMLog.h"
#import "UNMProvider.h"
#import "UNMStats.h"
#import "UNMUtil.h"

static const NSTimeInterval kUNMURLTTL = 90.0;   // third-party links expire fast

@interface UNMStore ()
@end

@implementation UNMStore {
    NSMutableDictionary<NSNumber *, UNMSongMeta *> *_meta;       // 1 week
    NSMutableDictionary<NSNumber *, NSDictionary *> *_match;     // provider + mediaId
    NSMutableDictionary<NSNumber *, NSDictionary *> *_urlCache;  // short TTL
    NSLock *_urlLock;   // guards _urlCache only: reads must never queue behind parsing
    NSMutableDictionary<NSNumber *, dispatch_semaphore_t> *_inflight;

    dispatch_queue_t _stateQueue;      // guards all of the above
    dispatch_queue_t _workQueue;       // runs provider lookups
    dispatch_semaphore_t _lookupLimit;
    BOOL _dirty;
    BOOL _flushScheduled;
}

+ (instancetype)shared {
    static UNMStore *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[UNMStore alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _meta = [NSMutableDictionary dictionary];
        _match = [NSMutableDictionary dictionary];
        _urlCache = [NSMutableDictionary dictionary];
    _urlLock = [[NSLock alloc] init];
        _inflight = [NSMutableDictionary dictionary];

        _stateQueue = dispatch_queue_create("com.hzeroer.unmios.store", DISPATCH_QUEUE_SERIAL);
        _workQueue = dispatch_queue_create("com.hzeroer.unmios.work", DISPATCH_QUEUE_CONCURRENT);
        _lookupLimit = dispatch_semaphore_create(MAX(1, [UNMConfig shared].prefetchConcurrency + 1));

        [self loadFromDisk];
    }
    return self;
}

#pragma mark - Persistence

- (NSString *)storePath {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    NSString *dir = [caches stringByAppendingPathComponent:@"unmios"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    return [dir stringByAppendingPathComponent:@"store.plist"];
}

- (void)loadFromDisk {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self storePath]];
    if (!d.count) return;

    NSTimeInterval ttl = MAX(1, [UNMConfig shared].cacheTTLHours) * 3600.0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    NSDictionary *meta = UNMAsDict(d[@"meta"]);
    for (NSString *key in meta) {
        NSDictionary *m = UNMAsDict(meta[key]);
        if (!m) continue;
        double ts = [m[@"ts"] doubleValue];
        if (ts > 0 && now - ts > ttl) continue;

        UNMSongMeta *sm = [UNMSongMeta new];
        sm.songID = key.longLongValue;
        sm.name = m[@"name"] ?: @"";
        sm.artists = UNMAsArray(m[@"artists"]) ?: @[];
        sm.album = m[@"album"];
        sm.duration = [m[@"duration"] doubleValue];
        _meta[@(sm.songID)] = sm;
    }

    NSDictionary *match = UNMAsDict(d[@"match"]);
    for (NSString *key in match) {
        NSDictionary *m = UNMAsDict(match[key]);
        if (!m) continue;
        double ts = [m[@"ts"] doubleValue];
        if (ts > 0 && now - ts > ttl) continue;
        _match[@(key.longLongValue)] = m;
    }

    UNMLogI(@"store loaded: %lu meta, %lu matches", (unsigned long)_meta.count, (unsigned long)_match.count);
}

- (void)scheduleFlush {
    if (_flushScheduled) return;
    _flushScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_ flush];
        self_->_flushScheduled = NO;
    });
}

- (void)flush {
    if (!_dirty) return;

    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    NSMutableDictionary *match = [NSMutableDictionary dictionary];
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    dispatch_sync(_stateQueue, ^{
        for (NSNumber *key in self->_meta) {
            UNMSongMeta *m = self->_meta[key];
            if (!m.name.length) continue;
            meta[key.stringValue] = @{
                @"name"     : m.name ?: @"",
                @"artists"  : m.artists ?: @[],
                @"album"    : m.album ?: @"",
                @"duration" : @(m.duration),
                @"ts"       : @(now),
            };
        }
        for (NSNumber *key in self->_match) {
            match[key.stringValue] = self->_match[key];
        }
    });

    NSDictionary *payload = @{ @"meta" : meta, @"match" : match, @"version" : @1 };
    BOOL ok = [payload writeToFile:[self storePath] atomically:YES];
    if (ok) _dirty = NO;
    UNMLogD(@"store flush %@ (%lu meta, %lu match)", ok ? @"ok" : @"failed",
            (unsigned long)meta.count, (unsigned long)match.count);
}

#pragma mark - Ingest

- (void)setMeta:(UNMSongMeta *)meta {
    if (!meta || meta.songID == 0 || !meta.usable) return;
    dispatch_sync(_stateQueue, ^{
        UNMSongMeta *old = self->_meta[@(meta.songID)];
        // Never downgrade a good record with a poorer one.
        if (old && old.name.length && !meta.name.length) return;
        if (old && old.artists.count && !meta.artists.count) meta.artists = old.artists;
        if (old && old.duration > 0 && meta.duration <= 0) meta.duration = old.duration;
        if (old && old.album.length && !meta.album.length) meta.album = old.album;
        self->_meta[@(meta.songID)] = meta;
    });
    _dirty = YES;
    [self scheduleFlush];
}

- (UNMSongMeta *)metaForID:(long long)songID {
    __block UNMSongMeta *m = nil;
    dispatch_sync(_stateQueue, ^{
        m = self->_meta[@(songID)];
    });
    return m;
}

static NSArray<NSString *> *UNMArtistsFromValue(id v) {
    NSMutableArray *out = [NSMutableArray array];

    if ([v isKindOfClass:NSString.class]) {
        return UNMSplitArtists((NSString *)v);
    }
    NSArray *arr = UNMAsArray(v);
    if (!arr) return out;

    for (id item in arr) {
        if ([item isKindOfClass:NSString.class]) {
            [out addObjectsFromArray:UNMSplitArtists(item)];
            continue;
        }
        NSDictionary *d = UNMAsDict(item);
        if (!d) continue;

        id rawName = UNMDictGet(d, @[@"name", @"singerName", @"nickname"]);
        if ([rawName isKindOfClass:NSDictionary.class]) {
            rawName = UNMDictGet(UNMAsDict(rawName), @[@"name"]);
        }
        if ([rawName isKindOfClass:NSString.class] && [rawName length]) {
            [out addObjectsFromArray:UNMSplitArtists(rawName)];
        }
    }
    return out;
}

/// A dict only counts as a song when it carries artist/album/duration fields.
/// This keeps playlist and album objects (which also have id + name) out of the
/// id -> metadata table.
static BOOL UNMLooksLikeSongDict(NSDictionary *d) {
    if (UNMDictGet(d, @[@"ar", @"artists", @"singer", @"singers", @"singerName"]) != nil) return YES;
    if (UNMDictGet(d, @[@"al", @"album", @"albumName"]) != nil) return YES;
    if (UNMDictGet(d, @[@"dt", @"duration", @"interval"]) != nil) return YES;
    if (UNMDictGet(d, @[@"fee", @"mst", @"privilege", @"no", @"pop"]) != nil) return YES;
    return NO;
}

- (void)ingestJSON:(id)json {
    if (!json) return;
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    [self collectSongDicts:json into:found depth:0];
    for (NSDictionary *d in found) {
        [self ingestOneSongDict:d];
    }
}

- (void)collectSongDicts:(id)node into:(NSMutableArray<NSDictionary *> *)out depth:(NSInteger)depth {
    if (depth > 8 || !node) return;

    if ([node isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = node;
        BOOL hasID = (UNMDictGet(d, @[@"id", @"songId", @"songid", @"musicId", @"resourceId"]) != nil);
        BOOL hasName = ([UNMDictGet(d, @[@"name", @"songName", @"songname", @"title"]) isKindOfClass:NSString.class]);
        if (hasID && hasName && UNMLooksLikeSongDict(d)) [out addObject:d];

        for (id v in d.allValues) {
            if ([v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class]) {
                [self collectSongDicts:v into:out depth:depth + 1];
            }
        }
        return;
    }

    if ([node isKindOfClass:NSArray.class]) {
        for (id v in (NSArray *)node) {
            if ([v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class]) {
                [self collectSongDicts:v into:out depth:depth + 1];
            }
        }
    }
}

- (void)ingestOneSongDict:(NSDictionary *)d {
    id rawID = UNMDictGet(d, @[@"id", @"songId", @"songid", @"musicId", @"resourceId"]);
    long long songID = 0;
    if ([rawID isKindOfClass:NSNumber.class]) songID = [rawID longLongValue];
    else if ([rawID isKindOfClass:NSString.class]) songID = [rawID longLongValue];
    if (songID == 0) return;

    id rawName = UNMDictGet(d, @[@"name", @"songName", @"songname", @"title"]);
    if (![rawName isKindOfClass:NSString.class]) return;
    NSString *name = UNMStripTags(rawName);
    if (name.length == 0) return;

    UNMSongMeta *meta = [UNMSongMeta new];
    meta.songID = songID;
    meta.name = name;

    id artists = UNMDictGet(d, @[@"ar", @"artists", @"singer", @"singers", @"singerName", @"artist"]);
    meta.artists = UNMArtistsFromValue(artists);

    id album = UNMDictGet(d, @[@"al", @"album"]);
    if ([album isKindOfClass:NSDictionary.class]) {
        id an = UNMDictGet(album, @[@"name", @"albumName"]);
        if ([an isKindOfClass:NSString.class]) meta.album = an;
    } else if ([album isKindOfClass:NSString.class]) {
        meta.album = album;
    } else {
        id an = UNMDictGet(d, @[@"albumName", @"albumname"]);
        if ([an isKindOfClass:NSString.class]) meta.album = an;
    }

    double dur = UNMParseDuration(UNMDictGet(d, @[@"dt", @"duration", @"interval", @"length"]));
    meta.duration = dur;

    [self setMeta:meta];
}

#pragma mark - NetEase public detail fallback

/// The client does not always send /song/detail before /player/url, so when a
/// greyed id has no metadata yet we ask NetEase's own unauthenticated detail
/// endpoint. That endpoint needs no login and no signature.
- (UNMSongMeta *)fetchMetaFromNetease:(long long)songID timeout:(NSTimeInterval)timeout {
    NSString *ids = [NSString stringWithFormat:@"[%lld]", songID];
    NSString *url = [NSString stringWithFormat:
                     @"http://music.163.com/api/song/detail/?id=%lld&ids=%@",
                     songID, UNMURLEncode(ids)];

    UNMHTTPResult *r = [UNMHTTP GET:url
                            headers:@{ @"Referer" : @"https://music.163.com/" }
                            timeout:timeout];
    NSDictionary *json = UNMAsDict(r.json);
    NSArray *songs = UNMAsArray(UNMDictGet(json, @[@"songs", @"data"]));
    if (!songs.count) {
        UNMLogW(@"meta fallback miss for %lld (%@)", songID, r.error.localizedDescription ?: @"no data");
        return nil;
    }

    NSMutableArray *found = [NSMutableArray array];
    [self collectSongDicts:songs into:found depth:0];
    if (!found.count) {
        // /song/detail sometimes nests everything one level deeper.
        [self collectSongDicts:json into:found depth:0];
    }
    for (NSDictionary *d in found) {
        id rawID = UNMDictGet(d, @[@"id", @"songId"]);
        if ([[rawID description] longLongValue] == songID) {
            [self ingestOneSongDict:d];
            return [self metaForID:songID];
        }
    }
    // Fall back to whatever the first usable record is.
    if (found.count) {
        [self ingestOneSongDict:found.firstObject];
        return [self metaForID:songID];
    }
    return nil;
}

#pragma mark - Resolve

/// Direct, lock-guarded read of the URL cache.
///
/// Deliberately does not go through _stateQueue: that serial queue also carries
/// JSON parsing and disk flushes, so a sync read there waits behind them -- and the
/// main thread reads this once per row while a list is being laid out. That is
/// what made opening a playlist take a visible moment.
- (NSDictionary *)cachedEntryForID:(long long)songID {
    [_urlLock lock];
    NSDictionary *entry = _urlCache[@(songID)];
    [_urlLock unlock];
    return entry;
}

- (NSString *)resolveID:(long long)songID deadline:(NSTimeInterval)deadline {
    if (songID == 0) return nil;

    // Serve from the short-lived URL cache first.
    NSDictionary *cachedURL = [self cachedEntryForID:songID];
    if (cachedURL && CFAbsoluteTimeGetCurrent() - [cachedURL[@"ts"] doubleValue] < kUNMURLTTL) {
        NSString *u = cachedURL[@"url"];
        if (u.length) {
            UNMLogD(@"url cache hit %lld", songID);
            return u;
        }
    }

    // De-duplicate concurrent lookups of the same song.
    __block dispatch_semaphore_t gate = nil;
    __block BOOL isOwner = NO;
    dispatch_sync(_stateQueue, ^{
        gate = self->_inflight[@(songID)];
        if (!gate) {
            gate = dispatch_semaphore_create(0);
            self->_inflight[@(songID)] = gate;
            isOwner = YES;
        }
    });

    if (!isOwner) {
        double remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining > 0) {
            dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        }
        cachedURL = [self cachedEntryForID:songID];
        if (cachedURL && CFAbsoluteTimeGetCurrent() - [cachedURL[@"ts"] doubleValue] < kUNMURLTTL) {
            return cachedURL[@"url"];
        }
        return nil;
    }

    NSString *result = nil;
    @try {
        result = [self performResolve:songID deadline:deadline];
    } @finally {
        dispatch_sync(_stateQueue, ^{
            [self->_inflight removeObjectForKey:@(songID)];
        });
        dispatch_semaphore_signal(gate);
    }

    if (result.length) {
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();
        // Only the url lock: writers must not have to hop the state queue either.
        [_urlLock lock];
        _urlCache[@(songID)] = @{ @"url" : result, @"ts" : @(now) };
        [_urlLock unlock];
    }
    return result;
}

- (NSString *)performResolve:(long long)songID deadline:(NSTimeInterval)deadline {
    UNMConfig *cfg = [UNMConfig shared];


    NSArray<NSString *> *order = cfg.providerOrder;
    if (order.count == 0) order = UNMRegisteredProviderKeys();

    UNMSongMeta *meta = [self metaForID:songID];
    if (!meta.usable && cfg.neteaseDetailFallback) {
        double remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining > 0.4) {
            meta = [self fetchMetaFromNetease:songID timeout:MIN(1.6, remaining - 0.2)];
        }
    }
    if (!meta.usable) {
        UNMLogW(@"no metadata for song %lld, cannot match", songID);
        return nil;
    }

    // Keyword order matters a great deal.
    //
    // Measured on MiGu with 稻香: searching "稻香" returns the studio version from
    // 魔杰座 as the first hit, with the live takes and the remix after it -- while
    // searching "稻香 周杰伦" returns the remix first and never surfaces the studio
    // version at all. The extra artist name degrades the search into a fuzzy text
    // match. So the title alone is tried first, and the combined form only as a
    // fallback.
    NSString *titleKeyword = UNMNormalizeTitle(meta.name);
    if (titleKeyword.length == 0) titleKeyword = meta.name;
    NSString *combinedKeyword = [UNMMatcher searchKeywordForMeta:meta];

    NSMutableArray<NSString *> *keywordList = [NSMutableArray array];
    if (titleKeyword.length) [keywordList addObject:titleKeyword];
    if (combinedKeyword.length && ![combinedKeyword isEqualToString:titleKeyword]) {
        [keywordList addObject:combinedKeyword];
    }

    NSString *keyword = combinedKeyword ?: titleKeyword ?: @"";


    NSMutableArray<NSString *> *tried = [NSMutableArray array];
    for (NSString *key in order) {
        if (deadline - CFAbsoluteTimeGetCurrent() <= 0.2) break;
        if (![key isKindOfClass:NSString.class]) continue;

        id<UNMProvider> provider = UNMProviderForKey(key);
        if (!provider) {
            [tried addObject:[NSString stringWithFormat:@"%@:absent", key]];
            continue;
        }

        double remaining = deadline - CFAbsoluteTimeGetCurrent();
        NSTimeInterval perTry = MIN((double)cfg.lookupTimeoutMS / 1000.0, remaining);
        if (perTry <= 0.2) break;

        // A blocking wait is intentional: the permit is only held for the
        // duration of one source request, and an unbalanced signal would let
        // the limit drift upwards over time.
        dispatch_semaphore_wait(_lookupLimit, DISPATCH_TIME_FOREVER);
        [[UNMStats shared] bumpResolveAttempt:key];

        NSArray<UNMCandidate *> *candidates = nil;
        UNMCandidate *hit = nil;

        for (NSString *attemptKeyword in keywordList) {
            // Give each attempt a real slice of the budget. Sharing one perTry across
            // attempts made the good keyword (title only) time out and hand over to
            // the weaker one, which is how a junk candidate pool was reached.
            double left = deadline - CFAbsoluteTimeGetCurrent();
            if (left <= 0.3) break;
            NSTimeInterval attemptTimeout = MIN((double)cfg.lookupTimeoutMS / 1000.0, left * 0.75);
            if (attemptTimeout <= 0.2) break;

            @try {
                candidates = [provider search:attemptKeyword timeout:attemptTimeout] ?: @[];
            } @catch (NSException *e) {
                UNMLogW(@"provider %@ search threw: %@", key, e.reason);
                candidates = @[];
            }

            hit = [UNMMatcher best:candidates forTarget:meta threshold:cfg.matchThreshold];

            // Nothing cleared the bar: take the best candidate anyway -- but only one
            // of the same kind. Loosening the similarity is fine when a title is
            // spelled oddly; swapping a remix in for the studio version is not, and
            // that is exactly what an unfiltered fallback did.
            if (hit == nil && candidates.count > 0) {
                NSMutableArray<UNMCandidate *> *compatible = [NSMutableArray array];
                for (UNMCandidate *candidate in candidates) {
                    if ([UNMMatcher isFamilyCompatible:candidate withTarget:meta]) {
                        [compatible addObject:candidate];
                    }
                }
                hit = [UNMMatcher best:compatible forTarget:meta threshold:0.30];
                if (hit) {
                    UNMLogI(@"[match] %@ 无候选过阈值(%.2f)，同类放宽后取 %.2f《%@》",
                            key, cfg.matchThreshold, hit.score, hit.title ?: @"?");
                    [[UNMStats shared] addEvent:[NSString stringWithFormat:@"放宽匹配 %@ %.2f",
                                                 key, hit.score]];
                }
            }

            if (hit) {
                UNMLogD(@"[match] %@ 用关键词《%@》命中 %.2f", key, attemptKeyword, hit.score);
                break;
            }
            if (deadline - CFAbsoluteTimeGetCurrent() <= 0.3) break;
        }

        NSString *url = nil;
        if (hit) {
            remaining = deadline - CFAbsoluteTimeGetCurrent();
            perTry = MIN((double)cfg.lookupTimeoutMS / 1000.0, remaining);
            if (perTry > 0.2) {
                @try {
                    url = [provider resolveURL:hit timeout:perTry];
                } @catch (NSException *e) {
                    UNMLogW(@"provider %@ resolve threw: %@", key, e.reason);
                }
            }
        }

        dispatch_semaphore_signal(_lookupLimit);

        if (url.length) {
            [self saveMatch:hit forID:songID];
            [[UNMStats shared] bumpResolveHit:key];
            UNMLogI(@"解灰命中 id=%lld 《%@》 -> %@ (%.2f, %@)", songID, meta.name, key, hit.score, hit.title);
            // Also surfaced as an event: the log line above is invisible from the
            // diagnostics screen, which is where anyone actually looks.
            [[UNMStats shared] addEvent:[NSString stringWithFormat:
                @"命中 %@ 《%@》/%@ (%.2f)", key, hit.title ?: @"?", hit.album ?: @"?", hit.score]];
            return url;
        }
        [[UNMStats shared] bumpResolveMiss:key];
        // Distinguish "the catalogue has nothing" from "everything it offered was a
        // different kind of recording and was refused" -- the second means the filter
        // is working and the song genuinely has no correct version available.
        if (candidates.count > 0 && hit == nil) {
            BOOL anyCompatible = NO;
            for (UNMCandidate *candidate in candidates) {
                if ([UNMMatcher isFamilyCompatible:candidate withTarget:meta]) {
                    anyCompatible = YES;
                    break;
                }
            }
            if (!anyCompatible) {
                [[UNMStats shared] addEvent:[NSString stringWithFormat:
                    @"%@ 只有变体版本(%lu条)，已全部拒绝", key, (unsigned long)candidates.count]];
            }
        }
        // Record *why*, not just that it failed: "0 candidates" and "found them but
        // could not get a URL" need completely different fixes, and without this the
        // only symptom is the same popup every time.
        NSString *outcome = candidates.count == 0
            ? [NSString stringWithFormat:@"%@:搜索0条", key]
            : (hit == nil
               ? [NSString stringWithFormat:@"%@:无匹配(共%lu条)", key, (unsigned long)candidates.count]
               : [NSString stringWithFormat:@"%@:取链失败《%@》", key, hit.title ?: @"?"]);
        [tried addObject:outcome];

        if (candidates.count == 0 && key) {
            [[UNMStats shared] addEvent:[NSString stringWithFormat:@"%@ 搜索无结果", key]];
        }
    }

    UNMLogW(@"解灰失败 id=%lld 《%@》-《%@》 tried %@",
            songID, meta.name, [meta.artists componentsJoinedByString:@"/"],
            [tried componentsJoinedByString:@","]);
    [[UNMStats shared] addEvent:[NSString stringWithFormat:@"无源《%@》 %@",
                                 meta.name ?: @"?", [tried componentsJoinedByString:@","]]];
    return nil;
}

- (void)saveMatch:(UNMCandidate *)candidate forID:(long long)songID {
    if (!candidate.provider.length || !candidate.mediaId.length) return;
    NSDictionary *entry = @{
        @"provider" : candidate.provider,
        @"mediaId"  : candidate.mediaId,
        @"extra"    : candidate.extra ?: @{},
        @"title"    : candidate.title ?: @"",
        @"artist"   : candidate.artist ?: @"",
        @"ts"       : @(CFAbsoluteTimeGetCurrent()),
    };
    dispatch_sync(_stateQueue, ^{
        self->_match[@(songID)] = entry;
    });
    _dirty = YES;
    [self scheduleFlush];
}

- (NSDictionary *)matchForID:(long long)songID {
    __block NSDictionary *m = nil;
    dispatch_sync(_stateQueue, ^{
        m = self->_match[@(songID)];
    });
    return m;
}

- (NSString *)cachedURLForID:(long long)songID {
    if (songID == 0) return nil;

    NSDictionary *entry = [self cachedEntryForID:songID];
    if (!entry) return nil;
    if (CFAbsoluteTimeGetCurrent() - [entry[@"ts"] doubleValue] >= kUNMURLTTL) return nil;

    id url = entry[@"url"];
    return [url isKindOfClass:NSString.class] ? url : nil;
}

- (void)seedMetaForID:(long long)songID
                 name:(NSString *)name
               artist:(NSString *)artist
                album:(NSString *)album
             duration:(double)duration {
    if (songID == 0 || name.length == 0) return;
    if ([self metaForID:songID].usable) return;

    UNMSongMeta *meta = [UNMSongMeta new];
    meta.songID = songID;
    meta.name = name;
    meta.artists = artist.length ? [artist componentsSeparatedByString:@"/"] : @[];
    meta.album = album ?: @"";
    meta.duration = duration;
    [self setMeta:meta];

    UNMLogD(@"[meta] 用 App 的歌曲对象填充 %lld 《%@》/%@/%@", songID, name,
            artist ?: @"?", album ?: @"?");
}

- (void)prefetchIDs:(NSArray<NSNumber *> *)songIDs {
    if (![UNMConfig shared].prefetchFromPrivilege || songIDs.count == 0) return;

    for (NSNumber *n in songIDs) {
        long long sid = n.longLongValue;
        if (sid == 0) continue;
        if ([self cachedURLForID:sid].length) continue;

        dispatch_async(_workQueue, ^{
            // The full provider chain. Prefetch must never depend on a single source, or
            // switching that source off silently turns warming into a no-op and every
            // tap fails for want of a warm URL.
            double deadline = CFAbsoluteTimeGetCurrent() + 6.0;
            [self resolveID:sid deadline:deadline];
        });
    }
}

- (NSString *)stats {
    __block NSUInteger meta = 0, match = 0;
    dispatch_sync(_stateQueue, ^{
        meta = self->_meta.count;
        match = self->_match.count;
    });
    [_urlLock lock];
    NSUInteger url = _urlCache.count;
    [_urlLock unlock];
    return [NSString stringWithFormat:@"meta=%lu match=%lu url=%lu providers=%@",
            (unsigned long)meta, (unsigned long)match, (unsigned long)url,
            [UNMRegisteredProviderKeys() componentsJoinedByString:@","]];
}

@end
