"""Check pre-edge window accounting and native replay's timing validation."""

import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from profile_matrix_dram_readiness import match_reads, select_queries


def fixture(start=40, cycles=5):
    reads = [dict(request=i, beat=0, ar=2 + i * 2, r=100 + i * 2,
                  issue=80, done=96) for i in range(16)]
    reads.append(dict(request=16, beat=0, ar=60, r=132, issue=90, done=106))
    for read in reads:
        read["ddr_address"] = (0, 0, 0, 0, 1, read["request"])
    wave = dict(verified=True, activation_gaps=[dict(start_ns=start, cycles=cycles)])
    dependency = dict(verified=True, trace_to_sim_offset_ns=0,
                      loads=[dict(issue_id=0, first_request=0, last_request=16,
                                  last_ar_ns=60, role="B")],
                      stalls=[dict(start_ns=start, cycles=cycles, load_issue_ids=[0])])
    return wave, dependency, dict(verified=True, clock_ns=2), reads


class ReadinessSelectionTest(unittest.TestCase):
    def test_full_window_with_unissued_load_requests(self):
        queries, partition = select_queries(*fixture(), 16)
        self.assertEqual([q["ns"] for q in queries], [40, 42, 44, 46, 48])
        self.assertEqual(partition, {"read_not_issued": 5})

    def test_same_edge_ar_is_excluded(self):
        data = fixture(60, 1)
        data[1]["loads"][0]["last_ar_ns"] = 110
        self.assertEqual(select_queries(*data, 16), ([], {}))

    def test_same_edge_r_still_occupies_slot(self):
        data = fixture(100, 2)
        data[3][-1]["ar"] = 110
        data[1]["loads"][0]["last_ar_ns"] = 110
        self.assertEqual(select_queries(*data, 16), ([], {"r_handshake": 1}))

    def test_rejects_nonblocking_head_and_overlapping_stalls(self):
        for kind in ("owner", "overlap", "ar_order", "unverified"):
            data = fixture()
            if kind == "owner":
                data[1]["loads"][0]["first_request"] = 1
            elif kind == "overlap":
                data[1]["stalls"] *= 2
            elif kind == "ar_order":
                data[3][1]["ar"] = data[3][0]["ar"]
            else:
                data[0]["verified"] = False
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                select_queries(*data, 16)

    def test_repeated_address_matches_in_submission_order(self):
        reads = [dict(submit=2, done=20, address=64), dict(submit=3, done=30, address=64)]
        commands = [dict(kind="read", address=(0, 0, 0, 0, 0, 1), time_ns=t)
                    for t in (10, 15)]
        match_reads(reads, commands, lambda _: (0, 0, 0, 0, 0, 1))
        self.assertEqual([r["issue"] for r in reads], [10, 15])
        with self.assertRaises(ValueError):
            match_reads(copy.deepcopy(reads), commands[:1], lambda _: (0, 0, 0, 0, 0, 1))


@unittest.skipUnless(os.getenv("CORAL_DRAM_STATE_PROBE"), "Native probe not supplied")
class NativeReadinessTest(unittest.TestCase):
    def run_probe(self, commands, queries):
        config = Path(__file__).with_name("CORAL_DDR4_32GBps_interleaved.ini")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "commands").write_text(commands)
            (path / "queries").write_text(queries)
            return subprocess.run([os.environ["CORAL_DRAM_STATE_PROBE"], str(config),
                                   str(path / "commands"), str(path / "queries"), temporary],
                                  capture_output=True, text=True)

    def test_activate_read_precharge_refresh_constraints(self):
        commands = ("101 100 activate 0 0 0 0 1 0\n"
                    "129 128 read 0 0 0 0 1 0\n"
                    "167 166 precharge 0 0 0 0 1 0\n"
                    "195 194 refresh -1 0 -1 -1 -1 -1\n")
        queries = ("0 110 0 0 0 0 1 0\n1 140 0 0 0 0 1 0\n"
                   "2 170 0 0 0 0 1 0\n3 200 0 0 0 0 1 0\n")
        result = self.run_probe(commands, queries)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r.split()[2:4] for r in result.stdout.splitlines()],
                         [["read_timing", "activate"], ["read_ready", "none"],
                          ["activate_timing", "activate+precharge"], ["activate_timing", "refresh"]])
        self.assertIn("Validated 4 native commands; 4 queries", result.stderr)

    def test_rejects_read_before_trcd_and_unsorted_commands(self):
        for commands in ("101 100 activate 0 0 0 0 1 0\n102 101 read 0 0 0 0 1 0\n",
                         "101 100 activate 0 0 0 0 1 0\n100 99 read 0 0 0 0 1 0\n"):
            result = self.run_probe(commands, "")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_write_recovery_blocks_read_and_row_switch(self):
        result = self.run_probe("101 100 activate 0 0 0 0 1 0\n"
                                "129 128 write 0 0 0 0 1 0\n",
                                "0 140 0 0 0 0 1 0\n1 150 0 0 0 0 2 0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r.split()[2:4] for r in result.stdout.splitlines()],
                         [["read_timing", "write"], ["precharge_timing", "write"]])


if __name__ == "__main__":
    unittest.main()
