#!/bin/bash
# Experimental backend reconstruction, separate from the 22D68 release build.
# Apple ships these frameworks as binaries; this builds the porting layers and
# reconstructs their relocations, rather than compiling proprietary Apple source.
set -euo pipefail

if [[ $# != 4 ]]; then
    echo "Usage: $0 <dyld-cache> <isolated-venv> <stock-ipsw> <output-directory>" >&2
    exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSC="$1"
VENV="$2"
STOCK_IPSW="$3"
OUTPUT="$4"
[[ -f "$DSC" && -f "$VENV/pyvenv.cfg" && -x "$VENV/bin/python3" && -x "$STOCK_IPSW" ]] || {
    echo "Provide a readable cache, an isolated venv, and stock ipsw." >&2
    exit 2
}
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
VENV="$(cd "$VENV" && pwd)"
STOCK_IPSW="$(cd "$(dirname "$STOCK_IPSW")" && pwd)/$(basename "$STOCK_IPSW")"
PYTHON="$VENV/bin/python3"
SITE="$($PYTHON -c 'import pathlib, DyldExtractor; print(pathlib.Path(DyldExtractor.__file__).resolve().parent.parent)')"
case "$SITE" in "$VENV"/*) ;; *) echo "Refusing to patch a global Python package." >&2; exit 2 ;; esac
[[ "$($PYTHON -c 'from importlib.metadata import version; print(version("dyldextractor"))')" == 2.2.2 ]] || {
    echo "This experimental patch set targets DyldExtractor 2.2.2." >&2
    exit 2
}

patches=(arm64e slide-v5 modern-load-commands relative-base-lists protocol-size shared-method-types)
for name in "${patches[@]}"; do
    file="$REPO_ROOT/patches/dyldextractor-2.2.2-$name.patch"
    if patch --dry-run --forward -p1 -d "$SITE" < "$file" > /dev/null 2>&1; then
        patch --forward -p1 -d "$SITE" < "$file"
    elif ! patch --dry-run --reverse -p1 -d "$SITE" < "$file" > /dev/null 2>&1; then
        echo "Patch does not match the isolated toolchain: $file" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT/dyldex" "$OUTPUT/macos" "$OUTPUT/ios" "$OUTPUT/logs"
: > "$OUTPUT/logs/manifest.txt"
cat > "$OUTPUT/EXPERIMENTAL.txt" <<'EOF'
Experimental modern PVG / MetalSerializer port.
Build and file-format validation are separate from native object initialization,
GPU submission, old-VMM compatibility, and iPad runtime validation.
The outputs are not wired into the shipping VMM or its trustcache.
EOF
"$PYTHON" "$REPO_ROOT/scripts/tests/test-modern-dyld-cache.py" > "$OUTPUT/logs/slide-tests.txt" 2>&1

ADAPTER="$OUTPUT/ipsw-a2sb"
"$PYTHON" - "$ADAPTER" "$PYTHON" "$REPO_ROOT/vz/development/tools/cache-a2s-batch.py" <<'PY'
import pathlib, shlex, sys
path = pathlib.Path(sys.argv[1])
path.write_text('#!/bin/sh\nexec ' + shlex.join(sys.argv[2:]) + ' "$@"\n')
path.chmod(0o755)
PY

export VZ_IPSW="$ADAPTER" VZ_STOCK_IPSW="$STOCK_IPSW"
export VZ_A2S_CACHE="${VZ_A2S_CACHE:-$OUTPUT/symbols.a2s}"
export PYTHONUNBUFFERED=1

for name in ParavirtualizedGraphics MetalSerializer; do
    image="$name.framework/Versions/A/$name"
    "$VENV/bin/dyldex" -e "$image" -o "$OUTPUT/dyldex/$name" "$DSC" > "$OUTPUT/logs/$name-extract.txt" 2>&1
    # The production cache intentionally lacks private local symbols. Any
    # other extraction error is a build failure, even if dyldex exits zero.
    "$PYTHON" - "$OUTPUT/logs/$name-extract.txt" <<'PY'
from pathlib import Path
import sys
errors = [line for line in Path(sys.argv[1]).read_text().splitlines()
          if 'ERROR' in line and "Symbols Cache doesn't contain local symbols" not in line]
if errors:
    raise SystemExit('\n'.join(errors))
PY
    VZ_MAC=1 "$PYTHON" "$REPO_ROOT/vz/uncache.py" "$DSC" "$image" \
        "$OUTPUT/dyldex/$name" "$OUTPUT/macos/$name" compact > "$OUTPUT/logs/$name-macos.txt" 2>&1
    codesign --force --sign - "$OUTPUT/macos/$name"
    codesign --verify "$OUTPUT/macos/$name"
    dyld_info -validate_only "$OUTPUT/macos/$name" > "$OUTPUT/logs/$name-macos-validate.txt" 2>&1
    VZ_MAC= "$PYTHON" "$REPO_ROOT/vz/uncache.py" "$DSC" "$image" \
        "$OUTPUT/dyldex/$name" "$OUTPUT/ios/$name.proto" compact > "$OUTPUT/logs/$name-ios.txt" 2>&1
    "$PYTHON" "$REPO_ROOT/vz/stamp_ios.py" "$OUTPUT/ios/$name.proto" "$OUTPUT/ios/$name" 16.1
    dyld_info -validate_only "$OUTPUT/ios/$name" > "$OUTPUT/logs/$name-ios-validate.txt" 2>&1
    codesign --verify "$OUTPUT/ios/$name"
    dwarfdump --uuid "$OUTPUT/ios/$name" >> "$OUTPUT/logs/manifest.txt"
    shasum -a 256 "$OUTPUT/macos/$name" "$OUTPUT/ios/$name" >> "$OUTPUT/logs/manifest.txt"
done

xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=16.1 \
    -dynamiclib -fblocks -framework Foundation -Wl,-reexport_framework,Metal \
    -install_name @rpath/MetalCompat.dylib \
    "$REPO_ROOT/vz/host/native_bc_texture_support.m" "$REPO_ROOT/vz/host/metalshim.m" \
    -o "$OUTPUT/ios/MetalCompat.dylib"
codesign --force --sign - "$OUTPUT/ios/MetalCompat.dylib"
dyld_info -validate_only "$OUTPUT/ios/MetalCompat.dylib" > "$OUTPUT/logs/MetalCompat-validate.txt" 2>&1

xcrun clang -fobjc-arc -Wall -Wextra -Werror -arch arm64e -mmacosx-version-min=13.0 \
    "$REPO_ROOT/vz/development/probes/pvg-backend-api.m" -framework Foundation \
    -o "$OUTPUT/pvg-backend-api"
"$OUTPUT/pvg-backend-api" "$OUTPUT/macos/ParavirtualizedGraphics" \
    "$OUTPUT/macos/MetalSerializer" > "$OUTPUT/logs/native-api-load.txt" 2>&1
"$OUTPUT/pvg-backend-api" > "$OUTPUT/logs/native-system-api.txt" 2>&1
"$PYTHON" - "$OUTPUT/logs/native-system-api.txt" "$OUTPUT/logs/native-api-load.txt" \
    > "$OUTPUT/logs/api-comparison.txt" <<'PY'
from pathlib import Path
import sys

def contract(path):
    # Runtime method order is unspecified; image paths deliberately differ.
    result, cls = {}, None
    for line in Path(path).read_text().splitlines():
        if line.startswith('class='):
            cls = line.split()[0]
            result[cls] = {line}
        elif line.startswith('  ') and not line.startswith('  classImage='):
            result[cls].add(line)
        elif line.startswith('legacyDescriptorSelector='):
            result.setdefault('legacy', set()).add(line)
    return result

native, candidate = map(contract, sys.argv[1:])
if native != candidate:
    for cls in sorted(native.keys() | candidate.keys()):
        for line in sorted(native.get(cls, set()) ^ candidate.get(cls, set())):
            print('API mismatch:', cls, line)
    raise SystemExit('Reconstructed API differs from the source system')
print('Selected class presence, method encodings, and legacy descriptor selectors match the native system.')
print('Compared contract entries:', sum(len(values) for values in native.values()))
PY
echo "Candidate build and native API probe completed: $OUTPUT"
