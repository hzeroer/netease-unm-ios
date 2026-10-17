//
//  UNMStoreStub.m  (test-only)
//
//  Stands in for the real UNMStore so the response rewriter -- the highest risk
//  piece of logic in the tweak -- can be executed and asserted on a Linux host,
//  with no network, no iOS SDK and no jailbreak.
//
//  It implements the exact UNMStore.h interface, so if the real store changes
//  shape the test stops compiling instead of silently drifting.
//

#import "UNMStore.h"
#import "UNMMatcher.h"

static NSUInteger gIngestCalls = 0;
static NSMutableDictionary<NSNumber *, UNMSongMeta *> *gMeta = nil;

/// Canned metadata, as if the app had already downloaded a song/detail response.
void UNMStubReset(void);
void UNMStubSeed(void);
NSUInteger UNMStubIngestCount(void);
void UNMStubSetResolvedURL(NSString *url);

static NSString *gResolvedURL = nil;

void UNMStubReset(void) {
    gIngestCalls = 0;
    gMeta = [NSMutableDictionary dictionary];
    gResolvedURL = @"https://stub.test/audio.mp3";
}

void UNMStubSeed(void) {
    UNMSongMeta *meta = [UNMSongMeta new];
    meta.songID = 186016;
    meta.name = @"晴天";
    meta.artists = @[ @"周杰伦" ];
    meta.album = @"叶惠美";
    meta.duration = 269;
    gMeta[@(meta.songID)] = meta;
}

NSUInteger UNMStubIngestCount(void) { return gIngestCalls; }
void UNMStubSetResolvedURL(NSString *url) { gResolvedURL = url; }

@implementation UNMStore

+ (instancetype)shared {
    static UNMStore *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[UNMStore alloc] init];
        UNMStubReset();
    });
    return inst;
}

- (void)ingestJSON:(id)json {
    if (json) gIngestCalls++;
}

- (void)setMeta:(UNMSongMeta *)meta {
    if (meta) gMeta[@(meta.songID)] = meta;
}

- (UNMSongMeta *)metaForID:(long long)songID {
    return gMeta[@(songID)];
}

- (NSDictionary *)matchForID:(long long)songID { (void)songID; return nil; }

- (NSString *)resolveID:(long long)songID deadline:(NSTimeInterval)deadline {
    (void)songID; (void)deadline;
    return gResolvedURL;
}

- (void)prefetchIDs:(NSArray<NSNumber *> *)songIDs { (void)songIDs; }
- (void)flush { }
- (NSString *)stats { return @"stub"; }

@end
