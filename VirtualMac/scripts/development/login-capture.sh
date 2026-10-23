#!/bin/sh
# Run as root in the guest while the Apple Account sign-in attempt happens.
# Captures: unified log (auth processes), sample stacks of the Settings
# appex + akd during the spinner, bridge events, and process lifecycle.
TS=$(date +%H%M%S)
DIR=/tmp/logincap-$TS
mkdir -p "$DIR"
echo "capture dir: $DIR"

log stream --level debug --style compact --predicate \
 'process == "akd" OR process == "AppleIDSettings" OR process == "appleaccountd" OR process == "System Settings" OR subsystem CONTAINS[c] "authkit" OR eventMessage CONTAINS[c] "anisette"' \
 > "$DIR/auth.log" 2>&1 &
LOGPID=$!

i=0
while [ $i -lt 60 ]; do
    ap=$(pgrep -x AppleIDSettings | head -1)
    ak=$(pgrep -x akd | head -1)
    {
      echo "== t=$i $(date +%H:%M:%S)"
      for p in "${ap:-}"; do [ -n "$p" ] && echo "appex pid=$p"; done
      [ -n "$ak" ] && echo "akd pid=$ak"
      pgrep -xl appleaccountd
    } >> "$DIR/lifecycle.log"
    if [ -n "$ap" ]; then
        sample "$ap" 2 -file "$DIR/sample-appex-$i.txt" >/dev/null 2>&1
    fi
    if [ -n "$ak" ]; then
        sample "$ak" 2 -file "$DIR/sample-akd-$i.txt" >/dev/null 2>&1
    fi
    sleep 2
    i=$((i+2))
done
kill $LOGPID 2>/dev/null
cp /tmp/sepbridge-events.log "$DIR/sepbridge-events.log" 2>/dev/null
echo "done: $DIR"
ls -l "$DIR" | head -20
