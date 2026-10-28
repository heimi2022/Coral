"""Handshake-based AXI outstanding measurements on small synthetic traces."""

import unittest

from profile_matrix_axi_wave import AXI_SIGNALS, AxiProfile


class AxiProfileTest(unittest.TestCase):
    def analyzer(self, reads=2, writes=2):
        return AxiProfile(dict(start_ns=0, end_ns=100, clock_ns=2,
                               axi_read_beats=reads, axi_write_beats=writes))

    def sample(self, result, ns, **updates):
        signals = dict.fromkeys(AXI_SIGNALS, 0)
        signals.update(rst_n=1, act=0, load_busy=1, store_busy=1)
        signals.update(updates)
        result.sample(ns, signals)

    def test_two_inflight_bursts_with_data_backpressure(self):
        result = self.analyzer()
        self.sample(result, 0, arvalid=1, arready=1, awvalid=1, awready=1)
        self.sample(result, 2, arvalid=1, arready=1, araddr=64,
                    awvalid=1, awready=1, awaddr=64)
        self.sample(result, 4, rvalid=1, rready=0, rlast=1,
                    wvalid=1, wready=0, wlast=1)
        self.sample(result, 6, rvalid=1, rready=1, rlast=1,
                    wvalid=1, wready=1, wlast=1)
        self.sample(result, 8, rvalid=1, rready=1, rlast=1,
                    wvalid=1, wready=1, wlast=1, bvalid=1, bready=1)
        self.sample(result, 10, bvalid=1, bready=1)
        stats = result.finish()
        self.assertEqual(stats["peak_read_outstanding"], 2)
        self.assertEqual(stats["peak_write_outstanding"], 2)
        self.assertEqual(stats["counts"]["r_backpressure"], 1)
        self.assertEqual(stats["counts"]["w_backpressure"], 1)
        self.assertEqual(stats["read"]["bursts"], 2)
        self.assertEqual(stats["write"]["average_address_to_response_cycles"], 4)

    def test_beats_are_not_counted_as_separate_bursts(self):
        result = self.analyzer()
        self.sample(result, 0, arvalid=1, arready=1, arlen=1,
                    awvalid=1, awready=1, awlen=1)
        self.sample(result, 2, rvalid=1, rready=1, wvalid=1, wready=1)
        self.sample(result, 4, rvalid=1, rready=1, rlast=1,
                    wvalid=1, wready=1, wlast=1)
        self.sample(result, 6, bvalid=1, bready=1)
        stats = result.finish()
        self.assertEqual(stats["peak_read_outstanding"], 1)
        self.assertEqual(stats["peak_read_beats_outstanding"], 2)
        self.assertEqual(stats["read"]["beat_counts"], {2: 1})

    def test_reject_wrong_rlast_and_missing_response(self):
        result = self.analyzer()
        self.sample(result, 0, arvalid=1, arready=1, arlen=1)
        with self.assertRaises(AssertionError):
            self.sample(result, 2, rvalid=1, rready=1, rlast=1)
        with self.assertRaises(AssertionError):
            result.finish()

    def test_same_edge_turnover_does_not_inflate_outstanding(self):
        result = self.analyzer()
        self.sample(result, 0, arvalid=1, arready=1,
                    awvalid=1, awready=1, wvalid=1, wready=1, wlast=1)
        self.sample(result, 2, arvalid=1, arready=1, araddr=64,
                    rvalid=1, rready=1, rlast=1,
                    awvalid=1, awready=1, awaddr=64,
                    wvalid=1, wready=1, wlast=1, bvalid=1, bready=1)
        self.sample(result, 4, rvalid=1, rready=1, rlast=1, bvalid=1, bready=1)
        stats = result.finish()
        self.assertEqual(stats["peak_read_outstanding"], 1)
        self.assertEqual(stats["peak_write_outstanding"], 1)


if __name__ == "__main__":
    unittest.main()
