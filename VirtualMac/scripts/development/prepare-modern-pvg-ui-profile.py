#!/usr/bin/env python3
"""Prepare the exact reviewed PVG27 UI profile in a new local directory.

Apple framework source is unavailable: this is a guarded binary transformation,
not an Apple framework rebuild. No device, root, trustcache, or deployment work.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys


SIZE = 665056
UUID = "9e6a667aa77532de8dd56872ef6a53d9"
IDENTIFIER = "ParavirtualizedGraphics-55554944" + UUID
HEADER_SIZE = 4064
HEADER_SHA = "a4e199dcb0f8278f2970acd2f3ed52540aee2e8db9dded33076a956f18a9845f"
TARGET_SHA = "7c052a43cf26b232b114d787f6b3f9133c0646db953858717645895ab0ef5065"
TARGET_CD = "88b6ad7d5a32de3a956ac8f4b82c4d6f5604dfc8"
SHARED_OFFSET = 0x26B98
SHARED_ORIGINAL = bytes.fromhex("08a0613900010012c0035fd6")
SHARED_NO = bytes.fromhex("000080521f2003d5c0035fd6")
PROFILE_OFFSET = 0xDD8C
PROFILE_ORIGINAL = bytes.fromhex("f30300aa")
PROFILE_MAC = bytes.fromhex("13008052")
PHYSICAL_QUERY = bytes.fromhex("e00316aaa27d80529e600194")
INPUTS = {
    "6e1d9945180e8dcf57474b7ecd7bc42a49379e4101bb8db089a4433eae97c92d":
        ("original-pvg27", "1ff660a809fbcecb8407a98015ef7fc1ab7d22fe", SHARED_ORIGINAL, PROFILE_ORIGINAL),
    "fee8179463878128371b80a4ea776d2b72f8207dd817c2033eeb112ff8ca005c":
        ("shared-handles-disabled", "5faec3260055bfb8b5a234e1ad5a9a143d8b3b11", SHARED_NO, PROFILE_ORIGINAL),
    TARGET_SHA: ("reviewed-ui-profile", TARGET_CD, SHARED_NO, PROFILE_MAC),
}
SEGMENTS = (
    ("__TEXT", 4294967296, 425984, 0, 425984, 5, 5),
    ("__DATA_CONST", 4295393280, 81920, 425984, 81920, 3, 3),
    ("__AUTH_CONST", 4295475200, 32768, 507904, 32768, 3, 3),
    ("__AUTH", 4295507968, 16384, 540672, 16384, 3, 3),
    ("__DATA", 4295524352, 16384, 557056, 16384, 3, 3),
    ("__EXTRA_OBJC", 4295540736, 65536, 573440, 65536, 3, 3),
    ("__LINKEDIT", 4295606272, 32768, 638976, 26080, 1, 1),
)
GUARDS = (
    (58044, 44, "fbc215c356d660ba30d278ef76ef2b2e8f6fe512b5b723f78d98b6f346a2b392"),
    (404736, 32, "5a8fa4c7f9d00e6de1dcbf4bc2844050eed42fa949119cada7199d0d50cc24fa"),
    (149072, 32, "59c5b1145a6b46d5ea2a6801f4dbe594dd8fd5a0bb775885fefc7980d134321d"),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_input(path):
    """Bound the read and reject leaf symlinks, special files, or changed files."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_size == SIZE,
                "Input must be a regular, non-symlink 665056-byte file")
        chunks, remaining = [], SIZE + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(identity(before) == identity(after), "Input changed during read")
        data = b"".join(chunks)
        require(len(data) == SIZE, "Input size changed during read")
        return data, identity(after)
    finally:
        os.close(fd)


def macho(data):
    require(len(data) == SIZE and data[:4] == bytes.fromhex("cffaedfe"),
            "Expected exact thin 64-bit Mach-O")
    require(struct.unpack_from("<II", data, 4) == (0x100000C, 0x80000002),
            "Expected exact arm64e CPU/subtype")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    end = 32 + command_bytes
    require(end == HEADER_SIZE and sha(data[:end]) == HEADER_SHA,
            "Unknown Mach-O header/load commands")
    pos, segments, sections, uuids, signatures = 32, [], [], [], []
    for _ in range(count):
        require(pos + 8 <= end, "Truncated load command")
        command, size = struct.unpack_from("<II", data, pos)
        require(size >= 8 and pos + size <= end, "Invalid load command size")
        if command == 0x19:
            require(size >= 72, "Invalid segment")
            name = data[pos + 8:pos + 24].split(b"\0")[0].decode("ascii")
            segment = (name,) + struct.unpack_from("<QQQQii", data, pos + 24)
            segments.append(segment)
            nsections = struct.unpack_from("<I", data, pos + 64)[0]
            require(size == 72 + 80 * nsections, "Invalid section table")
            for i in range(nsections):
                p = pos + 72 + 80 * i
                section_name = data[p:p + 16].split(b"\0")[0].decode("ascii")
                address, length, offset = struct.unpack_from("<QQI", data, p + 32)
                flags = struct.unpack_from("<I", data, p + 64)[0]
                zero_fill = (flags & 0xFF) in (1, 12, 18)
                require(zero_fill or offset + length <= len(data), "Section outside file")
                sections.append(dict(name=name + "/" + section_name, va=address,
                    bytes=length, fileOffset=offset, flags=flags, zeroFill=zero_fill,
                    sha256=None if zero_fill else sha(data[offset:offset + length])))
        elif command == 0x1B:
            require(size == 24, "Invalid UUID command")
            uuids.append(data[pos + 8:pos + 24].hex())
        elif command == 0x1D:
            require(size == 16, "Invalid signature command")
            signatures.append((pos,) + struct.unpack_from("<II", data, pos + 8))
        pos += size
    require(pos == end and tuple(segments) == SEGMENTS, "Unknown segment layout/protection")
    require(uuids == [UUID] and signatures == [(4048, 663456, 1600)],
            "Unknown UUID/signature layout")
    return dict(uuid=UUID, headerBytes=end, headerSHA256=HEADER_SHA,
                cpuSubtype="0x80000002", segments=segments, sections=sections,
                signature=dict(commandOffset=4048, fileOffset=663456, bytes=1600))


def validate(data):
    digest = sha(data)
    require(digest in INPUTS, "Unknown input SHA256; only the three reviewed builds are accepted")
    profile = INPUTS[digest]
    metadata = macho(data)
    require(data[SHARED_OFFSET:SHARED_OFFSET + 12] == profile[2], "Wrong shared-texture getter")
    require(data[PROFILE_OFFSET:PROFILE_OFFSET + 4] == profile[3], "Wrong guest profile instruction")
    require(data[PROFILE_OFFSET - 12:PROFILE_OFFSET] == PHYSICAL_QUERY,
            "Physical Metal family query changed")
    for offset, length, expected in GUARDS:
        require(sha(data[offset:offset + length]) == expected, "Native runtime byte guard changed")
    return digest, profile, metadata


def new_output(path):
    project = Path(__file__).resolve().parents[3]
    require(path.name not in ("", ".", ".."), "Output must name a new directory")
    parent = path.parent.resolve(strict=True)
    allowed = ((project / "DeviceDiagnostics").resolve(strict=True), Path("/private/tmp"))
    require(any(parent == root or root in parent.parents for root in allowed),
            "Output parent must exist under project DeviceDiagnostics or /private/tmp")
    result = parent / path.name
    require(not os.path.lexists(result), "Refusing to reuse any existing output")
    return result


def write_new(path, data, mode=0o644):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
    path.chmod(mode)


def command(output, name, argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    write_new(output / "verification" / name,
              ("argv: " + repr(argv) + "\nexit: " + str(result.returncode)
               + "\nstdout:\n").encode() + result.stdout + b"\nstderr:\n" + result.stderr)
    require(result.returncode == 0, name + " failed: " + result.stderr.decode(errors="replace"))
    return result.stdout, result.stderr


def signature(output, binary, label, expected_cd):
    command(output, label + "-strict.txt",
            ["/usr/bin/codesign", "--verify", "--strict", "--verbose=4", str(binary)])
    entitlements, info = command(output, label + "-signature.txt",
            ["/usr/bin/codesign", "-dvvv", "--entitlements", "-", str(binary)])
    require(entitlements == b"", "Unexpected entitlements")
    for line in ("Identifier=" + IDENTIFIER, "CDHash=" + expected_cd,
                 "Info.plist=not bound", "Signature=adhoc", "TeamIdentifier=not set"):
        require(line.encode() in info.splitlines(), "Signature field changed: " + line)
    require(b"flags=0x2(adhoc)" in info and b"Entitlements" not in info,
            "Unexpected signature flags/entitlements")


def prepare(input_path, output):
    require(os.geteuid() != 0, "Run as an ordinary local user; root is unnecessary")
    output = new_output(output)
    raw, input_identity = read_input(input_path)
    digest, profile, before = validate(raw)
    output.mkdir(mode=0o700)  # Atomic failure if another process claimed the name.
    (output / "verification").mkdir(mode=0o700)
    try:
        baseline = output / "baseline-ParavirtualizedGraphics"
        pending = output / "candidate.pending"
        write_new(baseline, raw, 0o755)
        signature(output, baseline, "baseline", profile[1])
        patched = bytearray(raw)
        patched[SHARED_OFFSET:SHARED_OFFSET + 12] = SHARED_NO
        patched[PROFILE_OFFSET:PROFILE_OFFSET + 4] = PROFILE_MAC
        write_new(pending, patched, 0o755)
        command(output, "candidate-sign.txt", ["/usr/bin/codesign", "--force", "--sign", "-",
            "--identifier", IDENTIFIER, "--timestamp=none", "--pagesize", "16384", str(pending)])
        signed, _ = read_input(pending)
        after_sha, after_profile, after = validate(signed)
        require(after_sha == TARGET_SHA and after_profile[1] == TARGET_CD,
                "Signing did not reproduce the exact reviewed candidate")
        signature(output, pending, "candidate", TARGET_CD)
        differences = [i for i, pair in enumerate(zip(raw, signed)) if pair[0] != pair[1]]
        allowed = ((PROFILE_OFFSET, 4), (SHARED_OFFSET, 12), (663456, 1600))
        require(all(any(start <= i < start + length for start, length in allowed)
                    for i in differences), "Bytes outside the two patches/signature changed")
        require(before["segments"] == after["segments"] and before["signature"] == after["signature"],
                "Mach-O layout/protection changed")
        changed_sections = []
        for a, b in zip(before["sections"], after["sections"]):
            require({k: v for k, v in a.items() if k != "sha256"} ==
                    {k: v for k, v in b.items() if k != "sha256"}, "Section metadata changed")
            if a["sha256"] != b["sha256"]:
                changed_sections.append(a["name"])
        require(changed_sections == ([] if digest == TARGET_SHA else ["__TEXT/__text"]),
                "Unexpected changed section")
        for arguments, label in ((["/usr/bin/xcrun", "otool", "-L"], "dependencies"),
                                 (["/usr/bin/xcrun", "nm", "-gU"], "exports")):
            a, _ = command(output, "baseline-" + label + ".txt", arguments + [str(baseline)])
            b, _ = command(output, "candidate-" + label + ".txt", arguments + [str(pending)])
            if label == "dependencies":
                a, b = a.split(b"\n", 1)[1], b.split(b"\n", 1)[1]
            require(a == b, label + " changed")
        latest, latest_identity = read_input(input_path)
        require(latest == raw and latest_identity == input_identity, "Input changed during preparation")
        write_new(output / "verification" / "input-macho.json",
                  (json.dumps(before, indent=2) + "\n").encode())
        write_new(output / "verification" / "candidate-macho.json",
                  (json.dumps(after, indent=2) + "\n").encode())
        write_new(output / "prepare-modern-pvg-ui-profile.py", Path(__file__).read_bytes(), 0o755)
        candidate = output / "ParavirtualizedGraphics"
        pending.rename(candidate)
        result = dict(passed=True, formatVersion=1,
            sourceDisclosure="Exact guarded binary transformation; Apple source unavailable, not an Apple framework rebuild.",
            input=dict(path=str(input_path.absolute()), sha256=digest, bytes=SIZE,
                       cdhash=profile[1], profile=profile[0], unchanged=True),
            candidate=dict(path=str(candidate), sha256=TARGET_SHA, bytes=SIZE, cdhash=TARGET_CD),
            physicalMetalQueryUnchanged=True, nativeRuntimeByteGuardsUnchanged=True,
            headersAndProtectionsUnchanged=True, exportsAndDependenciesUnchanged=True,
            changedSections=changed_sections, changedByteCount=len(differences),
            signatureChangedByteCount=sum(i >= 663456 for i in differences),
            patches=[dict(offset=SHARED_OFFSET, before=profile[2].hex(), after=SHARED_NO.hex(),
                          meaning="Native supportsSharedTextures getter returns genuine NO"),
                     dict(offset=PROFILE_OFFSET, before=profile[3].hex(), after=PROFILE_MAC.hex(),
                          meaning="Disable optional guest SupportFlags2023 bit0, selecting existing Mac profile10001")],
            executedCandidate=False, deviceOperations=False, rootOperations=False,
            trustcacheWrites=False, deployed=False,
            acceptance="Build identity only; full guest/UI acceptance belongs to the separate live test report.")
        write_new(output / "build-result.json", (json.dumps(result, indent=2) + "\n").encode())
        rows = []
        for path in sorted(output.rglob("*")):
            if path.is_file():
                data = path.read_bytes()
                rows.append(dict(path=str(path.relative_to(output)), bytes=len(data), sha256=sha(data),
                                 mode=oct(stat.S_IMODE(path.stat().st_mode))))
        write_new(output / "artifact-manifest.json",
                  (json.dumps(dict(formatVersion=1, passed=True, files=rows), indent=2) + "\n").encode())
        return result
    except Exception:
        # A pending binary is never published on a failed verification.
        pending = output / "candidate.pending"
        if pending.exists():
            pending.chmod(0o600)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="One exact reviewed PVG27 binary; read only")
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="New directory under DeviceDiagnostics or /private/tmp; parent must exist")
    args = parser.parse_args()
    try:
        result = prepare(args.input, args.output_dir)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Refused: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(dict(candidate=result["candidate"], passed=True), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
