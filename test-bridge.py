"""Exercise real WSL/Windows staging, source fidelity, failure reporting, and isolation.

Packaging is a tiny fixture, not an app build. Full app MSIX builds are verified
separately. No fixture touches certificate stores or installed packages.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import zipfile
from unittest import mock
import shutil
import signal

import build_lock
import host_platform

BRIDGE = Path(__file__).with_name('windows-build.py')


class HostPlatformTests(unittest.TestCase):
    """Map the architecture names uname and .NET report to --platform values."""

    def test_known_architectures(self):
        for name, expected in (('x86_64', 'x64'), ('AMD64', 'x64'), ('X64', 'x64'),
                               ('aarch64', 'ARM64'), ('Arm64', 'ARM64'), ('Arm64\r\n', 'ARM64')):
            self.assertEqual(host_platform.platform_for(name), expected, name)

    def test_unsupported_architecture_asks_for_an_explicit_platform(self):
        with self.assertRaisesRegex(ValueError, '--platform'):
            host_platform.platform_for('X86')
PACKAGE_FIXTURE = '''param([string]$Platform, [string]$Configuration, [switch]$NoSign)
$ErrorActionPreference = 'Stop'
# Exercise a non-ASCII UTF-8 script under the Windows packaging runtime.
$unicodeText = 'caf\u00e9'
if ($unicodeText.Length -ne 4) { throw 'UTF-8 script was decoded as ANSI' }
$root = Split-Path $PSScriptRoot -Parent
if (Test-Path (Join-Path $root '.git')) { throw 'Root Git metadata was staged' }
if (Test-Path (Join-Path $root 'external/promo/.git')) { throw 'Submodule gitfile was staged' }
if (Test-Path (Join-Path $root 'App/bin/stale.txt')) { throw 'Old build output was staged' }
foreach ($inputPath in @('App/changed.txt', 'external/promo/uncommitted.txt', 'local.secrets.props', 'AppMSIX/App.pfx')) {
    if ((Get-Content -LiteralPath (Join-Path $root $inputPath) -Raw) -ne 'working-tree') { throw "Missing current input: $inputPath" }
}
if (Test-Path (Join-Path $root 'fail')) { exit 9 }
if (Test-Path (Join-Path $root 'delay')) { Start-Sleep -Seconds 60 }
$output = Join-Path $PSScriptRoot 'bin/msix-output'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Set-Content -LiteralPath (Join-Path $output 'fixture.msix') -Value 'fixture only'
'''


class AppTestLockTests(unittest.TestCase):
    """app_test_lock in vm/app-test/app-test.sh shares the VM build lock across shells."""

    APP_TEST = BRIDGE.parent / 'vm/app-test/app-test.sh'

    def app_test(self, cache, command):
        """Run one app-test helper in its own bash, as an agent's separate tool call would."""
        return subprocess.run(['bash', '-c', f'source "{self.APP_TEST}"; {command}'],
                              env=dict(os.environ, XDG_CACHE_HOME=cache, APP_TEST_LOCK_MINUTES='2'),
                              capture_output=True, text=True, timeout=60)

    def assert_vm_lock_held(self, cache, held):
        with mock.patch.dict(os.environ, XDG_CACHE_HOME=cache):
            try:
                build_lock.acquire('vm-windows-dev', 'probe', no_wait=True).close()
                is_held = False
            except build_lock.BuildLockBusy:
                is_held = True
        self.assertEqual(is_held, held)

    def test_lock_outlives_its_shell_and_unlocks_from_another(self):
        with tempfile.TemporaryDirectory(prefix='app-test-lock-') as cache:
            locked = self.app_test(cache, 'app_test_lock')
            try:
                self.assertEqual(locked.returncode, 0, locked.stderr)
                self.assertIn('holding the vm-windows-dev build lock', locked.stdout)
                self.assert_vm_lock_held(cache, True)
            finally:
                unlocked = self.app_test(cache, 'app_test_unlock')
            self.assertIn('released', unlocked.stdout)
            self.assert_vm_lock_held(cache, False)

    def test_unlock_never_touches_a_real_builds_lock(self):
        with tempfile.TemporaryDirectory(prefix='app-test-lock-') as cache:
            with mock.patch.dict(os.environ, XDG_CACHE_HOME=cache):
                held = build_lock.acquire('vm-windows-dev', '/development/some-app')
            with held:
                result = self.app_test(cache, 'app_test_unlock')
                self.assertIn('no app-test holder', result.stdout)
                self.assert_vm_lock_held(cache, True)


class AppTestPackageTests(unittest.TestCase):
    """install-package.ps1 and remove-packages.ps1 against fake package cmdlets, in the host's pwsh.exe.

    Functions take precedence over cmdlets, so no real package is installed or removed.
    """

    APP_TEST_DIR = BRIDGE.parent / 'vm/app-test'
    PUBLISHER = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    FAKES = r"""
$global:Fake = [System.Collections.ArrayList]@()
function New-Fake($Full, $Deps = @()) {
    $parts = $Full.Split('_')
    $global:Fake.Add([pscustomobject]@{
        PackageFullName = $Full; Name = $parts[0]; Version = $parts[1]; Architecture = $parts[2]
        PackageFamilyName = "$($parts[0])_$($parts[4])"; Publisher = $global:Publisher
        Dependencies = @($Deps | ForEach-Object { [pscustomobject]@{ PackageFullName = $_ } })
    }) | Out-Null
}
function Get-AppxPackage { param($PackageTypeFilter) $global:Fake.ToArray() }
function Remove-AppxPackage {
    [CmdletBinding()] param([Parameter(Position = 0)] $Package)
    $global:Fake.Remove(($global:Fake | Where-Object PackageFullName -eq $Package | Select-Object -First 1))
}
$global:Offers = @{}
function Add-AppxPackage {
    [CmdletBinding()] param($Path, [switch]$ForceApplicationShutdown)
    New-Fake $global:Offers[(Split-Path $Path -Leaf)]
}
"""

    @staticmethod
    def windows(path):
        return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()

    def run_pwsh(self, script):
        """Run fakes plus script in pwsh.exe and return its stdout; fail the test on a nonzero exit."""
        if shutil.which('pwsh.exe') is None:
            self.skipTest('needs the Windows host pwsh.exe')
        # Bypass applies to this process only: scripts on the WSL share count as remote and unsigned.
        result = subprocess.run(['pwsh.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                 '-Command', f"$global:Publisher = '{self.PUBLISHER}'\n" + self.FAKES + script],
                                capture_output=True, text=True, timeout=120)
        output = result.stdout.replace('\r', '')
        self.assertEqual(result.returncode, 0, output + result.stderr)
        return output

    def write_msix(self, path, name, version):
        """A stand-in package: just the manifest identity install-package.ps1 reads."""
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('AppxManifest.xml', (
                '<?xml version="1.0" encoding="utf-8"?>'
                '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">'
                f'<Identity Name="{name}" Publisher="{self.PUBLISHER}" Version="{version}" '
                'ProcessorArchitecture="x64" /></Package>'))

    RUNTIME = {  # file in the NuGet cache: package name, as in Windows App Runtime 1.8
        'Microsoft.WindowsAppRuntime.1.8.msix': 'Microsoft.WindowsAppRuntime.1.8',
        'Microsoft.WindowsAppRuntime.DDLM.1.8.msix': 'Microsoft.WinAppRuntime.DDLM.8000.770.0.0-x6',
        'Microsoft.WindowsAppRuntime.Main.1.8.msix': 'MicrosoftCorporationII.WinAppRuntime.Main.1.8',
        'Microsoft.WindowsAppRuntime.Singleton.1.8.msix': 'MicrosoftCorporationII.WinAppRuntime.Singleton',
    }

    def install_runtime(self, directory, guest_packages):
        """Offer the 770 runtime to a guest holding guest_packages; return (output, recorded names)."""
        deps = Path(directory) / 'deps'
        deps.mkdir()
        record = Path(directory) / 'installed.txt'
        offers = []
        for file, name in self.RUNTIME.items():
            self.write_msix(deps / file, name, '8000.770.0.0')
            offers.append(f"$global:Offers['{file}'] = '{name}_8000.770.0.0_x64__8wekyb3d8bbwe'")
        guest = [f"New-Fake '{full}'" for full in guest_packages]
        output = self.run_pwsh('\n'.join(guest + offers) + f"""
& '{self.windows(self.APP_TEST_DIR / 'install-package.ps1')}' -Deps '{self.windows(deps)}' -Record '{self.windows(record)}'
""")
        recorded = [line.split('_')[0] for line in record.read_text().split()] if record.exists() else []
        return output, recorded

    def test_a_newer_guest_framework_keeps_back_the_whole_older_runtime(self):
        """Store-updated guests: nothing from the older release is installed or recorded."""
        with tempfile.TemporaryDirectory(prefix='install-package-') as directory:
            output, recorded = self.install_runtime(
                directory, ['Microsoft.WindowsAppRuntime.1.8_8000.994.0.0_x64__8wekyb3d8bbwe'])
            self.assertIn('kept installed 8000.994.0.0: Microsoft.WindowsAppRuntime.1.8 (offered 8000.770.0.0)', output)
            for file in ('DDLM', 'Main', 'Singleton'):
                self.assertIn(f'skipped Microsoft.WindowsAppRuntime.{file}.1.8.msix', output)
            self.assertEqual(recorded, [])

    def test_runtime_packages_are_kept_individually_when_newer(self):
        """Without a newer framework, each package is still skipped only if the guest's copy is newer."""
        with tempfile.TemporaryDirectory(prefix='install-package-') as directory:
            output, recorded = self.install_runtime(
                directory, ['MicrosoftCorporationII.WinAppRuntime.Singleton_8000.994.0.0_x64__8wekyb3d8bbwe'])
            self.assertIn('kept installed 8000.994.0.0: MicrosoftCorporationII.WinAppRuntime.Singleton', output)
            self.assertEqual(sorted(recorded), sorted([
                'Microsoft.WindowsAppRuntime.1.8', 'Microsoft.WinAppRuntime.DDLM.8000.770.0.0-x6',
                'MicrosoftCorporationII.WinAppRuntime.Main.1.8']))

    def test_updated_packages_are_removed_and_frameworks_in_use_are_kept(self):
        framework = 'Microsoft.WindowsAppRuntime.1.8_8000.{}.0.0_x64__8wekyb3d8bbwe'
        main = 'MicrosoftCorporationII.WinAppRuntime.Main.1.8_8000.{}.0.0_x64__8wekyb3d8bbwe'
        app = 'Example.TestApp_1.0.0.9_x64__abcdefghijklm'
        x86_framework = 'Microsoft.WindowsAppRuntime.1.8_8000.770.0.0_x86__8wekyb3d8bbwe'
        with tempfile.TemporaryDirectory(prefix='remove-packages-') as directory:
            # The test recorded the 770 runtime and the app; the Store then updated the runtime to 994.
            record = Path(directory) / 'installed.txt'
            record.write_text('\n'.join([framework.format(770), main.format(770), app]) + '\n')
            output = self.run_pwsh(f"""
New-Fake '{framework.format(994)}'
New-Fake '{x86_framework}'
New-Fake '{main.format(994)}' @('{framework.format(994)}')
New-Fake '{app}' @('{framework.format(994)}')
New-Fake 'Microsoft.DesktopAppInstaller_1.27.0.0_x64__8wekyb3d8bbwe' @('{framework.format(994)}')
& '{self.windows(self.APP_TEST_DIR / 'remove-packages.ps1')}' -Record '{self.windows(record)}'
'left: ' + (($global:Fake | ForEach-Object PackageFullName) -join ' ')
""")
            self.assertIn(f'removed: {app}', output)
            self.assertIn(f'removed: {main.format(994)}', output)
            self.assertIn(f'kept {framework.format(994)}, in use by Microsoft.DesktopAppInstaller', output)
            left = output.split('left: ', 1)[1]
            self.assertIn(framework.format(994), left)
            self.assertIn(x86_framework, left)
            self.assertNotIn(main.format(994), left)
            self.assertFalse(record.exists())


class BridgeTests(unittest.TestCase):
    """Check the OS boundary and cleanup policy with lightweight Windows fixtures."""

    def run_fixture(self, fail=False):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-test-') as directory:
            root = Path(directory)
            for relative in ('App/changed.txt', 'external/promo/uncommitted.txt',
                             'local.secrets.props', 'AppMSIX/App.pfx'):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('working-tree')
            (root / '.git').mkdir()
            (root / '.git/private-metadata').write_text('not source')
            (root / 'external/promo/.git').write_text('gitdir: absent')
            (root / 'App/bin').mkdir()
            (root / 'App/bin/stale.txt').write_text('stale')
            (root / 'App/App.csproj').write_text('<Project />')
            (root / 'AppMSIX/build-msix.ps1').write_text(PACKAGE_FIXTURE)
            if fail:
                (root / 'fail').touch()
            (root / 'windows-build.json').write_text(json.dumps({
                'project': 'App/App.csproj', 'package_script': 'AppMSIX/build-msix.ps1',
                'package_output': 'AppMSIX/bin/msix-output', 'certificate': 'AppMSIX/App.pfx',
            }))
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            output = next((root / '.artifacts/windows-build').iterdir())
            report = json.loads((output / 'result.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(report['success'], not fail, result.stdout)
            self.assertEqual(result.returncode, 1 if fail else 0, result.stdout)
            self.assertTrue((output / 'console.log').exists())
            self.assertFalse(list(output.rglob('*.pfx')))
            # Windows path is emitted once at startup, then that exact stage is removed.
            line = next(line for line in result.stdout.splitlines() if line.startswith('Staging '))
            windows_stage = line.split(' in ', 1)[1]
            linux_stage = subprocess.check_output(['wslpath', '-u', windows_stage], text=True).strip()
            self.assertFalse(Path(linux_stage).exists(), result.stdout)
            self.assertEqual((root / 'App/changed.txt').read_text(), 'working-tree')
            self.assertEqual((root / 'App/bin/stale.txt').read_text(), 'stale')
            return windows_stage

    def test_success_preserves_current_inputs_and_cleans_stage(self):
        self.run_fixture()

    def test_failure_returns_logs_and_cleans_stage(self):
        self.run_fixture(fail=True)

    def test_concurrent_builds_use_different_stages(self):
        with ThreadPoolExecutor(max_workers=2) as executor:
            stages = list(executor.map(lambda _: self.run_fixture(), range(2)))
        self.assertNotEqual(*stages)

    def test_cancellation_stops_only_its_windows_tree_before_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-cancel-') as directory:
            root = Path(directory)
            # A minimal packaging fixture sleeps in the packaging child. This
            # checks Windows PID cancellation rather than merely killing Python.
            (root / 'App').mkdir()
            (root / 'App/App.csproj').write_text('<Project />')
            (root / 'AppMSIX').mkdir()
            (root / 'AppMSIX/App.pfx').write_text('fixture')
            # The script marks that it is running, so the test cancels a live packaging child.
            (root / 'AppMSIX/build-msix.ps1').write_text(
                'param([string]$Platform, [string]$Configuration)\n'
                "Set-Content -LiteralPath (Join-Path $PSScriptRoot 'started') -Value 'running'\n"
                'Start-Sleep -Seconds 120\n')
            (root / 'windows-build.json').write_text(json.dumps({
                'project': 'App/App.csproj', 'package_script': 'AppMSIX/build-msix.ps1',
                'package_output': 'AppMSIX/bin/msix-output', 'certificate': 'AppMSIX/App.pfx',
            }))
            process = subprocess.Popen(['python3', str(BRIDGE), '--repo', str(root)],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                # The bridge may announce its chosen platform first; the stage line follows.
                line = process.stdout.readline()
                while line and not line.startswith('Staging '):
                    line = process.stdout.readline()
                windows_stage = line.strip().split(' in ', 1)[1]
                stage = Path(subprocess.check_output(['wslpath', '-u', windows_stage], text=True).strip())
                # Wait for the packaging child itself rather than a fixed delay: Windows process
                # startup and the fixture compile can take tens of seconds on a busy machine.
                started = stage / 'source/AppMSIX/started'
                deadline = time.monotonic() + 90
                while not started.exists() and time.monotonic() < deadline and process.poll() is None:
                    time.sleep(0.1)
                self.assertTrue((stage / 'windows.pid').exists())
                self.assertTrue(started.exists(), 'packaging child never started')
                # Interrupt the normal WSL invocation while that child is still sleeping.
                process.send_signal(signal.SIGINT)
                output, _ = process.communicate(timeout=60)
                self.assertEqual(process.returncode, 130, output)
                self.assertFalse(stage.exists(), output)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


    def make_library_repo(self, root):
        """A compile-only repo: a project that builds with no SDK, agent folders and the AI-8 symlink.

        The project fails its own build if an agent folder was staged next to it.
        """
        (root / 'Lib').mkdir()
        (root / 'Lib/Lib.csproj').write_text(
            '<Project DefaultTargets="Build">\n'
            '  <Target Name="Restore" />\n'
            '  <Target Name="Build">\n'
            "    <Error Condition=\"Exists('$(MSBuildThisFileDirectory)../.claude') Or Exists('$(MSBuildThisFileDirectory)../.agents')\" Text=\"Agent folders were staged\" />\n"
            '    <MakeDir Directories="$(MSBuildThisFileDirectory)bin" />\n'
            '  </Target>\n'
            '</Project>\n')
        (root / '.agents/skills/release').mkdir(parents=True)
        (root / '.agents/skills/release/SKILL.md').write_text('skill')
        (root / '.claude').mkdir()
        (root / '.claude/skills').symlink_to('../.agents/skills')
        # Only "project": no package_script, package_output or certificate.
        (root / 'windows-build.json').write_text(json.dumps({'project': 'Lib/Lib.csproj'}))

    def test_build_only_needs_only_project_and_skips_agent_folders(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-library-') as directory:
            root = Path(directory)
            self.make_library_repo(root)
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root), '--build-only',
                                     '--configuration', 'Debug', '--platform', 'x64'],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue((root / '.claude/skills').is_symlink())

    def test_packaging_still_requires_package_script(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-library-') as directory:
            root = Path(directory)
            self.make_library_repo(root)
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root), '--no-sign'],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('package_script', result.stdout)

    def test_other_symlinks_are_still_rejected(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-library-') as directory:
            root = Path(directory)
            self.make_library_repo(root)
            (root / 'Lib/linked.txt').symlink_to('Lib.csproj')
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root), '--build-only',
                                     '--configuration', 'Debug', '--platform', 'x64'],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('Source symlinks need an explicit staging policy', result.stdout)

    def test_platform_defaults_to_the_build_hosts_architecture(self):
        """Without --platform, a build targets this Windows host's own architecture (AI-13)."""
        expected = host_platform.local_platform()
        with tempfile.TemporaryDirectory(prefix='windows-bridge-platform-') as directory:
            root = Path(directory)
            self.make_library_repo(root)
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root), '--build-only',
                                     '--configuration', 'Debug'],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn(f'Platform: {expected} (this Windows host', result.stdout)
            report = next((root / '.artifacts/windows-build').glob('*/result.json'))
            self.assertEqual(json.loads(report.read_text(encoding='utf-8-sig'))['platform'], expected)

    def run_library_build(self, root, cache, *extra):
        """Start a compile-only library build that uses a private lock directory."""
        return subprocess.Popen(['python3', str(BRIDGE), '--repo', str(root), '--build-only',
                                 '--configuration', 'Debug', *extra],
                                env=dict(os.environ, XDG_CACHE_HOME=str(cache)),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def test_no_wait_fails_fast_while_another_run_holds_the_host(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-lock-') as directory:
            root, cache = Path(directory) / 'repo', Path(directory) / 'cache'
            root.mkdir()
            self.make_library_repo(root)
            with mock.patch.dict(os.environ, XDG_CACHE_HOME=str(cache)):
                held = build_lock.acquire('local', 'other-repo')
            with held:
                process = self.run_library_build(root, cache, '--no-wait')
                output, _ = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 1, output)
            self.assertIn(f'pid {os.getpid()}, repo other-repo', output)
            self.assertFalse((root / '.artifacts').exists(), output)

    def test_a_second_run_waits_for_the_host_then_builds(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-lock-') as directory:
            root, cache = Path(directory) / 'repo', Path(directory) / 'cache'
            root.mkdir()
            self.make_library_repo(root)
            with mock.patch.dict(os.environ, XDG_CACHE_HOME=str(cache)):
                held = build_lock.acquire('local', 'other-repo')
            process = self.run_library_build(root, cache)
            try:
                line = process.stdout.readline()
                while line and not line.startswith('Waiting for another windows-build run'):
                    line = process.stdout.readline()
                self.assertIn('repo other-repo', line)
                self.assertFalse((root / '.artifacts').exists(), 'built while the host was locked')
            finally:
                held.close()
            output, _ = process.communicate(timeout=120)
            self.assertEqual(process.returncode, 0, output)

    def test_a_killed_holder_never_leaves_a_stale_lock(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-lock-') as directory:
            env = dict(os.environ, XDG_CACHE_HOME=directory)
            holder = subprocess.Popen(
                ['python3', '-c', 'import build_lock, sys, time; build_lock.acquire("local", "held"); '
                                  'print("held", flush=True); time.sleep(120)'],
                cwd=str(BRIDGE.parent), env=env, stdout=subprocess.PIPE, text=True)
            self.assertEqual(holder.stdout.readline().strip(), 'held')
            holder.kill()
            holder.wait()
            holder.stdout.close()
            with mock.patch.dict(os.environ, XDG_CACHE_HOME=directory):
                build_lock.acquire('local', 'next', no_wait=True).close()

    def fake_interop_failure(self, directory, failures):
        """Put a pwsh.exe first on PATH that fails `failures` times with WSL's interop timeout.

        After that it hands every call to the real pwsh.exe, so the build still runs on
        Windows. Returns the environment to run the bridge with.
        """
        real = shutil.which('pwsh.exe')
        fake_bin = Path(directory) / 'bin'
        fake_bin.mkdir()
        counter = Path(directory) / 'failures-left'
        counter.write_text(str(failures))
        fake = fake_bin / 'pwsh.exe'
        fake.write_text(
            '#!/usr/bin/env bash\n'
            f'left=$(cat "{counter}")\n'
            'if [ "$left" -gt 0 ]; then\n'
            f'  echo $((left - 1)) > "{counter}"\n'
            "  echo '<3>WSL (1) ERROR: UtilAcceptVsock:281: accept4 failed 110' >&2\n"
            '  exit 1\n'
            'fi\n'
            f'exec "{real}" "$@"\n')
        fake.chmod(0o755)
        return dict(os.environ, PATH=f'{fake_bin}:{os.environ["PATH"]}')

    def test_first_interop_timeout_is_retried_once(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-interop-') as directory:
            root = Path(directory) / 'repo'
            root.mkdir()
            self.make_library_repo(root)
            env = self.fake_interop_failure(directory, failures=1)
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root), '--build-only',
                                     '--configuration', 'Debug'],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('retrying once', result.stdout)

    def test_a_second_interop_timeout_fails_with_its_error(self):
        with tempfile.TemporaryDirectory(prefix='windows-bridge-interop-') as directory:
            root = Path(directory) / 'repo'
            root.mkdir()
            self.make_library_repo(root)
            env = self.fake_interop_failure(directory, failures=2)
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root), '--build-only',
                                     '--configuration', 'Debug'],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertEqual(result.stdout.count('retrying once'), 1, result.stdout)
            self.assertIn('accept4 failed 110', result.stdout)
            self.assertFalse((root / '.artifacts').exists(), result.stdout)

    def test_signed_shared_dev_build_needs_the_private_password_file(self):
        """A signed build stops before any Windows work when the password file is absent (SEC-11)."""
        with tempfile.TemporaryDirectory(prefix='windows-bridge-signing-') as directory:
            root = Path(directory) / 'repo'
            home = Path(directory) / 'home'
            home.mkdir()
            root.mkdir()
            self.make_library_repo(root)
            (root / 'Lib/package.ps1').write_text('exit 0')
            (root / 'windows-build.json').write_text(json.dumps({
                'project': 'Lib/Lib.csproj', 'package_script': 'Lib/package.ps1',
                'certificate': 'Lib/dev.pfx', 'signing': 'shared-dev'}))
            # An empty HOME stands in for a machine without ~/.secrets/windows-build-tools/signing/.
            result = subprocess.run(['python3', str(BRIDGE), '--repo', str(root)],
                                    env=dict(os.environ, HOME=str(home)),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('Shared dev signing password missing', result.stdout)
            self.assertIn('windows-apps-dev.password', result.stdout)

if __name__ == '__main__':
    unittest.main(verbosity=2)
