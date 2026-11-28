import argparse
from dataclasses import replace
from pathlib import Path
import tempfile
import unittest

from tools import network_baseline as baseline


def fixture(at=10.0, cpu=None, devices=None, udp=None, index=4):
    return baseline.Snapshot(
        at=at, cpu=dict.fromkeys(baseline.CPU_FIELDS, 0) if cpu is None else cpu,
        devices={"eth0": dict.fromkeys(baseline.DEV_FIELDS, 0)} if devices is None else devices,
        udp4=dict.fromkeys(baseline.UDP_FIELDS, 0) if udp is None else udp,
        udp6=dict.fromkeys(baseline.UDP_FIELDS, 0) if udp is None else udp,
        mtu={"eth0": 1500}, ifindex={"eth0": index})


class NetworkBaselineTests(unittest.TestCase):
    def test_cpu_guest_is_not_counted_twice_and_steal_is_separate(self):
        before = fixture(cpu=baseline.parse_cpu("cpu 100 20 30 400 20 10 10 10 50 10\n"))
        after = fixture(at=12, cpu=baseline.parse_cpu("cpu 140 30 40 420 25 10 15 20 70 15\n"))
        cpu = baseline.report(before, after, 2)["cpu"]
        self.assertEqual(cpu["total_ticks"], 100)
        self.assertEqual(cpu["busy_percent"], 65)
        self.assertEqual(cpu["idle_percent"], 20)
        self.assertEqual(cpu["iowait_percent"], 5)
        self.assertEqual(cpu["steal_percent"], 10)
        self.assertEqual(cpu["softirq_percent"], 5)

    def test_rates_use_real_interval_not_requested_sleep(self):
        before = fixture()
        dev = dict.fromkeys(baseline.DEV_FIELDS, 0)
        dev.update(rx_bytes=2_000_000, tx_bytes=1_000_000, rx_errors=1, tx_drops=3)
        after = fixture(at=14, devices={"eth0": dev})
        item = baseline.report(before, after, 1)["interfaces"]["eth0"]
        self.assertEqual(item["rx_mbps"], 4)
        self.assertEqual(item["tx_mbps"], 2)
        self.assertEqual(item["deltas"]["rx_errors"], 1)
        self.assertEqual(item["deltas"]["tx_drops"], 3)

    def test_counter_reset_invalidates_entire_interface_epoch(self):
        dev = dict.fromkeys(baseline.DEV_FIELDS, 20)
        before = fixture(devices={"eth0": dev})
        after = fixture(at=12, devices={"eth0": {**dev, "rx_bytes": 19, "tx_bytes": 9000}})
        item = baseline.report(before, after, 2)["interfaces"]["eth0"]
        self.assertEqual(item["status"], "counter_reset")
        self.assertTrue(all(value is None for value in item["deltas"].values()))
        self.assertIsNone(item["rx_mbps"])
        self.assertIsNone(item["tx_mbps"])

    def test_new_interface_same_name_invalidates_monotonic_counters(self):
        before = fixture(index=4)
        after = fixture(at=12, index=8, devices={"eth0": dict.fromkeys(baseline.DEV_FIELDS, 1000)})
        item = baseline.report(before, after, 2)["interfaces"]["eth0"]
        self.assertEqual(item["status"], "interface_changed")
        self.assertIsNone(item["rx_mbps"])

    def test_iowait_decrease_is_unknown_instead_of_artificial_load(self):
        before = fixture(cpu={**dict.fromkeys(baseline.CPU_FIELDS, 10), "iowait": 100})
        after = fixture(at=12, cpu={**dict.fromkeys(baseline.CPU_FIELDS, 20), "iowait": 99})
        cpu = baseline.report(before, after, 2)["cpu"]
        self.assertEqual(cpu["status"], "counter_reset")
        self.assertIsNone(cpu["busy_percent"])

    def test_missing_sources_and_interface_are_explicitly_unknown(self):
        empty = baseline.Snapshot(10, None, None, None, None, {}, {})
        result = baseline.report(empty, replace(empty, at=12), 2, "missing0")
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["cpu"]["status"], "unavailable")
        self.assertEqual(result["udp6"]["status"], "unavailable")
        self.assertEqual(result["interfaces"]["missing0"]["status"], "unavailable")

    def test_nonpositive_or_nonfinite_time_never_produces_rate(self):
        for at in [10, 9, float("nan"), float("inf")]:
            with self.subTest(at=at):
                result = baseline.report(fixture(), fixture(at=at), 2)
                self.assertIsNone(result["elapsed_seconds"])
                self.assertEqual(result["interfaces"]["eth0"]["status"], "invalid_interval")
                self.assertIsNone(result["interfaces"]["eth0"]["rx_mbps"])

    def test_udp_parsers_and_resets(self):
        udp4 = baseline.parse_udp4("Ip: Forwarding\nIp: 1\nUdp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors\nUdp: 400 1 8 300 3 2\n")
        udp6 = baseline.parse_udp6("Ip6InReceives 600\nUdp6InErrors 9\nUdp6RcvbufErrors 4\nUdp6SndbufErrors 0\n")
        self.assertEqual(udp4, {"InErrors": 8, "RcvbufErrors": 3, "SndbufErrors": 2})
        self.assertEqual(udp6, {"InErrors": 9, "RcvbufErrors": 4, "SndbufErrors": 0})
        self.assertEqual(baseline.counter_delta(udp4, dict.fromkeys(baseline.UDP_FIELDS, 0), baseline.UDP_FIELDS)["status"], "counter_reset")
        self.assertIsNone(baseline.parse_udp4("Udp: InErrors RcvbufErrors SndbufErrors\nUdp: 4 nope 1\n"))
        self.assertIsNone(baseline.parse_udp6("Udp6InErrors 1\n"))

    def test_device_fields_and_malformed_rows(self):
        text = "Inter-| Receive | Transmit\n eth0: 100 2 3 4 0 0 0 0 200 7 8 9 0 0 0 0\n bad0: nonsense\n ../escape: 100 2 3 4 0 0 0 0 200 7 8 9 0 0 0 0\n"
        self.assertEqual(baseline.parse_devices(text), {"eth0": {"rx_bytes": 100, "rx_errors": 3,
                         "rx_drops": 4, "tx_bytes": 200, "tx_errors": 8, "tx_drops": 9}})
        self.assertIsNone(baseline.parse_cpu("cpu 1 2 -3 4\n"))

    def test_snapshot_filters_and_reads_only_aggregate_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "proc/net").mkdir(parents=True)
            (root / "sys/eth0").mkdir(parents=True)
            (root / "proc/stat").write_text("cpu 1 2 3 4 5 6 7 8 0 0\n")
            (root / "proc/net/dev").write_text("lo: " + "0 " * 15 + "0\neth0: " + "1 " * 15 + "1\n")
            (root / "sys/eth0/mtu").write_text("1420\n")
            (root / "sys/eth0/ifindex").write_text("7\n")
            value = baseline.snapshot(proc=root / "proc", sys_net=root / "sys")
            self.assertEqual(list(value.devices), ["eth0"])
            self.assertEqual(value.mtu, {"eth0": 1420})
            self.assertEqual(value.ifindex, {"eth0": 7})
            self.assertIsNone(value.udp6)

    def test_interface_and_duration_validation(self):
        for name in ("eth0", "wg0", "enp0s3", "br-abcd", "eth0.20"):
            self.assertEqual(baseline.interface_name(name), name)
        for name in ("", "../private", ".", "..", "a" * 16, "eth0\n"):
            with self.assertRaises(argparse.ArgumentTypeError):
                baseline.interface_name(name)
        for seconds in ("nan", "inf", "-1", "0", "31", "oops"):
            with self.assertRaises(argparse.ArgumentTypeError):
                baseline.sample_seconds(seconds)
        self.assertEqual(baseline.sample_seconds("0.1"), 0.1)
        self.assertEqual(baseline.sample_seconds("30"), 30)

    def test_interfaces_remain_independent_and_zero_cpu_ticks_unknown(self):
        before = fixture(devices={name: dict.fromkeys(baseline.DEV_FIELDS, 0) for name in ("wg0", "eth0")})
        after = fixture(at=12, devices={name: dict.fromkeys(baseline.DEV_FIELDS, 1_000_000) for name in ("wg0", "eth0")})
        result = baseline.report(before, after, 2)
        self.assertEqual(set(result["interfaces"]), {"wg0", "eth0"})
        self.assertEqual(result["interfaces"]["wg0"]["rx_mbps"], 4)
        self.assertEqual(result["interfaces"]["eth0"]["rx_mbps"], 4)
        self.assertNotIn("total_mbps", result)
        self.assertEqual(result["cpu"]["status"], "no_ticks")


if __name__ == "__main__":
    unittest.main()
