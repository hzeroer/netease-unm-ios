//
//  UNMProviderKugou.m
//
//  KuGou, as implemented by UnblockNeteaseMusic (src/provider/kugou.js).
//
//  This is the source that actually covers 华研's catalogue on the desktop setup
//  (田馥甄《小幸运》 and friends, which MiGu simply does not carry). It needs no
//  cookie: the whole authorisation is one MD5 over the track hash.
//
//      search  http://mobilecdn.kugou.com/api/v3/search/song?keyword=…&page=1&pagesize=10
//      track   http://trackercdn.kugou.com/i/v2/?key=MD5(hash + "kgcloudv2")
//                                            &hash=…&appid=1005&pid=2&cmd=25
//                                            &behavior=play&album_id=…
//
//  Verified end to end: 《小幸运》/田馥甄 returns a flac and two mp3s, all HTTP 206.
//

#import "UNMProvider.h"
#import "UNMHTTP.h"
#import "UNMLog.h"
#import "UNMUtil.h"

#import <CommonCrypto/CommonDigest.h>

static NSString *UNMKugouString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

static NSString *UNMKugouMD5(NSString *input) {
    if (input.length == 0) return @"";

    unsigned char digest[CC_MD5_DIGEST_LENGTH] = {0};
    CC_MD5(input.UTF8String, (CC_LONG)strlen(input.UTF8String), digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

/// The response embeds links as "http:\/\/host\/path" -- the slashes are escaped.
static NSString *UNMKugouUnescape(NSString *value) {
    return [value stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
}

@interface UNMProviderKugou : NSObject <UNMProvider>
@end

@implementation UNMProviderKugou

+ (NSString *)providerKey {
    return @"kugou";
}

- (NSArray<UNMCandidate *> *)search:(NSString *)keyword timeout:(NSTimeInterval)timeout {
    if (keyword.length == 0) return @[];

    NSString *encoded = [keyword stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:
        @"http://mobilecdn.kugou.com/api/v3/search/song?keyword=%@&page=1&pagesize=10",
        encoded];

    UNMHTTPResult *result = [UNMHTTP GET:url
                                 headers:@{ @"User-Agent" : @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)" }
                                 timeout:MIN(timeout, 8.0)];

    if (result == nil || result.status < 200 || result.status >= 300) {
        // Say *why* it failed: a status code separates "this network cannot reach
        // KuGou" from "KuGou answered but refused us", and those need different fixes.
        NSString *snippet = [result.text substringToIndex:MIN(120, result.text.length)];
        UNMLogW(@"[kugou] 搜索 HTTP %ld 错误=%@ 响应=%@", (long)result.status,
                result.error.localizedDescription ?: @"-", snippet ?: @"(空)");
        return @[];
    }
    NSDictionary *json = result.json;
    if (![json isKindOfClass:NSDictionary.class]) return @[];

    NSDictionary *data = UNMAsDict(json[@"data"]);
    NSArray *info = data[@"info"];
    if (![info isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<UNMCandidate *> *candidates = [NSMutableArray array];
    for (NSDictionary *entry in info) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;

        NSString *hash = UNMKugouString(entry[@"hash"]);
        NSString *title = UNMKugouString(entry[@"songname"]);
        if (hash.length != 32 || title.length == 0) continue;

        UNMCandidate *candidate = [UNMCandidate new];
        candidate.provider = [self.class providerKey];
        candidate.mediaId = hash;                       // the standard-quality hash
        candidate.title = title;
        candidate.artist = UNMKugouString(entry[@"singername"]);
        candidate.album = UNMKugouString(entry[@"album_name"]);

        id duration = entry[@"duration"];
        candidate.duration = [duration respondsToSelector:@selector(doubleValue)]
            ? [duration doubleValue] : -1;

        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        for (NSString *key in @[ @"320hash", @"sqhash" ]) {
            NSString *value = UNMKugouString(entry[key]);
            if (value.length == 32) extra[key] = value;
        }
        NSString *albumId = UNMKugouString(entry[@"album_id"]);
        if (albumId.length) extra[@"album_id"] = albumId;
        candidate.extra = extra;

        [candidates addObject:candidate];
    }

    UNMLogD(@"[kugou] 搜索《%@》得到 %lu 条", keyword, (unsigned long)candidates.count);
    return candidates;
}

/// One quality tier. nil when KuGou refuses this hash (paid, region, gone).
- (NSString *)urlForHash:(NSString *)hash
                 albumID:(NSString *)albumID
                 timeout:(NSTimeInterval)timeout {
    if (hash.length != 32) return nil;

    NSString *key = UNMKugouMD5([hash stringByAppendingString:@"kgcloudv2"]);
    NSString *url = [NSString stringWithFormat:
        @"http://trackercdn.kugou.com/i/v2/?key=%@&hash=%@&appid=1005&pid=2&cmd=25"
        @"&behavior=play&album_id=%@",
        key, hash, albumID.length ? albumID : @""];

    UNMHTTPResult *result = [UNMHTTP GET:url
                                 headers:@{ @"User-Agent" : @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)" }
                                 timeout:MIN(timeout, 7.0)];

    if (result == nil || result.status < 200 || result.status >= 300) {
        UNMLogW(@"[kugou] 取链 HTTP %ld 错误=%@", (long)result.status,
                result.error.localizedDescription ?: @"-");
        return nil;
    }
    NSDictionary *json = result.json;
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    // status 2 means "not playable for this caller"; the url array is absent.
    NSArray *urls = json[@"url"];
    if (![urls isKindOfClass:NSArray.class] || urls.count == 0) {
        // Distinguish "KuGou refused this hash" from "the body was not what we
        // expected" -- without this the caller only sees a nil URL.
        UNMLogW(@"[kugou] hash=%@ 无 url 字段 status=%@ 响应=%@",
                [hash substringToIndex:MIN(8, hash.length)],
                UNMKugouString(json[@"status"]),
                [result.text substringToIndex:MIN(150, result.text.length)] ?: @"(空)");
        return nil;
    }

    NSString *link = UNMKugouUnescape(UNMKugouString(urls.firstObject));
    if (![link hasPrefix:@"http"]) return nil;

    // KuGou hands out plain http, and the player on iOS answers that with its own
    // "网络不给力" because App Transport Security refuses cleartext. The same file is
    // served over https (verified: HTTP 206 both ways), so upgrade the scheme.
    if ([link hasPrefix:@"http://"]) {
        link = [@"https://" stringByAppendingString:[link substringFromIndex:7]];
    }
    return link;
}

- (NSString *)resolveURL:(UNMCandidate *)candidate timeout:(NSTimeInterval)timeout {
    if (candidate == nil) return nil;

    NSString *albumID = UNMKugouString(UNMAsDict(candidate.extra)[@"album_id"]);
    double deadline = CFAbsoluteTimeGetCurrent() + MIN(timeout, 9.0);

    // Highest quality first, exactly like the reference implementation: lossless,
    // then 320k, then whatever the default hash gives.
    NSMutableArray<NSString *> *tiers = [NSMutableArray array];
    NSString *sq = UNMKugouString(UNMAsDict(candidate.extra)[@"sqhash"]);
    NSString *hq = UNMKugouString(UNMAsDict(candidate.extra)[@"320hash"]);
    if (sq.length == 32) [tiers addObject:sq];
    if (hq.length == 32) [tiers addObject:hq];
    if (candidate.mediaId.length == 32) [tiers addObject:candidate.mediaId];

    for (NSString *hash in tiers) {
        if (deadline - CFAbsoluteTimeGetCurrent() <= 0.3) break;

        NSString *url = [self urlForHash:hash albumID:albumID
                                 timeout:deadline - CFAbsoluteTimeGetCurrent()];
        UNMLogI(@"[kugou] 尝试 hash=%@ 专辑=%@ → %@",
                [hash substringToIndex:MIN(8, hash.length)],
                albumID.length ? albumID : @"(空)",
                url.length ? @"成功" : @"失败");
        if (url.length) {
            UNMLogD(@"[kugou] 命中 %@ 《%@》", [url hasSuffix:@"flac"] ? @"FLAC" : @"MP3",
                    candidate.title ?: @"?");
            return url;
        }
    }
    return nil;
}

@end
