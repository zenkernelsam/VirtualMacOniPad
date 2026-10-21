#!/bin/bash
# Build a separate 2.0 experiment; do not change the normal release version.
set -euo pipefail
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <working-payload-snapshot> <macos27-candidate> <output> --gpu-task-source <matching-macos27-xpc-executable> [--prebuilt-vmm <verified-vmm>] [--prebuilt-app <app>] [--preserve-app-signature] [--shader-cache <verified-air25-data-directory>] [--compiler-runtime <private-compiler-directory>] [--release-version <version>] [--build-number <number>]" >&2
    exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORIGINAL="$1"
CANDIDATE="$2"
OUTPUT="$3"
shift 3
GPU_TASK_SOURCE=""
PREBUILT_APP=""
package_options=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-task-source)
            [[ $# -ge 2 ]] || { echo "Missing GPU task source." >&2; exit 2; }
            GPU_TASK_SOURCE="$2"; shift 2 ;;
        --prebuilt-vmm)
            [[ $# -ge 2 ]] || { echo "Missing prebuilt VMM." >&2; exit 2; }
            package_options+=(--prebuilt-vmm "$2"); shift 2 ;;
        --prebuilt-app)
            [[ $# -ge 2 ]] || { echo "Missing prebuilt app." >&2; exit 2; }
            PREBUILT_APP="$2"; shift 2 ;;
        --shader-cache)
            [[ $# -ge 2 ]] || { echo "Missing shader cache directory." >&2; exit 2; }
            package_options+=(--shader-cache "$2"); shift 2 ;;
        --compiler-runtime)
            [[ $# -ge 2 ]] || { echo "Missing compiler runtime directory." >&2; exit 2; }
            package_options+=(--compiler-runtime "$2"); shift 2 ;;
        --release-version|--build-number)
            [[ $# -ge 2 ]] || { echo "Missing version value." >&2; exit 2; }
            package_options+=("$1" "$2"); shift 2 ;;
        --preserve-app-signature)
            package_options+=(--preserve-app-signature); shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -f "$GPU_TASK_SOURCE" ]] || {
    echo "Provide --gpu-task-source from the matching macOS 27 framework XPC bundle." >&2
    exit 2
}
# A standalone task from another OS version can pass Mach-O validation but
# speak a different PVG protocol. Require the source bundle's macOS 27 metadata.
python3 - "$GPU_TASK_SOURCE" <<'PY'
from pathlib import Path
import plistlib
import sys
source = Path(sys.argv[1]).resolve()
info = plistlib.loads((source.parent.parent / 'Info.plist').read_bytes())
if (info.get('CFBundleExecutable') != source.name or
    info.get('CFBundleIdentifier') != 'com.apple.gpusw.ParavirtualizedGraphicsGPUTask' or
    str(info.get('DTPlatformVersion', '')).split('.')[0] != '27' or
    'MacOSX' not in info.get('CFBundleSupportedPlatforms', [])):
    raise SystemExit('GPU task source must be the matching macOS 27 XPC executable and Info.plist')
PY
mkdir -p "$OUTPUT/runtime" "$OUTPUT/probes"
OUTPUT="$(cd "$OUTPUT" && pwd)"
bash "$SCRIPT_DIR/build-modern-runtime.sh" "$OUTPUT/runtime"

# Rebuild the current native Metal backports rather than reuse an early
# candidate's shim while compiling a newer task transport against it.
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=16.1 \
    -dynamiclib -fblocks -framework Foundation -Wl,-reexport_framework,Metal \
    -install_name @rpath/MetalCompat.dylib \
    "$REPO_ROOT/vz/host/native_bc_texture_support.m" "$REPO_ROOT/vz/host/metalshim.m" \
    -o "$OUTPUT/runtime/MetalCompat.dylib"
codesign --force --sign - "$OUTPUT/runtime/MetalCompat.dylib"
codesign --verify --strict "$OUTPUT/runtime/MetalCompat.dylib"

# Match the validated v14 VMM-side library (MRC, iOS14.5, no AVFAudio link).
xcrun --sdk iphoneos clang -arch arm64e \
    -dynamiclib -fno-objc-arc -fblocks -Wl,-undefined,dynamic_lookup -Wl,-no_adhoc_codesign \
    -miphoneos-version-min=14.5 -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name @rpath/LaunchServicesCompat.dylib \
    "$REPO_ROOT/vz/host/lsshim.m" "$REPO_ROOT/vz/host/vmmhook.m" \
    "$REPO_ROOT/vz/host/pvg_trace.m" "$REPO_ROOT/vz/host/modern_pvg_memory.m" \
    "$REPO_ROOT/vz/host/modern_pvg_task.m" \
    "$REPO_ROOT/vz/host/modern_pvg_fault_observation.m" \
    "$REPO_ROOT/vz/host/modern_pvg_guest_linear_alignment.m" \
    "$REPO_ROOT/vz/host/modern_pvg_guest_texture_buffer_alignment.m" \
    -o "$OUTPUT/runtime/LaunchServicesCompat.dylib"
# Dynamic lookup remains necessary for Apple's framework-facing hooks, but
# this project's task transport must actually be defined in the library.
# The task transport and alignment scope must be real local definitions.
nm -gU "$OUTPUT/runtime/LaunchServicesCompat.dylib" | awk '
    BEGIN {
        required["_VZModernInstallTaskTransport"]=1
        required["_VZModernInstallFaultObservation"]=1
        required["_VZModernInstallGuestLinearAlignmentAdvertisement"]=1
        required["_VZModernInstallGuestTextureBufferAlignmentAdvertisement"]=1
    }
    { if ($NF in required) delete required[$NF] }
    END {
        for (symbol in required) {
            print "Missing required local definition: " symbol > "/dev/stderr"
            missing=1
        }
        exit missing
    }'
# Sign only after all project definitions pass; dylibs have no process entitlements.
codesign --force --sign - --timestamp=none "$OUTPUT/runtime/LaunchServicesCompat.dylib"
codesign --verify --strict "$OUTPUT/runtime/LaunchServicesCompat.dylib"
bash "$SCRIPT_DIR/build-modern-gputask-compat.sh" \
    "$OUTPUT/runtime/ModernRuntimeCompat.dylib" "$OUTPUT/runtime/MetalCompat.dylib" \
    "$OUTPUT/runtime"
python3 "$SCRIPT_DIR/build-modern-gputask.py" "$GPU_TASK_SOURCE" "$OUTPUT/gpu-task"
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=16.1 \
    -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    "$REPO_ROOT/vz/development/probes/pvg-backend-contract.m" \
    -o "$OUTPUT/probes/pvg-backend-contract"
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=16.1 \
    -fblocks -framework Foundation -framework Metal \
    "$REPO_ROOT/vz/development/probes/modern-pvg-smoke.m" \
    "$REPO_ROOT/vz/host/modern_pvg_memory.m" \
    -o "$OUTPUT/probes/modern-pvg-smoke"
for probe in pvg-backend-contract modern-pvg-smoke; do
    codesign --force --sign - \
        --entitlements "$REPO_ROOT/vz/development/probes/Probe.entitlements" \
        "$OUTPUT/probes/$probe"
done
if [[ -n "$PREBUILT_APP" ]]; then
    APP="$PREBUILT_APP"
else
    # FileProvider may reattach FinderInfo while the existing guest/app build
    # signs its bundles. Build those bundles in a clean local temporary root.
    TEMP_APP_BUILD_ROOT="$(mktemp -d /private/tmp/virtualmac2-app-build.XXXXXX)"
    trap 'rm -rf -- "$TEMP_APP_BUILD_ROOT"' EXIT
    VZ_IGNORE_ENV_FILE=1 VZ_BUILD_ROOT="$TEMP_APP_BUILD_ROOT" VZ_RELEASE_VERSION=2.0.0 \
        bash "$REPO_ROOT/scripts/build-ipad-app.sh"
    python3 - "$TEMP_APP_BUILD_ROOT" "$OUTPUT/build" <<'PY'
from pathlib import Path
import shutil
import sys
source, destination = map(Path, sys.argv[1:])
shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=True)
PY
    rm -rf -- "$TEMP_APP_BUILD_ROOT"
    trap - EXIT
    APP="$OUTPUT/build/ipad-app/VirtualMac.app"
fi
python3 "$SCRIPT_DIR/package-virtualmac2.py" \
    --original-payload "$ORIGINAL" --candidate "$CANDIDATE" \
    --runtime "$OUTPUT/runtime" --probes "$OUTPUT/probes" \
    --gpu-task "$OUTPUT/gpu-task" --app "$APP" --output "$OUTPUT" \
    ${package_options[@]+"${package_options[@]}"}
echo "Built isolated Virtual Mac 2.0; deployment requires the manifest's trust scope."
