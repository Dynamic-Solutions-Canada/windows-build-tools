#!/usr/bin/env bash
# Host helpers for exercising an installed app in a test VM (windows10-test or windows-dev) and
# capturing it, without touching the Windows host's own desktop. Source this file, then:
#   app_test_use win10        # or: app_test_use win11 (the build VM; app_test_lock first, app_test_unlock after)
#   app_test_put local.ps1    # copy into C:\apptest\ in the guest (claims C:\apptest for this repo)
#   app_test_put_runtime               # Windows App Runtime MSIX files from the NuGet cache, if the guest lacks them
#   app_test_run "& C:\\apptest\\install-package.ps1 -Msix C:\\apptest\\App.msix"   # one line in the desktop session
#   app_test_ps C:\\apptest\\script.ps1 -Arg value   # over SSH (no desktop, no package installs on Windows 11)
#   app_test_ui C:\\apptest\\drive.ps1     # run in the signed-in desktop session (no arguments)
#   app_test_get out/name.png ./shots/     # copy back from C:\apptest\
#   app_test_screendump ./shots/full.png   # whole guest screen through the QEMU monitor
#   app_test_effects                       # windows-dev only: rounded corners, shadows and Mica
#   app_test_clock                         # Toronto time zone and a clock resync at every boot
#   app_test_clean                         # undo the session and remove C:\apptest, whoever left it
# Scripts that drive UI dot-source C:\apptest\ui-lib.ps1 and save shots in C:\apptest\out.
#
# C:\apptest belongs to one run at a time, named by APP_TEST_OWNER (default: the calling repository's
# folder name). The first app_test_put records the owner in C:\apptest\owner.txt; later puts from
# another owner refuse and say whose it is, so one run never undoes another's install. app_test_clean
# ends the session and releases the folder.

app_test_use() {
    case "$1" in
        win10) APP_TEST_PORT=2230; APP_TEST_CONTAINER=windows10-test; APP_TEST_KNOWN=$HOME/.ssh/known_hosts_windows10_test ;;
        win11) APP_TEST_PORT=2229; APP_TEST_CONTAINER=windows-dev;    APP_TEST_KNOWN=$HOME/.ssh/known_hosts_windows_dev ;;
        *) echo "app_test_use: win10 or win11" >&2; return 1 ;;
    esac
    APP_TEST_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$APP_TEST_KNOWN"
                   -o IdentitiesOnly=yes -o LogLevel=ERROR -i "$HOME/.ssh/id_ed25519")
    APP_TEST_USER=$(grep -oP '^USERNAME=\K.*' "$HOME/.secrets/windows-build-tools/windows-dev/vm.env")
    # Who this run is, for the C:\apptest owner record; letters, digits, dot, dash and underscore only.
    APP_TEST_OWNER="${APP_TEST_OWNER:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
    APP_TEST_OWNER="${APP_TEST_OWNER//[^A-Za-z0-9._-]/_}"
}

app_test_ssh() { ssh "${APP_TEST_OPTS[@]}" -p "$APP_TEST_PORT" "$APP_TEST_USER@127.0.0.1" "$@"; }
app_test_put() { _app_test_claim && _app_test_copy "$1" "C:/apptest/${2:-$(basename "$1")}"; }
# Copy a file to any guest path (forward slashes), without the C:\apptest ownership check.
_app_test_copy() { scp -q "${APP_TEST_OPTS[@]}" -P "$APP_TEST_PORT" "$1" "$APP_TEST_USER@127.0.0.1:$2"; }
app_test_get() { scp -q "${APP_TEST_OPTS[@]}" -P "$APP_TEST_PORT" "$APP_TEST_USER@127.0.0.1:C:/apptest/$1" "$2"; }
# Each argument is passed in double quotes, so paths may contain spaces (not double quotes).
app_test_ps()  { local script="$1"; shift; app_test_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File \"$script\"$(printf ' "%s"' "$@")"; }
# The UI script takes no arguments (quoting through SSH, cmd and a scheduled task is fragile):
# write any inputs into the script or a file beside it.
app_test_ui()  { app_test_ps 'C:\apptest\run-interactive.ps1' -Script "$1"; }

# Run one PowerShell line in the desktop session, by writing it into a throwaway script. Needed for
# installs and removals: Windows 11 refuses Add-AppxPackage over SSH ("Access is denied").
app_test_run() { _app_test_claim && _app_test_run_line "$1"; }

# app_test_run without the ownership check, for app_test_clean.
_app_test_run_line() {
    local tmp status
    tmp=$(mktemp --suffix=.ps1)
    printf '%s\n' "$1" > "$tmp"
    _app_test_copy "$tmp" C:/apptest/run-line.ps1 && app_test_ui 'C:\apptest\run-line.ps1'
    status=$?
    rm -f "$tmp"
    return "$status"
}

# Make sure C:\apptest belongs to this run (APP_TEST_OWNER), claiming it when it does not exist.
# Refuses, naming the owner, when another run's files are there: its install record would otherwise
# be undone by this run's cleanup (one run's remove-packages once removed another's app and
# untrusted its certificate). A folder without an owner record predates this check; its install
# record is printed so the caller can tell whose it is. app_test_clean releases either kind.
_app_test_claim() {
    local state
    state=$(app_test_ssh 'if exist C:\apptest\owner.txt (type C:\apptest\owner.txt) else if exist C:\apptest\ (echo ?unowned) else (echo ?absent)') || return 1
    state="${state//$'\r'/}"
    state="${state%"${state##*[![:space:]]}"}"
    case "$state" in
        '?absent')
            app_test_ssh "mkdir C:\\apptest && echo $APP_TEST_OWNER, claimed $(_app_test_now)>C:\\apptest\\owner.txt"
            ;;
        '?unowned')
            echo "app-test: C:\apptest in $APP_TEST_CONTAINER was left by an earlier run and has no owner record. Its install record:" >&2
            app_test_ssh 'type C:\apptest\installed.txt 2>nul || echo (none)' >&2
            echo "app-test: if that run is over, app_test_clean removes its packages and certificate and frees the folder" >&2
            return 1
            ;;
        "$APP_TEST_OWNER, "*)
            return 0
            ;;
        *)
            echo "app-test: C:\apptest in $APP_TEST_CONTAINER belongs to another run: $state (this run is $APP_TEST_OWNER)" >&2
            echo "app-test: wait until it is done; if it is over and left the folder behind, app_test_clean removes its packages and certificate and frees it" >&2
            return 1
            ;;
    esac
}

# The current time in Toronto as "2026-11-17 3:05 p.m. EST", for owner and lock notes.
_app_test_now() {
    TZ=America/Toronto date '+%Y-%m-%d %-I:%M %p %Z' | sed 's/ AM / a.m. /; s/ PM / p.m. /'
}

# End a test session in the guest, whichever run left it: restore the screenshot desktop if it was
# prepared, remove the recorded packages and untrust the certificate (remove-packages.ps1), then
# delete C:\apptest and with it the owner record. Fresh copies of the scripts it needs are copied in
# first, since the folder may hold another run's older versions. Keeps the folder, and returns 1, when
# either step leaves its record behind, so nothing recorded is forgotten.
app_test_clean() {
    local here owner script left
    here="$(dirname "${BASH_SOURCE[0]}")"
    if ! app_test_ssh 'if exist C:\apptest\ (exit 0) else (exit 1)'; then
        echo "app-test: nothing to clean in $APP_TEST_CONTAINER"
        return 0
    fi
    owner=$(app_test_ssh 'type C:\apptest\owner.txt 2>nul' | tr -d '\r')
    echo "app-test: cleaning C:\apptest in $APP_TEST_CONTAINER (${owner:-no owner record})"
    for script in run-interactive.ps1 remove-packages.ps1 screenshot-desktop.ps1; do
        _app_test_copy "$here/$script" "C:/apptest/$script" || return 1
    done
    _app_test_run_line '& C:\apptest\screenshot-desktop.ps1 -Mode Restore' || return 1
    _app_test_run_line '& C:\apptest\remove-packages.ps1' || return 1

    # Each script deletes its own record only when it finishes; the desktop session reports failures
    # as output, not as an exit code. Either record still there means a step failed.
    left=$(app_test_ssh 'if exist C:\apptest\desktop\state.json echo desktop\state.json& if exist C:\apptest\installed.txt echo installed.txt') || return 1
    left="${left//$'\r'/}"
    if [[ -n "${left//[[:space:]]/}" ]]; then
        echo "app_test_clean: kept C:\apptest, since a step failed and left its record behind: $(tr '\n' ' ' <<<"$left")" >&2
        return 1
    fi
    app_test_ssh 'rmdir /s /q C:\apptest' && echo "app-test: removed C:\apptest"
}

# Force Windows 11's window effects (rounded corners, shadows, Mica) on in windows-dev and turn
# transparency effects on, then restart the guest once if anything changed. Without a GPU, Windows
# draws square corners and no Mica, so screenshots would not match a real PC. ForceEffectMode is an
# undocumented DWM value from third-party sources (Winaero, The Windows Club), not Microsoft
# documentation; delete it to undo. Needs app_test_lock, since it restarts the shared build VM.
app_test_effects() {
    local values
    if [[ "$APP_TEST_CONTAINER" != windows-dev ]]; then
        echo "app_test_effects: windows-dev only (app_test_use win11); Windows 10 has no rounded corners or Mica" >&2
        return 1
    fi
    values=$(app_test_ssh 'reg query HKLM\SOFTWARE\Microsoft\Windows\Dwm /v ForceEffectMode 2>nul & reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize /v EnableTransparency 2>nul') || return 1
    if grep -q 'ForceEffectMode.*0x2$' <<<"${values//$'\r'/}" && grep -q 'EnableTransparency.*0x1$' <<<"${values//$'\r'/}"; then
        echo "app-test: window effects and transparency are already on"
        return 0
    fi
    if [[ -z "$(_app_test_lock_holder)" ]]; then
        echo "app_test_effects: this restarts windows-dev; take app_test_lock first" >&2
        return 1
    fi
    app_test_ssh 'reg add HKLM\SOFTWARE\Microsoft\Windows\Dwm /v ForceEffectMode /t REG_DWORD /d 2 /f >nul && reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize /v EnableTransparency /t REG_DWORD /d 1 /f >nul' || return 1
    echo "app-test: window effects set; restarting windows-dev to apply them"
    app_test_restart 10 && echo "app-test: window effects are on"
}

# Set the guest's clock up: the Eastern time zone that matches the container's TZ, a "Clock resync"
# task at every boot, and a resync now (vm/oem/guest-clock.ps1). Fresh installs run it from
# oem/install.bat; this applies it to a guest installed before that. Safe to re-run; no restart.
app_test_clock() {
    local script
    script="$(dirname "${BASH_SOURCE[0]}")/../oem/guest-clock.ps1"
    _app_test_copy "$script" 'C:/OEM/guest-clock.ps1' || return 1
    app_test_ps 'C:\OEM\guest-clock.ps1'
}

# Restart the guest and wait, up to $1 minutes after it goes down, until it is back with a new boot
# time. Watching the boot time, not SSH dropping, matters: a guest can reboot in about 20 seconds,
# between two SSH checks, and a reboot that was never seen looked like one that never happened.
app_test_restart() {
    local before after deadline
    before=$(_app_test_boot_time) || return 1
    app_test_ssh 'shutdown /r /t 5 /c "app-test restart"' || return 1
    deadline=$(( $(date +%s) + 300 + $1 * 60 ))
    while :; do
        sleep 10
        after=$(_app_test_boot_time 2>/dev/null)
        if [[ -n "$after" && "$after" != "$before" ]]; then
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            echo "app-test: $APP_TEST_CONTAINER did not restart within $(( 5 + $1 )) minutes" >&2
            return 1
        fi
    done
}

# Print when the guest last booted, as .NET ticks; fails when the guest does not answer.
_app_test_boot_time() {
    local ticks
    ticks=$(app_test_ssh 'powershell -NoProfile -Command (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.Ticks') || return 1
    ticks="${ticks//[^0-9]/}"
    [[ -n "$ticks" ]] && echo "$ticks"
}

# Wait until the guest answers over SSH, up to $1 minutes.
app_test_wait() {
    local deadline=$(( $(date +%s) + $1 * 60 ))
    until app_test_ssh 'exit 0' 2>/dev/null; do
        if (( $(date +%s) >= deadline )); then
            echo "app-test: $APP_TEST_CONTAINER did not answer over SSH within $1 minutes" >&2
            return 1
        fi
        sleep 10
    done
}

# Copy the Windows App Runtime packages (framework, main, singleton, DDLM) from the NuGet cache into
# C:\apptest\deps, where install-package.ps1 installs them first. A clean guest has no runtime, and
# apps then fail with 0x80073CF3 "depends on a framework that could not be found".
#   $1: runtime package version (as in ~/.nuget/packages/microsoft.windowsappsdk.runtime/); defaults
#       to the newest there.
#   $2: x64 or arm64; defaults to the guest's own Windows architecture.
app_test_put_runtime() {
    local root="${NUGET_PACKAGES:-$HOME/.nuget/packages}/microsoft.windowsappsdk.runtime" version arch msix
    version="${1:-$(ls "$root" 2>/dev/null | sort -V | tail -1)}"
    arch="${2:-$(_app_test_guest_arch)}" || return 1
    [[ -n "$version" && -d "$root/$version/tools/MSIX/win10-$arch" ]] || { echo "app_test_put_runtime: no runtime MSIX under $root/$version/tools/MSIX/win10-$arch" >&2; return 1; }
    _app_test_claim || return 1
    app_test_ssh 'if not exist C:\apptest\deps mkdir C:\apptest\deps' || return 1
    for msix in "$root/$version/tools/MSIX/win10-$arch"/*.msix; do
        app_test_put "$msix" "deps/$(basename "$msix")" || return 1
    done
    echo "app-test: copied Windows App Runtime $version ($arch)"
}

# Print the guest's Windows architecture as a NuGet runtime folder suffix (x64 or arm64). Reads the
# machine-wide PROCESSOR_ARCHITECTURE from the registry, which names the real OS architecture even
# when the reading shell runs emulated (the per-process variable would not).
_app_test_guest_arch() {
    local value
    value=$(app_test_ssh 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PROCESSOR_ARCHITECTURE' |
            tr -d '\r' | awk '/PROCESSOR_ARCHITECTURE/ { print $3 }')
    case "$value" in
        AMD64) echo x64 ;;
        ARM64) echo arm64 ;;
        *) echo "app_test_put_runtime: unsupported guest architecture '$value'; pass x64 or arm64" >&2; return 1 ;;
    esac
}

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
    local pid
    pid="$(_app_test_lock_holder)"
    if [[ -z "$pid" ]]; then
        echo "app_test_unlock: no app-test holder of the vm-windows-dev lock is running"
        return 0
    fi
    kill "$pid" || return 1
    # Report release only once the holder has exited and the kernel has dropped its lock.
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || { echo "app-test: released the vm-windows-dev build lock (pid $pid)"; return 0; }
        sleep 0.1
    done
    echo "app_test_unlock: pid $pid did not exit within 5 s" >&2
    return 1
}

# Print the pid of the running app_test_lock holder, or nothing when no app-test run holds the lock.
_app_test_lock_holder() {
    local note pid
    note="$(cat "$(_app_test_lock_file)" 2>/dev/null)"
    [[ "$note" =~ ^pid\ ([0-9]+),\ repo\ app-test ]] || return 0
    pid="${BASH_REMATCH[1]}"
    if kill -0 "$pid" 2>/dev/null && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "build_lock"; then
        echo "$pid"
    fi
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
