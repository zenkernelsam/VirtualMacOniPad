#!/bin/sh
# make_identity_clone.sh — build a bootable identity-test clone of a VM
# bundle with a fresh AuxiliaryStorage and a MachineIdentifier that carries
# the given serial number.
#
# Run on the iPad as root. The source VM may be running: Disk.img is cloned
# with clonefile(2), which freezes its block map at that instant
# (crash-consistent, journal replay on boot). The source is never modified.
#
#   make_identity_clone.sh <src-bundle> <dst-bundle> <serial> <compat-dir> <tools-dir>
#
# compat-dir contains Hypervisor, ParavirtualizedGraphics, Virtualization
# (payload/Compatibility/iPadOS<NN>). tools-dir contains vz_identity_gen,
# vz_aux_create and vz_clonefile built for arm64e.
set -eu

SRC="$1"; DST="$2"; SERIAL="$3"; COMPAT="$4"; TOOLS="$5"

[ -d "$SRC" ] || { echo "missing source bundle: $SRC" >&2; exit 2; }
[ -e "$DST" ] && { echo "destination exists: $DST" >&2; exit 3; }

WORK="${TMPDIR:-/tmp}/vz-identity-$$"
mkdir -p "$DST" "$WORK"

"$TOOLS/vz_identity_gen" "$COMPAT" "$SERIAL" "$WORK/MachineIdentifier" || exit 4
"$TOOLS/vz_clonefile" "$SRC/Disk.img" "$DST/Disk.img" || exit 5
cp "$SRC/HardwareModel" "$DST/HardwareModel"
cp "$SRC/VirtualMac.plist" "$DST/VirtualMac.plist"
"$TOOLS/vz_aux_create" "$COMPAT" "$SRC/HardwareModel" "$DST/AuxiliaryStorage" || exit 6
cp "$WORK/MachineIdentifier" "$DST/MachineIdentifier"

# Keep the generated identity as the "original" so the app's identity pane
# reports it as configured rather than regenerated.
mkdir -p "$DST/Identities"
cp "$WORK/MachineIdentifier" "$DST/Identities/original.mid"

# The bundle lives under /var/mobile; the app expects the mobile owner.
chown -R mobile:mobile "$DST" 2>/dev/null || true

ls -l "$DST"
echo "identity clone ready: $DST (serial $SERIAL)"
