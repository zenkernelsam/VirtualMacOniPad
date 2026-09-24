#!/bin/bash
# Backup Qoder CN / Qoder CN IDE Quest state before the migration.
# Run with BOTH apps quit. Safe to run repeatedly.
#
#   ./backup.sh [dest-dir]
# Default dest: ~/Desktop/QoderCN-Migration-Backup-<yyyyMMdd-HHmmss>
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-$HOME/Desktop/QoderCN-Migration-Backup-$TS}"
APP_USER="$HOME/Library/Application Support/QoderCN/User"
GS="$APP_USER/globalStorage"
QODER="$HOME/.qoder-cn"

if pgrep -fl "Qoder CN" >/dev/null 2>&1; then
  echo "WARNING: 'Qoder CN' processes still running; quit them for a clean state:" >&2
  pgrep -fl "Qoder CN" >&2
fi

mkdir -p "$DEST/sqlite" "$DEST/qoder-cn"
for f in "$GS/state.vscdb" "$GS/state.vscdb-wal" "$GS/state.vscdb-shm"; do
  [ -f "$f" ] && cp -p "$f" "$DEST/sqlite/" && echo "saved $(basename "$f")"
done
[ -f "$DEST/sqlite/state.vscdb" ] || { echo "FATAL: state.vscdb not found at $GS" >&2; exit 1; }

# ditto keeps metadata/ACLs; excludes nothing (cache can be large but is required to roll back).
for d in cache projects tasks; do
  if [ -e "$QODER/$d" ]; then
    ditto "$QODER/$d" "$DEST/qoder-cn/$d"
    echo "saved ~/.qoder-cn/$d"
  fi
done

( cd "$DEST" && find . -type f -not -name BACKUP-MANIFEST.txt -print0 \
    | xargs -0 shasum -a 256 > BACKUP-MANIFEST.txt )

echo
echo "BACKUP COMPLETE: $DEST"
echo "  rollback with: ./rollback.sh \"$DEST\""
