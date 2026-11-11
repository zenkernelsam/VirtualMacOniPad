#!/usr/bin/env python3
"""Offline regressions for DHCP coexistence; never accesses host services."""
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[2] / "packaging/rootless/bootpd-hotspot-merge.py"
spec = importlib.util.spec_from_file_location("hotspot_merge", SOURCE)
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)
ARRAYS = ("dhcp_enabled", "detect_other_dhcp_server", "ignore_allow_deny")


def subnet(interface, creator, network="192.168.64.0"):
    # The two creators and addresses are taken from the 2026-10-09 snapshots.
    hotspot = creator != "com.apple.NetworkSharing"
    return {"_creator": creator, "interface": interface, "allocate": True,
            "net_address": network,
            "net_mask": "255.255.255.240" if hotspot else "255.255.255.0",
            "dhcp_router": "172.20.10.1" if hotspot else "192.168.64.1",
            "net_range": ["172.20.10.2", "172.20.10.14"] if hotspot
                         else ["192.168.64.2", "192.168.64.254"]}


def config(*subnets):
    interfaces = list(dict.fromkeys(item["interface"] for item in subnets))
    return {"Subnets": list(subnets), "bootp_enabled": False,
            **{key: interfaces[:] for key in ARRAYS}}


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="virtualmac-hotspot-test-")
        self.addCleanup(self.temporary.cleanup)
        self.runtime = Path(self.temporary.name) / "runtime.plist"
        self.stock = Path(self.temporary.name) / "stock.plist"
        for key, value in (("CONFIG", str(self.runtime)), ("STOCK_CONFIG", str(self.stock))):
            patcher = mock.patch.object(watcher, key, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.blocks = mock.patch.object(watcher, "interface_blocks", return_value={}).start()
        self.addCleanup(mock.patch.stopall)
        self.vm = subnet("bridge100", "com.apple.NetworkSharing")
        self.hotspot = subnet("bridge101", "com.apple.MobileInternetSharing", "172.20.10.0")
        self.managed = {**self.hotspot, "_creator": watcher.CREATOR}

    def write(self, data, path=None, fmt=plistlib.FMT_XML):
        (path or self.runtime).write_bytes(plistlib.dumps(data, fmt=fmt))

    def read(self):
        return plistlib.loads(self.runtime.read_bytes())

    def activate(self, hotspot=None, description=True):
        hotspot = hotspot or self.hotspot
        self.write(config(hotspot), self.stock)
        self.blocks.return_value = {
            hotspot["interface"]: [hotspot["interface"] + ": flags=UP",
                                   "\tdesc: com.apple.MobileInternetSharing" if description
                                   else "\tmember: ap1 flags=UP"],
        }

    def test_dynamic_bridge_and_stock_options_are_copied(self):
        hotspot = {**self.hotspot, "interface": "bridge42", "lease_max": 3600,
                   "net_address": "10.7.8.0", "net_mask": "255.255.255.0",
                   "net_range": ["10.7.8.2", "10.7.8.200"], "dhcp_router": "10.7.8.1"}
        self.activate(hotspot, description=False)
        self.write(config(self.vm))
        watcher.merge()
        result = self.read()
        self.assertEqual(result["Subnets"], [self.vm, {**hotspot, "_creator": watcher.CREATOR}])
        for key in ARRAYS:
            self.assertEqual(result[key], ["bridge100", "bridge42"])

    def test_cleanup_preserves_bridge_reused_by_vm(self):
        old_hotspot = {**self.managed, "interface": self.vm["interface"]}
        self.write(config(self.vm, old_hotspot))
        watcher.merge()
        result = self.read()
        self.assertEqual(result["Subnets"], [self.vm])
        for key in ARRAYS:
            self.assertEqual(result[key], [self.vm["interface"]])

    def test_cleanup_only_removes_managed_subnet_and_unused_interface(self):
        external = {**self.hotspot, "interface": "bridge99"}
        self.write(config(self.vm, self.managed, external))
        watcher.merge()
        result = self.read()
        self.assertEqual(result["Subnets"], [self.vm, external])
        for key in ARRAYS:
            self.assertEqual(result[key], ["bridge100", "bridge99"])

    def test_vm_rewrite_then_merge_recovers_both_networks_and_converges(self):
        self.activate()
        self.write(config(self.vm))
        watcher.merge()
        replacement_vm = {**self.vm, "interface": "bridge7", "lease_max": 1800}
        self.write(config(replacement_vm))  # InternetSharing replaces the file.
        watcher.merge()
        self.assertEqual(self.read()["Subnets"], [replacement_vm, self.managed])
        before = self.runtime.read_bytes(), self.runtime.stat().st_mtime_ns
        watcher.merge()
        self.assertEqual((self.runtime.read_bytes(), self.runtime.stat().st_mtime_ns), before)

    def test_missing_runtime_without_hotspot_does_not_create_configuration(self):
        watcher.merge()
        self.assertFalse(self.runtime.exists())

    def test_missing_runtime_with_hotspot_creates_only_hotspot(self):
        self.activate()
        watcher.merge()
        self.assertEqual(self.read()["Subnets"], [self.managed])

    def test_partial_runtime_write_is_preserved_until_valid(self):
        self.activate()
        partial = b"<?xml version='1.0'?><plist><dict><key>Subnets</key>"
        self.runtime.write_bytes(partial)
        watcher.merge()
        self.assertEqual(self.runtime.read_bytes(), partial)
        self.write(config(self.vm))
        watcher.merge()
        self.assertEqual(self.read()["Subnets"], [self.vm, self.managed])

    def test_partial_stock_write_does_not_disable_existing_hotspot(self):
        initial = config(self.vm, self.managed)
        self.write(initial)
        before = self.runtime.read_bytes()
        self.stock.write_bytes(b"<plist><dict>")
        watcher.merge()
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_no_change_preserves_original_binary_plist_and_mtime(self):
        self.write(config(self.vm), fmt=plistlib.FMT_BINARY)
        before = self.runtime.read_bytes(), self.runtime.stat().st_mtime_ns
        watcher.merge()
        self.assertEqual((self.runtime.read_bytes(), self.runtime.stat().st_mtime_ns), before)

    def test_concurrent_vm_rewrite_is_not_overwritten(self):
        self.activate()
        self.write(config(self.vm))
        replacement = config({**self.vm, "interface": "bridge7", "lease_max": 1800})
        replacement_bytes = plistlib.dumps(replacement)
        serialize = plistlib.dumps
        def write_during_merge(*args, **kwargs):
            self.runtime.write_bytes(replacement_bytes)
            return serialize(*args, **kwargs)
        with mock.patch.object(watcher.plistlib, "dumps", side_effect=write_during_merge):
            watcher.merge()
        self.assertEqual(self.runtime.read_bytes(), replacement_bytes)
        watcher.merge()
        self.assertEqual(self.read()["Subnets"], [replacement["Subnets"][0], self.managed])

    def test_vmenet_bridge_is_not_classified_as_hotspot(self):
        self.write(config(self.hotspot), self.stock)
        self.blocks.return_value = {"bridge101": ["bridge101: flags=UP",
                                                 "\tdesc: com.apple.NetworkSharing",
                                                 "\tmember: vmenet0 flags=UP"]}
        self.assertEqual(watcher.hotspot_config(), (None, None))

    def test_dynamic_hotspot_interface_switch_keeps_vm(self):
        self.write(config(self.vm, self.managed))
        new_hotspot = {**self.hotspot, "interface": "bridge7"}
        self.activate(new_hotspot)
        watcher.merge()
        result = self.read()
        self.assertEqual(result["Subnets"], [self.vm, {**new_hotspot, "_creator": watcher.CREATOR}])
        for key in ARRAYS:
            self.assertEqual(result[key], ["bridge100", "bridge7"])

    def test_unknown_runtime_array_types_are_preserved(self):
        self.activate()
        for value in (True, [{"interface": "bridge100"}]):
            with self.subTest(value=value):
                self.write({**config(self.vm), "dhcp_enabled": value})
                before = self.runtime.read_bytes()
                watcher.merge()
                self.assertEqual(self.runtime.read_bytes(), before)

    def test_failed_interface_query_preserves_existing_dhcp(self):
        self.activate()
        self.write(config(self.vm, self.managed))
        before = self.runtime.read_bytes()
        self.blocks.side_effect = watcher.SnapshotUnavailable("interface query unavailable")
        watcher.merge()
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_unrelated_interface_name_does_not_match_ap_member(self):
        self.write(config(self.hotspot), self.stock)
        self.blocks.return_value = {"bridge101": ["bridge101: flags=UP",
                                                 "\tmember: apple0 flags=UP"]}
        self.assertEqual(watcher.hotspot_config(), (None, None))


if __name__ == "__main__":
    unittest.main()
