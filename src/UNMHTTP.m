//
//  UNMHTTP.m
//

#import "UNMHTTP.h"
#import "UNMInternal.h"
#import "UNMLog.h"
#import "UNMUtil.h"

#import <sys/socket.h>
#import <sys/types.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

static NSString *const kUNMUA =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    @"AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";

#pragma mark - Result

@implementation UNMHTTPResult

- (NSString *)text {
    if (!self.body.length) return @"";

    NSString *charset = nil;
    for (NSString *key in self.headers) {
        if ([key.lowercaseString isEqualToString:@"content-type"]) {
            NSString *v = self.headers[key];
            NSString *cs = UNMRegexFirst(v, @"(?i)charset=\"?([a-z0-9_\\-]+)");
            if (cs.length) charset = cs.lowercaseString;
        }
    }

    if ([charset containsString:@"gb"] || [charset containsString:@"gbk"]) {
        NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        NSString *s = [[NSString alloc] initWithData:self.body encoding:gb];
        if (s) return s;
    }
    NSString *s = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    if (s) return s;

    NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    s = [[NSString alloc] initWithData:self.body encoding:gb];
    if (s) return s;

    return [[NSString alloc] initWithData:self.body encoding:NSISOLatin1StringEncoding] ?: @"";
}

- (id)json {
    return UNMJSONParse(self.body);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<UNMHTTPResult %ld bytes=%lu raw=%d err=%@>",
            (long)self.status, (unsigned long)self.body.length, self.usedRawSocket,
            self.error.localizedDescription ?: @"-"];
}

@end

#pragma mark - Raw socket transport (http:// only, immune to App Transport Security)

static BOOL UNMSetNonBlocking(int fd, BOOL nonblock) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return NO;
    if (nonblock) flags |= O_NONBLOCK; else flags &= ~O_NONBLOCK;
    return fcntl(fd, F_SETFL, flags) == 0;
}

static int UNMConnect(NSString *host, int port, NSTimeInterval timeout) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *res = NULL;
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", port);
    if (getaddrinfo(host.UTF8String, portStr, &hints, &res) != 0 || !res) return -1;

    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;

        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        UNMSetNonBlocking(s, YES);

        int rc = connect(s, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) {
            UNMSetNonBlocking(s, NO);
            fd = s;
            break;
        }
        if (errno != EINPROGRESS) { close(s); continue; }

        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(s, &wset);
        struct timeval tv;
        tv.tv_sec = (time_t)timeout;
        tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1e6);
        rc = select(s + 1, NULL, &wset, NULL, &tv);
        if (rc <= 0) { close(s); continue; }

        int soerr = 0;
        socklen_t len = sizeof(soerr);
        getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &len);
        if (soerr != 0) { close(s); continue; }

        UNMSetNonBlocking(s, NO);
        fd = s;
        break;
    }
    freeaddrinfo(res);

    if (fd >= 0) {
        struct timeval tv;
        tv.tv_sec = (time_t)timeout;
        tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1e6);
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    }
    return fd;
}

static BOOL UNMSendAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            return NO;
        }
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static NSData *UNMRawReadAll(int fd) {
    NSMutableData *out = [NSMutableData data];
    uint8_t buf[16384];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n > 0) {
            [out appendBytes:buf length:(NSUInteger)n];
            continue;
        }
        if (n == 0) break;
        if (errno == EINTR) continue;
        break;   // EAGAIN/timeout or hard error
    }
    return out;
}

static NSData *UNMDecodeChunked(NSData *raw) {
    NSMutableData *out = [NSMutableData data];
    const uint8_t *p = raw.bytes;
    NSUInteger n = raw.length, i = 0;

    while (i < n) {
        NSUInteger lineEnd = i;
        while (lineEnd + 1 < n && !(p[lineEnd] == '\r' && p[lineEnd + 1] == '\n')) lineEnd++;
        if (lineEnd + 1 >= n) break;

        NSData *lineData = [NSData dataWithBytes:p + i length:lineEnd - i];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        NSString *sizeHex = [[line componentsSeparatedByString:@";"].firstObject
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        unsigned long long size = strtoull(sizeHex.UTF8String, NULL, 16);
        i = lineEnd + 2;

        if (size == 0) break;
        if (i + size > n) size = n - i;
        [out appendBytes:p + i length:(NSUInteger)size];
        i += (NSUInteger)size + 2;   // skip payload and trailing CRLF
    }
    return out;
}

static NSData *UNMRawHTTP(NSString *url, NSString *method, NSData *body,
                          NSDictionary<NSString *, NSString *> *extraHeaders,
                          NSTimeInterval timeout,
                          NSInteger *outStatus,
                          NSDictionary<NSString *, NSString *> *__strong *outHeaders) {
    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    if (!c.host.length) return nil;
    if (![c.scheme.lowercaseString isEqualToString:@"http"]) return nil;

    int port = c.port ? c.port.intValue : 80;
    NSString *path = c.percentEncodedPath.length ? c.percentEncodedPath : @"/";
    if (c.percentEncodedQuery.length) path = [path stringByAppendingFormat:@"?%@", c.percentEncodedQuery];

    int fd = UNMConnect(c.host, port, timeout);
    if (fd < 0) return nil;

    // Merge headers case-insensitively, with caller-supplied values overriding
    // the defaults.
    //
    // This used to append every extra header after the defaults, so a caller that
    // passed "user-agent" or "host" (as the BoDian provider does, mirroring the
    // app's own header names) produced the header twice. Strict gateways reject a
    // request carrying two Host headers outright, which is exactly the endpoint
    // that was failing on device while passing on the desktop -- PowerShell
    // happens to de-duplicate them for you.
    NSMutableDictionary<NSString *, NSString *> *merged = [NSMutableDictionary dictionary];
    merged[@"host"] = c.host;
    merged[@"user-agent"] = kUNMUA;
    merged[@"accept"] = @"*/*";
    merged[@"accept-encoding"] = @"identity";
    merged[@"connection"] = @"close";
    for (NSString *key in extraHeaders) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSString *value = extraHeaders[key];
        if (![value isKindOfClass:NSString.class]) continue;
        merged[key.lowercaseString] = value;
    }
    if (body) merged[@"content-length"] = @(body.length).stringValue;

    NSDictionary<NSString *, NSString *> *canonicalNames = @{
        @"host" : @"Host",
        @"user-agent" : @"User-Agent",
        @"accept" : @"Accept",
        @"accept-encoding" : @"Accept-Encoding",
        @"connection" : @"Connection",
        @"content-length" : @"Content-Length",
        @"content-type" : @"Content-Type",
    };
    NSArray<NSString *> *firstKeys = @[ @"host", @"user-agent", @"accept",
                                        @"accept-encoding", @"connection" ];

    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"%@ %@ HTTP/1.1\r\n", method, path];
    for (NSString *key in firstKeys) {
        NSString *value = merged[key];
        if (value.length) [head appendFormat:@"%@: %@\r\n", canonicalNames[key], value];
    }
    for (NSString *key in merged) {
        if ([firstKeys containsObject:key]) continue;
        [head appendFormat:@"%@: %@\r\n", canonicalNames[key] ?: key, merged[key]];
    }
    [head appendString:@"\r\n"];

    NSMutableData *wire = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [wire appendData:body];

    if (!UNMSendAll(fd, wire.bytes, wire.length)) { close(fd); return nil; }

    NSData *raw = UNMRawReadAll(fd);
    close(fd);
    if (!raw.length) return nil;

    // Split head / body.
    NSRange sep = [raw rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             range:NSMakeRange(0, raw.length)];
    if (sep.location == NSNotFound) return nil;

    NSData *headData = [raw subdataWithRange:NSMakeRange(0, sep.location)];
    NSData *bodyData = [raw subdataWithRange:NSMakeRange(sep.location + 4, raw.length - sep.location - 4)];

    NSString *headStr = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    if (!headStr) return nil;
    NSArray<NSString *> *lines = [headStr componentsSeparatedByString:@"\r\n"];
    if (!lines.count) return nil;

    NSArray *statusParts = [lines.firstObject componentsSeparatedByString:@" "];
    NSInteger status = statusParts.count >= 2 ? [statusParts[1] integerValue] : 0;

    NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *k = UNMTrim([lines[i] substringToIndex:colon.location]).lowercaseString;
        NSString *v = UNMTrim([lines[i] substringFromIndex:colon.location + 1]);
        if (k.length && v.length) hdrs[k] = v;
    }

    if ([hdrs[@"transfer-encoding"] containsString:@"chunked"]) {
        bodyData = UNMDecodeChunked(bodyData);
    } else if (hdrs[@"content-length"]) {
        unsigned long long want = strtoull([hdrs[@"content-length"] UTF8String], NULL, 10);
        if (want > 0 && bodyData.length > want) {
            bodyData = [bodyData subdataWithRange:NSMakeRange(0, (NSUInteger)want)];
        }
    }

    if (outStatus) *outStatus = status;
    if (outHeaders) *outHeaders = hdrs;
    return bodyData;
}

#pragma mark - NSURLSession transport

static NSURLSession *UNMUpstreamSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 8;
        cfg.timeoutIntervalForResource = 12;
        cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        cfg.HTTPShouldSetCookies = NO;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];
    });
    return session;
}

/// Marks a request so the interceptor in UNMURLProtocol ignores it.
static NSMutableURLRequest *UNMMarkUpstream(NSString *url, NSString *method,
                                           NSDictionary<NSString *, NSString *> *headers,
                                           NSTimeInterval timeout) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = timeout;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    [req setValue:kUNMUA forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
    [NSURLProtocol setProperty:@YES forKey:UNMUpstreamKey inRequest:req];
    return req;
}

static UNMHTTPResult *UNMRunSync(NSMutableURLRequest *req, NSTimeInterval timeout) {
    __block UNMHTTPResult *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task =
        [UNMUpstreamSession() dataTaskWithRequest:req
                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UNMHTTPResult *r = [UNMHTTPResult new];
            if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                r.status = http.statusCode;
                r.headers = http.allHeaderFields;
            }
            r.body = data;
            r.error = error;
            result = r;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];

    int64_t ns = (int64_t)(MAX(timeout, 0.5) * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, ns)) != 0) {
        [task cancel];
        UNMLogD(@"http timeout %@", req.URL.absoluteString);
        return nil;
    }
    return result;
}

#pragma mark - Public

@implementation UNMHTTP

+ (UNMHTTPResult *)GET:(NSString *)url
               headers:(NSDictionary<NSString *, NSString *> *)headers
               timeout:(NSTimeInterval)timeout {
    if (url.length == 0) return nil;
    timeout = MAX(timeout, 0.5);

    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    BOOL isPlainHTTP = [c.scheme.lowercaseString isEqualToString:@"http"];

    // Plain http first goes over a raw socket: this sidesteps App Transport
    // Security in the host app entirely and adds no certificate requirements.
    if (isPlainHTTP) {
        NSInteger status = 0;
        NSDictionary<NSString *, NSString *> *hdrs = nil;
        NSData *body = UNMRawHTTP(url, @"GET", nil, headers, timeout, &status, &hdrs);
        if (body && status >= 200 && status < 400) {
            UNMHTTPResult *r = [UNMHTTPResult new];
            r.status = status;
            r.headers = hdrs;
            r.body = body;
            r.usedRawSocket = YES;
            return r;
        }
        UNMLogD(@"raw GET miss (%@) -> NSURLSession", url);
    }

    NSMutableURLRequest *req = UNMMarkUpstream(url, @"GET", headers, timeout);
    return UNMRunSync(req, timeout);
}

+ (UNMHTTPResult *)POST:(NSString *)url
                   body:(NSData *)body
            contentType:(NSString *)contentType
                headers:(NSDictionary<NSString *, NSString *> *)headers
                timeout:(NSTimeInterval)timeout {
    if (url.length == 0) return nil;
    timeout = MAX(timeout, 0.5);

    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    if (contentType.length) h[@"Content-Type"] = contentType;

    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    if ([c.scheme.lowercaseString isEqualToString:@"http"]) {
        NSInteger status = 0;
        NSDictionary<NSString *, NSString *> *hdrs = nil;
        NSData *resp = UNMRawHTTP(url, @"POST", body, h, timeout, &status, &hdrs);
        if (resp && status >= 200 && status < 400) {
            UNMHTTPResult *r = [UNMHTTPResult new];
            r.status = status;
            r.headers = hdrs;
            r.body = resp;
            r.usedRawSocket = YES;
            return r;
        }
    }

    NSMutableURLRequest *req = UNMMarkUpstream(url, @"POST", h, timeout);
    req.HTTPBody = body;
    return UNMRunSync(req, timeout);
}

+ (UNMHTTPResult *)POST:(NSString *)url
                   form:(NSDictionary<NSString *, NSString *> *)form
                headers:(NSDictionary<NSString *, NSString *> *)headers
                timeout:(NSTimeInterval)timeout {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *k in form) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", UNMURLEncode(k), UNMURLEncode(form[k])]];
    }
    NSData *body = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    return [self POST:url body:body
          contentType:@"application/x-www-form-urlencoded"
              headers:headers
              timeout:timeout];
}

+ (void)GETAsync:(NSString *)url
         headers:(NSDictionary<NSString *, NSString *> *)headers
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(UNMHTTPResult *))completion {
    if (url.length == 0 || !completion) return;

    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    if ([c.scheme.lowercaseString isEqualToString:@"http"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion([self GET:url headers:headers timeout:timeout]);
        });
        return;
    }

    NSMutableURLRequest *req = UNMMarkUpstream(url, @"GET", headers, timeout);
    [[UNMUpstreamSession() dataTaskWithRequest:req
                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UNMHTTPResult *r = [UNMHTTPResult new];
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            r.status = http.statusCode;
            r.headers = http.allHeaderFields;
        }
        r.body = data;
        r.error = error;
        completion(r);
    }] resume];
}

@end
