"""Small synthetic checks for the DRAMsim3 read trace analyzer."""

import json
from pathlib import Path
import tempfile
import unittest

from profile_matrix_dram_trace import analyze


class DramTraceProfileTest(unittest.TestCase):
    def write_trace(self, events):
        folder = tempfile.TemporaryDirectory(prefix="coral_dram_trace_")
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "trace.jsonl"
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        return path

    def valid_events(self):
        return [
            dict(event="meta", version=1, clock_ns=2.0),
            dict(event="ar", request=0, beat=0, time_ns=3.0,
                 address=0, beats=1, axi_id=0),
            dict(event="submit", request=0, beat=0, time_ns=4.0),
            dict(event="done", request=0, beat=0, time_ns=22.0, observed_ns=24.0),
            dict(event="offer", request=0, beat=0, time_ns=24.0),
            dict(event="r", request=0, beat=0, time_ns=25.0),
            dict(event="end", cycles=dict(total=2, r_handshake=1,
                 r_backpressure=0, no_pending_read=1, head_ready_no_rvalid=0,
                 head_backend_pending=0, head_not_submitted=0)),
        ]

    def test_stage_latency_and_cycle_classification(self):
        result = analyze(self.write_trace(self.valid_events()))
        self.assertEqual(result["read_requests"], 1)
        self.assertEqual(result["read_beats"], 1)
        self.assertEqual(result["latency_ns"]["submit_to_backend_done"]["mean"], 18)
        self.assertEqual(result["latency_ns"]["callback_poll_delay"]["mean"], 2)
        self.assertEqual(result["cycles"]["no_pending_read"], 1)

    def test_incomplete_trace_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Incomplete read beat"):
            analyze(self.write_trace(self.valid_events()[:-2] + [
                dict(event="end", cycles=dict(total=0))]))

    def test_nonmonotonic_stage_is_rejected(self):
        events = self.valid_events()
        events[5]["time_ns"] = 21.0
        with self.assertRaisesRegex(ValueError, "Nonmonotonic"):
            analyze(self.write_trace(events))

    def test_nonordered_axi_response_is_rejected(self):
        events = self.valid_events()
        # The younger request completes in DRAM first, but returning it first
        # would violate this adapter's declared in-order response policy.
        events.insert(2, dict(event="ar", request=1, beat=0, time_ns=5.0,
                              address=64, beats=1, axi_id=0))
        events[-1]["cycles"] = dict(total=3, r_handshake=2, no_pending_read=1)
        events[-1:-1] = [
            dict(event="submit", request=1, beat=0, time_ns=6.0),
            dict(event="done", request=1, beat=0, time_ns=18.0, observed_ns=18.0),
            dict(event="offer", request=1, beat=0, time_ns=18.0),
            dict(event="r", request=1, beat=0, time_ns=19.0),
        ]
        with self.assertRaisesRegex(ValueError, "did not retain"):
            analyze(self.write_trace(events))


if __name__ == "__main__":
    unittest.main()
