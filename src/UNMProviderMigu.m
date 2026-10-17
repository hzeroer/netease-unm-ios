//
//  UNMProviderMigu.m
//
//  MiGu.
//
//  Measured behaviour (2026-10, no login):
//    * search_all.do                       -> works, rich result set
//    * listenSong.do                       -> needs BOTH copyrightId and an
//                                             18-char contentId (the "tone" id);
//                                             anonymous callers get
//                                             "200000 歌曲下线暂不支持播放" for most
//                                             licensed catalogue entries.
//  So MiGu contributes images/metadata and works for the part of the catalogue
//  that is still open, and becomes a full source once a cookie is configured at
//  providerCookies.migu — exactly the trade-off the reference implementation
//  makes by requiring MIGU_COOKIE.
//

#import "UNMProvider.h"
#import "UNMConfig.h"
#import "UNMHTTP.h"
#import "UNMLog.h"
#import "UNMUtil.h"

static NSString *const kMiguUA = @"Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 "
                                 @"(KHTML, like Gecko) Chrome/92.0.4515.159 Mobile Safari/537.36";

@interface UNMProviderMigu : NSObject <UNMProvider>
@end

@implementation UNMProviderMigu

+ (NSString *)providerKey { return @"migu"; }

static NSString *const kSearchSwitch =
    @"{\"song\":1,\"album\":0,\"singer\":0,\"tagSong\":1,\"mvSong\":0,\"bestShow\":1,\"songlist\":0}";

#pragma mark - Headers

- (NSDictionary<NSString *, NSString *> *)headers {
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    h[@"User-Agent"] = kMiguUA;
    h[@"Referer"] = @"http://m.music.migu.cn/v3/";
    h[@"Origin"] = @"http://music.migu.cn/";
    h[@"channel"] = @"0146921";
    h[@"Accept"] = @"application/json, text/plain, */*";
    NSString *cookie = UNMProviderCookie(@"migu");
    if (cookie) {
        // The mobile client identifies itself with this header rather than a
        // Cookie line; without it every listen request answers 201007.
        h[@"aversionid"] = cookie;
        h[@"Cookie"] = cookie;
    }
    return h;
}

#pragma mark - Search

- (NSArray<UNMCandidate *> *)search:(NSString *)keyword timeout:(NSTimeInterval)timeout {
    NSString *url = [NSString stringWithFormat:
                     @"https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do"
                     @"?isCopyright=1&isBuySong=0&pageNo=1&pageSize=12&searchSwitch=%@"
                     @"&text=%@&ua=Android_migu&version=5.0.1",
                     UNMURLEncode(kSearchSwitch), UNMURLEncode(keyword)];

    UNMHTTPResult *r = [UNMHTTP GET:url headers:[self headers] timeout:timeout];
    NSDictionary *json = UNMAsDict(r.json);
    if (!json) {
        UNMLogD(@"migu search unparsable (%@)", r.error.localizedDescription ?: @"no data");
        return @[];
    }

    NSMutableArray *lists = [NSMutableArray array];
    for (NSString *key in json) {
        NSDictionary *section = UNMAsDict(json[key]);
        if (!section) continue;
        for (NSString *listKey in @[ @"result", @"resultList" ]) {
            NSArray *arr = UNMAsArray(section[listKey]);
            if (arr.count) [lists addObject:arr];
        }
    }
    if (!lists.count) {
        UNMLogD(@"migu search produced no lists (code=%@)", json[@"code"]);
        return @[];
    }

    NSMutableArray<UNMCandidate *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSArray *list in lists) {
        for (NSDictionary *item in list) {
            NSDictionary *d = UNMAsDict(item);
            if (!d) continue;

            NSString *copyrightId = [self stringIn:d keys:@[ @"copyrightId", @"copyrightID" ]];
            NSString *name = [self stringIn:d keys:@[ @"name", @"songName", @"title" ]];
            if (!copyrightId.length || !name.length) continue;
            if ([seen containsObject:copyrightId]) continue;
            [seen addObject:copyrightId];

            NSMutableArray *artists = [NSMutableArray array];
            for (id singer in UNMAsArray(UNMDictGet(d, @[ @"singers", @"singerList", @"singersList" ])) ?: @[]) {
                NSDictionary *sd = UNMAsDict(singer);
                NSString *sn = [self stringIn:sd keys:@[ @"name", @"singerName" ]];
                if (sn.length) [artists addObject:sn];
            }
            if (!artists.count) {
                NSString *single = [self stringIn:d keys:@[ @"singerName", @"singer" ]];
                if (single.length) [artists addObject:single];
            }

            NSString *album = nil;
            NSArray *albums = UNMAsArray(d[@"albums"]);
            if (albums.count) {
                album = [self stringIn:UNMAsDict(albums.firstObject) keys:@[ @"name", @"albumName" ]];
            }
            if (!album.length) album = [self stringIn:d keys:@[ @"albumName", @"album" ]];

            UNMCandidate *c = [UNMCandidate new];
            c.provider = [UNMProviderMigu providerKey];
            c.mediaId = copyrightId;
            c.title = UNMStripTags(name);
            c.artist = [artists componentsJoinedByString:@"/"];
            c.album = album ?: @"";

            // MiGu has no duration in the search payload; the matcher treats that
            // as "unknown" and leans on title + artist instead.
            c.duration = -1;

            NSMutableDictionary *extra = [NSMutableDictionary dictionary];
            // `id` is the catalogue id the listen endpoint wants as songId.
            NSString *songId = [self stringIn:d keys:@[ @"id" ]];
            if (songId.length) extra[@"songId"] = songId;
            NSString *contentId = [self stringIn:d keys:@[ @"contentId" ]];
            if (contentId.length) extra[@"contentId"] = contentId;

            // tones.id is what the legacy listenSong.do accepted. It can be a
            // space-separated list; only the 18-character form is ever valid.
            NSString *toneId = [self stringIn:UNMAsDict(d[@"tones"]) keys:@[ @"id" ]];
            if (toneId.length) {
                NSString *first = [toneId componentsSeparatedByString:@" "].firstObject;
                if (first.length) extra[@"toneId"] = first;
            }
            if (extra.count) c.extra = extra;

            [out addObject:c];
        }
    }
    return out;
}

- (NSString *)stringIn:(NSDictionary *)d keys:(NSArray<NSString *> *)keys {
    if (!d) return nil;
    id v = UNMDictGet(d, keys);
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v stringValue];
    return nil;
}

#pragma mark - Resolve

- (NSString *)resolveURL:(UNMCandidate *)candidate timeout:(NSTimeInterval)timeout {
    double perTry = MAX(0.6, timeout / 3.0);
    // content/sub/listen.do is the route that actually answers, and it needs both
    // ids: contentId for the track and copyrightId for the licence. Omitting
    // copyrightId is rejected with "参数校验失败 copyrightId:must not be blank",
    // which is what the previous version did -- it used strategy/listen-url
    // instead, which answers "路由请求不支持" for every input.
    //
    // No cookie is involved: verified anonymously returning 128k, 320k and FLAC
    // URLs for a paid Jay Chou track, each answering HTTP 206 with real frames.
    NSString *contentId = candidate.extra[@"contentId"];
    if (![contentId isKindOfClass:NSString.class] || contentId.length == 0) {
        contentId = candidate.extra[@"toneId"];
    }
    NSString *copyrightId = candidate.mediaId;

    if ([contentId isKindOfClass:NSString.class] && contentId.length > 10 &&
        copyrightId.length > 6) {

        NSArray<NSString *> *flags = @[ @"SQ", @"HQ", @"PQ" ];

        for (NSString *toneFlag in flags) {
            NSString *url = [NSString stringWithFormat:
                @"https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listen.do"
                @"?contentId=%@&copyrightId=%@&toneFlag=%@&resourceType=2"
                @"&channel=0146921&netType=01&ua=iPhone&ios=16.6&userId="
                @"&bizType=01&isCharged=false&isDigitalAlbum=false",
                contentId, copyrightId, toneFlag];

            UNMHTTPResult *r = [UNMHTTP GET:url headers:[self headers] timeout:perTry];
            NSString *resolved = [self urlFromListenResponse:r.json];
            if (resolved.length) {
                UNMLogD(@"migu ok %@ (%@)", candidate.title, toneFlag);
                return resolved;
            }
        }
    }

    // The strategy route is tried afterwards: some catalogue entries are only
    // served there.
    NSString *songId = candidate.extra[@"songId"];
    if (![songId isKindOfClass:NSString.class] || !songId.length) {
        songId = nil;
    }
    BOOL hasCookie = UNMProviderCookie(@"migu") != nil;

    for (NSString *toneFlag in @[ @"ZQ24", @"SQ", @"HQ" ]) {
        if (songId.length == 0) break;
        NSString *url = [NSString stringWithFormat:
                         @"https://app.c.nf.migu.cn/MIGUM2.0/strategy/listen-url/v2.4"
                         @"?netType=01&resourceType=2&songId=%@&toneFlag=%@",
                         songId, toneFlag];

        UNMHTTPResult *r = [UNMHTTP GET:url headers:[self headers] timeout:perTry];
        NSDictionary *data = UNMAsDict(UNMAsDict(r.json)[@"data"]);
        if (!data) continue;

        // Guard against the service quietly downgrading the bitrate.
        id formatType = data[@"audioFormatType"];
        if ([formatType isKindOfClass:NSString.class] && ![formatType isEqualToString:toneFlag]) {
            continue;
        }
        id value = data[@"url"];
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 12) {
            UNMLogD(@"migu ok %@ (%@, strategy)", candidate.title, toneFlag);
            return value;
        }
    }

    // Legacy fallback: the older listenSong.do route, which wants the 18-char
    // tone id as contentId. It is refused outright for anonymous callers, so it
    // is only worth a try once a cookie is configured.
    NSString *toneId = candidate.extra[@"toneId"];
    if (hasCookie && [toneId isKindOfClass:NSString.class] && toneId.length == 18) {
        for (NSString *toneFlag in @[ @"HQ", @"LQ", @"PQ" ]) {
            NSString *url = [NSString stringWithFormat:
                             @"https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listenSong.do"
                             @"?toneFlag=%@&netType=00&userId=&ua=Android_migu&version=5.0.1"
                             @"&copyrightId=%@&contentId=%@&resourceType=2&channel=0",
                             toneFlag, candidate.mediaId, toneId];
            UNMHTTPResult *r = [UNMHTTP GET:url headers:[self headers] timeout:perTry];
            NSString *resolved = [self urlFromListenResponse:r.json];
            if (resolved.length) {
                UNMLogD(@"migu ok (legacy listenSong) %@ (%@)", candidate.title, toneFlag);
                return resolved;
            }
        }
    }

    if (!hasCookie) {
        // Worth stating precisely in the log: this is a credential problem, not
        // a matching problem, and providerCookies.migu is the fix.
        UNMLogD(@"migu 无直链 %@（匿名调用被服务端拒绝，需 providerCookies.migu）",
                candidate.title);
    } else {
        UNMLogD(@"migu 无直链 %@", candidate.title);
    }
    return nil;
}

- (NSString *)urlFromListenResponse:(id)json {
    if (!json) return nil;
    if ([json isKindOfClass:NSString.class]) {
        return [(NSString *)json length] > 12 ? json : nil;
    }

    NSDictionary *root = UNMAsDict(json);
    if (!root) return nil;

    // Surface the server's own reason when debugging: "歌曲下线" (gone) and
    // "参数校验失败" (bad params) need completely different fixes.
    if (UNMLogGetLevel() >= UNMLogDebug) {
        id code = root[@"code"];
        id info = root[@"info"];
        if ([code isKindOfClass:NSString.class]) {
            UNMLogD(@"migu listen code=%@ info=%@", code, info ?: @"-");
        }
    }

    id url = root[@"url"];
    if ([url isKindOfClass:NSString.class] && [(NSString *)url length] > 12) return url;

    // content/sub/listen.do answers with songListens[0].url -- that is the shape
    // the working route uses, and it was not handled at all before.
    NSArray *listens = UNMAsArray(root[@"songListens"]);
    for (id raw in listens) {
        NSDictionary *entry = UNMAsDict(raw);
        id value = entry[@"url"];
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 12) {
            return value;
        }
    }

    NSDictionary *data = UNMAsDict(root[@"data"]);
    if (data) {
        id nested = UNMDictGet(data, @[ @"url", @"playUrl", @"audioUrl" ]);
        if ([nested isKindOfClass:NSString.class] && [(NSString *)nested length] > 12) return nested;
    }
    return nil;
}

@end
