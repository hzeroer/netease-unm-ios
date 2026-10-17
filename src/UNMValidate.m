//
//  UNMValidate.m
//

#import "UNMValidate.h"
#import "UNMHTTP.h"
#import "UNMLog.h"
#import "UNMStats.h"
#import "UNMUtil.h"

static NSMutableArray<NSString *> *gRejections = nil;
static NSLock *gRejectionLock = nil;

static void UNMRecordRejection(NSString *reason, NSString *url) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRejections = [NSMutableArray array];
        gRejectionLock = [[NSLock alloc] init];
    });

    // Keep enough of the URL to recognise the host and the tail, but not a wall
    // of query string.
    NSString *short_ = url.length > 80 ? [url substringFromIndex:url.length - 80] : url;
    NSString *line = [NSString stringWithFormat:@"%@  …%@", reason, short_];

    [gRejectionLock lock];
    [gRejections addObject:line];
    while (gRejections.count > 20) [gRejections removeObjectAtIndex:0];
    [gRejectionLock unlock];

    UNMLogW(@"[validate] 拒绝候选链接：%@", line);
    [[UNMStats shared] addEvent:[NSString stringWithFormat:@"拒绝链接：%@", reason]];
}

NSArray<NSString *> *UNMValidationLog(void) {
    if (!gRejections) return @[];
    [gRejectionLock lock];
    NSArray *copy = [gRejections copy];
    [gRejectionLock unlock];
    return copy;
}

void UNMValidationReset(void) {
    if (!gRejections) return;
    [gRejectionLock lock];
    [gRejections removeAllObjects];
    [gRejectionLock unlock];
}

BOOL UNMURLServesAudio(NSString *url, NSTimeInterval timeout) {
    if (url.length == 0) return NO;
    if (timeout <= 0.2) return YES;   // no budget to probe: keep the candidate

    // A neutral player-like request: no Referer, because sending the web referer
    // can make the CDN answer differently than it will for the app's own player.
    NSDictionary<NSString *, NSString *> *headers = @{
        @"Range" : @"bytes=0-1023",
        @"User-Agent" : @"Mozilla/5.0",
        @"Accept" : @"*/*",
    };

    UNMHTTPResult *result = [UNMHTTP GET:url headers:headers timeout:MIN(timeout, 0.6)];
    if (result == nil) {
        UNMRecordRejection(@"请求失败", url);
        return NO;
    }
    if (result.status >= 400) {
        UNMRecordRejection([NSString stringWithFormat:@"HTTP %ld", (long)result.status], url);
        return NO;
    }

    // Content type is the strongest signal when the server sends one.
    NSString *contentType = nil;
    for (NSString *key in result.headers) {
        if ([key.lowercaseString isEqualToString:@"content-type"]) {
            contentType = [result.headers[key] lowercaseString];
            break;
        }
    }
    if (contentType.length) {
        if ([contentType hasPrefix:@"audio/"] ||
            [contentType containsString:@"octet-stream"] ||
            [contentType containsString:@"mpegurl"] ||
            [contentType containsString:@"video/"]) {
            return YES;
        }
        if ([contentType hasPrefix:@"text/"] ||
            [contentType containsString:@"json"] ||
            [contentType containsString:@"html"] ||
            [contentType containsString:@"xml"]) {
            UNMRecordRejection([NSString stringWithFormat:@"Content-Type 是 %@", contentType], url);
            return NO;
        }
    }

    NSData *body = result.body;
    if (body.length == 0) {
        UNMRecordRejection(@"响应为空", url);
        return NO;
    }

    // A refusal notice is short. Anything under half a kilobyte that is not
    // labelled as audio is a message, whatever it says.
    if (body.length < 512 && contentType.length == 0) {
        UNMRecordRejection(@"响应过短，不像音频", url);
        return NO;
    }

    // No usable content type: judge the first bytes. Real audio either fails to
    // decode as text (so this is skipped) or starts with an ID3 tag.
    NSUInteger probeLength = MIN(body.length, (NSUInteger)256);
    NSString *head = [[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(0, probeLength)]
                                           encoding:NSUTF8StringEncoding];
    if (head.length > 0) {
        if ([head hasPrefix:@"ID3"]) return YES;
        if ([head hasPrefix:@"{"] || [head hasPrefix:@"<"] || [head hasPrefix:@"["]) {
            UNMRecordRejection(@"响应是 JSON/HTML", url);
            return NO;
        }
        NSArray<NSString *> *messages = @[ @"手机端", @"仅在", @"无法", @"试听", @"会员",
                                           @"VIP", @"vip", @"error", @"Error", @"forbidden" ];
        for (NSString *message in messages) {
            if ([head containsString:message]) {
                UNMRecordRejection([NSString stringWithFormat:@"响应提到「%@」", message], url);
                return NO;
            }
        }
        // Plain readable text with no marker either way: treat as a message.
        UNMRecordRejection(@"响应是可读文本", url);
        return NO;
    }

    return YES;
}
