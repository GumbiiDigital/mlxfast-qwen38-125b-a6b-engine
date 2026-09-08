#!/usr/bin/env bash
#
# test-benchmark-facade-env.sh -- the benchd facade exports the track id.
#
# `benchd iterate` REQUIRES MLXFAST_QWEN_MTP_TRACK_ID in every mode (its
# `-{platform}-v{N}` suffix keys the official baseline pair; the official path
# resolves it before the gates-only branch), and this repository once exported
# it nowhere, so `./benchmark.sh --local-iterate` and `--official` both refused
# with "no track_id". tools/benchmark.sh now reads benchmark.json's `trackId`
# and exports it before dispatch. This suite pins that, by driving the REAL
# facade with a STUB benchd that records the environment and argv it was
# spawned with. Hermetic: no toolchain, weights, GPU, benchd binary or network.
#
# Cases:
#   1. --local-iterate: the stub sees MLXFAST_QWEN_MTP_TRACK_ID == benchmark.json
#      trackId, non-empty, on an `iterate --mode local-iterate` argv.
#   2. --official (gates-only env): the same export on `--mode official`.
#   3. a manifest with NO trackId: the facade refuses (exit 1, names the field)
#      and benchd is never spawned.
#   4. a caller pre-sets a DIFFERENT MLXFAST_QWEN_MTP_TRACK_ID: refused, never
#      overridden, benchd never spawned.
#   5. a caller pre-sets the SAME value: accepted.
#
# It then pins the RANKED path's resident wiring on
# tools/qwen38-125b-a6b-measure-and-score.sh, with a stub bench-worker that
# binds a socket and answers a hello the way the real resident does:
#   6. by default the measurement runs INSIDE a resident window: one
#      `bench-worker resident` is booted with the contract argv, and the
#      benchd the measure script dispatches sees BENCH_WORKER_RESIDENT_SOCKET
#      in its environment, so every per-phase worker benchd spawns can attach
#      instead of loading the checkpoint again.
#   7. MLXFAST_RESIDENT_WORKER=0 is the ONLY opt-out: the dispatch is direct, no
#      resident is booted, and BENCH_WORKER_RESIDENT_SOCKET is absent -- the
#      pre-resident behaviour, unchanged.
#   8. --preflight-only boots no resident: a pre-GPU dry run loads nothing, so
#      it must not open a GPU window.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FACADE="${REPO_ROOT}/tools/benchmark.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

command -v jq >/dev/null 2>&1 || { echo "test-benchmark-facade-env.sh: jq is required" >&2; exit 1; }

EXPECTED="$(jq -r '.trackId // empty' "${REPO_ROOT}/benchmark.json")"
if [[ -z "${EXPECTED}" ]]; then
  echo "test-benchmark-facade-env.sh: benchmark.json carries no trackId; nothing to pin" >&2
  exit 1
fi

# The stub benchd: records the track id env (or __UNSET__) and its argv, emits
# an empty JSON payload the way benchd would on stdout, exits 0.
STUB="${WORK}/benchd-stub"
cat > "${STUB}" <<'STUBEOF'
#!/usr/bin/env bash
# The facade probes `iterate --help` for --engine-resource before it spawns
# the real run; answer it the way a benchd with the flag does, and record
# nothing for the probe.
for arg in "$@"; do
  if [[ "${arg}" == "--help" ]]; then
    echo "usage: benchd iterate --engine <bin> --engine-resource <k=v>"
    exit 0
  fi
done
printf '%s\n' "${MLXFAST_QWEN_MTP_TRACK_ID-__UNSET__}" > "${STUB_CAPTURE_ENV}"
printf '%s\n' "$@" > "${STUB_CAPTURE_ARGV}"
echo '{}'
exit 0
STUBEOF
chmod 755 "${STUB}"

GOLDEN="${WORK}/golden.json"
echo '{}' > "${GOLDEN}"

# run_facade CASE FACADE_PATH [facade args...] -- runs a facade with the stub
# benchd; captures land in ${WORK}/<case>.env / .argv / .out; sets rc.
run_facade() {
  local case_name="$1" facade="$2"
  shift 2
  rm -f "${WORK}/${case_name}.env" "${WORK}/${case_name}.argv"
  env -u MLXFAST_QWEN_MTP_TRACK_ID \
    STUB_CAPTURE_ENV="${WORK}/${case_name}.env" \
    STUB_CAPTURE_ARGV="${WORK}/${case_name}.argv" \
    BENCHD="${STUB}" \
    MLXFAST_ENGINE_BIN="${STUB}" \
    MLXFAST_CORRECTNESS_GOLDEN_PATH="${GOLDEN}" \
    MLXFAST_SCORE_PATH="${WORK}/${case_name}.score.json" \
    MLXFAST_INTEGRITY_PATH="${WORK}/${case_name}.integrity.json" \
    "${EXTRA_ENV[@]}" \
    "${facade}" "$@" > "${WORK}/${case_name}.out" 2>&1
  rc=$?
}

# Case 1: --local-iterate exports the manifest's trackId.
EXTRA_ENV=(MLXFAST_NO_SANDBOX=1)
run_facade case1 "${FACADE}" --local-iterate
if [[ "${rc}" -ne 0 ]]; then
  fail "case 1: facade exited ${rc} with the stub benchd; output: $(cat "${WORK}/case1.out")"
fi
if [[ ! -f "${WORK}/case1.env" ]]; then
  fail "case 1: benchd was never spawned"
elif [[ "$(cat "${WORK}/case1.env")" != "${EXPECTED}" ]]; then
  fail "case 1: benchd saw MLXFAST_QWEN_MTP_TRACK_ID='$(cat "${WORK}/case1.env")', expected '${EXPECTED}'"
fi
if [[ -f "${WORK}/case1.argv" ]]; then
  if [[ "$(head -n 1 "${WORK}/case1.argv")" != "iterate" ]]; then
    fail "case 1: benchd subcommand is not iterate: $(head -n 1 "${WORK}/case1.argv")"
  fi
  if ! grep -qx -- '--mode' "${WORK}/case1.argv" || ! grep -qx -- 'local-iterate' "${WORK}/case1.argv"; then
    fail "case 1: argv does not carry --mode local-iterate: $(tr '\n' ' ' < "${WORK}/case1.argv")"
  fi
fi

# Case 2: --official, gates-only env (the seam-1 run the ranked box takes).
EXTRA_ENV=(MLXFAST_BENCHMARK_SKIP_TIMED=1 MLXFAST_BENCHMARK_CHECK_GATES=1)
run_facade case2 "${FACADE}" --official
if [[ "${rc}" -ne 0 ]]; then
  fail "case 2: facade exited ${rc} in official mode; output: $(cat "${WORK}/case2.out")"
fi
if [[ ! -f "${WORK}/case2.env" ]]; then
  fail "case 2: benchd was never spawned in official mode"
elif [[ "$(cat "${WORK}/case2.env")" != "${EXPECTED}" ]]; then
  fail "case 2: official mode: benchd saw MLXFAST_QWEN_MTP_TRACK_ID='$(cat "${WORK}/case2.env")', expected '${EXPECTED}'"
fi
if [[ -f "${WORK}/case2.argv" ]] && ! grep -qx -- 'official' "${WORK}/case2.argv"; then
  fail "case 2: argv does not carry --mode official: $(tr '\n' ' ' < "${WORK}/case2.argv")"
fi

# Case 3: a manifest with NO trackId refuses before benchd is spawned. The
# facade is copied into a throwaway tree whose benchmark.json lacks the field;
# it resolves the manifest relative to its own location, so nothing else moves.
mkdir -p "${WORK}/notrack/tools"
cp "${FACADE}" "${WORK}/notrack/tools/benchmark.sh"
jq 'del(.trackId)' "${REPO_ROOT}/benchmark.json" > "${WORK}/notrack/benchmark.json"
EXTRA_ENV=(MLXFAST_NO_SANDBOX=1)
run_facade case3 "${WORK}/notrack/tools/benchmark.sh" --local-iterate
if [[ "${rc}" -eq 0 ]]; then
  fail "case 3: facade ran with a manifest that carries no trackId"
fi
if ! grep -q 'trackId' "${WORK}/case3.out"; then
  fail "case 3: refusal does not name trackId; got: $(cat "${WORK}/case3.out")"
fi
if [[ -f "${WORK}/case3.env" ]]; then
  fail "case 3: benchd was spawned despite the missing trackId"
fi

# Case 4: a caller pre-sets a DIFFERENT track id -> refused, not overridden.
EXTRA_ENV=(MLXFAST_NO_SANDBOX=1 MLXFAST_QWEN_MTP_TRACK_ID=some-other-track-mlx-v9)
run_facade case4 "${FACADE}" --local-iterate
if [[ "${rc}" -eq 0 ]]; then
  fail "case 4: facade ran with a caller-set track id that differs from benchmark.json"
fi
if ! grep -q 'MLXFAST_QWEN_MTP_TRACK_ID' "${WORK}/case4.out"; then
  fail "case 4: refusal does not name the variable; got: $(cat "${WORK}/case4.out")"
fi
if [[ -f "${WORK}/case4.env" ]]; then
  fail "case 4: benchd was spawned despite the track id mismatch"
fi

# Case 5: a caller pre-sets the SAME value -> accepted, same export.
EXTRA_ENV=(MLXFAST_NO_SANDBOX=1 "MLXFAST_QWEN_MTP_TRACK_ID=${EXPECTED}")
run_facade case5 "${FACADE}" --local-iterate
if [[ "${rc}" -ne 0 ]]; then
  fail "case 5: facade refused a caller-set track id equal to benchmark.json's; output: $(cat "${WORK}/case5.out")"
fi
if [[ ! -f "${WORK}/case5.env" ]] || [[ "$(cat "${WORK}/case5.env")" != "${EXPECTED}" ]]; then
  fail "case 5: benchd did not see the expected track id"
fi

# ---------------------------------------------------------------------------
# Cases 6-8: the ranked measure script runs under ONE resident bench-worker.
#
# Hermetic root: the REAL measure script and the REAL resident wrapper, copied
# beside the REAL benchmark.json and track fixture so both resolve their own
# paths inside the sandbox. Nothing loads: the bench-worker is a stub that
# binds the socket and answers the hello, and benchd is a stub too.
# ---------------------------------------------------------------------------
MEASURE_REL="tools/qwen38-125b-a6b-measure-and-score.sh"
RES_ROOT="${WORK}/measure-root"
mkdir -p "${RES_ROOT}/tools" "${RES_ROOT}/fixtures" "${RES_ROOT}/weights"
cp "${REPO_ROOT}/${MEASURE_REL}" "${RES_ROOT}/tools/"
cp "${REPO_ROOT}/tools/resident-up.sh" "${RES_ROOT}/tools/"
# The measure script resolves the declared draft depth through the trusted
# declaration reader (tools/spec-declaration.sh); stage it beside the script.
cp "${REPO_ROOT}/tools/spec-declaration.sh" "${RES_ROOT}/tools/"
chmod +x "${RES_ROOT}/tools/"*.sh
cp "${REPO_ROOT}/benchmark.json" "${RES_ROOT}/benchmark.json"
cp "${REPO_ROOT}/fixtures/qwen3_8_125b_a6b_track.json" "${RES_ROOT}/fixtures/"

# The staged live golden. Its bytes are never read here (benchd re-verifies the
# {sha256, bytes} pin on a real run); the file only has to exist under the name
# the fixture's live_golden resolves to.
LIVE_GOLDEN_NAME="$(jq -r '.live_golden' "${RES_ROOT}/fixtures/qwen3_8_125b_a6b_track.json")"
GOLDEN_DIR="${WORK}/goldens"
mkdir -p "${GOLDEN_DIR}"
echo '{}' > "${GOLDEN_DIR}/${LIVE_GOLDEN_NAME}.golden.json"

# The stub benchd for these cases: it records whether the resident socket
# reached its environment, plus its argv, and answers `iterate --help` with the
# --engine-resource line the measure script probes for.
MEASURE_STUB="${WORK}/benchd-measure-stub"
cat > "${MEASURE_STUB}" <<'MEASURESTUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" == "--help" ]]; then
    echo "usage: benchd iterate --engine <bin> --engine-resource <k=v>"
    exit 0
  fi
done
printf '%s\n' "${BENCH_WORKER_RESIDENT_SOCKET-__UNSET__}" > "${STUB_CAPTURE_ENV}"
printf '%s\n' "$@" > "${STUB_CAPTURE_ARGV}"
echo '{}'
exit 0
MEASURESTUBEOF
chmod 755 "${MEASURE_STUB}"

# The stub bench-worker resident: records its argv, binds the socket, and sends
# the unprompted ok:true hello on every connection, as Engine Protocol v1 does.
WORKER_STUB="${WORK}/stub-bench-worker.py"
cat > "${WORKER_STUB}" <<'WORKERSTUBEOF'
#!/usr/bin/env python3
import json, os, signal, socket, sys
argv = sys.argv[1:]
with open(os.environ["STUB_ARGV_FILE"], "w") as f:
    f.write("\n".join(argv) + "\n")
if not argv or argv[0] != "resident":
    print("stub: first argument must be resident", file=sys.stderr); sys.exit(2)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
path = argv[argv.index("--socket") + 1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(4)
hello = {"id": 0, "nonce": "stubnonce", "ok": True, "protocol_version": 1,
         "backend": "mlx-resident", "device": "stub", "spec_modes": ["serial", "mtp"],
         "runner": {"id": "layr/stub"}, "resident": {"pid": os.getpid()}}
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
WORKERSTUBEOF
chmod +x "${WORKER_STUB}"

WIRED_OK="${WORK}/wired-ok.sh"
printf '#!/bin/sh\necho 112000\n' > "${WIRED_OK}"
chmod +x "${WIRED_OK}"

# run_measure CASE [ENV=VAL...] [args...] -- drives the REAL measure script in
# the hermetic root. Captures land in ${WORK}/<case>.env / .argv / .out, and the
# resident's own argv in ${WORK}/<case>.resident-argv when one was booted.
run_measure() {
  local case_name="$1"
  shift
  rm -f "${WORK}/${case_name}.env" "${WORK}/${case_name}.argv" "${WORK}/${case_name}.resident-argv"
  local logdir="${WORK}/${case_name}.residentlog"
  mkdir -p "${logdir}"
  local extra=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do extra+=("$1"); shift; done
  env -u BENCH_WORKER_RESIDENT_SOCKET -u MLXFAST_QWEN_MTP_TRACK_ID \
    STUB_CAPTURE_ENV="${WORK}/${case_name}.env" \
    STUB_CAPTURE_ARGV="${WORK}/${case_name}.argv" \
    STUB_ARGV_FILE="${WORK}/${case_name}.resident-argv" \
    BENCHD="${MEASURE_STUB}" \
    MLXFAST_ENGINE_BIN="${WORKER_STUB}" \
    MLXFAST_QWEN38_GOLDEN_DIR="${GOLDEN_DIR}" \
    MLXFAST_SCORE_PATH="${WORK}/${case_name}.score.json" \
    RESIDENT_UP_LOCK_PATH="${WORK}/${case_name}.gpu.lock" \
    RESIDENT_UP_LOG_DIR="${logdir}" \
    RESIDENT_UP_WIRED_LIMIT_READER="${WIRED_OK}" \
    RESIDENT_UP_HEALTH_TIMEOUT_S=60 \
    MLXFAST_GPU_LOCK_TIMEOUT_S=60 \
    ${extra[@]+"${extra[@]}"} \
    "${RES_ROOT}/${MEASURE_REL}" "$@" > "${WORK}/${case_name}.out" 2>&1
  rc=$?
}

# Case 6: the default is a resident window.
run_measure case6
if [[ "${rc}" -ne 0 ]]; then
  fail "case 6: the measure script exited ${rc} under the resident window; output: $(cat "${WORK}/case6.out")"
fi
if [[ ! -f "${WORK}/case6.env" ]]; then
  fail "case 6: benchd was never dispatched; output: $(cat "${WORK}/case6.out")"
elif [[ "$(cat "${WORK}/case6.env")" == "__UNSET__" ]]; then
  fail "case 6: the measurement ran WITHOUT BENCH_WORKER_RESIDENT_SOCKET, so every phase would load the checkpoint again"
elif [[ "$(cat "${WORK}/case6.env")" != *"bench-worker-resident"* ]]; then
  fail "case 6: BENCH_WORKER_RESIDENT_SOCKET is not a resident socket path: $(cat "${WORK}/case6.env")"
fi
if [[ -f "${WORK}/case6.resident-argv" ]] \
   && grep -qx -- 'resident' "${WORK}/case6.resident-argv" \
   && grep -qx -- "${RES_ROOT}/weights" "${WORK}/case6.resident-argv" \
   && grep -qx -- "qwen4exp.ngramRowSource=${RES_ROOT}/weights" "${WORK}/case6.resident-argv"; then
  : # one resident, booted with the contract argv over the same weights
else
  fail "case 6: no resident was booted with the contract argv: $(cat "${WORK}/case6.resident-argv" 2>/dev/null | tr "\n" " ")"
fi
if [[ -f "${WORK}/case6.argv" ]] && ! grep -qx -- 'official' "${WORK}/case6.argv"; then
  fail "case 6: the dispatch is not --mode official: $(tr '\n' ' ' < "${WORK}/case6.argv")"
fi

# Case 7: MLXFAST_RESIDENT_WORKER=0 is the only opt-out.
run_measure case7 MLXFAST_RESIDENT_WORKER=0
if [[ "${rc}" -ne 0 ]]; then
  fail "case 7: the measure script exited ${rc} with the resident opted out; output: $(cat "${WORK}/case7.out")"
fi
if [[ ! -f "${WORK}/case7.env" ]]; then
  fail "case 7: benchd was never dispatched; output: $(cat "${WORK}/case7.out")"
elif [[ "$(cat "${WORK}/case7.env")" != "__UNSET__" ]]; then
  fail "case 7: BENCH_WORKER_RESIDENT_SOCKET reached benchd despite MLXFAST_RESIDENT_WORKER=0: $(cat "${WORK}/case7.env")"
fi
if [[ -f "${WORK}/case7.resident-argv" ]]; then
  fail "case 7: a resident was booted despite MLXFAST_RESIDENT_WORKER=0: $(tr '\n' ' ' < "${WORK}/case7.resident-argv")"
fi
if [[ -e "${WORK}/case7.gpu.lock" ]]; then
  fail "case 7: the opt-out path took the GPU lock; it must be the pre-resident behaviour"
fi

# Case 8: a pre-GPU dry run opens no window.
run_measure case8 --preflight-only
if [[ "${rc}" -ne 0 ]]; then
  fail "case 8: --preflight-only exited ${rc}; output: $(cat "${WORK}/case8.out")"
fi
if [[ -f "${WORK}/case8.resident-argv" ]]; then
  fail "case 8: --preflight-only booted a resident: $(tr '\n' ' ' < "${WORK}/case8.resident-argv")"
fi
if [[ -f "${WORK}/case8.argv" ]] && ! grep -qx -- 'validate-golden' "${WORK}/case8.argv"; then
  fail "case 8: --preflight-only did not dispatch validate-golden: $(tr '\n' ' ' < "${WORK}/case8.argv")"
fi

if [[ "${failures}" -eq 0 ]]; then
  echo "test-benchmark-facade-env.sh: all 8 cases passed (trackId=${EXPECTED})"
  exit 0
fi
echo "test-benchmark-facade-env.sh: ${failures} case(s) failed" >&2
exit 1
