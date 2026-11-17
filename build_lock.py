"""Serialize windows-build.py runs that share one Windows build host.

Parallel runs from different sessions overload the host: concurrent pwsh.exe interop
calls have failed with "UtilAcceptVsock ... accept4 failed 110", and agents wrote their
own pgrep wait loops that never ended. Each transport target therefore has one
exclusive lock. The local Windows host and each VM are separate targets, so a VM build
never waits for a local one.

The lock is a Linux flock on a file under ~/.cache/windows-build-tools/. The kernel
releases it when the holding process exits for any reason, including SIGKILL, so a
crashed build can never leave a stale lock behind. Python opens files
non-inheritable, so Windows child processes never keep it alive.
"""
import fcntl
import os
from pathlib import Path
import re
import time

POLL_SECONDS = 2


class BuildLockBusy(RuntimeError):
    """Raised under --no-wait when another run holds the lock."""


def _lock_directory():
    """Return the shared lock directory, honouring XDG_CACHE_HOME."""
    cache = os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache'
    return Path(cache) / 'windows-build-tools'


def _describe_holder(handle):
    """Read the holder's "pid N, repo X" note, or a placeholder while it is being written."""
    handle.seek(0)
    note = handle.read().strip()
    return note or 'holder details not yet written'


def acquire(target, repo, no_wait=False):
    """Take the exclusive build lock for one Windows build target and return its handle.

    target: short name of the build host, such as "local" or "vm-windows-dev".
    repo: repository being built, recorded so waiting runs can say who they wait for.
    no_wait: raise BuildLockBusy at once instead of waiting.

    Keep the returned file object referenced for the whole build; closing it, or the
    process exiting, releases the lock. Ctrl+C while waiting raises KeyboardInterrupt.
    """
    directory = _lock_directory()
    directory.mkdir(parents=True, exist_ok=True)
    safe_target = re.sub(r'[^A-Za-z0-9_.-]', '_', target)
    handle = open(directory / f'{safe_target}.lock', 'a+', encoding='utf-8')

    # Phase 1: try at once, then poll so the wait stays interruptible and reports changes.
    announced = None
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            holder = _describe_holder(handle)
            if no_wait:
                handle.close()
                raise BuildLockBusy(f'another windows-build run is using {target} ({holder}); '
                                    'retry later or drop --no-wait to queue')
            if holder != announced:
                print(f'Waiting for another windows-build run on {target} ({holder})', flush=True)
                announced = holder
            time.sleep(POLL_SECONDS)

    # Phase 2: record this run for anyone who queues behind it.
    handle.seek(0)
    handle.truncate()
    handle.write(f'pid {os.getpid()}, repo {repo}\n')
    handle.flush()
    return handle
