#!/usr/bin/env python3
"""Experimental a2sb adapter for stock ipsw; never guesses a nearest symbol.

The release ipsw CLI has no project-specific a2sb command. Resolve exact export
addresses in one read-only cache pass, then let ipsw handle ObjC/cache aliases.
Invoke with the same arguments as ipsw dyld a2sb. VZ_STOCK_IPSW is required.
Use a writable --cache path; ipsw stores its symbol index there.
"""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys

from DyldExtractor.dyld.dyld_context import DyldContext
from DyldExtractor.dyld.dyld_trie import ReadExports
from DyldExtractor.dyld.dyld_structs import dyld_cache_header
from DyldExtractor.converter import slide_info
from types import SimpleNamespace
import logging


def stub_pointer_slot(cache, address, depth=0):
    """Recognize cache branch-island stubs and return their GOT slot."""
    converted = cache.convertAddr(address)
    if not converted or depth > 4:
        return None
    offset, context = converted
    words = context.readFormat("<IIII", offset)
    if words[0] & 0xFC000000 == 0x14000000:
        displacement = words[0] & 0x3FFFFFF
        if displacement & 0x2000000:
            displacement -= 0x4000000
        return stub_pointer_slot(cache, address + displacement * 4, depth + 1)
    registers, loads = {}, {}
    for i, word in enumerate(words):
        if word & 0x9F000000 == 0x90000000:
            immediate = ((word >> 29) & 3) | (((word >> 5) & 0x7FFFF) << 2)
            if immediate & 0x100000:
                immediate -= 0x200000
            registers[word & 31] = ((address + i * 4) & ~0xFFF) + immediate * 4096
        elif word & 0xFFC00000 == 0x91000000 and (word >> 5) & 31 in registers:
            registers[word & 31] = registers[(word >> 5) & 31] + ((word >> 10) & 0xFFF)
        elif word & 0xFFC00000 == 0xF9400000 and (word >> 5) & 31 in registers:
            loads[word & 31] = registers[(word >> 5) & 31] + ((word >> 10) & 0xFFF) * 8
        elif word & 0xFFFFFC00 == 0xD71F0800:  # BRAA
            return loads.get((word >> 5) & 31)
        elif word & 0xFFFFFC1F == 0xD61F0000:  # BR
            return loads.get((word >> 5) & 31)
    return None


def selector_stub(cache, address):
    converted = cache.convertAddr(address)
    if not converted:
        return None
    offset, context = converted
    adrp, add, branch = context.readFormat("<III", offset)
    if adrp & 0x9F00001F != 0x90000001 or add & 0xFFC003FF != 0x91000021:
        return None
    if branch & 0xFC000000 != 0x14000000:
        return None
    immediate = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7FFFF) << 2)
    if immediate & 0x100000:
        immediate -= 0x200000
    name_address = (address & ~0xFFF) + immediate * 4096 + ((add >> 10) & 0xFFF)
    converted_name = cache.convertAddr(name_address)
    if not converted_name:
        return None
    name_offset, name_context = converted_name
    name_data = bytes(name_context.getBytes(name_offset, 256))
    if b"\0" not in name_data:
        return None
    name_bytes = name_data.split(b"\0", 1)[0]
    if not name_bytes or not all(32 <= byte < 127 for byte in name_bytes):
        return None
    displacement = branch & 0x3FFFFFF
    if displacement & 0x2000000:
        displacement -= 0x4000000
    return address + 8 + displacement * 4, name_bytes.decode()


def exported_symbols(cache_path, wanted):
    result = {}
    with cache_path.open("rb") as stream:
        cache = DyldContext(stream)
        subfiles = cache.addSubCaches(cache_path)
        try:
            mappings = slide_info._getMappingInfo(SimpleNamespace(
                dyldCtx=cache, logger=logging.getLogger(__name__)))
            destinations = {}
            stub_destinations = {}
            selector_stubs = {}
            strings = set()
            for address in wanted:
                converted = cache.convertAddr(address)
                if not converted:
                    continue
                offset, context = converted
                for info in mappings:
                    if info.mapping.address <= address < info.mapping.address + info.mapping.size:
                        raw = context.readFormat("<Q", offset)[0]
                        if info.slideInfo.version == 5 and address % 8 == 0:
                            destinations[address] = slide_info.decodeV5Pointer(raw, info.slideInfo.value_add)[0]
                        break
                else:
                    raw_string = bytes(context.getBytes(offset, 256)).split(b"\0")[0]
                    if raw_string and all(32 <= byte < 127 for byte in raw_string):
                        strings.add(address)
                    else:
                        selector = selector_stub(cache, address)
                        if selector:
                            selector_stubs[address] = selector
                            continue
                        slot = stub_pointer_slot(cache, address)
                        if slot is not None:
                            slot_offset, slot_context = cache.convertAddr(slot)
                            for info in mappings:
                                if info.slideInfo.version == 5 and info.mapping.address <= slot < info.mapping.address + info.mapping.size:
                                    raw = slot_context.readFormat("<Q", slot_offset)[0]
                                    stub_destinations[address] = slide_info.decodeV5Pointer(raw, info.slideInfo.value_add)[0]
                                    break
            interesting = (wanted | set(destinations.values()) | set(stub_destinations.values())
                           | {target for target, _ in selector_stubs.values()})
            names = {}
            for image in cache.images:
                offset, context = cache.convertAddr(image.address)
                ncmds = struct.unpack_from("<I", context.file, offset + 16)[0]
                command_offset = offset + 32
                export = linkedit = None
                image_path = cache.readString(image.pathFileOffset)[:-1].decode()
                for _ in range(ncmds):
                    cmd, size = struct.unpack_from("<II", context.file, command_offset)
                    if size < 8:
                        raise ValueError("Invalid Mach-O load command")
                    if cmd == 0x19:
                        name = bytes(context.file[command_offset + 8:command_offset + 24]).split(b"\0")[0]
                        if name == b"__LINKEDIT":
                            linkedit = struct.unpack_from("<Q", context.file, command_offset + 24)[0]
                    elif cmd == 0x80000033:
                        export = struct.unpack_from("<II", context.file, command_offset + 8)
                    elif cmd in (0x22, 0x80000022):
                        old_export = struct.unpack_from("<II", context.file, command_offset + 40)
                        if old_export[1]:
                            export = old_export
                    command_offset += size
                if not export or not export[1] or linkedit is None:
                    continue
                link_context = cache.convertAddr(linkedit)[1]
                for symbol in ReadExports(link_context.file, *export):
                    if symbol.flags & 0x08:  # A re-export has no address here.
                        continue
                    # Absolute exports (kind=2) are not header-relative.
                    address = symbol.address if symbol.flags & 3 == 2 else image.address + symbol.address
                    if address in interesting:
                        name = symbol.name.rstrip(b"\0").decode()
                        previous = names.get(address)
                        # Keep canonical names ahead of cache-only aliases.
                        if previous is None or previous[0].startswith(("__got.", "_ptr.")):
                            names[address] = name, image_path
            for address in wanted:
                if address in names:
                    result[address] = names[address]
                elif destinations.get(address) in names:
                    name, image_path = names[destinations[address]]
                    # Protocol objects are localized by uncache's existing
                    # protocol handler. Ordinary GOT slots bind their target.
                    if name != "_OBJC_CLASS_$_Protocol":
                        name = "__got." + name
                    result[address] = name, image_path
                elif stub_destinations.get(address) in names:
                    result[address] = names[stub_destinations[address]]
                elif address in selector_stubs:
                    target, selector = selector_stubs[address]
                    if names.get(target, (None,))[0] == "_objc_msgSend":
                        result[address] = "_objc_msgSend$" + selector, names[target][1]
                elif address in strings:
                    result[address] = None, None
        finally:
            for subfile in subfiles:
                subfile.close()
    return result


def resolve_with_ipsw(binary, cache_path, symbol_cache, address):
    result = subprocess.run(
        [binary, "--no-color", "dyld", "a2s", "--image", "--cache",
         symbol_cache, str(cache_path), hex(address)],
        text=True, capture_output=True, check=True)
    # Examples: 0xADDR: _symbol. Reject an interior address's symbol+offset.
    for line in result.stdout.splitlines():
        match = re.match(r"\s*0x[0-9a-fA-F]+:\s+(.+?)\s*$", line)
        if match:
            symbol = match.group(1)
            if symbol.endswith(" + 0x0"):
                symbol = symbol[:-6]
            if " + " in symbol:
                return None, None
            return symbol, None
    return None, None


def main():
    arguments = sys.argv[1:]
    if arguments[:3] != ["--no-color", "dyld", "a2sb"]:
        raise SystemExit("This experimental adapter only implements dyld a2sb")
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    parser.add_argument("dsc", type=Path)
    parser.add_argument("addresses", type=Path)
    args = parser.parse_args(arguments[3:])
    binary = os.environ["VZ_STOCK_IPSW"]
    wanted = {int(line, 0) for line in args.addresses.read_text().split()}
    memo_path = Path(args.cache + ".batch.json")
    with args.dsc.open("rb") as stream:
        stream.seek(dyld_cache_header.uuid.offset)
        cache_uuid = stream.read(16).hex()
    memo = {}
    if memo_path.exists():
        saved = json.loads(memo_path.read_text())
        if saved.get("uuid") == cache_uuid:
            memo = saved.get("symbols", {})
    missing = {address for address in wanted if hex(address) not in memo
               or memo[hex(address)][0] == "?"}
    symbols = exported_symbols(args.dsc, missing) if missing else {}
    for address in sorted(wanted):
        name, image_path = symbols.get(address, memo.get(hex(address), (None, None)))
        if hex(address) not in memo and address not in symbols:
            name, image_path = resolve_with_ipsw(binary, args.dsc, args.cache, address)
        memo[hex(address)] = name, image_path
        print(f"{address:#x}\t{name or ''}\t{image_path or ''}", flush=True)
    temporary = memo_path.with_suffix(memo_path.suffix + ".tmp")
    temporary.write_text(json.dumps({"uuid": cache_uuid, "symbols": memo}))
    temporary.replace(memo_path)


if __name__ == "__main__":
    main()
