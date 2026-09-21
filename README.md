# goose sandbox — run it without trusting it

A container kit for trying out a **specific goose build** while keeping it
fenced off from your machine. Nothing prebuilt is involved: the image compiles
goose from one pinned commit, and the launcher runs it as an unprivileged user
in a read-only container with no access to your files.

<!-- When handing this kit on, update the four rows below together with the
     commit pin in build.sh, the Containerfile and run.sh's image tag. -->

| | |
|---|---|
| source | `https://github.com/mamins1376/goose.git` branch `custom` |
| commit | `a5baa0071288068bda73ef715141e96c05b08a7b` |
| version | 1.51.0 |
| upstream | `https://github.com/aaif-goose/goose.git` |

## 1. Build it (you compile it, so there is nothing to take on faith)

```bash
cd goose-sandbox
./build.sh
```

Under the hood:

```bash
podman build -t localhost/goose-custom:a5baa00712 \
  --build-arg GOOSE_REPO=https://github.com/mamins1376/goose.git \
  --build-arg GOOSE_COMMIT=a5baa0071288068bda73ef715141e96c05b08a7b .
```

The tag is not cosmetic: `build.sh` tags the image with the first ten
characters of the commit, and `run.sh` plus the test harness default to
`localhost/goose-custom:a5baa00712`. Build it under a different name and you
must pass `GOOSE_IMAGE=...` to both.

What the build does and does not do:

- clones exactly that one commit, then asserts `git rev-parse HEAD` equals it —
  if the fetch resolves to anything else the build **fails** rather than
  silently shipping a different tree;
- builds with the same cargo profile the author used locally
  (`cargo build --release -p goose-cli --bin goose`, no LTO/`opt-level`
  overrides), `--locked` against the committed `Cargo.lock`, so every
  dependency version is fixed by the source you are reading;
- only strips the symbol table afterwards, which is a post-link step and cannot
  change behaviour.

Expect a first build of about six minutes and on the order of 15–20 GiB of
scratch space. A repeat build with the *same* commit and the same feature list
is served entirely from the layer cache and takes seconds; change
`GOOSE_FEATURES` and the compiler starts from zero, because the build stage
mounts no cargo cache.

**This is a deliberately stripped goose.** `goose-cli` ships ten default
features; this image builds with `--no-default-features --features
code-mode,native-tls`. That keeps exactly one of the ten (`code-mode`) and
swaps the TLS backend (`rustls-tls` out, `native-tls` in). Everything else is
gone:

| built in | what it gives you |
|---|---|
| `code-mode` | the `code_execution` platform extension |
| `native-tls` | TLS via OpenSSL (mutually exclusive with `rustls-tls`) |

What each dropped feature brought in:

| dropped | what it brought in |
|---|---|
| `local-inference` | llama.cpp (`llama-cpp-2` → `llama-cpp-sys-2` → GGML), the candle ML framework, and the `local-models` subcommand |
| `rustls-tls` | rustls + aws-lc-rs — replaced by `native-tls` |
| `telemetry` | telemetry emission *and* the first-run consent dialog |
| `system-keyring` | OS keyring storage for secrets |
| `nostr` | the Nostr client and the `--relays` session option |
| `otel` | OpenTelemetry OTLP exporters |
| `aws-providers` | the AWS Bedrock and SageMaker providers |
| `live-voice` | the real-time voice service and WebSocket transport |
| `update` | the `goose update` self-update subcommand |

Consequences worth knowing:

- **There is no `goose update`.** `commands/mod.rs` gates `pub mod update` on
  the `update` feature, so the subcommand does not exist at all —
  `goose update` returns `unrecognized subcommand`. Updating means rebuilding
  the image.
- **There is no local model server inside the container.** Ollama on your host
  still works as a provider; running a model *in* the container does not.
- **`native-tls` means OpenSSL**, so `libssl3` is in the runtime image and the
  binary links `libssl.so.3`/`libcrypto.so.3`. With `rustls-tls` instead,
  neither is needed.
- **No telemetry, and no consent prompt** — the prompt is part of the
  `telemetry` feature, so a fresh container goes straight to the session.

The build then *verifies* the llama.cpp claim rather than assuming it: it greps
its own binary for `ggml` and fails if the count is not zero. With
`local-inference` enabled that binary contains ~2000 `ggml` symbols, so a zero
count is a real measurement rather than a hopeful one. (It does not grep for
`llama`, because `ollama` is a provider name and appears either way.)

To build a different combination, pass `GOOSE_FEATURES`, e.g.
`GOOSE_FEATURES=code-mode,rustls-tls ./build.sh`. At least one of
`native-tls`/`rustls-tls` is required — without either there is no HTTPS to any
provider.

The image records its own provenance, so you can check it later:

```bash
podman run --rm --entrypoint cat localhost/goose-custom:a5baa00712 /usr/local/share/goose-build/goose-src-commit
podman run --rm --entrypoint cat localhost/goose-custom:a5baa00712 /usr/local/share/goose-build/goose-src-hash
```

### Proof you are running this fork and not plain upstream

The fork adds a second stream timeout budget, so its half of the error string
is unique to it:

```bash
podman run --rm --entrypoint grep localhost/goose-custom:a5baa00712 \
  -ac stream_first_line_timeout_secs /usr/local/bin/goose
```

A non-zero count means the binary carries the split-budget change. Upstream
1.51.0 returns `0`.

The fork also removes a TLS stack, which is visible the same way — these must
all be `0`:

```bash
podman run --rm --entrypoint grep localhost/goose-custom:a5baa00712 \
  -ac 'aws_lc' /usr/local/bin/goose
podman run --rm --entrypoint grep localhost/goose-custom:a5baa00712 \
  -ac 'hyper-rustls' /usr/local/bin/goose
```

and this must be non-zero, because OpenSSL is what the build actually uses:

```bash
podman run --rm --entrypoint ldd localhost/goose-custom:a5baa00712 /usr/local/bin/goose
# expect: libssl.so.3 => ... and libcrypto.so.3 => ...
```

### Handing the image over instead of the source

If he would rather not spend six minutes and 15–20 GiB compiling, the built
image transfers as a plain OCI archive and loads into either engine:

```bash
podman save --format oci-archive -o goose-custom.tar localhost/goose-custom:a5baa00712
podman load -i goose-custom.tar          # or: docker load -i goose-custom.tar
```

That is a ~390 MB file — the archive is uncompressed, and the binary inside it
is already 201 MiB — carrying the same provenance records, so it can still be
checked with the two `podman run ... cat` commands above. Building it himself
remains the stronger option.

## 2. Run it

With no arguments nothing of yours is reachable:

```bash
./run.sh --version
./run.sh session
```

`./run.sh --help` prints the *launcher's* own options, not goose's. To see the
goose help pages, ask for them explicitly:

```bash
./run.sh help
```

To let it see a directory of your choosing (and only that one):

```bash
GOOSE_WORKSPACE=~/scratch/goose-test ./run.sh session
```

To keep its config and session history between runs:

```bash
GOOSE_STATE=~/.local/share/goose-sandbox ./run.sh session
```

To give it an API key without it inheriting anything else from your shell:

```bash
cp goose.env.example goose.env && $EDITOR goose.env
GOOSE_ENV_FILE=./goose.env ./run.sh session
```

Read the exact `podman` invocation before you run it:

```bash
GOOSE_DRY_RUN=1 GOOSE_WORKSPACE=$PWD ./run.sh session
```

## 3. What the sandbox actually guarantees

Applied on every invocation by `run.sh`:

| Flag | Effect |
|---|---|
| `--read-only` | root filesystem cannot be written; a compromised goose cannot install or persist anything |
| `--tmpfs /tmp`, `/home/goose/.{config,local,cache}` | the only writable paths, size-capped, all in RAM, all gone on exit *(the three `~/.` mounts are replaced by the `GOOSE_STATE` bind mount when you set it)* |
| `--cap-drop=ALL` | no Linux capabilities at all |
| `--security-opt=no-new-privileges` | setuid binaries cannot escalate |
| `--pids-limit` / `--memory` / `--memory-swap` / `--cpus` | fork bombs, memory and CPU are bounded *(when the host can enforce cgroups — see below)* |
| no `--volume` unless you ask | your home, your keys, your repos are invisible |
| no `--env-host` | your shell environment is not inherited |
| no docker/podman socket | it cannot reach the host runtime |

One caveat on the resource caps: they need a cgroup the runtime is allowed to
write to. Rootless podman on a host without systemd cgroup delegation (this
machine is one: `seatd` + `turnstiled`, cgroup manager `cgroupfs`) has none, and
podman refuses to start the container at all rather than ignoring the flags.
`run.sh` detects that and drops the caps with a warning on stderr rather than
failing. On a normal systemd host they are applied. Force the choice with
`GOOSE_RESOURCE_LIMITS=on|off`.

The container user is uid 1000 with no password and no sudo. The runtime image
carries only `ca-certificates`, `curl`, `git`, `libssl3` and glibc — no
compiler, no Python, no Node, no C++ runtime. (`libssl3` is there because this
build uses `native-tls`; the `rustls-tls` alternative would not need it.)

### What is *not* isolated

- **Network egress.** goose has to reach your LLM provider, so the container
  gets outbound networking. It can therefore also reach anything else it can
  route to. Run `GOOSE_NETWORK=none ./run.sh --version` (or a full session
  against a local model) if you want the offline case.
- **Anything you explicitly mount.** `GOOSE_WORKSPACE` is read-write and
  `GOOSE_STATE` survives runs. Point them at throwaway paths.
- **The prompt content.** Whatever you type is sent to whichever provider you
  configured; the container cannot change that.

## 4. Sharp edges found while building this

These are worth knowing before you conclude something is broken.

**Podman copies your proxy variables into the container.** If you have
`http_proxy`/`HTTP_PROXY` set in your shell, podman injects it into every
container it starts, and to the runtime those variables are indistinguishable
from ones you set on purpose. A proxy on `127.0.0.1:8080` is *your* loopback;
inside the container nothing is listening there, so goose fails to reach its
provider with no error that mentions a proxy. `run.sh` therefore blanks all the
proxy variables on every run. If you genuinely need a proxy, point it at
something reachable and say so:

```bash
GOOSE_PROXY=http://host.containers.internal:8080 ./run.sh session
```

The same applies to `podman build`, which is why the Containerfile declares
`ARG http_proxy` / `https_proxy` / `no_proxy` explicitly.

**The repo's own `Dockerfile` will not reproduce this build.** It pins
`rust:1.82-bookworm` while the workspace requires Rust 1.94.1, and it compiles
with `LTO=true`, `opt-level=z`, `codegen-units=1`. That produces a different
binary from a plain `cargo build --release`. It is a fine image; it is just not
the same artifact as the one under test here.

**A prebuilt binary of this commit is glibc-2.39+.** It was built on a rolling
distro, so it will not start on `debian:bookworm` (glibc 2.36). Building in the
container removes the problem entirely, which is the other reason this kit
compiles rather than ships a binary.

**Check the build actually fetched the commit you think it did.** Both the git
pin and the binary hash are readable from inside the built image, and
`--build-arg GOOSE_COMMIT=<sha>` is checked with `test` before compilation, so a
mismatch fails the build rather than producing a quietly different binary.

## 5. What this fork changes

Upstream goose wrapped the *first* stream read in the same 15 s timer it uses
between chunks, so the time budget for "provider is still prefilling the
prompt" was the same as for "connection died mid-stream". On a large context,
where prefill legitimately takes longer than 15 s, that surfaced as a network
error, and because nothing had been tool-called yet it was retried up to three
times before failing. This fork splits it in two:

- inter-chunk idle window: unchanged at 15 s;
- time-to-first-line: its own budget, default 120 s, reported by name when it
  elapses.

Both are adjustable, per provider or globally, via
`stream_chunk_timeout_secs` / `stream_first_line_timeout_secs` in a declarative
provider config, or `GOOSE_INFERENCE_CHUNK_TIMEOUT_SECS` /
`GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS`.

Things worth poking at while you have it open:

- does a slow local model still trip the idle timeout? (it should not)
- is the 120 s default sane for your provider, or too long/short?
- `--read-only` plus no `GOOSE_STATE` means an interrupted session is lost —
  is that the trade-off you want?

### The fork also drops rustls entirely

Selecting `native-tls` is not by itself enough to get OpenSSL. The `code-mode`
feature pulls in `pctx_config`, a third-party crate that asked `reqwest` for
its `rustls` feature — and `reqwest` is a single crate in the graph, so that
one request decided the TLS backend for *every* HTTP client in the workspace.
The result was a build that linked OpenSSL **and** rustls: rustls →
hyper-rustls → aws-lc-rs, the last being aws-lc-sys, a large third-party C
crypto library (a BoringSSL fork) compiled from scratch.

Upstream `pctx_config` never names rustls in its own source; the backend was
always just something it inherited from `reqwest`. The fork vendors that crate
through `[patch.crates-io]` with exactly one change — that feature name becomes
`native-tls` — so every client uses OpenSSL and the rustls crates are not built
at all. `rustls-pki-types` does survive: it is a type-definitions crate with no
crypto and no TLS implementation, and `reqwest` depends on it regardless.

`ring` also survives, pulled in by `rcgen` because it needs a crypto backend to
*generate* the certificate for goose's local ACP server; OpenSSL does not expose
that interface. It is not a TLS transport and is not involved in any connection
goose makes.

## 6. End-to-end test: does the fork actually behave differently?

`test/run-tests.sh` answers the only question that matters here — is the split
budget real, or does it just look real? It spins up a mock SSE provider on the
host, runs the image against it, and asserts on the error text. No API key, no
internet.

Note what this test is and is not. The *logic* already has unit tests in the
fork itself (`crates/goose-providers/src/stream_util.rs`, cases
`slow_first_line_is_allowed_by_its_own_budget`,
`first_line_past_its_budget_reports_the_first_line_phase` and friends). This
script tests the *artifact*: that the binary you actually built, running in the
container you actually built, behaves that way. It is the only thing here that
connects source → image → observed behaviour, and it is what a reader who does
not trust the build can run for himself.

```bash
cd test && ./run-tests.sh
```

```
==> A: 20 s prefill, default budgets (expect success)
  PASS  slow prefill survives
==> B: same 20 s prefill, first-line budget forced to 5 s (expect failure naming 5s)
  PASS  budget is live
==> C: provider-level override stream_first_line_timeout_secs=3 (expect failure naming 3s)
  PASS  per-provider override reaches the timer
==> D: stall after the first chunk (expect the idle message, not the prefill one)
  PASS  idle window unchanged
==> E: 6 s of silence AFTER the headers, budget 1 s (expect the timer to fire)
  PASS  silence after headers is measured
==> F: the SAME 6 s of silence BEFORE the headers, budget 1 s (expect it to be invisible)
  PASS  silence before headers is NOT measured
  PASS    ...and the request still completes

7 passed, 0 failed          (about two minutes)
```

Case B is the one that matters. Case A alone proves nothing: "the 20 s prefill
succeeded" is also what you would see if the timeout were simply removed. B
reruns the identical scenario with the budget forced down to 5 s and requires it
to fail, naming 5 s — so the timer is demonstrably live in A, and A is a real
measurement rather than an absence of one.

Case C goes further and shows a *provider-level* override reaching the timer,
and D confirms the untidy half did not regress: a stall after output still
reports the inter-chunk error.

Cases A–D mirror the unit tests above at the HTTP level; E and F cannot, because
the thing they test is a property of HTTP framing (where the headers end) that a
unit test operating on a `Stream` never sees. If you ever trim this file, keep B
(the counter-measurement) and E/F (the boundary) and drop A, C and D first.

### Known limit: the budget cannot see time-to-first-token

The timer starts once the response **headers** have arrived, so what it measures
is headers → first SSE line, not request → first token. If a provider computes
the first token *before* it answers at all, the delay sits in front of the
headers and the timer never sees it.

Measured against Qubax with `deepseek-v4-flash`, timing headers and first body
byte separately:

| prompt | to headers | to first byte | gap the timer sees |
|---|---|---|---|
| 22 chars | 2205 / 3328 / 3927 / 24491 ms | same | **0 ms** every time |
| 28 KB | 23211 / 31590 / 14052 / 10994 ms | same | **0 ms** every time |

The headers and the first byte arrive in the same instant, so the window is
empty by construction. Accordingly, six runs with
`GOOSE_INFERENCE_FIRST_LINE_TIMEOUT_SECS=1` all succeeded — the knob had no
effect. Cases E and F pin the boundary down: identical 6 s of silence, differing
only in whether it falls before or after the headers, with the same 1 s budget.
E fires; F does not.

What follows from that:

- For a provider that answers headers immediately and *then* thinks — what the
  mock's `slow-prefill` mode imitates, and what Anthropic's early `message_start`
  looks like — the budget does exactly what it claims.
- For a provider that computes first and answers afterwards, Qubax included, the
  budget is inert. There are no false positives, so the original worry does not
  materialise; but there is also no protection, and a wedged prefill is bounded
  only by reqwest's 600 s read timeout.
- Upstream's single 15 s window began after the headers too, so it had the same
  blind spot. For Qubax-class providers this fork changes nothing. The
  improvement is real, but narrower than it first appears.

For providers in that second class, the knob that *should* bound prefill is the
declarative `timeout_seconds` (default 600): `api_client.rs` passes it to
reqwest as `read_timeout` and deliberately skips the request-level total timeout
when streaming, so it appears to cover the wait for headers. **This is not
verified.** Attempting to confirm it against Qubax is what produced the
measurements above, and the runs did not discriminate: with `timeout_seconds: 8`
and a 28 KB prompt the answer came back in 3.9 s, because Qubax's own latency
swings between roughly 2 s and 50 s for identical requests. Treat the
`timeout_seconds` claim as a hypothesis with a plausible mechanism, not a
measurement.

Two things this test does that `run.sh` will not: it uses `--network host` (so
the container can reach the mock) and it mounts a scratch directory. It is a
test harness, not the sandbox.

## 7. Troubleshooting

`error: No model configured. Run 'goose configure' first.`
: goose found no provider or no model. Either pass `GOOSE_ENV_FILE` with
  `GOOSE_PROVIDER`/`GOOSE_MODEL`, or run `./run.sh configure` interactively. With
  no `GOOSE_STATE` the answer is discarded on exit, so do the configuring and the
  running in the same container, or set `GOOSE_STATE`.

The build fails fetching git or crates
: Almost always the proxy problem in §4. Retry with
  `GOOSE_BUILD_PROXY=http://host.containers.internal:PORT ./build.sh`.

`Network error: Could not connect to <host>`
: Check it is not the proxy leak before suspecting your provider. Run
  `GOOSE_NETWORK=none ./run.sh --version`; if that works, the container is fine
  and the problem is egress. `GOOSE_DRY_RUN=1 ./run.sh session` shows exactly
  which environment variables the container was given.

Out of disk during the build
: The build wants ~15–20 GiB. Prune old images with
  `podman system prune -a` and rebuild; the compiled layers live in the image
  layer cache, so an identical rebuild costs nothing while a changed
  `GOOSE_FEATURES` compiles from scratch.

Something inside the container is missing
: The image is deliberately minimal: `ca-certificates`, `curl`, `git` and the
  runtime libs. There is no Python, no Node, no `npx`, so extensions such as
  Playwright or any MCP server will not start. Add them in a derived image if you
  want them — but note every package you add is more surface inside the sandbox.
