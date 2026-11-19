"""Remove the bridge's Windows staging folders, tolerating the /mnt/c client's transient ENOMEM.

Deleting a stage goes through WSL's 9p client for /mnt/c, which needs one contiguous 64 KB kernel
buffer per request (msize=65536). When physical memory is fragmented that allocation can fail
("page allocation failure: order:4, GFP_NOFS" in dmesg) and the delete fails with ENOMEM, although
the same delete succeeds moments later. A leftover stage is housekeeping, not a build failure, so
these helpers report what they could not remove instead of raising.
"""
import errno
import os
from pathlib import Path
import re
import shutil
import sys
import time

# tempfile.mkdtemp(prefix=repo.name + '-') adds eight characters from this set.
STAGE_NAME = re.compile(r'^.+-[a-z0-9_]{8}$')
MAX_STAGE_AGE_SECONDS = 24 * 60 * 60
REMOVE_ATTEMPTS = 3
RETRY_DELAY_SECONDS = 5


def remove_stage(stage):
    """Delete a stage folder, retrying the transient ENOMEM described above.

    Other errors are not retried. Returns True once the folder is gone; on failure prints a
    warning naming the folder (which is left, perhaps partly deleted) and returns False.
    """
    for attempt in range(1, REMOVE_ATTEMPTS + 1):
        try:
            shutil.rmtree(stage)
            return True
        except FileNotFoundError:
            return True
        except OSError as error:
            if error.errno != errno.ENOMEM or attempt == REMOVE_ATTEMPTS:
                print(f'Warning: stage not removed ({error.strerror}): {stage}; delete it later',
                      file=sys.stderr, flush=True)
                return False
            time.sleep(RETRY_DELAY_SECONDS)
    return False


def _last_change(folder):
    """The newest modification time of a folder and its top-level entries, in epoch seconds.

    A build rewrites its logs at the stage's top level, so this tracks a stage still in use more
    closely than the folder's own time, which changes only when entries are added or removed.
    """
    times = [folder.stat().st_mtime]
    for entry in os.scandir(folder):
        times.append(entry.stat(follow_symlinks=False).st_mtime)
    return max(times)


def prune_old_stages(stage_parent, now=None):
    """Remove stage folders under stage_parent untouched for over a day; return the removed paths.

    Only folders named like a bridge stage ("<repo>-" plus mkdtemp's eight characters) are
    candidates: anything else in the folder is left alone. A folder that cannot be inspected or
    removed is reported and skipped, so pruning never stops a build.
    """
    now = time.time() if now is None else now
    removed = []
    for entry in sorted(Path(stage_parent).iterdir()):
        if not entry.is_dir() or entry.is_symlink() or not STAGE_NAME.match(entry.name):
            continue
        try:
            age = now - _last_change(entry)
        except OSError as error:
            print(f'Warning: could not inspect old stage ({error.strerror}): {entry}', file=sys.stderr, flush=True)
            continue
        if age > MAX_STAGE_AGE_SECONDS and remove_stage(entry):
            removed.append(entry)
    return removed
