#import "UNMFavorite.h"

#import "UNMHTTP.h"
#import "UNMLog.h"
#import "UNMConfig.h"

static long long gSongId = 0;
static NSString *gSongName = nil;
static NSLock *gLock = nil;

@implementation UNMFavorite

+ (void)initialize {
    if (self == [UNMFavorite class]) {
        gLock = [[NSLock alloc] init];
    }
}

+ (void)rememberSongId:(long long)songId name:(NSString *)name {
    if (songId <= 0) return;
    [gLock lock];
    gSongId = songId;
    if (name.length) gSongName = [name copy];
    [gLock unlock];
}

+ (long long)currentSongId {
    [gLock lock];
    long long value = gSongId;
    [gLock unlock];
    return value;
}

+ (NSString *)currentSongName {
    [gLock lock];
    NSString *name = gSongName;
    [gLock unlock];
    return name;
}

#pragma mark - Cookies

/// The app keeps its session in the shared cookie store, so the same MUSIC_U that makes
/// playback work authenticates these calls.
+ (NSDictionary<NSString *, NSString *> *)cookieJar {
    NSMutableDictionary<NSString *, NSString *> *jar = [NSMutableDictionary dictionary];
    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        if (![cookie.domain containsString:@"music.163.com"]) continue;
        if (cookie.name.length == 0 || cookie.value.length == 0) continue;
        jar[cookie.name] = cookie.value;
    }
    return jar;
}

+ (NSString *)cookieHeader:(NSDictionary<NSString *, NSString *> *)jar {
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *name in jar) [pairs addObject:[NSString stringWithFormat:@"%@=%@", name, jar[name]]];
    return [pairs componentsJoinedByString:@"; "];
}

+ (NSDictionary<NSString *, NSString *> *)headersWithCookie:(NSString *)cookie {
    return @{
        @"Cookie" : cookie,
        @"User-Agent" : @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15",
        @"Referer" : @"https://music.163.com/",
        @"Content-Type" : @"application/x-www-form-urlencoded",
    };
}

#pragma mark - Steps

/// The account call is what turns a session cookie into a user id, and the user id is what
/// the playlist listing is keyed on.
+ (nullable NSString *)userIdWithCookie:(NSString *)cookie report:(NSMutableArray *)report {
    UNMHTTPResult *result = [UNMHTTP GET:@"https://music.163.com/api/nuser/account/get"
                                 headers:[self headersWithCookie:cookie]
                                 timeout:8.0];
    NSString *text = [result text] ?: @"";
    if (text.length > 160) text = [text substringToIndex:160];
    [report addObject:[NSString stringWithFormat:@"① 账号：HTTP %ld %@", (long)result.status, text]];

    id json = [result json];
    id profile = [json isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil;
    id uid = [profile isKindOfClass:NSDictionary.class] ? profile[@"userId"] : nil;
    if ([uid respondsToSelector:@selector(stringValue)]) return [uid stringValue];
    return nil;
}

/// specialType 5 is the "我喜欢的音乐" playlist; it is also normally the first entry.
+ (nullable NSString *)likedPlaylistIdForUser:(NSString *)uid
                                        cookie:(NSString *)cookie
                                        report:(NSMutableArray *)report {
    NSString *url = [NSString stringWithFormat:
        @"https://music.163.com/api/user/playlist?uid=%@&limit=1000&offset=0", uid];
    UNMHTTPResult *result = [UNMHTTP GET:url headers:[self headersWithCookie:cookie] timeout:10.0];
    id json = [result json];
    id playlists = [json isKindOfClass:NSDictionary.class] ? json[@"playlist"] : nil;
    if (![playlists isKindOfClass:NSArray.class]) {
        [report addObject:[NSString stringWithFormat:@"② 歌单：HTTP %ld 解析失败", (long)result.status]];
        return nil;
    }

    NSString *fallback = nil;
    for (NSDictionary *playlist in playlists) {
        if (![playlist isKindOfClass:NSDictionary.class]) continue;
        NSString *pid = [playlist[@"id"] respondsToSelector:@selector(stringValue)]
            ? [playlist[@"id"] stringValue] : nil;
        if (!pid.length) continue;
        if (!fallback.length) fallback = pid;
        NSInteger special = [playlist[@"specialType"] integerValue];
        if (special == 5) {
            [report addObject:[NSString stringWithFormat:@"② 歌单：找到「我喜欢的音乐」pid=%@", pid]];
            return pid;
        }
    }
    if (fallback.length) {
        [report addObject:[NSString stringWithFormat:@"② 歌单：没有 specialType=5，退回第一个 pid=%@", fallback]];
    } else {
        [report addObject:@"② 歌单：列表为空"];
    }
    return fallback;
}

/// The track id is sent twice on purpose: that is the shape the Android tweak uses, and the
/// endpoint accepts it for delisted songs where /song/like refuses.
+ (BOOL)addTrack:(long long)songId
       toPlaylist:(NSString *)pid
            cookie:(NSString *)cookie
            report:(NSMutableArray *)report {
    NSString *trackIds = [NSString stringWithFormat:@"[\"%lld\",\"%lld\"]", songId, songId];
    UNMHTTPResult *result =
        [UNMHTTP POST:@"https://music.163.com/api/playlist/manipulate/tracks"
                 form:@{ @"op" : @"add", @"pid" : pid, @"trackIds" : trackIds }
              headers:[self headersWithCookie:cookie]
              timeout:10.0];

    NSString *text = [result text] ?: @"";
    if (text.length > 200) text = [text substringToIndex:200];
    [report addObject:[NSString stringWithFormat:@"③ 加入：HTTP %ld %@", (long)result.status, text]];

    id json = [result json];
    NSInteger code = [json isKindOfClass:NSDictionary.class] ? [json[@"code"] integerValue] : -1;
    return code == 200 || code == 502;   // 502 means "already there" on this endpoint
}

#pragma mark - Entry point

+ (void)favoriteCurrentSongWithCompletion:(void (^)(BOOL, NSString *))completion {
    long long songId = [self currentSongId];
    NSString *name = [self currentSongName] ?: @"当前歌曲";
    if (songId <= 0) {
        completion(NO, @"还没记录到正在播放的歌。先播一首，再回来点这里。");
        return;
    }

    NSDictionary *jar = [self cookieJar];
    NSString *session = jar[@"MUSIC_U"];
    if (!session.length) {
        completion(NO, [NSString stringWithFormat:@"没读到 MUSIC_U（共 %lu 个 music.163.com Cookie）",
                                                  (unsigned long)jar.count]);
        return;
    }
    NSString *cookie = [self cookieHeader:jar];

    UNMLogI(@"[fav] 歌单路线 id=%lld《%@》，Cookie %lu 个", songId, name, (unsigned long)jar.count);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSString *> *report = [NSMutableArray array];

        NSString *uid = [self userIdWithCookie:cookie report:report];
        if (!uid.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [[report componentsJoinedByString:@"\n\n"]
                    stringByAppendingString:@"\n\n账号接口没返回 userId，收藏中止。"]);
            });
            return;
        }

        NSString *configured = [UNMConfig shared].favoritePlaylistId;
        NSString *pid = nil;
        if (configured.length) {
            pid = configured;
            [report addObject:[NSString stringWithFormat:@"② 歌单：使用指定 pid=%@", pid]];
        } else {
            pid = [self likedPlaylistIdForUser:uid cookie:cookie report:report];
        }
        if (!pid.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [[report componentsJoinedByString:@"\n\n"]
                    stringByAppendingString:@"\n\n找不到「我喜欢的音乐」，收藏中止。"]);
            });
            return;
        }

        BOOL ok = [self addTrack:songId toPlaylist:pid cookie:cookie report:report];
        NSString *summary = [report componentsJoinedByString:@"\n\n"];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, summary); });
    });
}


#pragma mark - Playlist listing

/// Editable playlists only: ones this account created. Subscribed playlists reject the add.
+ (void)loadEditablePlaylistsWithCompletion:(void (^)(NSArray<NSDictionary *> *items, NSString *report))completion {
    NSDictionary *jar = [self cookieJar];
    NSString *session = jar[@"MUSIC_U"];
    if (!session.length) {
        completion(@[], @"没读到 MUSIC_U");
        return;
    }
    NSString *cookie = [self cookieHeader:jar];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSString *> *report = [NSMutableArray array];
        NSString *uid = [self userIdWithCookie:cookie report:report];
        if (!uid.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], @"账号接口没返回 userId"); });
            return;
        }

        NSString *url = [NSString stringWithFormat:
            @"https://music.163.com/api/user/playlist?uid=%@&limit=1000&offset=0", uid];
        UNMHTTPResult *result = [UNMHTTP GET:url headers:[self headersWithCookie:cookie] timeout:10.0];
        id json = [result json];
        id playlists = [json isKindOfClass:NSDictionary.class] ? json[@"playlist"] : nil;
        if (![playlists isKindOfClass:NSArray.class]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@[], [NSString stringWithFormat:@"歌单列表解析失败（HTTP %ld）", (long)result.status]);
            });
            return;
        }

        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSDictionary *playlist in playlists) {
            if (![playlist isKindOfClass:NSDictionary.class]) continue;
            // Owned playlists only: creatorId equals the account, or subscribed is false.
            BOOL subscribed = [playlist[@"subscribed"] boolValue];
            NSString *creator = [playlist[@"creator"][@"userId"] respondsToSelector:@selector(stringValue)]
                ? [playlist[@"creator"][@"userId"] stringValue] : nil;
            BOOL mine = !subscribed || [creator isEqualToString:uid];
            if (!mine) continue;

            NSString *pid = [playlist[@"id"] respondsToSelector:@selector(stringValue)]
                ? [playlist[@"id"] stringValue] : nil;
            NSString *name = playlist[@"name"];
            if (!pid.length || !name.length) continue;

            [items addObject:@{
                @"id" : pid,
                @"name" : name,
                @"count" : playlist[@"trackCount"] ?: @0,
                @"special" : playlist[@"specialType"] ?: @0,
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items, [NSString stringWithFormat:@"共 %lu 个可写歌单", (unsigned long)items.count]);
        });
    });
}@end
