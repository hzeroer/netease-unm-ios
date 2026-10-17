//
//  UNMDiagnose.m
//

#import "UNMDiagnose.h"
#import "UNMConfig.h"
#import "UNMLog.h"
#import "UNMModelHook.h"
#import "UNMProvider.h"
#import "UNMRuntimeDump.h"
#import "UNMStats.h"
#import "UNMUtil.h"
#import "UNMValidate.h"
#import "UNMVersion.h"

@implementation UNMDiagnoseResult

- (NSString *)description {
    if (self.url.length) {
        return [NSString stringWithFormat:@"%@: OK  %@ - %@  %.2f  (搜 %.0fms / 取链 %.0fms)",
                self.provider, self.matchedArtist ?: @"", self.matchedTitle ?: @"",
                self.score, self.searchMilliseconds, self.resolveMilliseconds];
    }
    if (self.searchOK) {
        return [NSString stringWithFormat:@"%@: 搜到 %ld 条但取不到直链  %@",
                self.provider, (long)self.candidateCount, self.error ?: @""];
    }
    return [NSString stringWithFormat:@"%@: 搜索失败  %@", self.provider, self.error ?: @""];
}

@end

@implementation UNMDiagnose

+ (void)runWithDefaultKeywordWithCompletion:(void (^)(NSArray<UNMDiagnoseResult *> *,
                                                      NSString *))completion {
    [self runWithKeyword:@"晴天 周杰伦" completion:completion];
}

+ (void)runWithKeyword:(NSString *)keyword
            completion:(void (^)(NSArray<UNMDiagnoseResult *> *, NSString *))completion {
    if (!completion) return;

    NSString *probe = keyword.length ? keyword : @"晴天 周杰伦";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UNMConfig *cfg = [UNMConfig shared];
        [cfg reload];

        NSArray<NSString *> *order = cfg.providerOrder;
        if (order.count == 0) order = UNMRegisteredProviderKeys();

        NSMutableArray<UNMDiagnoseResult *> *results = [NSMutableArray array];
        NSTimeInterval perTry = MAX(2.0, (double)cfg.lookupTimeoutMS / 1000.0);

        for (NSString *key in order) {
            UNMDiagnoseResult *row = [UNMDiagnoseResult new];
            row.provider = key;

            id<UNMProvider> provider = UNMProviderForKey(key);
            if (!provider) {
                row.error = @"未注册";
                [results addObject:row];
                continue;
            }

            double t0 = CFAbsoluteTimeGetCurrent();
            NSArray<UNMCandidate *> *candidates = nil;
            @try {
                candidates = [provider search:probe timeout:perTry] ?: @[];
            } @catch (NSException *e) {
                candidates = @[];
                row.error = [NSString stringWithFormat:@"搜索异常 %@", e.reason ?: @""];
            }
            row.searchMilliseconds = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
            row.candidateCount = (NSInteger)candidates.count;
            row.searchOK = candidates.count > 0;

            UNMCandidate *pick = candidates.firstObject;
            if (!pick) {
                if (!row.error.length) row.error = @"搜索返回空";
                [results addObject:row];
                continue;
            }
            row.matchedTitle = pick.title;
            row.matchedArtist = pick.artist;
            row.score = pick.duration > 0 ? 1.0 : 0.0;   // search-only path: no target to score against

            double t1 = CFAbsoluteTimeGetCurrent();
            @try {
                row.url = [provider resolveURL:pick timeout:perTry];
            } @catch (NSException *e) {
                row.error = [NSString stringWithFormat:@"取链异常 %@", e.reason ?: @""];
            }
            row.resolveMilliseconds = (CFAbsoluteTimeGetCurrent() - t1) * 1000.0;
            if (!row.url.length && !row.error.length) row.error = @"未取到直链";

            [results addObject:row];
        }

        NSUInteger ok = 0;
        for (UNMDiagnoseResult *r in results) if (r.url.length) ok++;
        NSString *summary = [NSString stringWithFormat:@"%@ → %lu/%lu 个音源可用",
                             probe, (unsigned long)ok, (unsigned long)results.count];

        [[UNMStats shared] addEvent:[NSString stringWithFormat:@"自检 %@", summary]];
        UNMLogI(@"自检结果：%@", summary);
        for (UNMDiagnoseResult *r in results) UNMLogI(@"  %@", r.description);

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results, summary);
        });
    });
}

+ (void)startCaptureWithSeconds:(NSTimeInterval)seconds
                     completion:(void (^)(NSString *))completion {
    UNMConfig *cfg = [UNMConfig shared];
    [cfg forceReload];

    id oldLogLevel = [cfg valueForKey:@"logLevel"];
    id oldDiscovery = [cfg valueForKey:@"discoveryMode"];
    id oldEveryIntercept = [cfg valueForKey:@"logEveryIntercept"];

    UNMStats *stats = [UNMStats shared];

    // Start from a clean slate, so every number in the report describes the
    // capture window and nothing before it. Reporting cumulative totals next to
    // window deltas made an earlier report actively misleading: "intercepts 7,
    // session tasks 68" was read as a ratio when it was not one.
    [stats reset];

    [cfg persistValue:@4 forKey:@"logLevel"];
    [cfg persistValue:@YES forKey:@"discoveryMode"];
    [cfg persistValue:@YES forKey:@"logEveryIntercept"];
    [stats addEvent:[NSString stringWithFormat:@"开始抓取，请立刻去搜索并播放一首灰歌"]];
    UNMLogI(@"===== 开始诊断抓取（%.0f 秒）=====", seconds);
    UNMLogI(@"统计已清零：本报告的拦截/会话/接口列表都只反映这 %.0f 秒", seconds);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [cfg persistValue:oldLogLevel ?: @3 forKey:@"logLevel"];
        [cfg persistValue:oldDiscovery ?: @NO forKey:@"discoveryMode"];
        [cfg persistValue:oldEveryIntercept ?: @NO forKey:@"logEveryIntercept"];

        UNMStats *st = [UNMStats shared];
        NSMutableString *report = [NSMutableString string];
        [report appendFormat:@"UNMiOS 诊断抓取报告（最近 %.0f 秒）  版本 %s\n",
            seconds, UNMVersionString()];
        [report appendString:@"统计已清零，下面全部只反映本窗口。\n\n"];
        [report appendString:[st detailDump]];
        [report appendFormat:@"\n配置文件：%@\n日志文件：%@\n",
            [cfg configPath], UNMLogFilePath()];

        [report appendString:@"\n—— 最后一首为什么失败 ——\n"];
        [report appendString:[UNMModelHook lastAttemptText]];
        [report appendString:@"\n—— 模型层调用计数 ——\n"];
        [report appendString:[UNMModelHook countersText]];

        // KuWo's "app only" tracks show up here as rejected candidates, which is
        // what makes "the song resolved but still would not play" diagnosable.
        NSArray<NSString *> *rejections = UNMValidationLog();
        if (rejections.count) {
            [report appendString:@"\n—— 被拒绝的候选链接 ——\n"];
            for (NSString *line in rejections) [report appendFormat:@"  %@\n", line];
        }
        [report appendString:@"\n—— 模型层接管明细 ——\n"];
        [report appendString:[UNMModelHook statusText]];
        [report appendString:@"\n"];

        // The client's model classes are the next thing to work with, so they
        // travel with the report rather than requiring a separate trip. Matched on
        // member names, since class-name matching only ever found peripheral
        // Swift modules.
        [report appendString:@"\n—— 持有版权判定的类（按命中数排序）——\n"];
        [report appendString:[UNMRuntimeDump privilegeModelDump]];
        [report appendString:@"\n\n—— 关键模型类的完整成员/方法 ——\n"];
        [report appendString:[UNMRuntimeDump keyModelDetailDump]];
        [report appendString:@"\n\n—— 已加载的 App 自带库 ——\n"];
        [report appendString:[UNMRuntimeDump imageDump]];
        [report appendString:@"\n"];

        NSString *text = [report copy];
        // Logged at ERROR so it is impossible to miss in the log file, and shown
        // in the UI at the same time.
        UNMLogE(@"########## 诊断抓取报告 ##########\n%@\n##########", text);

        if (completion) completion(text);
    });
}

@end
