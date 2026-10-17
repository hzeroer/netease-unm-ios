#!/usr/bin/env bash
#
# Package the built dylib into the two shapes that matter:
#
#   dist/UNMiOS.dylib   -> drop straight into TrollFools
#   dist/UNMiOS.deb     -> install on a jailbroken device via Sileo/Zebra
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
LAYOUT="$ROOT/layout/Library/MobileSubstrate/DynamicLibraries"

DYLIB="$DIST/UNMiOS.dylib"
[[ -f "$DYLIB" ]] || { echo "error: $DYLIB not found, run tools/build-dylib.sh first" >&2; exit 1; }

# Refuse to package a stale binary.
#
# A failed compile used to leave the previous dylib in place, and a pipeline's
# exit status is the last command's, so it is entirely possible to end up with a
# .deb labelled v2 built from a v1 binary. The version string inside the dylib is
# the ground truth, so compare it against control.
if command -v strings >/dev/null 2>&1; then
    CONTROL_VERSION="$(sed -n 's/^Version: *//p' "$ROOT/control" | head -1)"
    BINARY_VERSION="$(strings -a "$DYLIB" | sed -n 's/^UNMiOS_VERSION=//p' | head -1)"
    if [[ -z "$BINARY_VERSION" ]]; then
        echo "warn: no version marker in the dylib; skipping the staleness check" >&2
    elif [[ -n "$CONTROL_VERSION" && "$CONTROL_VERSION" != "$BINARY_VERSION" ]]; then
        echo "error: stale artefact -- the dylib reports $BINARY_VERSION but control says $CONTROL_VERSION." >&2
        echo "       Rebuild (tools/build-dylib.sh) and check that it actually succeeded." >&2
        exit 1
    else
        echo "==> version check: $BINARY_VERSION (matches control)"
    fi
fi

# Sign in place first, so the artefact that gets handed to TrollFools is signed
# too and not just the copy that goes into the .deb layout.
if command -v ldid >/dev/null 2>&1; then
    echo "==> signing with ldid"
    ldid -S "$DYLIB" || echo "warn: ldid failed, continuing unsigned"
else
    echo "==> ldid not present, leaving the dylib unsigned (fine for TrollFools)"
fi

mkdir -p "$LAYOUT"
cp "$DYLIB" "$LAYOUT/UNMiOS.dylib"
cp "$ROOT/UNMiOS.plist" "$LAYOUT/UNMiOS.plist"

# ------------------------------------------------------------------ .deb
if command -v dpkg-deb >/dev/null 2>&1; then
    echo "==> building deb"
    # Build in a real tmpfs/ext4 location: on a drvfs mount (WSL /mnt/c) chmod is
    # a no-op, and dpkg-deb refuses a control directory with 0777 permissions.
    DEBROOT="$(mktemp -d)"
    mkdir -p "$DEBROOT/DEBIAN"
    chmod 0755 "$DEBROOT" "$DEBROOT/DEBIAN"
    cp "$ROOT/control" "$DEBROOT/DEBIAN/control"
    chmod 0644 "$DEBROOT/DEBIAN/control"
    mkdir -p "$DEBROOT/Library/MobileSubstrate/DynamicLibraries"
    cp "$LAYOUT/UNMiOS.dylib" "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/UNMiOS.dylib"
    cp "$LAYOUT/UNMiOS.plist" "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/UNMiOS.plist"
    # rootless devices expect everything under /var/jb
    if [[ "${ROOTLESS:-0}" == "1" ]]; then
        mkdir -p "$DEBROOT/var/jb/Library/MobileSubstrate/DynamicLibraries"
        cp "$LAYOUT/UNMiOS.dylib" "$DEBROOT/var/jb/Library/MobileSubstrate/DynamicLibraries/UNMiOS.dylib"
        cp "$LAYOUT/UNMiOS.plist" "$DEBROOT/var/jb/Library/MobileSubstrate/DynamicLibraries/UNMiOS.plist"
    fi
    dpkg-deb --build --root-owner-group "$DEBROOT" "$DIST/UNMiOS.deb" >/dev/null
    rm -rf "$DEBROOT"
    echo "    -> $DIST/UNMiOS.deb"
    dpkg-deb -I "$DIST/UNMiOS.deb" | sed 's/^/    /'
else
    echo "warn: dpkg-deb missing, skipped the .deb" >&2
fi

echo
echo "==> artifacts"
ls -l "$DIST"
( cd "$DIST" && sha256sum UNMiOS.dylib > SHA256SUMS 2>/dev/null && cat SHA256SUMS ) || true
