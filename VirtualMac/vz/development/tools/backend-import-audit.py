#!/usr/bin/env python3
"""Audit thin reconstructed frameworks against a read-only system export snapshot.

This reports lookup and dylib-version gaps. Export presence alone does not prove
Objective-C layout, method, GPU, or old-VMM compatibility. Missing weak imports
are still reported: a loader can succeed with a NULL pointer that crashes later.
"""
import argparse
import json
from pathlib import Path
import struct


def read_contract(path):
    data = Path(path).read_bytes()
    if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a thin, little-endian Mach-O")
    dependencies, fixups = {}, None
    offset = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = data[offset + name_offset:offset + size].split(b"\0", 1)[0].decode()
            dependencies[name] = struct.unpack_from("<I", data, offset + 20)[0]
        elif command == 0x80000034:
            fixups = struct.unpack_from("<II", data, offset + 8)
        offset += size
    if fixups is None:
        raise ValueError("No chained-fixups import table")
    fixup_offset, fixup_size = fixups
    blob = data[fixup_offset:fixup_offset + fixup_size]
    version, _, imports_offset, symbols_offset, count, format_, symbol_format = struct.unpack_from("<7I", blob)
    if version or symbol_format or format_ not in (1, 2, 3):
        raise ValueError("Unsupported chained import table")
    stride = {1: 4, 2: 8, 3: 16}[format_]
    if imports_offset + count * stride > len(blob):
        raise ValueError("Truncated chained import table")
    imports = set()
    for i in range(count):
        offset = imports_offset + i * stride
        if format_ == 3:
            word = struct.unpack_from("<Q", blob, offset)[0]
            name_offset = word >> 32
        else:
            word = struct.unpack_from("<I", blob, offset)[0]
            name_offset = word >> 9
        start = symbols_offset + name_offset
        end = blob.find(b"\0", start)
        if start >= len(blob) or end < start:
            raise ValueError("Invalid chained import symbol name")
        imports.add(blob[start:end].decode())
    return imports, dependencies


def version_string(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exports", required=True, type=Path)
    parser.add_argument("--versions", required=True, type=Path)
    parser.add_argument("--extra-exports", action="append", default=[], type=Path)
    parser.add_argument("images", nargs="+", type=Path)
    args = parser.parse_args()
    snapshot = json.loads(args.exports.read_text())
    versions = json.loads(args.versions.read_text())
    available = {symbol for symbols in snapshot.values() for symbol in symbols}
    for path in args.extra_exports:
        available.update(path.read_text().splitlines())
    report = {"scope": "Selected system dependency export tables; static checks only",
              "exportedImages": len(snapshot), "exportedSymbols": len(available), "candidates": {}}
    for path in args.images:
        imports, dependencies = read_contract(path)
        mismatches = []
        for dependency, required in dependencies.items():
            if dependency in versions and versions[dependency]["current"] < required:
                mismatches.append({"library": dependency, "required": version_string(required),
                                   "available": version_string(versions[dependency]["current"])})
        report["candidates"][str(path)] = {
            "importCount": len(imports), "importsNotFound": sorted(imports - available),
            "versionMismatches": mismatches,
            "dependencyPathsOutsideSnapshot": sorted(set(dependencies) - versions.keys())}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
