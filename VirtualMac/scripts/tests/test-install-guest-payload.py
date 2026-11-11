#!/usr/bin/env python3
"""Real signed-code transaction tests, entirely below a temporary directory."""
import ctypes
import hashlib
import mmap
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[2] / "vz/guest/install-guest-payload.sh"
LIBRARIES = ("OpenGLPVGCompat.dylib", "AppleAccountSignInCompat.dylib", "SEPBridgeCompat.dylib")


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError("fixture command failed: " + result.stderr[:400])
    return result


def sign(path):
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)])
    run(["/usr/bin/codesign", "--verify", "--strict", str(path)])


def corrupt_text(path):
    image = bytearray(path.read_bytes())
    if struct.unpack_from("<I", image)[0] != 0xFEEDFACF:
        raise RuntimeError("fixture is not a thin Mach-O 64-bit image")
    commands = struct.unpack_from("<I", image, 16)[0]
    offset = 32
    for _ in range(commands):
        command, length = struct.unpack_from("<II", image, offset)
        if command == 0x19:  # LC_SEGMENT_64
            count = struct.unpack_from("<I", image, offset + 64)[0]
            for index in range(count):
                section = offset + 72 + index * 80
                if image[section:section + 16].rstrip(b"\0") == b"__text":
                    text_offset = struct.unpack_from("<I", image, section + 48)[0]
                    image[text_offset] ^= 1
                    path.write_bytes(image)
                    return
        offset += length
    raise RuntimeError("fixture has no executable text section")


def snapshot(root):
    return {str(path.relative_to(root)): (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_ino,
                                         path.stat().st_mode)
            for path in root.rglob("*") if path.is_file()}


@unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign and dyld")
class InstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix="virtualmac-signed-fixtures-")
        cls.root = Path(cls.fixtures.name)
        cls.payloads = []
        for version in (21, 42):
            payload = cls.root / ("payload-" + str(version))
            payload.mkdir()
            source = cls.root / ("fixture-" + str(version) + ".c")
            source.write_text("int fixture_value(void) { return " + str(version)
                              + "; }\nint main(void) { return 0; }\n")
            library = payload / LIBRARIES[0]
            run(["/usr/bin/xcrun", "clang", "-dynamiclib", "-O0", str(source),
                 "-Wl,-install_name,@rpath/fixture-" + str(version) + ".dylib",
                 "-o", str(library)])
            sign(library)
            for name in LIBRARIES[1:]:
                shutil.copy2(library, payload / name)
            provider = payload / "independent-identity-provider"
            run(["/usr/bin/xcrun", "clang", str(source), "-o", str(provider)])
            sign(provider)
            app = payload / "Virtual Mac Guest Tools.app"
            executable = app / "Contents/MacOS/FixtureGuestTools"
            executable.parent.mkdir(parents=True)
            shutil.copy2(provider, executable)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.example.virtualmac.transaction-fixture",
                "CFBundleExecutable": "FixtureGuestTools", "CFBundlePackageType": "APPL",
                "CFBundleVersion": str(version)}))
            sign(app)
            shutil.copy2(INSTALLER, payload / INSTALLER.name)
            (payload / "apply-sep-bridge.sh").write_text("#!/bin/sh\n# fixture " + str(version) + "\nexit 0\n")
            cls.payloads.append(payload)

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="virtualmac-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "Library/VirtualMac"
        self.payload = self.root / "incoming"
        shutil.copytree(self.payloads[0], self.destination)
        shutil.copytree(self.payloads[1], self.payload)
        (self.destination / ".build").write_text("old-build-fixture\n")
        (self.destination / "unrelated-user-data").write_text("preserve-fixture\n")

    def install(self, env=None):
        return subprocess.run(["/bin/sh", str(INSTALLER), str(self.payload), str(self.destination)],
                              env=env, capture_output=True, text=True)

    def rollback_path(self):
        candidates = list((self.root / "Library").glob(".VirtualMac-install.*/rollback.sh"))
        self.assertEqual(len(candidates), 1)
        return candidates[0]

    def test_upgrade_changes_inode_and_keeps_old_mapping_and_code(self):
        library = self.destination / LIBRARIES[0]
        old_handle = ctypes.CDLL(str(library))
        old_handle.fixture_value.restype = ctypes.c_int
        self.assertEqual(old_handle.fixture_value(), 21)
        with library.open("rb") as file:
            with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as mapping:
                old_bytes = mapping[:]
                old_inode = library.stat().st_ino
                result = self.install()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(library.stat().st_ino, old_inode)
                self.assertEqual(mapping[:], old_bytes)
                self.assertEqual(old_handle.fixture_value(), 21)
                # A fresh process avoids dyld reusing the existing dlopen handle.
                child = run([sys.executable, "-c",
                             "import ctypes,sys; d=ctypes.CDLL(sys.argv[1]); "
                             "d.fixture_value.restype=ctypes.c_int; print(d.fixture_value())",
                             str(library)])
                self.assertEqual(child.stdout.strip(), "42")
        self.assertEqual((self.destination / ".build").read_text(), "old-build-fixture\n")

    def test_bad_staging_signature_preserves_every_old_target_and_marker(self):
        before = snapshot(self.destination)
        corrupt_text(self.payload / LIBRARIES[-1])
        invalid = subprocess.run(["/usr/bin/codesign", "--verify", "--strict",
                                  str(self.payload / LIBRARIES[-1])], capture_output=True)
        self.assertNotEqual(invalid.returncode, 0)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.destination), before)

    def test_explicit_rollback_restores_old_files_and_can_be_repeated(self):
        before = snapshot(self.destination)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        rollback = self.rollback_path()
        # The default target is the directory recorded by this transaction,
        # so a temporary install's rollback never defaults to real /Library.
        for arguments in ([], [str(self.destination)]):
            restored = subprocess.run(["/bin/sh", str(rollback), *arguments],
                                      capture_output=True, text=True)
            self.assertEqual(restored.returncode, 0, restored.stderr)
            self.assertEqual(snapshot(self.destination), before)

    def test_mid_commit_failure_restores_old_targets_and_removes_new_targets(self):
        # Simulate an older installation that did not ship the new provider.
        (self.destination / "independent-identity-provider").rename(self.root / "omitted-old-provider")
        before = snapshot(self.destination)
        tools = self.root / "tools"
        tools.mkdir()
        wrapper = tools / "mv"
        wrapper.write_text("#!/bin/sh\ncase \"$1\" in\n"
                           "  */stage/apply-sep-bridge.sh) exit 73 ;;\n"
                           "esac\nexec /bin/mv \"$@\"\n")
        wrapper.chmod(0o755)
        environment = dict(os.environ, PATH=str(tools) + ":" + os.environ.get("PATH", "/usr/bin:/bin"))
        result = self.install(env=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(self.destination), before)
        rollback = subprocess.run(["/bin/sh", str(self.rollback_path()), str(self.destination)],
                                  capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertEqual(snapshot(self.destination), before)


if __name__ == "__main__":
    unittest.main()
