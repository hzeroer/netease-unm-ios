//
//  unm_test.m
//
//  Host-side unit tests for the logic that does not need a device:
//    * MD5 and the BoDian request signature (checked against recorded live values)
//    * title normalisation and fuzzy matching
//    * tolerant JSON parsing of KuWo's single-quoted payloads
//    * the NetEase response rewriter for player/url, download/url and privilege
//
//  Built by tools/run-tests.sh and run on Linux with GNUstep.
//

#import <Foundation/Foundation.h>

#include <math.h>
#include <stdio.h>

#import "UNMBodianSign.h"
#import "UNMConfig.h"
#import "UNMInternal.h"
#import "UNMMatcher.h"
#import "UNMRewriter.h"
#import "UNMUtil.h"

// Provided by UNMStoreStub.m
extern void UNMStubReset(void);
extern void UNMStubSeed(void);
extern NSUInteger UNMStubIngestCount(void);
extern void UNMStubSetResolvedURL(NSString *url);

static NSUInteger gPass = 0;
static NSUInteger gFail = 0;

static void CHECK(BOOL condition, NSString *label, NSString *detail) {
    if (condition) {
        gPass++;
        printf("  \033[32mPASS\033[0m %s\n", label.UTF8String);
    } else {
        gFail++;
        printf("  \033[31mFAIL\033[0m %s   %s\n", label.UTF8String,
               (detail ?: @"").UTF8String);
    }
}

static void CHECK_EQ_STR(NSString *actual, NSString *expected, NSString *label) {
    BOOL ok = (actual == expected) || [actual isEqualToString:expected];
    CHECK(ok, label, [NSString stringWithFormat:@"got '%@' want '%@'", actual, expected]);
}

static void CHECK_EQ_NUM(double actual, double expected, NSString *label) {
    BOOL ok = fabs(actual - expected) < 0.0001;
    CHECK(ok, label, [NSString stringWithFormat:@"got %g want %g", actual, expected]);
}

static NSString *JSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static id ParseJSONString(NSString *string) {
    return [NSJSONSerialization JSONObjectWithData:[string dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0
                                            error:NULL];
}

static NSURLRequest *RequestForPath(NSString *path) {
    NSURL *url = [NSURL URLWithString:[@"https://interface3.music.163.com" stringByAppendingString:path]];
    return [NSURLRequest requestWithURL:url];
}

#pragma mark - Tests

static void TestMD5(void) {
    printf("\n[1] MD5\n");
    CHECK_EQ_STR(UNMMD5(@""), @"d41d8cd98f00b204e9800998ecf8427e", @"md5(\"\")");
    CHECK_EQ_STR(UNMMD5(@"abc"), @"900150983cd24fb0d6963f7d28e17f72", @"md5(\"abc\")");
    CHECK_EQ_STR(UNMMD5(@"The quick brown fox jumps over the lazy dog"),
                 @"9e107d9d372bb6826bd81d3542a419d6", @"md5(fox)");
    CHECK_EQ_STR(UNMMD5(@"周杰伦"), @"7a8941058aaf4df5147042ce104568da",
                 @"md5 of UTF-8 input is byte-exact");
}

static void TestBodianSignature(void) {
    printf("\n[2] BoDian signature (recorded live vector)\n");

    // Captured from the live service: this exact URL was accepted with HTTP 200
    // and returned a real audio URL, so the sign below is ground truth.
    NSString *base = @"http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=51685512";
    long long timestamp = 1792175305170LL;
    NSString *signedURL = UNMBodianSignedURLAtTimestamp(base, timestamp);

    CHECK_EQ_STR(signedURL,
                 @"http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=51685512"
                 @"&timestamp=1792175305170&sign=59c4168ac69ea2d943ae24183163eb3a",
                 @"signature matches the live request");

    // Determinism and the properties the server enforces.
    CHECK_EQ_STR(UNMBodianSignedURLAtTimestamp(base, timestamp), signedURL,
                 @"signature is deterministic");
    CHECK([signedURL containsString:@"timestamp="], @"timestamp retained", nil);
    CHECK([signedURL hasSuffix:@"sign=59c4168ac69ea2d943ae24183163eb3a"], @"sign is 32 hex chars", nil);

    NSString *other = UNMBodianSignedURLAtTimestamp(
        @"http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=228908", timestamp);
    CHECK(![other isEqualToString:signedURL], @"different musicId -> different sign", nil);
}

static void TestNormalisation(void) {
    printf("\n[3] Title normalisation\n");
    CHECK_EQ_STR(UNMNormalizeTitle(@"晴天"), @"晴天", @"plain CJK");
    CHECK_EQ_STR(UNMNormalizeTitle(@"晴天 (Live)"), @"晴天", @"drops (Live)");
    CHECK_EQ_STR(UNMNormalizeTitle(@"夜的钢琴曲5 (纯音乐)"), @"夜的钢琴曲5", @"drops 【descriptor】");
    CHECK_EQ_STR(UNMNormalizeTitle(@"Hello, World!"), @"helloworld", @"lowercase, drops punctuation");
    CHECK_EQ_STR(UNMNormalizeTitle(@"小苹果（Cover）"), @"小苹果", @"full-width brackets + Cover");
    CHECK_EQ_STR(UNMStripTags(@"&lt;em&gt;晴天"), @"<em>晴天", @"decodes html entities");
}

static NSArray<NSString *> *SplitArtists(NSString *s) {
    return UNMSplitArtists(s);
}

static void TestMatching(void) {
    printf("\n[4] Matching\n");

    UNMSongMeta *target = [UNMSongMeta new];
    target.songID = 186016;
    target.name = @"晴天";
    target.artists = @[ @"周杰伦" ];
    target.album = @"叶惠美";
    target.duration = 269;
    CHECK(target.usable, @"target is usable", nil);

    CHECK_EQ_STR([UNMMatcher searchKeywordForMeta:target], @"晴天 周杰伦", @"search keyword");

    // Exact hit.
    UNMCandidate *exact = [UNMCandidate new];
    exact.provider = @"kuwo";
    exact.mediaId = @"228908";
    exact.title = @"晴天";
    exact.artist = @"周杰伦";
    exact.album = @"叶惠美";
    exact.duration = 269;

    // Live version: right song, wrong length.
    UNMCandidate *live = [UNMCandidate new];
    live.provider = @"kuwo";
    live.mediaId = @"80456317";
    live.title = @"晴天 (Live)";
    live.artist = @"周杰伦";
    live.duration = 249;

    // Right artist, different song.
    UNMCandidate *wrongSong = [UNMCandidate new];
    wrongSong.provider = @"kuwo";
    wrongSong.mediaId = @"351583919";
    wrongSong.title = @"稻香";
    wrongSong.artist = @"周杰伦";
    wrongSong.duration = 223;

    // Right title, wrong artist (a cover).
    UNMCandidate *cover = [UNMCandidate new];
    cover.provider = @"kugou";
    cover.mediaId = @"deadbeef";
    cover.title = @"晴天";
    cover.artist = @"某某翻唱";
    cover.duration = 270;

    double exactScore = [UNMMatcher scoreCandidate:exact against:target];
    double liveScore = [UNMMatcher scoreCandidate:live against:target];
    double wrongScore = [UNMMatcher scoreCandidate:wrongSong against:target];
    double coverScore = [UNMMatcher scoreCandidate:cover against:target];

    printf("       scores: exact=%.3f live=%.3f wrongSong=%.3f cover=%.3f\n",
           exactScore, liveScore, wrongScore, coverScore);

    CHECK(exactScore > 0.9, @"exact match scores high", nil);
    CHECK(exactScore > liveScore, @"exact beats the live cut", nil);
    CHECK(liveScore >= 0.6, @"live cut still clears the default threshold", nil);
    CHECK(wrongScore < 0.6, @"a different song by the same artist is rejected", nil);
    CHECK(coverScore < exactScore, @"a cover ranks below the original", nil);

    // Selection honours the threshold and picks the best, not the first.
    NSArray *pool = @[ wrongSong, live, exact ];
    UNMCandidate *best = [UNMMatcher best:pool forTarget:target threshold:0.60];
    CHECK(best == exact, @"best: picks the exact match", nil);

    UNMCandidate *none = [UNMMatcher best:@[ wrongSong, cover ] forTarget:target threshold:0.60];
    CHECK(none == nil, @"best: returns nil when nothing clears the threshold", nil);

    // Artist parsing.
    CHECK_EQ_NUM((double)SplitArtists(@"周杰伦 & 袁咏琳").count, 2, @"splits on &");
    CHECK_EQ_NUM((double)SplitArtists(@"A / B").count, 2, @"splits on /");
    CHECK_EQ_NUM((double)SplitArtists(@"A feat. B").count, 2, @"splits on feat.");
}

static void TestTolerantJSON(void) {
    printf("\n[5] Tolerant JSON (KuWo single-quoted payload)\n");

    // Recorded shape of search.kuwo.cn/r.s with rformat=json.
    NSString *kuwo =
        @"{'ARTISTPIC':'','abslist':[{'ARTIST':'周杰伦','MUSICRID':'MUSIC_228908',"
         "'SONGNAME':'晴天','ALBUM':'叶惠美','DURATION':'269','FORMATS':'MP3128|MP3H'},"
         "{'ARTIST':'周杰伦','MUSICRID':'MUSIC_80456317','SONGNAME':'晴天 (Live)',"
         "'ALBUM':'演唱会','DURATION':'249'}],'TOTAL':'3851'}";

    id parsed = UNMJSONParse([kuwo dataUsingEncoding:NSUTF8StringEncoding]);
    CHECK(parsed != nil, @"single-quoted JSON parses", nil);
    NSArray *list = ((NSDictionary *)parsed)[@"abslist"];
    CHECK_EQ_NUM((double)list.count, 2, @"both entries survived");
    CHECK_EQ_STR(list[0][@"SONGNAME"], @"晴天", @"field values intact");
    CHECK_EQ_STR(list[1][@"MUSICRID"], @"MUSIC_80456317", @"second entry intact");

    // Strict JSON must keep working, and junk must fail cleanly.
    CHECK(UNMJSONParse([@"{\"a\":1}" dataUsingEncoding:NSUTF8StringEncoding]) != nil,
          @"strict JSON still parses", nil);
    CHECK(UNMJSONParse([@"not json at all" dataUsingEncoding:NSUTF8StringEncoding]) == nil,
          @"junk returns nil instead of throwing", nil);

    // Duration units.
    CHECK_EQ_NUM(UNMParseDuration(@269), 269, @"seconds");
    CHECK_EQ_NUM(UNMParseDuration(@269000), 269, @"milliseconds are detected");
    CHECK_EQ_NUM(UNMParseDuration(@"04:29"), 269, @"mm:ss");
    CHECK_EQ_NUM(UNMParseDuration(@"00:04:29"), 269, @"hh:mm:ss");
}

static void TestRewriterPlayerURL(void) {
    printf("\n[6] Rewriter: /song/enhance/player/url\n");
    UNMStubReset();
    UNMStubSeed();
    UNMStubSetResolvedURL(@"https://cdn.example/substitute.mp3");

    // Recorded shape of a greyed-out song: url null, code 404, fee 1, level none.
    NSString *grey =
        @"{\"code\":200,\"data\":[{\"id\":186016,\"url\":null,\"br\":0,\"size\":0,\"md5\":null,"
         "\"code\":404,\"expi\":1200,\"type\":null,\"gain\":0,\"fee\":1,\"payed\":0,\"flag\":0,"
         "\"freeTrialInfo\":null,\"level\":\"none\",\"encodeType\":null}]}";

    BOOL changed = NO;
    NSString *detail = nil;
    NSData *out = [UNMRewriter processBody:[grey dataUsingEncoding:NSUTF8StringEncoding]
                                forRequest:RequestForPath(@"/eapi/song/enhance/player/url/v1")
                                   changed:&changed
                                    detail:&detail];

    CHECK(changed, @"a greyed song is rewritten", detail);
    id json = ParseJSONString([[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]);
    CHECK(json != nil, @"output is still valid JSON", nil);
    NSDictionary *item = ((NSDictionary *)json)[@"data"][0];
    CHECK_EQ_STR(item[@"url"], @"https://cdn.example/substitute.mp3", @"url replaced");
    CHECK_EQ_NUM([item[@"code"] doubleValue], 200, @"code -> 200");
    CHECK_EQ_NUM([item[@"fee"] doubleValue], 0, @"fee -> 0 (no VIP badge)");
    CHECK_EQ_NUM([item[@"br"] doubleValue], 320000, @"br filled in when it was 0");
    CHECK(item[@"freeTrialInfo"] == [NSNull null], @"freeTrialInfo cleared", nil);
    CHECK_EQ_NUM([item[@"id"] doubleValue], 186016, @"id preserved");
    CHECK(UNMStubIngestCount() > 0, @"metadata ingestion ran", nil);
}

static void TestRewriterKeepsPlayableSongs(void) {
    printf("\n[7] Rewriter: playable songs are left alone\n");
    UNMStubReset();
    UNMStubSeed();

    NSString *playable =
        @"{\"code\":200,\"data\":[{\"id\":186016,\"url\":\"http://m801.music.126.net/x.mp3\","
         "\"br\":320000,\"size\":123,\"code\":200,\"fee\":0,\"level\":\"exhigh\"}]}";

    BOOL changed = NO;
    NSData *body = [playable dataUsingEncoding:NSUTF8StringEncoding];
    NSData *out = [UNMRewriter processBody:body
                                forRequest:RequestForPath(@"/api/song/enhance/player/url")
                                   changed:&changed
                                    detail:NULL];

    CHECK(!changed, @"nothing rewritten when the song already plays", nil);
    CHECK(out == body || [out isEqualToData:body], @"body handed back untouched", nil);
}

static void TestRewriterPrivilege(void) {
    printf("\n[8] Rewriter: /song/enhance/privilege\n");
    UNMStubReset();
    UNMStubSeed();

    // Recorded shape of a not-licensed song: st -200, pl 0.
    NSString *privilege =
        @"{\"code\":200,\"data\":[{\"id\":186016,\"fee\":1,\"payed\":0,\"st\":-200,\"pl\":0,\"dl\":0,"
         "\"sp\":0,\"cp\":0,\"subp\":0,\"cs\":false,\"maxbr\":999000,\"fl\":0,\"toast\":false,\"flag\":0,"
         "\"preSell\":false,\"playMaxbr\":999000,\"downloadMaxbr\":999000,\"maxBrLevel\":\"lossless\","
         "\"playMaxBrLevel\":\"lossless\",\"downloadMaxBrLevel\":\"lossless\",\"plLevel\":\"none\","
         "\"dlLevel\":\"none\",\"flLevel\":\"none\",\"rscl\":null,"
         "\"freeTrialPrivilege\":{\"resConsumable\":false,\"userConsumable\":false,\"listenType\":null},"
         "\"chargeInfoList\":[{\"rate\":128000,\"chargeUrl\":null,\"chargeMessage\":null,"
         "\"chargeType\":1}]}]}";

    BOOL changed = NO;
    NSString *detail = nil;
    NSData *out = [UNMRewriter processBody:[privilege dataUsingEncoding:NSUTF8StringEncoding]
                                forRequest:RequestForPath(@"/eapi/song/enhance/privilege")
                                   changed:&changed
                                    detail:&detail];
    CHECK(changed, @"greyed privilege is rewritten", detail);

    NSDictionary *item = ((NSDictionary *)ParseJSONString(
        [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]))[@"data"][0];
    CHECK_EQ_NUM([item[@"st"] doubleValue], 0, @"st -> 0 (row is no longer grey)");
    CHECK_EQ_NUM([item[@"pl"] doubleValue], 320000, @"pl filled in");
    CHECK_EQ_NUM([item[@"dl"] doubleValue], 320000, @"dl filled in");
    CHECK_EQ_NUM([item[@"cp"] doubleValue], 1, @"cp filled in");
    CHECK_EQ_NUM([item[@"flag"] doubleValue], 0, @"flag cleared");
    CHECK([item[@"plLevel"] isEqualToString:@"exhigh"],
          @"level labels downgraded to what we actually serve", nil);
    CHECK_EQ_NUM([item[@"chargeInfoList"][0][@"chargeType"] doubleValue], 0,
                 @"charge list neutralised");
    CHECK(item[@"chargeInfoList"][0][@"chargeUrl"] == [NSNull null], @"charge url emptied", nil);

    // A song that is already playable must not be touched.
    UNMStubReset();
    NSString *fine = @"{\"code\":200,\"data\":[{\"id\":186016,\"st\":0,\"pl\":320000,\"dl\":320000}]}";
    BOOL changed2 = NO;
    [UNMRewriter processBody:[fine dataUsingEncoding:NSUTF8StringEncoding]
                  forRequest:RequestForPath(@"/eapi/song/enhance/privilege")
                     changed:&changed2
                      detail:NULL];
    CHECK(!changed2, @"playable privilege untouched", nil);
}

static void TestRewriterDownloadURL(void) {
    printf("\n[9] Rewriter: /song/enhance/download/url\n");
    UNMStubReset();
    UNMStubSeed();
    UNMStubSetResolvedURL(@"https://cdn.example/download.mp3");

    NSString *body =
        @"{\"code\":200,\"data\":{\"id\":186016,\"url\":null,\"br\":0,\"size\":0,\"code\":404,"
         "\"fee\":1,\"level\":\"none\"}}";

    BOOL changed = NO;
    NSData *out = [UNMRewriter processBody:[body dataUsingEncoding:NSUTF8StringEncoding]
                                forRequest:RequestForPath(@"/api/song/enhance/download/url")
                                   changed:&changed
                                    detail:NULL];
    CHECK(changed, @"download url rewritten", nil);
    NSDictionary *data = ((NSDictionary *)ParseJSONString(
        [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]))[@"data"];
    CHECK_EQ_STR(data[@"url"], @"https://cdn.example/download.mp3", @"download url replaced");
}

static void TestRewriterIgnoresOtherEndpoints(void) {
    printf("\n[10] Rewriter: unrelated endpoints pass through\n");
    UNMStubReset();
    UNMStubSeed();

    NSString *detail =
        @"{\"songs\":[{\"id\":186016,\"name\":\"晴天\",\"ar\":[{\"name\":\"周杰伦\"}],\"dt\":269000}]}";
    NSData *body = [detail dataUsingEncoding:NSUTF8StringEncoding];
    BOOL changed = NO;
    NSData *out = [UNMRewriter processBody:body
                                forRequest:RequestForPath(@"/api/song/detail")
                                   changed:&changed
                                    detail:NULL];
    CHECK(!changed, @"song/detail is not modified", nil);
    CHECK([out isEqualToData:body], @"bytes are identical", nil);
    CHECK(UNMStubIngestCount() == 1, @"but metadata was harvested exactly once", nil);
}

static void TestEndpointClassification(void) {
    printf("\n[11] Endpoint classification\n");
    CHECK(UNMEndpointForPath(@"/eapi/song/enhance/player/url/v1") == UNMEndpointPlayerURL,
          @"eapi player url v1", nil);
    CHECK(UNMEndpointForPath(@"/api/song/enhance/player/url") == UNMEndpointPlayerURL,
          @"api player url", nil);
    CHECK(UNMEndpointForPath(@"/api/song/enhance/download/url") == UNMEndpointDownloadURL,
          @"download url", nil);
    CHECK(UNMEndpointForPath(@"/eapi/song/enhance/privilege") == UNMEndpointPrivilege,
          @"privilege", nil);
    CHECK(UNMEndpointForPath(@"/api/song/detail") == UNMEndpointSongDetail, @"song detail", nil);
    CHECK(UNMEndpointForPath(@"/something/else") == UNMEndpointNone, @"unrelated path", nil);

    CHECK(UNMEndpointIsRewritable(UNMEndpointPlayerURL), @"player is rewritable", nil);
    CHECK(!UNMEndpointIsRewritable(UNMEndpointSongDetail), @"detail is not rewritable", nil);

    CHECK(UNMIsNeteaseAPIHost(@"interface3.music.163.com"), @"api host accepted", nil);
    CHECK(UNMIsNeteaseAPIHost(@"music.163.com"), @"bare host accepted", nil);
    // The audio CDN must never be buffered.
    CHECK(!UNMIsNeteaseAPIHost(@"m801.music.126.net"), @"audio CDN excluded", nil);
    CHECK(!UNMIsNeteaseAPIHost(@"example.com"), @"foreign host excluded", nil);
}

static void TestConfigDefaults(void) {
    printf("\n[0] Shipped config defaults\n");
    UNMConfig *cfg = [UNMConfig shared];
    CHECK(cfg.enabled, @"enabled by default", nil);
    CHECK_EQ_STR([cfg.providerOrder componentsJoinedByString:@","], @"kuwo,bodian,kugou,migu",
                 @"source order");
    CHECK(cfg.rewritePlayerURL && cfg.rewriteDownloadURL && cfg.rewritePrivilege,
          @"all three endpoints are rewritten", nil);
    CHECK(cfg.enableXRealIP, @"X-Real-IP injection on by default", nil);
    CHECK_EQ_STR(cfg.xRealIP, @"118.88.88.8", @"default X-Real-IP");
    CHECK_EQ_NUM(cfg.matchThreshold, 0.60, @"match threshold");
    CHECK_EQ_NUM(cfg.matchDurationTolerance, 6.0, @"duration tolerance");
    CHECK(cfg.maxLookupsPerResponse > 0, @"lookup budget is bounded", nil);
    CHECK(cfg.totalTimeoutMS >= cfg.lookupTimeoutMS, @"total budget >= per-source budget", nil);
    CHECK(!cfg.discoveryMode, @"discovery off by default", nil);
    CHECK(cfg.neteaseDetailFallback, @"NetEase detail fallback on", nil);
    CHECK_EQ_NUM((double)cfg.providerCookies.count, 0.0, @"no baked-in cookies");
}

int main(void) {
    @autoreleasepool {
        printf("UNMiOS host-side tests\n");
        printf("config: %s\n", [[UNMConfig shared].dump UTF8String]);

        TestConfigDefaults();
        TestMD5();
        TestBodianSignature();
        TestNormalisation();
        TestMatching();
        TestTolerantJSON();
        TestRewriterPlayerURL();
        TestRewriterKeepsPlayableSongs();
        TestRewriterPrivilege();
        TestRewriterDownloadURL();
        TestRewriterIgnoresOtherEndpoints();
        TestEndpointClassification();

        printf("\n%d passed, %d failed\n", (int)gPass, (int)gFail);
        return gFail == 0 ? 0 : 1;
    }
}
