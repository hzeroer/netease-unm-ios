//
//  UNMCrashGuard.m
//

#import "UNMCrashGuard.h"
#import "UNMConfig.h"
#import "UNMLog.h"
#import "UNMUtil.h"
#import "UNMVersion.h"

#import <execinfo.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

static const NSTimeInterval kUNMHealthyBootSeconds = 8.0;
static const NSInteger kUNMRapidBootLimit = 2;

static BOOL gSafeMode = NO;
static BOOL gAutoClearedSafeMode = NO;
static BOOL gInstalled = NO;
static NSUncaughtExceptionHandler *gPreviousHandler = NULL;

#pragma mark - State file

static NSString *UNMGuardDirectory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    NSString *dir = [caches stringByAppendingPathComponent:@"unmios"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    return dir;
}

static NSString *UNMGuardStatePath(void) {
    return [UNMGuardDirectory() stringByAppendingPathComponent:@"boot.plist"];
}

static NSString *UNMCrashReportPath(void) {
    return [UNMGuardDirectory() stringByAppendingPathComponent:@"crash.log"];
}

#pragma mark - Reporting

static void UNMAppendCrashReport(NSString *text) {
    if (!text.length) return;
    NSString *path = UNMCrashReportPath();
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"===== %@ =====\n", [NSDate date]];
    [report appendString:text];
    [report appendString:@"\n\n"];

    // Keep the file small: it is read on a phone screen.
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (existing.length > 128 * 1024) existing = [existing substringFromIndex:existing.length - 64 * 1024];
    [(existing ?: @"") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];

    UNMLogRaw(text);
}

static NSString *UNMBacktraceString(void) {
    void *frames[64];
    int count = backtrace(frames, 64);
    char **symbols = backtrace_symbols(frames, count);
    NSMutableString *out = [NSMutableString stringWithString:@"backtrace:\n"];
    for (int i = 1; i < count; i++) {
        [out appendFormat:@"  #%d %s\n", i, symbols ? symbols[i] : "?"];
    }
    if (symbols) free(symbols);

    // The ObjC-level stack is far easier to read than raw addresses.
    [out appendString:@"objc stack:\n"];
    for (NSString *frame in [NSThread callStackSymbols]) {
        [out appendFormat:@"  %@\n", frame];
    }
    return out;
}

#pragma mark - Handlers

static void UNMExceptionHandler(NSException *exception) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"UNCAUGHT EXCEPTION in UNMiOS host process\n"];
    [report appendFormat:@"name:   %@\n", exception.name];
    [report appendFormat:@"reason: %@\n", exception.reason];
    [report appendFormat:@"userInfo: %@\n", exception.userInfo];
    for (NSString *line in exception.callStackSymbols) [report appendFormat:@"  %@\n", line];
    UNMAppendCrashReport(report);

    if (gPreviousHandler) gPreviousHandler(exception);
}

static void UNMSignalHandler(int signalNumber, siginfo_t *info, void *context) {
    (void)context;
    NSString *report = [NSString stringWithFormat:
        @"FATAL SIGNAL %d (%s)\naddress: %p\n%@",
        signalNumber, strsignal(signalNumber),
        info ? info->si_addr : NULL,
        UNMBacktraceString()];
    UNMAppendCrashReport(report);

    // Restore the default action so the OS still produces its own crash log,
    // which the user can find in 设置 → 隐私 → 分析与改进 → 分析数据.
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

#pragma mark - Public

@implementation UNMCrashGuard

+ (void)installEarly {
    if (gInstalled) return;
    gInstalled = YES;

    // ---- 1. Did the last launches die quickly?
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:UNMGuardStatePath()];
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval lastBoot = [state[@"lastBoot"] doubleValue];
    NSInteger rapidBoots = [state[@"rapidBoots"] integerValue];

    if (lastBoot > 0 && (now - lastBoot) < kUNMHealthyBootSeconds) {
        rapidBoots += 1;
    } else {
        rapidBoots = 1;
    }

    BOOL previousSafeMode = [state[@"safeMode"] boolValue];

    // A new build deserves a clean slate: otherwise a fixed version would stay
    // disabled forever because an older one crashed.
    NSString *previousVersion = [state[@"version"] isKindOfClass:NSString.class] ? state[@"version"] : nil;
    NSString *currentVersion = @(UNMVersionString());
    BOOL versionChanged = previousVersion.length && ![previousVersion isEqualToString:currentVersion];
    if (versionChanged && previousSafeMode) {
        rapidBoots = 0;
        previousSafeMode = NO;
        gAutoClearedSafeMode = YES;
    }

    if (previousSafeMode || rapidBoots > kUNMRapidBootLimit) {
        gSafeMode = YES;
        rapidBoots = 0;
    }

    [@{ @"lastBoot" : @(now),
        @"rapidBoots" : @(rapidBoots),
        @"safeMode" : @(gSafeMode),
        @"disabledBySafeMode" : @([state[@"disabledBySafeMode"] boolValue]),
        @"version" : currentVersion } writeToFile:UNMGuardStatePath() atomically:YES];

    // ---- 2. Handlers, so the *next* crash is explained.
    gPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&UNMExceptionHandler);

    static struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = UNMSignalHandler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);

    static const int signals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &action, NULL);
    }
}

+ (BOOL)safeModeEngaged { return gSafeMode; }

+ (BOOL)safeModeWasAutoCleared { return gAutoClearedSafeMode; }

+ (void)markBootHealthy {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:UNMGuardStatePath()];
    [@{ @"lastBoot" : @(CFAbsoluteTimeGetCurrent()),
        @"rapidBoots" : @0,
        @"safeMode" : @NO,
        @"disabledBySafeMode" : @([state[@"disabledBySafeMode"] boolValue]),
        @"version" : @(UNMVersionString()) } writeToFile:UNMGuardStatePath() atomically:YES];
    gSafeMode = NO;
}

+ (void)markDisabledBySafeMode {
    NSMutableDictionary *state = [[NSDictionary dictionaryWithContentsOfFile:UNMGuardStatePath()] mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];
    state[@"disabledBySafeMode"] = @YES;
    [state writeToFile:UNMGuardStatePath() atomically:YES];
}

+ (BOOL)wasDisabledBySafeMode {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:UNMGuardStatePath()];
    return [state[@"disabledBySafeMode"] boolValue];
}

+ (void)clearDisabledBySafeModeFlag {
    NSMutableDictionary *state = [[NSDictionary dictionaryWithContentsOfFile:UNMGuardStatePath()] mutableCopy];
    if (!state) return;
    state[@"disabledBySafeMode"] = @NO;
    [state writeToFile:UNMGuardStatePath() atomically:YES];
}

+ (NSString *)lastCrashReport {
    NSString *text = [NSString stringWithContentsOfFile:UNMCrashReportPath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (!text.length) return nil;
    // Report the most recent block only.
    NSRange lastSeparator = [text rangeOfString:@"=====" options:NSBackwardsSearch];
    (void)lastSeparator;
    return text.length > 16 * 1024 ? [text substringFromIndex:text.length - 16 * 1024] : text;
}

+ (NSString *)crashReportPath { return UNMCrashReportPath(); }

+ (void)clearSafeMode {
    gSafeMode = NO;
    [[NSFileManager defaultManager] removeItemAtPath:UNMGuardStatePath() error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:UNMCrashReportPath() error:NULL];
    [[UNMConfig shared] persistValue:@YES forKey:@"enabled"];
    UNMLogI(@"safe mode cleared");
}
@end
