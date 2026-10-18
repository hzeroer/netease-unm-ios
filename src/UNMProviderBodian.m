//
//  UNMProviderBodian.m
//
//  BoDian (波点) -- the first source in the desktop setup this project is measured
//  against, and the one that actually serves 田馥甄《小幸运》.
//
//  It is a KuWo mirror, so it uses KuWo's catalogue search and KuWo's mobile API:
//
//      search  http://search.kuwo.cn/r.s?…&all=<keyword>
//      track   http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=<rid>
//                                                &timestamp=<ms>&sign=<md5>
//
//  The signature is KuWo's "kuwotest" scheme, taken from UnblockNeteaseMusic:
//  lowercase the query string, strip everything but [a-zA-Z0-9], sort the characters,
//  and MD5 the concatenation of "kuwotest" + that + the URL path.
//
//  The reference implementation also POSTs to an ad-watch endpoint first to unlock
//  paid tracks. That endpoint's signature uses a different salt and the published one
//  is stale, so it is not reproduced here -- free entries resolve without it, and the
//  paid ones answer 20018 either way. Songs with several catalogue entries therefore
//  work as long as any one of them is free, which is why the caller retries the next
//  candidate before giving up on this source.
//

#import "UNMProvider.h"
#import "UNMConfig.h"
#import "UNMHTTP.h"
#import "UNMLog.h"
#import "UNMUtil.h"

#import <CommonCrypto/CommonDigest.h>

static NSString *UNMBodianMD5(NSString *input) {
    if (input.length == 0) return @"";
    unsigned char digest[CC_MD5_DIGEST_LENGTH] = {0};
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *UNMBodianString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

/// Append the KuWo signature to a request URL.
static NSString *UNMBodianSign(NSString *rawURL) {
    if (rawURL.length == 0) return rawURL;

    long long millis = (long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
    // Wall-clock milliseconds, not uptime: the service compares them with its own.
    millis = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);

    NSString *signed_ = [rawURL stringByAppendingFormat:@"&timestamp=%lld", millis];

    NSRange question = [signed_ rangeOfString:@"?"];
    if (question.location == NSNotFound) return signed_;
    NSString *query = [signed_ substringFromIndex:NSMaxRange(question)];

    NSMutableString *filtered = [NSMutableString stringWithCapacity:query.length];
    for (NSUInteger i = 0; i < query.length; i++) {
        unichar c = [query characterAtIndex:i];
        BOOL keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (keep) [filtered appendFormat:@"%C", c];
    }

    NSMutableArray<NSNumber *> *codes = [NSMutableArray arrayWithCapacity:filtered.length];
    for (NSUInteger i = 0; i < filtered.length; i++) {
        [codes addObject:@([filtered characterAtIndex:i])];
    }
    [codes sortUsingSelector:@selector(compare:)];

    NSMutableString *sorted = [NSMutableString stringWithCapacity:codes.count];
    for (NSNumber *code in codes) [sorted appendFormat:@"%C", (unichar)code.unsignedShortValue];

    NSURL *parsed = [NSURL URLWithString:rawURL];
    NSString *path = parsed.path ?: @"";

    NSString *payload = [NSString stringWithFormat:@"kuwotest%@%@", sorted, path];
    return [signed_ stringByAppendingFormat:@"&sign=%@", UNMBodianMD5(payload)];
}

@interface UNMProviderBodian : NSObject <UNMProvider>
@end

@implementation UNMProviderBodian

+ (NSString *)providerKey {
    return @"bodian";
}

/// The device id, and the only thing KuWo uses to decide whether a track is unlocked.
///
/// A pinned id goes stale within the hour, so this behaves like the reference client:
/// a new id per launch, plus one more whenever the service says "not unlocked".
static NSString *UNMBodianDeviceID = nil;

+ (NSString *)deviceID {
    NSString *pinned = [UNMConfig shared].bodianDevid;
    if (pinned.length > 0) return pinned;

    if (UNMBodianDeviceID == nil) {
        // arc4random_uniform takes a uint32, so 90 billion does not fit; build the
        // 11-digit id from two draws instead of truncating the range.
        unsigned long long value = 10000000000ULL
                                 + ((unsigned long long)arc4random_uniform(90000) * 1000000ULL)
                                 + (unsigned long long)arc4random_uniform(1000000);
        UNMBodianDeviceID = [NSString stringWithFormat:@"%llu", value];
    }
    return UNMBodianDeviceID;
}

+ (void)rotateDeviceID {
    UNMBodianDeviceID = nil;
}

- (NSDictionary<NSString *, NSString *> *)clientHeaders {
    // The device id is the whole authorisation.
    //
    // KuWo decides "is this track unlocked" per device, on the server: the id below
    // has already watched the advert that unlocks paid tracks, so audioUrl answers
    // 200 for them, while a freshly generated id answers 20018 "没有解锁付费歌曲"
    // for the same URL and the same signature. Measured minutes apart on one machine:
    //
    //     88637305104 -> 稻香 / 青花瓷 / 七里香 / 小幸运   all 200
    //     random id   -> 20018 for every one of them
    //
    // A fresh id per process, the way the reference client behaves.
    //
    // KuWo grants the paid-track unlock to a device id for a limited window and then
    // forgets it: an id that answered 200 at 22:55 answered 20018 by 23:15. The
    // reference client therefore generates a new id on every launch and re-runs the
    // advert call with it, which is why it keeps working while a pinned id goes stale.
    // The config value, when set, wins -- handy for pinning a known good id.
    NSString *deviceID = [self.class deviceID];

    return @{
        @"Accept" : @"application/json, text/plain, */*",
        @"Accept-Language" : @"zh-CN,zh;q=0.9",
        @"User-Agent" : @"Dart/2.19 (dart:io)",
        @"plat" : @"ar",
        @"channel" : @"aliopen",
        @"devid" : deviceID,
        @"ver" : @"3.9.0",
        @"host" : @"bd-api.kuwo.cn",
        @"X-Forwarded-For" : @"1.0.1.114",
    };
}

- (NSArray<UNMCandidate *> *)search:(NSString *)keyword timeout:(NSTimeInterval)timeout {
    if (keyword.length == 0) return @[];

    NSString *encoded = [keyword stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:
        @"http://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive&encoding=utf8"
        @"&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all=%@", encoded];

    UNMHTTPResult *result = [UNMHTTP GET:url
                                 headers:@{ @"User-Agent" : @"Mozilla/5.0" }
                                 timeout:MIN(timeout, 8.0)];

    // KuWo throttles the search endpoint: prefetching a whole playlist fires dozens of
    // requests within a second and some come back 403 with a 150-byte error page.
    // Dropping that song is the wrong answer to a rate limit -- back off and ask again.
    if (UNMAsDict(result.json) == nil &&
        (result.status == 403 || result.status == 429)) {
        for (NSInteger attempt = 1; attempt <= 2; attempt++) {
            NSTimeInterval wait = 0.25 * attempt;
            UNMLogI(@"[bodian] 搜索被限流（HTTP %ld），%.0fms 后重试第 %ld 次",
                    (long)result.status, wait * 1000.0, (long)attempt);
            [NSThread sleepForTimeInterval:wait];

            result = [UNMHTTP GET:url
                           headers:@{ @"User-Agent" : @"Mozilla/5.0" }
                           timeout:MIN(timeout, 8.0)];
            if (UNMAsDict(result.json) != nil) break;
        }
    }

    NSDictionary *root = UNMAsDict(result.json);
    if (root == nil) {
        UNMLogW(@"[bodian] 搜索 HTTP %ld 响应不是 JSON（%lu 字节）",
                (long)result.status, (unsigned long)result.text.length);
        return @[];
    }

    // Walk the payload instead of slicing it.
    //
    // A hit does not start at "{" -- it begins mid-object, after the previous record's
    // last field -- so splitting on a delimiter silently shifts every field by one
    // record. That is not theoretical: 《小幸运》's DURATION came back as 309s when the
    // song is 263s, because 309 was the *next* entry's duration. Walking the JSON keeps
    // every field with the record that owns it.
    NSMutableArray<UNMCandidate *> *candidates = [NSMutableArray array];

    for (id section in UNMAsArray(root[@"content"])) {
        NSDictionary *page = UNMAsDict(UNMAsDict(section)[@"musicpage"]);
        for (id item in UNMAsArray(page[@"abslist"])) {
            NSDictionary *row = UNMAsDict(item);
            if (row == nil) continue;

            NSString *rid = UNMBodianString(row[@"MUSICRID"]);
            if ([rid hasPrefix:@"MUSIC_"]) rid = [rid substringFromIndex:6];

            NSString *title = UNMBodianString(row[@"SONGNAME"]);
            if (title.length == 0) title = UNMBodianString(row[@"NAME"]);
            if (rid.length == 0 || title.length == 0) continue;

            UNMCandidate *candidate = [UNMCandidate new];
            candidate.provider = [self.class providerKey];
            candidate.mediaId = rid;
            candidate.title = title;
            candidate.artist = UNMBodianString(row[@"ARTIST"]);
            candidate.album = UNMBodianString(row[@"ALBUM"]);

            NSString *duration = UNMBodianString(row[@"DURATION"]);
            candidate.duration = duration.length ? duration.doubleValue : -1;

            [candidates addObject:candidate];
        }
    }

    UNMLogI(@"[bodian] 搜索《%@》→ %lu 条", keyword, (unsigned long)candidates.count);
    return candidates;
}

/// The advert call the reference client makes before asking for a paid track.
///
/// Its body comes back as `{"code":439,"sign invalid"}` -- the signature baked into
/// the reference client is stale -- but the call still has to be made: the service
/// grants the unlock to the device id that made it, not to a valid signature. Skip it
/// and the id stays unauthorised, and audioUrl answers 20018.
- (void)requestUnlockOnce {
    // One advert call per device id. A rotated id has to make its own call, which is
    // why this is keyed on the id rather than being a plain once-only flag.
    static NSString *unlockedID = nil;
    NSString *current = [self.class deviceID];
    if ([unlockedID isEqualToString:current]) return;
    unlockedID = current;

    NSString *url = @"http://bd-api.kuwo.cn/api/service/advert/watch?uid=-1&token="
                     "&timestamp=1724306124436&sign=15a676d66285117ad714e8c8371691da";
    NSMutableDictionary *headers = [[self clientHeaders] mutableCopy];
    headers[@"Content-Type"] = @"application/json; charset=utf-8";
    headers[@"qimei36"] = @"1e9970cbcdc20a031dee9f37100017e1840e";

    NSData *body = [@"{\"type\":5,\"subType\":5,\"musicId\":0,\"adToken\":\"\"}"
                    dataUsingEncoding:NSUTF8StringEncoding];
    UNMHTTPResult *result = [UNMHTTP POST:url
                                     body:body
                              contentType:@"application/json; charset=utf-8"
                                  headers:headers
                                  timeout:3.0];
    UNMLogI(@"[bodian] 解锁请求 devid=%@ HTTP %ld", current, (long)result.status);
}

- (NSString *)resolveURL:(UNMCandidate *)candidate timeout:(NSTimeInterval)timeout {
    if (candidate.mediaId.length == 0) return nil;
    [self requestUnlockOnce];


    NSString *base = [NSString stringWithFormat:
        @"http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=%@",
        candidate.mediaId];
    NSString *url = UNMBodianSign(base);

    UNMHTTPResult *result = [UNMHTTP GET:url headers:[self clientHeaders]
                                 timeout:MIN(timeout, 7.0)];
    NSDictionary *json = result.json;
    if (![json isKindOfClass:NSDictionary.class]) {
        UNMLogW(@"[bodian] rid=%@ 响应不是 JSON (HTTP %ld)", candidate.mediaId, (long)result.status);
        return nil;
    }

    NSInteger code = [json[@"code"] integerValue];
    if (code == 20018) {
        // "没有解锁付费歌曲": this device id has no grant, or its grant expired.
        // Rotate to a fresh id, make its advert call, and ask once more -- that is
        // exactly what the reference client does on every launch.
        [[self class] rotateDeviceID];
        [self requestUnlockOnce];

        url = UNMBodianSign(base);
        result = [UNMHTTP GET:url headers:[self clientHeaders] timeout:MIN(timeout, 7.0)];
        json = result.json;
        code = [json[@"code"] integerValue];
        if (code != 200) {
            UNMLogI(@"[bodian] rid=%@ 换设备号后仍 code=%ld %@", candidate.mediaId, (long)code,
                    UNMBodianString(json[@"msg"]));
            return nil;
        }
    }
    if (code != 200) {
        // 20018 is the paid-entry answer. Free entries for the same song exist under
        // other ids, which is what the caller's candidate retry is for.
        UNMLogI(@"[bodian] rid=%@ code=%ld %@", candidate.mediaId, (long)code,
                UNMBodianString(json[@"msg"]));
        return nil;
    }

    NSDictionary *data = UNMAsDict(json[@"data"]);
    NSString *audio = UNMBodianString(data[@"audioUrl"]);
    if (audio.length == 0) return nil;

    // Upgrade to https for the player: iOS refuses cleartext audio under ATS.
    if ([audio hasPrefix:@"http://"]) {
        audio = [@"https://" stringByAppendingString:[audio substringFromIndex:7]];
    }
    return audio;
}

@end
