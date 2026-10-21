# Swift27 compact enum tag compatibility

`modern_swift_enum_tag_compat.cpp` implements the default body of
`swift_cvw_enumFn_getEnumTag`, from the Swift source commit
`5ea0a2a5d8e126628da27747739e8d017c1d4882`. The upstream sources and complete
Apache license with Runtime Library Exception are preserved in
`vendor/swift-bytecode-enum-tag/`.

The pinned macOS27 Swift image has UUID
`c9b36da7bb3435afbc5d91ecbcaa9ed0`; its exported getter is at RVA `0x51f08`.
The implementation reads the compact layout pointer at `metadata - 16`,
authenticates it with DA, slot address diversity and discriminator `0x8b65`,
reads the signed relative callback at `layout + 24`, signs that callback with
IA and discriminator zero, and returns its actual 32-bit tag. It does not write
the value, metadata, or layout. A tagged layout traps as in the pinned default
body. Inputs must be valid, version-matched compact enum metadata and values;
this is a runtime witness, not an API for untrusted byte buffers.

The original Swift entry additionally consults a registered compatibility
override. This standalone function does not implement that registry. It must
remain an explicitly scoped provider and must not be globally interposed into
the old iPad Swift runtime. The remaining compact value-witness functions and
the typed context-descriptor conversion are separate unresolved dependencies.

The local Mac proof in
`DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-cpu-compact-enum-fixture-v2/`
constructs four real `VZLinuxRosettaDirectoryShare.CachingOptions` values using
the original Virtualization framework: both String cases with 3-byte and
200-byte payloads. This function and the system Swift getter both return the
expected tags, with unchanged value bytes and payloads. Actual image UUIDs,
metadata/layout/callback provenance and the native value-witness PAC are
checked before calls. No VM, Rosetta instance or cache setter is invoked.
This is a Mac ABI proof; it does not prove that VZ27 loads or runs on iPad.

Build a private, entitlement-free arm64e ABI0 library using
`scripts/development/build-modern-swift-enum-tag.py --output <new-directory>`.
The builder refuses existing output directories and records source/license
hashes, signature, build version, imports and the single export. It performs no
installation, trustcache update, native execution, or production modification.

On 2026-10-04, the isolated iPad probe in
`DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-swift-enum-tag-native-v4/`
completed 2048 mechanical calls with native PID72062 and parent wait0. It
verified the exact getter body, arm64e data/function authentication, positive
and negative layout offsets, private input bounds, and unchanged canaries.
These are owned byte-buffer fixtures, not genuine Swift enum values on iPad.
The deployed library is the earlier frozen build; the project builder's
16.1-targeted library has the identical 72-byte body but is not yet deployed.
No complete ownership interpreter is present: its Caching/EFI nested layout
programs need at least112/216 bytes, beyond the getter-only fixture copies.
