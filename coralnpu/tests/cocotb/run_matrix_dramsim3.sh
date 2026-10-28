#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
mode=${1:-smoke}
artifact_dir=${2:-/tmp/coral_matrix_dramsim3_${mode}}
mkdir -p "$artifact_dir"
artifact_dir=$(cd -- "$artifact_dir" && pwd)
run_started_ns=$(date +%s%N)
dram_dir="$repo_dir/hdl/verilog/SIM/dramsim3"
backend=$(realpath -- "${CORAL_DRAMSIM3_BACKEND_LIBRARY:-$dram_dir/lib/libdramsim3.so}")
test -f "$backend"
backend_dir=$(dirname -- "$backend")
header_dir="$dram_dir/include"
if [[ -f "$backend_dir/dramsim3.h" ]]; then
    header_dir="$backend_dir"
fi
config=${CORAL_DRAMSIM3_CONFIG:-$repo_dir/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini}
config=$(realpath -- "$config")
test -f "$config"
bridge="$artifact_dir/libcoral_dramsim3.so"
clock_ns=${CORAL_GEMM_CLOCK_NS:-2.0}
bridge_flags=()
if [[ "${CORAL_DRAMSIM3_COMMAND_TRACE:-0}" == 1 ]]; then
    bridge_flags+=(-DCORAL_DRAM_COMMAND_TRACE)
    export CORAL_DRAMSIM3_TRACE=1
fi

# RPATH and the loaded-library check prevent an unrelated LD_LIBRARY_PATH from
# silently turning an A/B comparison into two runs of the same backend.
"${CXX:-g++}" -std=c++17 -O2 -fPIC -shared "${bridge_flags[@]}" \
    "$repo_dir/tests/cocotb/dramsim3_c_api.cc" -I"$header_dir" \
    "$backend" -Wl,--disable-new-dtags -Wl,-rpath,"$backend_dir" \
    -Wl,-z,defs -ldl -o "$bridge"
python3 - "$backend" "$bridge" "$config" "$artifact_dir" <<'PY'
import ctypes
import hashlib
import json
from pathlib import Path
import sys

backend, bridge, config, output = map(Path, sys.argv[1:])
lib = ctypes.CDLL(str(bridge))
lib.coral_dram_backend_library.restype = ctypes.c_char_p
loaded = lib.coral_dram_backend_library()
if not loaded or Path(loaded.decode()).resolve() != backend:
    raise SystemExit(f"Wrong DRAMsim3 backend loaded: requested {backend}, got {loaded!r}")
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
metadata = dict(backend=str(backend), backend_sha256=digest(backend),
                bridge=str(bridge), config=str(config), config_sha256=digest(config))
build = backend.with_name("coral_backend_build.json")
if build.is_file():
    metadata["build"] = json.loads(build.read_text())
    if metadata["build"]["library_sha256"] != metadata["backend_sha256"]:
        raise SystemExit("DRAMsim3 library does not match its build metadata")
(output / "dramsim3_backend.json").write_text(json.dumps(metadata, indent=2) + "\n")
print("DRAMsim3 backend:", backend)
PY

if [[ "$mode" == build ]]; then
    echo "DRAMsim3 C ABI: $bridge"
    exit 0
fi
case "$mode" in
    selftest)
        CORAL_DRAMSIM3_LIBRARY="$bridge" CORAL_DRAMSIM3_CONFIG="$config" \
            python3 -m unittest tests.cocotb.dramsim3_timing_test -v
        PYTHONPATH="$repo_dir/tests/cocotb${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -m unittest profile_matrix_dram_trace_test profile_matrix_dram_commands_test \
                matrix_gemm_wave_analysis_test profile_matrix_gemm_dram_test \
                profile_matrix_dram_banks_test -v
        exit 0 ;;
    smoke) target=matrix_cpu_dma_multicreg_c_api_elf_multicreg_smoke ;;
    boundary) target=matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128 ;;
    backpressure) target=matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128_backpressure ;;
    gemm) target=matrix_cpu_dma_multicreg_c_api_elf_multicreg_gemm ;;
    gemm-rect) target=matrix_cpu_dma_gemm_rect_c_api_elf_gemm_m256_n512_k128 ;;
    packed-gemm) target=matrix_cpu_dma_gemm_packed_b ;;
    wave) target=matrix_cpu_dma_gemm_wave_c_api_elf_multicreg_gemm ;;
    packed-wave) target=matrix_cpu_dma_gemm_packed_b_wave ;;
    *) echo "Usage: $0 [build|selftest|smoke|boundary|backpressure|gemm|gemm-rect|packed-gemm|wave|packed-wave] [output directory]" >&2; exit 2 ;;
esac

echo "DRAMsim3 config: $config"
echo "MatrixCore/AXI clock period: $clock_ns ns (default 2 ns = 500 MHz)"
echo "Artifacts: $artifact_dir"
# Local execution deliberately makes the external library/config accessible.
# Each invocation runs one test; builds retain the user's Bazel parallelism.
test_status=0
bazel test "//tests/cocotb:$target" \
    --strategy=TestRunner=local \
    --test_env=CORAL_MATRIX_MEMORY_MODEL=dramsim3 \
    --test_env="CORAL_GEMM_CLOCK_NS=$clock_ns" \
    --test_env="CORAL_DRAMSIM3_LIBRARY=$bridge" \
    --test_env="CORAL_DRAMSIM3_CONFIG=$config" \
    --test_env="CORAL_DRAMSIM3_OUTPUT_DIR=$artifact_dir/dramsim3" \
    --test_env="CORAL_DRAMSIM3_TRACE=${CORAL_DRAMSIM3_TRACE:-0}" \
    --test_env="CORAL_GEMM_TIMEOUT_CYCLES=${CORAL_GEMM_TIMEOUT_CYCLES:-1000000}" \
    --test_output=streamed --nocache_test_results \
    --test_timeout="${CORAL_DRAMSIM3_TIMEOUT:-3600}" || test_status=$?

testlogs_dir=$(bazel info bazel-testlogs)
test_dir="$testlogs_dir/tests/cocotb/$target"
python3 - "$test_dir" "$artifact_dir" "$run_started_ns" <<'PY'
import json
from pathlib import Path
import shutil
import sys
import zipfile

test_dir, output = map(Path, sys.argv[1:3])
started_ns = int(sys.argv[3])
log = test_dir / "test.log"
if not log.is_file() or log.stat().st_mtime_ns < started_ns:
    print("No test log from this run; previous artifacts were not used.")
    sys.exit(0)
shutil.copy2(log, output / "test.log")
archive = test_dir / "test.outputs/outputs.zip"
extracted = set()
if archive.is_file() and archive.stat().st_mtime_ns >= started_ns:
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            name = Path(entry.filename).name
            if name in ("gemm_metrics.json", "gemm_m512_n512_k128.vcd"):
                with bundle.open(entry) as source, (output / name).open("wb") as dest:
                    shutil.copyfileobj(source, dest)
                extracted.add(name)
unpacked = test_dir / "test.outputs"
for name in ("gemm_metrics.json", "gemm_m512_n512_k128.vcd"):
    source = unpacked / name
    if name not in extracted and source.is_file() and source.stat().st_mtime_ns >= started_ns:
        shutil.copy2(source, output / name)
        extracted.add(name)
metrics = output / "gemm_metrics.json"
if "gemm_metrics.json" in extracted:
    data = json.loads(metrics.read_text())
    print("Memory model:", data["memory"])
    print("MatrixCore clock (MHz):", data["clock_mhz"])
    print("Logical MACs/cycle:", round(data["logical_macs_per_cycle"], 3))
print("Artifacts:", output)
PY
if [[ "$test_status" == 0 && "${CORAL_DRAMSIM3_TRACE:-0}" == 1 ]]; then
    trace="$artifact_dir/dramsim3/axi_read_trace.jsonl"
    if ! python3 - "$trace" "$run_started_ns" <<'PY'
from pathlib import Path
import sys
trace = Path(sys.argv[1])
sys.exit(0 if trace.is_file() and trace.stat().st_mtime_ns >= int(sys.argv[2]) else 1)
PY
    then
        echo "No fresh DRAM read trace from this run." >&2
        exit 1
    fi
    python3 tests/cocotb/profile_matrix_dram_trace.py "$trace" \
        --output "$artifact_dir/gemm_dram_read_profile.json"
    if [[ "${CORAL_DRAMSIM3_COMMAND_TRACE:-0}" == 1 ]]; then
        if ! python3 - "$artifact_dir/dramsim3/ddr_commands.trace" "$run_started_ns" <<'PY'
from pathlib import Path
import sys
trace = Path(sys.argv[1])
sys.exit(0 if trace.is_file() and trace.stat().st_size > 0 and
         trace.stat().st_mtime_ns >= int(sys.argv[2]) else 1)
PY
        then
            echo "No fresh native DDR command trace from this run." >&2
            exit 1
        fi
        python3 tests/cocotb/profile_matrix_dram_commands.py \
            "$artifact_dir/dramsim3/ddr_commands.trace" --reads "$trace" \
            --config "$config" --stats "$artifact_dir/dramsim3/dramsim3.json" \
            --output "$artifact_dir/gemm_dram_command_profile.json"
    fi
    if [[ "$mode" == wave || "$mode" == packed-wave ]]; then
        python3 - "$artifact_dir" "$run_started_ns" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])
for name in ("gemm_metrics.json", "gemm_m512_n512_k128.vcd"):
    path = output / name
    if not path.is_file() or path.stat().st_mtime_ns < int(sys.argv[2]):
        raise SystemExit(f"No fresh {name}; refusing to correlate previous artifacts")
PY
        python3 tests/cocotb/profile_matrix_gemm_wave.py \
            "$artifact_dir/gemm_m512_n512_k128.vcd" \
            --metrics "$artifact_dir/gemm_metrics.json" \
            --output "$artifact_dir/gemm_wave_profile.json"
        python3 tests/cocotb/profile_matrix_gemm_dram.py \
            --wave-profile "$artifact_dir/gemm_wave_profile.json" \
            --metrics "$artifact_dir/gemm_metrics.json" --reads "$trace" \
            --output "$artifact_dir/gemm_dram_dependency_profile.json"
    fi
fi
if [[ "$test_status" == 0 ]]; then
    python3 tests/cocotb/report_matrix_gemm.py "$artifact_dir" \
        --started-ns "$run_started_ns"
fi
exit "$test_status"
