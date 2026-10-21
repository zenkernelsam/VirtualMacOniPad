# Private Swift Context2/State2 entry compatibility

`modern_swift_lookup_compat.cpp` implements the two missing modern external
Swift entry contracts: `swift_getTypeByMangledNameInContext2` and
`swift_getTypeByMangledNameInContextInMetadataState2`. The associated provider
is `modern_swift_lookup_provider.cpp`. This is an application-private adapter:
the genuine, precisely identified old iPad stock Core still performs mangled
name decoding, substitutions, metadata cache/state handling and normal lookup
failures. A complete Swift27 parser has not been migrated or proven equivalent.

The exported ABI is SwiftCC with four/five register parameters and one nullable
metadata pointer return. Incoming context is opaque `void*` carrying DA,
no address diversity, discriminator `0xb5e3`. A nonzero pointer is authenticated,
stripped and compared; an invalid signature traps with BRK `0xc472`. Keeping the
external type opaque avoids an implicit C++ DB conversion before DA auth.
The old opaque entry receives the authenticated raw context. A genuinely signed
null is supported. State forwards the entire incoming `size_t` unchanged;
the actual old entry performs its original blocking bit8 handling. This API
returns one metadata pointer, not a `MetadataResponse` pair.

The provider uses a held `RTLD_NOLOAD` handle for
`/usr/lib/swift/libswiftCore.dylib` and exact per-handle lookups. It checks the
same loaded header/index/signed slide, UUID
`f896d145e02539d6afd3bc0a2ad4f839`, arm64e ABI0, iOS minimum15.4/SDK16.1,
original build tool record, complete header shape and RX TEXT range. Both old
entry addresses/RVAs and their128-byte original machine codes are checked
before and after real typed calls. Shared-cache file offsets are retained only
as provenance. Provider binding/PAC failures trap; a genuine old lookup may
still return null. There is no global lookup fallback, runtime constructor,
compatibility registry, interposition or automatic production installation.

The exact original entry pins, app-written proven source copies, official
Swift license and fixed upstream evidence are retained in
`vendor/swift-lookup-entry-compat/`. The official source commit is
`5ea0a2a5d8e126628da27747739e8d017c1d4882`; this wrapper is an app-written
adaptation based on its ABI declarations and exact old/new Apple machine-code
evidence. It does not claim to be a copy of the modern parser implementation.

On2026-10-04, the isolated iPad probe at
`DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-swift-lookup-wrapper-native-v1/`
passed with actual PID72397 and direct parent wait0. Six true public metatypes
(Int, String, UInt32, Array<UInt8>, Optional<Int>, Dictionary<String,UInt32>)
used their stock `_mangledTypeName` and genuine T.self metadata. The driver
compared raw null, DA-signed null, and a genuine nongeneric Int context
with null generic arguments. Four legal states (0,1,3f,ff) were tested with
and without the original bit8 controls. All162 comparisons returned the
same genuine metadata, with192-byte inputs/canaries and the original32-byte
Int descriptor unchanged. Full90/91/91 loaded names, ten complete stock
snapshots, exact original/private entry identities, two signed file pins and
native child cleanup passed.

There were324 explicit driver calls (18+18 Context and144+144 State).
The private entries each delegate once to a genuine old function, adding162
source/control-flow-proven calls. That second number is derived from the
frozen compiled implementation, not a separately instrumented global count.
Compiler-generated metadata lookups while preparing the public types are
uncounted. These fully usable public metatypes and nongeneric Int context
prove this finite entry compatibility path. They do not prove generic context
traversal, symbolic references, incomplete metadata initialization/waiting,
all modern parser extensions, full CVW ownership, whole Swift Core replacement,
modern VMM/CPU execution, VZ closure, or complete guest functionality.

Build manually using:

```sh
python3 -B VirtualMac/scripts/development/build-modern-swift-lookup.py \
  --output <new-local-output-directory>
```

The builder refuses an existing output directory, retains natural arm64e
subtype `0x80000002`, stamps the tested16.1 minimum/SDK, exposes only the two
symbols, signs without process entitlements, and saves exact inputs/imports/
exports/IR/assembly/signature evidence. Install name is
`@rpath/VM27SwiftLookupCompat.dylib`. It performs no trustcache update, device
execution, global registration or production linkage.

The first project build is at
`DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-swift-lookup-project-build-v1/`.
It passed77 local build checks. All six file-backed sections match the actually
executed frozen library, including the complete2484-byte code section
SHA256`7071dcede51d205e86a197d2d0cd88290b89ec1a8e8a7363e8de75f7006ebf39`.
The project library has a new install name, UUID and signature, and has not been
deployed or executed. Source equivalence and local signing/import closure do
not imply that the surrounding modern runtime stack is complete.


A later isolated native test on2026-10-04 extends the specific PID72397
nongeneric evidence above. The unchanged original wrapper library passed real
generic field lookups at PID72620 with direct parent wait0 in
`DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-swift-own-generic-field-native-v1/`.
The compiler created genuine `OwnGeneric<Int>`, `OwnGeneric<String>` and
`OwnGeneric<UInt32>` instances, their readonly nominal/reflection descriptors,
and four field typerefs for T, Optional<T>, Array<T> and OwnLeaf<T>. Each original
relative typeref address was passed to both actual typed entries; the OwnLeaf
symbolic relative reference resolved its genuine compiler-owned descriptor.
No metadata or mangled input was fabricated or relocated for a call.

All108 comparisons returned the expected true public metadata across nine
Context/State variants per field. There were216 explicit driver calls
(12+12 Context and96+96 State), plus108 old delegates derived from the unchanged
wrapper source. Compiler-generated metadata factory/lookups remain uncounted.
The real description's DA/address-diverse `0xae86` authentication, the modern
context's DA/no-diversity `0xb5e3` contract, six complete readonly section
snapshots, original48-byte selected generic metadata, genuine generic parameter
and complete72-byte argument canaries remained exact before/between/after calls.
Complete90/91/91 loaded-image epochs, ten stock identities, entry/file pins,
handle cleanup and native child absence passed. Original stdout SHA256 is
`dde5e64d9761311e9306bc93a0bdd6eb05328048968df49086160963ee6c2444`.
Independent raw-log review is retained at
`DeviceDiagnostics/2026-10-02-virtualmac-2.0/Tahoe3/modern-swift-own-generic-field-native-actual-independent-review-v1/`.

This proves a finite genuine one-parameter generic and direct symbolic-reference
path. It does not prove arbitrary generic constraints/operators, incomplete
metadata transitions/nonblocking waiting, full modern parser equivalence or
CVW ownership, whole Swift27/VMM/VZ closure, or complete guest functionality.
The first project build and its frozen evidence above were not changed or
redeployed; this later test used the original previously tested private library.
