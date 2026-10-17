//
//  UNMInternal.h
//  Shared internals between the URL interceptor, the rewriter and the store.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSURLProtocol property used to mark our own outbound requests so the
/// interceptor never re-enters itself.
FOUNDATION_EXPORT NSString *const UNMUpstreamKey;

typedef NS_ENUM(NSInteger, UNMEndpoint) {
    UNMEndpointNone = 0,
    UNMEndpointPlayerURL,     // /song/enhance/player/url  (also /v1)
    UNMEndpointDownloadURL,   // /song/enhance/download/url (also /v1)
    UNMEndpointPrivilege,     // /song/enhance/privilege
    UNMEndpointSongDetail,    // /song/detail, /v3/song/detail ...
    UNMEndpointPlaylist,      // /playlist/detail, /v6/playlist/detail ...
    UNMEndpointSearch,        // /search/get, /cloudsearch/...
    UNMEndpointOther,
};

FOUNDATION_EXPORT UNMEndpoint UNMEndpointForPath(NSString *path);
FOUNDATION_EXPORT BOOL UNMEndpointIsRewritable(UNMEndpoint e);
FOUNDATION_EXPORT BOOL UNMEndpointIsIngestable(UNMEndpoint e);
FOUNDATION_EXPORT NSString *UNMEndpointName(UNMEndpoint e);

/// True for the API hosts we care about (*.music.163.com etc), never for audio CDN.
FOUNDATION_EXPORT BOOL UNMIsNeteaseAPIHost(NSString *host);
FOUNDATION_EXPORT BOOL UNMIsNeteaseHost(NSString *host);

/// True when a path can only belong to the NetEase music API, regardless of the
/// host it arrived on. Covers the case where the client talks to the API by bare
/// IP (its config endpoint hands out server addresses) and a name whitelist would
/// therefore never match.
FOUNDATION_EXPORT BOOL UNMPathLooksLikeNeteaseAPI(NSString *path);

NS_ASSUME_NONNULL_END
