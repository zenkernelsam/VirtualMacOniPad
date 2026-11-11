#!/bin/sh
# Install code using fresh inodes. Existing mappings keep their original code.
# Accounts, keychains and the user's independent ADI state are never touched.
set -eu
payload=${1:?payload directory required}
destination=${2:-/Library/VirtualMac}
parent=$(dirname "$destination")
mkdir -p "$parent"
transaction=$(mktemp -d "$parent/.VirtualMac-install.XXXXXXXX")
mkdir "$transaction/stage" "$transaction/previous" "$transaction/failed" \
    "$transaction/existed"
printf '%s\n' "$destination" > "$transaction/destination"
items='Virtual Mac Guest Tools.app
OpenGLPVGCompat.dylib
AppleAccountSignInCompat.dylib
SEPBridgeCompat.dylib
independent-identity-provider
install-guest-payload.sh
apply-sep-bridge.sh'
printf '%s\n' "$items" > "$transaction/items"
# Validate every code object before changing any live path.
while IFS= read -r item; do
    test -e "$payload/$item"
    cp -R "$payload/$item" "$transaction/stage/$item"
    case "$item" in
        *.sh) chmod 755 "$transaction/stage/$item"; /bin/sh -n "$transaction/stage/$item";;
        *) /usr/bin/codesign --verify --strict "$transaction/stage/$item";;
    esac
done < "$transaction/items"
mkdir -p "$destination"
# Kept with the backup for an explicit, fresh-inode rollback.
cat > "$transaction/rollback.sh" <<'SCRIPT'
#!/bin/sh
set -eu
backup=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
destination=${1:-$(cat "$backup/destination")}
test ! -e "$backup/rollback-complete" || exit 0
while IFS= read -r item; do
    if test -e "$backup/previous/$item"; then
        if test -e "$destination/$item"; then
            mv "$destination/$item" "$backup/failed/$item"
        fi
        mv "$backup/previous/$item" "$destination/$item"
    elif test ! -e "$backup/existed/$item" && \
         test -e "$backup/installed/$item" && test -e "$destination/$item"; then
        mv "$destination/$item" "$backup/failed/$item"
    fi
done < "$backup/items"
: > "$backup/rollback-complete"
SCRIPT
chmod 700 "$transaction/rollback.sh"
mkdir "$transaction/installed"
committed=0
trap 'if test "$committed" = 0; then "$transaction/rollback.sh" "$destination"; fi' 0
trap 'exit 1' 1 2 3 15
failed=0
while IFS= read -r item; do
    if test -e "$destination/$item"; then
        # Keep the original existence marker after restoration. A repeated
        # rollback must not mistake an already-restored old file for new code.
        : > "$transaction/existed/$item"
        mv "$destination/$item" "$transaction/previous/$item" || { failed=1; break; }
    fi
    # Marker covers new files too, should a later operation fail.
    : > "$transaction/installed/$item"
    mv "$transaction/stage/$item" "$destination/$item" || { failed=1; break; }
done < "$transaction/items"
if test "$failed" = 1; then
    exit 1
fi
committed=1
trap - 1 2 3 15
printf 'VIRTUAL_MAC_CODE_INSTALLED rollback=%s/rollback.sh\n' "$transaction"
