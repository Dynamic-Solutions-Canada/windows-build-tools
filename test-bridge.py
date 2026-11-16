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
import signal

BRIDGE = Path(__file__).with_name('windows-build.py')
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
            (root / 'AppMSIX/build-msix.ps1').write_text('param([string]$Platform, [string]$Configuration)\nStart-Sleep -Seconds 60\n')
            (root / 'windows-build.json').write_text(json.dumps({
                'project': 'App/App.csproj', 'package_script': 'AppMSIX/build-msix.ps1',
                'package_output': 'AppMSIX/bin/msix-output', 'certificate': 'AppMSIX/App.pfx',
            }))
            process = subprocess.Popen(['python3', str(BRIDGE), '--repo', str(root)],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                line = process.stdout.readline()
                windows_stage = line.strip().split(' in ', 1)[1]
                stage = Path(subprocess.check_output(['wslpath', '-u', windows_stage], text=True).strip())
                deadline = time.monotonic() + 10
                while not (stage / 'windows.pid').exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue((stage / 'windows.pid').exists())
                # Let the child start, then interrupt the normal WSL invocation.
                time.sleep(0.5)
                process.send_signal(signal.SIGINT)
                output, _ = process.communicate(timeout=15)
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
