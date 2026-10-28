"""Check report arithmetic and rejection of stale or mismatched evidence."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from tests.cocotb.make_dramsim3_bandwidth_config import BASE
from tests.cocotb.report_matrix_gemm import write_report


class ReportTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.config = self.directory / "memory.ini"
        self.config.write_bytes(BASE.read_bytes())
        self.metrics = dict(
            m=512, k=128, n=512, logical_macs=33554432,
            elapsed_cycles=32768, clock_ns=2,
            logical_macs_per_cycle=1024, verified=True, dense=False,
            stalled=False, measurement="synthetic test fixture, not a measured result",
            axi_read_bytes=675840, axi_read_beats=10560,
            axi_write_bytes=1048576, axi_write_beats=16384,
            peak_dispatched_unretired_matmuls=2,
            memory=dict(model="dramsim3", config=str(self.config),
                        ddr_peak_gb_per_s_shared=32, axi_bus_bits=512,
                        ddr_channels=1, ddr_bus_bits_per_channel=64,
                        ddr_burst_length=8))
        self.save_metrics()
        (self.directory / "dramsim3_backend.json").write_text(json.dumps(dict(
            config=str(self.config),
            config_sha256=hashlib.sha256(self.config.read_bytes()).hexdigest(),
            backend="test-fixture", backend_sha256="test-fixture")))

    def save_metrics(self):
        (self.directory / "gemm_metrics.json").write_text(json.dumps(self.metrics))

    def test_peak_throughput_and_time_units(self):
        report = write_report(self.directory).read_text()
        for expected in ("**1024.000**", "**100.00%**", "512.000 GMAC/s",
                         "65.536 us", "32 GB/s", "rochracobabg"):
            self.assertIn(expected, report)

    def test_unverified_metrics_rejected(self):
        self.metrics["verified"] = False
        self.save_metrics()
        with self.assertRaisesRegex(ValueError, "verified"):
            write_report(self.directory)

    def test_changed_config_rejected(self):
        self.config.write_text(self.config.read_text().replace("tCK = 0.5", "tCK = 0.25"))
        with self.assertRaisesRegex(ValueError, "changed"):
            write_report(self.directory)

    def test_stale_metrics_rejected(self):
        future_ns = (self.directory / "gemm_metrics.json").stat().st_mtime_ns + 10**9
        with self.assertRaisesRegex(ValueError, "fresh"):
            write_report(self.directory, future_ns)

    def test_inconsistent_cycle_metric_rejected(self):
        self.metrics["elapsed_cycles"] += 100
        self.save_metrics()
        with self.assertRaisesRegex(ValueError, "MAC/cycle"):
            write_report(self.directory)


if __name__ == "__main__":
    unittest.main()
