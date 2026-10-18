//
//  UNMVersion.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bump on every build. A changed version is what makes the crash guard give a
/// fixed build a clean slate instead of leaving it disabled forever.
#define UNM_VERSION "2.8.5"

/// Shown in the panel and the startup banner.
#define UNM_AUTHOR   "hzeroer"

/// The tweak version, e.g. "2.8.5". Defined in UNMiOS.m.
FOUNDATION_EXPORT const char *UNMVersionString(void);

/// The author, shown in the panel footer and the startup banner.
FOUNDATION_EXPORT NSString *UNMAuthorString(void);

NS_ASSUME_NONNULL_END
