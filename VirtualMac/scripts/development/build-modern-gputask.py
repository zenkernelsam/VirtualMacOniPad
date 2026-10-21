#!/usr/bin/env python3
"""Port the matching, standalone macOS 27 GPU task into the isolated iPad runtime."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys


def run(*args):
    return subprocess.run(args, check=True)


def main(source, output):
    repo = Path(__file__).resolve().parents[2]
    source, output = Path(source).resolve(), Path(output).resolve()
    service_info = source.parent.parent / 'Info.plist'
    service_metadata = plistlib.loads(service_info.read_bytes())
    if service_metadata.get('CFBundleIdentifier') != 'com.apple.gpusw.ParavirtualizedGraphicsGPUTask':
        raise ValueError('Expected the matching GPU task XPC bundle metadata')
    if source.is_relative_to(output):
        raise ValueError('Build output must be separate from the original GPU task bundle')
    output.mkdir(parents=True, exist_ok=True)
    # A sibling Info.plist makes codesign treat this flat executable as a
    # bundle and bind the source Mac metadata. Keep the executable's signature
    # independent of metadata, which the isolated iPad packager converts later.
    metadata_output = output / 'Info.plist'
    if metadata_output.exists():
        metadata_output.replace(output / '.Info.plist.before-task-signing')
    raw = output / 'GPUTask.mac'
    binary = output / 'com.apple.gpusw.ParavirtualizedGraphicsGPUTask'
    run('lipo', str(source), '-thin', 'arm64e', '-output', str(raw))
    shutil.copyfile(raw, binary)
    root = '/var/root/VirtualMac2/payload/Frameworks/'
    for name, version in [('Foundation', 'C'), ('CoreFoundation', 'A'), ('IOSurface', 'A')]:
        run('install_name_tool', '-change',
            f'/System/Library/Frameworks/{name}.framework/Versions/{version}/{name}',
            f'/System/Library/Frameworks/{name}.framework/{name}', str(binary))
    run('install_name_tool', '-change', '/System/Library/Frameworks/Metal.framework/Versions/A/Metal',
        root + 'ModernGPUTaskCompat.dylib', str(binary))
    data = bytearray(binary.read_bytes())
    dependencies, fixups, offset = [], None, 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, offset)
        if command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            name_offset = struct.unpack_from('<I', data, offset + 8)[0]
            name = data[offset + name_offset:offset + size].split(b'\0', 1)[0].decode()
            dependencies.append(name)
        if command == 0x80000034:
            fixups = struct.unpack_from('<II', data, offset + 8)
        offset += size
    if not fixups: raise ValueError('Expected source chained fixups')
    base, length = fixups
    version, _, imports, symbols, count, fmt, symbols_fmt = struct.unpack_from('<7I', data, base)
    if version or symbols_fmt or fmt not in (1, 2, 3):
        raise ValueError('Unexpected import table format')
    task_ordinal = dependencies.index(root + 'ModernGPUTaskCompat.dylib') + 1
    bindings = []
    stride = {1: 4, 2: 8, 3: 16}[fmt]
    for index in range(count):
        at = base + imports + index * stride
        word = struct.unpack_from('<Q' if fmt == 3 else '<I', data, at)[0]
        name_offset = word >> (32 if fmt == 3 else 9)
        start = base + symbols + name_offset
        end = data.find(b'\0', start, base + length)
        if end < start: raise ValueError('Invalid import name')
        name = data[start:end].decode()
        ordinal = None
        if (name.startswith('__ZNSt3__18to_chars') or
            name in ['_malloc_type_malloc', '_malloc_type_realloc',
                     '__ZnwmSt19__type_descriptor_t', '__ZnamSt19__type_descriptor_t',
                     '__ZdlPvSt19__type_descriptor_t', '__ZdaPvSt19__type_descriptor_t',
                     '_OBJC_CLASS_$_MTLResourceAddressRangeArray']):
            # The task shim reexports the existing Metal and runtime shims.
            # Reuse this ordinal: the Apple executable has little header slack.
            ordinal = task_ordinal
        elif name in ['_MTLCopyDeviceForRegistryID', '_isRGBPixelFormat']:
            ordinal = task_ordinal
        if ordinal is not None:
            mask = 0xFFFF if fmt == 3 else 0xFF
            struct.pack_into('<Q' if fmt == 3 else '<I', data, at, (word & ~mask) | ordinal)
            bindings.append({'symbol': name, 'library': dependencies[ordinal - 1]})
    spec = importlib.util.spec_from_file_location('stamp_ios', repo / 'vz/stamp_ios.py')
    stamp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stamp)
    if not stamp.stamp(data, '16.1'): raise ValueError('Missing source platform command')
    binary.write_bytes(data)
    binary.chmod(0o755)
    run('codesign', '--force', '--sign', '-', '--identifier', 'com.mac.virtual.v2.gputask',
        '--entitlements', str(repo / 'vz/patches/vmm.ents.xml'), str(binary))
    run('codesign', '--verify', '--strict', str(binary))
    run('dyld_info', '-validate_only', str(binary))
    shutil.copyfile(service_info, metadata_output)
    (output / 'port-manifest.json').write_text(json.dumps({
        'source': str(source), 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'source_info': str(service_info),
        'source_info_sha256': hashlib.sha256(service_info.read_bytes()).hexdigest(),
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'runtime': '/var/root/VirtualMac2', 'bindings': bindings,
        'scope': 'matching macOS 27 per-process GPU task, iPad transport and runtime backports'
    }, indent=2) + '\n')


if __name__ == '__main__':
    main(*sys.argv[1:])
