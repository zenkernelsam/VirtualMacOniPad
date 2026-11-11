#!/bin/sh
# Compatibility entry for the old root LaunchDaemon. Apple service policy is
# now applied by the user's Guest Tools login item, with a local independent
# ADI provider. Never rewrite global PF rules, MTU or root preferences here.
set -eu
if test "$(id -u)" != 0; then
    exec /bin/launchctl kickstart "gui/$(id -u)/com.mac.virtual.guest-tools"
fi
attempt=0
while test "$attempt" -lt 300; do
    uid=$(/usr/bin/stat -f %u /dev/console 2>/dev/null || true)
    name=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)
    case "$uid" in ''|0|88) ;; *)
        if test -d "/Users/$name" && /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
            exec /bin/launchctl kickstart "gui/$uid/com.mac.virtual.guest-tools"
        fi;;
    esac
    sleep 1
    attempt=$((attempt+1))
done
exit 75
