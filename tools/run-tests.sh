#!/usr/bin/env bash
#
# Run the host-side unit tests.
#
# These execute the *real* source files -- the tolerant JSON parser, title
# normalisation, the fuzzy matcher, the BoDian request signature and the NetEase
# response rewriter -- against payloads recorded from the live services.
#
# Supported host: macOS (or any environment with Apple's Foundation and a modern
# Objective-C runtime).
#
# Why not Linux/GNUstep: GNUstep's default legacy ABI cannot auto-synthesise
# backing ivars for @property declarations, so the model/config classes in this
# project do not compile there. Building libobjc2 + gnustep-base from source
# would fix it but is far more setup than a unit test is worth. macOS gets it
# for free, and CI runs it on every push (.github/workflows/build.yml).
#
# Only UNMStore is replaced, by a stub implementing the identical header, so the
# tests stay hermetic: no network, no touching the user's music library.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/tests"
mkdir -p "$OUT"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: these tests need Apple's Foundation (run them on macOS)." >&2
    echo "       Reason: GNUstep's legacy Objective-C ABI cannot synthesise" >&2
    echo "       property backing ivars, which this project relies on." >&2
    exit 1
fi

SOURCES=(
    "$ROOT/src/UNMUtil.m"
    "$ROOT/src/UNMLog.m"
    "$ROOT/src/UNMConfig.m"
    "$ROOT/src/UNMInternal.m"
    "$ROOT/src/UNMMatcher.m"
    "$ROOT/src/UNMRewriter.m"
    "$ROOT/src/UNMBodianSign.m"
    "$ROOT/test/UNMStoreStub.m"
    "$ROOT/test/unm_test.m"
)

echo "==> compiling tests"
clang \
    -fobjc-arc \
    -fblocks \
    -I"$ROOT/src" \
    -I"$ROOT/test" \
    -Wno-unused-parameter \
    -Wno-deprecated-declarations \
    -framework Foundation \
    "${SOURCES[@]}" \
    -o "$OUT/unm_test"

echo "==> running"
# Keep test artefacts out of the user's real config/preference paths.
UNM_TEST=1 "$OUT/unm_test"
