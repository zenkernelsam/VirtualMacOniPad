#!/usr/bin/env python3
"""Build a private two-entry Swift PAC/provider adapter; no install, trust or execution."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='A new directory for this local build and evidence')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    host = project / 'vz/host'
    vendor = project / 'vendor/swift-lookup-entry-compat'
    sources = [host / 'modern_swift_lookup_compat.cpp',
               host / 'modern_swift_lookup_provider.cpp']
    header = host / 'modern_swift_lookup_compat.h'
    inputs = sources + [header, vendor / 'old_entry_pins.h',
                        vendor / 'exports.list', vendor / 'LICENSE.txt',
                        vendor / 'provenance.json', vendor / 'official-source-provenance.json',
                        vendor / 'original-entry-contract.json']
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    commands, checks = [], []
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()

    def check(label, condition):
        checks.append({'name': label, 'passed': bool(condition)})
        if not condition:
            raise ValueError(label)

    def run(label, argv):
        result = subprocess.run([str(arg) for arg in argv], capture_output=True)
        (output / (label + '.stdout')).write_bytes(result.stdout)
        (output / (label + '.stderr')).write_bytes(result.stderr)
        commands.append({'label': label, 'argv': [str(arg) for arg in argv],
                         'exit': result.returncode})
        (output / 'compile-commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        check(label, result.returncode == 0)
        return result

    def load_commands(data):
        check('thin little-endian ARM64e Mach-O',
              struct.unpack_from('<III', data) == (0xFEEDFACF, 0x100000C, 0x80000002))
        count, size = struct.unpack_from('<II', data, 16)
        check('bounded complete load command region', 0 < count <= 512 and
              0 < size <= 65536 and 32 + size <= len(data))
        cursor = 32
        for index in range(count):
            command, length = struct.unpack_from('<II', data, cursor)
            check('bounded command ' + str(index), length >= 8 and length % 8 == 0 and
                  cursor + length <= 32 + size)
            yield command, cursor, length
            cursor += length
        check('entire load command walk', cursor == 32 + size)

    input_records = [{'path': str(path), 'bytes': path.stat().st_size,
                      'sha256': digest(path)} for path in inputs]
    provenance = json.loads((vendor / 'provenance.json').read_bytes())
    check('fixed official license preserved', digest(vendor / 'LICENSE.txt') ==
          provenance['officialLicenseSHA256'])
    check('exact two original old entries preserved', digest(vendor / 'old_entry_pins.h') ==
          provenance['oldPins']['sha256'])
    base = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-arch', 'arm64e',
            '-miphoneos-version-min=16.1', '-std=c++17', '-O2', '-Wall', '-Wextra',
            '-Werror', '-Wno-deprecated-declarations', '-fvisibility=hidden',
            '-fno-exceptions', '-fno-rtti', '-nostdlib++', '-I' + str(vendor)]
    objects = []
    for source in sources:
        label = source.stem
        run(label + '-ir', base + ['-S', '-emit-llvm', source, '-o', output / (label + '.ll')])
        obj = output / (label + '.o')
        run(label + '-object', base + ['-c', source, '-o', obj])
        objects.append(obj)
    unsigned = output / 'VM27SwiftLookupCompat.unsigned.dylib'
    library = output / 'VM27SwiftLookupCompat.dylib'
    run('link', base + ['-dynamiclib', *objects, '-Wl,-no_adhoc_codesign',
        '-Wl,-install_name,@rpath/VM27SwiftLookupCompat.dylib',
        '-Wl,-exported_symbols_list,' + str(vendor / 'exports.list'), '-o', unsigned])
    data = bytearray(unsigned.read_bytes())
    natural_subtype = struct.unpack_from('<I', data, 8)[0]
    natural_flags = struct.unpack_from('<I', data, 24)[0]
    commands_before = list(load_commands(data))
    build = [(cursor, length) for command, cursor, length in commands_before if command == 0x32]
    uuid = [(cursor, length) for command, cursor, length in commands_before if command == 0x1B]
    check('single build version and UUID', len(build) == len(uuid) == 1)
    check('natural ptrauth ABI0 no LC_NOTE', not any(command == 0x31 for command, _, _ in commands_before))
    # Stamp only minimum/SDK to the independently tested 16.1 import closure.
    # Never clear CPU_SUBTYPE_PTRAUTH_ABI or alter code flags/instructions.
    struct.pack_into('<III', data, build[0][0] + 8, 2, 0x100100, 0x100100)
    check('minimum stamp preserves natural subtype and flags',
          struct.unpack_from('<I', data, 8)[0] == natural_subtype == 0x80000002 and
          struct.unpack_from('<I', data, 24)[0] == natural_flags)
    unsigned.write_bytes(data)
    library.write_bytes(data)
    run('sign', ['codesign', '--force', '--sign', '-', '--timestamp=none',
                '--identifier', 'com.virtualmac.swift-lookup-private-compat', library])
    run('strict-signature', ['codesign', '--verify', '--strict', library])
    run('dyld', ['xcrun', 'dyld_info', '-validate_only', library])
    exports = run('exports', ['xcrun', 'dyld_info', '-exports', library]).stdout.decode()
    wanted = ['_swift_getTypeByMangledNameInContext2',
              '_swift_getTypeByMangledNameInContextInMetadataState2']
    names = re.findall(r'\b(_swift_getTypeByMangledName\w+)\b', exports)
    check('only two default compatibility exports', names == wanted)
    imports = run('imports', ['xcrun', 'dyld_info', '-imports', '-linked_dylibs', library]).stdout.decode()
    for bad in ['libswift', 'Hypervisor', 'Virtualization', 'VM27Hypervisor',
                'ModernRuntimeCompat', '_hv_', '_h3_', '_mmap', '_mprotect',
                '_mach_vm_write', '_execve', '_posix_spawn']:
        check('private import closure excludes ' + bad, bad not in imports)
    assembly = run('assembly', ['xcrun', 'otool', '-tvV', library]).stdout.decode()
    check('both real DA auth and IA0 typed calls', assembly.count('autda\t') == 2 and
          assembly.count('blraaz\t') == 2 and 'brk\t#0xc472' in assembly)
    wrapper_ir = (output / 'modern_swift_lookup_compat.ll').read_text()
    check('both four/five argument SwiftCC nullable pointer definitions',
          wrapper_ir.count('define swiftcc ptr @swift_getTypeByMangledName') == 2)
    old_calls = [line for line in wrapper_ir.splitlines() if 'call swiftcc ptr %' in line]
    check('two exact old typed SwiftCC IA0 calls', len(old_calls) == 2 and
          all('"ptrauth"(i32 0, i64 0)' in line for line in old_calls))
    check('no automatic initializer/global interpose',
          b'__mod_init_func' not in data and b'__interpose' not in data)
    signature = run('signature', ['codesign', '-dvvv', library]).stderr
    cdhash = re.search(rb'CDHash=([0-9a-f]{40})', signature)[1].decode()
    entitlements = run('entitlements', ['codesign', '-d', '--entitlements', ':-', library])
    check('no process rights on private library',
          b'<key>' not in entitlements.stdout + entitlements.stderr)
    signed = library.read_bytes()
    commands_signed = list(load_commands(signed))
    uuid_value = next(signed[cursor + 8:cursor + 24].hex()
                      for command, cursor, _ in commands_signed if command == 0x1B)
    versions = [struct.unpack_from('<III', signed, cursor + 8)
                for command, cursor, _ in commands_signed if command == 0x32]
    check('exact final iOS16.1 minSDK/PAC subtype', versions == [(2, 0x100100, 0x100100)] and
          struct.unpack_from('<I', signed, 8)[0] == natural_subtype)
    check('inputs unchanged during local build', all(digest(Path(row['path'])) == row['sha256']
          for row in input_records))
    result = {
        'checks': len(checks), 'failures': 0, 'details': checks,
        'inputs': input_records, 'commands': commands,
        'library': {'path': str(library), 'bytes': len(signed), 'sha256': digest(library),
                    'cdhash': cdhash, 'uuid': uuid_value},
        'exports': wanted, 'cpuSubtypeWithCapabilities': '0x80000002', 'arm64eABI': 0,
        'minimumIOS': '16.1', 'sdkStamp': '16.1', 'signedEntitlements': {},
        'implementation': 'Two modern external entry/PAC contracts using a verified held old stock provider',
        'frozenEquivalentAdapterNativePID': provenance['actualProof']['nativePID'],
        'thisBuildInstalledTrustedOrExecuted': False,
        'productionGlobalRegistrationChanged': False,
        'completeContext2EquivalenceProven': False, 'genericParserEquivalenceProven': False,
        'fullSwiftVZ27ClosureProven': False,
    }
    (output / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in
          ['library', 'checks', 'failures', 'thisBuildInstalledTrustedOrExecuted']}, indent=2))


if __name__ == '__main__':
    main()
