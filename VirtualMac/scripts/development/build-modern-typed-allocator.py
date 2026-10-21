#!/usr/bin/env python3
"""Build scoped typed allocator backports; never install, trust, or execute them."""
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
    parser.add_argument('--all-five', action='store_true',
                        help='Also export the three SDK backdeployment malloc/calloc/realloc wrappers')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    source = project / 'vz/host/modern_typed_allocator_compat.c'
    header_file = project / 'vz/host/modern_typed_allocator.h'
    license_file = project / 'vendor/libmalloc-typed-backport/LICENSE.txt'
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
    library_name = 'VM27AllocatorProvider.dylib' if args.all_five else 'VM27TypedAllocatorCompat.dylib'
    library = output / library_name
    mode_options = [] if args.all_five else ['-DVZ_TYPED_ALLOCATOR_INCREMENTAL_ONLY=1']
    run('compile', ['xcrun', 'clang', '-target', 'arm64e-apple-ios16.1',
                   '-isysroot', sdk, '-O2', '-std=c11',
                   '-fvisibility=hidden', '-fno-typed-memory-operations-experimental',
                   *mode_options,
                   '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                   '-Wl,-platform_version,ios,16.1,16.1',
                   '-Wl,-install_name,@rpath/' + library_name,
                   str(source), '-o', str(library)])
    run('sign', ['codesign', '--force', '--sign', '-', '--timestamp=none',
                 '--identifier', 'com.virtualmac.typed-allocator-compat', str(library)])
    run('strict', ['codesign', '--verify', '--strict', str(library)])
    run('dyld', ['xcrun', 'dyld_info', '-validate_only', '-exports',
                 '-imports', '-linked_dylibs', str(library)])
    run('assembly', ['xcrun', 'otool', '-tvV', str(library)])
    undefined = run('undefined', ['xcrun', 'nm', '-u', str(library)]).stdout.decode().splitlines()
    expected_imports = {'_bzero', '_malloc_default_zone', '_malloc_zone_malloc', '_malloc_zone_calloc',
                        '_malloc_zone_memalign', '_malloc_zone_free', '_posix_memalign'}
    if args.all_five:
        expected_imports |= {'_malloc', '_calloc', '_realloc'}
    if {line.split()[-1] for line in undefined} != expected_imports:
        raise ValueError('Unexpected allocator imports; only audited old public APIs permitted')
    exports = run('defined', ['xcrun', 'nm', '-gU', str(library)]).stdout.decode().splitlines()
    expected_exports = {'_malloc_type_posix_memalign', '_malloc_type_zone_malloc_with_options'}
    if args.all_five:
        expected_exports |= {'_malloc_type_malloc', '_malloc_type_calloc', '_malloc_type_realloc'}
    if {line.split()[-1] for line in exports} != expected_exports:
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
        'header': {'path': str(header_file), 'sha256': digest(header_file)},
        'license': {'path': str(license_file), 'sha256': digest(license_file)},
        'upstreamCommit': 'c49dafa25f1efe8607701ae6014a663ad2ee437f',
        'upstream': 'Apple libmalloc 812.100.31 non-MTE old-zone fallback and installed SDK typed allocator backdeployment',
        'library': {'path': str(library), 'bytes': len(data), 'sha256': digest(library),
                    'cdhash': cdhash, 'uuid': uuids[0]},
        'exports': sorted(name[1:] for name in expected_exports),
        'allFiveSDKFallbacks': args.all_five,
        'undefinedImports': sorted(expected_imports),
        'minimumIOS': '16.1', 'sdkStamp': '16.1', 'arm64eABI': 0,
        'cpuSubtypeWithCapabilities': '0x80000002',
        'scope': ('Five typed allocator exports with genuine old allocation/reallocation, alignment, clear and ownership'
                  if args.all_five else 'Only two typed allocator exports with genuine old-zone allocation, alignment, clear and ownership'),
        'stockAllocatorReplaced': False, 'typedAllocationTelemetryOrMTEImplemented': False,
        'fullSwiftClosurePassed': False, 'fullVZ27Passed': False,
        'thisLibraryInstalledOrTrustedOrExecuted': False, 'commands': commands,
    }
    (output / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'library': result['library'], 'deviceDeployment': False}, indent=2))


if __name__ == '__main__':
    main()
