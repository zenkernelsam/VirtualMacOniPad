#!/var/jb/usr/bin/python3
import copy
import os
import plistlib
import subprocess
import tempfile

CONFIG = "/tmp/bootpd.plist"
CREATOR = "vzi-hotspot-compat"
STOCK_CONFIG = "/Library/Preferences/SystemConfiguration/bootpd.plist"

def interface_blocks():
    try:
        ifconfig = "/var/jb/sbin/ifconfig"
        if not os.path.exists(ifconfig):
            ifconfig = "/sbin/ifconfig"
        out = subprocess.check_output([ifconfig, "-a"],
                                      stderr=subprocess.DEVNULL).decode()
    except Exception:
        return {}
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
    try:
        with open(STOCK_CONFIG, "rb") as f:
            stock = plistlib.load(f)
    except Exception:
        stock = {}
    subnets = stock.get("Subnets", []) if isinstance(stock, dict) else []
    blocks = interface_blocks()
    for subnet in subnets:
        if not isinstance(subnet, dict):
            continue
        if subnet.get("net_address") != "172.20.10.0":
            continue
        interface = subnet.get("interface")
        # The carrier bridge index is not stable across a reboot/jailbreak.
        # The stock plist is written by misd only for an active hotspot; use
        # its interface and subnet as the authority. Requiring a particular
        # member (ap1) races bridge creation and misses the first WatchPaths
        # event, leaving DHCP disabled until the user toggles the hotspot.
        if interface:
            result = dict(subnet)
            result["_creator"] = CREATOR
            return interface, result
    return None, None

def merge():
    interface, hotspot_subnet = hotspot_config()
    try:
        with open(CONFIG, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        data = {"Subnets": []}
    if not isinstance(data, dict):
        data = {"Subnets": []}
    old_subnets = data.get("Subnets", [])
    stale_interfaces = {x.get("interface") for x in old_subnets
                        if isinstance(x, dict) and
                        (x.get("_creator") == CREATOR or
                         x.get("net_address") == "172.20.10.0")}
    data["Subnets"] = [x for x in old_subnets
                       if not (isinstance(x, dict) and
                               (x.get("_creator") == CREATOR or
                                x.get("net_address") == "172.20.10.0"))]
    for key in ("dhcp_enabled", "detect_other_dhcp_server", "ignore_allow_deny"):
        data[key] = [x for x in data.get(key, []) if x not in stale_interfaces]
    if interface and hotspot_subnet:
        data["Subnets"].append(hotspot_subnet)
        for key in ("dhcp_enabled", "detect_other_dhcp_server", "ignore_allow_deny"):
            data[key].append(interface)
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
    # misd may write the stock plist just before creating/configuring the
    # bridge. Retry briefly so the first hotspot activation converges without
    # requiring a second toggle, while each merge remains byte-idempotent.
    for attempt in range(6):
        merge()
        if attempt != 5:
            import time
            time.sleep(1)
