#!/bin/bash
# Restore Qoder CN / Qoder CN IDE state from a backup made by ./backup.sh
# NON-DESTRUCTIVE: the current state is moved aside (not deleted) first, so you
# can always inspect or move it back.
#
#   ./rollback.sh <backup-dir>
set -euo pipefail

SRC="${1:?usage: rollback.sh <backup-dir>}"
APP_USER="$HOME/Library/Application Support/QoderCN/User"
GS="$APP_USER/globalStorage"
QODER="$HOME/.qoder-cn"
STAMP="$(date +%Y%m%d-%H%M%S)"

[ -f "$SRC/sqlite/state.vscdb" ] || { echo "FATAL: $SRC/sqlite/state.vscdb missing" >&2; exit 1; }
[ -d "$SRC/qoder-cn" ]          || { echo "FATAL: $SRC/qoder-cn missing" >&2; exit 1; }

if pgrep -fl "Qoder CN" >/dev/null 2>&1; then
  echo "FATAL: quit 'Qoder CN' first:" >&2; pgrep -fl "Qoder CN" >&2; exit 1
fi

DEST_ASIDE="$HOME/Desktop/QoderCN-RolledBack-$STAMP"
mkdir -p "$DEST_ASIDE"
# 1) move current state aside (non-destructive)
for f in state.vscdb state.vscdb-wal state.vscdb-shm; do
  [ -f "$GS/$f" ] && mv "$GS/$f" "$DEST_ASIDE/" && echo "moved aside $f"
done

# 2) move aside only the fabricated task dirs created by the migration (listed
#    in fabricated-tasks.txt written by the migrator), if present
FAB="$HOME/Desktop/VirtualMacOniPad/tools/qoder-quest-migration/fabricated-tasks.txt"
if [ -f "$FAB" ]; then
  while read -r p; do
    [ -n "$p" ] && [ -e "$p" ] && mv "$p" "$DEST_ASIDE/" && echo "moved aside fabricated: $p"
  done < "$FAB"
fi

# 3) restore db + qoder-cn dirs from backup
cp -p "$SRC/sqlite/state.vscdb" "$GS/state.vscdb"
for f in state.vscdb-wal state.vscdb-shm; do
  [ -f "$SRC/sqlite/$f" ] && cp -p "$SRC/sqlite/$f" "$GS/$f"
done
echo "restored state.vscdb"

for d in cache projects tasks; do
  if [ -d "$SRC/qoder-cn/$d" ]; then
    # move the (possibly modified) current dir aside, then restore
    [ -e "$QODER/$d" ] && mv "$QODER/$d" "$DEST_ASIDE/qoder-cn-$d"
    mkdir -p "$QODER"
    ditto "$SRC/qoder-cn/$d" "$QODER/$d"
    echo "restored ~/.qoder-cn/$d"
  fi
done

echo
echo "ROLLBACK COMPLETE from: $SRC"
echo "  previous state moved to: $DEST_ASIDE  (inspect, then delete when satisfied)"
