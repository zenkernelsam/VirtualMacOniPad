#!/usr/bin/env python3
"""Build a private original27 scalar-cache accessor bridge; do not install or execute."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    sources = [project / 'vz/host' / ('modern_cpu_scalar_read_bridge' + suffix)
               for suffix in ('.c', '.h', '.S')]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    commands = []

    def run(label, argv):
        result = subprocess.run(argv, capture_output=True)
        (output / (label + '.stdout')).write_bytes(result.stdout)
        (output / (label + '.stderr')).write_bytes(result.stderr)
        commands.append({'argv': argv, 'exit': result.returncode})
        if result.returncode:
            raise RuntimeError(label + ': ' + result.stderr.decode(errors='replace'))
        return result

    unsigned = output / 'VM27CPUScalarReadBridge.dylib.unsigned'
    library = output / 'VM27CPUScalarReadBridge.dylib'
    run('compile', ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64e',
                   '-miphoneos-version-min=16.1', '-std=c11', '-Wall', '-Wextra',
                   '-Werror', '-dynamiclib', '-Wl,-no_adhoc_codesign',
                   '-install_name', '@rpath/VM27CPUScalarReadBridge.dylib',
                   str(sources[0]), str(sources[2]), '-o', str(unsigned)])
    data = bytearray(unsigned.read_bytes())
    magic, = struct.unpack_from('<I', data)
    count, size = struct.unpack_from('<II', data, 16)
    if magic != 0xFEEDFACF or 32 + size > len(data):
        raise ValueError('unexpected Mach-O')
    at, builds = 32, []
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, at)
        if length < 8 or length % 8 or at + length > 32 + size:
            raise ValueError('invalid load command')
        if command == 0x32:
            if length < 24:
                raise ValueError('invalid build version')
            builds.append(at)
        at += length
    if at != 32 + size or len(builds) != 1:
        raise ValueError('ambiguous build version')
    # Same ABI0/stamp policy as the previously native-proven isolated modules.
    struct.pack_into('<3I', data, builds[0] + 8, 2, 0x100100, 0x100100)
    unsigned.write_bytes(data)
    shutil.copyfile(unsigned, library)
    run('sign', ['codesign', '--force', '--sign', '-', '--timestamp=none',
                 '--identifier', 'com.virtualmac.cpu-scalar-read-bridge', str(library)])
    run('strict', ['codesign', '--verify', '--strict', str(library)])
    run('dyld', ['xcrun', 'dyld_info', '-validate_only', str(library)])
    signature = run('signature', ['codesign', '-dvvv', str(library)])
    cdhash = re.search(rb'CDHash=([0-9a-f]{40})', signature.stderr)[1].decode()
    undefined = run('undefined', ['xcrun', 'nm', '-u', str(library)]).stdout
    if re.search(rb' _(?:_?hv_|h3_|MTL|VT|objc_msgSend)', undefined):
        raise ValueError('unexpected CPU/GPU/factory import')
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    manifest = {
        'source': [{'path': str(p), 'sha256': digest(p)} for p in sources],
        'library': {'path': str(library), 'bytes': library.stat().st_size,
                    'sha256': digest(library), 'cdhash': cdhash},
        'original27HelperRVA': '0x3810', 'original27HelperBytes': 292,
        'input': 'Exclusively owned 0x350-byte cache, not an Apple CPU/context',
        'fields': ['X' + str(i) for i in range(31)] + ['PC', 'FPCR', 'FPSR'],
        'CPSRAlwaysRejected': True,
        'realNativeStaticallyLinkedModuleProof': 'PID71457/288 helper calls/native wait0',
        'thisDynamicLibraryInstalledOrLoaded': False,
        'nativeVMCPUCreated': False, 'kernelRunCalled': False,
        'original27VMMConnected': False, 'whole27ContextImplemented': False,
        'commands': commands,
    }
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'library': manifest['library'], 'deviceDeployment': False}, indent=2))


if __name__ == '__main__':
    main()
