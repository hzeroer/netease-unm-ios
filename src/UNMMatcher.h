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
