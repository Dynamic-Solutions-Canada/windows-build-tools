#!/usr/bin/env bash
# Bring the windows10-test guest up to the last public Windows 10 22H2 cumulative update, so it
# matches a patched user's PC rather than the May 2023 install media. Re-runnable: it does nothing
# when the guest is already at that build or later.
#
# Why this update: .NET 9 and later apps opt into CET shadow stacks, and Windows 10 builds before the
# late-2024 updates stop every such app at startup ("Your Windows doesn't fully support CET").
# KB5066791 (October 14, 2025, build 19045.6456) is the final update for PCs without paid Extended
# Security Updates, so every patched Windows 10 PC is at this build or later. Later ESU updates need
# an ESU licence this unactivated guest cannot have.
#
# Usage, from the repo root, with windows10-test running and nothing else using it:
#   vm/win10-update.sh
# Takes roughly an hour: a 730 MB download (kept for re-runs), the install, and a long first reboot.
set -euo pipefail

TARGET_BUILD=19045
TARGET_UBR=6456
MSU_URL='https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2025/10/windows10.0-kb5066791-x64_3210d264091be5effb3253d05397c4daefba44c8.msu'
# Microsoft Update Catalog digest, also embedded in the file name.
MSU_SHA1=3210d264091be5effb3253d05397c4daefba44c8
CACHE="$HOME/.local/share/windows10-test/updates"
MSU="$CACHE/windows10.0-kb5066791-x64.msu"

# shellcheck source=app-test/app-test.sh
source "$(dirname "${BASH_SOURCE[0]}")/app-test/app-test.sh"
app_test_use win10

# Print the guest's build as "<CurrentBuild>.<UBR>", or nothing while SSH is unreachable.
guest_build() {
    local values build ubr
    values=$(app_test_ssh 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild & reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v UBR' 2>/dev/null | tr -d '\r') || return 0
    build=$(awk '/CurrentBuild/ { print $3 }' <<<"$values")
    ubr=$(awk '/UBR/ { print $3 }' <<<"$values")   # REG_DWORD, printed as hex (0x...)
    [[ -n "$build" && -n "$ubr" ]] && echo "$build.$(( ubr ))"
    return 0
}

# Phase 1: confirm the guest is up and still needs the update.
[[ "$(_app_test_docker inspect -f '{{.State.Running}}' "$APP_TEST_CONTAINER" 2>/dev/null)" == true ]] ||
    { echo "win10-update: start it first: docker compose -f vm/compose.win10.yml up -d (or vm/remote.sh up win10 once it lives on the home server)" >&2; exit 1; }
app_test_wait 15
before=$(guest_build)
if (( ${before#*.} >= TARGET_UBR )) && [[ "${before%%.*}" == "$TARGET_BUILD" ]]; then
    echo "win10-update: already at $before; nothing to do"
    exit 0
fi
echo "win10-update: guest is at $before; installing KB5066791 ($TARGET_BUILD.$TARGET_UBR)"

# Phase 2: fetch the package once, and check it against the catalog digest every time.
mkdir -p "$CACHE"
if [[ ! -f "$MSU" ]]; then
    curl -sSf -o "$MSU.part" "$MSU_URL"
    mv "$MSU.part" "$MSU"
fi
echo "$MSU_SHA1  $MSU" | sha1sum -c --quiet - || { echo "win10-update: $MSU does not match the catalog digest; delete it and retry" >&2; exit 1; }

# Phase 3: install with DISM, which works over SSH (wusa does not). Windows 10's DISM cannot add an
# .msu to the running system ("Error: 50 The request is not supported"), so unpack it and add its
# servicing stack update first, then the cumulative update. DISM exits 3010 for "restart required",
# which reaches us as 194: SSH passes on only the low 8 bits of an exit code (3010 is 0xBC2).
# Its own folder, not C:\apptest: that belongs to whichever app-test run claims it.
app_test_ssh 'if exist C:\win10-update rmdir /s /q C:\win10-update' || true
app_test_ssh 'mkdir C:\win10-update\kb5066791' && _app_test_copy "$MSU" C:/win10-update/kb5066791.msu
app_test_ssh 'expand -F:*.cab C:\win10-update\kb5066791.msu C:\win10-update\kb5066791 >nul'
for cab in SSU-19041.6449-x64.cab Windows10.0-KB5066791-x64.cab; do
    echo "win10-update: adding $cab"
    set +e
    app_test_ssh "dism /Online /Add-Package /PackagePath:C:\\win10-update\\kb5066791\\$cab /Quiet /NoRestart"
    code=$?
    set -e
    if (( code != 0 && code != 3010 && code != 194 )); then
        echo "win10-update: DISM failed on $cab with exit code $code; see C:\\Windows\\Logs\\DISM\\dism.log in the guest" >&2
        exit "$code"
    fi
done

# Phase 4: restart to finish servicing, then report the build the guest reached.
app_test_restart 90
app_test_ssh 'rmdir /s /q C:\win10-update' || true
after=$(guest_build)
echo "win10-update: guest is now at $after (was $before)"
# Servicing can need a second restart; a lower revision here means it has not finished yet.
if (( ${after#*.} < TARGET_UBR )); then
    echo "win10-update: below $TARGET_BUILD.$TARGET_UBR; restart the guest once more and re-run to check" >&2
    exit 1
fi
