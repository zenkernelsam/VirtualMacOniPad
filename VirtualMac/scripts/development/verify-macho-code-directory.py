#!/usr/bin/env python3
"""Verify embedded CodeDirectory hashes without rewriting old ldid signatures.

Some trusted legacy runtime files have signatures that Apple's Mac-side
strict policy rejects. This checks their actual signed pages and embedded
requirements/entitlements; external bundle resources still need bundle checks.
"""
import hashlib
import struct


def check(data):
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected thin little-endian 64-bit Mach-O code")
    commands, size = struct.unpack_from("<II", data, 16)
    end = 32 + size
    if end > len(data) or commands > size // 8:
        raise ValueError("Malformed load-command table")
    offset, signatures = 32, []
    for _ in range(commands):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > end:
            raise ValueError("Malformed load command")
        if command == 0x1D:
            if length < 16:
                raise ValueError("Truncated LC_CODE_SIGNATURE")
            signatures.append(struct.unpack_from("<II", data, offset + 8))
        offset += length
    if offset != end or len(signatures) != 1:
        raise ValueError("Missing or duplicate LC_CODE_SIGNATURE")
    sig_offset, sig_size = signatures[0]
    if sig_offset < end or sig_offset + sig_size > len(data) or sig_size < 12:
        raise ValueError("Signature range outside executable")
    signature = data[sig_offset:sig_offset + sig_size]

    def integer(value, position):
        if position < 0 or position + 4 > len(value):
            raise ValueError("Signature integer outside blob")
        return struct.unpack_from(">I", value, position)[0]

    if integer(signature, 0) != 0xFADE0CC0:
        raise ValueError("Malformed signature superblob")
    length, count = integer(signature, 4), integer(signature, 8)
    if length > len(signature) or count > (length - 12) // 8:
        raise ValueError("Malformed signature index")
    blobs, ranges = {}, []
    for index in range(count):
        kind, start = struct.unpack_from(">II", signature, 12 + 8 * index)
        if start < 12 + 8 * count or start + 8 > length:
            raise ValueError("Signature blob outside bounds")
        blob_size = integer(signature, start + 4)
        if blob_size < 8 or start + blob_size > length or kind in blobs:
            raise ValueError("Invalid signature blob")
        if any(start < stop and begin < start + blob_size for begin, stop in ranges):
            raise ValueError("Overlapping signature blobs")
        ranges.append((start, start + blob_size))
        blobs[kind] = signature[start:start + blob_size]
    records = []
    for kind, cd in blobs.items():
        if integer(cd, 0) != 0xFADE0C02:
            continue
        if len(cd) < 44:
            raise ValueError("Truncated CodeDirectory")
        version, flags, hash_offset, identifier_offset, special, pages, limit = struct.unpack_from(">7I", cd, 8)
        hash_size, hash_type, _, page_power = struct.unpack_from(">4B", cd, 36)
        if version >= 0x20300 and limit == 0xFFFFFFFF:
            if len(cd) < 64:
                raise ValueError("Missing 64-bit CodeDirectory limit")
            limit = struct.unpack_from(">Q", cd, 56)[0]
        digest_sizes = {1: 20, 2: 32, 3: 20, 4: 48}
        if (hash_type not in digest_sizes or hash_size != digest_sizes[hash_type] or
            page_power > 30 or hash_offset < 44 + special * hash_size or
            hash_offset + pages * hash_size > len(cd) or
            not 44 <= identifier_offset < hash_offset - special * hash_size or
            b"\0" not in cd[identifier_offset:hash_offset - special * hash_size]):
            raise ValueError("Invalid CodeDirectory hashing bounds")
        function = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256, 4: hashlib.sha384}[hash_type]

        def digest(value):
            return function(value).digest()[:hash_size]

        page_size = 1 << page_power if page_power else limit
        expected = (limit + page_size - 1) // page_size if page_size else 0
        if not limit or limit > sig_offset or pages != expected:
            raise ValueError("CodeDirectory coverage mismatch")
        for index in range(pages):
            claimed = cd[hash_offset + index * hash_size:hash_offset + (index + 1) * hash_size]
            if digest(data[index * page_size:min((index + 1) * page_size, limit)]) != claimed:
                raise ValueError(f"Executable CodeDirectory page mismatch: {index}")
        for slot in (2, 5, 7):
            if special < slot:
                continue
            claimed = cd[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size]
            if slot in blobs:
                if digest(blobs[slot]) != claimed:
                    raise ValueError(f"Embedded special-slot hash mismatch: {slot}")
            elif any(claimed):
                raise ValueError(f"Missing hashed embedded signature slot: {slot}")
        records.append(dict(cdhash=function(cd).hexdigest()[:40], version=version,
                            flags=flags, codeLimit=limit, pages=pages, pageSize=page_size))
    if not records:
        raise ValueError("Missing CodeDirectory")
    return records
