//
//  UNMStore.h
//
//  Keeps the two pieces of state the plugin needs:
//    * songID -> metadata (name / artists / duration), harvested from the
//      responses the app already downloads,
//    * songID -> which third-party source matched it, so the (expensive)
//      search only ever runs once per song.
//
//  Everything is persisted inside the app sandbox, so it survives restarts
//  without needing a jailbreak path.
//

#import <Foundation/Foundation.h>
#import "UNMMatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface UNMStore : NSObject

+ (instancetype)shared;

/// Harvest song metadata from any parsed NetEase response body.
- (void)ingestJSON:(id)json;

- (void)setMeta:(UNMSongMeta *)meta;

/// Seed metadata from the client's own song object.
///
/// The model already knows the title and artist, so asking NetEase for them is a
/// wasted round trip -- and that round trip is most of the delay between tapping a
/// song and having a substitute URL ready. Only fills gaps: real metadata from a
/// response always wins.
- (void)seedMetaForID:(long long)songID
                 name:(NSString * _Nullable)name
               artist:(NSString * _Nullable)artist
                album:(NSString * _Nullable)album
             duration:(double)duration;
- (UNMSongMeta * _Nullable)metaForID:(long long)songID;

/// The cached match (provider + mediaId) for a song, when one exists.
- (NSDictionary * _Nullable)matchForID:(long long)songID;

/// A resolved URL that is still fresh, or nil. Instant: no network, no waiting.
///
/// Distinct from matchForID:, which records *which* candidate was chosen and has
/// no url field at all. Anything that wants to deliver a URL to the client must
/// read this one.
- (NSString * _Nullable)cachedURLForID:(long long)songID;

/// Blocking resolve: songID -> playable audio URL, or nil.
/// `deadline` is an absolute CFAbsoluteTime; the function never runs past it.
- (NSString * _Nullable)resolveID:(long long)songID deadline:(NSTimeInterval)deadline;

/// Resolve without blocking the caller (used to warm the cache ahead of play).
- (void)prefetchIDs:(NSArray<NSNumber *> *)songIDs;

- (void)flush;

- (NSString *)stats;

@end

NS_ASSUME_NONNULL_END
