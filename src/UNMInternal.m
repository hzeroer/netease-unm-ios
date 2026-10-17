//
//  UNMInternal.m
//

#import "UNMInternal.h"

NSString *const UNMUpstreamKey = @"com.hzeroer.unmios.upstream";

UNMEndpoint UNMEndpointForPath(NSString *path) {
    if (path.length == 0) return UNMEndpointNone;
    NSString *p = path.lowercaseString;

    // The list below mirrors the endpoints the reference implementation hooks.
    // Missing an endpoint is not a cosmetic bug: a client that reads its grey
    // state from /api/playlist/privilege, for instance, is completely unaffected
    // by rewriting /api/song/enhance/privilege, and the symptom is exactly
    // "intercepts > 0, rewrites == 0, songs still grey".

    // ---- the URL handed to the player / downloader
    if ([p containsString:@"/song/enhance/player/url"])    return UNMEndpointPlayerURL;
    if ([p containsString:@"/song/enhance/download/url"])  return UNMEndpointDownloadURL;
    if ([p containsString:@"/song/url"])                   return UNMEndpointPlayerURL;

    // ---- privilege: anything that decides whether a row looks playable
    if ([p containsString:@"/song/enhance/privilege"])     return UNMEndpointPrivilege;
    if ([p containsString:@"/playlist/privilege"])         return UNMEndpointPrivilege;
    if ([p containsString:@"/album/privilege"])            return UNMEndpointPrivilege;
    if ([p containsString:@"/artist/privilege"])           return UNMEndpointPrivilege;
    if ([p containsString:@"/listen/together/privilege"])  return UNMEndpointPrivilege;

    // ---- detail and list responses, which carry their own embedded privileges
    if ([p containsString:@"/song/detail"])                return UNMEndpointSongDetail;
    if ([p containsString:@"/playlist/detail"])            return UNMEndpointPlaylist;
    if ([p containsString:@"/playlist/v4/detail"])         return UNMEndpointPlaylist;
    if ([p containsString:@"/playlist/track/all"])         return UNMEndpointPlaylist;
    if ([p containsString:@"/playlist/manipulate/tracks"]) return UNMEndpointPlaylist;
    if ([p containsString:@"/album/v3/detail"])            return UNMEndpointPlaylist;
    if ([p containsString:@"/album/play"])                 return UNMEndpointPlaylist;
    if ([p containsString:@"/v1/album"])                   return UNMEndpointPlaylist;
    if ([p containsString:@"/v1/artist"])                  return UNMEndpointPlaylist;
    if ([p containsString:@"/v2/artist/songs"])            return UNMEndpointPlaylist;
    if ([p containsString:@"/artist/top/song"])            return UNMEndpointPlaylist;
    if ([p containsString:@"/playmode/intelligence/list"]) return UNMEndpointPlaylist;
    if ([p containsString:@"/discovery/recommend/songs"])  return UNMEndpointPlaylist;
    if ([p containsString:@"/v1/radio/get"])               return UNMEndpointPlaylist;
    if ([p containsString:@"/v1/play/record"])             return UNMEndpointPlaylist;
    if ([p containsString:@"/playmode/song"])              return UNMEndpointPlaylist;

    if ([p containsString:@"/search"])                     return UNMEndpointSearch;
    if ([p containsString:@"/cloudsearch"])                return UNMEndpointSearch;

    // Batched requests can wrap any of the above, so they are parsed and mined
    // for embedded privilege data even though nothing specific is rewritten.
    if ([p containsString:@"/batch"])                      return UNMEndpointOther;
    if ([p containsString:@"/song/enhance"])               return UNMEndpointOther;

    return UNMEndpointNone;
}

BOOL UNMEndpointIsRewritable(UNMEndpoint e) {
    return e == UNMEndpointPlayerURL || e == UNMEndpointDownloadURL || e == UNMEndpointPrivilege;
}

BOOL UNMEndpointIsIngestable(UNMEndpoint e) {
    switch (e) {
        case UNMEndpointPlayerURL:
        case UNMEndpointDownloadURL:
        case UNMEndpointPrivilege:
        case UNMEndpointSongDetail:
        case UNMEndpointPlaylist:
        case UNMEndpointSearch:
        case UNMEndpointOther:
            return YES;
        default:
            return NO;
    }
}

NSString *UNMEndpointName(UNMEndpoint e) {
    switch (e) {
        case UNMEndpointPlayerURL:   return @"player/url";
        case UNMEndpointDownloadURL: return @"download/url";
        case UNMEndpointPrivilege:   return @"privilege";
        case UNMEndpointSongDetail:  return @"song/detail";
        case UNMEndpointPlaylist:    return @"playlist/detail";
        case UNMEndpointSearch:      return @"search";
        case UNMEndpointOther:       return @"other";
        default:                     return @"none";
    }
}

BOOL UNMIsNeteaseHost(NSString *host) {
    if (host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h hasSuffix:@"music.163.com"]
        || [h hasSuffix:@"music.126.net"]
        || ([h hasSuffix:@"163.com"] && [h containsString:@"music"])
        || [h hasSuffix:@"netease.com"]
        || [h hasSuffix:@"music.163.com.cn"];
}

BOOL UNMIsNeteaseAPIHost(NSString *host) {
    if (host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    // Audio CDN hosts (m7xx.music.126.net) are deliberately excluded: the bodies
    // there are megabytes of audio and must never be buffered.
    if ([h hasSuffix:@".music.126.net"]) return NO;
    if ([h containsString:@"music.163.com"]) return YES;
    // api.iplay.163.com is the music client's older API host; it shows up in real
    // traffic and would otherwise be filtered out by the whitelist.
    if ([h containsString:@"iplay.163.com"]) return YES;
    if ([h hasSuffix:@".look.163.com"]) return YES;
    if ([h hasSuffix:@"netease.com"]) return YES;
    return NO;
}

/// A path signature that can only belong to the NetEase music API.
///
/// Needed because the client does not always address the API by name: its config
/// endpoint hands out server addresses, and requests then arrive with a bare IP in
/// the URL. A name-based whitelist misses those entirely, and the symptom is
/// "the client clearly streams audio, yet we never see it ask for a play URL".
/// The patterns here are specific enough that matching on the path alone is safe;
/// deliberately absent are generic ones like /batch.
BOOL UNMPathLooksLikeNeteaseAPI(NSString *path) {
    if (path.length == 0) return NO;
    NSString *p = path.lowercaseString;
    static NSArray<NSString *> *signatures = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        signatures = @[
            @"/song/enhance/",
            @"/playlist/privilege",
            @"/album/privilege",
            @"/artist/privilege",
            @"/listen/together/privilege",
            @"/song/detail",
            @"/playlist/detail",
            @"/cloudsearch",
            @"/song/url",
        ];
    });
    for (NSString *signature in signatures) {
        if ([p containsString:signature]) return YES;
    }
    return NO;
}
