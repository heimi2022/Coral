"""Physical-command correlation, including refresh rank and count checks."""

import json
from pathlib import Path
import tempfile
import unittest

try:
    from .profile_matrix_dram_commands import address_decoder, analyze
except ImportError:
    from profile_matrix_dram_commands import address_decoder, analyze


class DramCommandsTest(unittest.TestCase):
    config = Path(__file__).with_name("CORAL_DDR4_32GBps_interleaved.ini")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.commands, self.reads, self.stats = (root / name for name in ("commands", "reads", "stats"))
        self.commands.write_text(
            "2 1 refresh -1 1 -1 -1 -0x1 -0x1\n"
            "4 3 refresh -1 0 -1 -1 -0x1 -0x1\n"
            "20 19 write 0 0 0 0 0x0 0x1\n"
            "40 39 write 0 0 0 0 0x0 0x2\n"
            "804 803 read 0 0 0 0 0x0 0x0\n")
        events = [dict(event="ar", request=0, address=0, beats=1),
                  dict(event="submit", request=0, beat=0, time_ns=0),
                  dict(event="done", request=0, beat=0, time_ns=418),
                  dict(event="end")]
        self.reads.write_text("".join(json.dumps(row) + "\n" for row in events))
        self.stats.write_text(json.dumps({"0": dict(num_read_cmds=1, num_write_cmds=2, num_ref_cmds=2)}))

    def test_address_mapping_matches_native_formatter(self):
        decode, tck, trfc = address_decoder(self.config)
        self.assertEqual(decode(0x80010000), (0, 0, 0, 0, 0x2000, 0x40))
        self.assertEqual(decode(0x8001f1c0), (0, 0, 3, 1, 0x2000, 0x7c))
        self.assertEqual(decode(0x8001f240), (0, 0, 1, 2, 0x2000, 0x7c))
        self.assertEqual(decode(0x20000), (0, 1, 0, 0, 0, 0))
        self.assertEqual((tck, trfc), (0.5, 706))

    def test_write_runs_and_same_rank_refresh(self):
        result = analyze(self.commands, self.reads, self.config, self.stats)
        row = result["slowest_reads"][0]
        self.assertEqual(row["same_rank_refresh_overlap_ns"], 353)
        self.assertEqual(row["writes_while_waiting"], 2)
        self.assertEqual(row["submit_to_issue_ns"], 402)
        self.assertEqual(row["issue_to_done_ns"], 16)
        self.assertEqual(result["largest_write_runs"][0]["writes"], 2)
        self.assertEqual(result["slow_reads_with_same_rank_refresh"], 1)

    def test_stats_mismatch_rejected(self):
        self.stats.write_text(json.dumps({"0": dict(num_read_cmds=2, num_write_cmds=2, num_ref_cmds=2)}))
        with self.assertRaisesRegex(ValueError, "differs from DRAMsim3"):
            analyze(self.commands, self.reads, self.config, self.stats)

    def test_missing_physical_read_rejected(self):
        self.commands.write_text(self.commands.read_text().replace("0x0 0x0\n", "0x0 0x1\n"))
        with self.assertRaisesRegex(ValueError, "Unmatched physical READ"):
            analyze(self.commands, self.reads, self.config, self.stats)


if __name__ == "__main__":
    unittest.main()
