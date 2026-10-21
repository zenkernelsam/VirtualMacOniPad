#!/usr/bin/env python3
"""Package an isolated macOS 27 test runtime from already built binaries.

The original-payload argument is a read-only snapshot of a working iPad payload.
This never changes the shipping application or a connected device. The runtime
archive overlays a COPY of that snapshot at /var/root/VirtualMac2/payload.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile


def run(*arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


TASK_NAME = "com.apple.gpusw.ParavirtualizedGraphicsGPUTask"
COMPILER_FILES = (
    "VM27CompilerCompat.dylib", "VM27GPUCompiler.dylib",
    "VM27GPUCompilerImpl.dylib", "VM27LLVM.dylib",
    "VM27llvm-flatbuffers.dylib", "VM27llvm-lmdb.dylib",
    "metal-library-convert",
)
VMM_DEPENDENCIES = (
    "@loader_path/../../../Frameworks/ModernRuntimeCompat.dylib",
    "@loader_path/../../../Frameworks/MetalSerializer.framework/MetalSerializer",
)
APP_SETTINGS = dict(
    CFBundleIdentifier="com.mac.virtual.v2", CFBundleDisplayName="Virtual Mac 2.0",
    CFBundleName="Virtual Mac 2.0", CFBundleShortVersionString="2.0.0",
    CFBundleVersion="20001", MinimumOSVersion="16.1",
    VirtualMacRuntimeRoot="/var/root/VirtualMac2", VirtualMacPVGBackendVersion=27,
)


def dylib_dependencies(path):
    """Read exact install names without loading or modifying the executable."""
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError(f"Expected thin 64-bit Mach-O: {path}")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    offset, end = 32, 32 + command_bytes
    names = []
    for _ in range(count):
        if offset + 8 > end or end > len(data):
            raise ValueError(f"Invalid load-command table: {path}")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError(f"Invalid load command: {path}")
        if command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            if size < 24:
                raise ValueError(f"Invalid dylib load command: {path}")
            start = offset + struct.unpack_from("<I", data, offset + 8)[0]
            stop = data.find(b"\0", start, offset + size)
            if start < offset + 24 or stop < start:
                raise ValueError(f"Invalid dylib install name: {path}")
            names.append(data[start:stop].decode())
        offset += size
    if offset != end:
        raise ValueError(f"Load-command size mismatch: {path}")
    return names


def stage_shader_cache(source, destination):
    """Stage only hash-pinned shader data with recorded Apple verification."""
    manifest_path = source / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("Shader manifest must be a regular file")
    raw_manifest = manifest_path.read_bytes()
    if len(raw_manifest) > 1024 * 1024:
        raise ValueError("Shader manifest exceeds the runtime's 1 MiB limit")
    manifest = json.loads(raw_manifest)
    if (not isinstance(manifest, dict) or
        type(manifest.get("formatVersion")) is not int or
        manifest["formatVersion"] != 1 or
        manifest.get("deviceSystemModified") is not False or
        not isinstance(manifest.get("entries"), dict) or not manifest["entries"]):
        raise ValueError("Expected an application-only AIR 2.5 shader-cache manifest")
    destination.mkdir(parents=True, exist_ok=True)
    destination.parent.chmod(0o700)
    destination.chmod(0o700)
    staged = []
    for input_hash, entry in sorted(manifest["entries"].items()):
        if (not isinstance(input_hash, str) or
            not re.fullmatch(r"[0-9a-f]{64}", input_hash) or
            not isinstance(entry, dict)):
            raise ValueError("Shader cache entry must use a 64-digit lowercase SHA256 key")
        filename = input_hash + ".metallib"
        language = entry.get("languageVersion")
        if (entry.get("filename") != filename or
            not isinstance(entry.get("outputSHA256"), str) or
            not re.fullmatch(r"[0-9a-f]{64}", entry["outputSHA256"]) or
            entry.get("airVersion") != [2, 5, 0] or
            not isinstance(language, list) or len(language) != 3 or
            any(type(part) is not int for part in language) or
            language[2] != 0 or
            not ((language[0] == 1 and 0 <= language[1] <= 2) or
                 (language[0] == 2 and 0 <= language[1] <= 4) or
                 language == [3, 0, 0]) or
            entry.get("appleAIRVerified") is not True or
            entry.get("appleLLVMVerified") is not True):
            raise ValueError(f"Shader entry lacks compatible AIR 2.5 and Apple verifier records: {input_hash}")
        file = source / filename
        if file.is_symlink():
            raise ValueError(f"Shader cache file must be a regular file: {file}")
        data = file.read_bytes()
        if (len(data) > 16 * 1024 * 1024 or data[:4] != b"MTLB" or
            hashlib.sha256(data).hexdigest() != entry["outputSHA256"]):
            raise ValueError(f"Shader cache contents do not match verified output: {file}")
        output_file = destination / filename
        output_file.write_bytes(data)
        output_file.chmod(0o600)
        staged.append(output_file)
    output_manifest = destination / "manifest.json"
    output_manifest.write_bytes(raw_manifest)
    output_manifest.chmod(0o600)
    return [output_manifest] + staged


def clean_bundle_copy(app, directory):
    copied = Path(directory) / app.name
    shutil.copytree(app, copied, symlinks=True, copy_function=shutil.copyfile)
    run("xattr", "-cr", str(copied))
    return copied


def mobile_cache_member(member):
    # VMM and its task run as mobile, even when root installs this archive.
    member.uid = member.gid = 501
    member.uname = member.gname = "mobile"
    member.mode = 0o700 if member.isdir() else 0o600
    return member


def compiler_member(member):
    # Runtime code is immutable to mobile; only the separate work directory is
    # writable. Never inherit the Mac checkout's UID or candidate's 0700 mode.
    member.uid = member.gid = 0
    member.uname, member.gname = "root", "wheel"
    member.mode = 0o644 if member.name == "compiler27/compiler-profile.json" else 0o755
    return member


def compiler_platform(path):
    data = path.read_bytes()
    dylib_dependencies(path)  # Also validates the complete load-command bounds.
    cpu, _, kind, count = struct.unpack_from("<4I", data, 4)
    expected_kind = 2 if path.name == "metal-library-convert" else 6
    if cpu != 0x100000C or kind != expected_kind:
        raise ValueError(f"Compiler runtime requires ARM64 iOS code: {path}")
    offset, platforms = 32, []
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x32:
            if size < 24:
                raise ValueError(f"Invalid compiler build version: {path}")
            platform, minimum = struct.unpack_from("<II", data, offset + 8)
            platforms.append((platform, minimum))
        offset += size
    if not platforms or any(platform != 2 or minimum > 0x100100
                            for platform, minimum in platforms):
        raise ValueError(f"Compiler runtime must support iPadOS 16.1: {path}")


def stage_compiler_runtime(source, destination):
    """Copy an exact private compiler profile; no diagnostic trees or jobs."""
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Compiler runtime must be a regular self-contained directory")
    profile_path = source / "compiler-profile.json"
    if (profile_path.is_symlink() or not profile_path.is_file() or
        profile_path.stat().st_nlink != 1 or profile_path.stat().st_size > 64 * 1024):
        raise ValueError("Compiler profile must be a regular file of at most 64 KiB")
    raw_profile = profile_path.read_bytes()
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Compiler profile repeats a JSON field: {key}")
            result[key] = value
        return result
    profile = json.loads(raw_profile, object_pairs_hook=unique_object)
    if (not isinstance(profile, dict) or type(profile.get("formatVersion")) is not int or
        profile["formatVersion"] != 1 or
        not isinstance(profile.get("profile"), str) or
        not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile["profile"]) or
        any(not isinstance(profile.get(key), str) or not profile[key] or
            len(profile[key]) > 1024 for key in ("source", "scope")) or
        not isinstance(profile.get("files"), list) or len(profile["files"]) != len(COMPILER_FILES)):
        raise ValueError("Expected a version-1 private compiler profile with exactly seven code files")
    entries = {}
    for entry in profile["files"]:
        if (not isinstance(entry, dict) or entry.get("filename") not in COMPILER_FILES or
            entry["filename"] in entries or
            not isinstance(entry.get("sha256"), str) or
            not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) or
            not isinstance(entry.get("cdhash"), str) or
            not re.fullmatch(r"[0-9a-f]{40}", entry["cdhash"]) or
            type(entry.get("size")) is not int or not 0 < entry["size"] <= 256 * 1024 * 1024):
            raise ValueError("Compiler profile has an invalid or repeated code record")
        entries[entry["filename"]] = entry
    if set(entries) != set(COMPILER_FILES) or sum(e["size"] for e in entries.values()) > 256 * 1024 * 1024:
        raise ValueError("Compiler profile must contain the complete bounded six-library and worker set")
    if len({entry["cdhash"] for entry in entries.values()}) != len(COMPILER_FILES):
        raise ValueError("Compiler profile must identify seven distinct signed code files")
    contents = {}
    for name in COMPILER_FILES:
        path, entry = source / name, entries[name]
        value = path.lstat()
        if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_size != entry["size"]:
            raise ValueError(f"Compiler code must be an independent regular file matching its profile: {path}")
        data = path.read_bytes()
        if len(data) != entry["size"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError(f"Compiler code hash differs from its profile: {path}")
        compiler_platform(path)
        for dependency in dylib_dependencies(path):
            if dependency.startswith("@loader_path/"):
                if dependency.removeprefix("@loader_path/") not in COMPILER_FILES[:-1]:
                    raise ValueError(f"Compiler has an unpackaged private dependency: {dependency}")
            elif not dependency.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
                raise ValueError(f"Compiler dependency is outside its private or system runtime: {dependency}")
        contents[name] = data
    if destination.is_symlink():
        raise ValueError("Compiler staging directory must not be a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    destination.chmod(0o755)
    allowed = set(COMPILER_FILES) | {"compiler-profile.json", "work"}
    if any(path.name not in allowed for path in destination.iterdir()):
        raise ValueError("Compiler staging directory contains unlisted stale files")
    work = destination / "work"
    if work.is_symlink() or (work.exists() and (not work.is_dir() or any(work.iterdir()))):
        raise ValueError("Compiler work staging directory must be empty and regular")
    work.mkdir(exist_ok=True)
    work.chmod(0o700)
    staged = {}
    for name in (*COMPILER_FILES, "compiler-profile.json"):
        path = destination / name
        if path.is_symlink() or (path.exists() and (not path.is_file() or path.stat().st_nlink != 1)):
            raise ValueError(f"Compiler staging file must be an independent regular file: {path}")
        path.write_bytes(raw_profile if name == "compiler-profile.json" else contents[name])
        path.chmod(0o644 if name == "compiler-profile.json" else 0o755)
        if name in entries:
            staged[path] = entries[name]
    return staged, destination / "compiler-profile.json", work, profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original-payload", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--gpu-task", required=True, type=Path,
                        help="Converted matching macOS 27 task directory with executable and Info.plist")
    parser.add_argument("--probes", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--release-version", default="2.0.0",
                        help="CFBundleShortVersionString for this separate app")
    parser.add_argument("--build-number", default="20001",
                        help="Numeric CFBundleVersion for this separate app")
    parser.add_argument("--prebuilt-vmm", type=Path,
                        help="Preserve an already verified VMM's exact bytes and signature")
    parser.add_argument("--preserve-app-signature", action="store_true",
                        help="Validate an already configured 2.0 app without changing Info.plist or signing")
    parser.add_argument("--shader-cache", type=Path,
                        help="Optional AIR 2.5 data directory with hash-pinned Apple verifier records")
    parser.add_argument("--compiler-runtime", type=Path,
                        help="Optional private directory containing compiler-profile.json, six VM27 dylibs, and metal-library-convert")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+-]*", args.release_version):
        parser.error("release version must be a safe version string")
    if not re.fullmatch(r"[0-9]+", args.build_number):
        parser.error("build number must be numeric")
    app_settings = dict(APP_SETTINGS, CFBundleShortVersionString=args.release_version,
                        CFBundleVersion=args.build_number)
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    stage = output / "stage"
    framework = stage / "payload/Frameworks"
    framework.mkdir(parents=True, exist_ok=True)
    files, metadata_files, links = [], [], []
    compiler_files, compiler_profile, compiler_work, compiler_info = {}, None, None, None
    if args.compiler_runtime:
        compiler_files, compiler_profile, compiler_work, compiler_info = stage_compiler_runtime(
            args.compiler_runtime, stage / "compiler27")
        files.extend(compiler_files)
        metadata_files.append(compiler_profile)
    cache_files = []
    if args.shader_cache:
        cache_files = stage_shader_cache(args.shader_cache, stage / "shader-cache/air25")

    def copy(source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o755)
        files.append(destination)

    def relative_link(destination, target):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            if destination.is_dir() and not destination.is_symlink():
                raise ValueError(f"Refusing to replace a directory with a framework link: {destination}")
            destination.unlink()
        destination.symlink_to(target)
        links.append(destination)

    task_info = plistlib.loads((args.gpu_task / "Info.plist").read_bytes())
    if (task_info.get("CFBundleExecutable") != TASK_NAME or
        task_info.get("CFBundleIdentifier") != TASK_NAME or
        task_info.get("CFBundleSupportedPlatforms") not in (["MacOSX"], ["iPhoneOS"]) or
        str(task_info.get("DTPlatformVersion", "")).split(".")[0] != "27"):
        raise ValueError("GPU task directory must contain the matching macOS 27 XPC Info.plist")
    source_task_metadata = task_info.get("CFBundleSupportedPlatforms") == ["MacOSX"]
    if not source_task_metadata and task_info.get("MinimumOSVersion") != "16.1":
        raise ValueError("Converted GPU task metadata must target iPadOS 16.1")

    for name in ("ParavirtualizedGraphics", "MetalSerializer"):
        copy(args.candidate / "ios" / name,
             framework / (name + ".framework") / "Versions/A" / name)
        root = framework / (name + ".framework")
        relative_link(root / "Versions/Current", "A")
        relative_link(root / name, "Versions/Current/" + name)
    metal = args.runtime / "MetalCompat.dylib"
    copy(metal if metal.is_file() else args.candidate / "ios/MetalCompat.dylib",
         framework / "MetalCompat.dylib")
    for name in ("ModernRuntimeCompat.dylib", "LaunchServicesCompat.dylib", "ModernGPUTaskCompat.dylib"):
        copy(args.runtime / name, framework / name)
    exported = run("nm", "-gU", str(framework / "LaunchServicesCompat.dylib"),
                   capture_output=True, text=True).stdout
    if not re.search(r"\b_VZModernInstallTaskTransport$", exported, re.M):
        raise ValueError("LaunchServicesCompat must define VZModernInstallTaskTransport")
    task_contents = (framework / "ParavirtualizedGraphics.framework/Versions/A/XPCServices" /
                     (TASK_NAME + ".xpc") / "Contents")
    copy(args.gpu_task / TASK_NAME, task_contents / "MacOS" / TASK_NAME)
    required_task_library = "/var/root/VirtualMac2/payload/Frameworks/ModernGPUTaskCompat.dylib"
    if required_task_library not in dylib_dependencies(task_contents / "MacOS" / TASK_NAME):
        raise ValueError("GPU task must load ModernGPUTaskCompat from the isolated 2.0 runtime")
    task_metadata = task_contents / "Info.plist"
    if source_task_metadata:
        task_info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        task_info["MinimumOSVersion"] = "16.1"
        task_info.pop("LSMinimumSystemVersion", None)
        task_metadata.write_bytes(plistlib.dumps(task_info))
    else:
        shutil.copyfile(args.gpu_task / "Info.plist", task_metadata)
    task_metadata.chmod(0o644)
    metadata_files.append(task_metadata)
    for name in ("modern-pvg-smoke", "pvg-backend-contract"):
        copy(args.probes / name, stage / "testing" / name)

    relative = Path("VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine")
    original_vmm = args.prebuilt_vmm or args.original_payload / relative
    vmm = stage / "payload" / relative
    copy(original_vmm, vmm)
    if args.prebuilt_vmm:
        missing = set(VMM_DEPENDENCIES) - set(dylib_dependencies(vmm))
        if missing:
            raise ValueError(f"Prebuilt VMM is missing required modern dependencies: {sorted(missing)}")
    else:
        for dependency in VMM_DEPENDENCIES:
            run("python3", str(repo / "vz/patches/add_macho_dylib.py"), str(vmm), dependency)
        entitlements = output / "vmm-original-entitlements.plist"
        with entitlements.open("wb") as handle:
            run("ldid", "-e", str(original_vmm), stdout=handle)
        run("codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(vmm))

    app = args.app.resolve()
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if args.preserve_app_signature:
        different = {key: info.get(key) for key, expected in app_settings.items()
                     if key not in ("CFBundleName", "CFBundleDisplayName") and info.get(key) != expected}
        if different:
            raise ValueError(f"Preserved app is not configured for the isolated 2.0 runtime: {different}")
        if info.get("CFBundleExecutable") != "VirtualMac":
            raise ValueError("Preserved app must use the VirtualMac executable")
        url_types = info.get("CFBundleURLTypes", [])
        if (not url_types or any(entry.get("CFBundleURLName") != "com.mac.virtual.v2" or
                                entry.get("CFBundleURLSchemes") != ["virtualmac2"]
                                for entry in url_types)):
            raise ValueError("Preserved app must use its isolated virtualmac2 URL scheme")
        signature = run("codesign", "-d", "--verbose=4", str(app / "VirtualMac"),
                        capture_output=True, text=True)
        if not re.search(r"^Identifier=com\.mac\.virtual\.v2$",
                         signature.stdout + signature.stderr, re.M):
            raise ValueError("Preserved app executable must have the com.mac.virtual.v2 signing identifier")
    else:
        info.update(app_settings)
        for entry in info.get("CFBundleURLTypes", []):
            entry["CFBundleURLName"] = "com.mac.virtual.v2"
            entry["CFBundleURLSchemes"] = ["virtualmac2"]
        info_path.write_bytes(plistlib.dumps(info))
    # Extended attributes are not executable bytes. Remove checkout detritus
    # from both modes without changing an exact snapshot's Mach-O signatures.
    run("xattr", "-cr", str(app))
    if not args.preserve_app_signature:
        host_entitlements = str(repo / "vz/host/VirtualMac.entitlements")
        # Sign outside a FileProvider-managed checkout so FinderInfo cannot
        # race the signature operation. Only signing outputs change in the app.
        with tempfile.TemporaryDirectory(prefix="virtualmac2-app-signing-",
                                         dir="/private/tmp") as directory:
            signing_app = clean_bundle_copy(app, directory)
            run("codesign", "--force", "--sign", "-", "--entitlements", host_entitlements,
                str(signing_app / "VZHostCompat.dylib"))
            run("codesign", "--force", "--sign", "-", "--entitlements", host_entitlements,
                "--identifier", "com.mac.virtual.v2", str(signing_app))
            for name in ("VirtualMac", "VZHostCompat.dylib"):
                shutil.copyfile(signing_app / name, app / name)
            resources = app / "_CodeSignature"
            if resources.exists():
                shutil.rmtree(resources)
            shutil.copytree(signing_app / "_CodeSignature", resources,
                            copy_function=shutil.copyfile)
    metadata_files.append(info_path)
    metadata_files.extend(cache_files)
    stage_files = list(files)
    files.extend([app / "VirtualMac", app / "VZHostCompat.dylib"])

    hashes, manifest = [], []
    for file in files:
        result = run("codesign", "-d", "--verbose=4", str(file),
                     capture_output=True, text=True)
        signature_description = result.stdout + result.stderr
        # Device snapshots may contain a separately signed main executable;
        # codesign infers a bundle even from an executable path inside an XPC.
        # Verify identical bytes in a standalone context, independently from
        # the metadata checks, without changing their deployed code signature.
        if file == app / "VirtualMac" and "Info.plist entries=" in signature_description:
            # A normal whole-app signature binds Info.plist and resources, so
            # retain that bundle context when checking the seals. FileProvider
            # may reattach FinderInfo immediately after xattr removal in a
            # synced checkout; verify a byte-identical, clean temporary bundle.
            with tempfile.TemporaryDirectory(prefix="virtualmac2-app-verification-",
                                             dir="/private/tmp") as directory:
                isolated_app = clean_bundle_copy(app, directory)
                if (isolated_app / file.name).read_bytes() != file.read_bytes():
                    raise ValueError(f"Signature validation copy differs from {file}")
                run("codesign", "--verify", "--strict", str(isolated_app))
        else:
            with tempfile.TemporaryDirectory(prefix="code-verification-", dir=output) as directory:
                isolated = Path(directory) / file.name
                shutil.copyfile(file, isolated)
                if isolated.read_bytes() != file.read_bytes():
                    raise ValueError(f"Signature validation copy differs from {file}")
                run("codesign", "--verify", "--strict", str(isolated))
        run("dyld_info", "-validate_only", str(file), stdout=subprocess.DEVNULL)
        match = re.search(r"^CDHash=([0-9a-f]{40})$", signature_description, re.M)
        if not match:
            raise ValueError(f"Missing code-directory hash for {file}")
        cdhash = match.group(1)
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        expected = compiler_files.get(file)
        if expected and (cdhash != expected["cdhash"] or digest != expected["sha256"] or
                         file.stat().st_size != expected["size"]):
            raise ValueError(f"Signed staged compiler code differs from its profile: {file}")
        hashes.append(cdhash)
        manifest.append(dict(path=str(file), cdhash=cdhash,
                             sha256=digest))
    if compiler_profile and len(hashes) != len(set(hashes)):
        raise ValueError("Private compiler deployment must have a distinct trust hash for each code file")
    (stage / "trustcache.txt").write_text("\n".join(hashes) + "\n")
    with tarfile.open(output / "deploy-stage.tar", "w") as archive:
        # Explicit paths prevent stale or native-Mac test binaries entering the
        # device's deployment or trust scope when an output directory is reused.
        if compiler_profile:
            archive.add(stage / "compiler27", arcname="compiler27", recursive=False,
                        filter=compiler_member)
            archive.add(compiler_work, arcname="compiler27/work", recursive=False,
                        filter=mobile_cache_member)
        if cache_files:
            for directory in (stage / "shader-cache", stage / "shader-cache/air25"):
                archive.add(directory, arcname=str(directory.relative_to(stage)),
                            recursive=False, filter=mobile_cache_member)
        for file in stage_files + [file for file in metadata_files if stage in file.parents] + links:
            archive.add(file, arcname=str(file.relative_to(stage)), recursive=False,
                        filter=(compiler_member if file in compiler_files or file == compiler_profile
                                else mobile_cache_member if file in cache_files else None))
        archive.add(stage / "trustcache.txt", arcname="trustcache.txt")
    with tarfile.open(output / "app2.tar", "w") as archive:
        archive.add(app, arcname="VirtualMac2.app")
    deployment = dict(
        bundle_id="com.mac.virtual.v2", version=args.release_version,
        build_number=args.build_number, runtime="/var/root/VirtualMac2",
        backend="macOS 27 PVG, MetalSerializer, and GPU task; original Ventura VMM",
        preserved_vmm=bool(args.prebuilt_vmm), preserved_app_signature=args.preserve_app_signature,
        shader_cache_entries=len(cache_files) - 1 if cache_files else 0,
        shader_cache_owner="mobile:mobile (501:501)" if cache_files else None,
        files=manifest,
        metadata=[dict(path=str(file), sha256=hashlib.sha256(file.read_bytes()).hexdigest())
                  for file in metadata_files],
        symlinks=[dict(path=str(link), target=str(link.readlink())) for link in links])
    if compiler_profile:
        deployment["compiler_runtime"] = dict(
            profile=compiler_info["profile"], source=compiler_info["source"],
            directory="compiler27", profile_path="compiler27/compiler-profile.json",
            profile_sha256=hashlib.sha256(compiler_profile.read_bytes()).hexdigest(),
            code_files=len(compiler_files), libraries=6, worker="metal-library-convert",
            owner="root:wheel (0:0)", code_mode="0755", profile_mode="0644",
            work_directory="compiler27/work", work_owner="mobile:mobile (501:501)",
            work_mode="0700")
        deployment["directories"] = [
            dict(path="compiler27", uid=0, gid=0, mode="0755"),
            dict(path="compiler27/work", uid=501, gid=501, mode="0700"),
        ]
    (output / "deployment-manifest.json").write_text(json.dumps(deployment, indent=2) + "\n")
    print(f"Packaged {len(files)} verified binaries at {output}")


if __name__ == "__main__":
    main()
