#!/usr/bin/env python3
"""Compare write-drain scheduling with isolated DRAMsim3 processes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from coralnpu_test_utils.dramsim3 import Dramsim3


def run_probe(library, config, output):
    memory = Dramsim3(library, config, output, 2.0)
    read_tags = {("read", index) for index in range(32)}
    read_done_ns = {}
    write_total = 32
    try:
        for index in range(write_total):
            if not memory.submit(0x80100000 + index * 64, True, ("write", index)):
                raise AssertionError("Could not prefill the DRAM write buffer")
        for _ in range(8):
            memory.advance()

        read_start_ns = memory.axi_cycles * memory.axi_clock_ns
        for index, tag in enumerate(sorted(read_tags)):
            if not memory.submit(0x80000000 + index * 64, False, tag):
                raise AssertionError("Could not enqueue the read burst")

        for _ in range(6000):
            memory.advance()
            for is_write, context, done_ns in memory.last_completions:
                if not is_write:
                    read_done_ns[context] = done_ns
            if write_total < 1024 and memory.submit(
                    0x80100000 + write_total * 64, True, ("write", write_total)):
                write_total += 1
        if memory.pending:
            raise AssertionError(f"DRAM transactions did not drain: {memory.pending}")
        if write_total != 1024 or memory.completed != dict(read=32, write=1024):
            raise AssertionError(f"Incorrect completion counts: {memory.completed}")
        if set(read_done_ns) != read_tags:
            raise AssertionError(f"Read completions missing: {read_tags - set(read_done_ns)}")

        latencies = sorted(done - read_start_ns for done in read_done_ns.values())
        summary = dict(
            read_count=len(latencies), write_count=write_total,
            read_latency_ns=dict(
                mean=statistics.mean(latencies),
                p50=latencies[(len(latencies) - 1) // 2],
                p95=latencies[(95 * len(latencies) + 99) // 100 - 1],
                max=latencies[-1]),
            simulated_axi_cycles=memory.axi_cycles,
            completed=dict(memory.completed), pending=memory.summary()["pending"])
        return summary
    finally:
        memory.close()


def worker(args):
    result = run_probe(args.library, args.config, args.output)
    Path(args.result).write_text(json.dumps(result, indent=2) + "\n")


def compare(args):
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases = dict(bundled=args.bundled, rebuilt_baseline=args.rebuilt_baseline,
                 write16=args.write16)
    reports = {}
    for name, bridge in cases.items():
        result_path = output / f"{name}.json"
        subprocess.run([
            sys.executable, str(Path(__file__).resolve()), "worker",
            "--library", bridge, "--config", args.config,
            "--output", str(output / name), "--result", str(result_path)],
            check=True, env=os.environ.copy())
        reports[name] = json.loads(result_path.read_text())

    baseline = reports["rebuilt_baseline"]["read_latency_ns"]
    experimental = reports["write16"]["read_latency_ns"]
    bundled = reports["bundled"]["read_latency_ns"]
    command_digests = {}
    for name in cases:
        trace = output / name / "ddr_commands.trace"
        if not trace.is_file() or trace.stat().st_size == 0:
            raise SystemExit("Build the comparison bridges with CORAL_DRAMSIM3_COMMAND_TRACE=1")
        command_digests[name] = hashlib.sha256(trace.read_bytes()).hexdigest()
    exact_control_match = (reports["bundled"] == reports["rebuilt_baseline"] and
                           command_digests["bundled"] == command_digests["rebuilt_baseline"])
    result = dict(cases=reports,
                  command_trace_sha256=command_digests,
                  bundled_matches_rebuilt_baseline=exact_control_match,
                  write16_p95_reduction_percent=round(
                      100 * (baseline["p95"] - experimental["p95"]) / baseline["p95"], 2),
                  write16_mean_reduction_percent=round(
                      100 * (baseline["mean"] - experimental["mean"]) / baseline["mean"], 2))
    report_path = output / "comparison.json"
    report_path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if not exact_control_match:
        print("WARNING: bundled and rebuilt upstream baselines differ; use the rebuilt baseline for GEMM A/B.")
    if experimental["p95"] >= baseline["p95"]:
        raise SystemExit("Write-drain experiment did not reduce read P95 in the contention probe")
    print("PASS: all requests completed and write16 reduced read-tail latency")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    comparison = subparsers.add_parser("compare")
    comparison.add_argument("--bundled", required=True)
    comparison.add_argument("--rebuilt-baseline", required=True)
    comparison.add_argument("--write16", required=True)
    comparison.add_argument("--config", required=True)
    comparison.add_argument("--output", required=True)
    comparison.set_defaults(func=compare)
    child = subparsers.add_parser("worker")
    child.add_argument("--library", required=True)
    child.add_argument("--config", required=True)
    child.add_argument("--output", required=True)
    child.add_argument("--result", required=True)
    child.set_defaults(func=worker)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
