//
//  UNMValidate.h
//
//  Does a candidate URL actually serve audio?
//
//  KuWo answers some tracks with a plain-text notice -- "当前仅在酷我手机端播放" --
//  instead of a stream. Delivering that to the player yields a song that simply
//  will not play, with nothing in the UI to say why, so candidates are probed
//  before they are used.
//
//  The probe is a small Range request: cheap, and it needs no parsing of the
//  container. The judgement is deliberately conservative -- reject anything that
//  is clearly a message, accept anything that is clearly a stream, and when the
//  answer is ambiguous prefer the candidate rather than silently losing a source.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when the URL looks like it serves audio. Never network-free: it performs
/// one request, so call it from a background queue.
FOUNDATION_EXPORT BOOL UNMURLServesAudio(NSString * _Nullable url, NSTimeInterval timeout);

/// The last few rejections, for the diagnostics report.
FOUNDATION_EXPORT NSArray<NSString *> *UNMValidationLog(void);
FOUNDATION_EXPORT void UNMValidationReset(void);

NS_ASSUME_NONNULL_END
