#!/usr/bin/env python3
"""Prepare an unsigned macOS27 VMM copy with seven targeted strong runtime imports.

This edits original chained-import ordinals, never weakens imports, and does
not reconstruct pointers, port the platform, sign, deploy or execute the VMM.
VZ nlist metadata alone is deliberately insufficient for this operation.
"""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import sys

SOURCE_SHA = 'c81d16f0ec5364bf71d915ac3ee9388610dc940446b2ad1abf3849ba57d46422'
SOURCE_BYTES = 5195312
TARGETS = {
    '__ZTINSt3__119bad_expected_accessIvEE': (14, '@rpath/VM27CxxProvider.dylib'),
    '__ZNKSt3__119bad_expected_accessIvE4whatEv': (14, '@rpath/VM27CxxProvider.dylib'),
    '__ZNSt13exception_ptr31__from_native_exception_pointerEPv': (14, '@rpath/VM27CxxProvider.dylib'),
    '__ZNSt3__113__hash_memoryEPKvm': (14, '@rpath/VM27CxxProvider.dylib'),
    '_malloc_type_calloc': (15, '@rpath/VM27AllocatorProvider.dylib'),
    '_malloc_type_malloc': (15, '@rpath/VM27AllocatorProvider.dylib'),
    '_swift_getTypeByMangledNameInContext2': (41, '@rpath/VM27SwiftLookupCompat.dylib'),
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def commands(data):
    assert len(data) >= 32 and struct.unpack_from('<I', data)[0] == 0xfeedfacf
    at = 32
    end = at + struct.unpack_from('<I', data, 20)[0]
    assert end <= len(data)
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, at)
        assert size >= 8 and size % 8 == 0 and at + size <= end
        yield cmd, at, size
        at += size
    assert at == end


def string(data, at, end):
    assert 0 <= at < end <= len(data)
    zero = data.find(b'\0', at, end)
    assert zero >= at and zero - at < 4096
    return bytes(data[at:zero]).decode()


def libraries(data):
    return [string(data, at + struct.unpack_from('<I', data, at + 8)[0], at + size)
            for cmd, at, size in commands(data) if cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023)]


def import_rows(data):
    fixups = [struct.unpack_from('<II', data, at + 8)
              for cmd, at, size in commands(data) if cmd == 0x80000034]
    assert len(fixups) == 1, 'Original chained binding metadata is required'
    start, size = fixups[0]
    assert start + size <= len(data)
    version, starts, imports, symbols, count, fmt, symfmt = struct.unpack_from('<7I', data, start)
    assert version == symfmt == 0 and fmt == 2 and count == 1203
    assert imports + count * 8 <= size and symbols < size
    rows = []
    for index in range(count):
        at = start + imports + index * 8
        word, addend = struct.unpack_from('<Ii', data, at)
        ordinal = word & 255
        if ordinal > 0xf0:
            ordinal -= 256
        assert symbols + (word >> 9) < size
        rows.append({'index': index, 'offset': at,
                     'symbol': string(data, start + symbols + (word >> 9), start + size),
                     'ordinal': ordinal, 'weak': bool(word & 256), 'addend': addend})
    return rows


def dylib_command(name):
    encoded = name.encode() + b'\0'
    size = (24 + len(encoded) + 7) & ~7
    return struct.pack('<6I', 0xc, size, 24, 0, 0, 0) + encoded + bytes(size - 24 - len(encoded))


def main(input_path, output_directory):
    source = Path(input_path)
    assert source.is_file() and not source.is_symlink()
    original = source.read_bytes()
    assert len(original) == SOURCE_BYTES and sha(original) == SOURCE_SHA
    assert struct.unpack_from('<3I', original, 4) == (0x100000c, 0x80000002, 2)
    before = import_rows(original)
    assert sum(not row['weak'] for row in before) == 1064
    old_libraries = libraries(original)
    assert old_libraries[13:15] == ['/usr/lib/libc++.1.dylib', '/usr/lib/libSystem.B.dylib']
    assert old_libraries[40] == '/usr/lib/swift/libswiftCore.dylib'
    additions = ['@rpath/VM27CxxProvider.dylib', '@rpath/VM27AllocatorProvider.dylib',
                 '@rpath/VM27SwiftLookupCompat.dylib']
    assert not set(additions).intersection(old_libraries) and len(old_libraries) + len(additions) <= 0xf0
    ordinals = {name: len(old_libraries) + index + 1 for index, name in enumerate(additions)}
    data = bytearray(original)
    selected = []
    for row in before:
        if row['symbol'] in TARGETS:
            expected, provider = TARGETS[row['symbol']]
            assert row['ordinal'] == expected and row['weak'] is False and row['addend'] == 0
            word = struct.unpack_from('<I', data, row['offset'])[0]
            struct.pack_into('<I', data, row['offset'], (word & ~255) | ordinals[provider])
            selected.append({**row, 'newOrdinal': ordinals[provider], 'newProvider': provider})
    assert len(selected) == len(TARGETS) and {row['symbol'] for row in selected} == set(TARGETS)
    # Keep nlist's matching undefined-symbol metadata consistent with the
    # actual chained-import table, while retaining every low descriptor bit.
    symtabs = [struct.unpack_from('<4I', data, at + 8)
               for cmd, at, size in commands(data) if cmd == 2]
    assert len(symtabs) == 1
    symoff, nsyms, stroff, strsize = symtabs[0]
    assert symoff + nsyms * 16 <= len(data) and stroff + strsize <= len(data)
    nlist_changes = []
    for index in range(nsyms):
        at = symoff + index * 16
        strx, kind, section, desc, value = struct.unpack_from('<IBBHQ', data, at)
        if kind & 0xe0 or kind & 0xe != 0 or strx == 0:
            continue
        assert strx < strsize
        name = string(data, stroff + strx, stroff + strsize)
        if name not in TARGETS:
            continue
        expected, provider = TARGETS[name]
        assert desc >> 8 == expected and desc & 0x40 == 0
        new = (desc & 255) | (ordinals[provider] << 8)
        struct.pack_into('<H', data, at + 6, new)
        nlist_changes.append({'symbol': name, 'index': index, 'offset': at + 6,
                              'originalDescriptor': desc, 'newDescriptor': new})
    assert len(nlist_changes) == len(TARGETS)
    assert {row['symbol'] for row in nlist_changes} == set(TARGETS)
    original_commands = list(commands(original))
    signature_commands = [(at, size) for cmd, at, size in original_commands if cmd == 0x1d]
    assert len(signature_commands) == 1 and signature_commands[0][0] + signature_commands[0][1] == 32 + struct.unpack_from('<I', original, 20)[0]
    unchanged_commands = [original[at:at + size] for cmd, at, size in original_commands if cmd != 0x1d]
    new_commands = b''.join(unchanged_commands + [dylib_command(name) for name in additions])
    section_ranges = []
    for cmd, at, size in original_commands:
        if cmd == 0x19:
            count = struct.unpack_from('<I', original, at + 64)[0]
            assert 72 + count * 80 == size
            for index in range(count):
                s = at + 72 + index * 80
                length = struct.unpack_from('<Q', original, s + 40)[0]
                offset = struct.unpack_from('<I', original, s + 48)[0]
                flags = struct.unpack_from('<I', original, s + 64)[0]
                if length and offset and flags & 255 not in (1, 12, 18):
                    assert offset + length <= len(original)
                    section_ranges.append((offset, length))
    old_end = 32 + struct.unpack_from('<I', original, 20)[0]
    new_end = 32 + len(new_commands)
    first_section = min(offset for offset, length in section_ranges)
    assert old_end <= new_end <= first_section and not any(original[old_end:first_section])
    data[32:new_end] = new_commands
    struct.pack_into('<II', data, 16, len(unchanged_commands) + len(additions), len(new_commands))
    after = import_rows(data)
    assert libraries(data) == old_libraries + additions
    assert len(after) == len(before) and sum(not row['weak'] for row in after) == 1064
    for old, new in zip(before, after):
        expected = dict(old)
        if old['symbol'] in TARGETS:
            expected['ordinal'] = ordinals[TARGETS[old['symbol']][1]]
        assert new == expected
    assert all(original[offset:offset + size] == data[offset:offset + size]
               for offset, size in section_ranges)
    assert not any(cmd == 0x1d for cmd, at, size in commands(data))
    # Prove every changed byte is restricted to headers, seven import ordinal
    # bytes and the corresponding nlist descriptor words.
    allowed = {index for index in range(16, 24)} | set(range(32, new_end))
    allowed.update(row['offset'] for row in selected)
    for row in nlist_changes:
        allowed.update((row['offset'], row['offset'] + 1))
    changed = [index for index, (a, b) in enumerate(zip(original, data)) if a != b]
    assert len(data) == len(original) and set(changed) <= allowed
    out = Path(output_directory).resolve()
    assert not out.exists() and not out.is_symlink()
    out.mkdir(mode=0o700)
    candidate = out / 'VirtualMachine.runtime-imports.macos27.unsigned'
    candidate.write_bytes(data)
    result = subprocess.run(['xcrun', 'dyld_info', '-validate_only', str(candidate)], capture_output=True, timeout=20)
    (out / 'dyld-validation.stdout').write_bytes(result.stdout)
    (out / 'dyld-validation.stderr').write_bytes(result.stderr)
    assert result.returncode == 0, 'Static Mach-O validation failed; candidate retained, never executable'
    report = {'sourcePath': str(source.resolve()), 'sourceSHA256': SOURCE_SHA,
              'candidateSHA256': sha(data), 'candidateBytes': len(data),
              'originalImportRows': 1203, 'strongImportRowsBeforeAndAfter': 1064,
              'selectedActualChainedImports': selected, 'matchingNlistChanges': nlist_changes,
              'addedDependencies': ordinals, 'changedByteCount': len(changed),
              'allFileBackedSectionsByteIdentical': True,
              'allOtherChainedImportRowsUnchanged': True,
              'weakFlagsAndAddendsUnchanged': True, 'platformAndCPUABIUnchanged': True,
              'signatureRemovedForUnsignedCandidate': True, 'dyldStaticValidationPassed': True,
              'actualVMMExecuted': False, 'actualFullStrongClosureProved': False,
              'lookupAdapterActualIPadProbe': 'PID72397, 324 explicit real type lookup calls; separate guarded probe',
              'remainingKnownUntargetedImport': 'Other original runtime/framework bindings remain unresolved; full closure not claimed',
              'runtimeEntrypointTestIsVMMExecutionProof': False,
              'VZPatchedFromNlistMetadata': False, 'systemOrProductionModified': False}
    (out / 'binding-review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: prepare-modern-vmm-allocator-imports.py PINNED_ORIGINAL_VMM NEW_OUTPUT_DIRECTORY')
    main(*sys.argv[1:])
