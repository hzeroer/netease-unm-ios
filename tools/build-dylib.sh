#!/usr/bin/env bash
#
# Build UNMiOS.dylib without Theos.
#
# Only two things are needed:
#   * clang (any recent LLVM, including the Linux packages - lld handles the
#     Mach-O link, so no cctools / ld64 port is required)
#   * an iPhoneOS SDK (the theos/sdks repo is the usual source)
#
# Usage:
#   IOS_SDK=/opt/theos/sdks/iPhoneOS16.5.sdk ./tools/build-dylib.sh
#   THEOS=/opt/theos ./tools/build-dylib.sh          # SDK auto-discovered
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
mkdir -p "$OUT"

# ---------------------------------------------------------------- find the SDK
SDK="${IOS_SDK:-}"
if [[ -z "$SDK" ]]; then
    for base in "${THEOS:-/opt/theos}" "$HOME/theos" /opt/theos /usr/local/theos; do
        if [[ -d "$base/sdks" ]]; then
            # Highest version first.
            candidate="$(ls -1d "$base"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1 || true)"
            if [[ -n "${candidate:-}" ]]; then SDK="$candidate"; break; fi
        fi
    done
fi
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
    echo "error: no iPhoneOS SDK found. Set IOS_SDK=/path/to/iPhoneOSXX.sdk" >&2
    echo "       (theos/sdks is the usual source of these)" >&2
    exit 1
fi
echo "==> SDK: $SDK"

# ------------------------------------------------------------------ toolchain
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null || { echo "error: clang not found" >&2; exit 1; }

# lld is what lets a Linux/macOS clang emit a Mach-O dylib; probe for it.
LD_FLAG="-fuse-ld=lld"
if ! "$CLANG" --version 2>/dev/null | grep -qi 'clang version'; then
    echo "warn: unexpected clang, continuing anyway"
fi
if command -v ld64.lld >/dev/null 2>&1 || command -v ld.lld >/dev/null 2>&1; then
    echo "==> linker: lld ($(command -v ld64.lld 2>/dev/null || command -v ld.lld))"
else
    echo "warn: lld not found in PATH; falling back to the default linker" >&2
    LD_FLAG=""
fi

# Minimum iOS version. 14.0 is enough for every client build worth un-greying
# and keeps the flags simple.
MIN_IOS="${MIN_IOS:-14.0}"
PLATFORM_VER="-Wl,-platform_version,ios,$MIN_IOS,$MIN_IOS"

ARCHS="${ARCHS:-arm64}"

SOURCES=("$ROOT"/src/*.m)

build_arch() {
    local arch="$1"
    local out="$OUT/UNMiOS-$arch.dylib"
    echo "==> compiling $arch"
    # shellcheck disable=SC2086
    "$CLANG" \
        -target "$arch-apple-ios$MIN_IOS" \
        -isysroot "$SDK" \
        -dynamiclib \
        -fobjc-arc \
        -fblocks \
        -fmodules \
        -O2 \
        -Wno-unused-parameter \
        -Wno-deprecated-declarations \
        -Isrc \
        "${SOURCES[@]}" \
        -framework Foundation \
        -framework UIKit \
        -Wl,-install_name,@executable_path/UNMiOS.dylib \
        $PLATFORM_VER \
        $LD_FLAG \
        -o "$out"
    echo "    -> $out"
    ls -l "$out"
}

for arch in $ARCHS; do
    build_arch "$arch"
done

# ------------------------------------------------------------------ lipo step
if [[ "$(echo "$ARCHS" | wc -w)" -gt 1 ]]; then
    echo "==> combining architectures"
    LIPO=""
    for candidate in llvm-lipo llvm-lipo-20 llvm-lipo-19 llvm-lipo-18 llvm-lipo-17 lipo \
                     /usr/lib/llvm-18/bin/llvm-lipo /usr/lib/llvm-17/bin/llvm-lipo; do
        if command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]]; then
            LIPO="$candidate"
            break
        fi
    done
    if [[ -n "$LIPO" ]]; then
        files=()
        for arch in $ARCHS; do files+=("$OUT/UNMiOS-$arch.dylib"); done
        if "$LIPO" -create "${files[@]}" -output "$OUT/UNMiOS.dylib" 2>"$OUT/.lipo.err"; then
            echo "    -> $OUT/UNMiOS.dylib (universal, via $LIPO)"
        else
            # llvm on Linux collapses arm64e onto arm64, which is expected: the
            # App Store client is arm64 anyway, so ship that slice.
            echo "warn: lipo failed ($(head -1 "$OUT/.lipo.err" 2>/dev/null)); shipping arm64" >&2
            first_arch="$(echo "$ARCHS" | awk '{print $1}')"
            cp "$OUT/UNMiOS-$first_arch.dylib" "$OUT/UNMiOS.dylib"
        fi
        rm -f "$OUT/.lipo.err"
    else
        echo "warn: no lipo found; shipping the first arch only" >&2
        first_arch="$(echo "$ARCHS" | awk '{print $1}')"
        cp "$OUT/UNMiOS-$first_arch.dylib" "$OUT/UNMiOS.dylib"
    fi
else
    cp "$OUT/UNMiOS-$ARCHS.dylib" "$OUT/UNMiOS.dylib"
fi

# ------------------------------------------------------------------- verify
echo "==> verifying Mach-O"
if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump --macho --dylibs-used "$OUT/UNMiOS.dylib" || true
elif command -v file >/dev/null 2>&1; then
    file "$OUT/UNMiOS.dylib"
fi

# A flat-namespace bind means the linker let a symbol through that this dylib
# references but never defines. dyld then aborts the host app the first time that
# code runs, which is how an "undefined symbol" bug reaches a device instead of
# failing the build. Check for it explicitly and refuse to ship.
if command -v llvm-objdump >/dev/null 2>&1; then
    BINDS=$(mktemp)
    llvm-objdump --macho --bind "$OUT/UNMiOS.dylib"        >> "$BINDS" 2>/dev/null || true
    llvm-objdump --macho --lazy-bind "$OUT/UNMiOS.dylib"   >> "$BINDS" 2>/dev/null || true

    FLAT_COUNT=$(grep -c "flat-namespace" "$BINDS" || true)
    if [[ "${FLAT_COUNT:-0}" -gt 0 ]]; then
        echo >&2
        echo "error: ${FLAT_COUNT} flat-namespace bind(s) found." >&2
        echo "       These are symbols this dylib calls but does not define and does not" >&2
        echo "       link against. dyld will abort the app on first use of each one:" >&2
        grep "flat-namespace" "$BINDS" | sed 's/^/         /' >&2
        rm -f "$BINDS"
        exit 1
    fi
    rm -f "$BINDS"
    echo "    unresolved symbols: 0 (no flat-namespace binds)"
fi

echo
echo "==> done"
sha256sum "$OUT/UNMiOS.dylib" 2>/dev/null || shasum -a 256 "$OUT/UNMiOS.dylib"
