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

i=0
uid=""
while [ $i -lt 180 ]; do
    uid=$(stat -f %u /dev/console 2>/dev/null)
    [ -n "$uid" ] && [ "$uid" != "0" ] && break
    sleep 1
    i=$((i + 1))
done
[ -n "$uid" ] && [ "$uid" != "0" ] || exit 1

launchctl asuser "$uid" launchctl setenv DYLD_INSERT_LIBRARIES \
    "/Library/VirtualMac/OpenGLPVGCompat.dylib:/Library/VirtualMac/AppleAccountSignInCompat.dylib:$DYLIB"
launchctl asuser "$uid" launchctl setenv VM_SEP_BRIDGE 1
launchctl asuser "$uid" launchctl setenv VM_SEP_FAKE_NONVM 1
launchctl asuser "$uid" /usr/bin/defaults write com.mac.virtual.guest-tools SEPIdentityBridge -bool true

# Restart akd so it inherits the env; the bridge pins it afterwards.
launchctl kickstart -k "gui/$uid/com.apple.akd" 2>/dev/null || true

echo "sep-bridge applied uid=$uid at $(date)" >> /var/log/sepbridge-autostart.log
