#!/bin/sh
# Re-apply the SEP bridge profile after a guest reboot.
#
# launchd environment does not survive reboots, and akd must start AFTER the
# env is in place. This waits for the console user, sets the domain env,
# enables the guest pref, and restarts akd so it inherits everything.
#
# VM_SEP_FAKE_NONVM=1 is the diagnostic switch that makes DeviceIdentity
# report "not a VM" inside akd, which is what lets AuthKit take the real
# device-BAA path (the VM host-key path does not exist on iPadOS). It is kept
# explicit here on purpose.

set -u
DYLIB=/Library/VirtualMac/SEPBridgeCompat.dylib
[ -f "$DYLIB" ] || exit 0

# At boot /dev/console is briefly owned by system uids (e.g. 88 windowserver);
# only accept a real login user whose home exists and whose GUI domain is up.
i=0
uid=""
while [ $i -lt 300 ]; do
    u=$(stat -f %u /dev/console 2>/dev/null)
    name=$(stat -f %Su /dev/console 2>/dev/null)
    if [ -n "$u" ] && [ "$u" != "0" ] && [ -n "$name" ] && \
       [ -d "/Users/$name" ] && launchctl print "gui/$u" >/dev/null 2>&1; then
        uid=$u
        break
    fi
    sleep 1
    i=$((i + 1))
done
[ -n "$uid" ] || exit 1

# Network workarounds that are otherwise lost on every reboot:
# QUIC (UDP/443) is unreliable over the iPad hotspot; forcing TCP plus a
# 1400 MTU makes iCloud device lists and account pages load.
/sbin/ifconfig en0 mtu 1400 2>/dev/null || true
cat > /tmp/noquic.rules <<'R'
block return out quick proto udp from any to any port 443
pass out quick all keep state
R
/sbin/pfctl -e >/dev/null 2>&1 || true
/sbin/pfctl -f /tmp/noquic.rules >/dev/null 2>&1 || true

launchctl asuser "$uid" launchctl setenv DYLD_INSERT_LIBRARIES \
    "/Library/VirtualMac/OpenGLPVGCompat.dylib:/Library/VirtualMac/AppleAccountSignInCompat.dylib:$DYLIB"
launchctl asuser "$uid" launchctl setenv VM_SEP_BRIDGE 1
launchctl asuser "$uid" launchctl setenv VM_SEP_FAKE_NONVM 1
launchctl asuser "$uid" /usr/bin/defaults write com.mac.virtual.guest-tools SEPIdentityBridge -bool true

# Restart akd so it inherits the env; the bridge pins it afterwards.
launchctl kickstart -k "gui/$uid/com.apple.akd" 2>/dev/null || true

echo "sep-bridge applied uid=$uid at $(date)" >> /var/log/sepbridge-autostart.log
