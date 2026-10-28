"""Check MatrixCore command overlap and descriptor delivery in a Verilator VCD."""

import argparse
from collections import Counter, deque
import json
from pathlib import Path
import re


TILING = "u_matmul_tiling."
QUEUES = {
    "weight": TILING + "u_weight_block_fifo.",
    "act_psum": TILING + "u_act_psum_block_fifo.",
}
SIGNALS = (
    "clk", "rst_n", "cmd_valid_i", "cmd_ready_o", "cmd_pc_i",
    "cfg_m_i", "cfg_n_i", "cfg_k_i", "done_valid_o", "done_ready_i",
    "done_pc_o", "cmd_decode_busy", TILING + "block_queue_wr_en",
) + tuple(prefix + suffix for prefix in QUEUES.values()
          for suffix in ("full_o", "do_write", "do_read"))


def rising_samples(source, signal_names=SIGNALS, scope_name="u_pe_ctrl"):
    """Sample stable values before each edge, regardless of VCD update order."""
    scopes, bindings, units = [], {}, ""
    in_timescale = False
    for line in source:
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "$timescale":
            in_timescale = True
        if in_timescale:
            units += " ".join(fields) + " "
            if "$end" in fields:
                in_timescale = False
        if fields[0] == "$scope":
            scopes.append(fields[2])
        elif fields[0] == "$upscope":
            scopes.pop()
        elif fields[0] == "$var" and scope_name in scopes:
            index = scopes.index(scope_name)
            name = ".".join(scopes[index + 1:] + [fields[4]])
            if name in signal_names:
                key = tuple(scopes[:index + 1])
                bindings.setdefault(key, {})[name] = fields[3]
        elif fields[0] == "$enddefinitions":
            break
    if len(bindings) != 1:
        raise ValueError(f"Expected exactly one {scope_name} in the VCD")
    names = next(iter(bindings.values()))
    missing = set(signal_names) - names.keys()
    if missing:
        raise ValueError(f"Missing waveform signals: {sorted(missing)}")
    scale = re.search(r"(\d+)\s*(s|ms|us|ns|ps|fs)\b", units)
    if scale is None:
        raise ValueError("Missing or unsupported VCD timescale")
    ns_per_tick = int(scale[1]) * {
        "s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1, "ps": 1e-3, "fs": 1e-6,
    }[scale[2]]
    wanted = set(names.values())
    clock = names[next(name for name in signal_names if name.split(".")[-1] in ("clk", "clock"))]
    values, updates, timestamp = {}, {}, 0

    def snapshot():
        if values.get(clock) == 0 and updates.get(clock) == 1:
            return timestamp * ns_per_tick, {
                name: values.get(ident) for name, ident in names.items()
            }
        return None

    for line in source:
        line = line.strip()
        if not line:
            continue
        if line[0] == "#":
            sample = snapshot()
            if sample is not None:
                yield sample
            values.update(updates)
            updates.clear()
            timestamp = int(line[1:])
        elif line[0] in "bB":
            bits, ident = line[1:].split()
            if ident in wanted:
                updates[ident] = None if set(bits.lower()) & set("xz") else int(bits, 2)
        elif line[0] in "01xXzZ":
            ident = line[1:]
            if ident in wanted:
                updates[ident] = int(line[0]) if line[0] in "01" else None
    sample = snapshot()
    if sample is not None:
        yield sample


def analyze(samples, min_inflight=3, expected_commands=None):
    pending, accepts, completions = deque(), [], []
    counts, violations = Counter(), Counter()
    examples = []
    peak, expected_pairs = 0, 0

    def check(condition, message, ns):
        if not condition:
            violations[message] += 1
            if len(examples) < 12:
                examples.append({"ns": ns, "error": message})

    for ns, s in samples:
        if s["rst_n"] == 0:
            check(not pending, "Reset with commands still outstanding", ns)
            continue
        if any(value is None for value in s.values()):
            raise ValueError(f"Unknown required signal before edge at {ns:g} ns")
        counts["observed_cycles"] += 1
        if s["done_valid_o"] and s["done_ready_i"]:
            pc = s["done_pc_o"]
            completions.append({"pc": pc, "ns": ns})
            check(bool(pending) and pending[0] == pc,
                  "Completion PC does not match oldest accepted command", ns)
            if pending:
                pending.popleft()
        if s["cmd_valid_i"] and s["cmd_ready_o"]:
            pc = s["cmd_pc_i"]
            m, n, k = (s[f"cfg_{axis}_i"] for axis in "mnk")
            check(all(1 <= dim <= 64 for dim in (m, n, k)),
                  "Accepted command has invalid tile dimensions", ns)
            pending.append(pc)
            accepts.append({"pc": pc, "ns": ns, "m": m, "n": n, "k": k})
            expected_pairs += ((n + 31) // 32) * ((k + 31) // 32)
        peak = max(peak, len(pending))
        counts["cycles_with_multiple_outstanding_commands"] += len(pending) >= 2
        counts["upstream_blocked_cycles"] += bool(s["cmd_valid_i"] and not s["cmd_ready_o"])
        write_pair = s[TILING + "block_queue_wr_en"]
        writes = []
        for label, prefix in QUEUES.items():
            full, write = s[prefix + "full_o"], s[prefix + "do_write"]
            writes.append(write)
            counts[label + "_writes"] += write
            counts[label + "_reads"] += s[prefix + "do_read"]
            check(not (write_pair and full), "Descriptor write attempted while FIFO full", ns)
        check(writes[0] == writes[1] == write_pair,
              "Weight and act/psum descriptors were not written together", ns)
        if s["cmd_decode_busy"] and any(s[p + "full_o"] for p in QUEUES.values()):
            counts["fill_stalled_cycles"] += 1
            check(not write_pair and not s["cmd_ready_o"],
                  "Full descriptor FIFO did not backpressure command expansion", ns)

    check(not pending, "Accepted commands did not all complete", None)
    check(len(accepts) > 0, "No commands were accepted", None)
    check(peak >= min_inflight, "Required command overlap was not reached", None)
    if expected_commands is not None:
        check(len(accepts) == expected_commands,
              "Accepted command count differs from retired MATMUL count", None)
    for label in QUEUES:
        check(counts[label + "_writes"] == counts[label + "_reads"] == expected_pairs,
              f"{label} descriptor count differs from accepted command shapes", None)
    first_three = accepts[:3]
    return {
        "measurement": "pe_ctrl command accept through completion handshake; not CPU dispatch or ROB retirement",
        "accepted_commands": len(accepts), "completed_commands": len(completions),
        "peak_accepted_uncompleted_matmuls": peak,
        "expected_descriptor_pairs": expected_pairs,
        "first_three_accepts": first_three,
        "first_accept_gaps_ns": [b["ns"] - a["ns"]
                                 for a, b in zip(first_three, first_three[1:])],
        "first_completion": completions[0] if completions else None,
        "counts": dict(counts), "violations": dict(violations),
        "violation_examples": examples, "verified": not violations,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vcd", type=Path)
    parser.add_argument("--metrics", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--min-inflight", type=int, default=3)
    args = parser.parse_args()
    expected = None
    if args.metrics:
        metrics = json.loads(args.metrics.read_text())
        if not metrics["verified"]:
            parser.error("GEMM functional verification did not pass")
        expected = metrics["retired_matrix_instructions"]["MATMUL"]
    with args.vcd.open() as source:
        result = analyze(rising_samples(source), args.min_inflight, expected)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["verified"] else 1)


if __name__ == "__main__":
    main()
