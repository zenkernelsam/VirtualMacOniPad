#!/usr/bin/env python3
"""Compile the actual network header with fixture getifaddrs, never real NICs."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires Darwin sockaddr and Foundation")
class NetworkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="virtualmac-sep-network-test-")
        cls.binary = Path(cls.temporary.name) / "network-test"
        result = subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
            "-framework", "Foundation", str(Path(__file__).with_name("sepbridge-network-test.m")),
            "-o", str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("network fixture compilation failed: " + result.stderr[:800])

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_fixture(self, mode):
        result = subprocess.run([str(self.binary), mode], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rfc1918_boundaries(self): self.run_fixture("private")
    def test_interface_name_up_and_loopback_rules(self): self.run_fixture("interfaces")
    def test_host_addresses_exclude_public_down_tunnel_ipv6_and_duplicates(self): self.run_fixture("hosts")
    def test_current_guest_wifi_68_59_22_selects_ipad_68_66(self): self.run_fixture("wifi")
    def test_guest_64_2_24_selects_ipad_nat_64_1(self): self.run_fixture("nat")
    def test_bad_candidate_lists_and_addresses_rejected(self): self.run_fixture("candidates")
    def test_down_disallowed_loopback_and_ipv6_cannot_steal_preference(self): self.run_fixture("down")
    def test_incomplete_dhcp_mask_cannot_steal_preference(self): self.run_fixture("incomplete-mask")


if __name__ == "__main__":
    unittest.main()
