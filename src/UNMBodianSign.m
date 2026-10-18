#import "UNMBodianSign.h"

#import <CommonCrypto/CommonDigest.h>

static NSString *UNMBodianMD5Hex(NSString *input) {
    if (input.length == 0) return @"";
    unsigned char digest[CC_MD5_DIGEST_LENGTH] = {0};
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *UNMBodianSignedURLAtTimestamp(NSString *rawURL, long long millis) {
    if (rawURL.length == 0) return rawURL;

    NSString *stamped = [rawURL stringByAppendingFormat:@"&timestamp=%lld", millis];

    NSRange question = [stamped rangeOfString:@"?"];
    if (question.location == NSNotFound) return stamped;
    NSString *query = [stamped substringFromIndex:NSMaxRange(question)];

    // The service keeps only the alphanumerics of the query, sorts them as characters, and
    // hashes them with the literal "kuwotest" prefix plus the path. Verified byte-exact
    // against the signature the reference client itself sends.
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
    return [stamped stringByAppendingFormat:@"&sign=%@", UNMBodianMD5Hex(payload)];
}

NSString *UNMBodianSignedURL(NSString *rawURL) {
    // Wall-clock milliseconds, not uptime: the service compares them with its own clock.
    long long millis = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    return UNMBodianSignedURLAtTimestamp(rawURL, millis);
}
