"""Summarize accepted commands, block boundaries and rejected C reads."""

import argparse
from collections import Counter, deque
import csv


def analyze(path):
    with open(path, newline="") as source:
        rows = [{key: float(value) if key == "ns" else int(value)
                 for key, value in row.items()} for row in csv.DictReader(source)]
    pending_blocks = deque()
    commands = []
    blocks = []
    rejected = []
    current = None
    live = set()
    for row in rows:
        if not row["pe.rst_n"]:
            pending_blocks.clear()
            live.clear()
            continue
        if row["pe.cmd_accept"]:
            age = row["pe.cmd_rob_age_i"]
            command = {
                "command": len(commands), "cycle": row["cycle"], "age": age,
                "m": row["pe.cfg_m_i"], "n": row["pe.cfg_n_i"],
                "k": row["pe.cfg_k_i"], "c": row["pe.rd_i"],
                "inflight_before": len(live),
            }
            commands.append(command)
            live.add(age)
            for nblock in range((command["n"] + 31) // 32):
                for kblock in range((command["k"] + 31) // 32):
                    pending_blocks.append({
                        "command": command["command"], "age": age,
                        "nblock": nblock, "kblock": kblock,
                    })
        if row["pe.stream_issue_active"] and row["pe.stream_count"] == 0:
            current = dict(current)
            current["start"] = row["cycle"]
            current["m"] = row["pe.stream_m_rows"]
            blocks.append(current)
        if row["pe.stream_last"]:
            blocks[-1]["end"] = row["cycle"]
        if row["pe.stream_pop"]:
            current = pending_blocks.popleft()
            current["pop"] = row["cycle"]
            current["queued_after_pop"] = len(pending_blocks)
            current["c"] = row["pe.tiling_rd"]
        if row["pe.done_valid_o"] and row["pe.done_ready_i"]:
            live.discard(row["pe.done_rob_age_o"])
        if row["c.rd_en_i"] and not row["c.rd_accept_w"]:
            rejected.append(row)

    print("Accepted commands:")
    for command in commands:
        print(command)
    print("\nBlock activation intervals:")
    for index, block in enumerate(blocks):
        previous = blocks[index - 1] if index else None
        gap_rows = ([row for row in rows
                     if previous["end"] < row["cycle"] < block["start"]]
                    if previous else [])
        reasons = Counter()
        for row in gap_rows:
            if row["pe.stream_boundary_bubble_q"]:
                reasons["boundary_bubble"] += 1
            elif row["pe.stream_active"] and row["pe.stream_start_pending_q"]:
                reasons["startup_interval"] += 1
            elif row["pe.weight_load_active"] and row["pe.weight_done_now"]:
                reasons["final_weight_row"] += 1
            elif row["pe.state"] == 2 and not row["pe.weight_done_now"]:
                reasons["wait_weight"] += 1
            elif row["pe.state"] == 1:
                reasons["load_weight"] += 1
            elif row["pe.state"] == 0:
                reasons["idle"] += 1
            else:
                reasons["other_transition"] += 1
        print({**block, "gap": len(gap_rows), "gap_reasons": dict(reasons)})

    print("\nRejected C reads:")
    for row in rejected:
        print({key: row[key] for key in (
            "cycle", "ns", "c.rd_reg_i", "c.rd_addr_i", "c.rd_nblock_i",
            "c.wr_reg_i", "c.wr_addr_i", "c.wr_nblock_i",
            "c.rd_wr_conflict_w", "c.rd_dma_conflict_w")})
    print("\nRejected read count:", len(rejected))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cycles_csv")
    analyze(parser.parse_args().cycles_csv)
