//
//  UNMRewriter.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMRewriter : NSObject

/// Rewrite a NetEase API response body in place.
///
/// Returns the body to hand back to the app (the original object when nothing
/// changed). `changed` reports whether a substitution happened, `detail` gets a
/// short human-readable summary for the log.
+ (NSData *)processBody:(NSData *)body
             forRequest:(NSURLRequest *)request
                changed:(BOOL *)changed
                 detail:(NSString * _Nullable * _Nullable)detail;

/// Same, but `allowLookups` controls whether a missing play URL may trigger a
/// source search.
///
/// Pass NO on any path that runs on a thread the app cares about (the URL cache,
/// for instance): the privilege rewrite is pure in-memory and always safe, while
/// resolving a substitute URL can block for seconds waiting on a music source.
+ (NSData *)processBody:(NSData *)body
             forRequest:(NSURLRequest *)request
                changed:(BOOL *)changed
                 detail:(NSString * _Nullable * _Nullable)detail
           allowLookups:(BOOL)allowLookups;

/// Parse + harvest metadata only (used for endpoints we observe but never modify).
+ (void)ingestBody:(NSData *)body forRequest:(NSURLRequest *)request;

/// Best-effort rewrite for a body whose endpoint we cannot identify, used by the
/// configurable `extraHooks` escape hatch. Applies the player-URL rule to any
/// object that looks like it carries a `data` list of song URL entries.
+ (NSData *)processLooseBody:(NSData *)body changed:(BOOL *)changed;

/// Version string of the rewrite rules, surfaced in the diagnostics screen so a
/// bug report can say exactly which rules were in effect.
+ (NSString *)rulesVersion;

@end

NS_ASSUME_NONNULL_END
