#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${CORAL_TOOLCHAIN_SOURCE_ROOT:-$(cd "$repo_root/../riscv-matrix-extension-spec/xuantie-gnu-toolchain" 2>/dev/null && pwd || true)}"
if [[ -z "$source_root" ]]; then
  source_root="$repo_root/../riscv-matrix-extension-spec/xuantie-gnu-toolchain"
fi

gcc_url="${CORAL_GCC_URL:-https://github.com/XUANTIE-RV/gcc.git}"
binutils_url="${CORAL_BINUTILS_URL:-https://github.com/XUANTIE-RV/binutils-gdb.git}"
gcc_branch="${CORAL_GCC_BRANCH:-xuantie-gcc-14.3.0}"
binutils_branch="${CORAL_BINUTILS_BRANCH:-xuantie-binutils-gdb-2.42}"

gcc_base="3f7b8eff597d822d53988fcbaf4eaab8043de4aa"
gcc_patched="103c87c5b42029198e83a3748759c7c696b0892b"
binutils_base="873ae823fe211768425a18bb7be20a34fd2fddb5"
binutils_patched="ec857d9cd0909c5b3cba58e0d5ac861669fe7eeb"

prepare_repo() {
  local name="$1"
  local url="$2"
  local branch="$3"
  local base="$4"
  local patched="$5"
  local patch="$6"
  local directory="$7"

  if [[ ! -e "$directory/.git" ]]; then
    mkdir -p "$(dirname "$directory")"
    git clone --branch "$branch" "$url" "$directory"
  fi

  local head
  head="$(git -C "$directory" rev-parse HEAD)"
  if [[ "$head" == "$patched" ]]; then
    echo "$name: patched commit already checked out ($patched)"
    return
  fi

  if [[ -n "$(git -C "$directory" status --porcelain)" ]]; then
    echo "$name: source tree is not clean: $directory" >&2
    exit 1
  fi

  if ! git -C "$directory" cat-file -e "$base^{commit}" 2>/dev/null; then
    git -C "$directory" fetch origin "$base"
  fi
  git -C "$directory" checkout --detach "$base"

  if git -C "$directory" apply --check "$patch"; then
    git -C "$directory" apply "$patch"
    echo "$name: applied Coral Matrix patch"
  elif git -C "$directory" apply --reverse --check "$patch"; then
    echo "$name: Coral Matrix patch is already applied"
  else
    echo "$name: patch does not apply to the pinned base $base" >&2
    exit 1
  fi
}

mkdir -p "$source_root"
prepare_repo \
  "GCC" "$gcc_url" "$gcc_branch" "$gcc_base" "$gcc_patched" \
  "$repo_root/tests/toolchain/patches/xuantie-gcc-coral-matrix.patch" \
  "$source_root/riscv-gcc"
prepare_repo \
  "Binutils" "$binutils_url" "$binutils_branch" "$binutils_base" "$binutils_patched" \
  "$repo_root/tests/toolchain/patches/xuantie-binutils-coral-matrix.patch" \
  "$source_root/riscv-binutils"

echo "Coral Matrix toolchain sources are ready under: $source_root"
