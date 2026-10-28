#!/usr/bin/env python3
"""Generate single-channel DDR data-rate sensitivity configurations."""

import argparse
import configparser
from fractions import Fraction
import hashlib
import io
import json
from pathlib import Path

BASE = Path(__file__).with_name("CORAL_DDR4_32GBps_interleaved.ini")


def generate(bandwidth, output, base=BASE):
    if bandwidth not in (32, 48, 64):
        raise ValueError("Supported bandwidth points: 32, 48, 64 GB/s")
    cfg = configparser.ConfigParser()
    cfg.optionxform = str
    cfg.read(base)
    if (cfg.getint("system", "channels"),
        cfg.getint("system", "bus_width"),
        cfg.getint("dram_structure", "BL")) != (1, 64, 8):
        raise ValueError("Expected the single-channel 64-bit BL8 baseline")
    old_tck = Fraction(cfg["timing"]["tCK"])
    if old_tck != Fraction(1, 2):
        raise ValueError("Expected the 32 GB/s tCK=0.5ns baseline")
    new_tck = Fraction(16, bandwidth)
    report = {}
    for name, value in list(cfg["timing"].items()):
        if name == "tCK":
            continue
        old_cycles = int(value)
        scaled = old_cycles * old_tck / new_tck
        # The burst occupancy and cross-bank-group column cadence scale with
        # data rate. Other minimum delays round up; refresh intervals down.
        if name == "tCCD_S":
            cycles = old_cycles
        elif name.startswith("tREFI"):
            cycles = scaled.numerator // scaled.denominator
        else:
            cycles = -(-scaled.numerator // scaled.denominator)
        cfg["timing"][name] = str(cycles)
        report[name] = dict(baseline_cycles=old_cycles, cycles=cycles,
                            baseline_ns=float(old_cycles * old_tck),
                            ns=float(cycles * new_tck),
                            delta_ns=float(cycles * new_tck - old_cycles * old_tck))
    cfg["timing"]["tCK"] = format(float(new_tck), ".17g")
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if bandwidth == 32:
        output.write_bytes(Path(base).read_bytes())
    else:
        stream = io.StringIO()
        stream.write("; Architecture sensitivity experiment, not a qualified DDR device.\n")
        stream.write("; Same channel/bank topology and mapping; absolute timing rounded conservatively.\n")
        stream.write("; tCCD_S and BL/2 keep their cycle counts to raise data transfer capacity.\n")
        cfg.write(stream)
        output.write_text(stream.getvalue())
    burst_cycles = cfg.getint("dram_structure", "BL") // 2
    callback_cycles = sum(cfg.getint("timing", key) for key in ("AL", "CL")) + burst_cycles
    metadata = dict(
        experiment="single_channel_data_rate_sensitivity",
        target_shared_gb_per_s=bandwidth,
        base=str(Path(base).resolve()), config=str(output),
        baseline_sha256=hashlib.sha256(Path(base).read_bytes()).hexdigest(),
        config_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
        tck_ns=float(new_tck), timing=report,
        burst_ns=float(burst_cycles * new_tck),
        read_command_to_callback_ns=float(callback_cycles * new_tck),
        adapter_tck_quantization_fs=float(round(float(new_tck) * 1_000_000) - new_tck * 1_000_000),
        caveats=[
            "CL, row and refresh delays retain baseline nanoseconds with conservative cycle rounding.",
            "BL/2 and tCCD_S retain cycle counts; burst duration and cross-bank-group cadence shrink.",
            "Derived timings include the shorter burst; this is not a strictly bandwidth-only model.",
            "Command clock also accelerates, but topology, queues, mapping and scheduling policy are unchanged.",
            "The AXI adapter rounds tCK to integer femtoseconds (48 GB/s has a sub-fs error).",
            "Power parameters are copied, not calibrated for these synthetic data rates."])
    output.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bandwidth", type=int, choices=(32, 48, 64))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = generate(args.bandwidth, args.output)
    print(f"DDR shared peak: {args.bandwidth} GB/s; tCK={result['tck_ns']:.9f}ns")
    print(f"64B burst: {result['burst_ns']:.6f}ns; READ to callback: {result['read_command_to_callback_ns']:.6f}ns")
    print("Config:", result["config"])


if __name__ == "__main__":
    main()
