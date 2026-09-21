#!/usr/bin/env bash
#
# Build the goose sandbox image from source at a pinned commit.
#
#   ./build.sh                 # build + record provenance
#   GOOSE_COMMIT=<sha> ./build.sh
#
# Everything the build downloads is either the pinned git commit or crates whose
# versions come from that commit's Cargo.lock.
set -euo pipefail

cd "$(dirname "$0")"

ENGINE="${CONTAINER_ENGINE:-podman}"
GOOSE_REPO="${GOOSE_REPO:-https://github.com/mamins1376/goose.git}"
GOOSE_BRANCH="${GOOSE_BRANCH:-custom}"
GOOSE_COMMIT="${GOOSE_COMMIT:-a5baa0071288068bda73ef715141e96c05b08a7b}"
GOOSE_IMAGE="${GOOSE_IMAGE:-localhost/goose-custom:${GOOSE_COMMIT:0:10}}"
# spelled out because Cargo cannot express "defaults minus local-inference"
GOOSE_FEATURES="${GOOSE_FEATURES:-code-mode,native-tls}"

command -v "$ENGINE" >/dev/null || { echo "error: $ENGINE not found" >&2; exit 1; }

# A release build of this workspace wants a lot of disk. Fail early rather than
# discovering it half way through.
avail_kib=$(df -Pk . | awk 'NR==2 {print $4}')
if [ "${avail_kib:-0}" -lt 20971520 ]; then
    echo "warning: only $((avail_kib / 1024 / 1024)) GiB free; a build can use ~15-20 GiB." >&2
    read -r -p "continue anyway? [y/N] " ans
    [ "${ans:-n}" = "y" ] || exit 1
fi

echo "==> repository : $GOOSE_REPO (branch $GOOSE_BRANCH)"
echo "==> commit     : $GOOSE_COMMIT"
echo "==> image tag  : $GOOSE_IMAGE"
echo

# A proxy pointing at the host's loopback cannot be reached from inside the
# build container. If that is what we inherited, say so instead of failing
# minutes later inside a cargo fetch.
proxy_args=()
if [ -n "${GOOSE_BUILD_PROXY:-}" ]; then
    proxy_args=(--build-arg "http_proxy=$GOOSE_BUILD_PROXY" \
                --build-arg "https_proxy=$GOOSE_BUILD_PROXY" \
                --build-arg "no_proxy=localhost,127.0.0.1")
    echo "==> proxy      : $GOOSE_BUILD_PROXY"
    echo
elif printf '%s' "${https_proxy:-${HTTPS_PROXY:-}}" | grep -qE '://(localhost|127\.0\.0\.1|\[::1\])'; then
    echo "note: your https_proxy points at loopback, which the build container cannot"
    echo "      reach. If the build fails fetching git/crates, retry with:"
    echo "        GOOSE_BUILD_PROXY=http://host.containers.internal:PORT ./build.sh"
    echo
fi

"$ENGINE" build \
    --build-arg "GOOSE_REPO=$GOOSE_REPO" \
    --build-arg "GOOSE_BRANCH=$GOOSE_BRANCH" \
    --build-arg "GOOSE_COMMIT=$GOOSE_COMMIT" \
    "${proxy_args[@]}" \
    --tag "$GOOSE_IMAGE" \
    "$@" \
    .

echo
echo "==> built: $GOOSE_IMAGE"
image_id=$("$ENGINE" image inspect --format '{{.Id}}' "$GOOSE_IMAGE")
echo "    image id : $image_id"
echo
echo "provenance recorded inside the image:"
"$ENGINE" run --rm --entrypoint cat "$GOOSE_IMAGE" /usr/local/share/goose-build/goose-src-commit \
    | sed 's/^/    commit   : /'
"$ENGINE" run --rm --entrypoint cat "$GOOSE_IMAGE" /usr/local/share/goose-build/goose-src-hash \
    | sed 's/^/    binary   : /'
echo
echo "next: ./run.sh --help"
