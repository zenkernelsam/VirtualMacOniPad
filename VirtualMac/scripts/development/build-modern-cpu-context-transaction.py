#!/usr/bin/env python3
"""Build the private typed 69-field typed state transaction; never install or invoke Hypervisor."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    source = project / "vz/host/modern_cpu_context_transaction.c"
    header = project / "vz/host/modern_cpu_context_transaction.h"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sdk = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    frameworks = sdk / "System/Library/Frameworks"
    commands = []

    def run(label, argv):
        result = subprocess.run(argv, capture_output=True)
        (output / (label + ".stdout")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        commands.append({"argv": argv, "exit": result.returncode})
        if result.returncode:
            raise RuntimeError(label + ": " + result.stderr.decode(errors="replace"))
        return result

    unsigned = output / "VM27CPUContextTransaction.dylib.unsigned"
    library = output / "VM27CPUContextTransaction.dylib"
    run("compile", [
        "xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64e",
        "-miphoneos-version-min=14.5", "-std=c11", "-Wall", "-Wextra",
        "-Werror", "-dynamiclib", "-Xclang", "-iframework", "-Xclang",
        str(frameworks), "-Wl,-no_adhoc_codesign", "-install_name",
        "@rpath/VM27CPUContextTransaction.dylib", str(source), "-o", str(unsigned),
    ])
    image = bytearray(unsigned.read_bytes())
    magic, = struct.unpack_from("<I", image)
    count, size = struct.unpack_from("<II", image, 16)
    if magic != 0xFEEDFACF or 32 + size > len(image):
        raise ValueError("unexpected Mach-O header")
    at, builds = 32, []
    for _ in range(count):
        command, length = struct.unpack_from("<II", image, at)
        if length < 8 or length % 8 or at + length > 32 + size:
            raise ValueError("invalid load command")
        if command == 0x32:
            if length < 24:
                raise ValueError("invalid build version")
            builds.append(at)
        at += length
    if at != 32 + size or len(builds) != 1:
        raise ValueError("ambiguous build version")
    struct.pack_into("<3I", image, builds[0] + 8, 2, 0xE0500, 0xE0500)
    unsigned.write_bytes(image)
    shutil.copyfile(unsigned, library)
    run("sign", [
        "codesign", "--force", "--sign", "-", "--timestamp=none",
        "--identifier", "com.virtualmac.cpu-context-transaction", str(library),
    ])
    run("strict", ["codesign", "--verify", "--strict", str(library)])
    run("dyld", ["xcrun", "dyld_info", "-validate_only", str(library)])
    signature = run("signature", ["codesign", "-dvvv", str(library)])
    cdhash = re.search(rb"CDHash=([0-9a-f]{40})", signature.stderr)[1].decode()
    undefined = run("undefined", ["xcrun", "nm", "-u", str(library)]).stdout
    if re.search(rb" _(?:_?hv_|h3_|MTL|VTDecompression)", undefined):
        raise ValueError("unexpected direct Hypervisor or GPU import")
    metadata = {
        "source": [{"path": str(p), "sha256": digest(p)} for p in [source, header]],
        "library": {
            "path": str(library), "bytes": library.stat().st_size,
            "sha256": digest(library), "cdhash": cdhash,
        },
        "SDKHeadersOnly": str(frameworks / "Hypervisor.framework/Headers"),
        "fields": [f"Q{i}" for i in range(32)] + ["SCTLR_EL1"] + [f"X{i}" for i in range(31)] + ["PC", "FPCR", "FPSR", "SP_EL0", "SP_EL1"],
        "operation": "private 69-field typed snapshot, persistent commit, verify and explicit exact register-value restoration",
        "nativeProviderABI": 13,
        "realVCPURunMaximum": 0,
        "whole27ContextImplemented": False,
        "requiresOwnedNeverRunCPU": True,
        "nativeKernelAtomicTransaction": False,
        "readOnlyDirtyWords": ["0x670", "0x678", "0x748"],
        "realNativeProbePassed": "modern-hypervisor-context-transaction-v6/PID70456/wait0",
        "original27VMMConsumerConnected": False,
        "installedOrTrustedOnDevice": False,
        "commands": commands,
    }
    (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"library": metadata["library"], "deviceDeployment": False}, indent=2))


if __name__ == "__main__":
    main()
