#import <objc/runtime.h>
//
//  UNMUtil.m
//

#import "UNMUtil.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - MD5 (self-contained, so the dylib needs no extra library)

typedef struct {
    uint32_t state[4];
    uint64_t bitCount;
    uint8_t buffer[64];
    uint32_t bufferLen;
} UNMMD5Ctx;

static const uint32_t kMD5K[64] = {
    0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
    0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
    0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
    0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
    0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
    0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
    0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
    0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
};

static const uint32_t kMD5S[64] = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
};

static inline uint32_t UNMRotl(uint32_t x, uint32_t c) {
    return (x << c) | (x >> (32 - c));
}

static void UNMMD5Transform(UNMMD5Ctx *ctx, const uint8_t block[64]) {
    uint32_t M[16];
    for (int i = 0; i < 16; i++) {
        M[i] = (uint32_t)block[i * 4]
             | ((uint32_t)block[i * 4 + 1] << 8)
             | ((uint32_t)block[i * 4 + 2] << 16)
             | ((uint32_t)block[i * 4 + 3] << 24);
    }
    uint32_t a = ctx->state[0], b = ctx->state[1], c = ctx->state[2], d = ctx->state[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f, g;
        if (i < 16)      { f = (b & c) | (~b & d);         g = (uint32_t)i; }
        else if (i < 32) { f = (d & b) | (~d & c);         g = (uint32_t)(5 * i + 1) % 16; }
        else if (i < 48) { f = b ^ c ^ d;                  g = (uint32_t)(3 * i + 5) % 16; }
        else             { f = c ^ (b | ~d);               g = (uint32_t)(7 * i) % 16; }
        uint32_t tmp = d;
        d = c;
        c = b;
        b = b + UNMRotl(a + f + kMD5K[i] + M[g], kMD5S[i]);
        a = tmp;
    }
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
}

static void UNMMD5Init(UNMMD5Ctx *ctx) {
    ctx->state[0] = 0x67452301;
    ctx->state[1] = 0xefcdab89;
    ctx->state[2] = 0x98badcfe;
    ctx->state[3] = 0x10325476;
    ctx->bitCount = 0;
    ctx->bufferLen = 0;
}

static void UNMMD5Update(UNMMD5Ctx *ctx, const uint8_t *data, size_t len) {
    ctx->bitCount += (uint64_t)len * 8;
    while (len > 0) {
        size_t take = 64 - ctx->bufferLen;
        if (take > len) take = len;
        memcpy(ctx->buffer + ctx->bufferLen, data, take);
        ctx->bufferLen += (uint32_t)take;
        data += take;
        len -= take;
        if (ctx->bufferLen == 64) {
            UNMMD5Transform(ctx, ctx->buffer);
            ctx->bufferLen = 0;
        }
    }
}

static void UNMMD5Final(UNMMD5Ctx *ctx, uint8_t digest[16]) {
    uint64_t bits = ctx->bitCount;
    uint8_t pad = 0x80;
    UNMMD5Update(ctx, &pad, 1);
    uint8_t zero = 0;
    while (ctx->bufferLen != 56) {
        UNMMD5Update(ctx, &zero, 1);
    }
    uint8_t lenBytes[8];
    for (int i = 0; i < 8; i++) lenBytes[i] = (uint8_t)((bits >> (8 * i)) & 0xFF);
    UNMMD5Update(ctx, lenBytes, 8);

    for (int i = 0; i < 4; i++) {
        digest[i * 4]     = (uint8_t)(ctx->state[i] & 0xFF);
        digest[i * 4 + 1] = (uint8_t)((ctx->state[i] >> 8) & 0xFF);
        digest[i * 4 + 2] = (uint8_t)((ctx->state[i] >> 16) & 0xFF);
        digest[i * 4 + 3] = (uint8_t)((ctx->state[i] >> 24) & 0xFF);
    }
}

NSString *UNMMD5(NSString *input) {
    NSData *d = [input dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    UNMMD5Ctx ctx;
    UNMMD5Init(&ctx);
    UNMMD5Update(&ctx, d.bytes, d.length);
    uint8_t digest[16];
    UNMMD5Final(&ctx, digest);
    char out[33];
    for (int i = 0; i < 16; i++) snprintf(out + i * 2, 3, "%02x", digest[i]);
    return @(out);
}

#pragma mark - Generic helpers

NSString *UNMURLEncode(NSString *input) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    });
    return [input stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

NSString *UNMTrim(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *UNMStripTags(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    NSMutableString *out = [s mutableCopy];
    for (NSString *tag in @[@"<em>", @"</em>", @"<b>", @"</b>", @"<span>", @"</span>"]) {
        [out replaceOccurrencesOfString:tag withString:@"" options:NSCaseInsensitiveSearch
                                 range:NSMakeRange(0, out.length)];
    }
    // KuWo/KuGou escape a few characters in their JSON payloads.
    NSDictionary<NSString *, NSString *> *entities = @{
        @"&nbsp;" : @" ", @"&amp;" : @"&", @"&lt;" : @"<", @"&gt;" : @">",
        @"&quot;" : @"\"", @"&#39;" : @"'", @"&apos;" : @"'",
    };
    for (NSString *entity in entities) {
        [out replaceOccurrencesOfString:entity withString:entities[entity]
                                 options:NSCaseInsensitiveSearch
                                   range:NSMakeRange(0, out.length)];
    }
    return out;
}

static NSString *UNMFullWidthToHalf(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0xFF01 && c <= 0xFF5E) {
            [out appendFormat:@"%C", (unichar)(c - 0xFEE0)];
        } else if (c == 0x3000) {
            [out appendString:@" "];
        } else {
            [out appendFormat:@"%C", c];
        }
    }
    return out;
}

NSString *UNMNormalizeTitle(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length == 0) return @"";

    NSString *s = UNMStripTags(title);
    s = UNMFullWidthToHalf(s);
    s = s.lowercaseString;

    // Chinese "【tag】" is virtually always a descriptor: drop it outright.
    s = [s stringByReplacingOccurrencesOfString:@"【[^】]{0,40}】"
                                     withString:@""
                                        options:NSRegularExpressionSearch
                                          range:NSMakeRange(0, s.length)];

    // Bracketed descriptors: drop the group only when it looks like a tag.
    NSString *descriptor =
        @"(?i)(live|remaster|remastered|version|ver\\.|demo|karaoke|instrumental|"
         "acoustic|cover|remix|mix|edit|radio|mv|hd|hq|sq|hi-?res|lossless|"
         "现场|伴奏|纯音乐|翻自|翻唱|混音|重制|重置|完整版|高音质|无损|试听|片段|铃声|前奏|"
         "主题曲|插曲|片尾曲|片头曲|影视原声|电影|电视剧|ost)";
    s = [s stringByReplacingOccurrencesOfString:
         [NSString stringWithFormat:@"[\\(\\[\\{]\\s*%@[^\\)\\]\\}]{0,40}[\\)\\]\\}]", descriptor]
                                     withString:@""
                                        options:NSRegularExpressionSearch
                                          range:NSMakeRange(0, s.length)];

    // Cut everything from the featured-artist marker onwards.
    s = [s stringByReplacingOccurrencesOfString:@"(?i)\\s*(feat\\.?|ft\\.?|featuring)\\s+.*$"
                                     withString:@""
                                        options:NSRegularExpressionSearch
                                          range:NSMakeRange(0, s.length)];

    // Comparison key: keep letters/digits/CJK only.
    NSMutableString *key = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL keep = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                 || (c >= 0x4E00 && c <= 0x9FFF)   // CJK unified
                 || (c >= 0x3040 && c <= 0x30FF)   // kana
                 || (c >= 0xAC00 && c <= 0xD7AF);  // hangul
        if (keep) [key appendFormat:@"%C", c];
    }
    return key;
}

NSArray<NSString *> *UNMSplitArtists(NSString *artists) {
    if (![artists isKindOfClass:NSString.class] || artists.length == 0) return @[];
    NSString *s = UNMStripTags(artists);
    s = [s stringByReplacingOccurrencesOfString:@"(?i)\\s*(feat\\.?|ft\\.?|featuring)\\s+"
                                     withString:@"/"
                                        options:NSRegularExpressionSearch
                                          range:NSMakeRange(0, s.length)];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@"/、,，&;；|"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = UNMTrim(p);
        if (t.length) [out addObject:t.lowercaseString];
    }
    return out;
}

#pragma mark - Tolerant JSON

static NSString *UNMFixSingleQuotes(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c != '\'') {
            [out appendFormat:@"%C", c];
            continue;
        }
        // Decide whether this apostrophe acts as a JSON quote delimiter.
        NSUInteger j = i;
        while (j > 0 && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
                         characterIsMember:[s characterAtIndex:j - 1]]) j--;
        unichar prev = j > 0 ? [s characterAtIndex:j - 1] : '{';

        NSUInteger k = i + 1;
        while (k < n && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
                         characterIsMember:[s characterAtIndex:k]]) k++;
        unichar next = k < n ? [s characterAtIndex:k] : '}';

        BOOL prevIsDelim = (prev == '{' || prev == ',' || prev == '[' || prev == ':' || prev == '(');
        BOOL nextIsDelim = (next == ':' || next == ',' || next == '}' || next == ']' || next == ')');
        if (prevIsDelim || nextIsDelim) {
            [out appendString:@"\""];
        } else {
            [out appendString:@"'"];
        }
    }
    // Trailing commas are also common in these responses.
    NSString *fixed = [out stringByReplacingOccurrencesOfString:@",\\s*([\\}\\]])"
                                                    withString:@"$1"
                                                       options:NSRegularExpressionSearch
                                                         range:NSMakeRange(0, out.length)];
    return fixed;
}

id UNMJSONParse(NSData *data) {
    if (data.length == 0) return nil;

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (obj) return obj;

    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s.length) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!s.length) return nil;

    s = UNMTrim(s);
    if ([s hasPrefix:@"\uFEFF"]) s = [s substringFromIndex:1];
    // XSSI guard some endpoints prefix.
    if ([s hasPrefix:@")]}'"]) {
        NSRange nl = [s rangeOfString:@"\n"];
        if (nl.location != NSNotFound) s = [s substringFromIndex:nl.location + 1];
    }
    if ([s hasPrefix:@"for(;;);"]) s = [s substringFromIndex:8];

    NSData *d2 = [[UNMFixSingleQuotes(s) dataUsingEncoding:NSUTF8StringEncoding] copy];
    obj = [NSJSONSerialization JSONObjectWithData:d2 options:NSJSONReadingAllowFragments error:NULL];
    if (obj) return obj;

    // Last resort: some endpoints return a bare quoted string.
    return nil;
}

double UNMParseDuration(id raw) {
    if ([raw isKindOfClass:NSNumber.class]) {
        double v = [raw doubleValue];
        if (v <= 0) return -1;
        if (v > 7200) return v / 1000.0;   // looks like milliseconds
        return v;
    }
    if (![raw isKindOfClass:NSString.class]) return -1;

    NSString *s = UNMTrim((NSString *)raw);
    if (s.length == 0) return -1;

    NSArray *parts = [s componentsSeparatedByString:@":"];
    if (parts.count == 2 || parts.count == 3) {
        double total = 0;
        for (NSString *p in parts) {
            total = total * 60 + p.doubleValue;
        }
        return total > 0 ? total : -1;
    }
    double v = s.doubleValue;
    if (v <= 0) return -1;
    if (v > 7200) return v / 1000.0;
    return v;
}

NSString *UNMRegexFirst(NSString *s, NSString *pattern) {
    if (![s isKindOfClass:NSString.class] || s.length == 0) return nil;
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:0
                                                                         error:&err];
    if (!re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSRange r = [m rangeAtIndex:1];
    if (r.location == NSNotFound) return nil;
    return [s substringWithRange:r];
}

id UNMDictGet(NSDictionary *d, NSArray<NSString *> *keys) {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *k in keys) {
        id v = d[k];
        if (v && v != NSNull.null) return v;
    }
    return nil;
}

NSDictionary *UNMAsDict(id v) {
    return [v isKindOfClass:NSDictionary.class] ? (NSDictionary *)v : nil;
}

NSArray *UNMAsArray(id v) {
    return [v isKindOfClass:NSArray.class] ? (NSArray *)v : nil;
}

void UNMSetIvar(id object, NSString *name, id value) {
    if (object == nil || name.length == 0) return;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (ivar == NULL) return;
    object_setIvar(object, ivar, value);
}

void UNMSetIvarLongLong(id object, NSString *name, long long value) {
    if (object == nil || name.length == 0) return;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (ivar == NULL) return;
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (encoding == NULL) return;

    // Only touch integer-typed ivars; anything else would corrupt the object.
    if (encoding[0] != 'q' && encoding[0] != 'Q' && encoding[0] != 'l' &&
        encoding[0] != 'L' && encoding[0] != 'i' && encoding[0] != 'I') {
        return;
    }
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    switch (encoding[0]) {
        case 'q': *(int64_t *)(base + offset) = (int64_t)value; break;
        case 'Q': *(uint64_t *)(base + offset) = (uint64_t)value; break;
        case 'l': *(long *)(base + offset) = (long)value; break;
        case 'L': *(unsigned long *)(base + offset) = (unsigned long)value; break;
        case 'i': *(int32_t *)(base + offset) = (int32_t)value; break;
        case 'I': *(uint32_t *)(base + offset) = (uint32_t)value; break;
    }
}