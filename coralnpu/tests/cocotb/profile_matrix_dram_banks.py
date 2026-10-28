#!/usr/bin/env python3
"""Measure GEMM bank placement and screen address mappings without simulating RTL.

Alternative mappings reuse the observed READ/WRITE order only as a static
workload. Row changes are not predicted PRE/ACT counts, latency or performance.
"""

import argparse
from collections import Counter
import configparser
import hashlib
import io
import json
from pathlib import Path
import tempfile

from profile_matrix_dram_commands import address_decoder, commands_from
from profile_matrix_dram_readiness import match_reads
from profile_matrix_gemm_dram import read_beats

CANDIDATE = "rochrabacobg"
COMPARISONS = ("rochracobabg", CANDIDATE, "rochrababgco")


def read_config(path):
    cfg = configparser.ConfigParser()
    cfg.optionxform = str
    if not cfg.read(path):
        raise ValueError(f"Cannot read config: {path}")
    return cfg


def encoder(config):
    """Invert the DDR4 BL8 field decoder at transaction-byte granularity."""
    cfg = read_config(config)
    get = cfg.getint
    burst_bytes = get("dram_structure", "BL") * get("system", "bus_width") // 8
    sizes = dict(ch=get("system", "channels"), bg=get("dram_structure", "bankgroups"),
                 ba=get("dram_structure", "banks_per_group"), ro=get("dram_structure", "rows"),
                 co=get("dram_structure", "columns") // get("dram_structure", "BL"))
    rank_bytes = sizes["bg"] * sizes["ba"] * sizes["ro"] * sizes["co"] * burst_bytes
    sizes["ra"] = get("system", "channel_size") * 1024 * 1024 // rank_bytes
    mapping = cfg.get("system", "address_mapping")
    fields = [mapping[i:i + 2] for i in range(0, len(mapping), 2)]
    if sorted(fields) != sorted(sizes):
        raise ValueError("Invalid mapping fields")

    def encode(address):
        values = dict(zip(("ch", "ra", "bg", "ba", "ro", "co"), address))
        result = 0
        for field in fields:
            if not 0 <= values[field] < sizes[field]:
                raise ValueError("DDR address field outside configured geometry")
            result = result * sizes[field] + values[field]
        return result * burst_bytes

    return encode


def mapping_config(base, mapping, output):
    cfg = read_config(base)
    cfg["system"]["address_mapping"] = mapping
    stream = io.StringIO()
    stream.write("; Address mapping experiment: only address_mapping differs from the base.\n")
    cfg.write(stream)
    output = Path(output)
    if output.resolve() == Path(base).resolve():
        raise ValueError("Candidate config must not overwrite the baseline")
    # Validate before touching a user-supplied destination.
    with tempfile.TemporaryDirectory(prefix="coral_validate_map_") as temporary:
        check = Path(temporary) / "candidate.ini"
        check.write_text(stream.getvalue())
        address_decoder(check)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(stream.getvalue())
    return output


def tile_addresses(tile):
    width = tile["cols"] * (1 << tile["elem_bytes_log2"])
    if tile["base"] % 64 or width % 64 or tile["stride"] % 64:
        raise ValueError("This analysis requires aligned, complete 64B tile rows")
    return [tile["base"] + row * tile["stride"] + offset
            for row in range(tile["rows"]) for offset in range(0, width, 64)]


def placement(addresses, decode):
    decoded = [decode(address) for address in addresses]
    return dict(beats=len(decoded), banks=len({a[:4] for a in decoded}),
                rank_bank_groups=len({a[:3] for a in decoded}),
                ranks=len({a[1] for a in decoded}),
                bank_rows=len({a[:5] for a in decoded}),
                per_bank_beats={":".join(map(str, key)): count
                                for key, count in sorted(Counter(a[:4] for a in decoded).items())})


def access_row_changes(accesses, decode):
    """Count same-bank row changes in fixed observed data-command order."""
    last, counts = {}, Counter(total=0, write_to_read=0, c_write_to_b_read=0)
    for access in accesses:
        a = decode(access["byte_address"])
        bank, row = a[:4], a[4]
        previous = last.get(bank)
        if previous is not None and previous[0] != row:
            counts["total"] += 1
            if previous[1]["kind"] == "write" and access["kind"] == "read":
                counts["write_to_read"] += 1
                if previous[1]["role"] == "C" and access["role"] == "B":
                    counts["c_write_to_b_read"] += 1
        last[bank] = row, access
    return dict(counts)


def analyze(directory, output, candidate_config):
    def load(name):
        return json.loads((directory / name).read_text())

    base = directory / "CORAL_DDR4_64GBps_interleaved.ini"
    decode, tck, _ = address_decoder(base)
    encode = encoder(base)
    wave, dependency, metrics = [load(name) for name in
                                ("gemm_wave_profile.json", "gemm_dram_dependency_profile.json",
                                 "gemm_metrics.json")]
    readiness = load("gemm_dram_readiness_profile.json")
    if not all(data.get("verified") for data in (wave, dependency, metrics, readiness)):
        raise ValueError("Requires verified profiles from the same run")
    reads = read_beats(directory / "dramsim3/axi_read_trace.jsonl")
    commands = commands_from(directory / "dramsim3/ddr_commands.trace", tck)
    match_reads(reads, commands, decode)
    loads = dependency["loads"]
    role_by_address = {}
    for tile in loads:
        for address in tile_addresses(tile):
            if address in role_by_address and role_by_address[address] != tile["role"]:
                raise ValueError("LOAD roles overlap in memory")
            role_by_address[address] = tile["role"]
    for read in reads:
        if encode(read["ddr_address"]) != read["address"]:
            raise ValueError("Native address inversion differs from AXI read addresses")
        if read["address"] not in role_by_address:
            raise ValueError("READ has no matching LOAD memory region")
    stores = [event for event in wave["events"]
              if event["event"] == "DMA_ACCEPT" and event["op"] == 5]
    stores_by_address = {}
    for store_id, tile in enumerate(stores):
        for address in tile_addresses(tile):
            if address in stores_by_address or address in role_by_address:
                raise ValueError("STOREs overlap or alias LOADs")
            stores_by_address[address] = store_id
    if len(stores_by_address) != metrics["axi_write_beats"]:
        raise ValueError("STORE footprint differs from verified AXI write count")

    accesses, command_counts = [], Counter()
    for command in commands:
        kind = command["kind"]
        if kind not in ("read", "write"):
            continue
        byte_address = encode(command["address"])
        role = role_by_address.get(byte_address) if kind == "read" else "C"
        if (kind == "read" and role is None) or (kind == "write" and byte_address not in stores_by_address):
            raise ValueError("Native data command is outside the verified GEMM footprints")
        accesses.append(dict(command, byte_address=byte_address, role=role))
        command_counts[kind] += 1
    if command_counts["read"] != len(reads):
        raise ValueError("Physical READ count differs from AXI reads")
    write_addresses = Counter(a["byte_address"] for a in accesses if a["kind"] == "write")
    if any(count != 1 for count in write_addresses.values()):
        raise ValueError("Unexpected duplicate physical WRITE")

    # Attribute same-bank write-recovery constraints to the actual C STORE tile.
    latest_write, causes, pairs = {}, Counter(), Counter()
    cursor = 0
    offset = dependency["trace_to_sim_offset_ns"]
    for query in readiness["queries"]:
        ns = query["ns"] - offset
        while cursor < len(accesses) and accesses[cursor]["time_ns"] < ns:
            access = accesses[cursor]
            if access["kind"] == "write":
                latest_write[tuple(access["address"][:4])] = access
            cursor += 1
        if query["category"] != "precharge_timing" or query["timing_origin"] != "write":
            continue
        target = query["address"]
        if role_by_address.get(encode(target)) != "B":
            raise ValueError("Expected a B data read for the reported C-to-B conflict")
        write = latest_write[tuple(target[:4])]
        if write["address"][4] != query["open_row"] or query["open_row"] == target[4]:
            raise ValueError("Critical row conflict does not match last same-bank WRITE")
        causes[":".join(map(str, target[:4]))] += 1
        store = stores[stores_by_address[write["byte_address"]]]
        pairs[f"B_row={target[4]:#x},C_row={query['open_row']:#x},C_tile={store['base']:#x}"] += 1

    comparisons = []
    with tempfile.TemporaryDirectory(prefix="coral_bank_maps_") as temporary:
        for mapping in COMPARISONS:
            config = mapping_config(base, mapping, Path(temporary) / f"{mapping}.ini")
            candidate_decode, _, _ = address_decoder(config)
            representatives = {}
            for tile in loads + [dict(tile, role="C") for tile in stores]:
                if tile["role"] not in representatives:
                    representatives[tile["role"]] = placement(tile_addresses(tile), candidate_decode)
            # This is a fixed access-order comparison, not an alternative DRAM execution.
            comparisons.append(dict(mapping=mapping,
                                    fixed_order_row_changes=access_row_changes(accesses, candidate_decode),
                                    first_tile_placement=representatives))

    mapping_config(base, CANDIDATE, candidate_config)
    before, after = read_config(base), read_config(candidate_config)
    differences = [(section, key) for section in before.sections() for key in before[section]
                   if before[section][key] != after[section][key]]
    if differences != [("system", "address_mapping")]:
        raise ValueError("Candidate changes settings other than address_mapping")
    result = dict(
        verified=True, source=str(directory), baseline_mapping=before["system"]["address_mapping"],
        baseline_config_sha256=hashlib.sha256(base.read_bytes()).hexdigest(),
        physical_commands=dict(command_counts), verified_axi_write_beats=metrics["axi_write_beats"],
        writes_not_yet_physically_issued=metrics["axi_write_beats"] - command_counts["write"],
        write_recovery_conflict_sample_cycles=sum(causes.values()),
        write_recovery_conflict_samples_by_bank=dict(causes),
        write_recovery_conflict_samples_by_c_tile=dict(pairs),
        mapping_comparisons=comparisons, candidate_config=str(candidate_config.resolve()),
        candidate_config_sha256=hashlib.sha256(candidate_config.read_bytes()).hexdigest(),
        interpretation=[
            "Physical addresses were inverted from the baseline trace and checked against AXI reads and GEMM STORE footprints.",
            "Missing physical WRITEs may remain buffered after their early backend callbacks; AXI data verification passed.",
            "Alternative mappings reuse baseline READ/WRITE order; command order and timing can change in a real run.",
            "Fixed-order row changes exclude refresh, controller queues and precharge timing; they are not predicted ACT/PRE counts.",
            "The candidate preserves low bank-group bits; column-low mapping is a comparison, not the recommended candidate.",
            "The candidate spreads a C tile across more banks but reduces B tile bank parallelism; GEMM must measure the net effect.",
            "No RTL, outstanding depth, bandwidth, timing, queue capacity, matrix layout or software schedule changed."])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--candidate-config", type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    output = args.output or directory / "gemm_dram_bank_profile.json"
    candidate = args.candidate_config or directory / "CORAL_DDR4_64GBps_bankspread.ini"
    result = analyze(directory, output, candidate)
    print("Same-bank C write recovery conflict samples:", result["write_recovery_conflict_sample_cycles"])
    for comparison in result["mapping_comparisons"]:
        placements = comparison["first_tile_placement"]
        print(comparison["mapping"], comparison["fixed_order_row_changes"],
              "B tile banks/BGs:", placements["B"]["banks"], placements["B"]["rank_bank_groups"],
              "C tile banks/BGs:", placements["C"]["banks"], placements["C"]["rank_bank_groups"])
    print("Profile:", output)
    print("Candidate config (mapping only):", candidate)


if __name__ == "__main__":
    main()
