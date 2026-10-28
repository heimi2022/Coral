#!/usr/bin/env python3
"""Correlate native DDR commands with read requests; no RTL or timing changes."""

import argparse
from bisect import bisect_left
from collections import Counter, defaultdict, deque
import configparser
import json
from pathlib import Path

try:
    from .profile_matrix_dram_trace import distribution
except ImportError:
    from profile_matrix_dram_trace import distribution


def address_decoder(config):
    """Decode the six standard DRAMsim3 address fields for DDR4 BL8."""
    cfg = configparser.ConfigParser()
    cfg.read(config)
    get = cfg.getint
    if cfg.get("dram_structure", "protocol") != "DDR4":
        raise ValueError("Command correlation currently supports DDR4 only")
    burst = get("dram_structure", "BL")
    bus_bytes = get("system", "bus_width") // 8
    fields = dict(ro=get("dram_structure", "rows"),
                  co=get("dram_structure", "columns") // burst,
                  bg=get("dram_structure", "bankgroups"),
                  ba=get("dram_structure", "banks_per_group"),
                  ch=get("system", "channels"))
    rank_bytes = fields["ro"] * fields["co"] * fields["bg"] * fields["ba"] * burst * bus_bytes
    capacity = get("system", "channel_size") * 1024 * 1024
    if capacity % rank_bytes:
        raise ValueError("Nonintegral rank count")
    fields["ra"] = capacity // rank_bytes
    sizes = [burst * bus_bytes, *fields.values()]
    if any(value <= 0 or value & (value - 1) for value in sizes):
        raise ValueError("Address fields must have power-of-two sizes")
    mapping = cfg.get("system", "address_mapping")
    order = [mapping[i:i + 2] for i in range(0, len(mapping), 2)]
    if sorted(order) != sorted(fields):
        raise ValueError("Unknown address mapping")

    def decode(address):
        address //= burst * bus_bytes
        values = {}
        for name in reversed(order):
            values[name] = address % fields[name]
            address //= fields[name]
        return tuple(values[name] for name in ("ch", "ra", "bg", "ba", "ro", "co"))

    return decode, cfg.getfloat("timing", "tCK"), get("timing", "tRFC")


def commands_from(path, tck):
    result = []
    previous = 0
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) != 9:
            raise ValueError("Invalid DDR command record")
        tick, clk = map(int, parts[:2])
        if tick < previous or tick != clk + 1:
            raise ValueError("Invalid native/controller clock alignment")
        previous = tick
        address = tuple(int(value, 0) for value in parts[3:])
        result.append(dict(time_ns=tick * tck, kind=parts[2], address=address))
    if not result:
        raise ValueError("Empty command trace; library observation hook did not run")
    return result


def analyze(command_path, read_path, config, stats_path):
    decode, tck, trfc = address_decoder(config)
    commands = commands_from(command_path, tck)
    counts = Counter(command["kind"] for command in commands)
    stats = json.loads(Path(stats_path).read_text())
    for kinds, field in ((('read', 'read_p'), 'num_read_cmds'),
                         (('write', 'write_p'), 'num_write_cmds'),
                         (('refresh',), 'num_ref_cmds')):
        expected = sum(channel[field] for channel in stats.values())
        if sum(counts[kind] for kind in kinds) != expected:
            raise ValueError(f"Command trace differs from DRAMsim3 statistics: {field}")

    requests, reads = {}, {}
    ended = False
    for line in Path(read_path).read_text().splitlines():
        event = json.loads(line)
        kind = event["event"]
        if kind == "ar":
            requests[event["request"]] = event
        elif kind in ("submit", "done"):
            key = event["request"], event["beat"]
            row = reads.setdefault(key, dict(request=key[0], beat=key[1]))
            row[kind + "_ns"] = event["time_ns"]
        elif kind == "end":
            ended = True
    if not ended or not reads:
        raise ValueError("Incomplete read trace")
    pending = defaultdict(deque)
    for row in sorted(reads.values(), key=lambda row: row["submit_ns"]):
        row["address"] = requests[row["request"]]["address"] + row["beat"] * 64
        row["ddr_address"] = decode(row["address"])
        pending[row["ddr_address"]].append(row)
    for command in commands:
        if command["kind"] in ("read", "read_p"):
            queue = pending[command["address"]]
            if not queue or queue[0]["submit_ns"] > command["time_ns"]:
                raise ValueError("Unmatched physical READ; coalescing/forwarding is not supported")
            queue.popleft()["issue_ns"] = command["time_ns"]
    if any(pending.values()):
        raise ValueError("Reads without physical READ; coalescing/forwarding is not supported")

    writes = [c["time_ns"] for c in commands if c["kind"] in ("write", "write_p")]
    refreshes = [c for c in commands if c["kind"] == "refresh"]
    # Runs count physical WRITE commands between successive physical READs.
    runs, current = [], []
    for command in commands:
        if command["kind"] in ("write", "write_p"):
            current.append(command["time_ns"])
        elif command["kind"] in ("read", "read_p") and current:
            runs.append(dict(writes=len(current), first_ns=current[0], last_ns=current[-1]))
            current = []
    if current:
        runs.append(dict(writes=len(current), first_ns=current[0], last_ns=current[-1]))

    for row in reads.values():
        start, stop = row["submit_ns"], row["issue_ns"]
        if not start <= stop <= row["done_ns"]:
            raise ValueError("Nonmonotonic physical READ timing")
        row["submit_to_issue_ns"] = stop - start
        row["issue_to_done_ns"] = row["done_ns"] - stop
        row["writes_while_waiting"] = bisect_left(writes, stop) - bisect_left(writes, start)
        # Refreshes on another rank do not directly block this rank.
        row["same_rank_refresh_overlap_ns"] = sum(
            max(0, min(stop, c["time_ns"] + trfc * tck) - max(start, c["time_ns"]))
            for c in refreshes if c["address"][1] == row["ddr_address"][1])
    rows = list(reads.values())
    slow = [row for row in rows if row["done_ns"] - row["submit_ns"] >= 200]
    return dict(
        command_source=str(Path(command_path).resolve()), command_counts=dict(counts),
        read_beats=len(rows), tck_ns=tck,
        latency_ns={name: distribution([row[name] for row in rows])
                    for name in ("submit_to_issue_ns", "issue_to_done_ns")},
        slow_reads_ge_200ns=len(slow),
        slow_reads_with_writes=sum(row["writes_while_waiting"] > 0 for row in slow),
        slow_reads_with_same_rank_refresh=sum(row["same_rank_refresh_overlap_ns"] > 0 for row in slow),
        largest_write_runs=sorted(runs, key=lambda row: row["writes"], reverse=True)[:10],
        slowest_reads=sorted(rows, key=lambda row: row["submit_to_issue_ns"], reverse=True)[:10],
        interpretation=[
            "Commands and counts are checked against the native library statistics.",
            "submit_to_issue includes controller queueing and DRAM timing constraints.",
            "Write/refresh overlap shows correlation, not a causal stall-cycle breakdown.",
            "Write runs count WRITE commands between READ commands; other commands may intervene.",
            "Write callbacks may precede physical WRITE; unissued buffered writes are not counted."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commands", type=Path)
    parser.add_argument("--reads", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--stats", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.commands, args.reads, args.config, args.stats)
    except (ValueError, KeyError) as error:
        parser.exit(1, f"Invalid/incomplete DDR command trace: {error}\n")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("DDR commands:", result["command_counts"])
    for name, value in result["latency_ns"].items():
        print(f"  {name}: mean={value['mean']:.3f} ns, p95={value['p95']:.3f} ns, max={value['max']:.3f} ns")
    print(f"Slow reads >=200 ns: {result['slow_reads_ge_200ns']}; "
          f"overlapping writes: {result['slow_reads_with_writes']}; "
          f"same-rank refresh: {result['slow_reads_with_same_rank_refresh']}")
    print("DDR command profile:", args.output)


if __name__ == "__main__":
    main()
