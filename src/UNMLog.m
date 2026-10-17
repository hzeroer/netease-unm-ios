//
//  UNMLog.m
//

#import "UNMLog.h"
#import <stdarg.h>
#import <unistd.h>

static UNMLogLevel gLevel = UNMLogInfo;
static BOOL gDiscovery = NO;
static NSString *gLogPath = nil;
static NSLock *gLogLock = nil;
static unsigned long long gLogBytes = 0;

static const unsigned long long kUNMLogMaxBytes = 4ULL * 1024 * 1024;

static NSString *UNMLogDirectory(void) {
    // Inside a sandboxed app NSHomeDirectory() is the app container, which is
    // exactly what we want: writable, no jailbreak, no entitlements needed.
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) {
        caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    }
    NSString *dir = [caches stringByAppendingPathComponent:@"unmios"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    return dir;
}

void UNMLogSetLevel(UNMLogLevel level) { gLevel = level; }
UNMLogLevel UNMLogGetLevel(void) { return gLevel; }

void UNMLogSetDiscovery(BOOL on) { gDiscovery = on; }
BOOL UNMLogDiscovery(void) { return gDiscovery; }

NSString *UNMLogFilePath(void) {
    if (!gLogPath) {
        gLogPath = [UNMLogDirectory() stringByAppendingPathComponent:@"unmios.log"];
    }
    return gLogPath;
}

static void UNMEnsureInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogLock = [[NSLock alloc] init];
        NSString *p = UNMLogFilePath();
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
        gLogBytes = attr.fileSize;

        // Rotate once when the file grows past the cap.
        if (gLogBytes > kUNMLogMaxBytes) {
            NSString *bak = [p stringByAppendingString:@".1"];
            [[NSFileManager defaultManager] removeItemAtPath:bak error:NULL];
            [[NSFileManager defaultManager] moveItemAtPath:p toPath:bak error:NULL];
            gLogBytes = 0;
        }
    });
}

static void UNMAppendToFile(NSString *line) {
    UNMEnsureInit();
    [gLogLock lock];
    @try {
        NSString *path = UNMLogFilePath();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            gLogBytes = line.length;
        } else {
            [fh seekToEndOfFile];
            NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
            [fh writeData:d];
            [fh closeFile];
            gLogBytes += d.length;
        }
    } @catch (NSException *e) {
        // Logging must never take the app down.
        (void)e;
    } @finally {
        [gLogLock unlock];
    }
}

static NSString *UNMLevelTag(UNMLogLevel level) {
    switch (level) {
        case UNMLogError: return @"E";
        case UNMLogWarn:  return @"W";
        case UNMLogInfo:  return @"I";
        case UNMLogDebug: return @"D";
        default:          return @"?";
    }
}

static NSString *UNMFormatNow(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    return [fmt stringFromDate:[NSDate date]];
}

void UNMLogv(UNMLogLevel level, NSString *fmt, ...) {
    if (level > gLevel) return;

    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@][%@][pid %d][tid %llu] %@\n",
                      UNMFormatNow(), UNMLevelTag(level), getpid(),
                      (unsigned long long)[NSThread currentThread].hash,
                      msg ?: @""];

    UNMAppendToFile(line);
    // Also go to the system log so `idevicesyslog | grep UNMiOS` works.
    NSLog(@"[UNMiOS]%@", line);
}

void UNMLogRaw(NSString *line) {
    if (line.length == 0) return;
    UNMAppendToFile([line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"]);
}
