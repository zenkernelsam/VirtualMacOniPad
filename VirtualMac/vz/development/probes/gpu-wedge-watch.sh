#!/bin/bash
# gpu-wedge-watch.sh — passive wedge capture (DIAGNOSTIC, read-only on iPad)
# Polls guest DiagnosticReports for new Kernel_*.gpuRestart; on a fresh wedge:
#   1) copies the report locally
#   2) SSH `sample` on the host VMM process (shows where PGFifoThread is parked:
#      faultAtOffset condvar = faulted command; decodeSegments/Metal = content hang)
#   3) pulls /tmp/vmm.stderr.log tail
# Usage: ./gpu-wedge-watch.sh [interval_seconds]   (Ctrl-C to stop)
set -u
SSH="sshpass -p cisco ssh -o ConnectTimeout=6 -o ServerAliveInterval=10 -p 2222 root@192.168.64.1"
REMOTE_PREFIX='export PATH=/var/jb/usr/bin:/usr/bin:/bin;'
OUTDIR="$(cd "$(dirname "$0")" && pwd)/../../../.diag/wedge-watch"
mkdir -p "$OUTDIR"
INTERVAL="${1:-3}"
SEEN_FILE="$OUTDIR/.seen"
touch "$SEEN_FILE"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
log "watching for gpuRestart reports every ${INTERVAL}s; evidence -> $OUTDIR"
while true; do
  NEW=$(ls -t /Library/Logs/DiagnosticReports/Kernel_*.gpuRestart 2>/dev/null | head -1)
  if [ -n "$NEW" ] && ! grep -qxF "$NEW" "$SEEN_FILE"; then
    BN=$(basename "$NEW"); TS=$(date +%Y%m%d-%H%M%S)
    log "WEDGE DETECTED: $BN"
    echo "$NEW" >> "$SEEN_FILE"
    cp "$NEW" "$OUTDIR/$TS-$BN" 2>/dev/null
    # grab the matching tailspin (kdebug trace incl. GPUSubmission events)
    TSNAME=$(grep -oE 'gpuRestart[^ ]*\.tailspin' "$NEW" 2>/dev/null | head -1)
    [ -n "$TSNAME" ] && [ -f "/Library/Logs/DiagnosticReports/$TSNAME" ] && cp "/Library/Logs/DiagnosticReports/$TSNAME" "$OUTDIR/$TS-$TSNAME" 2>/dev/null
    # guest kernel log: the "Received fault interrupt" line + IOGPU context
    log show --last 5m --predicate 'eventMessage CONTAINS[c] "fault interrupt" OR eventMessage CONTAINS[c] "paravirt"' 2>/dev/null | tail -100 > "$OUTDIR/$TS-guest-faultlog.txt" &
    # host VMM: stackshot (binary kcdata, decode later) + stderr tail
    VPID=$($SSH "$REMOTE_PREFIX ps ax -o pid,comm | grep -i 'Virtualization.VirtualMachine' | grep -v grep | awk '{print \$1}'" 2>/dev/null | head -1)
    if [ -n "$VPID" ]; then
      log "capturing host VMM pid=$VPID (stackshot + stderr tail)"
      $SSH "$REMOTE_PREFIX stackshot -p $VPID 2>/dev/null" > "$OUTDIR/$TS-vmm-stackshot.bin" 2>/dev/null
      $SSH "$REMOTE_PREFIX tail -200 /tmp/vmm.stderr.log" > "$OUTDIR/$TS-vmm-stderr.txt" 2>/dev/null
      log "evidence saved: $OUTDIR/$TS-*"
    else
      log "WARNING: VMM pid not found via ssh"
    fi
    wait
  fi
  sleep "$INTERVAL"
done
