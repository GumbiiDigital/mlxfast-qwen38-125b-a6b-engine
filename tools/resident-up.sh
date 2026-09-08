#!/usr/bin/env bash
# resident-up.sh -- boot the ONE resident bench-worker for a benchmark window,
# run a command against it, then tear it down.
#
# WEIGHTS LOAD ONCE PER WINDOW. benchd spawns `bench-worker runtime-worker`
# once per phase (warmup, timed prefill, timed decode, correctness, and again
# for every leg). In process, each spawn loads the 113 GB checkpoint. So the
# weights get an OWNER: `bench-worker resident` (fork contract section 12f).
# This script boots exactly one of them, inside the caller's GPU-lock window,
# and exports BENCH_WORKER_RESIDENT_SOCKET. Every per-phase worker attaches to
# it and loads nothing. This is the Mac counterpart of the CUDA track's
# tools/serve-up.sh, with the same rules: caller owns the lock, one resident,
# no path leaves it up.
#
# GPU LOCK -- NOT TAKEN HERE, BUT REQUIRED. The caller owns the box GPU window
# (the ranked workflow holds /tmp/mtplx-gpu-exclusive.lock for the whole
# measurement) and this script boots the resident inside it. A resident holds
# ~113 GB of unified memory, so it must never outlive that window. The script
# checks that the lock is HELD (a non-blocking try-lock must fail) and refuses
# by name when nobody holds it. It never takes the lock itself, because a
# lock this script took would be released when this script exits, which is
# not the window.
#
# ONE RESIDENT PER BOX. A second resident would double-load the checkpoint.
# The script refuses by name when its pidfile names a live resident, or when a
# resident already answers on the socket.
#
# Usage:
#   tools/resident-up.sh --weights <dir> [--ngram <dir>] [--hello-identity]
#                        [--socket <path>] -- <command> [args...]
#
#   --weights <dir>    the transformed weights directory (`weights/` from
#                      setup.sh). Required.
#   --ngram <dir>      the n-gram row-source directory, passed to the resident
#                      as --resource qwen4exp.ngramRowSource=<dir>. Default: the
#                      weights directory (the fixture's ngram_shard_dir).
#   --hello-identity   export BENCH_WORKER_RESIDENT_HELLO=1 to the command, so
#                      each attached hello carries the resident's pid and
#                      load_epoch. Off by default until benchd admits the field.
#   --socket <path>    the resident's Unix socket. Default: a pid-keyed path
#                      under ${TMPDIR:-/tmp}. A Unix socket path holds 103
#                      bytes on macOS; a socket under the checkout would not
#                      bind on the ranked box.
#
# Environment (test seams and locations; none relaxes a refusal):
#   MLXFAST_ENGINE_BIN               the bench-worker binary benchd spawns
#                                    (default <repo>/.build/release/bench-worker,
#                                    the staged pair tools/stage-bench-worker.sh
#                                    writes, with mlx.metallib beside it; the
#                                    same variable and default the measure
#                                    script reads, so the resident and every
#                                    attaching phase run ONE binary)
#   RESIDENT_UP_LOG_DIR              pidfile, pgid file, identity file, resident
#                                    log (default <repo>/.build/resident)
#   RESIDENT_UP_LOCK_PATH            the GPU lock file (default
#                                    /tmp/mtplx-gpu-exclusive.lock)
#   RESIDENT_UP_HEALTH_TIMEOUT_S     ceiling on the load + first hello
#                                    (default 5400)
#   RESIDENT_UP_WIRED_LIMIT_READER   command printing iogpu.wired_limit_mb
#                                    (default `sysctl -n iogpu.wired_limit_mb`)
#
# Exit codes: the wrapped command's exit code on a served window; 1 on a boot
# failure; 2 on a refusal before any load.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
log() { printf 'resident-up.sh: %s\n' "$*" >&2; }
die() { printf 'resident-up.sh: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'resident-up.sh: REFUSED (%s): %s\n' "$1" "$2" >&2; exit 2; }

usage() {
  sed -n '27,40p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

# --- argv --------------------------------------------------------------------
WEIGHTS_DIR=""
NGRAM_DIR=""
SOCKET_PATH=""
HELLO_IDENTITY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --weights) [[ $# -ge 2 ]] || refuse bad-argument "--weights needs a directory"; WEIGHTS_DIR="$2"; shift 2 ;;
    --ngram) [[ $# -ge 2 ]] || refuse bad-argument "--ngram needs a directory"; NGRAM_DIR="$2"; shift 2 ;;
    --socket) [[ $# -ge 2 ]] || refuse bad-argument "--socket needs a path"; SOCKET_PATH="$2"; shift 2 ;;
    --hello-identity) HELLO_IDENTITY=1; shift ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) refuse bad-argument "unknown argument '$1' (usage: --weights <dir> [--ngram <dir>] [--hello-identity] [--socket <path>] -- <command> [args...])" ;;
  esac
done
[[ $# -ge 1 ]] || refuse bad-argument "no command after '--'"
[[ -n "${WEIGHTS_DIR}" ]] || refuse bad-argument "--weights <dir> is required"
[[ -d "${WEIGHTS_DIR}" ]] || refuse weights-missing "weights directory is missing: '${WEIGHTS_DIR}'"
NGRAM_DIR="${NGRAM_DIR:-${WEIGHTS_DIR}}"
[[ -d "${NGRAM_DIR}" ]] || refuse ngram-missing "n-gram row-source directory is missing: '${NGRAM_DIR}'"

command -v python3 >/dev/null 2>&1 || refuse tool-missing "python3 is required (it speaks the resident's hello probe and the lock check)"

BENCH_WORKER="${MLXFAST_ENGINE_BIN:-${SCRIPT_DIR}/.build/release/bench-worker}"
[[ -x "${BENCH_WORKER}" ]] || refuse worker-missing "bench-worker is missing or not executable: ${BENCH_WORKER} (build and stage it: setup.sh, or swift build -c release --scratch-path .build-worker --product bench-worker && tools/stage-bench-worker.sh)"

LOG_DIR="${RESIDENT_UP_LOG_DIR:-${SCRIPT_DIR}/.build/resident}"
LOCK_PATH="${RESIDENT_UP_LOCK_PATH:-/tmp/mtplx-gpu-exclusive.lock}"
HEALTH_TIMEOUT_S="${RESIDENT_UP_HEALTH_TIMEOUT_S:-5400}"
[[ "${HEALTH_TIMEOUT_S}" =~ ^[1-9][0-9]*$ ]] || refuse bad-argument "RESIDENT_UP_HEALTH_TIMEOUT_S must be a positive integer (got '${HEALTH_TIMEOUT_S}')"
WIRED_LIMIT_READER="${RESIDENT_UP_WIRED_LIMIT_READER:-sysctl -n iogpu.wired_limit_mb}"

mkdir -p "${LOG_DIR}"
RUN_TAG="$$-$(date -u +%Y%m%dT%H%M%SZ)"
SOCKET_PATH="${SOCKET_PATH:-${TMPDIR:-/tmp}/bench-worker-resident.${RUN_TAG}.sock}"
PIDFILE="${LOG_DIR}/resident.pid"
PGIDFILE="${LOG_DIR}/resident.pgid"
IDENTITY_FILE="${LOG_DIR}/resident-identity.json"
RESIDENT_LOG="${LOG_DIR}/resident.${RUN_TAG}.log"

# --- the GPU lock must be HELD by the caller ---------------------------------
# A non-blocking try-lock on a NEW open file description fails only when
# someone holds the lock. Success means nobody does: the caller is not inside
# a GPU window, and the try-lock is released at once.
lock_is_held() {
  python3 - "$1" <<'PY'
import fcntl, sys
try:
    f = open(sys.argv[1], "a+")
except OSError as err:
    print(f"cannot open the lock file: {err}", file=sys.stderr); sys.exit(2)
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)          # held by someone: the caller is inside a window
fcntl.flock(f, fcntl.LOCK_UN)
sys.exit(1)              # nobody holds it
PY
}
[[ -e "${LOCK_PATH}" ]] || refuse lock-missing "the GPU lock file does not exist: ${LOCK_PATH} (see the runbook, step 2)"
if ! lock_is_held "${LOCK_PATH}"; then
  refuse lock-not-held "nobody holds ${LOCK_PATH}; the caller must take the GPU lock for the whole window before booting a resident (flock, then run this script inside it). Nothing has been loaded."
fi

# --- the wired limit must be pinned ------------------------------------------
# The box runbook's boot daemon pins iogpu.wired_limit_mb so a 113 GB resident
# can be wired. This script verifies the pin and never sets it.
wired_limit_mb="$(${WIRED_LIMIT_READER} 2>/dev/null | tr -d '[:space:]' || true)"
if ! [[ "${wired_limit_mb}" =~ ^[0-9]+$ ]] || (( wired_limit_mb <= 0 )); then
  refuse wired-limit-unpinned "iogpu.wired_limit_mb is not pinned (reader '${WIRED_LIMIT_READER}' gave '${wired_limit_mb:-nothing}'); the boot daemon of the runbook sets it. Nothing has been loaded."
fi

# --- one resident per box ----------------------------------------------------
# The hello probe: connect, read the first line. The worker sends its hello
# unprompted at session start (hello is not a request kind in Engine Protocol
# v1), so a connection that receives an ok:true hello has found a live
# resident. The probe closes at once, which ends its session.
probe_resident() {
  python3 - "$1" <<'PY'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sys.argv[1])
    line = b""
    while not line.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        line += chunk
    s.close()
    reply = json.loads(line.decode())
except Exception as err:                       # noqa: BLE001 - any failure is unhealthy
    print(f"probe failed: {err}", file=sys.stderr)
    sys.exit(1)
if reply.get("ok") is not True:
    print(f"probe refused: {reply}", file=sys.stderr)
    sys.exit(1)
print(json.dumps({k: reply.get(k) for k in
                  ("backend", "device", "protocol_version", "spec_modes", "runner", "resident")}))
PY
}

if [[ -r "${PIDFILE}" ]]; then
  old_pid="$(tr -d '[:space:]' < "${PIDFILE}")"
  if [[ "${old_pid}" =~ ^[0-9]+$ ]] && kill -0 "${old_pid}" 2>/dev/null; then
    old_args="$(ps -o args= -p "${old_pid}" 2>/dev/null || true)"
    case "${old_args}" in
      *bench-worker*resident*)
        refuse resident-already-up "a resident is already running: pid ${old_pid} ('${old_args}'), recorded in ${PIDFILE}. One resident per box; halt it first (tools/resident-halt: SIGTERM the pgid in ${PGIDFILE}). Nothing has been loaded." ;;
      *)
        log "stale pidfile ${PIDFILE}: pid ${old_pid} is not a resident ('${old_args}'); removing it" ;;
    esac
  fi
  rm -f "${PIDFILE}" "${PGIDFILE}"
fi
if [[ -S "${SOCKET_PATH}" ]]; then
  if probe_resident "${SOCKET_PATH}" >/dev/null 2>&1; then
    refuse resident-already-up "a resident already answers on ${SOCKET_PATH}. One resident per box. Nothing has been loaded."
  fi
  log "stale socket ${SOCKET_PATH} (nothing answers); removing it"
  rm -f "${SOCKET_PATH}"
fi

# --- teardown ----------------------------------------------------------------
# ALWAYS. The resident holds the GPU and ~113 GB of unified memory, so it never
# outlives this script: the window that booted it tears it down, on success and
# on failure alike. SIGTERM to the process, then the process group, then
# SIGKILL to the group; the script then proves that nothing of the group is
# left. There is deliberately no path that leaves it up.
RESIDENT_PID=""
RESIDENT_PGID=""

group_members() { ps -o pid= -g "${RESIDENT_PGID}" 2>/dev/null | tr -d ' ' | grep -v '^$' || true; }

teardown() {
  if [[ -n "${RESIDENT_PID}" ]] && kill -0 "${RESIDENT_PID}" 2>/dev/null; then
    kill -TERM "${RESIDENT_PID}" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "${RESIDENT_PID}" 2>/dev/null || break
      sleep 0.2
    done
  fi
  if [[ -n "${RESIDENT_PGID}" && "${RESIDENT_PGID}" != "$$" ]] && [[ -n "$(group_members)" ]]; then
    kill -TERM -- "-${RESIDENT_PGID}" 2>/dev/null || true
    for _ in $(seq 1 25); do
      [[ -n "$(group_members)" ]] || break
      sleep 0.2
    done
    if [[ -n "$(group_members)" ]]; then
      log "resident did not stop on SIGTERM; killing process group ${RESIDENT_PGID}"
      kill -KILL -- "-${RESIDENT_PGID}" 2>/dev/null || true
      sleep 0.3
    fi
    if [[ -n "$(group_members)" ]]; then
      log "FAILED to halt the resident: process(es) $(group_members | tr '\n' ' ')of group ${RESIDENT_PGID} survived SIGKILL"
    fi
  fi
  if [[ -n "${RESIDENT_PID}" ]]; then
    log "resident torn down; its log is ${RESIDENT_LOG}"
  fi
  rm -f "${SOCKET_PATH}" "${PIDFILE}" "${PGIDFILE}" 2>/dev/null || true
}
trap teardown EXIT
trap 'exit 130' INT TERM

# --- boot the one resident ---------------------------------------------------
# The resident leads its own process group (setsid through python, which macOS
# has and util-linux setsid it does not), so the halt path can signal the
# group and reach anything the worker spawned.
log "booting the resident: ${BENCH_WORKER} resident --weights ${WEIGHTS_DIR} (n-gram rows from ${NGRAM_DIR}); ONE load for the whole window"
python3 - "${BENCH_WORKER}" resident \
  --weights "${WEIGHTS_DIR}" \
  --speculative-protocol v1.1 \
  --resource "qwen4exp.ngramRowSource=${NGRAM_DIR}" \
  --socket "${SOCKET_PATH}" >"${RESIDENT_LOG}" 2>&1 <<'PY' &
import os, sys
os.setsid()
os.execv(sys.argv[1], sys.argv[1:])
PY
RESIDENT_PID=$!
RESIDENT_PGID="${RESIDENT_PID}"
printf '%s\n' "${RESIDENT_PID}" > "${PIDFILE}"
printf '%s\n' "${RESIDENT_PGID}" > "${PGIDFILE}"

start="$(date +%s)"
while :; do
  if ! kill -0 "${RESIDENT_PID}" 2>/dev/null; then
    log "the resident exited before it was healthy; its log:"
    tail -40 "${RESIDENT_LOG}" >&2 || true
    exit 1
  fi
  if [[ -S "${SOCKET_PATH}" ]] && probe_resident "${SOCKET_PATH}" >/dev/null 2>&1; then
    break
  fi
  now="$(date +%s)"
  if (( now - start >= HEALTH_TIMEOUT_S )); then
    log "the resident was not healthy within ${HEALTH_TIMEOUT_S}s; its log:"
    tail -40 "${RESIDENT_LOG}" >&2 || true
    exit 1
  fi
  sleep 2
done
log "resident healthy on ${SOCKET_PATH} after $(( $(date +%s) - start ))s; every phase now attaches instead of loading"

HELLO_JSON="$(probe_resident "${SOCKET_PATH}")" || die "the resident stopped answering before the run started"

# --- the window's identity ---------------------------------------------------
python3 - "${IDENTITY_FILE}" "${HELLO_JSON}" <<PY
import json, sys
json.dump({
    "engine": "bench-worker",
    "weight_owner": "bench-worker-resident",
    "resident_socket": "${SOCKET_PATH}",
    "resident_pid": ${RESIDENT_PID},
    "resident_pgid": ${RESIDENT_PGID},
    "bench_worker": "${BENCH_WORKER}",
    "weights_dir": "${WEIGHTS_DIR}",
    "ngram_dir": "${NGRAM_DIR}",
    "hello_identity": ${HELLO_IDENTITY},
    "hello": json.loads(sys.argv[2]),
    "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
}, open(sys.argv[1], "w"), indent=2)
PY

export BENCH_WORKER_RESIDENT_SOCKET="${SOCKET_PATH}"
if [[ "${HELLO_IDENTITY}" == "1" ]]; then
  export BENCH_WORKER_RESIDENT_HELLO=1
else
  unset BENCH_WORKER_RESIDENT_HELLO || true
fi
export RESIDENT_IDENTITY_FILE="${IDENTITY_FILE}"
export RESIDENT_UP_PID="${RESIDENT_PID}"

log "running: $*"
set +e
"$@"
rc=$?
set -e
exit "${rc}"
