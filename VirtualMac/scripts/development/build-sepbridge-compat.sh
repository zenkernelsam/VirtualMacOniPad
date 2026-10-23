#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

need_command xcrun
need_command codesign

OUT="${VZ_SEPBRIDGE_GUEST_BUILD:-$VZ_BUILD_ROOT/guest-sepbridge}"
SOURCE="$VZ_REPO_ROOT/vz/guest/SEPBridgeCompat.m"
mkdir -p "$OUT"

for architecture in x86_64 arm64 arm64e; do
    xcrun --sdk macosx clang \
        -arch "$architecture" \
        -dynamiclib -fobjc-arc -fblocks \
        -mmacosx-version-min=12.0 \
        -framework CoreFoundation -framework Foundation \
        "$SOURCE" \
        -o "$OUT/SEPBridgeCompat.$architecture.dylib"
done

xcrun lipo -create \
    "$OUT/SEPBridgeCompat.x86_64.dylib" \
    "$OUT/SEPBridgeCompat.arm64.dylib" \
    "$OUT/SEPBridgeCompat.arm64e.dylib" \
    -output "$OUT/SEPBridgeCompat.dylib"
codesign --force --sign - "$OUT/SEPBridgeCompat.dylib"

echo "Built $OUT/SEPBridgeCompat.dylib"
xcrun lipo -archs "$OUT/SEPBridgeCompat.dylib"
