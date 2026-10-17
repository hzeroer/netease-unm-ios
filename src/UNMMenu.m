//
//  UNMMenu.m
//

#import "UNMMenu.h"

#import <UIKit/UIKit.h>

#import "UNMConfig.h"
#import "UNMCrashGuard.h"
#import "UNMDiagnose.h"
#import "UNMHook.h"
#import "UNMLog.h"
#import "UNMModelHook.h"
#import "UNMProvider.h"
#import "UNMRewriter.h"
#import "UNMRuntimeDump.h"
#import "UNMStats.h"
#import "UNMStore.h"
#import "UNMUtil.h"
#import "UNMVersion.h"

#pragma mark - Small helpers

static UIWindowScene *UNMActiveWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    // Pre-iOS 13 fallback.
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.windowScene) return window.windowScene;
    }
    return nil;
}

static void UNMAlertInput(UIViewController *host,
                          NSString *title,
                          NSString *message,
                          NSString *current,
                          UIKeyboardType keyboard,
                          void (^apply)(NSString *text)) {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                           message:message
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.keyboardType = keyboard;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        apply(alert.textFields.firstObject.text ?: @"");
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

static void UNMAlertInfo(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

/// Reads the tail of a file without loading a multi-megabyte log into memory.
static NSString *UNMTailOfFile(NSString *path, NSUInteger maxBytes) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return @"（没有日志文件）";

    @try {
        unsigned long long size = [handle seekToEndOfFile];
        unsigned long long start = size > maxBytes ? size - maxBytes : 0;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataToEndOfFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        return text.length ? text : @"（日志为空）";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"（读取日志失败：%@）", e.reason];
    } @finally {
        [handle closeFile];
    }
}

#pragma mark - Row model

typedef NS_ENUM(NSInteger, UNMRowKind) {
    UNMRowDetail = 0,   // read-only "title ......... value"
    UNMRowSwitch,       // bound to a UNMConfig key
    UNMRowAction,       // runs a block
    UNMRowInput,        // opens a text prompt for a UNMConfig key
};

@interface UNMRow : NSObject
@property (nonatomic) UNMRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic, copy, nullable) NSString *detail;
@property (nonatomic, copy, nullable) NSString *inputHint;
@property (nonatomic) UIKeyboardType keyboard;
@property (nonatomic, copy, nullable) void (^action)(UIViewController *host);
@end

@implementation UNMRow
@end

@interface UNMSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *footer;
@property (nonatomic, strong) NSMutableArray<UNMRow *> *rows;
@end

@implementation UNMSection
- (instancetype)init {
    if ((self = [super init])) _rows = [NSMutableArray array];
    return self;
}
@end

#pragma mark - Text output screen

@interface UNMOutputController : UIViewController
@property (nonatomic, copy) NSString *heading;
@property (nonatomic, copy) NSString *body;
@end

@implementation UNMOutputController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.heading;
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    textView.text = self.body;
    [self.view addSubview:textView];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                     target:self
                                                     action:@selector(share)];
}

- (void)share {
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[ self.body ?: @"" ]
                                          applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

@end

#pragma mark - Self-test screen

@interface UNMTestController : UITableViewController
@property (nonatomic, copy) NSString *keyword;
@end

@implementation UNMTestController {
    NSArray<UNMDiagnoseResult *> *_results;
    NSString *_summary;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音源自检";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"重跑"
                                        style:UIBarButtonItemStylePlain
                                       target:self
                                       action:@selector(rerun)];
    [self rerun];
}

- (void)rerun {
    __weak typeof(self) weakSelf = self;
    _summary = @"运行中…";
    _results = @[];
    [self.tableView reloadData];

    [UNMDiagnose runWithKeyword:self.keyword
                     completion:^(NSArray<UNMDiagnoseResult *> *results, NSString *summary) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        self_->_results = results;
        self_->_summary = summary;
        [self_.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? _summary : @"明细";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 0 : (NSInteger)_results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"UNMTestCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cellID];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    UNMDiagnoseResult *row = _results[(NSUInteger)indexPath.row];
    BOOL ok = row.url.length > 0;

    cell.textLabel.text = [NSString stringWithFormat:@"%@%@", ok ? @"✅" : @"❌", row.provider];
    cell.textLabel.textColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;

    if (ok) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ - %@\n搜 %.0fms / 取链 %.0fms\n%@",
                                     row.matchedArtist ?: @"", row.matchedTitle ?: @"",
                                     row.searchMilliseconds, row.resolveMilliseconds,
                                     row.url];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n候选 %ld 条  搜 %.0fms",
                                     row.error ?: @"未知原因",
                                     (long)row.candidateCount, row.searchMilliseconds];
    }
    return cell;
}

@end

#pragma mark - Settings table

@interface UNMMenuListController : UITableViewController
@end

@implementation UNMMenuListController {
    NSArray<UNMSection *> *_sections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"UNMiOS 解灰";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                        style:UIBarButtonItemStyleDone
                                       target:self
                                       action:@selector(close)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 48;
    [self rebuild];
}

- (void)close {
    [UNMMenu dismiss];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
}

#pragma mark Model

- (void)rebuild {
    UNMConfig *cfg = [UNMConfig shared];
    [cfg forceReload];

    NSMutableArray<UNMSection *> *sections = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;

    // -------- 状态
    UNMSection *status = [UNMSection new];
    status.title = @"状态";
    {
        UNMRow *row = [UNMRow new];
        row.kind = UNMRowDetail;
        row.title = @"版本";
        row.detail = [NSString stringWithFormat:@"%s  by %@%@", UNMVersionString(),
                      UNMAuthorString(),
                      [UNMCrashGuard safeModeEngaged] ? @"  ⚠️ 安全模式" : @""];
        [status.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowDetail;
        row.title = @"运行统计";
        row.detail = [[UNMStats shared] summary];
        [status.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowDetail;
        row.title = @"音源";
        row.detail = [cfg.providerOrder componentsJoinedByString:@", "];
        [status.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowDetail;
        row.title = @"配置来源";
        row.detail = cfg.loadedFrom.lastPathComponent ?: @"默认值";
        [status.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowDetail;
        row.title = @"缓存";
        row.detail = [[UNMStore shared] stats];
        [status.rows addObject:row];
    }
    status.footer = @"拦截数为 0 说明请求根本没进来，先看「诊断」。";
    [sections addObject:status];

    // -------- 自检
    UNMSection *test = [UNMSection new];
    test.title = @"自检";
    {
        UNMRow *row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"运行自检（晴天 周杰伦）";
        row.action = ^(UIViewController *host) {
            UNMTestController *vc = [UNMTestController new];
            vc.keyword = @"晴天 周杰伦";
            [host.navigationController pushViewController:vc animated:YES];
        };
        [test.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"自定义关键词自检";
        row.action = ^(UIViewController *host) {
            UNMAlertInput(host, @"自检关键词", @"格式：歌名 歌手", @"晴天 周杰伦",
                          UIKeyboardTypeDefault, ^(NSString *text) {
                UNMTestController *vc = [UNMTestController new];
                vc.keyword = text;
                [host.navigationController pushViewController:vc animated:YES];
            });
        };
        [test.rows addObject:row];
    }
    test.footer = @"自检只测音源连通性，不依赖网易云，也不需要播放任何歌。";
    [sections addObject:test];

    // -------- 开关
    UNMSection *switches = [UNMSection new];
    switches.title = @"开关";
    {
        NSArray *keys = @[
            @[ @"enabled",              @"总开关" ],
            @[ @"rewritePrivilege",     @"改写权限接口（灰歌变白）" ],
            @[ @"rewritePlayerURL",     @"改写播放取链接口" ],
            @[ @"rewriteDownloadURL",   @"改写下载取链接口" ],
            @[ @"enableXRealIP",        @"注入 X-Real-IP（解海外锁区）" ],
            @[ @"prefetchFromPrivilege",@"权限解锁后预取" ],
            @[ @"neteaseDetailFallback",@"缺元数据时用网易 detail 补齐" ],
            @[ @"logEveryIntercept",    @"记录每个被拦截的请求" ],
            @[ @"discoveryMode",        @"发现模式（只观察 + 打调用栈）" ],
            @[ @"forceUnblock",         @"强制解灰（接管 App 自身的版权判定）" ],
            @[ @"rejectVariants",       @"严格拒绝变体版本（remix/live/伴奏不顶替原版）" ],
            @[ @"onlyReplaceGrey",      @"只替换灰歌（不动有版权的歌和云盘）" ],
        ];
        for (NSArray *pair in keys) {
            UNMRow *row = [UNMRow new];
            row.kind = UNMRowSwitch;
            row.key = pair[0];
            row.title = pair[1];
            [switches.rows addObject:row];
        }
    }
    switches.footer = @"发现模式会写 classes.txt 并打印 App 侧调用栈，排查新版本客户端用。";
    [sections addObject:switches];

    // -------- 音源
    UNMSection *providers = [UNMSection new];
    providers.title = @"音源";
    // Only two sources, both kept visible so it is obvious what is being tried.
    //
    // MiGu first: it has the studio recordings. KuGou second: it has what MiGu
    // does not (华研's catalogue) and needs no cookie.
    for (NSString *key in @[ @"bodian", @"migu" ]) {
        UNMRow *row = [UNMRow new];
        row.kind = UNMRowSwitch;
        row.key = [@"provider." stringByAppendingString:key];
        row.title = key;
        row.detail = @{ @"migu"  : @"咪咕（匿名可用，含无损）",
                        @"bodian" : @"波点（酷我镜像，免 cookie）",
                        @"kugou" : @"酷狗（免 cookie，覆盖华研等）" }[key];
        [providers.rows addObject:row];
    }
    providers.footer = @"按顺序尝试：波点 → 咪咕。两者都不限速、不需要账号。";
    [sections addObject:providers];

    // -------- 参数
    UNMSection *params = [UNMSection new];
    params.title = @"参数";
    {
        UNMRow *row = [UNMRow new];
        row.kind = UNMRowInput;
        row.key = @"matchThreshold";
        row.title = @"匹配阈值";
        row.detail = [NSString stringWithFormat:@"%.2f", cfg.matchThreshold];
        row.keyboard = UIKeyboardTypeDecimalPad;
        [params.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowInput;
        row.key = @"lookupTimeoutMS";
        row.title = @"单音源超时";
        row.detail = [NSString stringWithFormat:@"%ld ms", (long)cfg.lookupTimeoutMS];
        row.keyboard = UIKeyboardTypeNumberPad;
        [params.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowInput;
        row.key = @"totalTimeoutMS";
        row.title = @"单首歌总预算";
        row.detail = [NSString stringWithFormat:@"%ld ms", (long)cfg.totalTimeoutMS];
        row.keyboard = UIKeyboardTypeNumberPad;
        [params.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowInput;
        row.key = @"xRealIP";
        row.title = @"X-Real-IP";
        row.detail = cfg.xRealIP;
        row.keyboard = UIKeyboardTypeNumbersAndPunctuation;
        [params.rows addObject:row];

    }
    params.footer = @"这些值只写在本机配置文件里，不会上传到任何地方。";
    [sections addObject:params];

    // -------- 入口
    UNMSection *entries = [UNMSection new];
    entries.title = @"入口";
    for (NSArray *pair in @[ @[ @"showFloatingButton", @"悬浮球" ],
                             @[ @"enableShakeMenu", @"摇一摇打开" ],
                             @[ @"showNavBarEntry", @"导航栏按钮" ] ]) {
        UNMRow *row = [UNMRow new];
        row.kind = UNMRowSwitch;
        row.key = pair[0];
        row.title = pair[1];
        [entries.rows addObject:row];
    }
    entries.footer = @"导航栏按钮可能和 App 自己的按钮冲突，默认关闭。悬浮球和摇一摇改完立刻生效。";
    [sections addObject:entries];

    // -------- 工具
    UNMSection *tools = [UNMSection new];
    tools.title = @"工具";
    {
        // One tap instead of "edit a plist, restart, reproduce, extract a log".
        // Statistics are reset at the start, so everything in the report describes
        // exactly this window.
        UNMRow *captureRow = [UNMRow new];
        captureRow.kind = UNMRowAction;
        captureRow.title = @"抓取 60 秒诊断";
        captureRow.detail = @"点一下 → 立刻去【搜索】里播一首灰歌 → 60 秒后自动出报告";
        captureRow.action = ^(UIViewController *host) {
            __weak UINavigationController *nav = host.navigationController;
            [[UNMStats shared] addEvent:@"开始 60 秒抓取"];
            [UNMDiagnose startCaptureWithSeconds:60 completion:^(NSString *report) {
                UNMOutputController *vc = [UNMOutputController new];
                vc.heading = @"诊断抓取报告";
                vc.body = report;
                if (nav) [nav pushViewController:vc animated:YES];
            }];
            UNMAlertInfo(host, @"已开始抓取（60 秒）",
                         @"请在这 60 秒内【连续切换 3 首不同的歌】：\n\n"
                         @"每首播 5 秒就切下一首。切歌会强制客户端去取新的播放地址 ——\n"
                         @"如果连切 3 首都没有取链请求，就说明地址不是客户端请求来的。\n\n"
                         @"报告里的「请求时间线」是这次的判据：它按时间顺序记录了\n"
                         @"App 发出的每个请求（含音频 CDN），能看出「先有取链请求、\n"
                         @"还是直接就出现音频了」。");
        };
        [tools.rows addObject:captureRow];

        // The play URL arrives over a channel that never appears as a request, so
        // the client's own "not playable" decision is the reachable target. Its
        // classes are discoverable at runtime; this is how we learn their names.
        UNMRow *dumpRow = [UNMRow new];
        dumpRow.kind = UNMRowAction;
        dumpRow.title = @"导出 App 类结构";        dumpRow.detail = @"版权相关类 + NMSong/NMSongPrivilege/NMSongUrlInfo 的完整成员与方法";
        dumpRow.action = ^(UIViewController *host) {
            NSMutableString *body = [NSMutableString string];
            [body appendString:@"—— 关键模型类的完整成员/方法 ——\n\n"];
            [body appendString:[UNMRuntimeDump keyModelDetailDump]];
            [body appendString:@"\n\n—— 持有版权判定的类（按命中数排序）——\n\n"];
            [body appendString:[UNMRuntimeDump privilegeModelDump]];
            [body appendString:@"\n\n—— 已加载的 App 自带库 ——\n\n"];
            [body appendString:[UNMRuntimeDump imageDump]];
            UNMOutputController *vc = [UNMOutputController new];
            vc.heading = @"App 类结构";
            vc.body = body;
            [host.navigationController pushViewController:vc animated:YES];
        };
        [tools.rows addObject:dumpRow];

        // Which model hooks actually took hold. Without this the only feedback for
        // "the list is still grey" is silence.
        UNMRow *modelRow = [UNMRow new];
        modelRow.kind = UNMRowAction;
        modelRow.title = @"模型层接管状态";
        modelRow.detail = @"哪些成员已被接管，以及各自被调用了多少次";
        modelRow.action = ^(UIViewController *host) {
            NSMutableString *body = [NSMutableString string];
            [body appendString:@"—— 最后一首为什么失败 ——\n\n"];
            [body appendString:[UNMModelHook lastAttemptText]];
            [body appendString:@"\n—— 调用计数（诊断哪一环断了）——\n\n"];
            [body appendString:[UNMModelHook countersText]];
            [body appendString:@"\n\n—— 接管明细 ——\n\n"];
            [body appendString:[UNMModelHook statusText]];
            UNMOutputController *vc = [UNMOutputController new];
            vc.heading = @"模型层接管状态";
            vc.body = body;
            [host.navigationController pushViewController:vc animated:YES];
        };
        [tools.rows addObject:modelRow];

        if ([UNMCrashGuard safeModeEngaged]) {
            UNMRow *row = [UNMRow new];
            row.kind = UNMRowAction;
            row.title = @"退出安全模式（重新启用）";
            row.detail = @"当前所有 hook 和改写都已停用";
            row.action = ^(UIViewController *host) {
                [UNMCrashGuard clearSafeMode];
                exit(0);
            };
            [tools.rows addObject:row];
        }

        if ([UNMCrashGuard lastCrashReport].length) {
            UNMRow *row = [UNMRow new];
            row.kind = UNMRowAction;
            row.title = @"崩溃报告（发给作者）";
            row.detail = [UNMCrashGuard crashReportPath];
            row.action = ^(UIViewController *host) {
                UNMOutputController *vc = [UNMOutputController new];
                vc.heading = @"崩溃报告";
                vc.body = [UNMCrashGuard lastCrashReport] ?: @"（无）";
                [host.navigationController pushViewController:vc animated:YES];
            };
            [tools.rows addObject:row];
        }

        UNMRow *row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"诊断";
        row.action = ^(UIViewController *host) {
            UNMOutputController *vc = [UNMOutputController new];
            vc.heading = @"诊断";
            vc.body = [NSString stringWithFormat:@"规则版本：%@\n\n%@",
                       [UNMRewriter rulesVersion], [[UNMStats shared] detailDump]];
            [host.navigationController pushViewController:vc animated:YES];
        };
        [tools.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"查看日志";
        row.action = ^(UIViewController *host) {
            UNMOutputController *vc = [UNMOutputController new];
            vc.heading = @"日志";
            vc.body = UNMTailOfFile(UNMLogFilePath(), 256 * 1024);
            [host.navigationController pushViewController:vc animated:YES];
        };
        [tools.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"当前配置";
        row.action = ^(UIViewController *host) {
            UNMOutputController *vc = [UNMOutputController new];
            vc.heading = @"配置";
            vc.body = [NSString stringWithFormat:@"%@\n\n配置文件：\n%@\n\n日志文件：\n%@\n",
                       [[UNMConfig shared] dump], [[UNMConfig shared] configPath],
                       UNMLogFilePath()];
            [host.navigationController pushViewController:vc animated:YES];
        };
        [tools.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"重置统计";
        row.action = ^(UIViewController *host) {
            [[UNMStats shared] reset];
            [[UNMConfig shared] persistValue:@NO forKey:@"discoveryMode"];
            [host.navigationController popToRootViewControllerAnimated:NO];
        };
        [tools.rows addObject:row];

        row = [UNMRow new];
        row.kind = UNMRowAction;
        row.title = @"重启 App";
        row.detail = @"配置改动大多热生效，改了注入层开关后需要重启";
        row.action = ^(UIViewController *host) {
            UNMLogI(@"user requested restart");
            [[UNMStore shared] flush];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                exit(0);
            });
        };
        [tools.rows addObject:row];
    }
    [sections addObject:tools];

    (void)weakSelf;
    _sections = sections;
    [self.tableView reloadData];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[(NSUInteger)section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _sections[(NSUInteger)section].footer;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_sections[(NSUInteger)section].rows.count;
}

- (BOOL)configBoolForKey:(NSString *)key {
    UNMConfig *cfg = [UNMConfig shared];

    if ([key hasPrefix:@"provider."]) {
        NSString *provider = [key substringFromIndex:@"provider.".length];
        return [cfg.providerOrder containsObject:provider];
    }
    id value = [cfg valueForKey:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (void)setConfigBool:(BOOL)on forKey:(NSString *)key {
    UNMConfig *cfg = [UNMConfig shared];

    if ([key hasPrefix:@"provider."]) {
        NSString *provider = [key substringFromIndex:@"provider.".length];
        NSMutableArray *order = [cfg.providerOrder mutableCopy] ?: [NSMutableArray array];
        if (on) {
            if (![order containsObject:provider]) [order addObject:provider];
        } else {
            [order removeObject:provider];
        }
        // Keep a canonical order so the search order stays predictable.
        NSArray *canonical = @[ @"kuwo", @"bodian", @"kugou", @"migu" ];
        NSMutableArray *sorted = [NSMutableArray array];
        for (NSString *k in canonical) if ([order containsObject:k]) [sorted addObject:k];
        [cfg persistValue:sorted forKey:@"providerOrder"];
        return;
    }
    [cfg persistValue:@(on) forKey:key];

    // Remember that a human flipped the master switch, so a later launch does not
    // mistake it for residue left behind by safe mode and switch it back on.
    if ([key isEqualToString:@"enabled"]) {
        [cfg setRawBool:YES forKey:@"enabledTouchedByUser"];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"UNMMenuCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cellID];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }

    UNMRow *row = _sections[(NSUInteger)indexPath.section].rows[(NSUInteger)indexPath.row];

    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.detail;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    switch (row.kind) {
        case UNMRowSwitch: {
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.onTintColor = UIColor.systemGreenColor;
            toggle.on = [self configBoolForKey:row.key];
            toggle.tag = indexPath.section * 1000 + indexPath.row;
            [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case UNMRowAction:
            cell.detailTextLabel.text = row.detail ?: (row.kind == UNMRowAction ? nil : @"");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.textColor = UIColor.labelColor;
            break;
        case UNMRowInput:
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case UNMRowDetail:
        default:
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
    }
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSInteger section = toggle.tag / 1000;
    NSInteger index = toggle.tag % 1000;
    UNMRow *row = _sections[(NSUInteger)section].rows[(NSUInteger)index];
    [self setConfigBool:toggle.isOn forKey:row.key];
    [UNMMenu install];   // entry-point toggles take effect immediately
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UNMRow *row = _sections[(NSUInteger)indexPath.section].rows[(NSUInteger)indexPath.row];

    if (row.kind == UNMRowAction && row.action) {
        row.action(self);
        return;
    }

    if (row.kind != UNMRowInput) return;
    __weak typeof(self) weakSelf = self;

    if ([row.key isEqualToString:@"miguCookie"] || [row.key isEqualToString:@"kugouCookie"]) {
        NSString *provider = [row.key isEqualToString:@"miguCookie"] ? @"migu" : @"kugou";
        NSString *current = [UNMConfig shared].providerCookies[provider] ?: @"";
        UNMAlertInput(self, [NSString stringWithFormat:@"%@ cookie", provider],
                      @"粘贴抓包得到的 Cookie 整行；留空则清除", current,
                      UIKeyboardTypeDefault, ^(NSString *text) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            NSMutableDictionary *cookies = [[UNMConfig shared].providerCookies mutableCopy] ?: [NSMutableDictionary dictionary];
            if (UNMTrim(text).length) cookies[provider] = UNMTrim(text);
            else [cookies removeObjectForKey:provider];
            [[UNMConfig shared] persistValue:cookies forKey:@"providerCookies"];
            [self_ rebuild];
        });
        return;
    }

    UIView *source = [tableView cellForRowAtIndexPath:indexPath];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:row.title
                                           message:nil
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = row.detail;
        field.keyboardType = row.keyboard;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"留空恢复默认值";
        field.keyboardType = row.keyboard;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *text = UNMTrim(alert.textFields.firstObject.text ?: @"");
        if (text.length == 0) {
            [[UNMConfig shared] persistValue:nil forKey:row.key];
        } else if ([row.key hasSuffix:@"MS"]) {
            [[UNMConfig shared] persistValue:@(text.integerValue) forKey:row.key];
        } else if ([row.key isEqualToString:@"matchThreshold"]) {
            [[UNMConfig shared] persistValue:@(text.doubleValue) forKey:row.key];
        } else {
            [[UNMConfig shared] persistValue:text forKey:row.key];
        }
        [self_ rebuild];
    }]];
    alert.popoverPresentationController.sourceView = source;
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Floating ball

@interface UNMBallWindow : UIWindow
@property (nonatomic, strong) UIButton *button;
@end

@implementation UNMBallWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // The window is only as large as the ball, but be explicit so nothing else
    // in it can ever swallow a touch meant for the app underneath.
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == nil) ? nil : hit;
}

@end

#pragma mark - UNMMenu

// Defined further down; declared here because +install hooks them by name.
static void UNMHookedMotionEnded(id self_, SEL _cmd, UIEventSubtype subtype, UIEvent *event);
static void UNMHookedViewDidAppear(id self_, SEL _cmd, BOOL animated);

@implementation UNMMenu

#pragma mark Entry points

+ (void)install {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }
    [self installUIHooksOnce];

    UNMConfig *cfg = [UNMConfig shared];
    [cfg reload];

    if (!cfg.showFloatingButton) {
        if (gBallWindow) gBallWindow.hidden = YES;
        [self detachHostBall];
        return;
    }
    [self showBall];
}

+ (void)installUIHooksOnce {
    if (gUIHooksInstalled) return;
    gUIHooksInstalled = YES;

    // In safe mode we still want the ball (it is how the crash report gets read
    // and safe mode gets cleared) but no swizzling of the host's UI at all.
    if ([UNMCrashGuard safeModeEngaged]) {
        UNMLogI(@"安全模式：跳过 UI hook，仅保留悬浮球");
        return;
    }

    // Shake to open: needs no cooperation from the host app's UI at all, which
    // is why it is the reliable fallback when the ball is turned off.
    Class windowClass = objc_getClass("UIWindow");
    if (windowClass) {
        BOOL ok = UNMHookInst(windowClass, @selector(motionEnded:withEvent:),
                              (IMP)UNMHookedMotionEnded, &gOrigMotionEnded);
        UNMLogI(@"hook UIWindow.motionEnded:withEvent: %@", ok ? @"ok" : @"skipped");
    }

    // Apps very often implement shake detection in their own view controller,
    // which would swallow the event before the window ever sees it. Hooking the
    // controller too means the panel still opens; we call the original either
    // way so the app keeps its own behaviour.
    Class vcClass = objc_getClass("UIViewController");
    if (vcClass) {
        BOOL ok = UNMHookInst(vcClass, @selector(motionEnded:withEvent:),
                              (IMP)UNMHookedMotionEnded, &gOrigMotionEndedVC);
        UNMLogI(@"hook UIViewController.motionEnded:withEvent: %@", ok ? @"ok" : @"skipped");
    }

    // Optional bar button, injected on every appearance of a top view controller.
    if (vcClass) {
        BOOL ok = UNMHookInst(vcClass, @selector(viewDidAppear:),
                              (IMP)UNMHookedViewDidAppear, &gOrigViewDidAppear);
        UNMLogI(@"hook UIViewController.viewDidAppear: %@", ok ? @"ok" : @"skipped");
    }
}

+ (void)present {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self present]; });
        return;
    }
    if (gMenuWindow && !gMenuWindow.hidden) return;
    if (!UNMActiveWindowScene()) return;   // cannot show a window without a scene

    UNMMenuListController *root = [[UNMMenuListController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIWindow *window = gMenuWindow;
    if (!window) {
        window = [[UIWindow alloc] init];
        window.windowLevel = UIWindowLevelAlert + 501;
        gMenuWindow = window;
    }
    window.windowScene = UNMActiveWindowScene();
    window.rootViewController = nav;
    window.hidden = NO;
    if (window.windowScene) [window makeKeyAndVisible];
}

+ (void)dismiss {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; });
        return;
    }
    gMenuWindow.hidden = YES;
    // Give the key window back to the app.
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window == gMenuWindow || window == gBallWindow) continue;
        if (window.isKeyWindow || window.hidden == NO) {
            [window makeKeyWindow];
            break;
        }
    }
}

#pragma mark Ball

// Shared state. Declared before the ball helpers because they reference it.
static UNMBallWindow *gBallWindow = nil;   // dedicated window (primary path)
static UIWindow *gMenuWindow = nil;        // settings panel window
static UIButton *gBallButton = nil;        // moved between the two hosts
static UIWindow *gHostWindow = nil;        // app window used as fallback host
static NSTimer *gRefrontTimer = nil;
static BOOL gUIHooksInstalled = NO;
static IMP gOrigMotionEnded = NULL;        // UIWindow
static IMP gOrigMotionEndedVC = NULL;      // UIViewController
static IMP gOrigViewDidAppear = NULL;

/// The window the app itself is showing.
///
/// Used as a fallback host when no window scene can be found: a subview on the
/// app's own window always displays, which beats a floating ball that silently
/// never appears. That failure mode is indistinguishable from a broken build, so
/// it is worth the extra path.
static UIWindow *UNMHostWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.rootViewController) return window;
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow && window.rootViewController) return window;
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window == gBallWindow || window == gMenuWindow) continue;
        if (!window.hidden && window.rootViewController) return window;
    }
    return nil;
}

+ (UIButton *)ballButton {
    static const CGFloat size = 52.0;
    if (gBallButton) return gBallButton;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, size, size);
    button.backgroundColor = [UIColor colorWithRed:0.78 green:0.16 blue:0.16 alpha:0.92];
    button.layer.cornerRadius = size / 2.0;
    button.layer.borderWidth = 2.0;
    button.layer.borderColor = UIColor.whiteColor.CGColor;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    [button addTarget:self action:@selector(present) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(handlePan:)]];
    gBallButton = button;
    return button;
}

/// The ball doubles as a status LED: red until a request has been seen, green
/// once rewriting is actually happening.
+ (void)updateBallAppearance {
    BOOL working = [UNMStats shared].intercepts > 0 || [UNMStats shared].rewrites > 0;
    [gBallButton setTitle:(working ? @"\n灰→播" : @"\nUNM") forState:UIControlStateNormal];
    gBallButton.backgroundColor = working
        ? [UIColor colorWithRed:0.11 green:0.55 blue:0.24 alpha:0.92]
        : [UIColor colorWithRed:0.78 green:0.16 blue:0.16 alpha:0.92];
}

+ (void)placeBall {
    static const CGFloat size = 52.0;
    CGPoint center = [self savedBallCenter];
    if (CGPointEqualToPoint(center, CGPointZero)) {
        CGSize screenSize = UIScreen.mainScreen.bounds.size;
        center = CGPointMake(screenSize.width - size / 2.0 - 6.0, screenSize.height * 0.62);
    }
    CGRect frame = CGRectMake(center.x - size / 2.0, center.y - size / 2.0, size, size);
    if (gBallWindow) gBallWindow.frame = frame;
    else gBallButton.frame = frame;
}

+ (void)detachHostBall {
    if (gHostWindow && gBallButton.superview == gHostWindow) {
        [gBallButton removeFromSuperview];
    }
    gHostWindow = nil;
    [gRefrontTimer invalidate];
    gRefrontTimer = nil;
}

+ (void)showBall {
    UIButton *button = [self ballButton];
    [self updateBallAppearance];

    UIWindowScene *scene = UNMActiveWindowScene();
    if (scene) {
        // Primary path: a dedicated window just above everything. Its frame is
        // only as large as the ball, so it never swallows the app's own touches.
        [self detachHostBall];
        if (!gBallWindow) {
            UNMBallWindow *window = [[UNMBallWindow alloc] initWithWindowScene:scene];
            window.windowLevel = UIWindowLevelAlert + 500;
            window.backgroundColor = UIColor.clearColor;
            window.rootViewController = [[UIViewController alloc] init];
            gBallWindow = window;
        }
        gBallWindow.windowScene = scene;
        if (button.superview != gBallWindow.rootViewController.view) {
            [button removeFromSuperview];
            [gBallWindow.rootViewController.view addSubview:button];
        }
        [self placeBall];
        gBallWindow.hidden = NO;

        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            UNMLogI(@"悬浮球：窗口模式已就绪（scene=%@ level=%.0f frame=%@）",
                    NSStringFromClass(scene.class), gBallWindow.windowLevel,
                    NSStringFromCGRect(gBallWindow.frame));
        }
        return;
    }

    // Fallback: no scene yet (too early, or an app that does not use scenes).
    UIWindow *host = UNMHostWindow();
    if (!host) {
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            UNMLogI(@"悬浮球：还没有 window scene 也没有宿主窗口，稍后重试"
                     "（scenes=%lu windows=%lu）",
                    (unsigned long)UIApplication.sharedApplication.connectedScenes.count,
                    (unsigned long)UIApplication.sharedApplication.windows.count);
        }
        return;
    }

    if (gBallWindow) gBallWindow.hidden = YES;
    if (button.superview != host) {
        [button removeFromSuperview];
        [host addSubview:button];
    }
    [host bringSubviewToFront:button];
    gHostWindow = host;
    [self placeBall];

    if (!gRefrontTimer) {
        gRefrontTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
            (void)timer;
            if (gHostWindow && gBallButton.superview == gHostWindow) {
                [gHostWindow bringSubviewToFront:gBallButton];
            } else {
                [UNMMenu install];
            }
        }];
    }

    static BOOL loggedHost = NO;
    if (!loggedHost) {
        loggedHost = YES;
        UNMLogI(@"悬浮球：改用宿主窗口模式（%@，frame=%@）",
                NSStringFromClass(host.class), NSStringFromCGRect(button.frame));
    }
}

+ (CGPoint)savedBallCenter {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults objectForKey:@"UNMiOSBallCenter"];
    if (![saved isKindOfClass:NSDictionary.class]) return CGPointZero;
    return CGPointMake([saved[@"x"] doubleValue], [saved[@"y"] doubleValue]);
}

+ (void)saveBallCenter:(CGPoint)center {
    [NSUserDefaults.standardUserDefaults setObject:@{ @"x" : @(center.x), @"y" : @(center.y) }
                                            forKey:@"UNMiOSBallCenter"];
}

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    // Works whether the ball lives in our own window or as a subview of the app's
    // window: everything is expressed relative to its parent.
    UIView *target = gBallWindow ? (UIView *)gBallWindow : gBallButton;
    UIView *parent = target.superview;
    if (!parent) return;

    CGPoint translation = [pan translationInView:parent];
    CGPoint center = CGPointMake(target.center.x + translation.x, target.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:parent];
    target.center = center;

    if (pan.state != UIGestureRecognizerStateEnded &&
        pan.state != UIGestureRecognizerStateCancelled) return;

    // Snap to whichever side is closer, and stay inside the parent.
    CGFloat half = target.bounds.size.width / 2.0;
    CGFloat x = center.x < parent.bounds.size.width / 2.0 ? half + 6.0
                                                          : parent.bounds.size.width - half - 6.0;
    CGFloat y = MIN(MAX(center.y, half + 50.0), parent.bounds.size.height - half - 50.0);

    [UIView animateWithDuration:0.18 animations:^{
        target.center = CGPointMake(x, y);
    }];
    [self saveBallCenter:CGPointMake(x, y)];
}

#pragma mark Optional bar button

static void UNMInstallBarButton(UIViewController *controller) {
    UIViewController *top = controller.navigationController.topViewController;
    if (!top || top != controller) return;
    if ([top.navigationItem.rightBarButtonItem.title isEqualToString:@"UNM"]) return;

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"UNM"
                                                            style:UIBarButtonItemStylePlain
                                                           target:[UNMMenu class]
                                                           action:@selector(present)];
    [top.navigationItem setRightBarButtonItem:item animated:NO];
}

#pragma mark Hook bodies

static void UNMHookedMotionEnded(id self_, SEL _cmd, UIEventSubtype subtype, UIEvent *event) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (original) {
        ((void (*)(id, SEL, UIEventSubtype, UIEvent *))original)(self_, _cmd, subtype, event);
    }
    if (subtype != UIEventSubtypeMotionShake) return;
    if (![UNMConfig shared].enableShakeMenu) return;
    [[UNMStats shared] addEvent:@"摇一摇打开菜单"];
    [UNMMenu present];
}

static void UNMHookedViewDidAppear(id self_, SEL _cmd, BOOL animated) {
    IMP original = UNMHookOriginalForReceiver(self_, _cmd);
    if (original) {
        ((void (*)(id, SEL, BOOL))original)(self_, _cmd, animated);
    }
    if (![UNMConfig shared].showNavBarEntry) return;
    if (![self_ isKindOfClass:UIViewController.class]) return;
    UNMInstallBarButton((UIViewController *)self_);
}

@end
