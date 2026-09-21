# syntax=docker/dockerfile:1.7
#
# goose — sandbox image built FROM SOURCE at a pinned commit.
#
# The point of this image is that nobody has to trust a prebuilt binary: it is
# compiled in front of you, from one immutable commit, and run as an
# unprivileged user in a read-only container.
#
#   podman build -t goose-custom .            # or: ./build.sh
#
# Deliberate differences from the repo's own Dockerfile (./Dockerfile upstream):
#   * base is rust:1.96.1 (the repo's rust-toolchain.toml) instead of rust:1.82,
#     which is older than the workspace MSRV of 1.94.1;
#   * the build uses the SAME cargo profile as a plain `cargo build --release`
#     (no LTO / opt-level=z overrides), so the code under test matches the
#     artifact the author actually ran. Only the symbol table is stripped, which
#     is post-link and cannot change behaviour.
#   * local-inference is DISABLED. It is in goose-cli's default feature set and
#     is what pulls in llama.cpp (llama-cpp-2 -> llama-cpp-sys-2 -> GGML C/C++),
#     plus the candle ML framework. None of that is needed to talk to a remote
#     or Ollama-hosted model, and it is the bulk of the build. See
#     GOOSE_FEATURES below.
#   * native-tls instead of rustls-tls: OpenSSL rather than rustls/aws-lc-rs.
#     The two are mutually exclusive (crates/goose/src/lib.rs has a
#     compile_error! for it). Consequence: the runtime image needs libssl3.
#   * NO rustls AT ALL, not merely "not selected". The `native-tls` feature
#     swaps goose's own TLS, but `code-mode` pulls in pctx_config, which asked
#     reqwest for rustls and thereby dragged rustls -> hyper-rustls ->
#     aws-lc-rs into the graph — a second full TLS stack plus aws-lc-sys, a
#     large third-party C crypto library. The commit pinned below carries the
#     fix (see its vendor/pctx_config). The dependency gate below asserts it
#     from the graph, so this cannot silently regress.
#   * telemetry, system-keyring, nostr, otel, aws-providers and live-voice are
#     all off. See GOOSE_FEATURES.
# ---------------------------------------------------------------------------

ARG RUST_IMAGE=docker.io/library/rust:1.96.1-bookworm

# ============================== build stage ================================
FROM ${RUST_IMAGE} AS build

ARG GOOSE_REPO=https://github.com/mamins1376/goose.git
ARG GOOSE_BRANCH=custom
ARG GOOSE_COMMIT=a5baa0071288068bda73ef715141e96c05b08a7b
ARG GOOSE_STRIP=true

# goose-cli's default feature set minus everything we do not want. Cargo has no
# "defaults except X", so the list is spelled out; here we keep only:
#
#   code-mode    the code_execution platform extension
#   native-tls   TLS via OpenSSL (mutually exclusive with rustls-tls)
#
# Dropped, with what they cost: local-inference (llama.cpp + candle),
# rustls-tls (rustls + aws-lc-rs, replaced by native-tls), telemetry (also
# removes the first-run consent dialog), system-keyring, nostr, otel,
# aws-providers, live-voice, update (sigstore-verify + snap).
#
# `update` being off is sufficient to remove the `goose update` subcommand —
# commands/mod.rs gates `pub mod update` on that feature, so disabling it needs
# no extra flag.
#
# A TLS feature is required: without either native-tls or rustls-tls there is no
# HTTPS to any provider. Trim further with --build-arg GOOSE_FEATURES=...
ARG GOOSE_FEATURES=code-mode,native-tls

# Declared so that --build-arg http_proxy=... actually reaches the RUN steps.
# Needed when the build host reaches the internet through a proxy: the value
# podman copies in points at the *host's* loopback, which is unreachable from
# inside the build container. Leave unset if you have direct egress.
ARG http_proxy
ARG https_proxy
ARG no_proxy

# Build dependencies, kept to exactly what this feature set needs:
#   ca-certificates, git   fetch the commit and the crates
#   pkg-config, libssl-dev native-tls links OpenSSL, so openssl-sys must find it
#
# Deliberately NOT installed, because the features that needed them are out:
#   cmake, libclang-dev      llama-cpp-sys / candle / bindgen (local-inference)
#   libdbus-1-dev            secret-service keyring (system-keyring)
#   protobuf-compiler,
#   libprotobuf-dev          prost codegen (otel)
# If you re-enable one of those features, re-add its package: the build will
# fail loudly rather than silently, so just watch the first error.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Fetch exactly one commit. The `test` is the important part: if the fetch ever
# resolves to something else, the build fails instead of silently shipping a
# different tree. `--locked` below then pins the dependency graph to the
# committed Cargo.lock.
RUN set -eux; \
    git init -q .; \
    git remote add origin "${GOOSE_REPO}"; \
    if git fetch -q --depth 1 origin "${GOOSE_COMMIT}"; then \
        git checkout -q FETCH_HEAD; \
    else \
        git fetch -q --depth 1 origin "${GOOSE_BRANCH}"; \
        git checkout -q FETCH_HEAD; \
    fi; \
    test "$(git rev-parse HEAD)" = "${GOOSE_COMMIT}"; \
    git rev-parse HEAD > /goose-src-commit

# Dependency gate, checked BEFORE compiling. It reads the feature-resolved
# crate graph, so it fails in seconds instead of after ten minutes, and it
# cannot be fooled by a string that merely mentions rustls (e.g. the
# `rustls-pki-types` type crate, which is not a TLS implementation and may
# legitimately survive).
RUN set -eux; \
    cargo tree -p goose-cli --no-default-features --features "${GOOSE_FEATURES}" \
        --locked --prefix none > /goose-deps.txt; \
    awk '{print $1}' /goose-deps.txt | sort -u > /goose-crates.txt; \
    forbidden=$(grep -xE 'rustls|hyper-rustls|aws-lc-rs|tokio-rustls|rustls-webpki|webpki-roots|quinn' /goose-crates.txt || true); \
    if [ -n "${forbidden}" ]; then \
        echo "ERROR: a rustls TLS implementation is in the dependency graph:" >&2; \
        echo "${forbidden}" >&2; \
        exit 1; \
    fi; \
    echo "dependency gate: no rustls implementation in the graph"; \
    grep -qx 'native-tls' /goose-crates.txt; \
    echo "dependency gate: native-tls is present"; \
    grep -qx 'openssl' /goose-crates.txt; \
    echo "dependency gate: openssl is present"

# `-p goose-cli --bin goose` is what the maintainer's install target runs, but
# with local-inference switched off. The marker checks afterwards are real
# measurements, not decoration: with local-inference ON this binary contains
# thousands of `ggml` symbols, and with rustls in the graph it contains
# `aws_lc` symbols, so a zero count is evidence rather than a hope.
# (`ollama` is deliberately not used as a marker - it appears ~200 times either
# way, because Ollama is a *provider* and has nothing to do with llama.cpp.
# Plain `rustls` is only reported, never gated: `rustls-pki-types` can leave
# the string `rustls-pki-types` behind, which says nothing about TLS.)
RUN set -eux; \
    CARGO_INCREMENTAL=0 cargo build --release --locked -p goose-cli --bin goose \
        --no-default-features --features "${GOOSE_FEATURES}"; \
    if [ "${GOOSE_STRIP}" = "true" ]; then strip target/release/goose; fi; \
    target/release/goose --version; \
    strings -a target/release/goose > /goose-strings.txt; \
    ggml=$(grep -ci 'ggml' /goose-strings.txt || true); \
    awslc=$(grep -ci 'aws_lc' /goose-strings.txt || true); \
    hyperrustls=$(grep -ci 'hyper-rustls' /goose-strings.txt || true); \
    rustlsany=$(grep -ci 'rustls' /goose-strings.txt || true); \
    rustlsimpl=$(grep -i 'rustls' /goose-strings.txt | grep -vic 'rustls-pki-types' || true); \
    echo "llama.cpp markers (ggml): ${ggml}"; \
    echo "rustls markers: aws_lc=${awslc} hyper-rustls=${hyperrustls} rustls-implementation=${rustlsimpl}"; \
    echo "  (raw 'rustls' string count is ${rustlsany}; every one of them must be a rustls-pki-types path)"; \
    if [ "${ggml}" != "0" ]; then echo "ERROR: llama.cpp is still linked in" >&2; exit 1; fi; \
    if [ "${awslc}" != "0" ]; then echo "ERROR: aws-lc-rs is still linked in" >&2; exit 1; fi; \
    if [ "${hyperrustls}" != "0" ]; then echo "ERROR: hyper-rustls is still linked in" >&2; exit 1; fi; \
    if [ "${rustlsimpl}" != "0" ]; then echo "ERROR: rustls is still linked in; the only crate allowed to mention rustls is rustls-pki-types" >&2; exit 1; fi; \
    rm -f /goose-strings.txt; \
    sha256sum target/release/goose | tee /goose-src-hash

# ============================= runtime stage ===============================
# bookworm matches the build stage's libc, so the binary runs here.
#
# The package list is the minimum for THIS feature set. With native-tls the
# binary links OpenSSL dynamically, so libssl3 is required. ca-certificates is
# required too: OpenSSL reads the system trust store. Compare with the previous
# rustls build, where ldd showed only libgcc_s/libm/libc and libssl3 could be
# dropped. If you rebuild with GOOSE_FEATURES including local-inference, add
# libstdc++6 and libgomp1 back.
FROM docker.io/library/debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash goose \
    && mkdir -p /workspace \
    && chown 1000:1000 /workspace

COPY --from=build /src/target/release/goose /usr/local/bin/goose
COPY --from=build /goose-src-commit /goose-src-hash /usr/local/share/goose-build/

# No D-Bus session exists in a container, so the keyring backend could not work
# anyway. Note that `system-keyring` is compiled out of this build, so
# `secret_storage()` in crates/goose/src/config/base.rs returns File storage
# unconditionally; GOOSE_DISABLE_KEYRING is therefore belt-and-braces rather
# than the thing doing the work. Either way secrets land in a plain file inside
# the config dir, where they vanish with the container.
ENV HOME=/home/goose \
    GOOSE_DISABLE_KEYRING=true \
    GOOSE_TELEMETRY_ENABLED=false \
    GOOSE_CLI_SHOW_COST=false \
    RUST_BACKTRACE=1 \
    PATH=/usr/local/bin:/usr/bin:/bin

WORKDIR /workspace
USER 1000:1000

ENTRYPOINT ["/usr/local/bin/goose"]
CMD ["--help"]
