#!/usr/bin/env python3
"""Build the scoped Swift compact enum getter; never install, trust, or execute it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    source = project / 'vz/host/modern_swift_enum_tag_compat.cpp'
    license_file = project / 'vendor/swift-bytecode-enum-tag/LICENSE.txt'
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

    sdk = run('sdk', ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']).stdout.decode().strip()
    library = output / 'VM27SwiftEnumTagCompat.dylib'
    run('compile', ['xcrun', 'clang++', '-target', 'arm64e-apple-ios16.1',
                   '-isysroot', sdk, '-O2', '-std=c++17', '-fno-exceptions',
                   '-fno-rtti', '-nostdlib++', '-fvisibility=hidden',
                   '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                   '-Wl,-platform_version,ios,16.1,16.1',
                   '-Wl,-install_name,@rpath/VM27SwiftEnumTagCompat.dylib',
                   str(source), '-o', str(library)])
    run('sign', ['codesign', '--force', '--sign', '-', '--timestamp=none',
                 '--identifier', 'com.virtualmac.swift-enum-tag-compat', str(library)])
    run('strict', ['codesign', '--verify', '--strict', str(library)])
    run('dyld', ['xcrun', 'dyld_info', '-validate_only', '-exports',
                 '-imports', '-linked_dylibs', str(library)])
    run('assembly', ['xcrun', 'otool', '-tvV', str(library)])
    undefined = run('undefined', ['xcrun', 'nm', '-u', str(library)]).stdout.strip()
    if undefined:
        raise ValueError('This getter must have no undefined imports')
    exports = run('defined', ['xcrun', 'nm', '-gU', str(library)]).stdout.decode().splitlines()
    if [line.split()[-1] for line in exports] != ['_swift_cvw_enumFn_getEnumTag']:
        raise ValueError('Unexpected exported symbols')
    data = library.read_bytes()
    # 0x80000000 is CPU_SUBTYPE_PTRAUTH_ABI capability, not ABI version 1.
    # This is the same exact ABI0 header as the pinned iOS candidate.
    if struct.unpack_from('<III', data) != (0xFEEDFACF, 0x100000C, 0x80000002):
        raise ValueError('Expected arm64e ABI0 Mach-O')
    ncmds, size = struct.unpack_from('<II', data, 16)
    at, versions, uuids = 32, [], []
    if 32 + size > len(data):
        raise ValueError('Invalid Mach-O command range')
    for _ in range(ncmds):
        command, length = struct.unpack_from('<II', data, at)
        if length < 8 or length % 8 or at + length > 32 + size:
            raise ValueError('Invalid Mach-O command')
        if command == 0x32:
            versions.append(struct.unpack_from('<III', data, at + 8))
        if command == 0x1B:
            uuids.append(data[at + 8:at + 24].hex())
        at += length
    if at != 32 + size or versions != [(2, 0x100100, 0x100100)] or len(uuids) != 1:
        raise ValueError('Unexpected platform/version/UUID')
    signature = run('signature', ['codesign', '-dvvv', str(library)]).stderr
    cdhash = re.search(rb'CDHash=([0-9a-f]{40})', signature)[1].decode()
    rights = run('entitlements', ['codesign', '-d', '--entitlements', ':-', str(library)])
    if b'<key>' in rights.stdout or b'<key>' in rights.stderr:
        raise ValueError('The library must not have process entitlements')
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {
        'source': {'path': str(source), 'sha256': digest(source)},
        'license': {'path': str(license_file), 'sha256': digest(license_file)},
        'upstreamCommit': '5ea0a2a5d8e126628da27747739e8d017c1d4882',
        'originalSwiftUUID': 'c9b36da7bb3435afbc5d91ecbcaa9ed0',
        'originalEntryRVA': '0x51f08',
        'library': {'path': str(library), 'bytes': len(data), 'sha256': digest(library),
                    'cdhash': cdhash, 'uuid': uuids[0]},
        'exports': ['swift_cvw_enumFn_getEnumTag'], 'undefinedImports': [],
        'minimumIOS': '16.1', 'sdkStamp': '16.1', 'arm64eABI': 0,
        'cpuSubtypeWithCapabilities': '0x80000002',
        'scope': 'Only default compact-value-witness enum tag body',
        'registeredSwiftCompatibilityOverrideImplemented': False,
        'fullSwiftClosurePassed': False, 'fullVZ27Passed': False,
        'thisLibraryInstalledOrTrustedOrExecuted': False, 'commands': commands,
    }
    (output / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'library': result['library'], 'deviceDeployment': False}, indent=2))


if __name__ == '__main__':
    main()
