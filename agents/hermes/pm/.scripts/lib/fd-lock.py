#!/usr/bin/env python3
"""flock(1) stand-in for hosts that lack it (macOS): lock an INHERITED descriptor.

    fd-lock.py lock FD TIMEOUT_SECONDS   exit 0 locked, 1 timed out, 2 usage or bad descriptor
    fd-lock.py unlock FD                 exit 0 unlocked, 2 usage or bad descriptor

This is `flock -w TIMEOUT FD` / `flock -u FD`, not a lock of its own. flock(2)
locks belong to the open file DESCRIPTION, not to the process: the shell opens
the lock file (`exec {fd}>"$lock"`), this child inherits that description,
locks it and exits, and the lock stays held through the shell's descriptor
until the shell unlocks or closes it, exactly as with flock(1). Because it is
the same syscall, a shell using this helper and one using flock(1) exclude each
other on the same lock file (Linux), and ownership stays kernel-scoped: a
crashed shell cannot leave a stale lock behind.
"""
from __future__ import annotations

import fcntl
import math
import os
import stat
import sys
import time

USAGE = "usage: fd-lock.py lock FD TIMEOUT_SECONDS | unlock FD"
POLL_SECONDS = 0.05


def descriptor(raw: str) -> int:
    if not raw.isdigit():
        raise ValueError("descriptor must be a non-negative integer")
    fd = int(raw)
    # A lock on anything but the regular lock file the caller opened is a bug.
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise ValueError("descriptor is not a regular file")
    return fd


def lock(fd: int, timeout: float) -> int:
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return 0
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return 1
            time.sleep(min(POLL_SECONDS, remaining))


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[0] == "lock":
            timeout = float(argv[2])
            if not math.isfinite(timeout) or timeout < 0:
                raise ValueError("timeout must be a finite, non-negative number of seconds")
            return lock(descriptor(argv[1]), timeout)
        if len(argv) == 2 and argv[0] == "unlock":
            fcntl.flock(descriptor(argv[1]), fcntl.LOCK_UN)
            return 0
    except (OSError, ValueError) as error:
        print(f"fd-lock: {error}", file=sys.stderr)
        return 2
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
