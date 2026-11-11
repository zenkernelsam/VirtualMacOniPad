#!/var/jb/usr/bin/python3
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time

CONFIG = "/tmp/bootpd.plist"
CREATOR = "vzi-hotspot-compat"
STOCK_CONFIG = "/Library/Preferences/SystemConfiguration/bootpd.plist"
INTERFACE_ARRAYS = ("dhcp_enabled", "detect_other_dhcp_server", "ignore_allow_deny")


class SnapshotUnavailable(Exception):
    """A writer or interface query is incomplete; retry without modifying DHCP."""


def config_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def decode_config(raw, source):
    try:
        data = plistlib.loads(raw)
    except Exception as error:
        raise SnapshotUnavailable(source + " plist incomplete") from error
    if not isinstance(data, dict) or not isinstance(data.get("Subnets", []), list):
        raise SnapshotUnavailable(source + " plist structure invalid")
    return data

def interface_blocks():
    try:
        ifconfig = "/var/jb/sbin/ifconfig"
        if not os.path.exists(ifconfig):
            ifconfig = "/sbin/ifconfig"
        out = subprocess.check_output([ifconfig, "-a"],
                                      stderr=subprocess.DEVNULL,
                                      timeout=3).decode(errors="replace")
    except (OSError, subprocess.SubprocessError) as error:
        raise SnapshotUnavailable("interface query unavailable") from error
    blocks = {}
    current = None
    for line in out.splitlines():
        if line and not line[0].isspace() and ":" in line:
            current = line.split(":", 1)[0]
            blocks[current] = []
        if current:
            blocks[current].append(line)
    return blocks

def hotspot_config():
    raw = config_bytes(STOCK_CONFIG)
    if raw is None:
        return None, None
    stock = decode_config(raw, "stock")
    subnets = stock.get("Subnets", [])
    if not subnets:
        return None, None
    blocks = interface_blocks()
    for subnet in subnets:
        if not isinstance(subnet, dict):
            continue
        interface = subnet.get("interface")
        if not isinstance(interface, str) or not interface:
            continue
        lines = blocks.get(interface, [])
        joined = "\n".join(lines)
        # Bridge indexes are assigned dynamically. The stock plist is written
        # by misd only for an active hotspot; use its subnet and identify the
        # corresponding interface by Apple's sharing description or AP member.
        # A vmenet bridge therefore cannot be mistaken for the hotspot.
        is_mobile_sharing = "desc: com.apple.MobileInternetSharing" in joined
        has_ap_member = any(re.match(r"member: ap\d+(?:\s|$)", line.strip())
                            for line in lines)
        if is_mobile_sharing or has_ap_member:
            result = dict(subnet)
            result["_creator"] = CREATOR
            return interface, result
    return None, None

def merge():
    try:
        interface, hotspot_subnet = hotspot_config()
        old_data = config_bytes(CONFIG)
        if old_data is None and not interface:
            return False
        data = decode_config(old_data, "runtime") if old_data is not None else {}
        for key in INTERFACE_ARRAYS:
            if key in data and (not isinstance(data[key], list) or
                                any(not isinstance(item, str) for item in data[key])):
                raise SnapshotUnavailable("runtime interface array invalid")
    except (OSError, SnapshotUnavailable) as error:
        print("bootpd-hotspot-merge: deferred: " + str(error), file=sys.stderr)
        return False
    merged = dict(data)
    old_subnets = data.get("Subnets", [])
    stale_interfaces = {x.get("interface") for x in old_subnets
                        if isinstance(x, dict) and
                        x.get("_creator") == CREATOR and
                        isinstance(x.get("interface"), str)}
    merged["Subnets"] = [x for x in old_subnets
                         if not (isinstance(x, dict) and
                                 x.get("_creator") == CREATOR)]
    # The old hotspot bridge may now belong to a VM. Removing its name from
    # dhcp_enabled would disable DHCP despite preserving the VM's subnet.
    retained_interfaces = {x.get("interface") for x in merged["Subnets"]
                           if isinstance(x, dict) and
                           isinstance(x.get("interface"), str)}
    removable_interfaces = stale_interfaces - retained_interfaces
    for key in INTERFACE_ARRAYS:
        values = [x for x in data.get(key, []) if x not in removable_interfaces]
        if interface and interface not in values:
            values.append(interface)
        if key in data or interface:
            merged[key] = values
    if interface and hotspot_subnet:
        merged["Subnets"].append(hotspot_subnet)
    if merged == data:
        return False
    new_data = plistlib.dumps(merged, fmt=plistlib.FMT_XML, sort_keys=False)
    directory = os.path.dirname(CONFIG) or "/tmp"
    fd, temporary = tempfile.mkstemp(prefix="bootpd.plist.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(new_data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temporary, 0o644)
        # InternetSharing may replace the file while this watcher prepares its
        # merge. Defer if the snapshot changed, then retry with its new VM data.
        if config_bytes(CONFIG) != old_data:
            return False
        os.replace(temporary, CONFIG)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return True

if __name__ == "__main__":
    # misd may write the stock plist just before creating/configuring the
    # bridge. Retry briefly so the first hotspot activation converges without
    # requiring a second toggle, while each merge remains byte-idempotent.
    for attempt in range(6):
        merge()
        if attempt != 5:
            time.sleep(1)
