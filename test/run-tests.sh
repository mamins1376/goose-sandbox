#!/usr/bin/env bash
#
# End-to-end test of the timeout behaviour, run inside the sandbox image.
#
#   ./run-tests.sh
#
# No API key and no internet access to a provider are needed: a mock
# [OI]-compatible SSE server runs on the host and plays back the failure
# shapes this fork cares about. The container reaches it with
# --network host, which is the only reason this script is less strict than
# run.sh.
#
# What it establishes:
#   A  a 3 s prefill succeeds against a 1 s    -> the first-line budget is a
#      inter-chunk window                           window of its own: the gap
#                                                   between headers and the first
#                                                   line is not charged to the
#                                                   chunk budget
#   B  the SAME 3 s prefill fails when the      -> the budget is actually live,
#      first-line budget is lowered to 2 s         so A is a real measurement
#      and the error names 2 s
#   C  a provider-level override of 1 s reaches  -> per-provider config works
#      the timer and is named in the error
#   D  a stall after output still reports the    -> the idle window is unchanged
#      inter-chunk error, not the prefill one
#   E  2 s of silence AFTER the headers, 1 s     -> the timer measures the gap
#      budget: it fires                             after the headers
#   F  the same 2 s of silence BEFORE the        -> ...and cannot see the gap
#      headers, same 1 s budget: it does not        before them; request completes
#
# A-D duplicate, at HTTP level, unit tests that already exist in the fork
# (crates/goose-providers/src/stream_util.rs). E and F do not: they test where
# the response headers end, which a test over a Stream cannot observe. Keep
# B (the counter-measurement) and E/F (the boundary) if you ever trim this.
#
# SPEED. Three things keep this under a minute:
#
#  1. The cases run in PARALLEL. They were already independent (own port, own
#     GOOSE_PATH_ROOT, own container) and the mock is a ThreadingHTTPServer, so
#     the suite costs max(case) instead of sum(case). The per-case timings
#     printed below therefore overlap; only the total at the end is wall clock.
#  2. GOOSE_PROVIDER_SKIP_BACKOFF=true. A first-line timeout is retried by
#     `agents/reply_parts.rs` ("Provider stream failed before its first item")
#     with `RetryConfig::default()`: 3 retries and 1 s/2 s/4 s backoff. The
#     retries still happen -- the same error is still asserted -- but the 7 s of
#     sleeping per case is skipped, which is ~21 s of the suite. Nothing here
#     asserts pacing, so no assertion depends on it.
#  3. The budgets and mock delays are as small as still discriminating. A timed
#     out case costs 4x budget (the retries), so the budget is the multiplier;
#     each one just has to sit below the delay it is meant to catch. Keep them
#     at 1 s or above -- below that this measures the scheduler, not goose. And
#     A's prefill must exceed the chunk window pinned on its provider (1 s), or
#     it stops being a test of a slow-but-healthy prefill at all.
#
# GOOSE_DISABLE_SESSION_NAMING is set so each case measures exactly ONE stream.
# Otherwise goose also spawns a background "name this session" request
# (agent.rs -> session_manager::maybe_update_name) that runs concurrently, hangs
# its own connection against the mock and logs its own llm_request file.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMAGE="${GOOSE_IMAGE:-localhost/goose-custom:a5baa00712}"
ENGINE="${CONTAINER_ENGINE:-podman}"
SLOW_PORT=8201   # 3 s prefill, 1 s chunk window
FAST_PORT=8202   # never sends anything
DEAD_PORT=8203   # one chunk, then silence
PRE_PORT=8205    # 2 s delay AFTER headers
HDR_PORT=8206    # 2 s delay BEFORE headers

WORK=$(mktemp -d)
ROOT="$WORK/root"
OUT="$WORK/out"
mkdir -p "$ROOT/config/custom_providers" "$OUT"
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

provider() { # name port [extra json fields]
    local name="$1" port="$2" extra="${3:-}"
    local tail=""
    [ -n "$extra" ] && tail=$',\n  '"$extra"
    cat > "$ROOT/config/custom_providers/$name.json" <<EOF
{
  "name": "$name",
  "engine": "openai",
  "display_name": "Mock $name",
  "base_url": "http://127.0.0.1:$port/v1/chat/completions",
  "api_key_env": "MOCK_API_KEY",
  "requires_auth": false,
  "supports_streaming": true,
  "models": [{ "name": "mock-1", "context_limit": 128000 }]$tail
}
EOF
}

provider mockslow     "$SLOW_PORT" '"stream_chunk_timeout_secs": 1'
provider mockfastline "$FAST_PORT" '"stream_first_line_timeout_secs": 1'
provider mockdead     "$DEAD_PORT" '"stream_chunk_timeout_secs": 3'
provider mockpre2     "$PRE_PORT"  '"stream_first_line_timeout_secs": 1'
provider mockhdr2     "$HDR_PORT"  '"stream_first_line_timeout_secs": 1'

cat > "$ROOT/config/config.yaml" <<'EOF'
GOOSE_TELEMETRY_ENABLED: false
GOOSE_CLI_SHOW_COST: false
GOOSE_DISABLE_KEYRING: true
providers:
  mockslow:     {enabled: true, model: mock-1, configured: true}
  mockfastline: {enabled: true, model: mock-1, configured: true}
  mockdead:     {enabled: true, model: mock-1, configured: true}
  mockpre2:     {enabled: true, model: mock-1, configured: true}
  mockhdr2:     {enabled: true, model: mock-1, configured: true}
EOF

echo "==> starting mock providers"
python3 mock_sse.py slow-prefill    "$SLOW_PORT" 3  & pids+=($!)
python3 mock_sse.py dead-from-start "$FAST_PORT"    & pids+=($!)
python3 mock_sse.py dead-midstream  "$DEAD_PORT"    & pids+=($!)
python3 mock_sse.py slow-prefill    "$PRE_PORT" 2   & pids+=($!)
python3 mock_sse.py slow-headers    "$HDR_PORT" 2   & pids+=($!)
sleep 1

run_goose() { # provider [extra --env ...]
    local provider="$1"; shift
    local _t0=$SECONDS
    local _out
    _out=$(run_goose_inner "$provider" "$@")
    echo "      [${provider}: $((SECONDS - _t0))s]" >&2
    printf '%s' "$_out"
}

run_goose_inner() { # provider [extra --env ...]
    local provider="$1"; shift
    timeout 300 "$ENGINE" run --rm --read-only --network host \
        --cap-drop=ALL --security-opt=no-new-privileges \
        --tmpfs /tmp:rw,size=64m,mode=1777 \
        --tmpfs /home/goose/.local:rw,size=64m,mode=1777 \
        --tmpfs /home/goose/.cache:rw,size=256m,mode=1777 \
        -v "$ROOT:/goose-root:Z" \
        --userns=keep-id:uid=1000,gid=1000 \
        --env GOOSE_PATH_ROOT=/goose-root \
        --env GOOSE_PROVIDER="$provider" \
        --env GOOSE_MODEL=mock-1 \
        --env MOCK_API_KEY=none \
        --env GOOSE_TELEMETRY_ENABLED=false \
        --env GOOSE_DISABLE_KEYRING=true \
        --env GOOSE_DISABLE_SESSION_NAMING=true \
        --env GOOSE_PROVIDER_SKIP_BACKOFF=true \
        --env HTTP_PROXY= --env HTTPS_PROXY= --env http_proxy= --env https_proxy= \
        "$@" \
        "$IMAGE" run -t "say hello" 2>&1
}

# --- the six cases, each in its own function so they can run concurrently ----

case_A() { run_goose mockslow; }
case_B() { run_goose mockslow --env GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=2; }
case_C() { run_goose mockfastline; }
case_D() { run_goose mockdead; }
case_E() { run_goose mockpre2 --env GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=1; }
case_F() { run_goose mockhdr2 --env GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=1; }

echo "==> running A-F in parallel (each case is one container)"
suite_t0=$SECONDS
case_pids=()
for c in A B C D E F; do
    ( "case_$c" > "$OUT/$c.out" 2> "$OUT/$c.err" ) &
    case_pids+=($!)
done
for p in "${case_pids[@]}"; do wait "$p"; done

pass=0; fail=0
check() { # label haystack needle
    if grep -qF -- "$3" <<<"$2"; then
        echo "  PASS  $1"; pass=$((pass + 1))
    else
        echo "  FAIL  $1"; echo "        expected to find: $3"; fail=$((fail + 1))
    fi
}
check_absent() { # label haystack needle
    if grep -qF -- "$3" <<<"$2"; then
        echo "  FAIL  $1"; echo "        expected NOT to find: $3"; fail=$((fail + 1))
    else
        echo "  PASS  $1"; pass=$((pass + 1))
    fi
}
out_of() { cat "$OUT/$1.out"; }
timing_of() { cat "$OUT/$1.err"; }

echo "==> A: 3 s prefill, 1 s chunk window (expect success)"; timing_of A
check "slow prefill survives" "$(out_of A)" "hello world"

echo "==> B: same 3 s prefill, first-line budget forced to 2 s (expect failure naming 2s)"; timing_of B
check "budget is live" "$(out_of B)" "no response within 2s"

echo "==> C: provider-level override stream_first_line_timeout_secs=1 (expect failure naming 1s)"; timing_of C
check "per-provider override reaches the timer" "$(out_of C)" "no response within 1s"

echo "==> D: stall after the first chunk, 3 s window (expect the idle message, not the prefill one)"; timing_of D
check "idle window unchanged" "$(out_of D)" "Stream timed out waiting for next chunk"

# E/F document the boundary of the first-line budget. Both mocks sit silent for
# 2 s with a 1 s budget; the only difference is whether the silence starts
# before or after the response headers.
echo "==> E: 2 s of silence AFTER the headers, budget 1 s (expect the timer to fire)"; timing_of E
check "silence after headers is measured" "$(out_of E)" "no response within 1s"

echo "==> F: the SAME 2 s of silence BEFORE the headers, budget 1 s (expect it to be invisible)"; timing_of F
check_absent "silence before headers is NOT measured" "$(out_of F)" "no response within"
check "  ...and the request still completes" "$(out_of F)" "hello world"

echo
echo "$pass passed, $fail failed"
echo "total wall clock: $((SECONDS - suite_t0))s"
[ "$fail" -eq 0 ]
