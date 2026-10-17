//
//  UNMMatcher.h
//

#import <Foundation/Foundation.h>
#import "UNMProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// Metadata of the greyed-out NetEase song we are trying to replace.
@interface UNMSongMeta : NSObject
@property (nonatomic) long long songID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray<NSString *> *artists;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic) double duration;
@property (nonatomic, readonly) BOOL usable;   // has enough info to search
@end

@interface UNMMatcher : NSObject

/// Score a candidate against the target, 0.0 ... 1.0.
+ (double)scoreCandidate:(UNMCandidate *)candidate against:(UNMSongMeta *)meta;

/// Is this the same kind of recording as the target (studio / live / remix / ...)?
///
/// Used when the threshold is relaxed: matching may be loosened because a title is
/// spelled oddly, but the *kind* of recording must never be traded away -- a remix
/// is not an acceptable stand-in for the studio version just because nothing else
/// cleared the bar.
+ (BOOL)isFamilyCompatible:(UNMCandidate *)candidate withTarget:(UNMSongMeta *)meta;

/// How close the titles are, 0...1, independent of artist and duration.
///
/// Needed because the relaxed fallback threshold looks at the *total* score, and a
/// candidate by the same artist with an unrelated title still reaches 0.34 (0.34 is
/// exactly the artist weight). That is how 小幸运 came back as 一二三 -- same singer,
/// different song. Relaxing may forgive a spelling difference, never a different song.
+ (double)titleSimilarity:(UNMCandidate *)candidate withTarget:(UNMSongMeta *)meta;

/// Every acceptable candidate, best first.
///
/// A source often carries the same song several times -- one entry that needs a
/// purchase and another that does not. Trying only the top match means a paid entry
/// hides a free one behind it, which is exactly what happens with 《小幸运》 on KuGou.
+ (NSArray<UNMCandidate *> *)rankedCandidates:(NSArray<UNMCandidate *> *)candidates
                                    forTarget:(UNMSongMeta *)meta
                                    threshold:(double)threshold;

/// The same list, but willing to accept a different kind of recording.
///
/// Used only as a last resort, after every same-family candidate has failed to
/// produce a URL. BoDian is a case in point: the studio take of 《晴天》 is a paid
/// entry while the live take is free, so refusing variants outright would mean
/// playing nothing at all. A live version is worse than the studio one and far
/// better than silence, but only when silence is the alternative.
+ (NSArray<UNMCandidate *> *)relaxedCandidates:(NSArray<UNMCandidate *> *)candidates
                                     forTarget:(UNMSongMeta *)meta
                                     threshold:(double)threshold;

/// Best candidate above the configured threshold, or nil.
+ (UNMCandidate * _Nullable)best:(NSArray<UNMCandidate *> *)candidates
                       forTarget:(UNMSongMeta *)meta
                       threshold:(double)threshold;

/// The query string handed to a source search endpoint.
+ (NSString *)searchKeywordForMeta:(UNMSongMeta *)meta;

/// Duration tolerance in seconds, taken from the live config.
+ (double)durationTolerance;

@end

NS_ASSUME_NONNULL_END
