#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
need_command xcrun
need_command ldid
need_command codesign
OUTPUT="${VZ_PVG_BRIDGE_OUTPUT_DIR:-$VZ_BUILD_ROOT/pvg-resource-address-bridge}"
mkdir -p "$OUTPUT"
xcrun --sdk iphoneos clang -arch arm64e \
    -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" \
    -dynamiclib -fobjc-arc -Wall -Wextra -Werror -DVZ_PVG_BRIDGE_DIAGNOSTIC_INJECT=1 \
    "$VZ_REPO_ROOT/vz/host/pvg_resource_address_bridge.m" \
    -framework Foundation -framework Metal \
    -o "$OUTPUT/PVGResourceAddressBridge.dylib"
ldid -S "$OUTPUT/PVGResourceAddressBridge.dylib"
xcrun clang -arch arm64 -arch arm64e -arch x86_64 \
    -mmacosx-version-min=13.0 -dynamiclib -fobjc-arc -Wall -Wextra -Werror \
    "$VZ_REPO_ROOT/vz/guest/PVGResourceAddressCompat.m" \
    -framework Foundation -framework Metal \
    -o "$OUTPUT/PVGResourceAddressCompat.dylib"
codesign --force --sign - "$OUTPUT/PVGResourceAddressCompat.dylib"
echo "Built experimental host/guest bridge in $OUTPUT"
