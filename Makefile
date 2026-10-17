# UNMiOS - NetEase Cloud Music un-grey tweak
#
# Two supported build paths:
#
#   1) tools/build-dylib.sh   -> plain UNMiOS.dylib, zero dependencies.
#                                This is the one TrollStore / TrollFools wants.
#   2) make package           -> .deb for a *jailbroken* device (Sileo/Zebra).
#
# The tweak deliberately uses its own libobjc-based swizzler instead of Logos,
# so it never links substrate / libhooker / Orion. That is what allows the very
# same binary to run both inside a jailed TrollStore app copy and on a
# jailbroken device.

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:14.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UNMiOS

UNMiOS_FILES = $(wildcard src/*.m)
UNMiOS_CFLAGS = -fobjc-arc -fblocks -Isrc -Wno-unused-parameter -Wno-deprecated-declarations
UNMiOS_FRAMEWORKS = Foundation UIKit
UNMiOS_PRIVATE_FRAMEWORKS =
# No substrate: every hook goes through src/UNMHook.m.
UNMiOS_LIBRARIES =
UNMiOS_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 NeteaseMusic 2>/dev/null || true"

.PHONY: dylib
dylib:
	./tools/build-dylib.sh
