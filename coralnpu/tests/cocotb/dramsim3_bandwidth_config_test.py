"""Configuration invariants for the DDR data-rate experiment; no RTL build."""

import configparser
from fractions import Fraction
from pathlib import Path
import tempfile
import unittest

from tests.cocotb.make_dramsim3_bandwidth_config import BASE, generate


def read_config(path):
    cfg = configparser.ConfigParser()
    cfg.optionxform = str
    cfg.read(path)
    return cfg


class BandwidthConfigTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def config(self, bandwidth):
        output = Path(self.directory.name) / f"bw{bandwidth}.ini"
        result = generate(bandwidth, output)
        return output, read_config(output), result

    def test_baseline_is_byte_identical(self):
        output, _, _ = self.config(32)
        self.assertEqual(output.read_bytes(), BASE.read_bytes())

    def test_topology_mapping_power_and_queue_parameters_unchanged(self):
        baseline = read_config(BASE)
        for bandwidth in (32, 48, 64):
            with self.subTest(bandwidth=bandwidth):
                _, cfg, _ = self.config(bandwidth)
                self.assertEqual(set(cfg.sections()), set(baseline.sections()))
                for section in ("system", "dram_structure", "power", "other"):
                    self.assertEqual(dict(cfg[section]), dict(baseline[section]))
                self.assertAlmostEqual(16 / cfg.getfloat("timing", "tCK"), bandwidth)
                self.assertEqual(cfg.getint("system", "bus_width") // 8 *
                                 cfg.getint("dram_structure", "BL"), 64)

    def test_absolute_timing_rounding_and_refresh_interval(self):
        for bandwidth in (48, 64):
            _, cfg, report = self.config(bandwidth)
            tck = Fraction(16, bandwidth)
            for name, timing in report["timing"].items():
                old_ns = Fraction(timing["baseline_cycles"], 2)
                actual_ns = cfg.getint("timing", name) * tck
                if name == "tCCD_S":
                    self.assertEqual(cfg.getint("timing", name), 4)
                elif name.startswith("tREFI"):
                    self.assertLessEqual(actual_ns, old_ns)
                    self.assertLess(old_ns - actual_ns, tck)
                else:
                    self.assertGreaterEqual(actual_ns, old_ns)
                    self.assertLess(actual_ns - old_ns, tck)
            self.assertEqual(report["timing"]["CL"]["ns"], 14)
            self.assertEqual(report["timing"]["tRCD"]["ns"], 14)
            self.assertEqual(report["timing"]["tRFC"]["ns"], 353)
            self.assertEqual(report["timing"]["tREFI"]["ns"], 7862)
            self.assertAlmostEqual(report["burst_ns"], 64 / bandwidth)
            self.assertAlmostEqual(report["read_command_to_callback_ns"], 14 + 64 / bandwidth)

    def test_unsupported_bandwidth_rejected(self):
        with self.assertRaisesRegex(ValueError, "Supported bandwidth"):
            self.config(96)


if __name__ == "__main__":
    unittest.main()
