# Windows desktop development from WSL

Run these commands from the repository root in Ubuntu WSL:

| Command | Result |
| --- | --- |
| `npm run build:desktop` | Signed ARM64 Release dev MSIX |
| `npm run verify:desktop` | Full Windows Debug compile, including XAML |
| `npm run install:desktop` | Build, update in place, then launch |
| `npm run install:desktop -- --skip-build` | Reinstall the latest successful dev MSIX for the selected platform |
| `npm run install:desktop -- --skip-build --dry-run` | Validate the install without changing Windows |
| `npm run install:desktop -- --no-launch` | Build and install without launching |
| `npm run package:desktop` | Unsigned Release MSIX with Store identity |

A library with no MSIX project can use `--build-only` with a `windows-build.json`
that names only `project`; packaging and signing keys are required only by the
modes that use them.

Pass `-- --platform x64` to build for x64. Packaging defaults to Release;
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
