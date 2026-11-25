"""Run a bridge build inside the windows-dev VM over key-only SSH.

The VM has no view of the WSL checkout, so this transport snapshots the source on
the Linux side, streams it into the VM user's TEMP/WindowsAppBuilds, runs the same
build-staged.ps1 there, copies logs and artifacts back, and removes the VM stage.

Only unsigned work is supported (compile-only and --no-sign packaging). Signed
builds and installation would need the private dev signing key inside the VM and
a signed-in desktop session; both stay out of scope until explicitly authorized.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

import staged_packages

SSH_OPTIONS = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
RETURNED_FILES = ('build.log', 'console.log', 'result.json')


DEFAULT_VM = 'windows-dev'
# Where windows-dev normally runs: the home server's Docker, reached over SSH (vm/remote.sh). The
# local Docker is the fallback, and is checked first so a local VM always wins.
REMOTE_DOCKER_HOST = os.environ.get('WINDOWS_VM_DOCKER_HOST', 'ssh://home')


def _container_running(docker_host):
    """True when windows-dev is up in the given Docker (None: this machine's own).

    Any Docker or SSH failure, or no answer within 10 seconds, counts as not running.
    """
    env = dict(os.environ)
    if docker_host:
        env['DOCKER_HOST'] = docker_host
    try:
        state = subprocess.run(['docker', 'inspect', '-f', '{{.State.Running}}', DEFAULT_VM],
                               capture_output=True, text=True, timeout=10, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return state.returncode == 0 and state.stdout.strip() == 'true'


def _vm_running():
    """True when the windows-dev container is up locally or on the home server.

    The remote VM is reached through vm/remote.sh's SSH tunnel on the same loopback port as the
    local one, so the SSH destination is the same either way.
    """
    return _container_running(None) or _container_running(REMOTE_DOCKER_HOST)


def vm_host():
    """Return the SSH destination for the VM, or None when the VM transport does not apply.

    WINDOWS_BUILD_VM selects a destination explicitly. Otherwise a running windows-dev
    container is used automatically, so projects need no extra setting. The VM is never
    started here: starting it reserves memory and is the caller's decision.
    """
    explicit = os.environ.get('WINDOWS_BUILD_VM')
    if explicit:
        return explicit
    return DEFAULT_VM if _vm_running() else None


def forced_vm_host(requested):
    """Return the VM's SSH destination when the caller forced the VM transport, else None.

    requested: the bridge's --vm flag. Setting WINDOWS_BUILD_VM forces it too, even on a machine
    with host build tools (pwsh.exe on the WSL path): a destination that was named but silently
    ignored would build somewhere the caller did not ask for. --vm without WINDOWS_BUILD_VM needs
    the windows-dev container running, and raises a RuntimeError saying how to start it.
    """
    host = vm_host()
    if os.environ.get('WINDOWS_BUILD_VM'):
        return host
    if not requested:
        return None
    if host is None:
        raise RuntimeError('--vm needs the windows-dev VM running (/development/windows-build-tools/vm/remote.sh up) '
                           'or WINDOWS_BUILD_VM naming an SSH destination')
    return host


def _ssh(host, command, **kwargs):
    """Run one command in the VM. Windows OpenSSH hands it to cmd.exe."""
    return subprocess.run(['ssh', *SSH_OPTIONS, host, command], **kwargs)


def _pwsh(host, script, **kwargs):
    """Run a short PowerShell 7 snippet in the VM and return the completed process."""
    return _ssh(host, f'pwsh -NoProfile -NonInteractive -Command "{script}"', **kwargs)


def _guest_platform(host):
    """Return the guest's --platform value from its OS architecture.

    OSArchitecture reports the real Windows architecture even when pwsh itself runs
    emulated, unlike PROCESSOR_ARCHITECTURE, which reports the emulated one.
    """
    import host_platform
    architecture = _pwsh(host, '[Runtime.InteropServices.RuntimeInformation]::OSArchitecture',
                         capture_output=True, text=True, check=True).stdout
    return host_platform.platform_for(architecture)


def _remote_stage(host, repo_name):
    """Choose a unique stage under the VM user's TEMP, as build-staged.ps1 requires."""
    temp = _pwsh(host, '[IO.Path]::GetTempPath()', capture_output=True, text=True, check=True).stdout.strip()
    if not temp.lower().startswith('c:\\'):
        raise RuntimeError('VM TEMP must be on C:; refusing a different staging drive')
    return temp.rstrip('\\') + '\\WindowsAppBuilds\\' + repo_name + '-' + uuid.uuid4().hex[:12]


def _upload(host, local_stage, remote_stage):
    """Stream the prepared local stage into the VM with tar (bsdtar ships with Windows)."""
    _pwsh(host, f"New-Item -ItemType Directory -Force -Path '{remote_stage}' | Out-Null", check=True)
    with tempfile.TemporaryFile() as archive:
        with tarfile.open(fileobj=archive, mode='w') as tar:
            tar.add(local_stage, arcname='.')
        archive.seek(0)
        subprocess.run(['ssh', *SSH_OPTIONS, host, f'tar -xf - -C "{remote_stage}"'],
                       stdin=archive, check=True)


# The named deliverables a LAYOUT-12 packaging script writes in the staged source. They arrive in
# the build's output folder first, and run() merges them into the repository from there.
STAGED_PACKAGES = 'source/.artifacts/packages'


def _download(host, remote_stage, output):
    """Copy back whichever logs, result, artifacts and named packages exist; a failed build has fewer."""
    candidates = ', '.join(f"'{name}'" for name in (*RETURNED_FILES, 'artifacts', STAGED_PACKAGES))
    listing = _pwsh(host, f"Set-Location '{remote_stage}'; @({candidates}) | Where-Object {{ Test-Path $_ }}",
                    capture_output=True, text=True)
    names = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    if not names:
        return
    with tempfile.TemporaryFile() as archive:
        subprocess.run(['ssh', *SSH_OPTIONS, host, f'tar -cf - -C "{remote_stage}" ' + ' '.join(names)],
                       stdout=archive, check=False)
        archive.seek(0)
        with tarfile.open(fileobj=archive, mode='r') as tar:
            tar.extractall(output, filter='data')


def _merge_packages(output, repo, succeeded):
    """Merge the downloaded named packages into the repository, then drop the downloaded copy.

    Only a build that succeeded contributes, so a failed run never replaces a good package of the
    same name. The copy under output/source is removed either way: the build's output folder holds
    logs and artifacts, not a partial source tree.
    """
    staged_source = output / 'source'
    try:
        if succeeded:
            for package in staged_packages.merge_staged_packages(staged_source, repo):
                print(f'Package copy: {package}', flush=True)
    finally:
        shutil.rmtree(staged_source, ignore_errors=True)


def _stop_remote_tree(host, remote_stage):
    """Stop this build's Windows process tree using the PID build-staged.ps1 recorded."""
    result = _pwsh(host, f"$p = Get-Content -LiteralPath '{remote_stage}\\windows.pid' -ErrorAction Stop; "
                         "taskkill.exe /PID $p /T /F | Out-Null; exit $LASTEXITCODE",
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def run(args, repo, config, snapshot_source, scripts_dir):
    """Build in the VM and return the build's exit code.

    args: parsed bridge arguments; repo: resolved WSL checkout; config: validated
    windows-build.json; snapshot_source: the bridge's source copier; scripts_dir:
    directory holding build-staged.ps1 and install-staged.ps1.
    """
    host = vm_host()
    if args.install or args.dev or args.skip_build or not (args.build_only or args.no_sign):
        raise RuntimeError('The windows-dev VM transport supports only --build-only and --no-sign builds; '
                           'signed builds and installs need the dev signing key in the VM, which is not authorized')

    # Queue behind other runs on this VM only; local Windows builds use their own lock.
    import build_lock
    held_lock = build_lock.acquire(f'vm-{host}', repo, no_wait=args.no_wait)  # noqa: F841 (kept open until return)

    if args.platform is None:
        args.platform = _guest_platform(host)
        print(f'Platform: {args.platform} ({host}; pass --platform to override)', flush=True)

    build_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    output = repo / '.artifacts' / 'windows-build' / build_id
    output.mkdir(parents=True)
    remote_stage = _remote_stage(host, repo.name)
    code = 1
    cleanup_allowed = True
    process = None

    try:
        # Phase 1: prepare the same stage layout the local transport uses.
        with tempfile.TemporaryDirectory(prefix=repo.name + '-vm-') as directory:
            local_stage = Path(directory)
            source_directory = config.get('source_directory', '.')
            snapshot_source(repo / source_directory, local_stage / 'source' / source_directory)
            for name in ('build-staged.ps1', 'install-staged.ps1'):
                (local_stage / name).write_bytes((scripts_dir / name).read_bytes())
            request = dict(config, platform=args.platform, configuration=args.configuration,
                           build_only=args.build_only, no_sign=args.no_sign, dev=False, install=False,
                           skip_build=False, dry_run=False, no_launch=False, store_identity_mode=False)
            # Unsigned builds never open the key, so its password stays on this side.
            request.pop('certificate_password', None)
            (local_stage / 'request.json').write_text(json.dumps(request), encoding='ascii')
            print(f'Staging {repo.name} in {host}:{remote_stage}', flush=True)
            _upload(host, local_stage, remote_stage)

        # Phase 2: run the shared build script, teeing output into console.log.
        with (output / 'console.log').open('wb') as console:
            process = subprocess.Popen(
                ['ssh', *SSH_OPTIONS, host,
                 f'pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{remote_stage}\\build-staged.ps1" -Stage "{remote_stage}"'],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            for line in process.stdout:
                console.write(line)
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            code = process.wait()
    except BaseException:
        # Interrupted: stop only this build's VM process tree before removing inputs.
        if process is not None and process.poll() is None:
            process.terminate()
            cleanup_allowed = _stop_remote_tree(host, remote_stage)
        raise
    finally:
        # Phase 3: return results, then remove the VM stage unless a build may still run.
        try:
            _download(host, remote_stage, output)
            _merge_packages(output, repo, succeeded=code == 0)
        finally:
            if cleanup_allowed:
                _pwsh(host, f"Remove-Item -LiteralPath '{remote_stage}' -Recurse -Force", check=False)
            else:
                print(f'Build may still be running; VM stage preserved: {remote_stage}', file=sys.stderr)
            print(f'Results: {output}', flush=True)
    return code
