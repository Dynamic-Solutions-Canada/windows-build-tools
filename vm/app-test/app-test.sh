#!/usr/bin/env bash
# Host helpers for exercising an installed app in a test VM (windows10-test or windows-dev) and
# capturing it, without touching the Windows host's own desktop. Source this file, then:
#   app_test_use win10        # or: app_test_use win11 (the build VM; app_test_lock first, app_test_unlock after)
#   app_test_put local.ps1    # copy into C:\apptest\ in the guest
#   app_test_ps C:\\apptest\\install-package.ps1 -Msix C:\\apptest\\App.msix   # over SSH
#   app_test_ui C:\\apptest\\drive.ps1     # run in the signed-in desktop session (no arguments)
#   app_test_get out/name.png ./shots/     # copy back from C:\apptest\
#   app_test_screendump ./shots/full.png   # whole guest screen through the QEMU monitor
# Scripts that drive UI dot-source C:\apptest\ui-lib.ps1 and save shots in C:\apptest\out.

app_test_use() {
    case "$1" in
        win10) APP_TEST_PORT=2230; APP_TEST_CONTAINER=windows10-test; APP_TEST_KNOWN=$HOME/.ssh/known_hosts_windows10_test ;;
        win11) APP_TEST_PORT=2229; APP_TEST_CONTAINER=windows-dev;    APP_TEST_KNOWN=$HOME/.ssh/known_hosts_windows_dev ;;
        *) echo "app_test_use: win10 or win11" >&2; return 1 ;;
    esac
    APP_TEST_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$APP_TEST_KNOWN"
                   -o IdentitiesOnly=yes -o LogLevel=ERROR -i "$HOME/.ssh/id_ed25519")
    APP_TEST_USER=$(grep -oP '^USERNAME=\K.*' "$HOME/.secrets/windows-build-tools/windows-dev/vm.env")
}

app_test_ssh() { ssh "${APP_TEST_OPTS[@]}" -p "$APP_TEST_PORT" "$APP_TEST_USER@127.0.0.1" "$@"; }
app_test_put() { app_test_ssh 'if not exist C:\apptest mkdir C:\apptest' && scp -q "${APP_TEST_OPTS[@]}" -P "$APP_TEST_PORT" "$1" "$APP_TEST_USER@127.0.0.1:C:/apptest/${2:-$(basename "$1")}"; }
app_test_get() { scp -q "${APP_TEST_OPTS[@]}" -P "$APP_TEST_PORT" "$APP_TEST_USER@127.0.0.1:C:/apptest/$1" "$2"; }
# Each argument is passed in double quotes, so paths may contain spaces (not double quotes).
app_test_ps()  { local script="$1"; shift; app_test_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File \"$script\"$(printf ' "%s"' "$@")"; }
# The UI script takes no arguments (quoting through SSH, cmd and a scheduled task is fragile):
# write any inputs into the script or a file beside it.
app_test_ui()  { app_test_ps 'C:\apptest\run-interactive.ps1' -Script "$1"; }

# Hold windows-dev's build lock (the same one vm_transport.py takes), so no build runs against a guest
# that is half-configured for testing. Waits while a build holds it. The holder runs in its own
# session and outlives the calling shell (agent shells exit after every command): it lasts until
# app_test_unlock, from any shell, or until APP_TEST_LOCK_MINUTES (default 60) have passed.
app_test_lock() {
    local tools minutes log
    tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    minutes="${APP_TEST_LOCK_MINUTES:-60}"
    log="$(_app_test_lock_file).holder.log"
    # Create the directory and empty the log before starting, so the wait below can never read a
    # previous holder's "holding" line, and the first use on a new machine does not fail.
    mkdir -p "$(dirname "$log")"
    : >"$log"
    setsid python3 -I -c "
import sys, time
sys.path.insert(0, sys.argv[1])
import build_lock
minutes = int(sys.argv[2])
end = time.localtime(time.time() + minutes * 60)
expires = time.strftime('%Y-%m-%d ', end) + time.strftime('%I:%M', end).lstrip('0') + (' a.m. ' if end.tm_hour < 12 else ' p.m. ') + time.strftime('%Z', end)
held = build_lock.acquire('vm-windows-dev', f'app-test, held until {expires}')
print(f'app-test: holding the vm-windows-dev build lock until {expires}', flush=True)
time.sleep(minutes * 60)
print(f'app-test: time limit of {minutes} min reached; released the vm-windows-dev build lock', flush=True)
" "$tools" "$minutes" >"$log" 2>&1 < /dev/null &
    # setsid forks, so $! is not the holder; follow its log instead. While a build holds the lock,
    # build_lock prints "Waiting for ..." there and this keeps waiting.
    until grep -q "^app-test: holding" "$log" 2>/dev/null; do
        if grep -q "Traceback\|Error" "$log" 2>/dev/null; then
            echo "app_test_lock: the lock holder failed:" >&2
            cat "$log" >&2
            return 1
        fi
        sleep 1
    done
    cat "$log"
}

# Release the lock app_test_lock took, from this or any later shell. Kills only a holder whose lock
# note says "repo app-test", so a real build's lock is never touched.
app_test_unlock() {
    local note pid
    note="$(cat "$(_app_test_lock_file)" 2>/dev/null)"
    if [[ "$note" =~ ^pid\ ([0-9]+),\ repo\ app-test ]]; then
        pid="${BASH_REMATCH[1]}"
        if kill -0 "$pid" 2>/dev/null && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "build_lock"; then
            kill "$pid" || return 1
            # Report release only once the holder has exited and the kernel has dropped its lock.
            for _ in $(seq 1 50); do
                kill -0 "$pid" 2>/dev/null || { echo "app-test: released the vm-windows-dev build lock (pid $pid)"; return 0; }
                sleep 0.1
            done
            echo "app_test_unlock: pid $pid did not exit within 5 s" >&2
            return 1
        fi
    fi
    echo "app_test_unlock: no app-test holder of the vm-windows-dev lock is running"
}

_app_test_lock_file() { echo "${XDG_CACHE_HOME:-$HOME/.cache}/windows-build-tools/vm-windows-dev.lock"; }

# Whole-screen capture from QEMU (works even with no session script running). Converts the monitor's
# PPM to PNG with the Python standard library.
app_test_screendump() {
    local out="$1" tmp
    tmp=$(mktemp -d)
    printf 'screendump /tmp/app-test.ppm\n' | docker exec -i "$APP_TEST_CONTAINER" sh -c 'nc -q1 -U /run/shm/monitor.sock' >/dev/null 2>&1
    # The monitor writes the file asynchronously; wait until its size stops changing.
    local size=-1 now
    for _ in $(seq 1 20); do
        sleep 0.5
        now=$(docker exec "$APP_TEST_CONTAINER" stat -c %s /tmp/app-test.ppm 2>/dev/null || echo 0)
        [[ "$now" -gt 0 && "$now" == "$size" ]] && break
        size=$now
    done
    docker cp "$APP_TEST_CONTAINER:/tmp/app-test.ppm" "$tmp/s.ppm" >/dev/null
    python3 -I - "$tmp/s.ppm" "$out" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
magic, size, depth, pixels = data.split(b"\n", 3)
width, height = map(int, size.split())
rows = b"".join(b"\x00" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
PY
    rm -rf "$tmp"
}
