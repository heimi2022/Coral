#!/usr/bin/env bash
# Build two isolated upstream libraries; never overwrite the bundled backend.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
root=${1:-/tmp/coral_dramsim3_write_drain}
revision=29817593b3389f1337235d63cac515024ab8fd6e
upstream_url=https://github.com/umd-memsys/DRAMsim3.git
patch_file="$repo_dir/tests/cocotb/dramsim3_write_drain.patch"
mkdir -p "$root"
root=$(cd -- "$root" && pwd)
upstream="$root/upstream"
if [[ ! -d "$upstream/.git" ]]; then
    git clone --no-checkout "$upstream_url" "$upstream"
fi
if ! git -C "$upstream" cat-file -e "$revision^{commit}"; then
    git -C "$upstream" fetch --depth=1 origin "$revision"
fi
patch_sha=$(sha256sum "$patch_file" | cut -d ' ' -f 1)
for policy in baseline write16; do
    variant="$root/$policy"
    source="$variant/source"
    expected="$revision:$policy:$patch_sha"
    if [[ -e "$source" ]]; then
        if [[ ! -f "$variant/source.version" ]] ||
           [[ "$(<"$variant/source.version")" != "$expected" ]]; then
            echo "Source differs from this experiment; use a new output directory: $variant" >&2
            exit 1
        fi
    else
        mkdir -p "$source"
        git -C "$upstream" archive "$revision" | tar -x -C "$source"
        if [[ "$policy" == write16 ]]; then
            (cd "$source" && git apply --check "$patch_file" && git apply "$patch_file")
        fi
        printf '%s\n' "$expected" > "$variant/source.version"
    fi
    cmake -S "$source" -B "$variant/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMD_TRACE=OFF -DADDR_TRACE=OFF -DTHERMAL=OFF
    cmake --build "$variant/build" --target dramsim3 --parallel "${CORAL_DRAMSIM3_BUILD_JOBS:-4}"
    cp "$source/libdramsim3.so" "$variant/libdramsim3.so"
    cp "$source/src/dramsim3.h" "$variant/dramsim3.h"
    python3 - "$variant" "$revision" "$policy" "$patch_file" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

variant, revision, policy, patch = sys.argv[1:]
variant = Path(variant)
digest = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
metadata = dict(upstream="umd-memsys/DRAMsim3", revision=revision,
                policy=policy, write_drain_transaction_batch_limit=16 if policy == "write16" else None,
                patch_sha256=digest(patch) if policy == "write16" else None,
                library_sha256=digest(variant / "libdramsim3.so"))
(variant / "coral_backend_build.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY
done
echo "Unmodified rebuilt backend: $root/baseline/libdramsim3.so"
echo "Experimental write16 backend: $root/write16/libdramsim3.so"
echo "Bundled backend is unchanged. Run the scheduler comparison before GEMM."
