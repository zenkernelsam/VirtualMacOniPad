#!/usr/bin/env python3
"""Build app-private reexport providers; do not replace system or production libraries."""
from pathlib import Path
import hashlib
import json
import re
import struct
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def commands(data):
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
    at = 32
    end = at + struct.unpack_from('<I', data, 20)[0]
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, at)
        assert size >= 8 and size % 8 == 0 and at + size <= end
        yield cmd, at, size
        at += size
    assert at == end


def main(runtime_directory, output_directory):
    runtime = Path(runtime_directory).resolve()
    manifest = json.loads((runtime / 'build-manifest.json').read_bytes())
    libraries = {row['role']: row for row in manifest['libraries']}
    assert set(libraries) == {'ios', 'macos'}
    out = Path(output_directory).resolve()
    assert not out.exists() and not out.is_symlink()
    out.mkdir(mode=0o700)
    source = out / 'empty-provider.c'
    source.write_text('/* All definitions are real reexports; no function stubs. */\n')
    rows = []

    def run(label, args):
        result = subprocess.run(args, capture_output=True, timeout=30)
        (out / (label + '.stdout')).write_bytes(result.stdout)
        (out / (label + '.stderr')).write_bytes(result.stderr)
        (out / (label + '.command.json')).write_text(json.dumps(args, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(label + ': ' + result.stderr.decode(errors='replace')[-1500:])
        return result

    for role, sdk, target in [('ios', 'iphoneos', 'arm64e-apple-ios16.1'),
                              ('macos', 'macosx', 'arm64e-apple-macos13.0')]:
        original = libraries[role]
        lib = Path(original['path'])
        assert lib.is_file() and not lib.is_symlink() and lib.resolve().parent == runtime
        assert lib.stat().st_size == original['bytes'] and sha(lib) == original['sha256']
        run(role + '-original-strict', ['codesign', '--verify', '--strict', str(lib)])
        sig = run(role + '-original-signature', ['codesign', '-dvvv', str(lib)]).stderr
        assert re.search(rb'CDHash=([0-9a-f]{40})', sig)[1].decode() == original['CDHash']
        for kind, system_path in [('cxx', '/usr/lib/libc++.1.dylib'),
                                  ('allocator', '/usr/lib/system/libsystem_malloc.dylib')]:
            selected = [name for name in original['exports']
                        if (name == '_malloc_type_calloc') == (kind == 'allocator')]
            assert len(selected) == (1 if kind == 'allocator' else 7)
            selected_file = out / (role + '-' + kind + '-reexports.txt')
            selected_file.write_text('\n'.join(selected) + '\n')
            # Only declare the native dependency's identity. SDK27 falsely
            # tells ld that iOS16 already exports these missing functions.
            # Runtime LC_REEXPORT_DYLIB forwards to the genuine system image;
            # this build-only stub provides no functions or data definitions.
            native_stub = out / (role + '-' + kind + '-native-identity.tbd')
            native_stub.write_text('--- !tapi-tbd\ntbd-version: 4\ntargets: [ arm64e-' +
                                   ('ios' if role == 'ios' else 'macos') +
                                   ' ]\ninstall-name: ' + json.dumps(system_path) + '\n...\n')
            name = ('VM27CxxProvider' if kind == 'cxx' else 'VM27AllocatorProvider')
            name += ('.mac' if role == 'macos' else '') + '.dylib'
            path = out / name
            label = role + '-' + kind
            args = ['xcrun', '--sdk', sdk, 'clang', '-target', target,
                    '-fptrauth-abi-version=0', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                    '-Wl,-no_adhoc_codesign', '-Wl,-reexport_library,' + str(native_stub),
                    str(lib), '-Wl,-reexported_symbols_list,' + str(selected_file),
                    '-Wl,-rpath,@loader_path',
                    '-install_name', '@rpath/' + name, str(source), '-o', str(path)]
            if role == 'macos':
                args.insert(8, '-Wl,-no_mac_public_arm64e')
            run(label + '-compile', args)
            data = bytearray(path.read_bytes())
            assert struct.unpack_from('<I', data, 8)[0] == 0x80000002
            builds = [at for cmd, at, size in commands(data) if cmd == 0x32]
            assert len(builds) == 1
            if role == 'ios':
                struct.pack_into('<3I', data, builds[0] + 8, 2, 0x100100, 0x100100)
                path.write_bytes(data)
            reexports = []
            for cmd, at, size in commands(data):
                if cmd == 0x8000001f:
                    offset = struct.unpack_from('<I', data, at + 8)[0]
                    reexports.append(bytes(data[at + offset:at + size]).split(b'\0', 1)[0].decode())
            assert reexports == [system_path]
            run(label + '-sign', ['codesign', '--force', '--sign', '-', '--timestamp=none',
                                  '--identifier', 'local.VirtualMac.cpu-provider.' + label, str(path)])
            run(label + '-strict', ['codesign', '--verify', '--strict', str(path)])
            run(label + '-dyld', ['xcrun', 'dyld_info', '-validate_only', str(path)])
            exports = run(label + '-exports', ['xcrun', 'dyld_info', '-exports', str(path)]).stdout.decode()
            actual_selected = []
            for line in exports.splitlines():
                match = re.match(r'\s*\[re-export\]\s+(\S+)\s+\(from ModernCPURuntimeCompat(?:\.mac)?\)\s*$', line)
                if match:
                    actual_selected.append(match[1])
            assert set(actual_selected) == set(selected) and len(actual_selected) == len(selected), exports
            assert not run(label + '-entitlements', ['codesign', '-d', '--entitlements', ':-', str(path)]).stdout
            cd = re.search(rb'CDHash=([0-9a-f]{40})', run(label + '-signature', ['codesign', '-dvvv', str(path)]).stderr)[1].decode()
            uuid = [path.read_bytes()[at + 8:at + 24].hex() for cmd, at, size in commands(path.read_bytes()) if cmd == 0x1b]
            assert len(uuid) == 1 and sha(lib) == original['sha256']
            rows.append({'role': role, 'kind': kind, 'name': name, 'path': str(path),
                         'bytes': path.stat().st_size, 'sha256': sha(path), 'CDHash': cd,
                         'UUID': uuid[0], 'reexports': reexports, 'emptyEntitlements': True,
                         'selectedCPUSymbolReexports': actual_selected,
                         'runtimeSHA256': original['sha256']})
    result = {'scope': 'private two-level C++/allocator lookup candidates with genuine reexports',
              'providers': rows, 'runtimeManifestSHA256': sha(runtime / 'build-manifest.json'),
              'builderSHA256': sha(Path(__file__)), 'actualExecution': False,
              'originalVMMOrVZBindingModified': False, 'systemLibrariesModified': False}
    (out / 'providers.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: build-modern-cpu-providers.py RUNTIME_DIRECTORY NEW_OUTPUT_DIRECTORY')
    main(*sys.argv[1:])
