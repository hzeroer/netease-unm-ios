//
//  UNMCrashGuard.h
//
//  Two jobs, both about surviving a bad build on a device we cannot debug:
//
//  1. Record why we died. A TrollFools-injected dylib that crashes on launch is
//     the worst case for the user: the app is unusable and un-injecting is
//     awkward. So the last exception or fatal signal is written to a file, with
//     a backtrace, and surfaced in the settings panel.
//
//  2. Fail safe. If the app dies within a few seconds of launching twice in a
//     row, we assume this build is broken, flip `enabled` off in the config and
//     stand down. The app then always starts, the user can open the panel, read
//     the crash report, and re-enable once a fixed build is in.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMCrashGuard : NSObject

/// Call this as the very first statement of the dylib constructor.
+ (void)installEarly;

/// YES when the previous launches kept dying: skip all hook installation.
+ (BOOL)safeModeEngaged;

/// Call once the app has been alive long enough to be considered healthy; this
/// clears the crash counter so the next crash starts counting from zero again.
+ (void)markBootHealthy;

/// Contents of the last crash report, or nil.
+ (NSString * _Nullable)lastCrashReport;
+ (NSString * _Nullable)crashReportPath;

/// Clears the crash counter and re-enables the tweak.
+ (void)clearSafeMode;

#pragma mark - Remembering who disabled the tweak

// Safe mode turns `enabled` off in the config so the next launch is clean. That
// makes it indistinguishable from the user switching the tweak off themselves --
// and if we ever forget to undo it, the app boots with the tweak disabled *and*
// no menu to re-enable it, because the menu is also behind the same flag.
//
// So the fact is recorded here, and a later launch restores the switch only when
// safe mode was the one that flipped it.

+ (void)markDisabledBySafeMode;
+ (BOOL)wasDisabledBySafeMode;
+ (void)clearDisabledBySafeModeFlag;

/// YES when this launch auto-cleared safe mode because the version changed.
///
/// Safe mode is only ever engaged because a previous build crashed, and that same
/// code path is what turns `enabled` off. So "we just cleared safe mode" is a
/// reliable signal that the off switch was not the user's doing, and the tweak
/// can be switched back on automatically.
+ (BOOL)safeModeWasAutoCleared;

@end

NS_ASSUME_NONNULL_END
