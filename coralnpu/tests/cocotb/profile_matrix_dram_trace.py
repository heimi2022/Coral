#!/usr/bin/env python3
"""Analyze optional DRAMsim3 AXI read events, without a VCD or third-party deps."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path


def distribution(values):
    ordered = sorted(values)
    return {"mean": sum(values) / len(values),
            "p50": ordered[math.ceil(len(values) * 0.50) - 1],
            "p95": ordered[math.ceil(len(values) * 0.95) - 1],
            "max": ordered[-1]}


def analyze(path):
    with Path(path).open() as source:
        return analyze_lines(source, path)


def analyze_lines(source, path):
    meta = None
    end = None
    requests = {}
    beats = {}
    for line in source:
        event = json.loads(line)
        kind = event["event"]
        if end is not None:
            raise ValueError("Events after end marker")
        if kind == "meta":
            if meta is not None or requests or event["version"] != 1:
                raise ValueError("Invalid trace metadata")
            meta = event
        elif kind == "end":
            end = event
        else:
            if meta is None:
                raise ValueError("Missing trace metadata")
            request = event["request"]
            if kind == "ar":
                if request in requests:
                    raise ValueError("Duplicate AR request")
                requests[request] = event
                for beat in range(event["beats"]):
                    beats[request, beat] = {"ar": event["time_ns"]}
            else:
                if kind not in ("submit", "done", "offer", "r"):
                    raise ValueError(f"Unknown event: {kind}")
                key = (request, event["beat"])
                if key not in beats or kind in beats[key]:
                    raise ValueError(f"Unknown beat or duplicate stage: {key}, {kind}")
                beats[key][kind] = event["time_ns"]
                if kind == "done":
                    beats[key]["observed"] = event["observed_ns"]
    if meta is None or end is None or not beats:
        raise ValueError("Missing metadata/end marker or empty trace; run may be incomplete")

    stages = {"ar_to_submit": [], "submit_to_backend_done": [],
              "callback_poll_delay": [], "observed_to_offer": [],
              "offer_to_handshake": [], "ar_to_handshake": []}
    rows = []
    for (request, beat), times in beats.items():
        names = ("ar", "submit", "done", "observed", "offer", "r")
        if any(name not in times for name in names):
            raise ValueError(f"Incomplete read beat: request={request}, beat={beat}")
        if any(times[b] < times[a] - 1e-9 for a, b in zip(names, names[1:])):
            raise ValueError(f"Nonmonotonic read timing: request={request}, beat={beat}")
        pairs = zip(stages, (("ar", "submit"), ("submit", "done"),
                             ("done", "observed"), ("observed", "offer"),
                             ("offer", "r"), ("ar", "r")))
        delays = {name: times[b] - times[a] for name, (a, b) in pairs}
        for name, delay in delays.items():
            stages[name].append(delay)
        rows.append(dict(request=request, beat=beat,
                         address=requests[request]["address"] + beat * 64,
                         times_ns=times, delays_ns=delays))
    counts = end["cycles"]
    partition = ("r_handshake", "r_backpressure", "no_pending_read",
                 "head_ready_no_rvalid", "head_backend_pending", "head_not_submitted")
    if counts.get("total", 0) != sum(counts.get(name, 0) for name in partition):
        raise ValueError("Read channel cycle counts do not sum to total")
    if counts.get("r_handshake", 0) != len(beats):
        raise ValueError("Read handshake count differs from completed beat count")
    ar_order = sorted(requests, key=lambda req: requests[req]["time_ns"])
    completion_order = sorted(beats, key=lambda key: beats[key]["r"])
    expected_order = [(req, beat) for req in ar_order for beat in range(requests[req]["beats"])]
    if completion_order != expected_order:
        raise ValueError("AXI read responses did not retain request/beat order")
    first_ar = min(row["ar"] for row in beats.values())
    last_r = max(row["r"] for row in beats.values())
    return dict(
        source=str(Path(path).resolve()), clock_ns=meta["clock_ns"],
        read_requests=len(requests), read_beats=len(beats),
        first_ar_ns=first_ar, last_r_ns=last_r,
        latency_ns={name: distribution(values) for name, values in stages.items()},
        cycles=dict(Counter({name: 0 for name in partition}) | Counter(counts)),
        slowest_reads=sorted(rows, key=lambda row: row["delays_ns"]["ar_to_handshake"],
                             reverse=True)[:10],
        interpretation=[
            "Per-beat latency distributions are not additive wall-clock stall totals.",
            "head_wait_with_later_beat_ready is a subset of head waiting cycles.",
            "observed_to_offer includes ordered response waiting and adapter scheduling.",
            "offer_to_handshake includes half an AXI period even without backpressure.",
            "Backend latency includes queueing, bank/row timing, refresh and read/write competition; "
            "this trace does not separate those physical causes."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.trace)
    except (ValueError, KeyError) as error:
        parser.exit(1, f"Invalid/incomplete DRAM read trace: {error}\n")
    output = args.output or args.trace.with_name("axi_read_profile.json")
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"DRAM read trace: {result['read_requests']} requests, {result['read_beats']} beats")
    for name, stats in result["latency_ns"].items():
        print(f"  {name}: mean={stats['mean']:.3f} ns, p95={stats['p95']:.3f} ns, "
              f"max={stats['max']:.3f} ns")
    print("Read channel cycles:", result["cycles"])
    if "read_window_full" in result["cycles"]:
        counts = result["cycles"]
        print("Read window capacity cycles:", {
            "full": counts.get("read_window_full", 0),
            "full_with_ar_valid": counts.get("read_window_full_ar_valid", 0),
            "full_with_ar_blocked": counts.get("read_window_full_ar_blocked", 0),
            "full_without_ar_valid": counts.get("read_window_full_without_ar_valid", 0),
            "one_slot_left": counts.get("read_window_one_slot_left", 0),
        })
    print("DRAM read profile:", output)


if __name__ == "__main__":
    main()
