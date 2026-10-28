#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
artifact_dir=${1:-/tmp/coral_matrix_gemm_512_wave}
target=matrix_cpu_dma_gemm_wave_c_api_elf_multicreg_gemm
min_inflight=${CORAL_GEMM_MIN_INFLIGHT:-1}
if ! [[ "$min_inflight" =~ ^[1-9][0-9]*$ ]]; then
    echo "CORAL_GEMM_MIN_INFLIGHT must be a positive integer" >&2
    exit 2
fi
echo "GEMM overlap target: at least $min_inflight outstanding MATMUL(s)"

run_started_ns=$(date +%s%N)
test_status=0
bazel test "//tests/cocotb:$target" \
    --test_env="CORAL_GEMM_MIN_INFLIGHT=$min_inflight" \
    --test_output=streamed --nocache_test_results \
    --test_timeout="${CORAL_GEMM_WAVE_TIMEOUT:-3600}" || test_status=$?

testlogs_dir=$(bazel info bazel-testlogs)
python3 - "$testlogs_dir/tests/cocotb/$target" "$artifact_dir" "$run_started_ns" "$test_status" <<'PY'
import json
from pathlib import Path
import shutil
import sys
import zipfile

test_dir, destination = map(Path, sys.argv[1:3])
started_ns, status = map(int, sys.argv[3:5])
destination.mkdir(parents=True, exist_ok=True)
names = ("gemm_m512_n512_k128.vcd", "gemm_metrics.json")
extracted = set()
log = test_dir / "test.log"
if not log.is_file() or log.stat().st_mtime_ns < started_ns:
    print("No test log from this run; previous artifacts were not used.")
    sys.exit(0 if status else 1)
archive = test_dir / "test.outputs" / "outputs.zip"
if archive.is_file() and archive.stat().st_mtime_ns >= started_ns:
    with zipfile.ZipFile(archive) as outputs:
        for name in names:
            if name not in outputs.namelist():
                continue
            with outputs.open(name) as source, (destination / name).open("wb") as sink:
                shutil.copyfileobj(source, sink)
            extracted.add(name)
else:
    for name in names:
        source = test_dir / "test.outputs" / name
        if source.is_file() and source.stat().st_mtime_ns >= started_ns:
            shutil.copyfile(source, destination / name)
            extracted.add(name)
shutil.copyfile(log, destination / "test.log")
print(f"Artifacts: {destination.resolve()}")
print(f"Extracted from this run: {sorted(extracted)}")
if status:
    sys.exit(0)
if not set(names) <= extracted:
    print("GEMM metrics unavailable; inspect test.log and the waveform if present.")
    sys.exit(1)
metrics = json.loads((destination / "gemm_metrics.json").read_text())
print(f"Waveform: {(destination / names[0]).resolve()}")
print(f"Metrics: {(destination / names[1]).resolve()}")
print(f"Launch-to-halt cycles: {metrics['elapsed_cycles']}")
print(f"Logical MACs/cycle: {metrics['logical_macs_per_cycle']:.3f}")
PY

if (( test_status != 0 )); then
    exit "$test_status"
fi

python3 tests/cocotb/analyze_matrix_gemm_wave.py \
    "$artifact_dir/gemm_m512_n512_k128.vcd" \
    --metrics "$artifact_dir/gemm_metrics.json" \
    --min-inflight "$min_inflight" \
    --output "$artifact_dir/gemm_command_overlap.json"
