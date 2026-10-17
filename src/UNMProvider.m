//
//  UNMProvider.m
//

#import "UNMProvider.h"
#import "UNMConfig.h"
#import "UNMUtil.h"

@implementation UNMCandidate

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ - %@ dur=%.0f id=%@ score=%.2f>",
            self.provider, self.artist, self.title, self.duration, self.mediaId, self.score];
}

@end

static NSMutableDictionary<NSString *, Class> *gProviders = nil;
static NSMutableArray<NSString *> *gOrder = nil;

void UNMRegisterProvider(Class providerClass) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gProviders = [NSMutableDictionary dictionary];
        gOrder = [NSMutableArray array];
    });

    if (![providerClass respondsToSelector:@selector(providerKey)]) return;
    NSString *key = [providerClass providerKey];
    if (key.length == 0) return;
    if (gProviders[key]) return;

    gProviders[key] = providerClass;
    [gOrder addObject:key];
}

NSArray<NSString *> *UNMRegisteredProviderKeys(void) {
    return gOrder ? [gOrder copy] : @[];
}

id<UNMProvider> UNMProviderForKey(NSString *key) {
    if (![key isKindOfClass:NSString.class] || key.length == 0) return nil;
    Class cls = gProviders[key.lowercaseString];
    if (!cls) return nil;
    return [[cls alloc] init];
}

NSString *UNMProviderCookie(NSString *providerKey) {
    if (providerKey.length == 0) return nil;
    NSString *cookie = [UNMConfig shared].providerCookies[providerKey.lowercaseString];
    return cookie.length ? cookie : nil;
}
