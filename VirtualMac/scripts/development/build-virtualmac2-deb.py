#!/usr/bin/env python3
"""Package a reviewed, complete Virtual Mac 2 runtime alongside release 1.2.3.

Inputs are local binary snapshots, never a connected device or a VM disk. The
normal application supplies the shared installation and networking helpers.
This package owns only its separate application and /var/root/VirtualMac2.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import lzma
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
RUNTIME = "/var/root/VirtualMac2"
APP_PATH = "/var/jb/Applications/VirtualMac2.app"
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def run(*arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package_helpers():
    spec = importlib.util.spec_from_file_location("virtualmac2_package", HERE / "package-virtualmac2.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def copy_tree(source, destination):
    if source.is_symlink() or not source.is_dir():
        raise ValueError(f"Expected a regular input directory: {source}")
    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copyfile)
    for path in destination.rglob("*"):
        if path.name == ".DS_Store" or path.name.startswith("._"):
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    for path in [destination, *destination.rglob("*")]:
        if path.is_symlink():
            target = os.readlink(path)
            # Existing framework links can deliberately reuse the normal
            # application's immutable runtime, declared as a dependency.
            resolved = PurePosixPath(target)
            if resolved.is_absolute() and not target.startswith("/var/root/VirtualMac/"):
                raise ValueError(f"Unexpected external runtime link: {path} -> {target}")
            if not resolved.is_absolute() and not path.resolve().is_relative_to(destination.resolve()):
                raise ValueError(f"Runtime link escapes its copied subtree: {path} -> {target}")
        elif path.is_dir():
            path.chmod(0o755)
        elif path.is_file():
            path.chmod(0o755 if path.read_bytes()[:4] in MACHO_MAGICS else 0o644)
        else:
            raise ValueError(f"Unsupported package input node: {path}")


def code_identity(path):
    data = path.read_bytes()
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("App must be a thin 64-bit Mach-O")
    count = struct.unpack_from("<I", data, 16)[0]
    offset, result = 32, []
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x1B:
            result.append(("UUID", data[offset + 8:offset + 24].hex()))
        elif command == 0x19:
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(sections):
                position = offset + 72 + index * 80
                name, segment, address, length, start, _, _, _, flags, _, _, _ = struct.unpack_from(
                    "<16s16sQQ8I", data, position)
                if flags & 0xFF not in (1, 12, 18):
                    result.append((segment.hex(), name.hex(), address, length,
                                   hashlib.sha256(data[start:start + length]).hexdigest()))
        offset += size
    return result


def configure_app(source, destination, version, build):
    copy_tree(source, destination)
    before = code_identity(destination / "VirtualMac")
    info_path = destination / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier="com.mac.virtual.v2", CFBundleName="Virtual Mac 2.0",
                CFBundleDisplayName=f"Virtual Mac {version}", CFBundleShortVersionString=version,
                CFBundleVersion=build, VirtualMacRuntimeRoot=RUNTIME,
                VirtualMacPVGBackendVersion=27, MinimumOSVersion="16.1")
    for row in info.get("CFBundleURLTypes", []):
        row["CFBundleURLName"] = "com.mac.virtual.v2"
        row["CFBundleURLSchemes"] = ["virtualmac2"]
    info_path.write_bytes(plistlib.dumps(info))
    for strings in destination.glob("*.lproj/InfoPlist.strings"):
        raw = run("plutil", "-convert", "xml1", "-o", "-", str(strings), capture_output=True).stdout
        localized = plistlib.loads(raw)
        for key in ("CFBundleName", "CFBundleDisplayName"):
            if isinstance(localized.get(key), str):
                localized[key] = localized[key] + " " + version
        strings.write_bytes(plistlib.dumps(localized, fmt=plistlib.FMT_BINARY))
    # Capture the reviewed executable's actual entitlements, including the
    # platform flag, and preserve them when only version metadata changes.
    original = run("codesign", "-d", "--entitlements", ":-", str(source),
                   capture_output=True).stdout
    entitlements = destination.parent / "app-entitlements.plist"
    entitlements.write_bytes(original)
    run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier",
        "com.mac.virtual.v2", "--entitlements", str(entitlements), str(destination))
    run("codesign", "--verify", "--deep", "--strict", str(destination))
    signed = run("codesign", "-d", "--entitlements", ":-", str(destination),
                 capture_output=True).stdout
    if plistlib.loads(original) != plistlib.loads(signed) or before != code_identity(destination / "VirtualMac"):
        raise ValueError("Changing app version altered entitlements or executable code sections")
    entitlements.unlink()


def signed_code(path, directory, allow_legacy=False):
    details = run("codesign", "-d", "--verbose=4", str(path),
                  capture_output=True, text=True)
    match = re.search(r"^CDHash=([0-9a-f]{40})$", details.stdout + details.stderr, re.M)
    if not match:
        raise ValueError(f"Missing code-directory hash: {path}")
    isolated = Path(directory) / "code-validation"
    shutil.copyfile(path, isolated)
    # The main application seal hashes Info.plist and resources. Validate it
    # in its complete clean bundle, rather than deleting that bundle context.
    verification_target = path.parent if path.parent.suffix == ".app" and path.name == "VirtualMac" else isolated
    strict = subprocess.run(["codesign", "--verify", "--strict", str(verification_target)], capture_output=True)
    spec = importlib.util.spec_from_file_location("code_directory", HERE / "verify-macho-code-directory.py")
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    directories = validator.check(path.read_bytes())
    if match.group(1) not in {entry["cdhash"] for entry in directories}:
        raise ValueError(f"Reported CDHash differs from verified CodeDirectory: {path}")
    if strict.returncode and not allow_legacy:
        raise ValueError(f"Strict signature verification failed: {path}: {strict.stderr.decode()}")
    run("dyld_info", "-validate_only", str(isolated), capture_output=True)
    isolated.unlink()
    return match.group(1), strict.returncode == 0


def tar_bytes(paths, root, epoch):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for path in paths:
            name = "./" + str(path.relative_to(root))
            info = archive.gettarinfo(str(path), arcname=name)
            info.uid = info.gid = 0
            info.uname, info.gname = "root", "wheel"
            info.mtime = epoch
            info.pax_headers = {}
            if info.isfile():
                with path.open("rb") as handle:
                    archive.addfile(info, handle)
            else:
                archive.addfile(info)
    return lzma.compress(buffer.getvalue(), preset=6)


def write_deb(path, control, data, epoch):
    # Construct the standard three-member Debian ar archive. Data includes
    # only owned subtrees, never chmod/chown metadata for /var/root, /var/jb,
    # or their existing application parent directories.
    with path.open("wb") as handle:
        handle.write(b"!<arch>\n")
        for name, contents in (("debian-binary", b"2.0\n"),
                               ("control.tar.xz", control), ("data.tar.xz", data)):
            header = (f"{name + '/':<16}{epoch:<12}{0:<6}{0:<6}{'100644':<8}{len(contents):<10}`\n").encode()
            if len(header) != 60:
                raise ValueError("Invalid Debian archive member")
            handle.write(header)
            handle.write(contents)
            if len(contents) % 2:
                handle.write(b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-payload", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--compiler-runtime", type=Path, required=True)
    parser.add_argument("--shader-cache", type=Path, required=True)
    parser.add_argument("--probes", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-version", default="2.0.0beta1")
    parser.add_argument("--build-number", default="1001")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+-]*", args.release_version) or not re.fullmatch(r"[0-9]+", args.build_number):
        parser.error("Expected a safe release version and numeric build number")
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    deb = output / f"VirtualMac_{args.release_version}_{args.build_number}.deb"
    if deb.exists():
        raise ValueError("Refusing to overwrite a release package")
    helper = package_helpers()
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "1791417600"))
    with tempfile.TemporaryDirectory(prefix="virtualmac2-deb-", dir="/private/tmp") as temporary:
        temporary = Path(temporary)
        stage = temporary / "stage"
        runtime, app = stage / RUNTIME[1:], stage / APP_PATH[1:]
        runtime.mkdir(parents=True)
        app.parent.mkdir(parents=True)
        copy_tree(args.runtime_payload, runtime / "payload")
        configure_app(args.app, app, args.release_version, args.build_number)
        compiler = runtime / "package-source/compiler27"
        compiler_files, profile, work, compiler_info = helper.stage_compiler_runtime(args.compiler_runtime, compiler)
        # Work and target-specific identity receipts belong to the target
        # device, not a public release archive.
        work.rmdir()
        helper.stage_shader_cache(args.shader_cache, runtime / "shader-cache/air25")
        (runtime / "testing").mkdir()
        for name in ("modern-pvg-smoke", "pvg-backend-contract"):
            shutil.copyfile(args.probes / name, runtime / "testing" / name)
            (runtime / "testing" / name).chmod(0o755)
        code, file_records, trust = [], [], []
        for path in sorted([*runtime.rglob("*"), *app.rglob("*")]):
            if not path.is_file() or path.is_symlink():
                continue
            installed = "/" + str(path.relative_to(stage))
            if compiler in path.parents:
                installed = RUNTIME + "/compiler27/" + path.name
            digest = sha(path)
            row = dict(path=installed, sha256=digest, bytes=path.stat().st_size)
            if path.read_bytes()[:4] in MACHO_MAGICS:
                cdhash, strict = signed_code(path, temporary, allow_legacy=(runtime / "payload") in path.parents)
                row["cdhash"] = cdhash
                row["codeDirectoryIntegrity"] = True
                row["nativeStrictSignature"] = strict
                code.append(row)
                trust.append(cdhash + "\t" + installed)
            file_records.append(row)
        manifest = dict(formatVersion=1, package="com.mac.virtual.v2", version=args.release_version,
                        build=args.build_number, backend="macOS 27 PVG/GPU/MetalSerializer/compiler; Ventura CPU/VMM/VZ",
                        dependency="com.mac.virtual (>= 1.2.3)", compilerProfile=compiler_info["profile"],
                        shaderCacheEntries=len(json.loads((args.shader_cache / "manifest.json").read_text())["entries"]),
                        deviceIdentityReceiptIncluded=False, guestDataIncluded=False, files=file_records)
        metadata = runtime / "release"
        metadata.mkdir()
        (metadata / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (metadata / "trustcache.txt").write_text("\n".join(sorted(set(trust))) + "\n")
        (metadata / "files.sha256").write_text("".join(row["sha256"] + "  " + row["path"] + "\n" for row in file_records))
        compiler_table = runtime / "package-source/compiler27.sha256"
        compiler_table.write_text("".join(sha(compiler / name) + "  " + name + "\n"
                                          for name in (*helper.COMPILER_FILES, "compiler-profile.json")))
        maintainer = temporary / "DEBIAN"
        copy_tree(REPO / "packaging/virtualmac2/DEBIAN", maintainer)
        size = sum(path.stat().st_size for path in [*runtime.rglob("*"), *app.rglob("*")]
                   if path.is_file() and not path.is_symlink())
        control = (maintainer / "control").read_text()
        control = control.replace("@VERSION@", args.build_number).replace("@RELEASE@", args.release_version)
        control = control.replace("@INSTALLED_SIZE@", str((size + 1023) // 1024))
        (maintainer / "control").write_text(control)
        for name in ("preinst", "postinst", "prerm", "postrm"):
            (maintainer / name).chmod(0o755)
            run("/bin/sh", "-n", str(maintainer / name))
        data_paths = [runtime, *sorted(runtime.rglob("*")), app, *sorted(app.rglob("*"))]
        control_tar = tar_bytes(sorted(maintainer.iterdir()), maintainer, epoch)
        data_tar = tar_bytes(data_paths, stage, epoch)
        write_deb(deb, control_tar, data_tar, epoch)
        (output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (output / "release-code-pins.json").write_text(json.dumps(code, indent=2) + "\n")
    run("dpkg-deb", "--info", str(deb))
    (output / "SHA256SUMS").write_text(sha(deb) + "  " + deb.name + "\n")
    print(json.dumps(dict(package=str(deb), sha256=sha(deb), signedCodeFiles=len(code),
                          version=args.release_version, build=args.build_number)))


if __name__ == "__main__":
    main()
