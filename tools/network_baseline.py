#!/usr/bin/env python3
"""Passive Linux network/CPU baseline. Reads aggregate counters; never tunes the host.

The reported Mbps describe observed interface traffic, not available Internet speed.
No endpoints, peers, keys, account data or environment variables are collected.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import time

CPU_FIELDS = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")
DEV_FIELDS = {"rx_bytes": 0, "rx_errors": 2, "rx_drops": 3,
              "tx_bytes": 8, "tx_errors": 10, "tx_drops": 11}
UDP_FIELDS = ("InErrors", "RcvbufErrors", "SndbufErrors")
INTERFACE = re.compile(r"[A-Za-z0-9_.:@-]{1,15}\Z")


def valid_interface(value: str) -> bool:
    return value not in (".", "..") and bool(INTERFACE.fullmatch(value))


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return None


def unsigned(value: str) -> int:
    if not value or not value.isascii() or not value.isdecimal():
        raise ValueError("Invalid aggregate counter")
    return int(value)


def parse_cpu(text: str | None) -> dict[str, int] | None:
    if text is None:
        return None
    for line in text.splitlines():
        parts = line.split()
        if parts and parts[0] == "cpu":
            if len(parts) < 5:
                return None
            try:
                # guest/guest_nice are ALREADY included in user/nice. Never add
                # the ninth and tenth counters to total a second time.
                values = [unsigned(x) for x in parts[1:9]]
                values.extend([0] * (len(CPU_FIELDS) - len(values)))
                return dict(zip(CPU_FIELDS, values))
            except ValueError:
                return None
    return None


def parse_devices(text: str | None) -> dict[str, dict[str, int]] | None:
    if text is None:
        return None
    output = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        name, data = line.rsplit(":", 1)
        name, fields = name.strip(), data.split()
        if not valid_interface(name) or len(fields) != 16:
            continue
        try:
            output[name] = {key: unsigned(fields[index]) for key, index in DEV_FIELDS.items()}
        except ValueError:
            continue
    return output


def parse_udp4(text: str | None) -> dict[str, int] | None:
    if text is None:
        return None
    lines = [line.split() for line in text.splitlines() if line.startswith("Udp:")]
    if len(lines) != 2 or len(lines[0]) != len(lines[1]):
        return None
    try:
        values = dict(zip(lines[0][1:], lines[1][1:]))
        return {key: unsigned(values[key]) for key in UDP_FIELDS}
    except (KeyError, ValueError):
        return None


def parse_udp6(text: str | None) -> dict[str, int] | None:
    if text is None:
        return None
    values = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            values[parts[0]] = parts[1]
    try:
        return {key: unsigned(values["Udp6" + key]) for key in UDP_FIELDS}
    except (KeyError, ValueError):
        return None


def sysfs_number(sys_net: Path, interface: str, field: str) -> int | None:
    # Interface names originate from /proc or strict CLI validation; field names
    # are fixed by this module, never user-provided paths.
    text = read_text(sys_net / interface / field)
    try:
        value = unsigned(text.strip()) if text is not None else 0
        return value if value > 0 else None
    except ValueError:
        return None


@dataclass(frozen=True)
class Snapshot:
    at: float
    cpu: dict[str, int] | None
    devices: dict[str, dict[str, int]] | None
    udp4: dict[str, int] | None
    udp6: dict[str, int] | None
    mtu: dict[str, int | None]
    ifindex: dict[str, int | None]


def snapshot(interface: str | None = None, *, proc: Path = Path("/proc"),
             sys_net: Path = Path("/sys/class/net")) -> Snapshot:
    cpu = parse_cpu(read_text(proc / "stat"))
    devices = parse_devices(read_text(proc / "net/dev"))
    names = ([interface] if interface else sorted(name for name in (devices or {}) if name != "lo"))
    if devices is not None:
        devices = {name: devices[name] for name in names if name in devices}
    udp4 = parse_udp4(read_text(proc / "net/snmp"))
    udp6 = parse_udp6(read_text(proc / "net/snmp6"))
    mtu = {name: sysfs_number(sys_net, name, "mtu") for name in names}
    ifindex = {name: sysfs_number(sys_net, name, "ifindex") for name in names}
    return Snapshot(time.monotonic(), cpu, devices, udp4, udp6, mtu, ifindex)


def counter_delta(before: dict[str, int] | None, after: dict[str, int] | None,
                  keys: tuple[str, ...]) -> dict:
    status = "ok"
    values = {key: None for key in keys}
    if before is None or after is None or any(key not in before or key not in after for key in keys):
        status = "unavailable"
    elif any(after[key] < before[key] for key in keys):
        # The source may have restarted. Do not combine two counter epochs.
        status = "counter_reset"
    else:
        values = {key: after[key] - before[key] for key in keys}
    return {"status": status, "deltas": values}


def report(before: Snapshot, after: Snapshot, requested_seconds: float,
           interface: str | None = None) -> dict:
    elapsed = after.at - before.at
    interval_valid = math.isfinite(elapsed) and elapsed > 0
    cpu = counter_delta(before.cpu, after.cpu, CPU_FIELDS)
    cpu.update({"total_ticks": None, "busy_percent": None, "idle_percent": None,
                "iowait_percent": None, "steal_percent": None, "softirq_percent": None})
    if cpu["status"] == "ok" and interval_valid:
        delta = cpu["deltas"]
        total = sum(delta.values())
        cpu["total_ticks"] = total
        if total:
            busy = total - delta["idle"] - delta["iowait"] - delta["steal"]
            cpu["busy_percent"] = round(100 * busy / total, 4)
            for field in ("idle", "iowait", "steal", "softirq"):
                cpu[field + "_percent"] = round(100 * delta[field] / total, 4)
        else:
            cpu["status"] = "no_ticks"
    elif not interval_valid:
        cpu["status"] = "invalid_interval"

    names = sorted(set(before.devices or {}) | set(after.devices or {}))
    if interface and interface not in names:
        names.append(interface)
    interfaces = {}
    for name in names:
        item = counter_delta((before.devices or {}).get(name), (after.devices or {}).get(name),
                             tuple(DEV_FIELDS))
        old_index, new_index = before.ifindex.get(name), after.ifindex.get(name)
        if old_index is not None and new_index is not None and old_index != new_index:
            item = {"status": "interface_changed", "deltas": dict.fromkeys(DEV_FIELDS)}
        if not interval_valid:
            item["status"] = "invalid_interval"
        item.update({"rx_mbps": None, "tx_mbps": None, "mtu_bytes": after.mtu.get(name),
                     "mtu_changed": None})
        if before.mtu.get(name) is not None and after.mtu.get(name) is not None:
            item["mtu_changed"] = before.mtu[name] != after.mtu[name]
        if item["status"] == "ok":
            for direction in ("rx", "tx"):
                item[direction + "_mbps"] = round(item["deltas"][direction + "_bytes"] * 8 / elapsed / 1_000_000, 6)
        interfaces[name] = item

    udp4 = counter_delta(before.udp4, after.udp4, UDP_FIELDS)
    udp6 = counter_delta(before.udp6, after.udp6, UDP_FIELDS)
    partial = (not interfaces or cpu["status"] != "ok" or
               any(value["status"] != "ok" for value in interfaces.values()) or
               udp4["status"] != "ok" or udp6["status"] != "ok")
    return {"schema_version": 1, "kind": "pushok-network-baseline", "scope": "local_host",
            "measurement": "passive_counters", "status": "partial" if partial else "ok",
            "collected_at_utc": datetime.now(timezone.utc).isoformat(),
            "requested_sample_seconds": requested_seconds,
            "elapsed_seconds": round(elapsed, 6) if interval_valid else None,
            "cpu": cpu, "interfaces": interfaces, "udp4": udp4, "udp6": udp6}


def sample_seconds(value: str) -> float:
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Sample must be a finite number from 0.1 to 30 seconds") from error
    if not math.isfinite(number) or not 0.1 <= number <= 30:
        raise argparse.ArgumentTypeError("Sample must be a finite number from 0.1 to 30 seconds")
    return number


def interface_name(value: str) -> str:
    if not valid_interface(value):
        raise argparse.ArgumentTypeError("Invalid Linux interface name")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample-seconds", type=sample_seconds, default=3.0)
    parser.add_argument("--interface", type=interface_name,
                        help="One interface; by default report all observed interfaces except lo")
    args = parser.parse_args()
    before = snapshot(args.interface)
    time.sleep(args.sample_seconds)
    after = snapshot(args.interface)
    print(json.dumps(report(before, after, args.sample_seconds, args.interface),
                     ensure_ascii=False, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
