//
//  UNMRuntimeDump.h
//
//  Runtime introspection of the host app's own classes.
//
//  The play URL turns out to arrive over a channel that never shows up as an
//  observable HTTP request, so there is nothing left to rewrite on the response
//  path. What is still reachable is the client's own decision "this song is not
//  playable": that lives in the app's model objects, and the classes holding it
//  can be found by asking the ObjC runtime -- no hooks, no system functions
//  replaced, nothing that can destabilise the process.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMRuntimeDump : NSObject

/// Class names, property names and ivar names of the host app's own classes that
/// look related to songs, privileges and playback. Bounded in size.
+ (NSString *)modelDump;

/// Classes that carry the fields deciding whether a song is playable.
///
/// Matched on *member* names rather than class names, because that is what
/// actually matters: whichever class holds `privilege`, `fee`, `playable`, `st`,
/// `pl` or `dl` is the class worth changing. Class-name matching surfaced nothing
/// but peripheral Swift modules and filled the output cap before reaching the
/// core models.
+ (NSString *)privilegeModelDump;

/// Every property, ivar and instance method of the named classes, including
/// inherited members.
///
/// The member-name scan identified the models (`NMSong`, `NMSongPrivilege`,
/// `NMSongUrlInfo`); this is what is needed to actually write the hook against
/// them, because the accessor names are what get replaced.
+ (NSString *)detailDumpForClasses:(NSArray<NSString *> *)classNames;

/// The detail dump for the classes the member scan identified as the ones holding
/// song, privilege and play-URL state.
+ (NSString *)keyModelDetailDump;

/// Every image the process has loaded, so the app's own frameworks are visible.
+ (NSString *)imageDump;

@end

NS_ASSUME_NONNULL_END
