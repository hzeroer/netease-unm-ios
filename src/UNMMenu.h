//
//  UNMMenu.h
//
//  In-app settings UI.
//
//  Three ways in, in order of robustness:
//    1. a floating ball (its own tiny UIWindow, so it never blocks the app)
//    2. shaking the device
//    3. an optional bar button, injected into whatever navigation controller is
//       on screen -- opt-in because the host app may own that button already
//
//  The ball/window approach is deliberate: it depends on nothing but UIKit, so
//  it keeps working when the host app reshuffles its own settings screens, and
//  it gives us a place to put the diagnostics that make "it still doesn't work"
//  answerable from the device itself.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UNMMenu : NSObject

/// Idempotent; safe to call from any thread.
+ (void)install;

/// Present the settings panel (used by the shake gesture and the bar button).
+ (void)present;

/// Hide the settings panel and hand the key window back to the host app.
+ (void)dismiss;

@end

NS_ASSUME_NONNULL_END
