#!/usr/bin/env bash
set -euo pipefail

# Stub-only regression test. It materializes the current tools in a temporary
# git repository and
# exercises cache save/restore without Swift, Metal, weights, a runner, or a
# network connection. The production workspace is never modified.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null && pwd -P)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mlxfast-cache-repair.XXXXXX")"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

REPO="${TMP_DIR}/repo"
mkdir -p "${TMP_DIR}/bin"
printf '%s\n' '#!/bin/sh' 'echo "Swift version test-stub"' > "${TMP_DIR}/bin/swift"
chmod +x "${TMP_DIR}/bin/swift"
export PATH="${TMP_DIR}/bin:${PATH}"

mkdir -p "${REPO}/tools" "${REPO}/.github/workflows" \
  "${REPO}/Sources" "${REPO}/Vendor/mlx-swift" \
  "${REPO}/Runner" "${REPO}/Plugins/TrackBenchRevisionStamp"
cp "${SOURCE_DIR}/tools/build-cache.sh" "${REPO}/tools/build-cache.sh"
cp "${SOURCE_DIR}/.github/workflows/benchmark.yml" "${REPO}/.github/workflows/benchmark.yml"
chmod +x "${REPO}/tools/build-cache.sh"

grep -Fq '.build-worker/release/track-bench-worker' "${REPO}/tools/build-cache.sh"
grep -Fq "'Runner/*'" "${REPO}/tools/build-cache.sh"
grep -Fq "'Plugins/*'" "${REPO}/tools/build-cache.sh"
grep -Fq "'tools/stamp-bench-revision.sh'" "${REPO}/tools/build-cache.sh"
grep -Fq 'MLXFAST_BENCH_WORKER_EXECUTABLE: .build-worker/release/track-bench-worker' \
  "${REPO}/.github/workflows/benchmark.yml"

printf '%s\n' 'source' > "${REPO}/Sources/example.swift"
printf '%s\n' 'metal' > "${REPO}/Vendor/mlx-swift/example.metal"
printf '%s\n' 'package' > "${REPO}/Package.swift"
printf '%s\n' 'resolved' > "${REPO}/Package.resolved"
printf '%s\n' 'runner' > "${REPO}/Runner/Qwen4ExpRunner.swift"
printf '%s\n' 'plugin' > "${REPO}/Plugins/TrackBenchRevisionStamp/TrackBenchRevisionStamp.swift"
printf '%s\n' 'stamp' > "${REPO}/tools/stamp-bench-revision.sh"
printf '%s\n' '#!/bin/sh' 'if [ "${1:-}" = "--print-fingerprint" ]; then printf "test-fingerprint\\n"; fi' \
  > "${REPO}/tools/build-mlx-metallib.sh"
chmod +x "${REPO}/tools/build-mlx-metallib.sh"

git -C "${REPO}" init -q
git -C "${REPO}" config user.email test@example.invalid
git -C "${REPO}" config user.name cache-repair-test
git -C "${REPO}" add .
git -C "${REPO}" update-index --add --cacheinfo \
  160000,0123456789012345678901234567890123456789,Vendor/mlx-swift-lm
git -C "${REPO}" commit -qm initial

mkdir -p "${REPO}/.build-worker/release" "${REPO}/.build/release"
printf '%s\n' 'worker' > "${REPO}/.build-worker/release/track-bench-worker"
printf '%s\n' 'metallib' > "${REPO}/.build-worker/release/mlx.metallib"
printf '%s\n' 'mlxfast-metallib-fingerprint-v1 test-fingerprint' \
  > "${REPO}/.build-worker/release/mlx.metallib.fingerprint"
printf '%s\n' 'cli' > "${REPO}/.build/release/mlxfast-swift"

export MLXFAST_BUILD_CACHE_DIR="${TMP_DIR}/cache"
BASE_KEY="$(cd "${REPO}" && tools/build-cache.sh key)"
for tracked in \
  "Runner/Qwen4ExpRunner.swift" \
  "Plugins/TrackBenchRevisionStamp/TrackBenchRevisionStamp.swift" \
  "tools/stamp-bench-revision.sh" \
  "tools/build-cache.sh"; do
  cp "${REPO}/${tracked}" "${REPO}/${tracked}.save"
  printf '%s\n' '# mutation' >> "${REPO}/${tracked}"
  MUTATED_KEY="$(cd "${REPO}" && tools/build-cache.sh key)"
  [[ "${MUTATED_KEY}" != "${BASE_KEY}" ]] || {
    printf 'FAIL: key did not change for %s\n' "${tracked}" >&2
    exit 1
  }
  mv "${REPO}/${tracked}.save" "${REPO}/${tracked}"
done

cd "${REPO}"
tools/build-cache.sh save >/dev/null
rm -f .build-worker/release/track-bench-worker \
  .build-worker/release/mlx.metallib \
  .build-worker/release/mlx.metallib.fingerprint \
  .build/release/mlxfast-swift
[[ ! -e .build-worker/release/bench-worker ]]
tools/build-cache.sh restore >/dev/null
[[ -x .build-worker/release/track-bench-worker || -f .build-worker/release/track-bench-worker ]]
[[ -f .build-worker/release/mlx.metallib ]]
[[ -f .build-worker/release/mlx.metallib.fingerprint ]]
[[ -f .build/release/mlxfast-swift ]]

printf '%s\n' 'PASS: cache saves/restores only track-bench-worker and invalidates Runner/Plugins/stamp changes'
