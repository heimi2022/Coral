"""Small fixtures for pre-edge VCD sampling and command overlap checks."""

from io import StringIO
import unittest

from analyze_matrix_gemm_wave import QUEUES, SIGNALS, TILING, analyze, rising_samples
from profile_matrix_gemm_wave import SIGNALS as PROFILE_SIGNALS, profile, validate_profile


def idle():
    s = dict.fromkeys(SIGNALS, 0)
    s.update(rst_n=1, cfg_m_i=1, cfg_n_i=1, cfg_k_i=1)
    return s


def overlap_samples():
    samples = []
    for index in range(3):
        s = idle()
        s.update(cmd_valid_i=1, cmd_ready_o=1, cmd_pc_i=0x100 + 4 * index)
        s[TILING + "block_queue_wr_en"] = 1
        for prefix in QUEUES.values():
            s[prefix + "do_write"] = 1
        samples.append((10 * index, s))
    s = idle()
    s.update(cmd_valid_i=1, cmd_decode_busy=1)
    s[QUEUES["act_psum"] + "full_o"] = 1
    samples.append((30, s))
    for index in range(3):
        s = idle()
        s.update(done_valid_o=1, done_ready_i=1, done_pc_o=0x100 + 4 * index)
        for prefix in QUEUES.values():
            s[prefix + "do_read"] = 1
        samples.append((40 + 10 * index, s))
    return samples


class WaveAnalysisTest(unittest.TestCase):
    def test_samples_before_edge_independent_of_update_order(self):
        for clock_first in (True, False):
            header = ["$timescale\n 1 ps\n$end\n",
                      "$scope module top $end\n$scope module u_pe_ctrl $end\n"]
            for index, name in enumerate(SIGNALS):
                # Flat fake variable names are sufficient for this parser test.
                parts = name.split(".")
                for scope in parts[:-1]:
                    header.append(f"$scope module {scope} $end\n")
                header.append(f"$var wire 32 v{index} {parts[-1]} $end\n")
                header.extend("$upscope $end\n" for _ in parts[:-1])
            header.append("$upscope $end\n$upscope $end\n$enddefinitions $end\n")
            initial = idle()
            initial.update(cmd_valid_i=1, cmd_ready_o=1, cmd_pc_i=0x100)
            body = ["#0\n"] + [f"b{initial[name]:b} v{index}\n"
                                    for index, name in enumerate(SIGNALS)]
            changes = [f"b0 v{SIGNALS.index('cmd_ready_o')}\n", "b1 v0\n"]
            if clock_first:
                changes.reverse()
            body.extend(["#5000\n", *changes, "#10000\nb0 v0\n"])
            samples = list(rising_samples(StringIO("".join(header + body))))
            self.assertEqual(len(samples), 1)
            self.assertEqual(samples[0][0], 5)
            self.assertEqual(samples[0][1]["cmd_ready_o"], 1)

    def test_parser_accepts_a_different_scope(self):
        source = StringIO("""$timescale 1 ns $end
$scope module top $end
$scope module device $end
$var wire 1 c clock $end
$var wire 1 a active $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
0c
1a
#5
1c
0a
#10
0c
""")
        self.assertEqual(list(rising_samples(source, ("clock", "active"), "device")),
                         [(5, {"clock": 0, "active": 1})])

    def test_three_commands_and_fifo_stall(self):
        result = analyze(overlap_samples(), expected_commands=3)
        self.assertTrue(result["verified"], result)
        self.assertEqual(result["peak_accepted_uncompleted_matmuls"], 3)
        self.assertEqual(result["counts"]["fill_stalled_cycles"], 1)
        self.assertEqual(result["first_accept_gaps_ns"], [10, 10])

    def test_rejects_unpaired_write(self):
        samples = overlap_samples()
        samples[0][1][QUEUES["act_psum"] + "do_write"] = 0
        self.assertFalse(analyze(samples)["verified"])

    def test_rejects_full_fifo_write(self):
        samples = overlap_samples()
        samples[0][1][QUEUES["weight"] + "full_o"] = 1
        self.assertIn("Descriptor write attempted while FIFO full",
                      analyze(samples)["violations"])

    def test_rejects_wrong_completion_order_and_truncated_trace(self):
        samples = overlap_samples()
        samples[4][1]["done_pc_o"] = 0x104
        self.assertFalse(analyze(samples)["verified"])
        self.assertFalse(analyze(overlap_samples()[:4])["verified"])

    def test_rejects_serialized_commands(self):
        samples = overlap_samples()
        serialized = [samples[index] for index in (0, 4, 1, 5, 2, 6)]
        self.assertIn("Required command overlap was not reached",
                      analyze(serialized)["violations"])

    def test_serial_measurement_still_checks_descriptor_integrity(self):
        samples = overlap_samples()
        serialized = [samples[index] for index in (0, 4, 1, 5, 2, 6)]
        result = analyze(serialized, min_inflight=1, expected_commands=3)
        self.assertTrue(result["verified"], result)
        self.assertEqual(result["peak_accepted_uncompleted_matmuls"], 1)
        serialized[0][1][QUEUES["act_psum"] + "do_write"] = 0
        self.assertFalse(analyze(serialized, min_inflight=1)["verified"])


class PerformanceProfileTest(unittest.TestCase):
    def test_repeated_load_pc_keeps_distinct_blocker_ids_and_dma_shape(self):
        base = dict.fromkeys(PROFILE_SIGNALS, 0)
        base.update(rst_n=1, rob_space=8, head_valid=1)
        load = dict(base, issued=1, head_ready=1, head_pc=0x100,
                    head_inst=0x0400002b, writeAbData=2,
                    mem_valid=1, mem_ready=1, mem_pc=0x100, mem_op=1,
                    mem_base=0x80010000, mem_rows=64, mem_cols=64, mem_stride=128)
        multiply = dict(base, candidate=1, head_pc=0x104,
                        head_inst=0x0800002b, readAbData=2)
        reload = dict(load, completed=1, completed_pc=0x100, mem_base=0x80010040)
        metrics = dict(start_ns=0, end_ns=4, clock_ns=1)
        result = profile([(0, load), (1, multiply), (2, reload), (3, multiply)], metrics)
        self.assertEqual([s["blockers"][0]["issue_id"]
                          for s in result["cpu_head_stall_intervals"]], [0, 1])
        accepts = [e for e in result["events"] if e["event"] == "DMA_ACCEPT"]
        self.assertEqual([e["base"] for e in accepts], [0x80010000, 0x80010040])
        self.assertEqual(accepts[0]["stride"], 128)

    def test_launch_compute_idle_partition_and_missing_trace(self):
        metrics = dict(start_ns=0, end_ns=3, elapsed_cycles=3, clock_ns=1,
                       m=1, n=1, k=1, axi_read_beats=1, axi_write_beats=1)
        reset = dict.fromkeys(PROFILE_SIGNALS, 0)
        compute = dict(reset, rst_n=1, act=1, rvalid=1, rready=1, wvalid=1, wready=1)
        tail = dict(reset, rst_n=1)
        result = profile([(0, reset), (1, compute), (2, tail)], metrics)
        validate_profile(result, metrics)
        self.assertTrue(result["verified"])
        self.assertEqual(result["counts"]["reset_or_launch_cycles"], 1)
        self.assertEqual(result["activation_feed_idle_reasons"], {"controller_idle": 1})
        truncated = profile([(0, reset), (1, compute)], metrics)
        with self.assertRaisesRegex(ValueError, "measured_cycles"):
            validate_profile(truncated, metrics)

    def test_conflict_releases_on_completion_and_stall_can_overlap_compute(self):
        base = dict.fromkeys(PROFILE_SIGNALS, 0)
        base.update(rst_n=1, rob_space=8, head_valid=1)
        # A LOAD into AB1 remains a blocker for the following MATMUL.
        load = dict(base, issued=1, head_ready=1, head_pc=0x100,
                    head_inst=0x0400002b, writeAbData=2)
        multiply = dict(base, candidate=1, head_pc=0x104,
                        head_inst=0x0800002b, readAbData=2, act=1)
        release = dict(multiply, completed=1, completed_pc=0x100,
                       issue_allowed=1, head_ready=1, issued=1)
        metrics = dict(start_ns=0, end_ns=3, clock_ns=1)
        result = profile([(0, load), (1, multiply), (2, release)], metrics)
        stall = result["cpu_head_stall_intervals"][0]
        self.assertEqual(stall["cycles"], 1)
        self.assertEqual(stall["reason"], "register_conflict")
        self.assertEqual(stall["blockers"][0]["pc"], 0x100)
        self.assertEqual(result["cpu_head_during_activation_idle"], {"LOAD:not_stalled": 1})


if __name__ == "__main__":
    unittest.main()
