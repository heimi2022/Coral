#!/usr/bin/env python3
"""Join verified GEMM waveform stalls to individual DRAM-backed LOADs.

This measures observed dependencies, not the speedup from removing them.
Only aligned, at-most-64-byte A/B data and scale rows are supported.
"""

import argparse
from collections import Counter, defaultdict, deque
import json
from pathlib import Path

from profile_matrix_dram_trace import analyze as validate_reads


LOAD_ROLES = {0: "A", 1: "B", 8: "A_scale", 9: "B_scale"}


def read_beats(path):
    validate_reads(path)
    requests, beats = {}, {}
    for line in Path(path).read_text().splitlines():
        event = json.loads(line)
        kind = event["event"]
        if kind == "ar":
            requests[event["request"]] = event
            for beat in range(event["beats"]):
                beats[event["request"], beat] = dict(ar=event["time_ns"])
        elif kind in ("submit", "done", "offer", "r"):
            times = beats[event["request"], event["beat"]]
            times[kind] = event["time_ns"]
            if kind == "done":
                times["observed"] = event["observed_ns"]
    rows = [dict(request=req, beat=beat,
                 address=requests[req]["address"] + beat * 64, **times)
            for (req, beat), times in beats.items()]
    return sorted(rows, key=lambda row: row["r"])


def phase(load, ns):
    if ns < load["first_ar_ns"]:
        return "before_first_ar"
    if ns < load["last_ar_ns"]:
        return "ar_issue_in_progress"
    if ns < load["all_backend_done_ns"]:
        return "backend_not_all_done"
    if ns < load["all_observed_ns"]:
        return "callback_poll"
    if ns < load["last_r_ns"]:
        return "backend_done_waiting_axi"
    return "r_returned_waiting_scoreboard_release"


def analyze(wave, metrics, reads):
    if not wave.get("verified") or not metrics.get("verified"):
        raise ValueError("Functional and waveform validation must pass")
    clock = metrics["clock_ns"]
    r_events = [e for e in wave["events"] if e["event"] == "AXI_R"]
    if len(reads) != len(r_events) or len(reads) != metrics["axi_read_beats"] or not reads:
        raise ValueError("Waveform/DRAM read counts differ or AXI_R events are missing")
    offset = r_events[0]["ns"] - reads[0]["r"]
    if any(abs(e["ns"] - row["r"] - offset) > 1e-6
           for e, row in zip(r_events, reads)):
        raise ValueError("Waveform/DRAM read handshakes do not share a constant clock offset")

    issued, accepted = defaultdict(deque), defaultdict(deque)
    loads, by_id = [], {}
    for event in wave["events"]:
        kind, pc = event["event"], event["pc"]
        if kind == "ISSUE_LOAD":
            issued[pc].append(event)
        elif kind == "DMA_ACCEPT" and event["op"] in LOAD_ROLES:
            if not issued[pc]:
                raise ValueError(f"DMA LOAD without matching dispatch: {pc:#x}")
            issue = issued[pc].popleft()
            load = dict(event, issue_id=issue["issue_id"], issue_ns=issue["ns"],
                        role=LOAD_ROLES[event["op"]])
            if load["issue_id"] in by_id:
                raise ValueError("Duplicate LOAD occurrence ID")
            loads.append(load)
            by_id[load["issue_id"]] = load
            accepted[pc].append(load)
        elif kind == "COMPLETE" and accepted[pc]:
            accepted[pc].popleft()["scoreboard_release_ns"] = event["ns"]
    if any(issued.values()) or any(accepted.values()) or not loads:
        raise ValueError("Unmatched or incomplete LOADs; unsupported operation or truncated waveform")
    if len(loads) != metrics["retired_matrix_instructions"]["LOAD"]:
        raise ValueError("DMA LOAD count differs from functional metrics")

    cursor = 0
    for load in loads:
        row_bytes = load["cols"] << load["elem_bytes_log2"]
        if not (0 < row_bytes <= 64 and load["rows"] > 0
                and load["base"] % 64 == 0 and load["stride"] % 64 == 0):
            raise ValueError("Only aligned LOADs with at-most-64-byte rows are supported")
        part = reads[cursor:cursor + load["rows"]]
        expected = [load["base"] + r * load["stride"] for r in range(load["rows"])]
        if [row["address"] for row in part] != expected or any(row["beat"] for row in part):
            raise ValueError(f"LOAD/AR address order mismatch at occurrence {load['issue_id']}")
        if part[0]["ar"] + offset < load["ns"]:
            raise ValueError("AR preceded DMA command acceptance")
        load.update(first_request=part[0]["request"], last_request=part[-1]["request"],
                    first_ar_ns=part[0]["ar"] + offset,
                    last_ar_ns=part[-1]["ar"] + offset,
                    all_backend_done_ns=max(row["done"] for row in part) + offset,
                    all_observed_ns=max(row["observed"] for row in part) + offset,
                    last_r_ns=part[-1]["r"] + offset,
                    tail_beat_times_ns={key: part[-1][key] + offset
                                        for key in ("ar", "submit", "done", "observed", "offer", "r")})
        if load["last_r_ns"] > load["scoreboard_release_ns"]:
            raise ValueError("Scoreboard released LOAD before its last R handshake")
        cursor += len(part)
    if cursor != len(reads):
        raise ValueError("Read beats left over after matching all DMA LOADs")

    phases, intervals = Counter(), []
    total_stalls = idle_stalls = also_non_load = 0
    for stall in wave["cpu_head_stall_intervals"]:
        if stall["kind"] != "MATMUL" or stall["reason"] != "register_conflict":
            continue
        blockers = [b for b in stall["blockers"] if b["kind"] == "LOAD"]
        if not blockers:
            continue
        dependencies = [by_id[b["issue_id"]] for b in blockers]
        stop = stall["start_ns"] + stall["cycles"] * clock
        if any(load["issue_ns"] > stall["start_ns"] or
               load["scoreboard_release_ns"] < stop - clock for load in dependencies):
            raise ValueError("LOAD lifetime does not cover its scoreboard stall")
        total_stalls += stall["cycles"]
        local = Counter()
        for gap in wave["activation_gaps"]:
            start = max(stall["start_ns"], gap["start_ns"])
            end = min(stop, gap["start_ns"] + gap["cycles"] * clock)
            for cycle in range(max(0, round((end - start) / clock))):
                ns = start + cycle * clock
                label = " + ".join(sorted(load["role"] + ":" + phase(load, ns)
                                          for load in dependencies))
                local[label] += 1
        idle = sum(local.values())
        idle_stalls += idle
        if len(blockers) < len(stall["blockers"]):
            also_non_load += idle
        phases.update(local)
        intervals.append(dict(pc=stall["pc"], start_ns=stall["start_ns"],
                              cycles=stall["cycles"], activation_idle_cycles=idle,
                              load_issue_ids=[load["issue_id"] for load in dependencies],
                              also_non_load_blocker=len(blockers) < len(stall["blockers"]),
                              joint_phases=dict(local)))
    return dict(verified=True, trace_to_sim_offset_ns=offset, matched_loads=len(loads),
                matched_read_beats=len(reads),
                load_blocked_matmul_head_cycles=total_stalls,
                load_blocked_matmul_activation_idle_cycles=idle_stalls,
                activation_idle_cycles_also_with_non_load_blocker=also_non_load,
                joint_load_phases_during_activation_idle=dict(phases),
                stalls=intervals, loads=loads,
                interpretation=[
                    "LOAD occurrence IDs distinguish repeated PCs and register reuse.",
                    "Idle means no activation feed; it does not mean all PEs are idle.",
                    "Joint phase counts partition the observed LOAD-blocked MATMUL head cycles "
                    "during activation idle; multiple blockers are counted once per cycle.",
                    "backend_not_all_done may overlap ordered AXI waiting; it is not a "
                    "counterfactual DDR speedup or an attribution to a specific DDR command.",
                    "before_first_ar/ar_issue_in_progress can include older LOADs and AXI "
                    "outstanding limits; r_returned includes DMA and completion arbitration.",
                    "Prefetches blocked behind earlier scalar instructions or STOREs are "
                    "outside this subset; use the complete waveform head-stall report too."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wave-profile", type=Path, required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    parser.add_argument("--reads", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(json.loads(args.wave_profile.read_text()),
                         json.loads(args.metrics.read_text()), read_beats(args.reads))
    except (ValueError, KeyError) as error:
        parser.exit(1, f"Cannot correlate GEMM/DRAM trace: {error}\n")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("GEMM/DRAM matched LOADs:", result["matched_loads"])
    print("LOAD-blocked MATMUL head cycles during activation idle:",
          result["load_blocked_matmul_activation_idle_cycles"])
    print("Joint LOAD phases:", result["joint_load_phases_during_activation_idle"])
    print("GEMM/DRAM correlation:", args.output)


if __name__ == "__main__":
    main()
