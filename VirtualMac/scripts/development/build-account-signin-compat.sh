#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command xcrun
need_command codesign

OUT="${VZ_ACCOUNT_GUEST_BUILD:-$VZ_BUILD_ROOT/guest-account}"
SOURCE="$VZ_REPO_ROOT/vz/guest/AppleAccountSignInCompat.m"
mkdir -p "$OUT"

for architecture in x86_64 arm64 arm64e; do
    xcrun --sdk macosx clang \
        -arch "$architecture" \
        -dynamiclib -fobjc-arc -fblocks \
        -mmacosx-version-min=12.0 \
        -framework CoreFoundation -framework Foundation \
        "$SOURCE" \
        -o "$OUT/AppleAccountSignInCompat.$architecture.dylib"
done

xcrun lipo -create \
    "$OUT/AppleAccountSignInCompat.x86_64.dylib" \
    "$OUT/AppleAccountSignInCompat.arm64.dylib" \
    "$OUT/AppleAccountSignInCompat.arm64e.dylib" \
    -output "$OUT/AppleAccountSignInCompat.dylib"
codesign --force --sign - "$OUT/AppleAccountSignInCompat.dylib"

echo "Built $OUT/AppleAccountSignInCompat.dylib"
xcrun lipo -archs "$OUT/AppleAccountSignInCompat.dylib"
