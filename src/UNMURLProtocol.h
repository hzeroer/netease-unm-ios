//
//  UNMURLProtocol.h
//
//  In-process interception of the host app's own HTTP traffic.
//
//  Because the dylib lives inside the NetEase Cloud Music process, the bodies
//  we see are already decrypted by the app's TLS stack. That is the entire
//  reason this design needs no proxy, no local server and no CA certificate.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMURLProtocol : NSURLProtocol
@end

/// Install the interceptor:
///   * register the NSURLProtocol subclass,
///   * make every NSURLSessionConfiguration hand it out through -protocolClasses.
FOUNDATION_EXPORT void UNMInstallInterceptor(void);

NS_ASSUME_NONNULL_END
