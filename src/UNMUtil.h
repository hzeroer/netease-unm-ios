//
//  UNMUtil.h
//  Small pure-ObjC helpers: hashing, URL encoding, title/artist normalisation,
//  and a tolerant JSON parser for the sloppy JSON some music APIs return.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *UNMMD5(NSString *input);
FOUNDATION_EXPORT NSString *UNMURLEncode(NSString *input);

/// Trim, collapse whitespace, strip control characters.
FOUNDATION_EXPORT NSString *UNMTrim(NSString *s);

/// Normalise a song title for fuzzy comparison:
/// full-width -> half-width, lowercase, drop bracketed suffixes such as
/// "(Live)", "[Remastered]", "【纯音乐】", "feat. X", "伴奏", quality tags.
FOUNDATION_EXPORT NSString *UNMNormalizeTitle(NSString *title);

/// Split an artist string ("A / B", "A、B", "A & B", "A feat. B") into parts.
FOUNDATION_EXPORT NSArray<NSString *> *UNMSplitArtists(NSString *artists);

/// Strip the "<em>" highlighting that some search APIs inject.
FOUNDATION_EXPORT NSString *UNMStripTags(NSString *s);

/// Tolerant JSON parse. Handles a UTF-8 BOM, a leading ")]}'," XSSI guard and
/// single-quoted keys/values, which real-world music APIs still emit.
FOUNDATION_EXPORT id _Nullable UNMJSONParse(NSData *data);

/// Parse "00:03:45" or "225" or 225.0 into seconds. Returns -1 when unknown.
FOUNDATION_EXPORT double UNMParseDuration(id raw);

/// First capture group of the first regex match, or nil.
FOUNDATION_EXPORT NSString * _Nullable UNMRegexFirst(NSString *s, NSString *pattern);

/// Value lookup that accepts several alternative keys.
FOUNDATION_EXPORT id _Nullable UNMDictGet(NSDictionary *d, NSArray<NSString *> *keys);

/// Convert a JSON value to a dictionary/array only when it really is one.
FOUNDATION_EXPORT NSDictionary * _Nullable UNMAsDict(id v);
FOUNDATION_EXPORT NSArray * _Nullable UNMAsArray(id v);

NS_ASSUME_NONNULL_END
