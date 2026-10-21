#!/bin/bash
# Build the small runtime backports without replacing the OS's libc++ or Metal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT="${1:?Usage: build-modern-runtime.sh output-directory}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
VENDOR="$REPO_ROOT/vendor/llvm-charconv"

# Retain the upstream files unchanged. Compile only the nine to_chars overloads
# that the backend needs; integer and from_chars exports stay with system libc++.
python3 - "$VENDOR/src/charconv.cpp" "$OUTPUT/to_chars_backport.cpp" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
license = source[:source.index('#include <charconv>')]
start = source.index('// The original version of floating-point to_chars')
end = source.index('template <class _Fp>')
Path(sys.argv[2]).write_text(license +
    '#include <charconv>\n#include "include/to_chars_floating_point.h"\n' +
    '_LIBCPP_BEGIN_NAMESPACE_STD\n' + source[start:end] +
    '_LIBCPP_END_NAMESPACE_STD\n')
PY

common=(-std=c++20 -O2 -fno-typed-cxx-new-delete -D_LIBCPP_BUILDING_LIBRARY
    -D_LIBCPP_DISABLE_AVAILABILITY -I"$VENDOR/src" -dynamiclib -fblocks
    -framework Foundation -install_name @rpath/ModernRuntimeCompat.dylib)
sources=("$OUTPUT/to_chars_backport.cpp" "$VENDOR/src/ryu/d2s.cpp"
    "$VENDOR/src/ryu/f2s.cpp" "$VENDOR/src/ryu/d2fixed.cpp"
    "$REPO_ROOT/vz/host/modern_runtime_compat.mm")
xcrun --sdk iphoneos clang++ -arch arm64e -miphoneos-version-min=16.1 \
    "${common[@]}" "${sources[@]}" -o "$OUTPUT/ModernRuntimeCompat.dylib"
codesign --force --sign - "$OUTPUT/ModernRuntimeCompat.dylib"
codesign --verify "$OUTPUT/ModernRuntimeCompat.dylib"
dyld_info -validate_only "$OUTPUT/ModernRuntimeCompat.dylib"
xcrun clang++ -arch arm64e -mmacosx-version-min=13.0 \
    -DVZ_RUNTIME_COMPAT_NATIVE_TEST "${common[@]}" "${sources[@]}" \
    -o "$OUTPUT/ModernRuntimeCompat.mac.dylib"
codesign --force --sign - "$OUTPUT/ModernRuntimeCompat.mac.dylib"
nm -gU "$OUTPUT/ModernRuntimeCompat.dylib" > "$OUTPUT/exports.txt"
echo "Runtime backports built: $OUTPUT/ModernRuntimeCompat.dylib"
