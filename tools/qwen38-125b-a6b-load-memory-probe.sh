#!/usr/bin/env bash
#
# Load-only memory probe for the Qwen 3.8 125B A6B MLX loader.
#
# WHAT IT DOES
#   Runs the SCORED runtime worker's LOAD path only -- `runtime-worker
#   --weights <DIR>` with stdin closed -- so the worker loads the 4-bit target,
#   runs its constructor warmup, emits its hello, then reads EOF and exits. No
#   request is ever sent, so no prefill/decode/measured work runs. While the
#   worker is alive this script samples the system memory components
#   (file-backed / anonymous / wired / compressor pages and the kernel memory
#   pressure level) and the worker's resident size, and it captures the worker's
#   own per-shard / per-phase MLX activeMemory trace.
#
#   Pair the two streams to attribute footprint to each load step:
#     * the sampler TSV  -> OS-level file-backed / anon / wired / compressor /
#                           pressure over wall-clock time
#     * the worker log   -> `[loadmemtrace]` lines: MLX active/cache/peak plus
#                           per-shard and per-phase deltas
#
#   Expected result of the single-copy loader fix: file-backed grows ~0 across
#   the load (the streamed reader is uncached), active+wired settle near the
#   62-72 GiB model, and the compressor / pressure stay flat.
#
# WHAT IT DOES NOT DO
#   It does not acquire, release, or touch the GPU exclusivity lock, and it
#   changes no fleet serving state. On the M5 fleet a model load MUST hold
#   /tmp/mtplx-gpu-exclusive.lock: run this script UNDER the authorized blocking
#   lock wrapper (David runs it). It also never fetches, stages, or mutates
#   weights.
#
# USAGE
#   tools/qwen38-125b-a6b-load-memory-probe.sh \
#       --weights <WEIGHTS_DIR> \
#       [--worker <RUNTIME_WORKER_BIN>] \
#       [--out <OUTPUT_DIR>] \
#       [--interval-ms <N>]
#
#   Defaults: --worker .build/release/bench-worker
#             --weights $MLXFAST_WEIGHTS_PATH (else "weights")
#             --out ./load-memory-probe-<UTC timestamp>
#             --interval-ms 500

set -euo pipefail

WORKER_BIN="${MLXFAST_WORKER_BIN:-.build/release/bench-worker}"
WEIGHTS="${MLXFAST_WEIGHTS_PATH:-weights}"
OUT_DIR=""
INTERVAL_MS="${MLXFAST_PROBE_INTERVAL_MS:-500}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --weights) WEIGHTS="$2"; shift 2 ;;
    --worker) WORKER_BIN="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --interval-ms) INTERVAL_MS="$2"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "load-memory-probe: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done

if [ ! -x "$WORKER_BIN" ]; then
  echo "load-memory-probe: worker binary not found or not executable: $WORKER_BIN" >&2
  echo "  build+stage it first (setup.sh), or pass --worker <path>." >&2
  exit 1
fi
if [ ! -d "$WEIGHTS" ]; then
  echo "load-memory-probe: weights directory not found: $WEIGHTS" >&2
  exit 1
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="./load-memory-probe-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR"

SAMPLES_TSV="$OUT_DIR/memcomponents.tsv"
WORKER_LOG="$OUT_DIR/worker.stderr.log"
WORKER_OUT="$OUT_DIR/worker.stdout.log"

# vm_stat reports page counts; convert with the page size it prints itself.
PAGE_SIZE="$(vm_stat | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')"
if [ -z "$PAGE_SIZE" ]; then PAGE_SIZE=16384; fi

# Pull one vm_stat page-count field (matched on its label) as an integer.
vmstat_pages() {
  vm_stat | awk -v label="$1" '
    index($0, label) == 1 {
      v = $NF; gsub(/[^0-9]/, "", v); print v; exit
    }'
}

# Kernel memory pressure level: 1 = normal, 2 = warning, 4 = critical. This is
# the same signal the OS jetsam guard reacts to.
pressure_level() {
  sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo ""
}

echo "load-memory-probe: worker   = $WORKER_BIN"
echo "load-memory-probe: weights  = $WEIGHTS"
echo "load-memory-probe: out      = $OUT_DIR"
echo "load-memory-probe: interval = ${INTERVAL_MS} ms, page size = ${PAGE_SIZE} B"
echo "load-memory-probe: NOTE run this under the authorized blocking GPU-lock wrapper."

printf 'iso_utc\telapsed_s\tpressure_level\twired_bytes\tanon_bytes\tfilebacked_bytes\tcompressor_bytes\tworker_rss_bytes\n' >"$SAMPLES_TSV"

# Launch the load-only worker. stdin from /dev/null => the worker loads, warms,
# says hello, then reads EOF and exits on its own. MLXFAST_LOAD_MEMTRACE=1 turns
# on the loader's per-step activeMemory emission (off by default, diagnostic
# only, no effect on any measured path).
MLXFAST_LOAD_MEMTRACE=1 "$WORKER_BIN" runtime-worker --weights "$WEIGHTS" \
  </dev/null >"$WORKER_OUT" 2>"$WORKER_LOG" &
WORKER_PID=$!

cleanup() {
  if kill -0 "$WORKER_PID" 2>/dev/null; then
    kill "$WORKER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Fractional sleep interval in seconds (bash 3.2: use awk, no $((float))).
SLEEP_S="$(awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms/1000.0 }')"
START_EPOCH="$(date +%s)"

while kill -0 "$WORKER_PID" 2>/dev/null; do
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ELAPSED="$(( $(date +%s) - START_EPOCH ))"
  WIRED_P="$(vmstat_pages 'Pages wired down:')"
  ANON_P="$(vmstat_pages 'Anonymous pages:')"
  FILE_P="$(vmstat_pages 'File-backed pages:')"
  COMP_P="$(vmstat_pages 'Pages occupied by compressor:')"
  PRESSURE="$(pressure_level)"
  RSS_KB="$(ps -o rss= -p "$WORKER_PID" 2>/dev/null | tr -d ' ')"
  [ -z "$RSS_KB" ] && RSS_KB=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NOW_ISO" "$ELAPSED" "${PRESSURE:-NA}" \
    "$(( ${WIRED_P:-0} * PAGE_SIZE ))" \
    "$(( ${ANON_P:-0} * PAGE_SIZE ))" \
    "$(( ${FILE_P:-0} * PAGE_SIZE ))" \
    "$(( ${COMP_P:-0} * PAGE_SIZE ))" \
    "$(( RSS_KB * 1024 ))" >>"$SAMPLES_TSV"
  sleep "$SLEEP_S"
done

wait "$WORKER_PID"
WORKER_STATUS=$?
trap - EXIT INT TERM

echo
echo "load-memory-probe: worker exited with status $WORKER_STATUS"
echo "load-memory-probe: memory components -> $SAMPLES_TSV"
echo "load-memory-probe: worker load trace -> $WORKER_LOG"
echo
echo "== per-step MLX load trace (bytes) =="
grep '\[loadmemtrace\]' "$WORKER_LOG" || echo "(no [loadmemtrace] lines; was MLXFAST_LOAD_MEMTRACE honored by this build?)"
echo
echo "== memory-component peaks (bytes) =="
awk -F'\t' 'NR>1 {
    if ($4>wired) wired=$4; if ($5>anon) anon=$5;
    if ($6>file) file=$6; if ($7>comp) comp=$7;
    if ($8>rss) rss=$8; if ($3!="NA" && $3+0>press) press=$3+0
  }
  END {
    printf "  wired_max      = %d\n", wired;
    printf "  anon_max       = %d\n", anon;
    printf "  filebacked_max = %d\n", file;
    printf "  compressor_max = %d\n", comp;
    printf "  worker_rss_max = %d\n", rss;
    printf "  pressure_max   = %d\n", press;
  }' "$SAMPLES_TSV"

exit "$WORKER_STATUS"
