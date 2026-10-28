"""Check clock alignment, LOAD identity and overlapping stall attribution."""

import copy
import unittest

from profile_matrix_gemm_dram import analyze


def fixture():
    events = [
        dict(event="ISSUE_LOAD", pc=16, ns=100, issue_id=0),
        dict(event="DMA_ACCEPT", pc=16, ns=102, op=0, reg=0, base=0x80000000,
             rows=1, cols=64, stride=128, elem_bytes_log2=0),
        dict(event="ISSUE_LOAD", pc=20, ns=104, issue_id=1),
        dict(event="DMA_ACCEPT", pc=20, ns=106, op=9, reg=1, base=0x80021000,
             rows=1, cols=64, stride=512, elem_bytes_log2=0),
        dict(event="AXI_R", pc=0, ns=112),
        dict(event="AXI_R", pc=0, ns=114),
        dict(event="COMPLETE", pc=16, ns=114),
        dict(event="COMPLETE", pc=20, ns=116),
    ]
    wave = dict(verified=True, events=events,
                cpu_head_stall_intervals=[
                    dict(kind="MATMUL", pc=24, reason="register_conflict",
                         start_ns=108, cycles=3, blockers=[
                             dict(kind="LOAD", issue_id=0), dict(kind="LOAD", issue_id=1)]),
                    dict(kind="MATMUL", pc=24, reason="register_conflict",
                         start_ns=114, cycles=1, blockers=[dict(kind="LOAD", issue_id=1)])],
                activation_gaps=[dict(start_ns=108, cycles=4)])
    reads = [dict(request=0, beat=0, address=0x80000000,
                  ar=3, submit=4, done=8, observed=8, offer=11, r=12),
             dict(request=1, beat=0, address=0x80021000,
                  ar=7, submit=8, done=10, observed=10, offer=13, r=14)]
    metrics = dict(verified=True, clock_ns=2, axi_read_beats=2,
                   retired_matrix_instructions={"LOAD": 2})
    return wave, metrics, reads


class GemmDramProfileTest(unittest.TestCase):
    def test_overlapping_data_and_scale_loads_count_each_idle_cycle_once(self):
        result = analyze(*fixture())
        self.assertEqual(result["trace_to_sim_offset_ns"], 100)
        self.assertEqual(result["matched_loads"], 2)
        self.assertEqual(result["load_blocked_matmul_activation_idle_cycles"], 4)
        self.assertEqual(sum(result["joint_load_phases_during_activation_idle"].values()), 4)
        self.assertEqual(result["loads"][1]["role"], "B_scale")
        self.assertEqual(result["loads"][0]["last_r_ns"], 112)

    def test_stall_can_overlap_useful_activation_feed(self):
        wave, metrics, reads = fixture()
        wave["activation_gaps"] = [dict(start_ns=110, cycles=1)]
        result = analyze(wave, metrics, reads)
        self.assertEqual(result["load_blocked_matmul_head_cycles"], 4)
        self.assertEqual(result["load_blocked_matmul_activation_idle_cycles"], 1)

    def test_repeated_pc_is_matched_by_occurrence(self):
        wave, metrics, reads = fixture()
        for event in wave["events"]:
            if event["pc"] == 20:
                event["pc"] = 16
        result = analyze(wave, metrics, reads)
        self.assertEqual([load["issue_id"] for load in result["loads"]], [0, 1])
        self.assertEqual([load["scoreboard_release_ns"] for load in result["loads"]], [114, 116])

    def test_multiple_rows_remain_part_of_one_load(self):
        wave, metrics, reads = fixture()
        wave["events"] = wave["events"][:2] + wave["events"][4:7]
        wave["events"][1]["rows"] = 2
        wave["cpu_head_stall_intervals"] = []
        reads[1]["address"] = reads[0]["address"] + 128
        metrics["retired_matrix_instructions"]["LOAD"] = 1
        self.assertEqual(analyze(wave, metrics, reads)["matched_loads"], 1)

    def test_bad_or_incomplete_inputs_fail_closed(self):
        for label in ("clock", "address", "unverified", "completion", "count", "width", "id"):
            with self.subTest(label=label):
                wave, metrics, reads = copy.deepcopy(fixture())
                if label == "clock":
                    wave["events"][5]["ns"] += 2
                elif label == "address":
                    reads[1]["address"] += 64
                elif label == "unverified":
                    wave["verified"] = False
                elif label == "completion":
                    wave["events"] = wave["events"][:-1]
                elif label == "count":
                    metrics["axi_read_beats"] += 1
                elif label == "width":
                    wave["events"][1]["cols"] = 128
                elif label == "id":
                    wave["events"][2]["issue_id"] = 0
                with self.assertRaises(ValueError):
                    analyze(wave, metrics, reads)


if __name__ == "__main__":
    unittest.main()
