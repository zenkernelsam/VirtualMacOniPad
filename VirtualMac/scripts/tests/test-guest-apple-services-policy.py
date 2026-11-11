#!/usr/bin/env python3
"""Run actual Guest Tools config/menu methods without UI or user preferences."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit headers")
class GuestPolicyTests(unittest.TestCase):
    def test_new_ready_token_initializes_but_menu_or_relaunch_preserves_user_choice(self):
        with tempfile.TemporaryDirectory(prefix="virtualmac-guest-policy-build-") as temporary:
            binary = Path(temporary) / "policy-test"
            build = subprocess.run(["/usr/bin/xcrun", "clang", "-fno-objc-arc", "-fblocks",
                "-Wall", "-Wextra", "-Werror", "-framework", "AppKit",
                str(Path(__file__).with_name("guest-apple-services-policy-test.m")), "-o", str(binary)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS real Guest Tools", result.stdout)


if __name__ == "__main__":
    unittest.main()
