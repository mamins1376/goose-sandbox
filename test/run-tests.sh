#!/usr/bin/env bash
#
# End-to-end test of the timeout behaviour, run inside the sandbox image.
#
#   ./run-tests.sh
#
# No API key and no internet access to a provider are needed: a mock
# OpenAI-compatible SSE server runs on the host and plays back the failure
# shapes this fork cares about. The container reaches it with
# --network host, which is the only reason this script is less strict than
# run.sh.
#
# What it establishes:
#   A  a 20 s prefill succeeds on defaults      -> the fix works
#   B  the SAME 20 s prefill fails when the      -> the budget is actually live,
#      first-line budget is lowered to 5 s          so A is a real measurement
#      and the error names 5 s
#   C  a provider-level override of 3 s reaches  -> per-provider config works
#      the timer and is named in the error
#   D  a stall after output still reports the    -> the idle window is unchanged
#      inter-chunk error, not the prefill one
#   E  6 s of silence AFTER the headers, 1 s     -> the timer measures the gap
#      budget: it fires                             after the headers
#   F  the same 6 s of silence BEFORE the        -> ...and cannot see the gap
#      headers, same 1 s budget: it does not        before them; request completes
#
# A-D duplicate, at HTTP level, unit tests that already exist in the fork
# (crates/goose-providers/src/stream_util.rs). E and F do not: they test where
# the response headers end, which a test over a Stream cannot observe. Keep
# B (the counter-measurement) and E/F (the boundary) if you ever trim this.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMAGE="${GOOSE_IMAGE:-localhost/goose-custom:a5baa00712}"
ENGINE="${CONTAINER_ENGINE:-podman}"
SLOW_PORT=8201   # 20 s prefill
FAST_PORT=8202   # never sends anything
DEAD_PORT=8203   # one chunk, then silence
PRE6_PORT=8205   # 6 s delay AFTER headers
HDR6_PORT=8206   # 6 s delay BEFORE headers

WORK=$(mktemp -d)
ROOT="$WORK/root"
mkdir -p "$ROOT/config/custom_providers"
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

provider() { # name port [first_line_secs]
    local name="$1" port="$2" first="${3:-}"
    local extra=""
    [ -n "$first" ] && extra=$',\n  "stream_first_line_timeout_secs": '"$first"$',\n  "stream_chunk_timeout_secs": '"$first"
    cat > "$ROOT/config/custom_providers/$name.json" <<EOF
{
  "name": "$name",
  "engine": "openai",
  "display_name": "Mock $name",
  "base_url": "http://127.0.0.1:$port/v1/chat/completions",
  "api_key_env": "MOCK_API_KEY",
  "requires_auth": false,
  "supports_streaming": true,
  "models": [{ "name": "mock-1", "context_limit": 128000 }]$extra
}
EOF
}

provider mockslow     "$SLOW_PORT"
provider mockfastline "$FAST_PORT" 3
provider mockdead     "$DEAD_PORT"
provider mockpre6     "$PRE6_PORT"
provider mockhdr6     "$HDR6_PORT"

cat > "$ROOT/config/config.yaml" <<'EOF'
GOOSE_TELEMETRY_ENABLED: false
GOOSE_CLI_SHOW_COST: false
GOOSE_DISABLE_KEYRING: true
providers:
  mockslow:     {enabled: true, model: mock-1, configured: true}
  mockfastline: {enabled: true, model: mock-1, configured: true}
  mockdead:     {enabled: true, model: mock-1, configured: true}
  mockpre6:     {enabled: true, model: mock-1, configured: true}
  mockhdr6:     {enabled: true, model: mock-1, configured: true}
EOF

echo "==> starting mock providers"
python3 mock_sse.py slow-prefill    "$SLOW_PORT" 20 & pids+=($!)
python3 mock_sse.py dead-from-start "$FAST_PORT"    & pids+=($!)
python3 mock_sse.py dead-midstream  "$DEAD_PORT"    & pids+=($!)
python3 mock_sse.py slow-prefill    "$PRE6_PORT" 6  & pids+=($!)
python3 mock_sse.py slow-headers    "$HDR6_PORT" 6  & pids+=($!)
sleep 1

run_goose() { # provider [extra --env ...]
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
        --env HTTP_PROXY= --env HTTPS_PROXY= --env http_proxy= --env https_proxy= \
        "$@" \
        "$IMAGE" run -t "say hello" 2>&1
}

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

echo "==> A: 20 s prefill, default budgets (expect success)"
out=$(run_goose mockslow)
check "slow prefill survives" "$out" "hello world"

echo "==> B: same 20 s prefill, first-line budget forced to 5 s (expect failure naming 5s)"
out=$(run_goose mockslow --env GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=5)
check "budget is live" "$out" "no response within 5s"

echo "==> C: provider-level override stream_first_line_timeout_secs=3 (expect failure naming 3s)"
out=$(run_goose mockfastline)
check "per-provider override reaches the timer" "$out" "no response within 3s"

echo "==> D: stall after the first chunk (expect the idle message, not the prefill one)"
out=$(run_goose mockdead)
check "idle window unchanged" "$out" "Stream timed out waiting for next chunk"

# E/F document the boundary of the first-line budget. Both mocks sit silent for
# 6 s with a 1 s budget; the only difference is whether the silence starts
# before or after the response headers.
echo "==> E: 6 s of silence AFTER the headers, budget 1 s (expect the timer to fire)"
out=$(run_goose mockpre6 --env GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=1)
check "silence after headers is measured" "$out" "no response within 1s"

echo "==> F: the SAME 6 s of silence BEFORE the headers, budget 1 s (expect it to be invisible)"
out=$(run_goose mockhdr6 --env GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=1)
check_absent "silence before headers is NOT measured" "$out" "no response within"
check "  ...and the request still completes" "$out" "hello world"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
