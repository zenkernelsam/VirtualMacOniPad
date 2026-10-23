# VZ identity probes — serial-bound MachineIdentifier

Host-side experiments for making a Virtual Mac guest present a chosen
serial number ("三码" sharing) so Apple services see an identity that
matches the iPad's real SEP (anisette/BAA already come from the iPad via
the SEP bridge).

Everything here runs on the iPad against the extracted VZ payload. The
payload is macOS code stamped for iOS; the guest can also dlopen it after
retagging LC_BUILD_VERSION (see below), which is how the API was first
probed offline.

## What the payload exposes

`VZMacMachineIdentifier` (private):

| selector | notes |
|---|---|
| `+_machineIdentifierWithSerialNumber:` | random ECID + the given serial |
| `+_machineIdentifierWithECID:serialNumber:` | explicit ECID + serial |
| `+_machineIdentifierForVirtualMachineClone*` | clone variants |
| `-_ECID` / `-_disableECIDChecks` / `-_serialNumber` | ivars; the getters are unreliable here |
| `-dataRepresentation` / `-initWithDataRepresentation:` | bplist `{ECID, SerialNumber}` |

`VZMacPlatformConfiguration`'s underlying Mac platform struct carries
`optional<AvpSerialNumber>`, so a serial set on the machine identifier
reaches the guest device tree.

## Payload bug and workaround

The serial-bearing constructors store the serial as an `NSString` in the
`_serialNumber` ivar, but `-dataRepresentation` sends `-string` to it and
aborts:

```
-[__NSCFString string]: unrecognized selector sent to instance ...
```

Replace the ivar with a real `_VZMacSerialNumber` built via `initWithString:`
before serializing. `vz_identity_gen` does exactly that and produces a
96-byte blob, e.g. `{ECID: <random>, SerialNumber: "<serial>"}`, which
`-initWithDataRepresentation:` accepts.

## AuxiliaryStorage: copy it, do not create it

Verified on 2026-10-24 with three clones of the same stopped VM:

| disk | AuxiliaryStorage | identity | boot |
|---|---|---|---|
| clonefile | copied from source | original | boots |
| clonefile | **freshly created** | original / random / serial | **black screen** |

A freshly created auxiliary storage (`initCreatingStorageAtURL:hardwareModel:options:error:`)
boots to a black screen on this VZ payload: the guest never connects the
guest agent socket, i.e. it never reaches the OS. The working recipe is

```
Disk.img        = clonefile(source)
AuxiliaryStorage= clonefile(source)      # never create a new one for a clone
MachineIdentifier = {ECID, SerialNumber, DisableECIDChecks:true}
```

`make_identity_clone.sh` implements exactly that. `vz_aux_create` remains
useful for brand-new VMs only.

The earlier comment in `VirtualMacApp.m` ("installed VM identity is bound to
AuxiliaryStorage") is why the app ignores a serial override on a live VM;
a clone carrying both files with a new identity is the supported path.

## Build

```sh
SDK=/Users/ciscohe/theos/sdks/iPhoneOS16.5.sdk
for m in vz_identity_gen vz_identity_load vz_aux_create; do
  xcrun clang -arch arm64e -isysroot "$SDK" -miphoneos-version-min=15.0 \
    -fobjc-arc -framework Foundation -o /tmp/$m $m.m
  codesign --force --sign - /tmp/$m
done
xcrun clang -arch arm64e -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -o /tmp/vz_clonefile vz_clonefile.c && codesign --force --sign - /tmp/vz_clonefile
```

Deploy to `/var/jb/tmp/` together with the compatibility dylibs
(`payload/Compatibility/iPadOS<NN>/{Hypervisor,ParavirtualizedGraphics,Virtualization}`)
in a `compat/` directory.

## Use

```sh
# 1. generate the identity blob
vz_identity_gen /var/jb/tmp/compat "<serial>" /var/jb/tmp/serial.mid
vz_identity_load /var/jb/tmp/compat /var/jb/tmp/serial.mid   # verify

# 2. create the clone (source VM may be running; it is not modified)
make_identity_clone.sh \
  /var/mobile/Media/VirtualMac/<Src>.bundle \
  /var/mobile/Media/VirtualMac/<Src>-IDTest.bundle \
  "<serial>" /var/jb/tmp/compat /var/jb/tmp
```

Stop the source VM in the app, start the clone, then check inside the guest:

```sh
ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'IOPlatformSerialNumber|IOPlatformUUID|"model"'
```

Expected: the serial equals the supplied value. What the derived
IOPlatformUUID becomes, and whether AOS stops answering HTTP 440, is still
unverified — that is the open question this clone exists to answer.

## Offline dlopen in the guest

The same payload can be loaded inside the macOS guest after changing the
platform stamp (iOS 2 → macOS 1) in LC_BUILD_VERSION and re-signing; macPad's
`misc/vtool_and_sign.sh` is the same trick. The `_ECID`/`_serialNumber`
getters crash there, so read the ivars directly (see `vz_identity_load`).
