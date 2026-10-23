#!/bin/sh
# make_identity_clone.sh — build a bootable identity-test clone of a VM
# bundle whose MachineIdentifier carries the given serial number.
#
# Run on the iPad as root. The source VM never changes: Disk.img and
# AuxiliaryStorage are both clonefile(2) clones.
#
# IMPORTANT (verified 2026-10-24): copy the source AuxiliaryStorage. A
# freshly created auxiliary storage (vz_aux_create) boots to a black screen
# on this VZ payload: the guest never reaches its OS and never opens the
# guest agent socket. The clone recipe that boots is:
#   cloned Disk.img + copied AuxiliaryStorage + serial-bound MachineIdentifier
#
#   make_identity_clone.sh <src-bundle> <dst-bundle> <serial> <compat-dir> <tools-dir>
#
# compat-dir contains Hypervisor, ParavirtualizedGraphics, Virtualization
# (payload/Compatibility/iPadOS<NN>). tools-dir contains vz_identity_gen
# and vz_clonefile built for arm64e.
set -eu

SRC="$1"; DST="$2"; SERIAL="$3"; COMPAT="$4"; TOOLS="$5"

[ -d "$SRC" ] || { echo "missing source bundle: $SRC" >&2; exit 2; }
[ -e "$DST" ] && { echo "destination exists: $DST" >&2; exit 3; }

WORK="${TMPDIR:-/tmp}/vz-identity-$$"
mkdir -p "$DST" "$WORK"

"$TOOLS/vz_identity_gen" "$COMPAT" "$SERIAL" "$WORK/MachineIdentifier" || exit 4
"$TOOLS/vz_clonefile" "$SRC/Disk.img" "$DST/Disk.img" || exit 5
"$TOOLS/vz_clonefile" "$SRC/AuxiliaryStorage" "$DST/AuxiliaryStorage" || exit 6
cp "$SRC/HardwareModel" "$DST/HardwareModel"
cp "$SRC/VirtualMac.plist" "$DST/VirtualMac.plist"
cp "$WORK/MachineIdentifier" "$DST/MachineIdentifier"

# Keep the generated identity as the "original" so the app's identity pane
# reports it as configured rather than regenerated.
mkdir -p "$DST/Identities"
cp "$WORK/MachineIdentifier" "$DST/Identities/original.mid"

# The bundle lives under /var/mobile; the app expects the mobile owner.
chown -R mobile:mobile "$DST" 2>/dev/null || true

ls -l "$DST"
echo "identity clone ready: $DST (serial $SERIAL)"
