"""Bring a build's named deliverables back from its stage into the repository (LAYOUT-12).

A packaging script that follows LAYOUT-12 (winui-app-kit's build-msix.ps1 from v2.2.0) writes
finished, named copies of its packages under .artifacts/packages/<version>/ in the source it was
given, which for the bridge is the staged copy. The stage is deleted after the build, so both
transports call merge_staged_packages() before cleaning up.
"""
from pathlib import Path
import shutil

PACKAGES = Path('.artifacts') / 'packages'


def merge_staged_packages(staged_source, repo):
    """Merge staged_source/.artifacts/packages into repo/.artifacts/packages.

    staged_source: the staged source root the packaging script ran in; repo: the WSL checkout.
    Same-named files are overwritten, and everything else already in the repository's folder is
    kept, so earlier versions stay until LAYOUT-11 pruning removes them. Returns the repository
    paths of the merged files, which is empty when the build wrote no packages folder (older
    packaging scripts), so callers need no version check.
    """
    source = Path(staged_source) / PACKAGES
    if not source.is_dir():
        return []
    destination = Path(repo) / PACKAGES
    shutil.copytree(source, destination, dirs_exist_ok=True)
    merged = (destination / path.relative_to(source) for path in source.rglob('*') if path.is_file())
    return sorted(merged)
