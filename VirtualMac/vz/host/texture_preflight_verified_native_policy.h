// App-private native27 preflight bridge: compiled proof only, never env/file
// activated. Root actually executed six v2 cases plus five v3 offset48 cases.
// This is NOT a general GPU-family advertisement or a system validation flag.
// These fingerprints bind the reviewed actual result bytes and native probe.
static const VerifiedNativePolicy compiledNativePolicy = {
    .GPUReadbackVerified = true,
    .evidenceManifestSHA256 = "dd4656517406b1383cd7c16875e6dd5a2cda2d12a91c16d13ec35267fc7780de",
    .evidenceResultsSHA256 = "8d25d7a73b0e5d7921648cee3940ed768884650a6b3e96d69da2374d0e0c48ca",
    .nativeProbeSHA256 = "5b3d06ef5a48ef80d9c6e423e1aae1d8f95d806459b6c9e3b47376b0d631a8d9",
    .nativeProbeCDHash = "b8fb2e3f43bf1ecb77a7e09019319cbfe318ccd6",
    .additionalEvidenceManifestSHA256 = "c8a68d686e8edf23860817df309da24db38e26bd1702923e535fe40c35495405",
    .additionalEvidenceResultsSHA256 = "536a2bd82efbc454f6593f213ed29996a85828c96d3a95a6d9caee4a58997ed5",
    .additionalNativeProbeSHA256 = "4c5c6d73bc19a225167482e9a8233117a0e2181d377f242b53375cd6e30729c7",
    .additionalNativeProbeCDHash = "98fff79cf5ea7445921bd9b425f0935fb7a37a41",
    .formats = {1, 10, 30, 70, 80, 90, 115},
    .formatCount = 7,
    .publicAlignment = 64,
    .privateAlignment = 16,
};

// Additional native M2 GPU offset48 proof, preserved and verified at build.
// Manifest c8a68d686e8edf23860817df309da24db38e26bd1702923e535fe40c35495405
// Result 536a2bd82efbc454f6593f213ed29996a85828c96d3a95a6d9caee4a58997ed5
// Probe 4c5c6d73bc19a225167482e9a8233117a0e2181d377f242b53375cd6e30729c7 CDHash 98fff79cf5ea7445921bd9b425f0935fb7a37a41
