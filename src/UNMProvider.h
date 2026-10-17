//
//  UNMProvider.h
//
//  A "source" is one third-party music service we can borrow an audio URL from.
//  Everything happens from inside the app process: plain HTTPS/HTTP calls to
//  public endpoints, no proxy, no local server, no certificates.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A candidate returned by a source search.
@interface UNMCandidate : NSObject
@property (nonatomic, copy) NSString *provider;     // "kuwo" / "kugou" / "migu"
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic) double duration;              // seconds, -1 when unknown
@property (nonatomic, copy) NSString *mediaId;      // provider-specific id
@property (nonatomic, copy, nullable) NSDictionary *extra;  // hashes, flags ...
@property (nonatomic) double score;                 // filled in by the matcher
@end

@protocol UNMProvider <NSObject>

+ (NSString *)providerKey;

/// Search the source. Returns candidates; must not throw, may return @[].
- (NSArray<UNMCandidate *> *)search:(NSString *)keyword timeout:(NSTimeInterval)timeout;

/// Turn a candidate into a directly playable audio URL. nil when unavailable.
- (NSString * _Nullable)resolveURL:(UNMCandidate *)candidate timeout:(NSTimeInterval)timeout;

@end

FOUNDATION_EXPORT NSArray<NSString *> *UNMRegisteredProviderKeys(void);
FOUNDATION_EXPORT id<UNMProvider> _Nullable UNMProviderForKey(NSString *key);
FOUNDATION_EXPORT void UNMRegisterProvider(Class providerClass);

/// Optional user-supplied cookie for a source ("migu", "kugou", "kuwo" ...).
/// MiGu and KuGou refuse to hand out a play URL to an anonymous caller, so
/// without one of these those sources simply report "no match".
FOUNDATION_EXPORT NSString * _Nullable UNMProviderCookie(NSString *providerKey);

NS_ASSUME_NONNULL_END
