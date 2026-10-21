#!/usr/bin/env python3
"""Run with the isolated, patched DyldExtractor Python used by the candidate build."""
from ctypes import sizeof
import importlib.util
from pathlib import Path
import struct
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from DyldExtractor.converter import slide_info
from DyldExtractor.dyld.dyld_structs import dyld_cache_slide_info5

VZ = Path(__file__).resolve().parents[2] / "vz"
spec = importlib.util.spec_from_file_location("uncache", VZ / "uncache.py")
uncache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uncache)
spec = importlib.util.spec_from_file_location("cache_adapter", VZ / "development/tools/cache-a2s-batch.py")
cache_adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache_adapter)


class FixtureCache:
    def __init__(self, regions):
        self.regions = regions

    def convertAddr(self, address):
        for base, data in self.regions:
            if base <= address < base + len(data):
                context = SimpleNamespace(
                    readFormat=lambda fmt, off, data=data: struct.unpack_from(fmt, data, off),
                    getBytes=lambda off, size, data=data: data[off:off + size])
                return address - base, context
        return None


def fixture_image():
    """Small image with cache-emptied sections and an adjacent live data segment."""
    buf = bytearray(0x2000)
    text, data = 0x222000000, 0x270000000
    text_command_size = 72 + 3 * 80
    struct.pack_into("<8I", buf, 0, 0xFEEDFACF, 0x100000C, 2, 6, 2,
                     text_command_size + 72, 0, 0)
    for lc, name, address, offset, count, command_size in (
            (32, b"__TEXT", text, 0, 3, text_command_size),
            (32 + text_command_size, b"__DATA", data, 0x1000, 0, 72)):
        struct.pack_into("<II16sQQQQIIII", buf, lc, 0x19, command_size, name,
                         address, 0x1000, offset, 0x1000, 7, 5 if count else 3, count, 0)
    for k, name, address, size, offset in (
            (0, b"__text", text + 0x200, 0x20, 0x200),
            (1, b"__auth_stubs", text + 0x1000, 0, 0),
            (2, b"__objc_methname", text + 0x1000, 0, 0)):
        struct.pack_into("<16s16sQQIIIIIIII", buf, 32 + 72 + k * 80,
                         name, b"__TEXT", address, size, offset, 2, 0, 0,
                         0x80000400, 0, 0, 0)
    buf[0x200:0x220] = b"\x55" * 0x20
    buf[0x1000:] = b"\xAA" * 0x1000
    return buf, text, data


class ModernCacheTests(unittest.TestCase):
    def test_header_alignment(self):
        header = struct.pack("<III4xQ", 5, 16384, 3, 0x180000000)
        info = dyld_cache_slide_info5(header)
        self.assertEqual(sizeof(info), 24)
        self.assertEqual(info.page_starts_count, 3)
        self.assertEqual(info.value_add, 0x180000000)

    def test_plain_pointer_preserves_top_byte_and_stride(self):
        # Golden word generated with the SDK's shared-cache-rebase C bitfields.
        raw = 0x003002AC23456789
        self.assertEqual(slide_info.decodeV5Pointer(raw, 0x180000000),
                         (0xAB000001A3456789, 0, 0, 0, 0, 24))

    def test_authenticated_pointer_preserves_da_and_diversity(self):
        raw = 0x809F2BF923456789
        self.assertEqual(slide_info.decodeV5Pointer(raw, 0x180000000),
                         (0x2A3456789, 1, 2, 0xCAFE, 1, 72))

    def test_authenticated_instruction_key(self):
        raw = 0x8000000023456789
        self.assertEqual(slide_info.decodeV5Pointer(raw, 0x180000000),
                         (0x1A3456789, 1, 0, 0, 0, 0))

    def make_rebaser(self, source):
        rebaser = slide_info._V5Rebaser.__new__(slide_info._V5Rebaser)
        rebaser.slideInfo = SimpleNamespace(page_size=4096, value_add=0x180000000)
        rebaser.dyldCtx = SimpleNamespace(
            readFormat=lambda fmt, offset: struct.unpack_from(fmt, source, offset))
        return rebaser

    def test_chain_writes_only_pointer_slots(self):
        source = bytearray(b"\x55" * 4096)
        struct.pack_into("<Q", source, 0, 0x0020000000000100)
        struct.pack_into("<Q", source, 16, 0x8008000000000200)
        destination = bytearray(b"\x55" * 4096)
        context = SimpleNamespace(writeBytes=lambda off, data: destination.__setitem__(slice(off, off + len(data)), data))
        self.make_rebaser(source)._rebasePage(context, 0, 0)
        self.assertEqual(struct.unpack_from("<Q", destination, 0)[0], 0x180000100)
        self.assertEqual(struct.unpack_from("<Q", destination, 16)[0], 0x180000200)
        self.assertEqual(destination[8:16], b"\x55" * 8)
        self.assertEqual(destination[24:], b"\x55" * (4096 - 24))

    def test_chain_rejects_escape_from_page(self):
        source = bytearray(4096)
        struct.pack_into("<Q", source, 4088, 0x0020000000000100)
        context = SimpleNamespace(writeBytes=lambda off, data: None)
        with self.assertRaisesRegex(ValueError, "Invalid slide-info-v5"):
            self.make_rebaser(source)._rebasePage(context, 0, 4088)

    def test_relayout_keeps_authenticated_key_and_diversity(self):
        value = uncache.pack_auth_rebase(0x1234, 0xCAFE, 1, 2, 0)
        self.assertEqual((value >> 49) & 3, 2)
        self.assertEqual((value >> 32) & 0xFFFF, 0xCAFE)
        self.assertEqual((value >> 48) & 1, 1)

    def test_cache_authenticated_stub_uses_the_loaded_register(self):
        # Captured macOS 27 cache instructions: adrp/add x17; ldr x16; braa x16,x17.
        cache = FixtureCache([(0x22804FF60, struct.pack("<4I", 0x902893B1,
                             0x91326231, 0xF9400230, 0xD71F0A11))])
        self.assertEqual(cache_adapter.stub_pointer_slot(cache, 0x22804FF60), 0x2792C3C98)

    def test_cache_selector_stub_recovers_selector_and_tail_call(self):
        # Captured adrp/add x1 + backward B into objc_msgSend, including its string.
        cache = FixtureCache([
            (0x22800EA80, struct.pack("<4I", 0xD0E6A5C1, 0x91220021, 0x17FFC75E, 0xD4200020)),
            (0x1F54C8880, b"textureType\0")])
        self.assertEqual(cache_adapter.selector_stub(cache, 0x22800EA80),
                         (0x228000800, "textureType"))

    def test_cache_selector_stub_rejects_unterminated_string(self):
        cache = FixtureCache([
            (0x22800EA80, struct.pack("<4I", 0xD0E6A5C1, 0x91220021, 0x17FFC75E, 0xD4200020)),
            (0x1F54C8880, b"x" * 256)])
        self.assertIsNone(cache_adapter.selector_stub(cache, 0x22800EA80))

    def test_executable_reservation_preserves_live_data_and_original_ranges(self):
        buf, text, data = fixture_image()
        rebuilt, deltas = uncache.relayout_compact(buf, normalize_empty=True, text_tail=0x10000)
        mapping = uncache.make_amap(deltas)
        self.assertEqual(rebuilt[0x200:0x220], b"\x55" * 0x20)
        new_data = mapping(data) - 0x100000000
        self.assertEqual(new_data, 0x14000)
        self.assertEqual(rebuilt[new_data:new_data + 0x1000], b"\xAA" * 0x1000)
        self.assertIsNone(mapping(text + 0x1000))

    def test_branch_islands_preserve_call_opcode_and_selector_register(self):
        buf, text, data = fixture_image()
        struct.pack_into("<II", buf, 0x200, 0x94000000, 0x14000000)
        rebuilt, deltas = uncache.relayout_compact(buf, normalize_empty=True, text_tail=64)
        mapping = uncache.make_amap(deltas)
        names = {text + 0x200: "_objc_msgSend$textureType", text + 0x204: "_objc_msgSendSuper2"}
        data_va = mapping(data)
        got = {"__branch._objc_msgSend$textureType": data_va + 0x100,
               "__branch._objc_msgSendSuper2": data_va + 0x108}
        selectors = {"textureType": data_va + 0x120}
        uncache.rebuild_external_branches(rebuilt, uncache.parse_segments(rebuilt)[0],
            names, mapping, got, 0x100000000, selectors)
        first, second = struct.unpack_from("<II", rebuilt, 0x200)
        self.assertEqual(first & 0xFC000000, 0x94000000)
        self.assertEqual(second & 0xFC000000, 0x14000000)
        stub_address = 0x100000200 + (first & 0x3FFFFFF) * 4
        stub = struct.unpack_from("<8I", rebuilt, stub_address - 0x100000000)
        self.assertEqual(stub[0] & 31, 1)  # Selector stays in the ABI's x1 register.
        self.assertEqual(uncache._adrp_target(stub[0], stub_address)
                         + ((stub[1] >> 10) & 0xFFF) * 8, selectors["textureType"])
        self.assertEqual(stub[5], 0xD71F0A30)  # Authenticated jump, preserves caller's LR.
        empty = 32 + 72 + 2 * 80
        self.assertEqual(struct.unpack_from("<Q", rebuilt, empty + 32)[0], stub_address + 64)

    def test_unresolved_external_calls_fail_instead_of_emitting_invalid_code(self):
        buf, text, _ = fixture_image()
        struct.pack_into("<I", buf, 0x200, 0x94004000)  # Call outside all image segments.
        with patch.object(uncache, "a2s_batch", return_value={}):
            with self.assertRaisesRegex(SystemExit, "Unresolved cache branch island"):
                uncache.collect_external_branches(buf)

    def test_fixups_header_reserves_codesign_command_without_touching_code(self):
        buf, text, _ = fixture_image()
        old_size = struct.unpack_from("<I", buf, 20)[0]
        optional_offset = 32 + old_size
        struct.pack_into("<8I", buf, optional_offset, 0x26, 16, 0, 0, 0x29, 16, 0, 0)
        struct.pack_into("<II", buf, 16, 4, old_size + 32)
        # Just eight bytes remain between the original header and the first
        # function. Both the fixups and the subsequent signing LC need room.
        code_offset = optional_offset + 40
        section = 32 + 72
        struct.pack_into("<Q", buf, section + 32, text + code_offset)
        struct.pack_into("<I", buf, section + 48, code_offset)
        buf[code_offset:code_offset + 8] = b"livecode"
        uncache.append_fixups_command(buf, 0x1800, 64)
        _, new_size = struct.unpack_from("<II", buf, 16)
        self.assertLessEqual(32 + new_size + 16, code_offset)
        self.assertEqual(buf[code_offset:code_offset + 8], b"livecode")
        commands = []
        offset = 32
        for _ in range(struct.unpack_from("<I", buf, 16)[0]):
            cmd, size = struct.unpack_from("<II", buf, offset)
            commands.append(cmd)
            offset += size
        self.assertIn(uncache.LC_DYLD_CHAINED_FIXUPS, commands)
        self.assertNotIn(uncache.LC_FUNCTION_STARTS, commands)
        self.assertNotIn(uncache.LC_DATA_IN_CODE, commands)


if __name__ == "__main__":
    unittest.main()
