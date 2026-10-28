"""Profile matrix AXI outstanding and PE gaps in one pass over an existing VCD."""

import argparse
from collections import Counter, deque
import csv
import gzip
import json
from pathlib import Path
from statistics import mean

from analyze_matrix_gemm_wave import SIGNALS as COMMAND_SIGNALS, analyze, rising_samples
from profile_matrix_gemm_wave import DMA, PE, SIGNALS as PE_SIGNALS, profile, validate_profile


AXI_SIGNALS = {
    short: DMA + "m_axi_" + port
    for short, port in {
        "arvalid": "arvalid_o", "arready": "arready_i",
        "araddr": "araddr_o", "arlen": "arlen_o", "arid": "arid_o",
        "rvalid": "rvalid_i", "rready": "rready_o",
        "rlast": "rlast_i", "rid": "rid_i",
        "awvalid": "awvalid_o", "awready": "awready_i",
        "awaddr": "awaddr_o", "awlen": "awlen_o", "awid": "awid_o",
        "wvalid": "wvalid_o", "wready": "wready_i", "wlast": "wlast_o",
        "bvalid": "bvalid_i", "bready": "bready_o", "bid": "bid_i",
    }.items()
}


class AxiProfile:
    def __init__(self, metrics):
        self.metrics = metrics
        self.reads, self.writes, self.write_data = deque(), deque(), deque()
        self.read_bursts, self.write_bursts = [], []
        self.read_hist, self.write_hist = Counter(), Counter()
        self.counts = Counter()
        self.peak_read = self.peak_write = 0
        self.peak_read_beats = 0

    def sample(self, ns, s):
        if not s["rst_n"]:
            assert not self.reads and not self.writes
            return
        if not self.metrics["start_ns"] <= ns < self.metrics["end_ns"]:
            return
        c = self.counts
        c["cycles"] += 1
        self.read_hist[len(self.reads)] += 1
        self.write_hist[len(self.writes)] += 1
        self.peak_read_beats = max(self.peak_read_beats,
                                  sum(r["beats"] - r["received"] for r in self.reads))
        for channel in ("ar", "r", "aw", "w", "b"):
            valid, ready = s[channel + "valid"], s[channel + "ready"]
            c[channel + "_handshakes"] += bool(valid and ready)
            c[channel + "_backpressure"] += bool(valid and not ready)
        c["read_outstanding_without_rvalid"] += bool(self.reads and not s["rvalid"])
        c["write_outstanding_without_wvalid"] += bool(self.write_data and not s["wvalid"])
        c["read_write_outstanding_overlap"] += bool(self.reads and self.writes)
        if not s["act"]:
            c["act_idle"] += 1
            c["act_idle_load_busy"] += bool(s["load_busy"])
            c["act_idle_store_busy"] += bool(s["store_busy"])
            c["act_idle_read_outstanding_without_rvalid"] += bool(self.reads and not s["rvalid"])
            c["act_idle_no_axi_outstanding"] += not (self.reads or self.writes)

        if s["arvalid"] and s["arready"]:
            req = dict(address=s["araddr"], beats=s["arlen"] + 1, id=s["arid"],
                       start_ns=ns, received=0)
            self.reads.append(req)
        if s["rvalid"] and s["rready"]:
            assert self.reads, "R without an outstanding AR"
            req = self.reads[0]
            assert req["id"] == s["rid"]
            if not req["received"]:
                req["first_ns"] = ns
            req["received"] += 1
            assert bool(s["rlast"]) == (req["received"] == req["beats"])
            if s["rlast"]:
                req["end_ns"] = ns
                self.read_bursts.append(self.reads.popleft())
        if s["awvalid"] and s["awready"]:
            req = dict(address=s["awaddr"], beats=s["awlen"] + 1, id=s["awid"],
                       start_ns=ns, received=0)
            self.writes.append(req)
            self.write_data.append(req)
        if s["wvalid"] and s["wready"]:
            assert self.write_data, "W without an outstanding AW"
            req = self.write_data[0]
            if not req["received"]:
                req["first_ns"] = ns
            req["received"] += 1
            assert bool(s["wlast"]) == (req["received"] == req["beats"])
            if s["wlast"]:
                req["last_w_ns"] = ns
                self.write_data.popleft()
        if s["bvalid"] and s["bready"]:
            assert self.writes, "B without an outstanding AW"
            req = self.writes.popleft()
            assert req["id"] == s["bid"] and req["received"] == req["beats"]
            req["end_ns"] = ns
            self.write_bursts.append(req)
        # Address acceptance and response completion on the same edge are
        # simultaneous; do not count the temporary queue update as a peak.
        self.peak_read = max(self.peak_read, len(self.reads))
        self.peak_write = max(self.peak_write, len(self.writes))

    def finish(self):
        assert not self.reads and not self.writes and not self.write_data
        assert self.counts["r_handshakes"] == self.metrics["axi_read_beats"]
        assert self.counts["w_handshakes"] == self.metrics["axi_write_beats"]
        period = self.metrics["clock_ns"]

        def summary(bursts):
            latency = [(r["end_ns"] - r["start_ns"]) / period for r in bursts]
            first = [(r["first_ns"] - r["start_ns"]) / period for r in bursts]
            return dict(bursts=len(bursts), average_beats=mean(r["beats"] for r in bursts),
                        beat_counts=dict(Counter(r["beats"] for r in bursts)),
                        average_address_to_first_data_cycles=mean(first),
                        average_address_to_response_cycles=mean(latency),
                        max_address_to_response_cycles=max(latency))

        return dict(
            verified=True, counts=dict(self.counts),
            peak_read_outstanding=self.peak_read, peak_write_outstanding=self.peak_write,
            peak_read_beats_outstanding=self.peak_read_beats,
            read_outstanding_cycle_histogram=dict(self.read_hist),
            write_outstanding_cycle_histogram=dict(self.write_hist),
            read=summary(self.read_bursts), write=summary(self.write_bursts),
            read_bursts=self.read_bursts, write_bursts=self.write_bursts,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    directory = args.directory
    metrics = json.loads((directory / "gemm_metrics.json").read_text())
    if not metrics.get("verified"):
        parser.error("GEMM must pass functional verification before profiling")
    paths = dict(PE_SIGNALS, **AXI_SIGNALS)
    paths.update(("command_" + str(i), PE + path) for i, path in enumerate(COMMAND_SIGNALS))
    axi = AxiProfile(metrics)
    command_samples = []
    cache = directory / "gemm_axi_samples.csv.gz"

    def observe(samples):
        for ns, s in samples:
            axi.sample(ns, s)
            command_samples.append((ns, {path: s["command_" + str(i)]
                                        for i, path in enumerate(COMMAND_SIGNALS)}))
            yield ns, s

    if cache.is_file():
        with gzip.open(cache, "rt") as source:
            reader = csv.DictReader(source)
            result = profile(observe((float(row.pop("ns")), {k: int(v) for k, v in row.items()})
                                     for row in reader), metrics)
    else:
        temporary_cache = cache.with_suffix(cache.suffix + ".partial")
        with (directory / "gemm_m512_n512_k128.vcd").open() as source, gzip.open(temporary_cache, "wt") as output:
            writer = csv.DictWriter(output, ["ns", *paths])
            writer.writeheader()

            def decoded():
                for ns, values in rising_samples(source, set(paths.values()), "MatrixCoreMiniAxi"):
                    s = {name: values[path] for name, path in paths.items()}
                    if all(v is not None for v in s.values()):
                        writer.writerow(dict(ns=ns, **s))
                    yield ns, s

            result = profile(observe(decoded()), metrics)
        temporary_cache.replace(cache)
    validate_profile(result, metrics)
    outputs = {
        "gemm_performance_profile.json": result,
        "gemm_axi_profile.json": axi.finish(),
        "gemm_command_overlap.json": analyze(command_samples, min_inflight=1,
                                              expected_commands=metrics["retired_matrix_instructions"]["MATMUL"]),
    }
    for name, value in outputs.items():
        (directory / name).write_text(json.dumps(value, indent=2) + "\n")
        if not value["verified"]:
            raise ValueError(f"Waveform validation failed: {name}")
    compact = {k: v for k, v in outputs["gemm_axi_profile.json"].items()
               if k not in ("read_bursts", "write_bursts")}
    print(json.dumps(compact, indent=2))
    print("PE feed:", json.dumps(result["counts"]))
    print("PE idle:", json.dumps(result["activation_feed_idle_reasons"]))
    print("PE command overlap:", outputs["gemm_command_overlap.json"]["peak_accepted_uncompleted_matmuls"])


if __name__ == "__main__":
    main()
