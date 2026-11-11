#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
need_command xcrun
need_command codesign
OUT="$VZ_BUILD_ROOT/host-sepbridge"
mkdir -p "$OUT"
cat > "$OUT/helper.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>get-task-allow</key><true/>
</dict></plist>
PLIST
xcrun --sdk iphoneos clang -arch arm64e \
    -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -O2 -fobjc-arc -fblocks \
    -Wall -Wextra -Werror -framework Foundation \
    "$VZ_REPO_ROOT/vz/guest/sepbridge-helper.m" -o "$OUT/sepbridge-helper"
xcrun --sdk iphoneos clang -arch arm64e \
    -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -O2 -fobjc-arc -fblocks \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -dynamiclib \
    -framework Foundation "$VZ_REPO_ROOT/vz/guest/sepinject.m" \
    -o "$OUT/sepinject.dylib"
codesign --force --sign - --entitlements "$OUT/helper.entitlements" "$OUT/sepbridge-helper"
codesign --force --sign - "$OUT/sepinject.dylib"
codesign --verify --strict "$OUT/sepbridge-helper"
codesign --verify --strict "$OUT/sepinject.dylib"
cp "$VZ_REPO_ROOT/vz/guest/com.mac.virtual.sepbridge.host.plist" "$OUT/"
printf 'Built opt-in host SEP relay: %s\n' "$OUT"
