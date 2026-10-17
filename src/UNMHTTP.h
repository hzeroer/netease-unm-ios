//
//  UNMHTTP.h
//
//  Tiny self-contained HTTP client used to talk to the third-party music
//  sources from inside the app process.
//
//  Two transports:
//    * NSURLSession  - the normal path, reuses the app's TLS stack.
//    * raw sockets   - fallback for plain http:// endpoints when App Transport
//                      Security in the host app's Info.plist blocks them.
//                      (No TLS involved, so nothing extra needs to be linked.)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMHTTPResult : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong, nullable) NSData *body;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic) BOOL usedRawSocket;

- (NSString *)text;
- (id _Nullable)json;
@end

@interface UNMHTTP : NSObject

/// Synchronous GET. Safe to call from a background queue; never call it on the
/// main thread. Returns nil only when the request could not be attempted.
+ (UNMHTTPResult * _Nullable)GET:(NSString *)url
                        headers:(NSDictionary<NSString *, NSString *> * _Nullable)headers
                        timeout:(NSTimeInterval)timeout;

/// Synchronous POST with an application/x-www-form-urlencoded body.
+ (UNMHTTPResult * _Nullable)POST:(NSString *)url
                             form:(NSDictionary<NSString *, NSString *> * _Nullable)form
                          headers:(NSDictionary<NSString *, NSString *> * _Nullable)headers
                          timeout:(NSTimeInterval)timeout;

/// Raw body POST with an explicit content type (some sources want JSON).
+ (UNMHTTPResult * _Nullable)POST:(NSString *)url
                             body:(NSData * _Nullable)body
                      contentType:(NSString * _Nullable)contentType
                          headers:(NSDictionary<NSString *, NSString *> * _Nullable)headers
                          timeout:(NSTimeInterval)timeout;

/// Async GET, used for prefetching where blocking would be pointless.
+ (void)GETAsync:(NSString *)url
         headers:(NSDictionary<NSString *, NSString *> * _Nullable)headers
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(UNMHTTPResult * _Nullable result))completion;

@end

NS_ASSUME_NONNULL_END
