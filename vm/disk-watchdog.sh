#!/usr/bin/env bash
# Disk watchdog for a Windows VM on the home server. vm/remote.sh copies this script to the server and
# starts it there, detached, beside the container; it is not meant to be run by hand.
#   disk-watchdog.sh <container>
#
# The guest's disk image is sparse: it starts at what Windows has written and can grow to its full
# virtual size (128 GB for windows-dev), on the same root disk as Home Assistant and the server's other
# services. Every minute while the container runs, this checks the free space on /. Below 8 GB it logs
# a warning; below 5 GB it shuts the guest down cleanly (docker stop with the compose file's two-minute
# grace period, so Windows gets the same shutdown as vm/remote.sh down) and exits. vm/remote.sh's
# tunnel ends by itself once the container stops. It also exits when the container stops for any
# other reason, so a stopped VM leaves nothing running.
set -uo pipefail

CONTAINER="$1"
WARN_MB=8192
STOP_MB=5120
INTERVAL_SECONDS=60
# How long to wait for the container to start before giving up, in seconds.
START_GRACE_SECONDS=180

# Print a line to the log (stdout, redirected by vm/remote.sh) with the time in Toronto.
log() {
    echo "$(TZ=America/Toronto date '+%Y-%m-%d %-I:%M:%S %p' | sed 's/ AM$/ a.m./; s/ PM$/ p.m./') $CONTAINER: $*"
}

running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true ]]
}

# Free space on /, in MB.
free_mb() {
    df -BM --output=avail / | tail -1 | tr -dc '0-9'
}

# Wait for the container to come up, since the watchdog starts right after compose up.
waited=0
until running; do
    if (( waited >= START_GRACE_SECONDS )); then
        log "container did not start within $START_GRACE_SECONDS s; watchdog exiting"
        exit 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
done
log "watchdog started (warn below $WARN_MB MB free on /, shut down below $STOP_MB MB)"

while running; do
    free=$(free_mb)
    if (( free < STOP_MB )); then
        log "STOPPING: only $free MB free on /; shutting the guest down to protect the server's services"
        docker stop -t 120 "$CONTAINER" >/dev/null
        log "guest stopped"
        exit 0
    fi
    if (( free < WARN_MB )); then
        log "WARNING: only $free MB free on /; the guest stops below $STOP_MB MB"
    fi
    sleep "$INTERVAL_SECONDS"
done
log "container stopped; watchdog exiting"
