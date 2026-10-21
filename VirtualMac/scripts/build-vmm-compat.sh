#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUTPUT="${VZ_VMM_COMPAT_OUTPUT:-$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/LaunchServicesCompat.dylib}"
ENTITLEMENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"

need_command ldid
need_command xcrun
need_file "$ENTITLEMENTS"
need_file "$VZ_REPO_ROOT/vz/host/lsshim.m"
need_file "$VZ_REPO_ROOT/vz/host/vmmhook.m"
need_file "$VZ_REPO_ROOT/vz/host/pvg_trace.m"
need_file "$VZ_REPO_ROOT/vz/host/modern_pvg_memory.m"
need_file "$VZ_REPO_ROOT/vz/host/modern_pvg_task.m"
need_file "$VZ_REPO_ROOT/vz/host/modern_pvg_fault_observation.m"
need_file "$VZ_REPO_ROOT/vz/host/modern_pvg_guest_linear_alignment.m"
need_file "$VZ_REPO_ROOT/vz/host/modern_pvg_guest_texture_buffer_alignment.h"
need_file "$VZ_REPO_ROOT/vz/host/modern_pvg_guest_texture_buffer_alignment.m"

mkdir -p "$(dirname "$OUTPUT")"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name "@rpath/LaunchServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/lsshim.m" \
    "$VZ_REPO_ROOT/vz/host/vmmhook.m" \
    "$VZ_REPO_ROOT/vz/host/pvg_trace.m" \
    "$VZ_REPO_ROOT/vz/host/modern_pvg_memory.m" \
    "$VZ_REPO_ROOT/vz/host/modern_pvg_task.m" \
    "$VZ_REPO_ROOT/vz/host/modern_pvg_fault_observation.m" \
    "$VZ_REPO_ROOT/vz/host/modern_pvg_guest_linear_alignment.m" \
    "$VZ_REPO_ROOT/vz/host/modern_pvg_guest_texture_buffer_alignment.m" \
    -o "$OUTPUT"
# These project entries must be local definitions before signing.
nm -gU "$OUTPUT" | awk '    BEGIN {
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
ldid -S"$ENTITLEMENTS" "$OUTPUT"

echo "VMM compatibility library built: $OUTPUT"
echo "CDHash: $(ldid -h "$OUTPUT" | sed -n 's/^CDHash=//p')"
