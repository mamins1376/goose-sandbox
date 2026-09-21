#!/usr/bin/env bash
#
# Hardened launcher for the goose sandbox image.
#
#   ./run.sh session                        # interactive goose session
#   ./run.sh run -t "hello"
#   GOOSE_WORKSPACE=$PWD ./run.sh session   # expose one directory at /workspace
#   GOOSE_NETWORK=none ./run.sh --version   # prove it runs with no network at all
#   GOOSE_DRY_RUN=1 ./run.sh session        # print the command, run nothing
#
# Defaults are deliberately paranoid: nothing from the host is mounted, no host
# environment is passed through, the root filesystem is read-only, all
# capabilities are dropped, and PID/memory/CPU are capped where the host allows.
#
# Knobs, all optional:
#   GOOSE_STATE             host dir mounted at /home/goose so config and
#                           sessions survive the container
#   GOOSE_WORKSPACE         host dir mounted read-write at /workspace
#   GOOSE_ENV_FILE          --env-file holding your provider credentials
#   GOOSE_PROXY             proxy URL reachable from inside the container
#   GOOSE_NETWORK           e.g. "none" for a fully offline run
#   GOOSE_RESOURCE_LIMITS   on | off | auto   (default auto)
#   GOOSE_IMAGE, CONTAINER_ENGINE, GOOSE_DRY_RUN
#
# GOOSE_STATE and GOOSE_WORKSPACE are the only knobs that put anything of yours
# inside the container; the rest stay outside it.
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-podman}"
GOOSE_IMAGE="${GOOSE_IMAGE:-localhost/goose-custom:a5baa00712}"
WORKSPACE="${GOOSE_WORKSPACE:-}"
STATE="${GOOSE_STATE:-}"
ENV_FILE="${GOOSE_ENV_FILE:-}"
NETWORK="${GOOSE_NETWORK:-}"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then usage; exit 0; fi
command -v "$ENGINE" >/dev/null || { echo "error: $ENGINE not found" >&2; exit 1; }

args=(
    run
    --rm
    --name "goose-sandbox-$$"
    # --- filesystem ---------------------------------------------------------
    --read-only
    --tmpfs "/tmp:rw,nosuid,nodev,size=256m,mode=1777"
    --tmpfs "/run:rw,nosuid,nodev,size=8m,mode=755"
    # --- privileges ---------------------------------------------------------
    --cap-drop=ALL
    --security-opt=no-new-privileges
    # --- misc ---------------------------------------------------------------
    --workdir /workspace
    --hostname goose-sandbox
)

# Interactive only when there is a terminal to attach to.
[ -t 0 ] && args+=(-i)
[ -t 1 ] && args+=(-t)

# --- resource bounds -------------------------------------------------------
# --pids-limit / --memory / --cpus need a cgroup the container runtime is
# allowed to write to. Rootless podman with cgroupfs (no systemd delegation,
# e.g. a seatd/turnstiled box) has none, and podman then refuses to start the
# container at all rather than ignoring the flags. Detect that instead of
# turning it into a confusing failure, and say so out loud when we fall back.
limits="${GOOSE_RESOURCE_LIMITS:-auto}"
if [ "$limits" = "auto" ]; then
    if [ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" != "true" ] \
       || [ "$("$ENGINE" info --format '{{.Host.CgroupManager}}' 2>/dev/null)" = "systemd" ]; then
        limits=on
    else
        limits=off
    fi
fi

if [ "$limits" = "on" ]; then
    args+=(--pids-limit=512 --memory=4g --memory-swap=4g --cpus=4)
else
    echo "note: this host cannot enforce container cgroup limits" >&2
    echo "      (rootless podman without systemd cgroup delegation)." >&2
    echo "      PID/memory/CPU caps are OFF for this run." >&2
fi

# goose needs to write its config, sessions and cache somewhere. Without
# GOOSE_STATE those live in RAM and die with the container. Both mounts below
# need our uid mapped onto the image's uid 1000, so files stay ours on the host;
# the flag is emitted once, after the mounts, to avoid repeating it.
seed_volumes=()
keep_id=0

if [ -n "$STATE" ]; then
    mkdir -p "$STATE"
    seed_volumes+=(-v "$STATE:/home/goose:Z")
    keep_id=1
else
    # tmpfs mounts accept only size/mode. mode=1777 (sticky, like /tmp) is what
    # lets the unprivileged user create its own files under a root-owned mount.
    args+=(
        --tmpfs "/home/goose/.config:rw,nosuid,nodev,size=64m,mode=1777"
        --tmpfs "/home/goose/.local:rw,nosuid,nodev,size=64m,mode=1777"
        --tmpfs "/home/goose/.cache:rw,nosuid,nodev,size=512m,mode=1777"
    )
fi

if [ -n "$WORKSPACE" ]; then
    [ -d "$WORKSPACE" ] || { echo "error: GOOSE_WORKSPACE is not a directory: $WORKSPACE" >&2; exit 1; }
    seed_volumes+=(-v "$WORKSPACE:/workspace:Z")
    keep_id=1
fi

args+=("${seed_volumes[@]}")
# shellcheck disable=SC2054  # the comma is part of podman's uid=,gid= value
if [ "$keep_id" = 1 ]; then args+=(--userns=keep-id:uid=1000,gid=1000); fi

if [ -n "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] || { echo "error: GOOSE_ENV_FILE not found: $ENV_FILE" >&2; exit 1; }
    args+=(--env-file "$ENV_FILE")
fi

[ -n "$NETWORK" ] && args+=(--network "$NETWORK")

# Podman helpfully copies the host's proxy variables into every container.
# That is wrong here: a proxy on 127.0.0.1:PORT is the *host's* loopback, which
# inside the container is a dead port, so goose would fail to reach its API for
# no visible reason. Clear them, and let GOOSE_PROXY set a reachable one
# (for rootless podman the host is usually host.containers.internal).
proxy_vars=(http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY)
if [ -n "${GOOSE_PROXY:-}" ]; then
    for v in "${proxy_vars[@]}"; do args+=(--env "$v=$GOOSE_PROXY"); done
    args+=(--env "no_proxy=localhost,127.0.0.1" --env "NO_PROXY=localhost,127.0.0.1")
else
    for v in "${proxy_vars[@]}"; do args+=(--env "$v="); done
    args+=(--env "no_proxy=localhost,127.0.0.1" --env "NO_PROXY=localhost,127.0.0.1")
fi

# No --env-host: the rest of the host environment is not inherited, so a stray
# exported API key or token cannot leak in by accident. Use GOOSE_ENV_FILE.
args+=("$GOOSE_IMAGE" "$@")

if [ "${GOOSE_DRY_RUN:-}" = "1" ]; then
    printf '%q ' "$ENGINE" "${args[@]}"; echo
    exit 0
fi

exec "$ENGINE" "${args[@]}"
