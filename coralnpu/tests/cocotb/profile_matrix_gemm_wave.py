"""Attribute activation-feed gaps using an existing MatrixCoreMiniAxi VCD.

These counters describe signals observed in this run, not counterfactual speedups.
CPU stalls and DMA work can overlap useful PE work and are reported separately.
"""

import argparse
from collections import Counter
import csv
import gzip
import json
from pathlib import Path

from analyze_matrix_gemm_wave import rising_samples


PE = "core.matrixCore.matrixCore.u_pe_ctrl."
MC = "core.matrixCore.matrixCore."
DMA = MC + "dma."
DISPATCH = "core.score.dispatch."
SB = DISPATCH + "matrixScoreboard."
SIGNALS = {
    "clk": PE + "clk",
    "rst_n": PE + "rst_n",
    "state": PE + "state",
    "act": PE + "rs1_read_valid_o",
    "act_return": PE + "rs1_data_valid_i",
    "weight": PE + "rs2_read_valid_o",
    "stream_count": PE + "stream_count",
    "stream_a": PE + "rs1_o",
    "stream_c": PE + "stream_rd",
    "stream_kblock": PE + "rs1_col_o",
    "bubble": PE + "stream_boundary_bubble_q",
    "pending": PE + "stream_start_pending_q",
    "stream_active": PE + "stream_active",
    "next_stream_ready": PE + "next_stream_ready",
    "weight_busy": PE + "weight_banks_busy_q",
    "weight_empty": PE + "tiling_weight_empty",
    "weight_overlap_done": PE + "weight_overlap_done",
    "stream_overlap_done": PE + "stream_overlap_done",
    "weight_bank_available": PE + "weight_bank_available",
    "cmd_valid": PE + "cmd_valid_i",
    "cmd_ready": PE + "cmd_ready_o",
    "cmd_pc": PE + "cmd_pc_i",
    "done_valid": PE + "done_valid_o",
    "done_ready": PE + "done_ready_i",
    "done_pc": PE + "done_pc_o",
    "mem_valid": MC + "mem_valid_i",
    "mem_ready": MC + "mem_ready_o",
    "mem_pc": MC + "mem_pc_i",
    "mem_op": MC + "mem_op_i",
    "mem_reg": MC + "mem_reg_i",
    "mem_base": MC + "mem_base_i",
    "mem_rows": MC + "mem_rows_w",
    "mem_cols": MC + "mem_cols_w",
    "mem_scale": MC + "mem_ab_scale_sel_w",
    "mem_stride": MC + "mem_stride_w",
    "mem_elem_bytes": MC + "mem_elem_bytes_w",
    "load_busy": DMA + "load_busy_w",
    "store_busy": DMA + "store_busy_w",
    "load_done": DMA + "load_done_valid_w",
    "load_done_pc": DMA + "load_done_pc_w",
    "store_done": DMA + "store_done_valid_w",
    "store_done_pc": DMA + "store_done_pc_w",
    "rvalid": DMA + "m_axi_rvalid_i",
    "rready": DMA + "m_axi_rready_o",
    "wvalid": DMA + "m_axi_wvalid_o",
    "wready": DMA + "m_axi_wready_i",
    "head_valid": DISPATCH + "io_inst_0_valid",
    "head_ready": DISPATCH + "io_inst_0_ready",
    "head_pc": DISPATCH + "io_inst_0_bits_addr",
    "head_inst": DISPATCH + "io_inst_0_bits_inst",
    "rob_space": DISPATCH + "io_retirement_buffer_nSpace",
    "mem_pending": DISPATCH + "io_matrixMemPending",
    "mem_dispatch_ready": DISPATCH + "io_matrixMem_ready",
    "candidate": SB + "io_candidateValid",
    "issue_allowed": SB + "io_issueAllowed",
    "sb_count": SB + "count_q",
    "issued": SB + "io_issued_valid",
    "completed": SB + "io_completed_valid",
    "completed_pc": SB + "io_completed_bits",
}
MASKS = ("readAbData", "writeAbData", "readAbScale", "writeAbScale", "readC", "writeC")
SIGNALS.update((name, SB + "io_candidate_" + name) for name in MASKS)


def instruction_kind(inst):
    if (inst & 0x7f) != 0x2b:
        return "SCALAR"
    uop = (inst >> 26) & 3
    if uop == 1:
        return "STORE" if (inst >> 25) & 1 else "LOAD"
    return {0: "CONFIG", 2: "MATMUL", 3: "MZERO"}[uop]


def conflicts(older, current):
    for data in ("AbData", "AbScale", "C"):
        if data == "C" and older["kind"] == current["kind"] == "MATMUL":
            continue
        rd, wr = "read" + data, "write" + data
        if older[wr] & (current[rd] | current[wr]) or older[rd] & current[wr]:
            return True
    return False


def profile(samples, metrics):
    counts, idle_reasons, stalls = Counter(), Counter(), Counter()
    idle_head = Counter()
    active, events, blocks, gaps, stall_intervals = [], [], [], [], []
    gap, stall = None, None
    first_sample = True
    next_issue_id = 0
    for ns, s in samples:
        if first_sample:
            # pe_ctrl's clock starts after the test's execute_from timestamp.
            # Keep this initial gap separate from observed controller states.
            counts["launch_before_first_clock_edge"] = max(
                0, round((ns - metrics["start_ns"]) / metrics["clock_ns"]))
            first_sample = False
        measured = metrics["start_ns"] <= ns < metrics["end_ns"]
        if measured:
            counts["cycles"] += 1
        if s["rst_n"] != 1:
            if measured:
                counts["reset_or_launch_cycles"] += 1
            continue
        # Track scoreboard lifetimes even before the measurement window.
        if s["completed"]:
            for i, item in enumerate(active):
                if item["pc"] == s["completed_pc"]:
                    active.pop(i)
                    break
        kind = instruction_kind(s["head_inst"])
        current = {key: s[key] for key in MASKS}
        current.update(pc=s["head_pc"], kind=kind)
        blockers = [item for item in active if conflicts(item, current)]
        if s["issued"]:
            current["issue_id"] = next_issue_id
            next_issue_id += 1
            active.append(current)
        if not measured:
            continue
        if any(value is None for value in s.values()):
            raise ValueError(f"Unknown signal at {ns} ns")
        cycle = round((ns - metrics["start_ns"]) / metrics["clock_ns"])
        counts["cycles_out_of_reset"] += 1
        for signal in ("act", "act_return", "weight", "load_busy", "store_busy"):
            counts[signal + "_cycles"] += bool(s[signal])
        counts["axi_read_beats"] += bool(s["rvalid"] and s["rready"])
        counts["axi_write_beats"] += bool(s["wvalid"] and s["wready"])
        counts["mem_backpressure"] += bool(s["mem_valid"] and not s["mem_ready"])
        counts["command_backpressure"] += bool(s["cmd_valid"] and not s["cmd_ready"])

        reason = "not_stalled"
        if s["head_valid"] and not s["head_ready"]:
            if s["candidate"] and not s["issue_allowed"]:
                reason = ("register_conflict" if blockers else "scoreboard_capacity")
            elif s["rob_space"] == 0:
                reason = "rob_full"
            elif kind in ("LOAD", "STORE") and not s["mem_dispatch_ready"]:
                reason = "memory_command_staging"
            else:
                reason = "other_cpu_interlock"
            stalls[(kind, reason)] += 1
        stall_key = (s["head_pc"], reason, tuple(item["issue_id"] for item in blockers))
        if stall is not None and (reason == "not_stalled" or stall_key != stall["key"]):
            stall_intervals.append({k: v for k, v in stall.items() if k != "key"})
            stall = None
        if reason != "not_stalled":
            if stall is None:
                stall = {"key": stall_key, "start_cycle": cycle, "start_ns": ns,
                         "cycles": 0, "pc": s["head_pc"], "kind": kind,
                         "reason": reason, "access": current,
                         "blockers": blockers}
            stall["cycles"] += 1
        if s["act"] and s["stream_count"] == 0:
            blocks.append({"cycle": cycle, "ns": ns, "a": s["stream_a"],
                           "c": s["stream_c"], "kblock": s["stream_kblock"]})
        if not s["act"]:
            if s["stream_active"] and s["bubble"]:
                idle_reason = "boundary_bubble"
            elif s["stream_active"] and s["pending"] and not s["next_stream_ready"]:
                idle_reason = "minimum_start_spacing"
            elif s["state"] == 0:
                idle_reason = "controller_idle"
            elif s["weight"]:
                idle_reason = "loading_pe_weights"
            elif s["state"] == 2 and s["stream_overlap_done"] and not s["weight_bank_available"]:
                idle_reason = "waiting_for_weight_bank_release"
            else:
                idle_reason = "controller_transition"
            idle_reasons[idle_reason] += 1
            idle_head[(kind if s["head_valid"] else "NO_INSTRUCTION", reason)] += 1
            if gap is None:
                gap = {"start_cycle": cycle, "start_ns": ns, "cycles": 0,
                       "reasons": Counter(), "head_stalls": Counter()}
            gap["cycles"] += 1
            gap["reasons"][idle_reason] += 1
            gap["head_stalls"][f"{kind}:{reason}@{s['head_pc']:#x}"] += 1
        elif gap is not None:
            gaps.append(gap)
            gap = None

        def event(label, pc, **extra):
            events.append({"cycle": cycle, "ns": ns, "event": label, "pc": pc, **extra})

        if s["issued"]:
            event("ISSUE_" + kind, s["head_pc"], issue_id=current["issue_id"],
                  access={key: s[key] for key in MASKS},
                  blockers=[x["pc"] for x in blockers])
        if s["completed"]:
            event("COMPLETE", s["completed_pc"])
        if s["cmd_valid"] and s["cmd_ready"]:
            event("PE_ACCEPT", s["cmd_pc"])
        if s["mem_valid"] and s["mem_ready"]:
            event("DMA_ACCEPT", s["mem_pc"], op=s["mem_op"], reg=s["mem_reg"],
                  base=s["mem_base"], rows=s["mem_rows"], cols=s["mem_cols"],
                  scale=s["mem_scale"], stride=s["mem_stride"],
                  elem_bytes_log2=s["mem_elem_bytes"])
        if s["rvalid"] and s["rready"]:
            event("AXI_R", 0)
    if gap is not None:
        gaps.append(gap)
    if stall is not None:
        stall_intervals.append({k: v for k, v in stall.items() if k != "key"})
    return {
        "measurement": "Pre-edge samples from execute_from to CPU halt; activation feed is not an all-PE occupancy signal",
        "counts": dict(counts),
        "activation_feed_idle_reasons": dict(idle_reasons),
        "cpu_head_stalls_including_overlap_with_compute": {
            f"{kind}:{reason}": n for (kind, reason), n in stalls.items()},
        "cpu_head_during_activation_idle": {
            f"{kind}:{reason}": n for (kind, reason), n in idle_head.items()},
        "activation_blocks": blocks, "activation_gaps": gaps, "events": events,
        "cpu_head_stall_intervals": stall_intervals,
    }


def validate_profile(result, metrics):
    counts = result["counts"]
    m, n, k = (metrics[axis] for axis in "mnk")
    checks = {
        "measured_cycles": (counts.get("cycles", 0) + counts.get("launch_before_first_clock_edge", 0), metrics["elapsed_cycles"]),
        "activation_rows": (counts.get("act_cycles", 0), m * ((n + 31) // 32) * ((k + 31) // 32)),
        "activation_blocks": (len(result["activation_blocks"]), ((m + 63) // 64) * ((n + 31) // 32) * ((k + 31) // 32)),
        "read_beats": (counts.get("axi_read_beats", 0), metrics["axi_read_beats"]),
        "write_beats": (counts.get("axi_write_beats", 0), metrics["axi_write_beats"]),
        "idle_partition": (sum(result["activation_feed_idle_reasons"].values()) + counts.get("act_cycles", 0), counts.get("cycles_out_of_reset", 0)),
    }
    mismatches = {name: {"observed": got, "expected": expected}
                  for name, (got, expected) in checks.items() if got != expected}
    if mismatches:
        raise ValueError(f"Waveform/metrics mismatch: {mismatches}")
    result["verified"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vcd", type=Path)
    parser.add_argument("--metrics", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=Path, help="Optional gzip CSV cache, reused on later invocations")
    args = parser.parse_args()
    metrics = json.loads(args.metrics.read_text())
    if not metrics.get("verified"):
        parser.error("Functional verification must pass before profiling")
    if args.samples and args.samples.exists():
        with gzip.open(args.samples, "rt") as source:
            reader = csv.DictReader(source)
            result = profile(((float(row.pop("ns")), {k: int(v) for k, v in row.items()})
                              for row in reader), metrics)
    else:
        with args.vcd.open() as source:
            samples = rising_samples(source, set(SIGNALS.values()), "MatrixCoreMiniAxi")

            def renamed():
                for ns, values in samples:
                    yield ns, {name: values[path] for name, path in SIGNALS.items()}

            if args.samples:
                with gzip.open(args.samples, "wt") as cache:
                    writer = csv.DictWriter(cache, ["ns", *SIGNALS])
                    writer.writeheader()

                    def cached():
                        for ns, s in renamed():
                            if all(value is not None for value in s.values()):
                                writer.writerow({"ns": ns, **s})
                            yield ns, s

                    result = profile(cached(), metrics)
            else:
                result = profile(renamed(), metrics)
    validate_profile(result, metrics)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items()
                      if key not in ("events", "activation_blocks", "activation_gaps",
                                     "cpu_head_stall_intervals")}, indent=2))
    print(f"Profile: {args.output}")


if __name__ == "__main__":
    main()
