#!/usr/bin/env python3
"""Exercise native client against fixture-only authenticated loopback servers."""
import os
from pathlib import Path
import plistlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

SOURCE = Path(__file__).with_name("independent-identity-client-test.m")


def fixture_payload(**changes):
    return {"independentEnabled": True, "anisetteArchive": b"archive-fixture",
            "nativeHeaders": {"fixture": "only"}, **changes}


@unittest.skipUnless(sys.platform == "darwin", "requires Foundation and Darwin sockets")
class ClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="virtualmac-identity-client-test-")
        cls.binary = Path(cls.temporary.name) / "client-test"
        build = subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks",
                                "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                                str(SOURCE), "-o", str(cls.binary)], capture_output=True, text=True)
        if build.returncode:
            raise RuntimeError("client fixture compilation failed: " + build.stderr[:500])

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def fetch(self, frame, success=False, fragmented=False, wrong_token=False):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            server.settimeout(5)
            token = os.urandom(32)
            errors = []
            def respond():
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(5)
                        request = bytearray()
                        while len(request) < 33:
                            part = connection.recv(33 - len(request))
                            if not part:
                                errors.append("short authenticated request")
                                return
                            request.extend(part)
                        if wrong_token:
                            if request[:32] == token:
                                errors.append("wrong-token fixture unexpectedly matched")
                            return
                        if request[:32] != token or request[32] != ord("P"):
                            errors.append("authenticated request mismatch")
                            return
                        if fragmented:
                            for offset in range(0, len(frame), 3):
                                connection.sendall(frame[offset:offset + 3])
                        else:
                            connection.sendall(frame)
                except Exception:
                    errors.append("fixture server I/O failed")
            thread = threading.Thread(target=respond, daemon=True)
            thread.start()
            environment = dict(os.environ,
                VM_INDEPENDENT_IDENTITY_PORT=str(server.getsockname()[1]),
                VM_INDEPENDENT_IDENTITY_TOKEN=(os.urandom(32) if wrong_token else token).hex())
            result = subprocess.run([str(self.binary), "fetch", "success" if success else "failure"],
                                    env=environment, capture_output=True, text=True, timeout=12)
            thread.join(6)
            self.assertFalse(thread.is_alive(), "fixture server did not finish")
            self.assertFalse(errors, "; ".join(errors))
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_valid_fragmented_binary_payload(self):
        payload = plistlib.dumps(fixture_payload(), fmt=plistlib.FMT_BINARY)
        self.fetch(struct.pack(">I", len(payload)) + payload, success=True, fragmented=True)

    def test_zero_or_oversized_frame_rejected(self):
        for length in (0, 65537):
            with self.subTest(length=length):
                self.fetch(struct.pack(">I", length))

    def test_truncated_prefix_or_body_rejected(self):
        for frame in (b"\0\0", struct.pack(">I", 10) + b"short"):
            with self.subTest(kind="truncated-frame"):
                self.fetch(frame)

    def test_invalid_plist_rejected(self):
        payload = b"not-a-plist-fixture"
        self.fetch(struct.pack(">I", len(payload)) + payload)

    def test_disabled_or_wrong_payload_field_types_rejected(self):
        fixtures = [[], fixture_payload(independentEnabled=False),
                    fixture_payload(independentEnabled="1"),
                    fixture_payload(anisetteArchive="wrong-type"),
                    fixture_payload(nativeHeaders=[])]
        for index, value in enumerate(fixtures):
            with self.subTest(fixture=index):
                payload = plistlib.dumps(value)
                self.fetch(struct.pack(">I", len(payload)) + payload)

    def test_provider_refusal_for_wrong_token_fails_closed(self):
        self.fetch(b"", wrong_token=True)

    def test_invalid_client_environment_fails_without_provider(self):
        for changes in ({"VM_INDEPENDENT_IDENTITY_PORT": "65536"},
                        {"VM_INDEPENDENT_IDENTITY_PORT": "1234suffix"},
                        {"VM_INDEPENDENT_IDENTITY_TOKEN": "z" * 64},
                        {"VM_INDEPENDENT_IDENTITY_TOKEN": "0" * 63}):
            with self.subTest(kind="invalid-client-environment"):
                environment = dict(os.environ, VM_INDEPENDENT_IDENTITY_PORT="1234",
                                   VM_INDEPENDENT_IDENTITY_TOKEN="0" * 64)
                environment.update(changes)
                result = subprocess.run([str(self.binary), "fetch", "failure"], env=environment,
                                        capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_header_replacement_preserves_original_request_fields(self):
        result = subprocess.run([str(self.binary), "merge"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
