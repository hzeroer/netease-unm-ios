#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// KuWo's request signature, extracted so the unit test can pin it against a recorded vector.
///
/// The provider used to keep this as a static function that stamped the current time itself,
/// which made it untestable and left the test target referencing a header that did not exist.
/// Taking the timestamp as an argument keeps the algorithm honest and lets CI verify it.
NSString *UNMBodianSignedURLAtTimestamp(NSString *rawURL, long long millis);

/// Same signature, stamped with the current wall-clock time.
NSString *UNMBodianSignedURL(NSString *rawURL);

NS_ASSUME_NONNULL_END
