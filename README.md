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
`.agents`, which hold the tracked `.claude/skills` symlink) are excluded; any other
symlink stops the build. It runs Windows
build tools there, returns logs and packages to
`.artifacts/windows-build/<build-id>/`, then deletes that invocation's Windows
temporary directory on success or failure. Cancellation stops that build's
process tree before cleanup. If it cannot confirm the process stopped, it
reports and preserves the directory for recovery rather than deleting active
inputs. Build IDs are UTC identifiers, not displayed appointment times.

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

## Local windows-dev VM (when this PC has no Windows build tools)

`vm/compose.yml` runs a Windows 11 guest (`dockurr/windows`, pinned) under WSL's nested KVM. It starts on demand and should be stopped after builds so its memory returns to WSL. Its ports bind to loopback only: web console `http://127.0.0.1:8006`, RDP `127.0.0.1:3389` and SSH `127.0.0.1:2229` (key-only, alias `windows-dev` in `~/.ssh/config`). The disk lives in `~/.local/share/windows-dev/storage`; the guest's local account password is in `~/.secrets/windows-build-tools/windows-dev/vm.env`, outside version control. Windows is installed unactivated, which is enough for building.

Before the first `up`, write the guest's SSH key list from your own public key. It is git-ignored, and the comment field (user@host) is dropped so nothing personal is copied into the guest:

```bash
cut -d' ' -f1,2 ~/.ssh/id_ed25519.pub > /development/windows-build-tools/vm/oem/administrators_authorized_keys
```

The unattended install copies it into the guest once; `vm/oem/administrators_authorized_keys.example` shows the format.

```bash
docker compose -f /development/windows-build-tools/vm/compose.yml up -d
npm run verify:desktop
docker compose -f /development/windows-build-tools/vm/compose.yml stop
```

When `pwsh.exe` is not on the WSL path and the `windows-dev` container is running (or `WINDOWS_BUILD_VM` names an SSH destination explicitly), `vm_transport.py` snapshots the source here, streams it into the guest user's `%TEMP%\WindowsAppBuilds`, runs the same `build-staged.ps1`, copies logs and artifacts back to `.artifacts/windows-build/<build-id>/`, then removes the guest stage. The guest toolchain (PowerShell 7, the .NET SDK band from `global.json`, Visual Studio Build Tools with the C++ workload, ARM64 tools and the Windows SDK) is installed by the re-runnable `vm/guest-toolchain.ps1`; see its header for the two commands. It supports `--build-only` and `--no-sign` only: signed builds and installs would need the private dev signing key inside the guest, which is not authorized. The guest is a 4 GiB VM under a 5 GiB hard container cap, sized for WSL's shared memory; raise both together only after WSL's own limit is increased.

## Windows 10 22H2 test VM

`vm/compose.win10.yml` runs a Windows 10 Pro 22H2 guest (build 19045, the family's minimum, D-018) for installing and exercising apps there before a release (TEST-9). It is a test machine, not a build host: build on the host or the Windows 11 VM, then install the package in this one. It uses the same pinned image, guest password and SSH key list as `windows-dev`, with its own disk in `~/.local/share/windows10-test/storage` and loopback ports beside the build VM's: web console `http://127.0.0.1:8007`, RDP `127.0.0.1:3390` and SSH `127.0.0.1:2230`.

```bash
docker compose -f vm/compose.win10.yml up -d
docker compose -f vm/compose.win10.yml stop
```

The guest gets 3 GB under a 3.5 GB container cap, so check `free -m` first and leave the usual safety margin. Never run it alongside `windows-dev` or the Android VM. The first start downloads Windows 10 from Microsoft and installs it unattended, which takes a while; later starts boot the existing disk. Windows is installed unactivated, which is enough for testing.

## Exercising and capturing an app in a test VM

`vm/app-test/` installs a dev-signed package in `windows10-test` or `windows-dev` and drives and screenshots it there, so UI checks (light, dark, high contrast, narrow widths) never use the Windows host's own desktop. Install in a guest whose Windows meets the app's `MinVersion`: the Windows 10 VM refuses Windows 11-only packages with 0x80073CFD.

| File | Runs | Does |
|---|---|---|
| `app-test.sh` | Host, sourced | `app_test_use win10\|win11`, `app_test_lock` and `app_test_unlock` for `windows-dev`, then `app_test_put`, `app_test_ps` (over SSH), `app_test_ui` (in the desktop session), `app_test_get` and `app_test_screendump` (whole screen through the QEMU monitor, no session needed) |
| `install-package.ps1` | Guest, over SSH | Trusts the signer's public certificate taken from the package's own signature, then installs or updates it; `-Untrust` removes that certificate |
| `run-interactive.ps1` | Guest, over SSH | Runs a script in the signed-in desktop session through a one-off interactive scheduled task, waits, prints its transcript and removes the task |
| `ui-lib.ps1` | Guest, dot-sourced by a UI script | UI Automation lookups, clicks, combo box choices, window resizing, region screenshots into `C:\apptest\out`, and high contrast on or off for the session (not persisted) |

```bash
source vm/app-test/app-test.sh
app_test_use win11
for f in vm/app-test/*.ps1 drive.ps1 App-1.2.3.4-x64.msix; do app_test_put "$f"; done
app_test_ps 'C:\apptest\install-package.ps1' -Msix 'C:\apptest\App-1.2.3.4-x64.msix'
app_test_ui 'C:\apptest\drive.ps1'
app_test_get 'out/*.png' ./shots/
```

Both guests sign in automatically, which `run-interactive.ps1` needs: SSH sessions run outside the desktop, so UI Automation, screenshots and theme changes made over SSH do not reach the screen. Add-AppxPackage over SSH fails with "Access is denied ... reading the console output buffer" unless progress output is off, which `install-package.ps1` does. On `windows-dev`, the shared build VM, hold its build lock for the whole session (`app_test_lock`, then `app_test_unlock`), and afterwards uninstall the test packages and run `install-package.ps1 -Untrust` (also after a failed install, since the certificate is trusted first), so builds never run against a half-configured guest. The lock outlives the shell that took it: it is held until `app_test_unlock`, from any shell, or until `APP_TEST_LOCK_MINUTES` (default 60) pass, and the lock note shows when it expires. `windows10-test` is disposable and keeps the certificate. Narrator and other assistive technology cannot be judged this way; check them by hand.

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
publisher. Package data stays with the same family; no uninstall is performed. Store
updates resume when a higher version becomes available. This is local testing, not a
Store submission. Other projects and default dev builds keep their existing identities.
`--skip-build` selects only packages built for the requested identity mode.

Store-distributed bundles must be updated with signed `.msixbundle` files, not standalone
MSIX packages. The bridge supports both formats and validates bundle identity against its
application package before installing. ImmichDrive packages its Store-identity test builds
as bundles with an explicit version.
