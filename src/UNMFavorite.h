#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Favouriting a song through the "我喜欢的音乐" playlist instead of /eapi/song/like.
///
/// The like endpoint answers 401 "下架歌曲无法收藏" for anything the catalogue has delisted, and
/// no client-side change alters that. The playlist endpoint is a different code path with a
/// looser check, so this module follows the route the Android tweak uses: find the liked
/// playlist, then add the track to it with the plain (non-eapi) API.
@interface UNMFavorite : NSObject

/// The song the player last started. Recorded from NMSong -setPlayUrlInfo:, which fires for
/// every song including the ones that already play.
+ (void)rememberSongId:(long long)songId name:(nullable NSString *)name;
+ (long long)currentSongId;
+ (nullable NSString *)currentSongName;

/// Resolves the liked playlist and adds the current song to it, off the main thread.
/// The completion gets a human-readable report of every step, for the menu dialog.
+ (void)favoriteCurrentSongWithCompletion:(void (^)(BOOL ok, NSString *report))completion;

/// Playlists this account can add to (its own, not subscriptions), for the picker.
+ (void)loadEditablePlaylistsWithCompletion:(void (^)(NSArray<NSDictionary *> *items, NSString *report))completion;

@end

NS_ASSUME_NONNULL_END
