#!/usr/bin/env bash
# test-resident-up.sh -- prove tools/resident-up.sh without a model, a GPU or
# a network.
#
# WHAT THIS PROVES, with a stub bench-worker that binds its socket after a
# delay and answers the hello the way the real resident does:
#   1. a served window: the stub receives the contract argv (resident,
#      --weights, --speculative-protocol v1.1, --resource
#      qwen4exp.ngramRowSource=<weights dir> by default, --socket), the wrapped
#      command sees BENCH_WORKER_RESIDENT_SOCKET and the resident's identity
#      file, its exit code is returned, and after the window the stub, the
#      socket, the pidfile and the pgid file are all gone
#   2. --ngram and --hello-identity reach the stub and the command
#   3. the GPU lock must be HELD: nobody holding it refuses by name before any
#      boot; the refusal has no environment bypass
#   4. an unpinned iogpu wired limit refuses by name before any boot
#   5. a resident already up (live pidfile, or a socket that answers) refuses
#      by name, and the first window is left alone
#   6. a resident that dies before it is healthy fails the window, with its log
#   7. a resident that never binds fails on the health timeout
#   8. a resident that ignores SIGTERM is killed with the process group
#
# Hermetic: bash (3.2 on macOS is enough) and python3.
#
# Usage: tools/test-resident-up.sh
# Exit:  0 all cases pass, 1 a case failed (printed with a FAIL prefix)
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
RESIDENT_UP="${ROOT_DIR}/tools/resident-up.sh"

WORK="$(mktemp -d)"
trap 'cleanup' EXIT
LOCK_HOLDER_PID=""
cleanup() {
  [[ -n "${LOCK_HOLDER_PID}" ]] && kill "${LOCK_HOLDER_PID}" 2>/dev/null
  pkill -f "stub-bench-worker.py" 2>/dev/null
  rm -rf "${WORK}"
}

fails=0
pass() { printf 'test-resident-up: PASS -- %s\n' "$*"; }
fail() { printf 'test-resident-up: FAIL -- %s\n' "$*" >&2; fails=$((fails + 1)); }

# --- the stub resident --------------------------------------------------------
# Speaks the contract: validates argv, waits STUB_LOAD_S, binds the socket,
# then serves one connection at a time: on accept it sends the hello line
# (unprompted, ok:true, backend mlx-resident) and closes when the client does.
# STUB_DIE_BEFORE_BIND=1 exits 3 before binding. STUB_NEVER_BIND=1 sleeps
# forever without binding. STUB_IGNORE_TERM=1 ignores SIGTERM.
# It records its argv in STUB_ARGV_FILE.
STUB="${WORK}/stub-bench-worker.py"
cat > "${STUB}" <<'PY'
#!/usr/bin/env python3
import json, os, signal, socket, sys, time
argv = sys.argv[1:]
with open(os.environ["STUB_ARGV_FILE"], "w") as f:
    f.write("\n".join(argv) + "\n")
if not argv or argv[0] != "resident":
    print("stub: first argument must be resident", file=sys.stderr); sys.exit(2)
opts = {}
i = 1
while i < len(argv):
    if argv[i].startswith("--"):
        opts.setdefault(argv[i], []).append(argv[i + 1] if i + 1 < len(argv) else None); i += 2
    else:
        print(f"stub: stray argument {argv[i]}", file=sys.stderr); sys.exit(2)
for needed in ("--weights", "--socket", "--speculative-protocol", "--resource"):
    if needed not in opts:
        print(f"stub: missing {needed}", file=sys.stderr); sys.exit(2)
if opts["--speculative-protocol"] != ["v1.1"]:
    print("stub: --speculative-protocol must be v1.1", file=sys.stderr); sys.exit(2)
if os.environ.get("STUB_IGNORE_TERM") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
time.sleep(float(os.environ.get("STUB_LOAD_S", "1")))
if os.environ.get("STUB_DIE_BEFORE_BIND") == "1":
    print("stub: dying before bind, as asked", file=sys.stderr); sys.exit(3)
if os.environ.get("STUB_NEVER_BIND") == "1":
    while True:
        time.sleep(1)
path = opts["--socket"][0]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(4)
hello = {"id": 0, "nonce": "stubnonce", "ok": True, "protocol_version": 1,
         "backend": "mlx-resident", "device": "stub", "spec_modes": ["serial", "mtp"],
         "runner": {"id": "layr/stub"}, "resident": {"pid": os.getpid(), "load_epoch": 1}}
while True:
    conn, _ = srv.accept()
    try:
        conn.sendall((json.dumps(hello) + "\n").encode())
        while conn.recv(65536):
            pass
    except OSError:
        pass
    finally:
        conn.close()
PY
chmod +x "${STUB}"

# --- the lock, held by a background holder for the served cases --------------
LOCK="${WORK}/gpu.lock"
: > "${LOCK}"
hold_lock() {
  python3 - "${LOCK}" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "a+")
fcntl.flock(f, fcntl.LOCK_EX)
while True:
    time.sleep(1)
PY
  LOCK_HOLDER_PID=$!
  sleep 0.5
}
release_lock() {
  [[ -n "${LOCK_HOLDER_PID}" ]] && kill "${LOCK_HOLDER_PID}" 2>/dev/null
  wait "${LOCK_HOLDER_PID}" 2>/dev/null
  LOCK_HOLDER_PID=""
}

WEIGHTS="${WORK}/weights"; mkdir -p "${WEIGHTS}"
NGRAM="${WORK}/ngram"; mkdir -p "${NGRAM}"
WIRED_OK="${WORK}/wired-ok.sh"; printf '#!/bin/sh\necho 112000\n' > "${WIRED_OK}"; chmod +x "${WIRED_OK}"
WIRED_ZERO="${WORK}/wired-zero.sh"; printf '#!/bin/sh\necho 0\n' > "${WIRED_ZERO}"; chmod +x "${WIRED_ZERO}"

# run_up LOGDIR [ENV=VAL...] -- ARGS... : drive the real script with the stub.
run_up() {
  local logdir="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do envs+=("$1"); shift; done
  # The case's own ENV=VAL pairs come LAST, so a case can override a default.
  env MLXFAST_ENGINE_BIN="${STUB}" \
    RESIDENT_UP_LOG_DIR="${logdir}" \
    RESIDENT_UP_LOCK_PATH="${LOCK}" \
    RESIDENT_UP_WIRED_LIMIT_READER="${WIRED_OK}" \
    STUB_ARGV_FILE="${logdir}/stub-argv" \
    ${envs[@]+"${envs[@]}"} \
    "${RESIDENT_UP}" "$@" 2>&1
}

# --- 1. a served window ------------------------------------------------------
hold_lock
L1="${WORK}/case1"; mkdir -p "${L1}"
SOCK1="${WORK}/case1.sock"
out="$(run_up "${L1}" RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --socket "${SOCK1}" -- \
  bash -c 'echo "socket=$BENCH_WORKER_RESIDENT_SOCKET hello=${BENCH_WORKER_RESIDENT_HELLO:-unset} identity=$RESIDENT_IDENTITY_FILE"; test -S "$BENCH_WORKER_RESIDENT_SOCKET" && echo socket-live; kill -0 "$RESIDENT_UP_PID" && echo resident-live; exit 7')"
rc=$?
if [[ "${rc}" -eq 7 ]]; then pass "the wrapped command's exit code (7) is returned"; else fail "expected exit 7, got ${rc}: ${out}"; fi
if [[ "${out}" == *"socket=${SOCK1} hello=unset identity=${L1}/resident-identity.json"* && "${out}" == *"socket-live"* && "${out}" == *"resident-live"* ]]; then
  pass "the command runs with BENCH_WORKER_RESIDENT_SOCKET, no hello identity by default, and a live resident"
else
  fail "the command did not see the window: ${out}"
fi
if [[ -f "${L1}/stub-argv" ]] && grep -qx -- "resident" "${L1}/stub-argv" && grep -qx -- "--speculative-protocol" "${L1}/stub-argv" \
   && grep -qx -- "v1.1" "${L1}/stub-argv" && grep -qx -- "qwen4exp.ngramRowSource=${WEIGHTS}" "${L1}/stub-argv" \
   && grep -qx -- "${SOCK1}" "${L1}/stub-argv"; then
  pass "the resident received the contract argv; --ngram defaulted to the weights directory"
else
  fail "the resident argv is wrong: $(tr '\n' ' ' < "${L1}/stub-argv" 2>/dev/null)"
fi
if [[ "${out}" == *"resident healthy on ${SOCK1}"* ]]; then pass "the health probe read the resident's hello"; else fail "no health line: ${out}"; fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["hello"]["backend"]=="mlx-resident" and d["weight_owner"]=="bench-worker-resident"' "${L1}/resident-identity.json" 2>/dev/null; then
  pass "the identity file records the resident's hello"
else
  fail "identity file missing or wrong: $(cat "${L1}/resident-identity.json" 2>/dev/null)"
fi
sleep 0.5
if [[ ! -e "${SOCK1}" && ! -e "${L1}/resident.pid" && ! -e "${L1}/resident.pgid" ]] && ! pgrep -f "stub-bench-worker.py resident --weights ${WEIGHTS} --speculative-protocol v1.1 --resource qwen4exp.ngramRowSource=${WEIGHTS} --socket ${SOCK1}" >/dev/null; then
  pass "after the window: resident gone, socket, pidfile and pgid file removed"
else
  fail "the window left something behind: $(ls "${L1}" "${SOCK1}" 2>&1 | tr '\n' ' ')"
fi

# --- 2. --ngram and --hello-identity -----------------------------------------
L2="${WORK}/case2"; mkdir -p "${L2}"
SOCK2="${WORK}/case2.sock"
out="$(run_up "${L2}" RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --ngram "${NGRAM}" --hello-identity --socket "${SOCK2}" -- \
  bash -c 'echo "hello=${BENCH_WORKER_RESIDENT_HELLO:-unset}"')"
if [[ "${out}" == *"hello=1"* ]] && grep -qx -- "qwen4exp.ngramRowSource=${NGRAM}" "${L2}/stub-argv"; then
  pass "--ngram reaches the resident and --hello-identity exports BENCH_WORKER_RESIDENT_HELLO=1"
else
  fail "--ngram/--hello-identity not honoured: ${out} / $(tr '\n' ' ' < "${L2}/stub-argv" 2>/dev/null)"
fi

# --- 5. a resident already up refuses ----------------------------------------
L5="${WORK}/case5"; mkdir -p "${L5}"
SOCK5="${WORK}/case5.sock"
FIRST_OUT="${WORK}/case5.first"
( run_up "${L5}" RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --socket "${SOCK5}" -- \
    bash -c 'sleep 6; echo first-window-finished' > "${FIRST_OUT}" 2>&1 ) &
FIRST_PID=$!
for _ in $(seq 1 40); do [[ -S "${SOCK5}" ]] && break; sleep 0.2; done
out="$(run_up "${L5}" RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --socket "${SOCK5}" -- true)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"REFUSED (resident-already-up)"* && "${out}" == *"Nothing has been loaded"* ]]; then
  pass "a second window while a resident is up refuses by name (same pidfile)"
else
  fail "a second window did not refuse by name (rc ${rc}): ${out}"
fi
L5b="${WORK}/case5b"; mkdir -p "${L5b}"
out="$(run_up "${L5b}" RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --socket "${SOCK5}" -- true)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"REFUSED (resident-already-up)"* && "${out}" == *"already answers on ${SOCK5}"* ]]; then
  pass "a second window against a socket that answers refuses by name (different log dir)"
else
  fail "a socket that answers did not refuse (rc ${rc}): ${out}"
fi
wait "${FIRST_PID}"
if grep -q "first-window-finished" "${FIRST_OUT}"; then
  pass "the first window was left alone and finished"
else
  fail "the first window was disturbed: $(cat "${FIRST_OUT}")"
fi

# --- 6. a resident that dies before it is healthy ----------------------------
L6="${WORK}/case6"; mkdir -p "${L6}"
out="$(run_up "${L6}" STUB_DIE_BEFORE_BIND=1 RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --socket "${WORK}/case6.sock" -- echo should-not-run)"; rc=$?
if [[ "${rc}" -eq 1 && "${out}" == *"exited before it was healthy"* && "${out}" == *"dying before bind"* && "${out}" != *"should-not-run"* ]]; then
  pass "a resident that dies before it is healthy fails the window with its log, and the command never runs"
else
  fail "an early death was not reported (rc ${rc}): ${out}"
fi

# --- 7. a resident that never binds ------------------------------------------
L7="${WORK}/case7"; mkdir -p "${L7}"
out="$(run_up "${L7}" STUB_NEVER_BIND=1 RESIDENT_UP_HEALTH_TIMEOUT_S=3 --weights "${WEIGHTS}" --socket "${WORK}/case7.sock" -- echo should-not-run)"; rc=$?
if [[ "${rc}" -eq 1 && "${out}" == *"not healthy within 3s"* && "${out}" != *"should-not-run"* ]] && ! pgrep -f "case7.sock" >/dev/null; then
  pass "a resident that never binds fails on the health timeout and is torn down"
else
  fail "the health timeout did not fire or the resident survived (rc ${rc}): ${out}"
fi

# --- 8. a resident that ignores SIGTERM --------------------------------------
L8="${WORK}/case8"; mkdir -p "${L8}"
out="$(run_up "${L8}" STUB_IGNORE_TERM=1 RESIDENT_UP_HEALTH_TIMEOUT_S=30 --weights "${WEIGHTS}" --socket "${WORK}/case8.sock" -- true)"; rc=$?
sleep 0.5
if [[ "${rc}" -eq 0 && "${out}" == *"killing process group"* ]] && ! pgrep -f "case8.sock" >/dev/null; then
  pass "a resident that ignores SIGTERM is killed with its process group; nothing survives"
else
  fail "SIGTERM escalation failed (rc ${rc}): ${out}; survivors: $(pgrep -fl case8.sock | tr '\n' ' ')"
fi

release_lock

# --- 3. the lock must be held -------------------------------------------------
L3="${WORK}/case3"; mkdir -p "${L3}"
out="$(run_up "${L3}" --weights "${WEIGHTS}" --socket "${WORK}/case3.sock" -- echo should-not-run)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"REFUSED (lock-not-held)"* && "${out}" == *"Nothing has been loaded"* && ! -f "${L3}/stub-argv" ]]; then
  pass "nobody holding the GPU lock refuses by name before any boot"
else
  fail "an unheld lock did not refuse (rc ${rc}): ${out}"
fi
out="$(run_up "${L3}" RESIDENT_UP_SKIP_LOCK=1 RESIDENT_UP_LOCK_CHECK=0 --weights "${WEIGHTS}" --socket "${WORK}/case3.sock" -- echo should-not-run)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"REFUSED (lock-not-held)"* ]]; then
  pass "the lock refusal has no environment bypass"
else
  fail "an environment variable relaxed the lock refusal (rc ${rc}): ${out}"
fi
out="$(run_up "${L3}" RESIDENT_UP_LOCK_PATH="${WORK}/no-such-lock" --weights "${WEIGHTS}" --socket "${WORK}/case3.sock" -- echo should-not-run)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"REFUSED (lock-missing)"* ]]; then
  pass "a missing lock file refuses by name"
else
  fail "a missing lock file did not refuse (rc ${rc}): ${out}"
fi

# --- 4. the wired limit must be pinned ---------------------------------------
hold_lock
L4="${WORK}/case4"; mkdir -p "${L4}"
out="$(run_up "${L4}" RESIDENT_UP_WIRED_LIMIT_READER="${WIRED_ZERO}" --weights "${WEIGHTS}" --socket "${WORK}/case4.sock" -- echo should-not-run)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"REFUSED (wired-limit-unpinned)"* && ! -f "${L4}/stub-argv" ]]; then
  pass "an unpinned iogpu wired limit refuses by name before any boot"
else
  fail "an unpinned wired limit did not refuse (rc ${rc}): ${out}"
fi
release_lock

# --- argv refusals -------------------------------------------------------------
out="$("${RESIDENT_UP}" --weights "${WEIGHTS}" 2>&1)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"no command after '--'"* ]]; then pass "a missing command refuses"; else fail "missing command (rc ${rc}): ${out}"; fi
out="$("${RESIDENT_UP}" -- true 2>&1)"; rc=$?
if [[ "${rc}" -eq 2 && "${out}" == *"--weights <dir> is required"* ]]; then pass "a missing --weights refuses"; else fail "missing weights (rc ${rc}): ${out}"; fi

if [[ "${fails}" -eq 0 ]]; then
  printf 'test-resident-up: all cases pass\n'
  exit 0
fi
printf 'test-resident-up: %s case(s) failed\n' "${fails}" >&2
exit 1
