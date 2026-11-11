#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/guest-independent"
DEPENDENCY="$VZ_REPO_ROOT/third-party/apple-auth/prebuilt/macos-arm64_x86_64"
EXPECTED=69ee8eb959aabaf5b4444fc57958d98d037ff2897f8684c1c034186d9f7bddca
ACTUAL=$(shasum -a 256 "$DEPENDENCY/libapple_auth.a" | cut -d ' ' -f 1)
[[ "$ACTUAL" = "$EXPECTED" ]] || die "independent ADI dependency fingerprint mismatch"
mkdir -p "$OUT"
for arch in arm64 x86_64; do
    xcrun --sdk macosx clang++ -std=c++20 -arch "$arch" -O2 -fobjc-arc -fblocks \
        -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
        -I "$DEPENDENCY/Headers" "$VZ_REPO_ROOT/vz/guest/independent-identity-provider.mm" \
        "$DEPENDENCY/libapple_auth.a" -framework Foundation -framework IOKit \
        -framework Security -lcurl -lz -o "$OUT/independent-identity-provider.$arch"
done
xcrun lipo -create "$OUT/independent-identity-provider.arm64" \
    "$OUT/independent-identity-provider.x86_64" -output "$OUT/independent-identity-provider"
codesign --force --sign - "$OUT/independent-identity-provider"
codesign --verify --strict "$OUT/independent-identity-provider"
