# Windows desktop development from WSL

Run these commands from the repository root in Ubuntu WSL:

| Command | Result |
| --- | --- |
| `npm run build:desktop` | Signed Release dev MSIX for the build host's architecture |
| `npm run verify:desktop` | Full Windows Debug compile, including XAML |
| `npm run install:desktop` | Build, update in place, then launch |
| `npm run install:desktop -- --skip-build` | Reinstall the latest successful dev MSIX for the selected platform |
| `npm run install:desktop -- --skip-build --dry-run` | Validate the install without changing Windows |
| `npm run install:desktop -- --no-launch` | Build and install without launching |
| `npm run package:desktop` | Unsigned Release MSIX with Store identity |

A library with no MSIX project can use `--build-only` with a `windows-build.json`
that names only `project`; packaging and signing keys are required only by the
modes that use them.

The platform defaults to the Windows build host's own architecture: x64 or ARM64.
Local builds use the WSL distro's architecture, which always matches its Windows
host, and VM builds ask the guest for its OS architecture. The bridge prints the
platform it chose. Pass `-- --platform x64` or `-- --platform ARM64` to override it,
for example to build for another PC; apps should not record which architecture a
given PC has. Packaging defaults to Release;
`verify:desktop` uses Debug. Store upload/bundling remains in the existing
project release workflow. These commands never commit, push, or publish.

## Shared build and install policy

Source lives in `/development/`. `scripts/windows-build` delegates to
`/development/windows-build-tools/windows-build.py`. Override that location with
`WINDOWS_BUILD_TOOLS` if needed. Python 3 and the existing Windows PowerShell 7,
.NET SDK and Windows SDK must be available. No npm install is needed just to run
these desktop scripts. Persistent's web/API commands still require its existing
dependencies and Docker environment.

The helper copies the current working tree, including uncommitted changes,
submodule source and local build inputs, into a unique directory under the
Windows user's `%TEMP%\WindowsAppBuilds` on C:. Git metadata, node_modules,
bin/obj, package layouts, previous artifacts and agent folders (`.claude`,
`.agents`, which hold the tracked `.claude/skills` symlink) and nested Git worktrees (`.worktrees`) are excluded; any other
symlink stops the build. It runs Windows
build tools there, returns logs and packages to
`.artifacts/windows-build/<build-id>/`, merges any named deliverables a successful build wrote in its `.artifacts/packages/<version>/` (LAYOUT-12, winui-app-kit's packaging script from v2.2.0) into the repository's own `.artifacts/packages/`, replacing same-named files, then deletes that invocation's Windows
temporary directory on success or failure. Cancellation stops that build's
process tree before cleanup. If it cannot confirm the process stopped, it
reports and preserves the directory for recovery rather than deleting active
inputs. A delete that fails is reported with the folder's path and never changes the build's exit code; the transient "Cannot allocate memory" that WSL's `/mnt/c` client can return when memory is fragmented is retried first. Each build starts by removing the bridge's own stage folders left untouched for over a day, and prints each one it removed. Build IDs are UTC identifiers, not displayed appointment times.

Build and install commands assign a higher four-part dev version only in the
temporary source copy. Tracked release versions stay unchanged. A per-app Windows
mutex serializes dev builds and installs. Store packaging keeps the tracked
release version and revision zero.

### One build at a time per Windows host

Every run takes an exclusive lock for its Windows host before doing any Windows work,
so builds from different sessions and repositories queue instead of overlapping.
Overlapping runs have failed with `UtilAcceptVsock ... accept4 failed 110` from
`pwsh.exe`. A queued run prints `Waiting for another windows-build run on local
(pid N, repo X)` and starts by itself when the lock is free. Pass `--no-wait`
(`npm run verify:desktop -- --no-wait`) to fail at once instead. The local host and
each VM have separate locks under `~/.cache/windows-build-tools/`. The lock is
released when the run exits for any reason, including a crash or `kill -9`, so
there is never a stale lock to delete. Do not write `pgrep` wait loops around these
commands; just run them, and they will queue.

Installation uses `Add-AppxPackage -ForceApplicationShutdown`, verifies the
installed version, and launches its manifest entry point. It never uninstalls,
forces a downgrade or removes another publisher's package. A Store copy signed by
another publisher may coexist with the local dev family; its data is not migrated. Settings remain with
the existing package identity. A mismatch with an installed development publisher stops with instructions to
resolve it explicitly. Every app that selects `shared-dev` uses the same preserved development signing certificate, matching
Little Launcher's installed publisher. Windows checks package name and publisher
as well as version; the helper preserves the project's established package name. Repilot launches Settings
after installation, rather than triggering the Copilot-key handler. A first dev-certificate trust may request Windows UAC;
only the public certificate is added to LocalMachine TrustedPeople. Private keys
stay local and are never copied to output artifacts. See Microsoft's
[certificate guidance](https://learn.microsoft.com/en-us/windows/msix/package/create-certificate-package-signing).

`install:desktop` is a native Windows check, not a Linux test. After installation,
check startup, tray/flyout behavior and the feature changed. ImmichDrive shell,
thumbnail and Cloud Files behavior requires the installed MSIX. A successful
compile does not establish runtime behavior.

The install updates the package in place with `-ForceApplicationShutdown`, then launches the app. If the app was running and registered for restart (`RegisterApplicationRestart`), Windows restarts it after the update; the install then waits up to 8 seconds for that and does not launch it again, because a second launch in the same second fails with "the target host was not in a valid state to receive process registrations" (0x80070BF7). An app that was running but didn't register is launched after that wait.

Run desktop commands from WSL in the signed-in Windows session. A Docker
container can delegate the same commands over the existing Windows SSH host:
mount the shared tools read-only, set `WINDOWS_BUILD_TOOLS` to that mount,
`WINDOWS_BUILD_HOST` to the SSH alias, and `WINDOWS_BUILD_REPO` to the authoritative
host WSL checkout bound into the container. `WINDOWS_BUILD_HOST_TOOLS` defaults to
`/development/windows-build-tools`. The remote command builds that exact
checkout, so the container must bind that same source, not a separate clone.
Persistent's Compose node service supplies these mappings. Windows SSH must be
configured and a signed-in session must exist for installation; installation is
handed to a unique interactive scheduled task and its result checked explicitly.
Direct WSL is the simplest desktop workflow. Container transport requires the
existing SSH credentials and has not been runtime-tested.
On a PC with the Windows build tools, no D: checkout, fixed Windows staging tree,
Windows VM or Windows build container is required. `.artifacts/` is deliberately retained for review and reinstalling;
remove old result directories yourself when no longer needed.

## Codex task guides

Apps that carry `.codex/commands/build.md`, `install.md` or `rebuild.md` should read
the matching guide when performing that task. These are repository task guides, not
automatically registered slash commands. Follow project release guides for releases,
and leave changes uncommitted unless a commit is explicitly requested.

## windows-dev VM (when this PC has no Windows build tools)

`vm/compose.yml` runs a Windows 11 guest (`dockurr/windows`, pinned) under KVM. It normally runs on the home server (ssh alias `home`), not in WSL, so its memory and CPU stay off this machine. It starts on demand and is stopped after use, since the server's memory also runs its own services. Its ports bind to loopback only, on the server, and `vm/remote.sh` opens an SSH tunnel so WSL sees the same addresses as before: web console `http://127.0.0.1:8006`, RDP `127.0.0.1:3389` and SSH `127.0.0.1:2229` (key-only, alias `windows-dev` in `~/.ssh/config`). The build bridge and `vm/app-test` need no setting: they find the container locally or on the server and connect to the same loopback port. The guest's local account password is in `~/.secrets/windows-build-tools/windows-dev/vm.env`, outside version control; Compose reads it on WSL and passes it to the container, so the server keeps no copy on disk. Windows is installed unactivated, which is enough for building.

```bash
vm/remote.sh up        # refuses if another Windows VM runs on the server, or memory or disk is short
npm run verify:desktop
vm/remote.sh down      # clean guest shutdown, then the tunnel closes
vm/remote.sh status    # where it runs, the server's free memory and disk, and the tunnel
```

On the server, the disk is in `/servers/windows-dev/storage` and the OEM scripts in `/servers/windows-dev/oem` (`up` copies `vm/oem` there each time). `up` checks that no other Windows VM runs there (one at a time), that the server keeps at least 1.5 GB of memory available beyond the VM's cap, that its root disk has room for the guest's sparse disk to grow, and that the disk image has been copied there, since an empty storage folder would make the image install a fresh Windows. The server's own xrdp holds port 3389, so the VM's RDP is published at `127.0.0.1:13389` there and the tunnel maps it back to 3389. While the VM runs, `vm/disk-watchdog.sh` runs beside it on the server, started by `up` and stopped by `down`. The guest's disk image is sparse and can grow to its full 128 GB on the same root disk as Home Assistant and the server's other services, which had about 30 GB free when the VM moved. Every minute the watchdog checks free space on `/`: below 8 GB it logs a warning, and below 5 GB it shuts Windows down cleanly (the same two-minute shutdown as `down`). The tunnel ends by itself whenever the container stops, so it never points at a stopped VM. `vm/remote.sh status` shows whether the watchdog runs and the last lines of its log, `/servers/windows-dev/watchdog.log`. Swap on the server is fully used, so its free memory is the `available` column of `free -m` (the kernel's MemAvailable), never `free` plus swap; `up` checks that figure. For the QEMU monitor and other recovery steps in a guest on the server, prefix the usual `docker` commands with `DOCKER_HOST=ssh://home`. Settings: `WINDOWS_VM_SSH_HOST` and `WINDOWS_VM_DOCKER_HOST` name another server.

### Keeping the guests small

Both guests' disks are sparse files that grow as Windows writes and shrink only when the guest trims freed space, which the image passes through by default. `vm/guest-slim.ps1` keeps them small and is safe to re-run: it removes consumer apps and OneDrive, clears caches (temp folders, update downloads, Delivery Optimization, NuGet), turns off hibernation and reserved storage, fixes the page file at 1.5 GB, compresses system files (CompactOS), cleans the component store and trims. It keeps everything builds and app tests use; its header lists what is kept and why, and how to run its steps (Clean, Deep, then Trim after a restart). Run it on a new guest after `guest-toolchain.ps1`, and again whenever the disk has grown. On Windows 10, app removal works only from the desktop session; the header shows how.

### Local fallback

The same compose file can still run the VM in WSL, but no local disk is kept (the local copies were deleted on November 25, 2026, after the move). To use the fallback, first copy the server's disk back with `rsync -S home:/servers/windows-dev/storage/ ~/.local/share/windows-dev/storage/`. The local container and the tunnel use the same local ports, so only one of them can be in use: run `vm/remote.sh down` before the local `up`, and stop the local container before `vm/remote.sh up` (which refuses while it runs).

```bash
docker compose -f /development/windows-build-tools/vm/compose.yml up -d
npm run verify:desktop
docker compose -f /development/windows-build-tools/vm/compose.yml stop
```

Before the first `up`, write the guest's SSH key list from your own public key. It is git-ignored, and the comment field (user@host) is dropped so nothing personal is copied into the guest:

```bash
cut -d' ' -f1,2 ~/.ssh/id_ed25519.pub > /development/windows-build-tools/vm/oem/administrators_authorized_keys
```

The unattended install copies it into the guest once; `vm/oem/administrators_authorized_keys.example` shows the format.

When `pwsh.exe` is not on the WSL path and the `windows-dev` container is running, or whenever the build is asked for the VM explicitly, `vm_transport.py` snapshots the source here, streams it into the guest user's `%TEMP%\WindowsAppBuilds`, runs the same `build-staged.ps1`, copies logs and artifacts back to `.artifacts/windows-build/<build-id>/`, then removes the guest stage. The guest toolchain (PowerShell 7, the .NET SDK band from `global.json`, Visual Studio Build Tools with the C++ workload, ARM64 tools, the UWP build tools and the Windows SDK) is installed by the re-runnable `vm/guest-toolchain.ps1`; see its header for the two commands. To build in the VM on a machine that also has host build tools, pass `--vm` (the `windows-dev` container must be running) or set `WINDOWS_BUILD_VM` to the guest's SSH destination; either one overrides the host tools. It supports `--build-only` and `--no-sign` only: signed builds and installs would need the private dev signing key inside the guest, which is not authorized. The guest is a 4 GiB VM under a 5 GiB hard container cap, sized for the memory the home server (and WSL, for the fallback) can spare; raise both together only when both have room.

Both VMs keep Toronto time. The image starts QEMU with `-rtc base=localtime`, so the guest's hardware clock holds the container's local time and Windows reads it as its own local time. The compose files therefore set `TZ=America/Toronto`, and `vm/oem/guest-clock.ps1` sets the guest to the matching Eastern time zone; with a UTC container and the image's default Pacific guest, both VMs booted 8 hours ahead. The script also registers a "Clock resync" task that resyncs Windows Time at every boot, logging to `C:\OEM\clock-resync.log`. Fresh installs run it from `oem/install.bat`; for a guest installed before that, recreate the container with `up -d` (which picks up the new `TZ`), then run `app_test_clock` from `vm/app-test/app-test.sh` once per guest.

## Windows 10 22H2 test VM

`vm/compose.win10.yml` runs a Windows 10 Pro 22H2 guest (build 19045, the family's minimum, D-018) for installing and exercising apps there before a release (TEST-9). It is a test machine, not a build host: build on the host or the Windows 11 VM, then install the package in this one. It uses the same pinned image, guest password and SSH key list as `windows-dev`, with its own disk and loopback ports beside the build VM's. Like `windows-dev`, it runs on the home server (disk in `/servers/windows10-test/storage`, RDP at `127.0.0.1:13390` there), and `vm/remote.sh ... win10` tunnels the usual local addresses: web console `http://127.0.0.1:8007`, RDP `127.0.0.1:3390` and SSH `127.0.0.1:2230`.

```bash
vm/remote.sh up win10
vm/remote.sh down win10
```

The guest gets 3 GB under a 3.5 GB container cap. Only one Windows VM runs on the server at a time, so `up win10` refuses while `windows-dev` runs there, and the same memory, disk watchdog and tunnel rules apply. The local fallback (`docker compose -f vm/compose.win10.yml up -d`, then `stop`) keeps no local disk since November 25, 2026; copy it back first with `rsync -S home:/servers/windows10-test/storage/ ~/.local/share/windows10-test/storage/`. Check `free -m` first, never run it alongside the Android VM, and stop it before `vm/remote.sh up win10`, since both use the same local ports. The first start downloads Windows 10 from Microsoft and installs it unattended, which takes a while; later starts boot the existing disk. Windows is installed unactivated, which is enough for testing.

The install media is from May 2023 (build 19045.2965), older than any patched user's PC, and .NET 9 and later apps fail to start there ("Your Windows doesn't fully support CET"). After the first install, and after recreating the disk, run `vm/win10-update.sh` with the VM running and nothing else using it. It installs KB5066791, the last public Windows 10 update (October 2025, build 19045.6456), checked against Microsoft's catalog digest, and reports the build it reached. That is the oldest build a patched user can have; later updates need a paid Extended Security Updates licence this guest cannot have. It takes about an hour, and does nothing once the guest is up to date.

## Exercising and capturing an app in a test VM

`vm/app-test/` installs a dev-signed package in `windows10-test` or `windows-dev` and drives and screenshots it there, so UI checks (light, dark, high contrast, narrow widths) never use the Windows host's own desktop. Install in a guest whose Windows meets the app's `MinVersion`: the Windows 10 VM refuses Windows 11-only packages with 0x80073CFD.

| File | Runs | Does |
|---|---|---|
| `app-test.sh` | Host, sourced | `app_test_use win10\|win11`, `app_test_lock` and `app_test_unlock` for `windows-dev`, `app_test_effects` (window effects on `windows-dev`), `app_test_clock` (guest time zone and boot resync), `app_test_language` (the guest's display language as a set; see "Localized captures"), then `app_test_put`, `app_test_put_runtime` (the Windows App Runtime from the NuGet cache), `app_test_ps` (over SSH), `app_test_ui` (a script in the desktop session), `app_test_run` (one line in the desktop session), `app_test_get`, `app_test_screendump` (whole screen through the QEMU monitor, no session needed) and `app_test_clean` (undo the session and remove `C:\apptest`) |
| `install-package.ps1` | Guest, desktop session (`app_test_run`) | Installs any Windows App Runtime packages in `C:\apptest\deps` (skipping, and not recording, any the guest already has at that version or higher, and the whole older release when the guest's runtime framework is newer), trusts the signer's public certificate taken from the package's own signature, then installs or updates the app; records everything it adds in `C:\apptest\installed.txt` |
| `remove-packages.ps1` | Guest, desktop session | Removes what `installed.txt` records, newest first (a newer version only when the guest did not have that package family before, so the guest's own packages stay), and untrusts the certificate if the install trusted it; also after a failed install |
| `screenshot-desktop.ps1` | Guest, desktop session | `-Mode Prepare` saves the desktop settings, then sets the screenshot desktop: the dark bloom wallpaper (`img19.jpg`), no desktop icons, no taskbar search box, Widgets or app notifications (Windows then refuses taskbar pin requests, since its pin prompt is a notification: turn them on around a pin step), Edge and Store unpinned, dark mode for Windows and apps, transparency on, and a 1920 x 1080 desktop for the session: 1920 x 1080 at 100% display scale, or 3840 x 2160 at 200% with `-Scale 200`. `-Mode Restore` puts it all back, including the display scale and the taskbar pins exactly as saved, so a pin a test added is removed (deleting only its shortcut leaves a dead button) |
| `run-interactive.ps1` | Guest, over SSH | Runs a script in the signed-in desktop session through a one-off interactive scheduled task, waits, prints the script's own output (the transcript's lines between two markers the task writes, so the transcript's translated header and footer never leak into it) and removes the task. The task's PowerShell runs in a headless console host, so no terminal button shows on the taskbar in captures |
| `ui-lib.ps1` | Guest, dot-sourced by a UI script | UI Automation lookups by automation ID (`Find-ById`, which works in every display language) and, only for an element without one, by its displayed name (`Find-ByName`), File Explorer's folder windows by class and process, optionally only those showing a path (`Get-ExplorerWindows`), clicks, combo box choices by position (`Select-ComboOption $combo -Index 2`) or by text, window resizing, region screenshots into `C:\apptest\out`, making a window active and checking it took (`Set-WindowActive`), centring a window in the work area (`Set-WindowCentered`), whole-screen captures with a JSON sidecar for Store screenshots (`Save-DesktopCapture`, which also writes `<name>.uia.json`: every named element of the captured window with its control type, automation ID, text and rectangle, for automated localization checks), the user's real display language (`Get-DisplayLanguage`; `Get-UICulture` reads en-US for Chinese and Japanese in the desktop session's console), finding an app's tray icon by its tooltip prefix, such as `"App:"` (`Find-TrayIcon`; a search for a button named after the app finds its taskbar button first), and reading and choosing items of an open popup menu by command ID, position or name (`Get-MenuItems` lists all three; `Invoke-MenuItem -Id 1002`, `-Position 0` or `'Quit'`). Tray menus are standard Win32 popup menus (`#32768`, a top-level window found from the desktop root); these helpers read their items through MSAA, because the managed UI Automation client used here shows them as an empty pane. Native UI Automation and Narrator read them through the system's menu proxy. A drive script opens its own menu immediately before choosing from it, since the helpers act on whichever popup menu is open; `screenshot-desktop.ps1` and `app_test_clean` close any menu left open first, and high contrast on or off for the session (not persisted) |
| `guest-language.ps1` | Guest, over SSH (`app_test_language`) | Switches the user's display language, input language (one keyboard: the plain US layout for zh-CN, the Microsoft IME for ja-JP), home location and regional format together, or back with `-Language en-US`; `-Show` prints them. Applies at the next sign-in |
| `gamebar.ps1` | Guest, dot-sourced after `ui-lib.ps1` | Testing an Xbox Game Bar widget: `Restart-GameBar` (a widget installed while Game Bar ran appears only after a restart), `Switch-GameBar` (the Win+G chord, then a shot), `Invoke-GameBarClick`, `Open-WidgetMenu` and `Open-GameBarWidget` (clicks by screen position, each followed by a shot), and `Wait-LogLine` with `Get-LogPosition` (pass or fail from the app's own log). See "Game Bar widgets" below |

```bash
source vm/app-test/app-test.sh
app_test_use win11
app_test_lock
vm/remote.sh up                            # or the local fallback: docker compose -f vm/compose.yml up -d
app_test_wait 10
app_test_effects                           # once per guest; restarts it the first time
for f in vm/app-test/*.ps1 drive.ps1 App-1.2.3.4-x64.msix; do app_test_put "$f"; done
app_test_put_runtime
app_test_run "& C:\apptest\install-package.ps1 -Msix C:\apptest\App-1.2.3.4-x64.msix"
app_test_run "& C:\apptest\screenshot-desktop.ps1 -Mode Prepare"   # for store or marketing shots
app_test_ui 'C:\apptest\drive.ps1'
app_test_get 'out/*.png' ./shots/
app_test_clean                             # restores the desktop, removes packages and C:\apptest
vm/remote.sh down                          # or: docker compose -f vm/compose.yml stop
app_test_unlock
```

`drive.ps1` is your own UI script: it dot-sources `C:\apptest\ui-lib.ps1` and saves shots in `C:\apptest\out`. Apps built on winui-app-kit can use the kit's ready-made tour of every page and theme instead. `app_test_put_runtime` copies the newest runtime in the NuGet cache (now 2.6.5, which current apps need), for the guest's own architecture; pass a version and `x64` or `arm64` to choose. Builds still on the 1.8 runtime pass their version explicitly, for example `app_test_put_runtime 1.8.260921001`.

### Game Bar widgets

Both guests have Xbox Game Bar, and its overlay draws on the VMs' basic display adapter, so a widget can be opened and checked there. UI Automation can't see inside Game Bar: its overlay has no top-level window the client reaches, and a lookup by point lands on the desktop behind it. A drive script therefore works by sight, with `gamebar.ps1`:

1. Install the package, start the app, then `Restart-GameBar`, so the new widget is listed.
2. `Switch-GameBar 'gamebar-open'` sends Win+G and saves a shot.
3. `Open-WidgetMenu` clicks the toolbar's Widget menu button, by default at 473, 55 on the 1280 x 800 screen, and saves a shot. Read the widget's position in the list from that shot: Microsoft's favourites come first, so it differs between guests and Windows versions.
4. `Open-GameBarWidget <x> <y>` opens the widget and saves a shot; later clicks inside the widget take their positions from that shot.
5. Decide pass or fail from the app's own logs, not the shots: take `Get-LogPosition <path>` before a step, then `Wait-LogLine <path> <pattern> -Since <position>` for the line that step should write (if the log has moved to a new file since, all of it counts), such as the widget's activation or its connection to the app. Game Bar reopens the widgets that were open when it last closed, so take the position before `Switch-GameBar`, not just before the click.

On a new guest or Windows version, run the steps once with shots only, then fill in the positions. The VMs can't show what needs hardware or a game: they have no audio endpoint, no USB devices such as headset receivers, and no full-screen game to draw the overlay over.

For an app that needs a playback device, give the guest an emulated sound card for the session with an uncommitted compose override. Windows lists it as "Speakers (High Definition Audio Device)", a hardware device rather than a virtual one, and its sound goes nowhere:

```yaml
services:
  windows:
    environment:
      ARGUMENTS: "-audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0"
```

Start the guest with both files, for example `docker compose -f vm/compose.win10.yml -f audio-override.yml up -d` on the local fallback, which recreates it. For a guest on the home server, run the same command with `DOCKER_HOST=ssh://home` and the `WINDOWS_VM_STORAGE`, `WINDOWS_VM_OEM` and `WINDOWS_VM_RDP_PORT` values `vm/remote.sh` uses (its `use_vm` and `server_compose`), so the disk and ports stay the server's. Never commit the override. Afterwards, recreate the guest without it (`docker compose -f vm/compose.win10.yml up -d --force-recreate`), and check that `docker inspect` no longer lists `ARGUMENTS` in its environment. On `windows-dev`, hold the build lock throughout.

Both guests sign in automatically, which `run-interactive.ps1` needs: SSH sessions run outside the desktop, so UI Automation, screenshots and theme changes made over SSH do not reach the screen. Install and remove packages in the desktop session too: over SSH, Windows 11 refuses Add-AppxPackage with 0x80070005 "Access is denied". A clean guest has no Windows App Runtime, and apps then fail with 0x80073CF3 "depends on a framework that could not be found"; `app_test_put_runtime` supplies it. Test VM screens are small (1280 x 800), so drive scripts fit the window to the work area (`Set-WindowFitted`) before clicking navigation items, and call `Set-WindowActive` before each shot, since an inactive window has a dimmed title bar and no Mica. On `windows-dev`, the shared build VM, hold its build lock for the whole session (`app_test_lock`, then `app_test_unlock`), and afterwards run `app_test_clean` (also after a failed install), so builds never run against a half-configured guest. The lock outlives the shell that took it: it is held until `app_test_unlock`, from any shell, or until `APP_TEST_LOCK_MINUTES` (default 60) pass, and the lock note shows when it expires. `C:\apptest` belongs to one run at a time. The first `app_test_put` records the owner (`APP_TEST_OWNER`, by default the calling repository's folder name) in `C:\apptest\owner.txt`, and `app_test_put`, `app_test_put_runtime` or `app_test_run` from another owner is refused with the owner's name, so it never undoes another run's install. A folder left by an older run, with no owner record, is refused too, and its install record printed. Once that run is over, `app_test_clean` removes its packages and certificate and frees the folder; it also ends your own session. `windows10-test` has no lock, so the owner record is all that keeps two runs apart there.

Without a GPU, Windows 11 draws square window corners and no Mica, so screenshots from `windows-dev` would not match a real PC. `app_test_effects` sets `HKLM\SOFTWARE\Microsoft\Windows\Dwm` `ForceEffectMode` to 2 and turns transparency effects on, then restarts the guest once; it does nothing when both are already set. That value is undocumented and comes from third-party guides (Winaero, The Windows Club), not Microsoft; delete it to undo. `screenshot-desktop.ps1` reports whether it is on. Widgets are turned off with the documented "Allow widgets" policy, because Windows 11 refuses scripted writes to the per-user `TaskbarDa` setting; File Explorer's taskbar pin has no unpin command a script can call, so it stays. Store screenshots are taken on `windows-dev` only. After `screenshot-desktop.ps1 -Mode Prepare` (with `-Scale 200` for 200% captures, which winui-app-kit v2.10.0 and later crop in logical pixels), a drive script centres the app's window (`Set-WindowCentered $window 1100 700`, frame size in physical pixels, so `2200 1400` at 200%) and calls `Save-DesktopCapture 'name' $window`. That makes the window active and writes `C:\apptest\out\name.png`, the whole screen 1:1, and `name.json`, which records what the winui-app-kit render script needs to crop and check it: `screen` (the PNG's size), `scale` (display scale percent), `window` (the visible frame, without the shadow), `workArea`, `theme` (`apps` and `system`, `dark` or `light`), `wallpaper` (file name), `effects`, `os` and `capturedUtc`. Sizes are physical pixels: at 200%, `screen` is 3840 x 2160 and `scale` 200 (checked against the QEMU screendump and the window's visible edge, November 25, 2026). The helpers run per-monitor DPI aware, so their coordinates stay physical after a scale change in the same sign-in. Write UI scripts in ASCII, or save them as UTF-8 with a byte order mark: the guests' Windows PowerShell 5.1 reads UTF-8 without one as ANSI and mangles labels such as "é". Find elements by automation ID rather than by their text, which changes with the language (see "Localized captures"). Narrator and other assistive technology cannot be judged this way; check them by hand.

### Localized captures

Store screenshots show Windows, the app and its sample data in each listing language (winui-app-kit v2.10.0's `{locale}` manifest entries). `windows-dev` has the language packs for every listing language: en-US, de-DE, es-ES, fr-FR, ja-JP, pt-BR and zh-CN (en-CA and fr-CA reuse en-US and fr-FR). Capture one language at a time, all apps in it, since each switch needs a fresh sign-in:

```bash
source vm/app-test/app-test.sh
app_test_use win11
app_test_lock
vm/remote.sh up && app_test_wait 10
app_test_language ja-JP                    # display, input, home location and format, as a set
vm/remote.sh down && vm/remote.sh up      # the switch applies at the next sign-in (about 80 s)
app_test_wait 10
# ... prepare, capture each app's ja-JP set, app_test_clean ...
app_test_language en-US                    # back to the usual guest, then cycle again
```

Switch on the base disk, before starting a `-snapshot` session: a cold restart discards the snapshot's overlay, and with it the switch. `app_test_language` with no argument prints the current settings. The system locale, the welcome screen and the time zone (Toronto) stay as they are.

Drive scripts must not depend on the display language. Find elements by automation ID (`Find-ById`; give an element `AutomationProperties.AutomationId` in the app when it has none), choose menu items by command ID or position (`Invoke-MenuItem -Id`, `-Position`) and combo box options by position (`Select-ComboOption -Index`), and find File Explorer by `Get-ExplorerWindows`, never by window title. `Find-ByName` and text matches remain for elements that have no ID, with the name for the language being captured. `Find-TrayIcon` matches the app's own tooltip prefix, its product name, which is not translated. `screenshot-desktop.ps1` and `run-interactive.ps1` work in every language.

Input: every language gets one keyboard, so Windows shows no language switcher. zh-CN gets the plain US layout instead of its IME: typed text arrives unchanged and no input indicator shows (checked with SendKeys and `keybd_event` into Notepad at 200%, November 26, 2026). ja-JP keeps the Microsoft IME, because Windows has no plain Japanese keyboard: given the Japanese layout alone, the language was left with no keyboard and the next sign-in loaded the Chinese IME, with its "中" indicator in the taskbar. The Japanese IME starts in direct input, so typed text arrives unchanged (checked with SendKeys and `keybd_event` into Notepad, November 25, 2026), but its input-mode indicator ("A") shows in the taskbar's notification area in every ja-JP capture. Turning on the legacy language bar and hiding it (`Set-WinLanguageBarOption -UseLegacyLanguageBar`, `HKCU\Software\Microsoft\CTF\LangBar` `ShowStatus` 3) removes the indicator in the running session but opens the IME's floating CAPS/KANA toolbar, and Windows turned the legacy bar off again at the next sign-in; there is no settled fix yet. Inbox Store apps such as Notepad stay in English, since the guest gets no Store language resources; only Windows and the app being captured are localized. `Get-InstalledLanguage` also lists `und-Hans` and `und-Jpan` after the zh-CN and ja-JP packs (script support that comes with them).

Each pack was installed over SSH with `Install-Language <tag> -ExcludeFeatures` (from es-ES on, run as SYSTEM in a scheduled task so a dropped SSH session cannot stop it; it still adds Basic typing and OCR), followed by `guest-slim.ps1 -Step Clean`. Measured on November 25, 2026:

| Language | Install | Clean | Disk image peak | Disk image after Clean |
|---|---|---|---|---|
| de-DE | 26 min | 9 min | +3.3 GB | +0.44 GB |
| es-ES | about 28 min | 6 min | at least +3.2 GB | +0.36 GB |
| fr-FR | 28 min | 6 min | +3.4 GB | +0.31 GB |
| zh-CN | 31 min | 7 min | +3.7 GB | +0.45 GB |
| pt-BR | 28 min | 7 min | +3.4 GB | +0.26 GB |
| ja-JP | 28 min | 6 min | +3.7 GB | +0.45 GB |

Sizes are the server's `data.img` (`du`) against its size before each pack. All six add about 2.2 GB to the image (33.9 GB to 36.1 GB); the server's free disk never fell below 26 GB. Do not run two installs at once: each peaks at about 3.7 GB before Clean hands it back.

## Shared development signing

The six app manifests (Hub Display Switch, ImmichDrive, Little Launcher, Persistent,
Repilot and WSL Monitor) select `shared-dev`; winui-app-kit is a library and uses
`--build-only`. The single local key is
`signing/windows-apps-dev.pfx` beside this helper, exported from the existing
Little Launcher Store-identity development certificate. Its publisher is
`CN=C21E6CEF-D0D1-4497-93F9-3718D054DA0E`; its thumbprint is
`E608BFE231C345D9BFA967E1383D2C49E9BE79C2`. It is self-signed for local development,
not a production CA certificate. The helper injects it only into signed staging,
exports only its public certificate, and cleans the temporary private copy.
The key has mode 600 and its directory mode 700. Back it up securely; do not
commit it, rotate it automatically, or regenerate it for each build.

The repository's old private keys remain untouched as recovery inputs; they are
not selected by these npm commands. The key's password is never written in source:
fresh signed builds read it from `~/.secrets/windows-build-tools/signing/windows-apps-dev.password`
(mode 600, directory mode 700) and stop with a clear message if it is missing.
Compile-only, unsigned and `--skip-build` runs do not need it. Store packages stay unsigned and Microsoft signs
them on ingestion. Changing signing policy does not authorize a Store submission.

## Testing an update over a Store installation

Projects that configure `store_identity`, `store_publisher`, and `store_identity_switch`
can opt into `npm run install:desktop -- --store-identity`. This signs a local test
package with the existing Store name and publisher, allocates its revision against that
installed family, and updates in place. The signing certificate must match the Store
publisher, so each Partner Center publisher has its own self-signed key in `signing/`,
listed in `STORE_PUBLISHER_KEYS` in `windows-build.py`: `windows-apps-dev.pfx` for
`CN=C21E6CEF-D0D1-4497-93F9-3718D054DA0E`, and `dynamic-solutions-dev.pfx` for
`CN=B55B96A5-F10C-49D3-8D0B-7260EDBE7625` (ChatMixr, DisplaySwitchr, Tray Control for WSL;
thumbprint `FF22AEBB4FEC5716E6544EA5F6A6D3C00047E9B6`, expires 2029-11-24). Each key's
password is `~/.secrets/windows-build-tools/signing/<key>.password`; the same rules as the
shared key apply. Dev-identity builds always sign with `windows-apps-dev.pfx`. The first
install signed by a new key asks Windows for consent to trust its public certificate. Package data stays with the same family; no uninstall is performed. Store
updates resume when a higher version becomes available. This is local testing, not a
Store submission. Other projects and default dev builds keep their existing identities.
`--skip-build` selects only packages built for the requested identity mode.

Store-distributed bundles must be updated with signed `.msixbundle` files, not standalone
MSIX packages. The bridge supports both formats and validates bundle identity against its
application package before installing. ImmichDrive packages its Store-identity test builds
as bundles with an explicit version.
