//
//  UNMLog.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, UNMLogLevel) {
    UNMLogOff = 0,
    UNMLogError = 1,
    UNMLogWarn = 2,
    UNMLogInfo = 3,
    UNMLogDebug = 4,
};

FOUNDATION_EXPORT void UNMLogSetLevel(UNMLogLevel level);
FOUNDATION_EXPORT UNMLogLevel UNMLogGetLevel(void);

FOUNDATION_EXPORT void UNMLogv(UNMLogLevel level, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

#define UNMLogE(...) UNMLogv(UNMLogError, __VA_ARGS__)
#define UNMLogW(...) UNMLogv(UNMLogWarn,  __VA_ARGS__)
#define UNMLogI(...) UNMLogv(UNMLogInfo,  __VA_ARGS__)
#define UNMLogD(...) UNMLogv(UNMLogDebug, __VA_ARGS__)

/// Discovery mode: log every intercepted request, and (once) dump the app's
/// private classes so the real hook point can be identified on a new app build.
FOUNDATION_EXPORT void UNMLogSetDiscovery(BOOL on);
FOUNDATION_EXPORT BOOL UNMLogDiscovery(void);

/// Absolute path of the on-disk log inside the app sandbox.
FOUNDATION_EXPORT NSString *UNMLogFilePath(void);

/// Append a raw line without level filtering (used for discovery dumps).
FOUNDATION_EXPORT void UNMLogRaw(NSString *line);

NS_ASSUME_NONNULL_END
