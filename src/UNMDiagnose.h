//
//  UNMDiagnose.h
//
//  End-to-end self test: run a keyword through every configured source and
//  report, per source, whether the search answered and whether a playable URL
//  came back. This is what the in-app menu's "运行自检" button calls, and it is
//  the fastest way to tell "the plugin is broken" apart from "this one source is
//  down".
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMDiagnoseResult : NSObject
@property (nonatomic, copy) NSString *provider;
@property (nonatomic) BOOL searchOK;
@property (nonatomic) NSInteger candidateCount;
@property (nonatomic, copy, nullable) NSString *matchedTitle;
@property (nonatomic, copy, nullable) NSString *matchedArtist;
@property (nonatomic) double score;
@property (nonatomic, copy, nullable) NSString *url;
@property (nonatomic, copy, nullable) NSString *error;
@property (nonatomic) double searchMilliseconds;
@property (nonatomic) double resolveMilliseconds;
@end

@interface UNMDiagnose : NSObject

/// `keyword` is passed to the sources as-is, e.g. "晴天 周杰伦".
+ (void)runWithKeyword:(NSString *)keyword
            completion:(void (^)(NSArray<UNMDiagnoseResult *> *results,
                                 NSString *summary))completion;

/// Runs the test on a background queue; the completion fires on the main queue.
+ (void)runWithDefaultKeywordWithCompletion:(void (^)(NSArray<UNMDiagnoseResult *> *results,
                                                     NSString *summary))completion;

/// Turn on every diagnostic for `seconds`, then restore the previous settings and
/// hand back a report.
///
/// Exists because the interesting numbers live behind `logLevel` and
/// `discoveryMode`, and asking a user to edit a plist, restart, reproduce, and
/// extract a log is four chances to get it wrong. One tap, play a grey song, read
/// the result. The completion fires on the main queue.
+ (void)startCaptureWithSeconds:(NSTimeInterval)seconds
                     completion:(void (^)(NSString *report))completion;

@end

NS_ASSUME_NONNULL_END
