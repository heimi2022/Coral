#!/usr/bin/env python3
"""Probe native DDR timing during full-window, LOAD-blocked activation gaps.

Consumes existing profiles and traces; never runs the RTL simulation.
The native probe must use headers matching the linked DRAMsim3 library.
"""

import argparse
from bisect import bisect_left
from collections import Counter, defaultdict, deque
import json
from pathlib import Path
import subprocess
import tempfile

from profile_matrix_dram_commands import address_decoder, commands_from
from profile_matrix_gemm_dram import read_beats


def match_reads(reads, commands, decode):
    pending = defaultdict(deque)
    for row in sorted(reads, key=lambda r: r["submit"]):
        row["ddr_address"] = decode(row["address"])
        pending[row["ddr_address"]].append(row)
    for command in commands:
        if command["kind"] != "read":
            continue
        queue = pending[command["address"]]
        if not queue:
            raise ValueError("Physical READ has no matching request")
        row = queue.popleft()
        row["issue"] = command["time_ns"]
        if not row["submit"] <= row["issue"] <= row["done"]:
            raise ValueError("Physical READ falls outside request lifetime")
    if any(pending.values()):
        raise ValueError("Request has no physical READ")


def select_queries(wave, dependency, metrics, reads, depth):
    if not all(p.get("verified") for p in (wave, dependency, metrics)):
        raise ValueError("Profiles must be verified")
    if depth < 1 or not reads or any(r["beat"] != 0 for r in reads):
        raise ValueError("Requires positive depth and single-beat reads")
    clock = metrics["clock_ns"]
    offset = dependency["trace_to_sim_offset_ns"]

    def tick(ns):
        result = round(ns / clock)
        if abs(result * clock - ns) > 1e-6:
            raise ValueError("Profile timestamp is off the AXI sampling grid")
        return result

    ar = [r["ar"] + offset for r in reads]
    returned = [r["r"] + offset for r in reads]
    if any(b <= a for values in (ar, returned) for a, b in zip(values, values[1:])):
        raise ValueError("Requires strictly ordered AR and R handshakes")
    ar_set = set(ar)
    idle = {tick(gap["start_ns"]) + i for gap in wave["activation_gaps"]
            for i in range(gap["cycles"])}
    loads = {load["issue_id"]: load for load in dependency["loads"]}
    queries, partition, seen = [], Counter(), set()
    for stall in dependency["stalls"]:
        deps = [loads[i] for i in stall["load_issue_ids"]]
        for cycle in range(tick(stall["start_ns"]), tick(stall["start_ns"]) + stall["cycles"]):
            ns = cycle * clock
            if cycle not in idle or not any(ns < load["last_ar_ns"] for load in deps):
                continue
            accepted = bisect_left(ar, ns)
            completed = bisect_left(returned, ns)
            if accepted - completed != depth or ns in ar_set:
                continue
            if cycle in seen:
                raise ValueError("Overlapping stall intervals double-count a cycle")
            seen.add(cycle)
            row = reads[completed]
            owners = [load for load in deps
                      if load["first_request"] <= row["request"] <= load["last_request"]]
            if len(owners) != 1:
                raise ValueError("Window head does not belong to exactly one blocking LOAD")
            if row["r"] + offset == ns:
                partition["r_handshake"] += 1
            elif row["done"] + offset <= ns:
                partition["backend_done_waiting_axi"] += 1
            elif row["issue"] + offset <= ns:
                partition["read_issued_waiting_backend"] += 1
            else:
                partition["read_not_issued"] += 1
                queries.append(dict(ns=ns, request=row["request"],
                                    address=row["ddr_address"],
                                    load_issue_id=owners[0]["issue_id"], role=owners[0]["role"]))
    return sorted(queries, key=lambda q: q["ns"]), dict(partition)


def analyze(directory, probe, depth):
    def load(name):
        return json.loads((directory / name).read_text())

    metrics = load("gemm_metrics.json")
    dependency = load("gemm_dram_dependency_profile.json")
    wave = load("gemm_wave_profile.json")
    config = directory / "CORAL_DDR4_64GBps_interleaved.ini"
    # Other bandwidth runs use the original config path stored in their metrics.
    if not config.is_file():
        raise ValueError("Expected preserved shared-64GB/s configuration")
    decode, tck, _ = address_decoder(config)
    commands_path = directory / "dramsim3/ddr_commands.trace"
    commands = commands_from(commands_path, tck)
    reads = read_beats(directory / "dramsim3/axi_read_trace.jsonl")
    match_reads(reads, commands, decode)
    queries, partition = select_queries(wave, dependency, metrics, reads, depth)
    offset = dependency["trace_to_sim_offset_ns"]
    with tempfile.TemporaryDirectory(prefix="coral_dram_replay_") as temporary:
        query_path = Path(temporary) / "queries.txt"
        lines = []
        for index, query in enumerate(queries):
            native_tick = (query["ns"] - offset) / tck
            if abs(native_tick - round(native_tick)) > 1e-6 or native_tick < 1:
                raise ValueError("Query is not on a native DDR tick")
            lines.append(" ".join(map(str, [index, round(native_tick) - 1, *query["address"]])))
        query_path.write_text("\n".join(lines) + ("\n" if lines else ""))
        run = subprocess.run([str(probe.resolve()), str(config), str(commands_path),
                              str(query_path), temporary], text=True, capture_output=True)
        if run.returncode:
            raise ValueError(f"Native replay failed: {run.stderr.strip()}")
    records = run.stdout.splitlines()
    if len(records) != len(queries):
        raise ValueError("Probe did not return exactly one row per query")
    categories, origins, by_role, sampled_commands = Counter(), Counter(), Counter(), Counter()
    for index, (record, query) in enumerate(zip(records, queries)):
        query_id, native_clk, category, origin, row, until, issued = record.split()
        if int(query_id) != index:
            raise ValueError("Probe query order mismatch")
        query.update(native_clock=int(native_clk), category=category, timing_origin=origin,
                     open_row=int(row), timing_until=int(until), same_clock_command=issued)
        categories[category] += 1
        origins[f"{category}:{origin}"] += 1
        by_role[f"{query['role']}:{category}"] += 1
        sampled_commands[f"{category}:{issued}"] += 1
    return dict(verified=True, source=str(directory), outstanding_depth=depth,
                native_validation=run.stderr.strip(), full_window_cycles=sum(partition.values()),
                head_partition=partition, physical_readiness_cycles=dict(categories),
                limiting_timing_origins=dict(origins), by_load_role=dict(by_role),
                same_sample_clock_commands=dict(sampled_commands), queries=queries,
                interpretation=[
                    "Queries are AXI cycle samples before commands on the same native clock.",
                    "Native readiness and timing origin describe physical constraints only.",
                    "Ready prerequisites (ACT/PRE) do not mean the READ itself can issue.",
                    "Controller transaction/command queues, arbitration and pending refresh priority are not replayed.",
                    "Counts are observations, not removable cycles or predicted speedup from a larger window."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--depth", type=int, default=16)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = analyze(args.directory.resolve(), args.probe, args.depth)
    output = args.output or args.directory / "gemm_dram_readiness_profile.json"
    output.write_text(json.dumps(result, indent=2) + "\n")
    for key in ("native_validation", "head_partition", "physical_readiness_cycles", "limiting_timing_origins"):
        print(f"{key}: {result[key]}")
    print(f"DDR readiness profile: {output}")


if __name__ == "__main__":
    main()
