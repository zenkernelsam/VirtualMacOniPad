# Prepare the reviewed PVG27 UI profile

`prepare-modern-pvg-ui-profile.py` creates a **new local output**, using the exact
binary transformation reviewed and tested for VirtualMac2/Tahoe3. Apple framework
source is unavailable. This does not recompile an Apple framework, reconstruct a
complete Apple8 backend, or build CPU/VMM/runtime components.

The existing native physical Metal family query remains byte-for-byte unchanged.
Two reviewed changes are applied to this particular app-owned PVG27 framework:

| Location | Change |
| --- | --- |
| Native `_PGDevice supportsSharedTextures`, file offset `0x26b98` | Return `NO` for shared texture handles; its 12-byte implementation window has eight changed bytes. |
| Native DeviceInfo producer, file offset `0xdd8c` | Capture zero for optional guest `SupportFlags2023` bit 0. The existing guest consumer selects Mac profile `10001` rather than Apple profile `6`. Other producer flags and the physical Metal query remain unchanged. |

The profile naturally changes several guest capabilities. On the measured guest
macOS 26.6.2 build 25G83, this includes a public linear texture alignment of 256
bytes and read/write texture tier 1. Consumers must obey the actual reported
alignment. These are existing guest profile paths, not invented Apple8 support.
Real guest execution and UI acceptance are separate from a successful local build.

## Exact accepted inputs

All inputs must be regular non-symlink files of **665056 bytes**, arm64e, with
Mach-O UUID `9e6a667a-a775-32de-8dd5-6872ef6a53d9`.

| Input | Complete SHA256 |
| --- | --- |
| Original converted PVG27 | `6e1d9945180e8dcf57474b7ecd7bc42a49379e4101bb8db089a4433eae97c92d` |
| Shared handles already disabled | `fee8179463878128371b80a4ea776d2b72f8207dd817c2033eeb112ff8ca005c` |
| Reviewed UI profile already applied | `7c052a43cf26b232b114d787f6b3f9133c0646db953858717645895ab0ef5065` |

The tool also validates the exact original instructions, physical query, Mach-O
header, segment protections, and three native windows guarded by the existing
runtime. Unknown versions fail closed: do not remove these checks to accept a
different framework. A changed native version needs fresh analysis and validation.

The output must reproduce exactly:

- SHA256 `7c052a43cf26b232b114d787f6b3f9133c0646db953858717645895ab0ef5065`
- CDHash `88b6ad7d5a32de3a956ac8f4b82c4d6f5604dfc8`
- Identifier `ParavirtualizedGraphics-555549449e6a667aa77532de8dd56872ef6a53d9`
- Ad hoc signature, flags `0x2`, 16384-byte signing pages, no entitlements.

Only the two reviewed instruction windows and original signature area may change.
Dependencies, exports, UUID, header, protections and all other sections must remain
unchanged. An already-patched input reproduces all bytes identically.

## Local use

Run as an ordinary macOS user with Python 3 and the existing Apple `codesign`,
`xcrun otool` and `xcrun nm` tools. No packages are installed. A signing toolchain
that cannot reproduce the pinned output causes failure.

From the repository root, supply the actual input file and a **new** output
directory whose parent already exists under this repository's `DeviceDiagnostics`
or `/private/tmp` (including `/tmp`, which resolves there):

```sh
python3 VirtualMac/scripts/development/prepare-modern-pvg-ui-profile.py \
  --input DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/native-shared-texture-gate-2026-10-08-v1/original/ParavirtualizedGraphics \
  --output-dir /private/tmp/pvg27-ui-profile-new-build
```

The tool refuses an existing output directory, including a symlink. It never
modifies the input or any existing candidate. It does not execute the framework,
contact a device, request root, alter trustcache, modify iPadOS, or deploy.

The output contains the verified `ParavirtualizedGraphics`, a baseline byte copy,
`build-result.json`, `artifact-manifest.json`, source snapshot, and native signature,
dependency, export and Mach-O evidence. Treat the directory as a completed build
only when the command exits zero, `artifact-manifest.json` and `build-result.json` both report `passed:true`
and the candidate has the exact SHA256 above. A failed attempt may leave a private
directory and diagnostic logs; any unverified signed file remains `candidate.pending`
with mode `0600` and must not be packaged.

## Reviewable packager integration

The existing `package-virtualmac2.py --candidate <directory>` already copies
`<directory>/ios/ParavirtualizedGraphics` into the payload framework without
rebuilding it. No packager code has been changed by this tool.

After final guest/UI acceptance, a narrow integration can use this existing input:

1. Run this tool on the hash-validated PVG binary in the approved candidate.
2. Copy that entire approved candidate into a **new private candidate directory**.
   Refuse any pre-existing destination. Retain its other `ios` binaries unchanged.
3. In that new copy only, replace `ios/ParavirtualizedGraphics` with the verified
   tool output and pass the new copy as `--candidate` to the existing packager.
4. Verify the packaged framework's full SHA256 and CDHash against the pins above,
   and verify all other package inputs against the approved runtime closure.

Do not overlay an existing frozen candidate or shipping package. Do not invoke a
full CPU/VMM/runtime rebuild merely to prepare this single framework. No opt-in
packager flag or automatic deployment is introduced here.

Provenance: the frozen guarded conversion and actual guest consumer evidence are
in `DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/native-guest-mac-profile-2026-10-08-v1/`.
Its actual 25G83 Metal selector/profile/vector/membership proof binds to UUID
`493e76d9-74d4-333b-a3b2-e5f9bc86429d`, TEXT SHA256
`622ca7caf18b462553a0715a0d9ebd9ec405c4a6736fd3bf0892ea7384ea59f5`.
This provenance does not assert that a different guest OS has the same consumer.
