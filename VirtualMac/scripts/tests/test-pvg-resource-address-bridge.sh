#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export VZ_IGNORE_ENV_FILE=1
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
need_command xcrun
OUTPUT="$VZ_BUILD_ROOT/tests/test-pvg-resource-address-bridge"
mkdir -p "$(dirname "$OUTPUT")"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$SCRIPT_DIR/test-pvg-resource-address-bridge.m" \
    -framework Foundation -framework Metal -o "$OUTPUT"
"$OUTPUT"
