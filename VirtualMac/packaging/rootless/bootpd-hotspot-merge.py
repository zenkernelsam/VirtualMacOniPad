#!/var/jb/usr/bin/python3
import copy
import os
import plistlib
import subprocess
import tempfile

CONFIG = "/tmp/bootpd.plist"
INTERFACE = "bridge101"
CREATOR = "vzi-hotspot-compat"

def hotspot_active():
    try:
        ifconfig = "/var/jb/sbin/ifconfig"
        if not os.path.exists(ifconfig):
            ifconfig = "/sbin/ifconfig"
        out = subprocess.check_output([ifconfig, INTERFACE],
                                      stderr=subprocess.DEVNULL).decode()
    except Exception:
        return False
    return "inet 172.20.10.1" in out

def subnet():
    return {
        "_creator": CREATOR,
        "allocate": True,
        "dhcp_domain_name_server": ["172.20.10.1"],
        "dhcp_router": "172.20.10.1",
        "interface": INTERFACE,
        "lease_max": 86400,
        "lease_min": 86400,
        "name": "172.20.10.1/28",
        "net_address": "172.20.10.0",
        "net_mask": "255.255.255.240",
        "net_range": ["172.20.10.2", "172.20.10.14"],
    }

def merge():
    active = hotspot_active()
    try:
        with open(CONFIG, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        data = {"Subnets": []}
    if not isinstance(data, dict):
        data = {"Subnets": []}
    data["Subnets"] = [x for x in data.get("Subnets", [])
                       if not (isinstance(x, dict) and
                               x.get("interface") == INTERFACE)]
    for key in ("dhcp_enabled", "detect_other_dhcp_server", "ignore_allow_deny"):
        data[key] = [x for x in data.get(key, []) if x != INTERFACE]
    if active:
        data["Subnets"].append(subnet())
        for key in ("dhcp_enabled", "detect_other_dhcp_server", "ignore_allow_deny"):
            data[key].append(INTERFACE)
    new_data = plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)
    old_data = None
    try:
        with open(CONFIG, "rb") as f:
            old_data = f.read()
    except OSError:
        pass
    if old_data == new_data:
        return
    directory = os.path.dirname(CONFIG) or "/tmp"
    fd, temporary = tempfile.mkstemp(prefix="bootpd.plist.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(new_data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, CONFIG)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

if __name__ == "__main__":
    merge()
