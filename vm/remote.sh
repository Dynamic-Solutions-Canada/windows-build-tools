#!/usr/bin/env bash
# Run a Windows test VM on the home server instead of in WSL, and reach it from WSL through an SSH
# tunnel on the same loopback ports the local VM used, so `ssh windows-dev`, the build bridge and
# vm/app-test keep working unchanged. From the repo root:
#   vm/remote.sh up [win11|win10]       # checks, start the VM on the server, open the tunnel
#   vm/remote.sh down [win11|win10]     # shut the guest down cleanly, close the tunnel
#   vm/remote.sh tunnel [win11|win10]   # open the tunnel only (the VM is already running)
#   vm/remote.sh status [win11|win10]   # where it runs, the server's free memory and disk, the tunnel
# win11 (the windows-dev build VM) is the default. The VM is started on demand and stopped after use.
#
# The server shares its memory and disk with its own services, so `up` refuses when another Windows
# VM runs there, when starting this one would leave less than 1.5 GB of memory available, when its
# root disk is nearly full, or when the VM's disk has not been copied there (an empty storage folder
# would make the image download and install a fresh Windows). Ports stay on the server's loopback.
# While the VM runs, vm/disk-watchdog.sh runs beside it on the server and shuts the guest down cleanly
# if the server's root disk falls below 5 GB free (warning below 8 GB in its log), since the guest's
# sparse disk grows into the same space as the server's services. The tunnel closes by itself when
# the container stops, whoever stopped it.
#
# Settings: WINDOWS_VM_SSH_HOST (default home) is the SSH alias of the server, and
# WINDOWS_VM_DOCKER_HOST (default ssh://home) its Docker endpoint. The compose files are the same
# ones the local fallback uses; this script only points their storage, OEM folder and RDP port at
# the server through WINDOWS_VM_STORAGE, WINDOWS_VM_OEM and WINDOWS_VM_RDP_PORT.
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_HOST="${WINDOWS_VM_SSH_HOST:-home}"
DOCKER_ENDPOINT="${WINDOWS_VM_DOCKER_HOST:-ssh://home}"
TUNNEL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/windows-build-tools"
# Memory the server must keep available for its own services while a VM runs, in MB.
SERVER_RESERVE_MB=1536
# Free space the server's root disk must have before a start, in GB. The guest's disk image is
# sparse and grows into free space as Windows writes, so a start on a nearly full disk risks every
# service on the server.
SERVER_MIN_DISK_GB=8
# Containers that are Windows VMs; only one of them may run on the server at a time.
WINDOWS_VMS=(windows-dev windows10-test)

# Set the settings for one VM: its container, compose file, memory cap (the compose mem_limit, in
# MB), folder on the server, and tunnel forwards as "local port:server port". The server's own xrdp
# holds port 3389 on every interface, so RDP is published there on a different loopback port and the
# tunnel maps it back to the local port the fallback uses.
use_vm() {
    case "${1:-win11}" in
        win11)
            NAME=windows-dev
            COMPOSE="$VM_DIR/compose.yml"
            CAP_MB=5120
            RDP_SERVER_PORT=13389
            FORWARDS=(2229:2229 3389:13389 8006:8006)
            ;;
        win10)
            NAME=windows10-test
            COMPOSE="$VM_DIR/compose.win10.yml"
            CAP_MB=3584
            RDP_SERVER_PORT=13390
            FORWARDS=(2230:2230 3390:13390 8007:8007)
            ;;
        *)
            echo "remote.sh: unknown VM '$1' (win11 or win10)" >&2
            exit 2
            ;;
    esac
    SERVER_DIR="/servers/$NAME"
    WATCHDOG_PID="$SERVER_DIR/watchdog.pid"
    WATCHDOG_LOG="$SERVER_DIR/watchdog.log"
    TUNNEL_SOCKET="$TUNNEL_DIR/tunnel-$NAME.sock"
}

# Run docker against the server's Docker daemon.
server_docker() {
    DOCKER_HOST="$DOCKER_ENDPOINT" docker "$@"
}

# Run this VM's compose file against the server, with the storage, OEM folder and RDP port the
# server uses. The env_file (guest password) is read here, on WSL, so the secret never sits on the
# server's disk.
server_compose() {
    WINDOWS_VM_STORAGE="$SERVER_DIR/storage" \
        WINDOWS_VM_OEM="$SERVER_DIR/oem" \
        WINDOWS_VM_RDP_PORT="$RDP_SERVER_PORT" \
        server_docker compose -f "$COMPOSE" "$@"
}

# Print "true" when the named container runs on the server, or nothing.
server_running() {
    server_docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true
}

# Print "true" when the named container runs in this machine's own Docker, or nothing.
local_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true
}

tunnel_open() {
    ssh -S "$TUNNEL_SOCKET" -O check "$SSH_HOST" >/dev/null 2>&1
}

# Refuse to start when the server cannot take the VM: another Windows VM running there, the local
# fallback holding the same ports, too little memory or disk, or no copied disk image.
check_can_start() {
    local vm available free_gb

    for vm in "${WINDOWS_VMS[@]}"; do
        if [[ "$vm" != "$NAME" && "$(server_running "$vm")" == true ]]; then
            echo "remote.sh: $vm is running on $SSH_HOST; only one Windows VM runs there at a time" >&2
            exit 1
        fi
    done

    if [[ "$(local_running "$NAME")" == true ]]; then
        echo "remote.sh: the local $NAME container is running and holds the tunnel's ports; stop it first:" >&2
        echo "  docker compose -f $COMPOSE stop" >&2
        exit 1
    fi

    if ! ssh "$SSH_HOST" "test -s $SERVER_DIR/storage/data.img"; then
        echo "remote.sh: $SERVER_DIR/storage/data.img is missing on $SSH_HOST; copy the VM's disk there first (see the README)" >&2
        exit 1
    fi

    # "available" from free -m: what the server can give without swapping.
    available=$(ssh "$SSH_HOST" free -m | awk '/^Mem:/ { print $7 }')
    if (( available - CAP_MB < SERVER_RESERVE_MB )); then
        echo "remote.sh: $SSH_HOST has $available MB available; $NAME needs $CAP_MB MB and the server keeps $SERVER_RESERVE_MB MB. Wait and retry." >&2
        exit 1
    fi

    free_gb=$(ssh "$SSH_HOST" df -BG --output=avail / | tail -1 | tr -dc '0-9')
    if (( free_gb < SERVER_MIN_DISK_GB )); then
        echo "remote.sh: $SSH_HOST has $free_gb GB free on /; $NAME needs at least $SERVER_MIN_DISK_GB GB to grow into" >&2
        exit 1
    fi
}

# Open the SSH tunnel in the background, once; a tunnel that is already open is reused. Fails when a
# local port is taken (ExitOnForwardFailure), for example by the local fallback VM. The session runs a
# loop on the server that ends when the container stops, so the tunnel closes with the VM even when
# the disk watchdog or another session stopped it.
open_tunnel() {
    local forward args=()

    if tunnel_open; then
        echo "remote.sh: tunnel for $NAME already open"
        return 0
    fi
    mkdir -p "$TUNNEL_DIR"
    for forward in "${FORWARDS[@]}"; do
        args+=(-L "127.0.0.1:${forward%%:*}:127.0.0.1:${forward#*:}")
    done
    # The backgrounded ssh must not keep this script's output open (a caller piping it would wait for
    # the tunnel to close), so its output goes to a log, shown when it fails to start.
    if ! ssh -f -n -M -S "$TUNNEL_SOCKET" \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        "${args[@]}" "$SSH_HOST" \
        "while [ \"\$(docker inspect -f '{{.State.Running}}' $NAME 2>/dev/null)\" = true ]; do sleep 20; done" \
        >"$TUNNEL_DIR/tunnel-$NAME.log" 2>&1; then
        cat "$TUNNEL_DIR/tunnel-$NAME.log" >&2
        echo "remote.sh: could not open the tunnel for $NAME" >&2
        return 1
    fi
    echo "remote.sh: tunnel for $NAME open (local ports ${FORWARDS[*]%%:*})"
}

close_tunnel() {
    if tunnel_open; then
        ssh -S "$TUNNEL_SOCKET" -O exit "$SSH_HOST" >/dev/null 2>&1 || true
        echo "remote.sh: tunnel for $NAME closed"
    fi
}

# Print the server-side test that succeeds when the watchdog in WATCHDOG_PID is alive. Checking its
# command line, not just the pid, keeps a reused pid from counting as the watchdog.
watchdog_alive_test() {
    echo "[ -f $WATCHDOG_PID ] && grep -q disk-watchdog /proc/\$(cat $WATCHDOG_PID)/cmdline 2>/dev/null"
}

# Start the disk watchdog on the server, detached from this SSH session, unless one is already
# watching this VM. It logs to WATCHDOG_LOG and exits by itself when the container stops.
start_watchdog() {
    ssh "$SSH_HOST" "if $(watchdog_alive_test); then
            echo 'remote.sh: disk watchdog already running'
        else
            setsid nohup bash $SERVER_DIR/disk-watchdog.sh $NAME >> $WATCHDOG_LOG 2>&1 < /dev/null &
            echo \$! > $WATCHDOG_PID
            echo 'remote.sh: disk watchdog started (log: $WATCHDOG_LOG)'
        fi"
}

stop_watchdog() {
    ssh "$SSH_HOST" "if $(watchdog_alive_test); then kill \$(cat $WATCHDOG_PID) && echo 'remote.sh: disk watchdog stopped'; fi; rm -f $WATCHDOG_PID"
}

# Copy the files the server needs from this checkout: the OEM scripts and SSH key list, which are
# bind-mounted into the container, and the disk watchdog.
sync_server_files() {
    ssh "$SSH_HOST" "mkdir -p $SERVER_DIR/oem"
    rsync -a --delete "$VM_DIR/oem/" "$SSH_HOST:$SERVER_DIR/oem/"
    rsync -a "$VM_DIR/disk-watchdog.sh" "$SSH_HOST:$SERVER_DIR/disk-watchdog.sh"
}

cmd_up() {
    # Another session may have started it already; its own memory would fail the checks below.
    if [[ "$(server_running "$NAME")" == true ]]; then
        echo "remote.sh: $NAME is already running on $SSH_HOST"
        start_watchdog
        open_tunnel
        return 0
    fi

    check_can_start
    sync_server_files
    server_compose up -d
    start_watchdog
    open_tunnel
    echo "remote.sh: $NAME is starting on $SSH_HOST; Windows takes a few minutes to answer over SSH"
}

cmd_down() {
    # stop, not down: the container keeps its settings for the next start. The compose file gives
    # Windows two minutes to shut down cleanly.
    if [[ "$(server_running "$NAME")" == true ]]; then
        server_compose stop
    else
        echo "remote.sh: $NAME is not running on $SSH_HOST"
    fi
    stop_watchdog
    close_tunnel
}

# Print "running" or "not running" for a container state from server_running or local_running.
describe_state() {
    if [[ "$1" == true ]]; then
        echo running
    else
        echo "not running"
    fi
}

cmd_status() {
    echo "$NAME on $SSH_HOST: $(describe_state "$(server_running "$NAME")")"
    echo "$NAME in local Docker (fallback): $(describe_state "$(local_running "$NAME")")"
    if tunnel_open; then
        echo "tunnel: open"
    else
        echo "tunnel: closed"
    fi
    if ssh "$SSH_HOST" "$(watchdog_alive_test)"; then
        echo "disk watchdog: running"
    else
        echo "disk watchdog: not running"
    fi
    ssh "$SSH_HOST" "tail -n 3 $WATCHDOG_LOG 2>/dev/null | sed 's/^/  watchdog log: /'"
    ssh "$SSH_HOST" "free -m | awk '/^Mem:/ { print \"server memory available: \" \$7 \" MB\" }'; df -h --output=avail / | tail -1 | sed 's/^ */server disk free on \\/: /'"
}

main() {
    local command="${1:-}"

    use_vm "${2:-win11}"
    case "$command" in
        up) cmd_up ;;
        down) cmd_down ;;
        tunnel) open_tunnel ;;
        status) cmd_status ;;
        *)
            echo "usage: vm/remote.sh up|down|tunnel|status [win11|win10]" >&2
            exit 2
            ;;
    esac
}

main "$@"
