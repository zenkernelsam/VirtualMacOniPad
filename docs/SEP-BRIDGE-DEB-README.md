# SEP Identity Bridge — com.vm.sepbridge 0.9.1 (test build)

Status: iPad-side bridge VERIFIED end-to-end including akd-respawn
self-healing. Real AKAnisetteData returned through the packaged install
(machineID + per-call OTP + routingInfo); the watchdog re-injects into
fresh akd instances automatically (verified across killall akd).
Guest-side akd swizzle and the final sign-in UI test remain to be
exercised by user.

## What the deb installs (iPad, Dopamine rootless)

- /var/jb/sepbridge/sepbridge-helper  — TCP relay + akd watchdog
    :18443 guest-facing request port
    :18444 reverse-link port (sepinject inside akd dials out)
    :18445 HTTP file server (serves guest dylib + docs)
- /var/jb/sepbridge/sepinject.dylib   — injected into akd; calls
    AKClient(initWithAuditToken: akd's own token) +
    AKNativeAnisetteService/AKAnisetteProvisioningService natively
- /var/jb/sepbridge/SEPBridgeCompat.dylib — guest-side universal
    (x86_64/arm64/arm64e) swizzle dylib, fetched via :18445
- /var/jb/Library/LaunchDaemons/com.vm.sepbridge.plist — system domain,
    KeepAlive; watchdog re-injects sepinject after every akd respawn
    (akd is Adaptive + jetsam-prone; reinjection is automatic)

postinst admits both binaries via /var/jb/trustadd (jbclient trust_file_by_path).
Helper is ldid-signed with identifier com.apple.dt.xcodebuild + AuthKit
client entitlements (only needed for legacy paths; the live path is
in-process and does not cross XPC).

## Install / reinstall on iPad

    dpkg -i com.vm.sepbridge_0.9.1_iphoneos-arm64.deb

Verify:

    tail -20 /var/jb/sepbridge/helper.log   # want: listening + link-listen + akd-linked

## Guest (macOS VM) enable — once, in guest Terminal

    curl -o /tmp/SEPBridgeCompat.dylib http://192.168.64.1:18445/SEPBridgeCompat.dylib
    sudo mkdir -p /Library/VirtualMac
    sudo cp /tmp/SEPBridgeCompat.dylib /Library/VirtualMac/
    sudo chmod 755 /Library/VirtualMac/SEPBridgeCompat.dylib
    sudo launchctl setenv VM_SEP_BRIDGE 1
    sudo launchctl setenv DYLD_INSERT_LIBRARIES "/Library/VirtualMac/OpenGLPVGCompat.dylib:/Library/VirtualMac/AppleAccountSignInCompat.dylib:/Library/VirtualMac/SEPBridgeCompat.dylib"
    sudo killall akd

(If OpenGLPVGCompat/AppleAccountSignInCompat are not installed, omit them
from the list. VM_SEP_HOST/VM_SEP_PORT default to 192.168.64.1:18443.)

## Expected witnesses

- Guest: /tmp/sepbridge-events.log gets VMSEP "loaded"/"install-pass"/
  "bridge-call" lines once an anisette request is made.
- iPad: helper.log shows "fwd" lines per request; injected side logs
  VMINJ via os_log.
- Sign-in per docs/GUEST-SIGNIN-TEST-PROTOCOL.md — success = proceeds
  past the earlier "Verification failed, an error occurred" location.

## Honest caveats

- Erase/reset anisette ops are NOT forwarded (host identity protection).
- helper runs as root in system domain; akd link is a reverse TCP dial
  from inside akd's sandbox (network-outbound allowed).
- If akd is jetsam-killed the link drops for <2s; watchdog re-injects.

## Source integration (next app build)

SEPBridgeCompat is now wired into the payload chain:
- scripts/development/build-sepbridge-compat.sh (universal, ad-hoc signed)
- build-guest-tools.sh copies it into the payload tarball
- VZGuestTools.m finish script installs + verifies it like the account dylib
- VirtualMacGuestToolsApp appends it to DYLD_INSERT_LIBRARIES when the
  SEPIdentityBridge preference is on — identical opt-in policy to
  AccountSignInAdapter.

After an app build containing these changes, the manual curl/cp steps
above are unnecessary — enabling the preference is sufficient.
EOF-less note: local build-guest-tools.sh run needs full Xcode (actool);
CLT-only environments stop after producing the dylibs.
