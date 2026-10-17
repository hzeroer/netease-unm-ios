//
//  UNMModelHook.h
//
//  Un-greys songs by changing the client's own model objects.
//
//  Why this layer exists: on this client the play URL is not fetched by any
//  request the URL loading system can see. The timeline proves it -- the audio
//  stream is requested from the CDN in the same second the server mints the URL,
//  while the entire session layer carries nothing but clientlog traffic. Rewriting
//  responses therefore has nothing to act on.
//
//  What *is* reachable is the decision itself. `NMSongPrivilege.status` is the
//  API's `st` field, `fee`/`payed` decide the paid gate, `playMaxbr` is the
//  highest playable bitrate, and `NMSongUrlInfo` holds both the song id and the
//  URL -- so it is also the place a substitute URL can be delivered, without
//  needing to know where the original came from.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMModelHook : NSObject

/// Installs the hooks. Safe to call before the classes are loaded: unknown
/// classes and methods are skipped and logged, never guessed at.
+ (void)install;

/// How many of the model hooks are in place, and which classes were found.
+ (NSString *)statusText;

/// How often each decisive hook was actually entered. An installed hook proves
/// nothing: a read count of zero is what shows the client went a different way.
+ (NSString *)countersText;

/// What every link in the chain saw for the most recent song the client tried.
///
/// The client's own message is only "歌曲不存在"; this is what separates "no URL
/// found", "URL delivered but the client still refused", "playUrlInfo missing" and
/// "privilege still restricted".
+ (NSString *)lastAttemptText;

/// Synthesised privilege for a song that arrived without one (a grey song often
/// has no privilege object at all, and a nil one cannot be made playable).
+ (id _Nullable)synthesizedPrivilegeForSong:(id)song;

/// A substitute URL for the given NMSongUrlInfo, from a warm cache only.
/// Returns nil when nothing is cached, so the caller can leave the original alone.
+ (NSString * _Nullable)substituteURLForUrlInfo:(id)urlInfo;

/// A synthesised instance of the named class carrying the song's id, so a
/// substituted URL has somewhere to live when the client never created one.
+ (id _Nullable)synthesizedUrlInfoForClassNamed:(NSString *)className song:(id)song;

@end

NS_ASSUME_NONNULL_END
