#!/usr/bin/env python3
"""Capture VirtualMac key-event evidence from an iPad without changing it.

The script follows /tmp/VirtualMac.log over SSH and extracts the host-side
HID usage, macOS virtual keyCode, press/release state, and event counter. It
never writes to the iPad. The SSH password is read from stdin or prompted and
is passed through SSHPASS only; it is not saved.

On normal builds VirtualMac prints only its first 12 key events. When debug
logging is enabled for the next VM boot, the same log also contains health
lines with cumulative key counts. The report distinguishes those cases from
an actual missing key event.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


KEY_RE = re.compile(
    r"input key=(?P<count>\d+) HID=0x(?P<hid>[0-9a-f]+) "
    r"mac=(?P<mac>-?\d+) pressed=(?P<pressed>[01])"
)
HEALTH_RE = re.compile(r"health state=.*? keys=(?P<keys>\d+)")
POINTER_RE = re.compile(
    r"input pointer=(?P<count>\d+) location=(?P<x>[0-9.]+),(?P<y>[0-9.]+) "
    r"buttons=0x(?P<buttons>[0-9a-f]+)"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="192.168.64.1")
    parser.add_argument("--port", default="22")
    parser.add_argument("--duration", type=float, default=90.0)
    parser.add_argument("--out", type=Path, default=Path(".diag/ipad-key-events"))
    parser.add_argument(
        "--password-stdin", action="store_true",
        help="read the SSH password from stdin instead of prompting",
    )
    args = parser.parse_args()

    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\r\n")
    else:
        password = getpass.getpass("SSH password (not saved): ")
    if not password:
        parser.error("empty SSH password")

    args.out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    raw_path = args.out / f"raw-{stamp}.log"
    events_path = args.out / f"events-{stamp}.jsonl"
    pointer_path = args.out / f"pointers-{stamp}.jsonl"
    summary_path = args.out / f"summary-{stamp}.json"

    env = os.environ.copy()
    env["SSHPASS"] = password
    command = [
        "sshpass", "-e", "ssh", "-T", "-n",
        "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
        "-p", str(args.port), f"root@{args.host}",
        "tail -F /tmp/VirtualMac.log",
    ]
    proc = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, env=env,
    )
    started = time.monotonic()
    events: list[dict[str, object]] = []
    pointer_events: list[dict[str, object]] = []
    health_counts: list[int] = []
    raw_lines = 0

    try:
        with raw_path.open("w", encoding="utf-8") as raw, events_path.open(
            "w", encoding="utf-8"
        ) as events_file, pointer_path.open("w", encoding="utf-8") as pointer_file:
            assert proc.stdout is not None
            while time.monotonic() - started < args.duration:
                ready, _, _ = select.select([proc.stdout], [], [], 0.25)
                if not ready:
                    continue
                line = proc.stdout.readline()
                if not line:
                    if proc.poll() is not None:
                        break
                    continue
                raw.write(line)
                raw.flush()
                raw_lines += 1
                match = KEY_RE.search(line)
                if match:
                    event = {
                        "event_count": int(match.group("count")),
                        "hid_usage": f"0x{match.group('hid').lower()}",
                        "mac_key_code": int(match.group("mac")),
                        "pressed": bool(int(match.group("pressed"))),
                        "raw": line.rstrip("\n"),
                    }
                    events.append(event)
                    events_file.write(json.dumps(event, ensure_ascii=False) + "\n")
                    events_file.flush()
                pointer = POINTER_RE.search(line)
                if pointer:
                    pointer_event = {
                        "event_count": int(pointer.group("count")),
                        "x": float(pointer.group("x")),
                        "y": float(pointer.group("y")),
                        "buttons": f"0x{pointer.group('buttons').lower()}",
                        "raw": line.rstrip("\n"),
                    }
                    pointer_events.append(pointer_event)
                    pointer_file.write(json.dumps(pointer_event, ensure_ascii=False) + "\n")
                    pointer_file.flush()
                health = HEALTH_RE.search(line)
                if health:
                    health_counts.append(int(health.group("keys")))
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
        env.pop("SSHPASS", None)

    summary = {
        "host": args.host,
        "port": int(args.port),
        "duration_seconds": round(time.monotonic() - started, 2),
        "raw_lines": raw_lines,
        "key_event_lines": len(events),
        "pointer_event_lines": len(pointer_events),
        "health_key_counts": health_counts,
        "debug_health_seen": bool(health_counts),
        "note": (
            "Normal builds print only the first 12 key events; absence after "
            "that threshold is inconclusive."
        ),
        "raw_log": str(raw_path),
        "events_jsonl": str(events_path),
        "pointers_jsonl": str(pointer_path),
    }
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
