#!/usr/bin/env python3
"""Build a WSL working tree in a fresh Windows TEMP directory using host tools."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

import build_lock
import host_platform
import stage_cleanup
import staged_packages
import vm_transport

EXCLUDED_DIRECTORIES = {
    '.git', '.vs', '.crashdiag', 'bin', 'obj', 'node_modules',
    '__pycache__', '.artifacts', 'layout', 'artifacts',
    # Agent instructions and skills are never build inputs. Skipping them also keeps the tracked
    # .claude/skills -> ../.agents/skills symlink (AI-8) out of the symlink check below, in the repo
    # and in any submodule (such as a kit) that carries one. The working tree keeps both folders.
    '.claude', '.agents',
    # Git worktrees live inside each checkout (D-032). Each is a whole second working tree, often of
    # another branch, so staging it would copy that branch's source into this build.
    '.worktrees',
}


def windows_path(path):
    """Translate an existing mounted Windows path for a Windows process."""
    return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()


def snapshot_source(repo, target):
    """Copy current source and local build inputs, excluding Git and generated output.

    Local secrets, signing certificates, and submodule working-tree files are included.
    External symlinks are rejected rather than silently copying unrelated files.
    """
    for directory, directories, files in os.walk(repo):
        directories[:] = [name for name in directories if name.lower() not in EXCLUDED_DIRECTORIES]
        relative = Path(directory).relative_to(repo)
        destination = target / relative
        destination.mkdir(parents=True, exist_ok=True)
        for name in directories + files:
            source = Path(directory) / name
            if source.is_symlink():
                raise RuntimeError(f'Source symlinks need an explicit staging policy: {source}')
        for name in files:
            if name.lower() in EXCLUDED_DIRECTORIES:
                continue
            source = Path(directory) / name
            before = source.stat()
            shutil.copy2(source, destination / name)
            after = source.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise RuntimeError(f'Source changed while being staged; retry: {source}')


SHARED_DEV_PASSWORD_FILE = Path.home() / '.secrets' / 'windows-build-tools' / 'signing' / 'windows-apps-dev.password'


def read_shared_dev_password():
    """Return the shared dev signing key's password from its private file (SEC-11).

    The password is never written in source. Raises FileNotFoundError naming the expected
    file, without echoing any value, when it is missing or empty.
    """
    try:
        password = SHARED_DEV_PASSWORD_FILE.read_text(encoding='utf-8').strip()
    except FileNotFoundError:
        password = ''
    if not password:
        raise FileNotFoundError(
            f'Shared dev signing password missing: create {SHARED_DEV_PASSWORD_FILE} '
            '(mode 600, in a mode 700 directory) holding the password of signing/windows-apps-dev.pfx')
    return password


def read_config(repo, build_only=False):
    """Validate the repository's small build manifest before passing it to Windows.

    A compile-only build needs only "project", so a library with no MSIX packaging project
    can use --build-only. Every other mode also needs "package_script".
    """
    config = json.loads((repo / 'windows-build.json').read_text())
    for key in ('project', 'package_script', 'package_output', 'certificate', 'source_directory', 'version_file', 'prepare_script'):
        if key not in config:
            continue
        value = Path(config[key])
        if value.is_absolute() or '..' in value.parts or '\\' in str(value) or ':' in str(value):
            raise ValueError(f'{key} must be a relative repository path')
    required = ('project',) if build_only else ('project', 'package_script')
    for key in required:
        if key not in config:
            raise ValueError(f'windows-build.json needs "{key}" for this build mode')
        if not (repo / config[key]).is_file():
            raise FileNotFoundError(config[key])
    return config



def parse_arguments():
    """Validate mutually exclusive build and install modes before any mutation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path)
    # No fixed default: the build host's own architecture is used unless this overrides it.
    parser.add_argument('--platform', choices=('ARM64', 'x64'), default=None,
                        help="Target platform; defaults to the Windows build host's architecture")
    parser.add_argument('--configuration', choices=('Debug', 'Release'), default='Release')
    parser.add_argument('--build-only', action='store_true', help='Compile without MSIX packaging')
    parser.add_argument('--no-sign', action='store_true', help='Build an unsigned Store-identity MSIX')
    parser.add_argument('--dev', action='store_true', help='Assign a staging-only version for repeated dev installs')
    parser.add_argument('--store-identity', action='store_true', help='Sign a test package using the configured Store identity')
    parser.add_argument('--install', action='store_true', help='Build, update in place, and launch on Windows')
    parser.add_argument('--skip-build', action='store_true', help='Install the most recent successful dev package')
    parser.add_argument('--dry-run', action='store_true', help='Validate installation without changing Windows')
    parser.add_argument('--no-launch', action='store_true', help='Install without starting the app')
    parser.add_argument('--vm', action='store_true',
                        help='Build in the windows-dev VM even when this machine has host build tools '
                             '(WINDOWS_BUILD_VM does the same); --build-only and --no-sign only')
    parser.add_argument('--no-wait', action='store_true',
                        help='Fail at once instead of queueing behind another run on the same Windows host')
    args = parser.parse_args()
    if args.skip_build and not args.install:
        parser.error('--skip-build requires --install')
    if args.install and (args.no_sign or args.build_only):
        parser.error('installation requires a signed MSIX')
    if args.dev and (args.no_sign or args.build_only):
        parser.error('--dev requires a signed MSIX')
    if (args.dry_run or args.no_launch) and not args.install:
        parser.error('--dry-run and --no-launch require --install')
    if args.build_only and args.no_sign:
        parser.error('--no-sign applies only to MSIX packaging')
    if args.store_identity and (args.no_sign or args.build_only or not (args.dev or args.install)):
        parser.error('--store-identity requires a signed dev build or install')
    return args


def delegate_container():
    """Run against the exact host WSL bind-mounted checkout over Windows SSH.

    This transport does not copy a separate container clone. Its environment
    must identify the WSL checkout mounted into the container and existing SSH host.
    """
    # Containers share the host WSL checkout through a bind mount. Delegate
    # to that exact checkout over the existing Windows SSH host, never D:.
    host = os.environ.get('WINDOWS_BUILD_HOST')
    host_repo = os.environ.get('WINDOWS_BUILD_REPO')
    host_tools = os.environ.get('WINDOWS_BUILD_HOST_TOOLS', '/development/windows-build-tools')
    if not host or not host_repo:
        raise FileNotFoundError('Run from WSL with Windows PowerShell 7, set WINDOWS_BUILD_VM=windows-dev for the local VM, '
                                'or configure WINDOWS_BUILD_HOST and WINDOWS_BUILD_REPO for a container')
    remote_args = ['wsl.exe', '-d', 'Ubuntu', '--exec', 'python3',
                   host_tools + '/windows-build.py', '--repo', host_repo]
    remote_args += sys.argv[1:]
    # Drop this container's --repo pair; the Windows host must use its WSL path.
    repo_index = remote_args.index('--repo', 8)
    del remote_args[repo_index:repo_index + 2]
    for value in remote_args:
        if any(character in value for character in '\"\r\n&|<>^%'):
            raise ValueError('Remote Windows command contains unsupported shell characters')
    command = ' '.join('"' + value + '"' for value in remote_args)
    return subprocess.call(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host, command])


INTEROP_TIMEOUT_MARKERS = ('UtilAcceptVsock', 'accept4 failed 110')


def windows_temp_path(powershell):
    """Return the Windows user's TEMP path, from the run's first pwsh.exe interop call.

    The first interop call after a quiet spell sometimes times out inside WSL with
    "UtilAcceptVsock ... accept4 failed 110" while later calls succeed, so exactly
    that failure is retried once and the retry is reported. Any other failure, or a
    second timeout, raises CalledProcessError with Windows' own error output.
    """
    command = [powershell, '-NoProfile', '-NonInteractive', '-Command', '[System.IO.Path]::GetTempPath()']
    for attempt in (1, 2):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
        timed_out = all(marker in result.stderr for marker in INTEROP_TIMEOUT_MARKERS)
        if attempt == 1 and timed_out:
            print('Windows interop timed out on the first call (UtilAcceptVsock accept4 110); retrying once',
                  flush=True)
            continue
        sys.stderr.write(result.stderr)
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)


def latest_dev_package(repo, platform, store_identity=False):
    """Find the newest successful dev artifact for this platform, excluding failures."""
    candidates = sorted((repo / '.artifacts/windows-build').glob('*/result.json'), reverse=True)
    for path in candidates:
        result = json.loads(path.read_text(encoding='utf-8-sig'))
        if (result.get('success') and result.get('dev') and result.get('platform') == platform
                and bool(result.get('store_identity', False)) == store_identity):
            return path.parent
    raise FileNotFoundError('No successful dev package for this platform; run npm run build:desktop first')

def main():
    """Stage, invoke Windows, return artifacts/logs, and clean only this build's TEMP.

    Installation is opt-in. Dev version changes affect the disposable snapshot only.
    Failed stages are cleaned too; their logs and result are copied back first.
    """
    args = parse_arguments()
    repo = args.repo.resolve()
    config = read_config(repo, build_only=args.build_only)
    if args.store_identity:
        for key in ('store_identity', 'store_publisher', 'store_identity_switch'):
            if not config.get(key):
                raise ValueError(f'--store-identity requires configured {key}')
        config['dev_identity'] = config['store_identity']
    if config.get('signing') == 'shared-dev':
        certificate_source = Path(__file__).with_name('signing') / 'windows-apps-dev.pfx'
    else:
        # Optional: only signed builds read it, and compile-only repos need not name one.
        certificate_source = repo / config['certificate'] if 'certificate' in config else None
    # An explicit request for the VM (--vm or WINDOWS_BUILD_VM) wins over host build tools.
    if vm_transport.forced_vm_host(args.vm):
        return vm_transport.run(args, repo, config, snapshot_source, Path(__file__).parent)
    # Match the projects' GitHub Actions pwsh runtime. PowerShell 5.1's ANSI
    # defaults corrupt UTF-8 scripts and manifests even when source bytes match.
    powershell = shutil.which('pwsh.exe')
    if powershell is None:
        # No host PowerShell 7: build in a running windows-dev VM, otherwise fall back to the
        # container-to-host SSH delegation.
        if vm_transport.vm_host():
            return vm_transport.run(args, repo, config, snapshot_source, Path(__file__).parent)
        return delegate_container()
    if (not args.skip_build and not args.build_only and not args.no_sign
            and (certificate_source is None or not certificate_source.is_file())):
        raise FileNotFoundError('Existing dev signing certificate missing; create it deliberately before a signed build')
    if args.platform is None:
        args.platform = host_platform.local_platform()
        print(f'Platform: {args.platform} (this Windows host; pass --platform to override)', flush=True)
    # Read the password only here, on the local Windows path: container delegation re-runs this
    # script on the WSL host, which owns ~/.secrets, and the VM transport never signs. Only a
    # fresh signed build opens the key, so compile-only, unsigned and --skip-build runs skip it.
    if config.get('signing') == 'shared-dev' and not (args.build_only or args.no_sign or args.skip_build):
        config['certificate_password'] = read_shared_dev_password()

    # One build at a time per Windows host, across all sessions. Held until this process
    # exits; validation above runs first so a bad request fails without queueing.
    held_lock = build_lock.acquire('local', repo, no_wait=args.no_wait)  # noqa: F841 (kept open until exit)

    temp_windows = windows_temp_path(powershell)
    temp_linux = Path(subprocess.check_output(['wslpath', '-u', temp_windows], text=True).strip())
    if not temp_windows.lower().startswith('c:\\'):
        raise RuntimeError('Windows TEMP must be on C:; refusing a different staging drive')
    stage_parent = temp_linux / 'WindowsAppBuilds'
    stage_parent.mkdir(exist_ok=True)
    # Stages a failed cleanup left behind (see stage_cleanup.py) go once they are a day old.
    for old_stage in stage_cleanup.prune_old_stages(stage_parent):
        print(f'Removed old build stage: {old_stage}', flush=True)
    stage = Path(tempfile.mkdtemp(prefix=repo.name + '-', dir=stage_parent))
    build_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    output = repo / '.artifacts' / 'windows-build' / build_id
    output.mkdir(parents=True)
    code = 1
    process = None
    cleanup_allowed = True
    try:
        print(f'Staging {repo.name} in {windows_path(stage)}', flush=True)
        (stage / 'source').mkdir()
        if args.skip_build:
            previous = latest_dev_package(repo, args.platform, args.store_identity)
            shutil.copytree(previous / 'artifacts', stage / 'artifacts')
        else:
            source_directory = config.get('source_directory', '.')
            snapshot_source(repo / source_directory, stage / 'source' / source_directory)
            if not args.build_only and not args.no_sign:
                staged_certificate = stage / 'source' / config['certificate']
                staged_certificate.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(certificate_source, staged_certificate)
        shutil.copy2(Path(__file__).with_name('build-staged.ps1'), stage / 'build-staged.ps1')
        shutil.copy2(Path(__file__).with_name('install-staged.ps1'), stage / 'install-staged.ps1')
        request = dict(config, platform=args.platform, configuration=args.configuration,
                       build_only=args.build_only, no_sign=args.no_sign, dev=args.dev or args.install,
                       install=args.install, skip_build=args.skip_build, dry_run=args.dry_run, no_launch=args.no_launch,
                       store_identity_mode=args.store_identity)
        (stage / 'request.json').write_text(json.dumps(request), encoding='ascii')
        # Tee child output into a file too: Windows transcripts do not consistently
        # capture every native compiler's stdout/stderr when invoked through WSL.
        with (stage / 'console.log').open('wb') as console:
            process = subprocess.Popen([
                powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', windows_path(stage / 'build-staged.ps1'), '-Stage', windows_path(stage)
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            for line in process.stdout:
                console.write(line)
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            code = process.wait()
    except BaseException:
        # Cancel only this stage's Windows process tree before deleting its inputs.
        # A WSL process ID is not the Windows PID, so the driver records its own PID.
        if process is not None and process.poll() is None:
            pid_file = stage / 'windows.pid'
            if pid_file.exists():
                windows_pid = int(pid_file.read_text(encoding='utf-8-sig').strip())
                stopped = subprocess.run(['taskkill.exe', '/PID', str(windows_pid), '/T', '/F'],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if stopped.returncode != 0:
                    cleanup_allowed = False
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                cleanup_allowed = False
        raise
    finally:
        # Keep logs even after a failed build. Private keys remain source inputs and
        # are never exported as artifacts. Result paths use UTC only as identifiers.
        try:
            for name in ('build.log', 'console.log', 'result.json', 'install-result.json'):
                if (stage / name).exists():
                    shutil.copy2(stage / name, output / name)
            if (stage / 'artifacts').exists():
                shutil.copytree(stage / 'artifacts', output / 'artifacts')
            # Named deliverables (LAYOUT-12) only from a build that succeeded, so a failed run
            # never replaces a good package of the same name.
            if code == 0:
                for package in staged_packages.merge_staged_packages(stage / 'source', repo):
                    print(f'Package copy: {package}', flush=True)
        finally:
            resolved = stage.resolve()
            if resolved.parent != stage_parent.resolve() or not resolved.name.startswith(repo.name + '-'):
                raise RuntimeError(f'Refusing to clean an unexpected staging path: {resolved}')
            if (stage / 'cleanup-blocked').exists() or (stage / 'interactive-task.txt').exists():
                # A scheduled task is outside the driver's process tree. Keep its
                # inputs if interruption prevented confirming that it completed.
                cleanup_allowed = False
            if cleanup_allowed:
                # A stage that cannot be deleted is reported, never turned into a build failure:
                # the exit code stays the build's own.
                stage_cleanup.remove_stage(stage)
            else:
                print(f'Build still running; stage preserved for recovery: {windows_path(stage)}', file=sys.stderr)
            print(f'Results: {output}', flush=True)
            for package in (output / 'artifacts').glob('*.msix*'):
                print(f'Windows package path: {windows_path(package)}', flush=True)
    return code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Windows build canceled.', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print(f'Windows build failed: {error}', file=sys.stderr)
        sys.exit(1)
