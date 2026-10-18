//
//  UNMRewriter.m
//
//  Where the actual un-greying happens.
//
//  Three NetEase endpoints decide whether a song looks (and sounds) available:
//
//    /song/enhance/privilege      -> whether the row is greyed in the list
//    /song/enhance/player/url     -> the URL the player is handed
//    /song/enhance/download/url   -> the URL the downloader is handed
//
//  All three carry plaintext JSON in their responses even on the encrypted
//  /eapi/ routes (only the request bodies are encrypted), so a response-level
//  rewrite is enough and no crypto is involved.
//

#import "UNMRewriter.h"
#import "UNMConfig.h"
#import "UNMInternal.h"
#import "UNMLog.h"
#import "UNMStats.h"
#import "UNMStore.h"
#import "UNMUtil.h"

static id UNMParseMutable(NSData *data) {
    if (!data.length) return nil;

    id obj = [NSJSONSerialization JSONObjectWithData:data
                                            options:NSJSONReadingMutableContainers
                                              error:NULL];
    if (obj) return obj;

    id tolerant = UNMJSONParse(data);
    if (!tolerant) return nil;

    NSData *round = [NSJSONSerialization dataWithJSONObject:tolerant options:0 error:NULL];
    if (!round) return nil;
    return [NSJSONSerialization JSONObjectWithData:round
                                           options:NSJSONReadingMutableContainers
                                             error:NULL];
}

static long long UNMItemID(NSDictionary *item) {
    id raw = UNMDictGet(item, @[ @"id", @"songId", @"musicId", @"resourceId" ]);
    if ([raw isKindOfClass:NSNumber.class]) return [raw longLongValue];
    if ([raw isKindOfClass:NSString.class]) return [raw longLongValue];
    return 0;
}

// Defined below the unlock helpers; declared here so the order stays readable.
static NSDictionary *UNMResetFreeTrialPrivilege(void);
static NSArray *UNMResetChargeInfo(void);

static BOOL UNMIsGreyItem(NSDictionary *item) {
    id url = UNMDictGet(item, @[ @"url" ]);
    BOOL urlOK = [url isKindOfClass:NSString.class] && [(NSString *)url length] > 8;

    NSInteger code = 0;
    id rawCode = UNMDictGet(item, @[ @"code" ]);
    if ([rawCode respondsToSelector:@selector(integerValue)]) code = [rawCode integerValue];

    id freeTrial = UNMDictGet(item, @[ @"freeTrialInfo", @"freeTrialPrivilege" ]);
    BOOL hasTrial = freeTrial && freeTrial != NSNull.null
                    && !([freeTrial isKindOfClass:NSDictionary.class]
                         && [(NSDictionary *)freeTrial count] == 0);

    if (!urlOK) return YES;
    if (code != 0 && code != 200) return YES;
    if (hasTrial) return YES;
    return NO;
}

/// A privilege object is identified by its permission fields, so unrelated
/// `privilege` keys in other payloads are never touched.
static BOOL UNMLooksLikePrivilege(NSDictionary *item) {
    for (NSString *key in @[ @"st", @"pl", @"dl", @"subp", @"cp", @"playMaxbr" ]) {
        if (item[key] != nil) return YES;
    }
    return NO;
}

/// Un-grey one privilege object. Returns YES when something was modified.
static BOOL UNMUnlockPrivilegeItem(NSMutableDictionary *item) {
    if (!UNMLooksLikePrivilege(item)) return NO;

    NSInteger st = 0, pl = 0;
    id rawSt = item[@"st"], rawPl = item[@"pl"];
    if ([rawSt respondsToSelector:@selector(integerValue)]) st = [rawSt integerValue];
    if ([rawPl respondsToSelector:@selector(integerValue)]) pl = [rawPl integerValue];

    // st == 0 means playable; anything negative is the grey marker.
    if (st >= 0 && pl > 0) return NO;

    [item setObject:@0 forKey:@"st"];
    [item setObject:@320000 forKey:@"pl"];
    [item setObject:@320000 forKey:@"dl"];
    [item setObject:@320000 forKey:@"fl"];
    [item setObject:@7 forKey:@"sp"];
    [item setObject:@1 forKey:@"cp"];
    [item setObject:@1 forKey:@"subp"];
    [item setObject:@NO forKey:@"cs"];
    [item setObject:@0 forKey:@"flag"];
    [item setObject:@NO forKey:@"toast"];
    [item setObject:@NO forKey:@"preSell"];
    [item setObject:@320000 forKey:@"maxbr"];
    [item setObject:@320000 forKey:@"playMaxbr"];
    [item setObject:@320000 forKey:@"downloadMaxbr"];
    [item setObject:@"exhigh" forKey:@"maxBrLevel"];
    [item setObject:@"exhigh" forKey:@"playMaxBrLevel"];
    [item setObject:@"exhigh" forKey:@"downloadMaxBrLevel"];
    [item setObject:@"exhigh" forKey:@"plLevel"];
    [item setObject:@"exhigh" forKey:@"dlLevel"];
    [item setObject:@"exhigh" forKey:@"flLevel"];
    [item setObject:NSNull.null forKey:@"rscl"];
    [item setObject:UNMResetFreeTrialPrivilege() forKey:@"freeTrialPrivilege"];
    [item setObject:UNMResetChargeInfo() forKey:@"chargeInfoList"];
    return YES;
}

static NSDictionary *UNMResetFreeTrialPrivilege(void) {
    return @{
        @"resConsumable"       : @NO,
        @"userConsumable"      : @NO,
        @"listenType"          : NSNull.null,
        @"cannotListenReason"  : NSNull.null,
        @"playReason"          : NSNull.null,
        @"freeLimitTagType"    : NSNull.null,
    };
}

static NSArray *UNMResetChargeInfo(void) {
    return @[
        @{ @"rate" : @320000, @"chargeUrl" : NSNull.null,
           @"chargeMessage" : NSNull.null, @"chargeType" : @0 },
    ];
}

@implementation UNMRewriter

#pragma mark - Public

+ (NSString *)rulesVersion {
    return @"2026-10-a (player/url + download/url + privilege + embedded privileges)";
}

#pragma mark - Response shape reporting

// The rewriter can only change what it recognises, and on a modern client the
// play URLs may not come from /song/enhance/player/url at all -- the timeline
// shows them arriving in the same second as the audio request, right after a
// different endpoint. When a response passes through unchanged, its structure is
// the missing information, so it gets described once per endpoint.

+ (NSString *)describeNode:(id)node depth:(NSInteger)depth width:(NSInteger)width {
    if (node == nil || node == NSNull.null) return @"null";

    if ([node isKindOfClass:NSNumber.class]) return @"num";
    if ([node isKindOfClass:NSString.class]) {
        NSString *s = node;
        NSString *lower = s.lowercaseString;
        if ([lower hasPrefix:@"http"]) {
            // A URL is the whole point of this exercise: show enough of it to see
            // what kind of resource it points at.
            return [NSString stringWithFormat:@"url(%@)",
                    s.length > 90 ? [[s substringToIndex:90] stringByAppendingString:@"…"] : s];
        }
        return [NSString stringWithFormat:@"str(%lu)", (unsigned long)s.length];
    }

    if (depth <= 0) return @"…";
    if (width <= 0) return @"{…}";

    if ([node isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = node;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSArray *keys = [dict.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSInteger shown = 0;
        for (NSString *key in keys) {
            if (shown++ >= 16) { [parts addObject:@"…"]; break; }
            [parts addObject:[NSString stringWithFormat:@"%@:%@", key,
                              [self describeNode:dict[key] depth:depth - 1 width:width - 1]]];
        }
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }

    if ([node isKindOfClass:NSArray.class]) {
        NSArray *array = node;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:[NSString stringWithFormat:@"count=%lu", (unsigned long)array.count]];
        NSInteger sampled = 0;
        for (id item in array) {
            if (sampled++ >= 2) { [parts addObject:@"…"]; break; }
            [parts addObject:[self describeNode:item depth:depth - 1 width:width - 1]];
        }
        return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@", "]];
    }
    return @"?";
}

+ (void)reportShapeOnceForPath:(NSString *)path json:(id)json {
    static NSMutableSet<NSString *> *reported = nil;
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reported = [NSMutableSet set];
        lock = [[NSLock alloc] init];
    });
    if (path.length == 0 || json == nil) return;

    [lock lock];
    BOOL first = ![reported containsObject:path];
    if (first) [reported addObject:path];
    [lock unlock];
    if (!first) return;

    NSString *shape = [self describeNode:json depth:4 width:4];
    if (shape.length > 4000) shape = [shape substringToIndex:4000];
    UNMLogI(@"[shape] %@\n  %@", path, shape);
    [[UNMStats shared] noteShape:shape forPath:path];
    [[UNMStats shared] addEvent:[NSString stringWithFormat:@"记录了响应结构：%@", path]];
}

+ (void)ingestBody:(NSData *)body forRequest:(NSURLRequest *)request {
    if (!body.length) return;
    id json = UNMJSONParse(body);
    if (!json) return;

    // The favourite and play-report calls are the two things this project cannot see
    // any other way: if the client never sends them the UI is gated, and if it sends
    // them and gets an error the reason is in the body. Either answer ends the guessing.
    NSString *path = request.URL.path ?: @"";
    if ([path containsString:@"like"] || [path containsString:@"play/record"] ||
        [path containsString:@"scrobble"]) {
        NSDictionary *answer = UNMAsDict(json);
        UNMLogI(@"[收藏/上报] %@ %@ → code=%@ %@", request.HTTPMethod, path,
                answer[@"code"] ?: @"?",
                answer[@"message"] ?: answer[@"msg"] ?: @"");
    }

    [[UNMStore shared] ingestJSON:json];
}

/// Remove the server-side block verdict from a response.
///
/// Tapping the heart on a grey track produces 《版权方要求该资源无法操作》 and no request
/// at all, and the text is not on the model: it arrives in the answer to
/// /api/song/play/about/block/page. The client asks "may this be played or collected?",
/// stores the verdict, and refuses every action on the song while it holds one.
///
/// The payload shape is not documented, so instead of naming one key this walks the whole
/// document and defuses every block marker it can recognise: text that carries the verdict
/// becomes empty, and any numeric flag whose key talks about blocking becomes 0. The song
/// then looks playable, which is already true of its audio, so the heart works.
static BOOL UNMSanitizeBlockNode(id node);

static BOOL UNMSanitizeBlockDictionary(NSMutableDictionary *dict) {
    BOOL touched = NO;
    for (NSString *key in dict.allKeys) {
        id value = dict[key];
        NSString *lower = key.lowercaseString;

        BOOL isFlagKey = [lower containsString:@"block"] || [lower containsString:@"ban"] ||
                         [lower containsString:@"forbid"] || [lower containsString:@"restrict"] ||
                         [lower containsString:@"limit"] || [lower containsString:@"grey"] ||
                         [lower containsString:@"gray"] || [lower containsString:@"copyright"];

        if ([value isKindOfClass:NSNumber.class] && isFlagKey) {
            dict[key] = @(0);
            touched = YES;
            continue;
        }
        if ([value isKindOfClass:NSString.class]) {
            NSString *text = value;
            if ([text containsString:@"版权"] || [text containsString:@"无法"] ||
                [text containsString:@"不可"] || [text containsString:@"受限"] ||
                [text containsString:@"下架"]) {
                dict[key] = @"";
                touched = YES;
                continue;
            }
        }
        if (UNMSanitizeBlockNode(value)) touched = YES;
    }
    return touched;
}

static BOOL UNMSanitizeBlockNode(id node) {
    if ([node isKindOfClass:NSMutableDictionary.class]) {
        return UNMSanitizeBlockDictionary(node);
    }
    if ([node isKindOfClass:NSMutableArray.class]) {
        BOOL touched = NO;
        for (id child in node) {
            if (UNMSanitizeBlockNode(child)) touched = YES;
        }
        return touched;
    }
    return NO;
}


/// Rewrite the licensing verdict inside the JSON itself.
///
/// Every model-level hook is in place and the heart still refuses, which means the gate is
/// reading the payload rather than the object graph: the verdict arrives in the song-detail
/// and privilege responses as numbers (st/fee/payed/flag/cp/pl/dl/maxbr) and is stored before
/// any model is built. Normalising those numbers is the only place left that is upstream of
/// every consumer, so it is done here for the endpoints that carry them.
static NSUInteger UNMLiberatePrivilegeNode(id node) {
    if ([node isKindOfClass:NSMutableArray.class]) {
        NSUInteger total = 0;
        for (id child in node) total += UNMLiberatePrivilegeNode(child);
        return total;
    }
    if (![node isKindOfClass:NSMutableDictionary.class]) return 0;

    NSMutableDictionary *dict = node;
    NSUInteger total = 0;

    BOOL hasIdentity = dict[@"id"] || dict[@"songId"] || dict[@"musicId"] || dict[@"resourceId"];
    BOOL hasVerdict = dict[@"st"] || dict[@"status"] || dict[@"fee"] ||
                      dict[@"payed"] || dict[@"flag"] || dict[@"cp"];

    if (hasIdentity && hasVerdict) {
        if (dict[@"st"]) dict[@"st"] = @(0);
        if (dict[@"status"]) dict[@"status"] = @(200);
        if (dict[@"fee"]) dict[@"fee"] = @(0);
        if (dict[@"payed"]) dict[@"payed"] = @(1);
        if (dict[@"flag"]) dict[@"flag"] = @(0);
        if (dict[@"cp"]) dict[@"cp"] = @(1);
        if (dict[@"subp"]) dict[@"subp"] = @(1);
        if (dict[@"downloadMaxbr"]) dict[@"downloadMaxbr"] = @(320000);
        if (dict[@"playMaxbr"]) dict[@"playMaxbr"] = @(320000);
        if (dict[@"maxbr"]) dict[@"maxbr"] = @(320000);
        if (dict[@"fl"]) dict[@"fl"] = @(320000);
        if (dict[@"pl"]) dict[@"pl"] = @(320000);
        if (dict[@"dl"]) dict[@"dl"] = @(320000);
        // The client prints this string when it refuses an action.
        for (NSString *key in dict.allKeys) {
            if ([key.lowercaseString containsString:@"copyright"]) {
                dict[key] = @"";
            }
        }
        total += 1;
    }

    for (id child in dict.allValues) total += UNMLiberatePrivilegeNode(child);
    return total;
}
+ (NSData *)processBody:(NSData *)body
             forRequest:(NSURLRequest *)request
                changed:(BOOL *)changed
                 detail:(NSString * *)detail {
    return [self processBody:body forRequest:request changed:changed detail:detail allowLookups:YES];
}

+ (NSData *)processBody:(NSData *)body
             forRequest:(NSURLRequest *)request
                changed:(BOOL *)changed
                 detail:(NSString * *)detail
           allowLookups:(BOOL)allowLookups {
    if (changed) *changed = NO;
    if (detail) *detail = nil;
    if (!body.length) return body;

    // Answered before endpoint resolution: /api/song/play/about/block/page is not one of the
    // endpoints this layer knows about, and it is the call that decides whether the client
    // lets the user collect or play the song at all.
    NSString *blockPath = request.URL.path ?: @"";
    if ([blockPath containsString:@"about/block"] || [blockPath containsString:@"play/block"]) {
        id blocked = UNMParseMutable(body);
        if (blocked) {
            BOOL touched = UNMSanitizeBlockNode(blocked);
            NSData *clean = [NSJSONSerialization dataWithJSONObject:blocked options:0 error:NULL];
            if (clean) {
                UNMLogI(@"[block] %@ %lu → %lu 字节（%@）", blockPath,
                        (unsigned long)body.length, (unsigned long)clean.length,
                        touched ? @"已清除屏蔽" : @"无屏蔽标记");
                NSString *peek = [blocked description];
                if (peek.length > 700) peek = [[peek substringToIndex:700] stringByAppendingString:@"…"];
                UNMLogI(@"[block] 原文：%@", peek);
                if (touched) {
                    if (changed) *changed = YES;
                    if (detail) *detail = @"block-page cleared";
                    return clean;
                }
            }
        }
        return body;
    }

    UNMConfig *cfg = [UNMConfig shared];
    [cfg reload];
    if (!cfg.enabled) return body;

    NSURL *url = request.URL;
    // Licensing verdicts travel as plain numbers in the song payloads; rewrite them before
    // anything builds a model from them.
    {
        NSString *p = request.URL.path ?: @"";
        if ([p containsString:@"song/detail"] || [p containsString:@"privilege"] ||
            [p containsString:@"playlist/detail"] || [p containsString:@"album/"] ||
            [p containsString:@"song/enhance"] || [p containsString:@"v3/song"] ||
            [p containsString:@"v6/playlist"] || [p containsString:@"song/url"]) {
            id payload = UNMParseMutable(body);
            if (payload) {
                NSUInteger freed = UNMLiberatePrivilegeNode(payload);
                if (freed) {
                    NSData *out = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
                    if (out) {
                        UNMLogI(@"[license] %@ 放行 %lu 条", p, (unsigned long)freed);
                        if (changed) *changed = YES;
                        if (detail) *detail = @"privilege liberated";
                        body = out;
                    }
                }
            }
        }
    }

    UNMEndpoint endpoint = UNMEndpointForPath(url.path);
    if (endpoint == UNMEndpointNone) return body;

    id json = UNMParseMutable(body);
    if (!json) return body;

    // Always harvest metadata, even for endpoints we do not modify.
    [[UNMStore shared] ingestJSON:json];

    if (!UNMEndpointIsRewritable(endpoint) && !UNMEndpointIsIngestable(endpoint)) return body;

    BOOL didChange = NO;
    NSString *summary = nil;

    if (UNMEndpointIsRewritable(endpoint)) {
        switch (endpoint) {
            case UNMEndpointPlayerURL:
                if (cfg.rewritePlayerURL && allowLookups) {
                    summary = [self rewriteURLItemsIn:json
                                              bounded:cfg.maxLookupsPerResponse
                                           didChange:&didChange];
                }
                break;

            case UNMEndpointDownloadURL:
                if (cfg.rewriteDownloadURL && allowLookups) {
                    summary = [self rewriteURLItemsIn:json
                                              bounded:cfg.maxLookupsPerResponse
                                           didChange:&didChange];
                }
                break;

            case UNMEndpointPrivilege:
                if (cfg.rewritePrivilege) {
                    summary = [self rewritePrivilegeIn:json didChange:&didChange];
                }
                break;

            default:
                break;
        }
    }

    // List responses carry their own `privileges` array, and that is what the
    // table view reads to grey a row out. The dedicated endpoint is not always
    // consulted, so both have to be handled.
    if (cfg.rewritePrivilege && endpoint != UNMEndpointPrivilege) {
        NSInteger budget = 20000;   // in-memory only, and playlists get long
        NSString *embedded = [self rewriteEmbeddedPrivilegesIn:json
                                                        depth:0
                                                    didChange:&didChange
                                                       budget:&budget];
        if (embedded.length) {
            summary = summary.length
                ? [NSString stringWithFormat:@"%@; %@", summary, embedded]
                : embedded;
        }
    }

    if (!didChange) {
        // Nothing needed rewriting. For an endpoint we do not fully understand,
        // the response structure is exactly the information that is missing --
        // record it once so the rewriter can be taught what to look for.
        if (UNMEndpointIsIngestable(endpoint)) {
            [self reportShapeOnceForPath:url.path json:json];
        }
        return body;
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    if (!out.length) {
        UNMLogW(@"re-serialise failed for %@", url.path);
        return body;
    }

    if (changed) *changed = YES;
    if (detail) *detail = summary;
    [[UNMStats shared] bumpRewrite:UNMEndpointName(endpoint)];
    UNMLogI(@"[%@] %@ (%lu -> %lu bytes)",
            UNMEndpointName(endpoint), summary ?: @"rewritten",
            (unsigned long)body.length, (unsigned long)out.length);
    return out;
}

+ (NSData *)processLooseBody:(NSData *)body changed:(BOOL *)changed {
    if (changed) *changed = NO;
    if (!body.length) return body;

    UNMConfig *cfg = [UNMConfig shared];
    [cfg reload];
    if (!cfg.enabled) return body;

    id json = UNMParseMutable(body);
    if (!json) return body;

    [[UNMStore shared] ingestJSON:json];

    BOOL didChange = NO;
    NSString *summary = [self rewriteURLItemsIn:json
                                        bounded:cfg.maxLookupsPerResponse
                                     didChange:&didChange];
    if (!didChange) return body;

    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    if (!out.length) return body;

    if (changed) *changed = YES;
    UNMLogI(@"[loose hook] %@", summary ?: @"rewritten");
    return out;
}

#pragma mark - player/url + download/url

+ (NSString *)rewriteURLItemsIn:(id)root
                        bounded:(NSInteger)maxLookups
                     didChange:(BOOL *)didChange {
    // processBody: parsed the tree with NSJSONReadingMutableContainers, so we
    // can edit it in place and just re-serialise afterwards.
    if (![root isKindOfClass:NSMutableDictionary.class]) return nil;
    NSMutableDictionary *dict = root;

    id data = dict[@"data"];
    NSMutableArray *notes = [NSMutableArray array];
    NSInteger budget = MAX(1, maxLookups);

    if ([data isKindOfClass:NSMutableArray.class]) {
        for (id item in (NSMutableArray *)data) {
            if (budget <= 0) break;
            if (![item isKindOfClass:NSMutableDictionary.class]) continue;
            if ([self rewriteOneItem:item budget:&budget notes:notes]) *didChange = YES;
        }
    } else if ([data isKindOfClass:NSMutableDictionary.class]) {
        if ([self rewriteOneItem:data budget:&budget notes:notes]) *didChange = YES;
    }

    if (!notes.count) return nil;
    return [notes componentsJoinedByString:@"; "];
}

+ (BOOL)rewriteOneItem:(NSMutableDictionary *)item
                budget:(NSInteger *)budget
                 notes:(NSMutableArray *)notes {
    if (!UNMIsGreyItem(item)) return NO;

    long long songID = UNMItemID(item);
    if (songID == 0) return NO;

    UNMConfig *cfg = [UNMConfig shared];
    double deadline = CFAbsoluteTimeGetCurrent() + (double)cfg.totalTimeoutMS / 1000.0;

    // Warm lookups are instant; a cold one may legitimately take a moment, and
    // that delay is what the user feels as "the song took a second to start".
    NSString *resolved = [[UNMStore shared] resolveID:songID deadline:deadline];
    (*budget)--;

    if (!resolved.length) {
        UNMSongMeta *meta = [[UNMStore shared] metaForID:songID];
        [notes addObject:[NSString stringWithFormat:@"%lld 未找到替代源", songID]];
        [[UNMStats shared] bumpFailure:[NSString stringWithFormat:@"%@ 无替代源",
                                       meta.name ?: @""]];
        UNMLogW(@"无法为 %lld 《%@》找到替代源", songID, meta.name ?: @"?");
        return NO;
    }

    [item setObject:resolved forKey:@"url"];
    [item setObject:@200 forKey:@"code"];
    [item setObject:@0 forKey:@"fee"];
    [item setObject:NSNull.null forKey:@"freeTrialInfo"];
    if ([item objectForKey:@"freeTrialPrivilege"]) {
        [item setObject:UNMResetFreeTrialPrivilege() forKey:@"freeTrialPrivilege"];
    }

    NSInteger br = 0;
    id rawBr = item[@"br"];
    if ([rawBr respondsToSelector:@selector(integerValue)]) br = [rawBr integerValue];
    if (br <= 0) [item setObject:@320000 forKey:@"br"];

    NSString *type = nil;
    id rawType = item[@"type"];
    if ([rawType isKindOfClass:NSString.class]) type = rawType;
    if (!type.length) {
        type = [[resolved lowercaseString] containsString:@".flac"] ? @"flac" : @"mp3";
        [item setObject:type forKey:@"type"];
    }
    if (![item objectForKey:@"level"] || [item[@"level"] isEqual:NSNull.null]) {
        [item setObject:@"exhigh" forKey:@"level"];
    }
    if (![item objectForKey:@"encodeType"]) {
        [item setObject:type forKey:@"encodeType"];
    }

    UNMSongMeta *meta = [[UNMStore shared] metaForID:songID];
    [notes addObject:[NSString stringWithFormat:@"%lld 《%@》", songID, meta.name ?: @"?"]];
    return YES;
}

#pragma mark - privilege

+ (NSString *)rewritePrivilegeIn:(id)root didChange:(BOOL *)didChange {
    if (![root isKindOfClass:NSMutableDictionary.class]) return nil;

    id data = ((NSMutableDictionary *)root)[@"data"];

    // The dedicated endpoint returns data as an array; be lenient about a single
    // object, which some client builds ask for.
    NSArray<NSMutableDictionary *> *items = nil;
    if ([data isKindOfClass:NSMutableArray.class]) {
        items = (NSArray<NSMutableDictionary *> *)data;
    } else if ([data isKindOfClass:NSMutableDictionary.class]) {
        items = @[ (NSMutableDictionary *)data ];
    }
    if (!items.count) return nil;

    NSMutableArray *notes = [NSMutableArray array];
    NSMutableArray<NSNumber *> *toPrefetch = [NSMutableArray array];

    for (id raw in items) {
        if (![raw isKindOfClass:NSMutableDictionary.class]) continue;
        if (!UNMUnlockPrivilegeItem(raw)) continue;

        long long songID = UNMItemID(raw);
        if (songID == 0) continue;
        [notes addObject:[NSString stringWithFormat:@"%lld", songID]];
        [toPrefetch addObject:@(songID)];
    }

    if (!notes.count) return nil;

    *didChange = YES;

    // The app is about to ask for these URLs; resolve them now so playback
    // starts without a stall.
    if (toPrefetch.count) {
        [[UNMStore shared] prefetchIDs:toPrefetch];
    }

    return [NSString stringWithFormat:@"解锁 %lu 首 (%@%@)",
            (unsigned long)notes.count,
            [[notes subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, notes.count))]
                componentsJoinedByString:@","],
            notes.count > 6 ? @"…" : @""];
}

#pragma mark - Embedded privileges

/// Playlist, album and song-detail responses embed a `privileges` array, and
/// that is what the list UI actually reads to decide whether a row is grey.
/// Rewriting only the dedicated privilege endpoint is not enough -- which is the
/// single most common reason a "correct" rewrite still shows grey rows.
+ (NSString *)rewriteEmbeddedPrivilegesIn:(id)root
                                    depth:(NSInteger)depth
                                didChange:(BOOL *)didChange
                                   budget:(NSInteger *)budget {
    if (depth > 6 || !root || *budget <= 0) return nil;

    NSMutableArray *notes = [NSMutableArray array];

    if ([root isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = root;
        for (NSString *key in @[ @"privileges", @"privilege" ]) {
            id value = dict[key];
            if ([value isKindOfClass:NSMutableArray.class]) {
                for (id item in (NSMutableArray *)value) {
                    if (*budget <= 0) break;
                    if (![item isKindOfClass:NSMutableDictionary.class]) continue;
                    if (UNMUnlockPrivilegeItem(item)) {
                        long long songID = UNMItemID(item);
                        if (songID) [notes addObject:@(songID)];
                        (*budget)--;
                    }
                }
            } else if ([value isKindOfClass:NSMutableDictionary.class]) {
                if (UNMUnlockPrivilegeItem((NSMutableDictionary *)value)) {
                    long long songID = UNMItemID((NSMutableDictionary *)value);
                    if (songID) [notes addObject:@(songID)];
                    (*budget)--;
                }
            }
        }
        for (id value in dict.allValues) {
            if (*budget <= 0) break;
            if (![value isKindOfClass:NSDictionary.class] && ![value isKindOfClass:NSArray.class]) continue;
            NSString *sub = [self rewriteEmbeddedPrivilegesIn:value
                                                        depth:depth + 1
                                                    didChange:didChange
                                                       budget:budget];
            if (sub.length) [notes addObjectsFromArray:@[ sub ]];
        }
    } else if ([root isKindOfClass:NSMutableArray.class]) {
        for (id value in (NSMutableArray *)root) {
            if (*budget <= 0) break;
            if (![value isKindOfClass:NSDictionary.class] && ![value isKindOfClass:NSArray.class]) continue;
            NSString *sub = [self rewriteEmbeddedPrivilegesIn:value
                                                        depth:depth + 1
                                                    didChange:didChange
                                                       budget:budget];
            if (sub.length) [notes addObjectsFromArray:@[ sub ]];
        }
    }

    if (!notes.count) return nil;
    *didChange = YES;
    return [NSString stringWithFormat:@"内嵌权限解锁 %lu 项", (unsigned long)notes.count];
}

@end
