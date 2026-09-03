#!/usr/bin/env python3
"""Shared serialization for one Hermes profile's generated configuration.

All code that can read and then rewrite ``config.delta.yaml`` or ``config.yaml``
must hold this lock from topology validation through commit or rollback.  A
channel transaction already holds the fleet registry lock before it enters this
lock; config-only reconcilers never acquire the registry lock.  The only valid
ordering is therefore::

    fleet registry lock -> profile config lock

Never acquire the fleet registry lock while holding a profile config lock.
``flock`` ownership is kernel-scoped, so process exit releases the lock even
though the deliberately persistent lock file remains on disk.
"""

from __future__ import annotations

import fcntl
import os
import pathlib
import stat
import time
from types import TracebackType
from typing import Self


DEFAULT_TIMEOUT_SECONDS = 30.0
LOCK_TIMEOUT_ENV = "HERMES_PROFILE_CONFIG_LOCK_TIMEOUT_SECONDS"
TEST_BARRIER_ENV = "PJANGLER_TEST_PROFILE_CONFIG_BARRIER"
TEST_BARRIER_TIMEOUT_ENV = "PJANGLER_TEST_PROFILE_CONFIG_BARRIER_TIMEOUT_SECONDS"
TEST_BARRIER_LABEL_ENV = "PJANGLER_TEST_PROFILE_CONFIG_BARRIER_LABEL"
TEST_LOCK_ATTEMPT_ENV = "PJANGLER_TEST_PROFILE_CONFIG_LOCK_ATTEMPT"


class ProfileConfigLockError(RuntimeError):
    """The profile lock could not be acquired safely."""


def lock_path(profile: pathlib.Path) -> pathlib.Path:
    """Return a lock path that does not require following the profile root."""

    return profile.parent / f".{profile.name}.config.lock"


def _timeout_seconds() -> float:
    raw = os.environ.get(LOCK_TIMEOUT_ENV, str(DEFAULT_TIMEOUT_SECONDS))
    try:
        timeout = float(raw)
    except ValueError as exc:
        raise ProfileConfigLockError(
            f"{LOCK_TIMEOUT_ENV} must be a non-negative number"
        ) from exc
    if timeout < 0 or timeout != timeout:
        raise ProfileConfigLockError(
            f"{LOCK_TIMEOUT_ENV} must be a non-negative number"
        )
    return timeout


class ProfileConfigLock:
    """Exclusive, bounded, symlink-safe lock for one profile config pair."""

    def __init__(self, profile: pathlib.Path | str, timeout: float | None = None):
        self.profile = pathlib.Path(profile)
        self.path = lock_path(self.profile)
        self.timeout = _timeout_seconds() if timeout is None else timeout
        self.fd: int | None = None

    def acquire(self) -> Self:
        parent = self.profile.parent
        if parent.is_symlink() or not parent.is_dir():
            raise ProfileConfigLockError(
                f"profile parent must be a real directory before locking: {parent}"
            )
        if self.path.is_symlink():
            raise ProfileConfigLockError(
                f"refusing profile config lock symlink: {self.path}"
            )
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(self.path, flags, 0o600)
        except OSError as exc:
            raise ProfileConfigLockError(
                f"cannot open profile config lock {self.path}: {exc.strerror or type(exc).__name__}"
            ) from exc
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ProfileConfigLockError(
                    f"profile config lock is not a regular file: {self.path}"
                )
            os.fchmod(fd, 0o600)
            _notify_test_lock_attempt(self.path)
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError as exc:
                    if time.monotonic() >= deadline:
                        raise ProfileConfigLockError(
                            f"timed out waiting for profile config lock: {self.path}"
                        ) from exc
                    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
        except BaseException:
            os.close(fd)
            raise
        self.fd = fd
        return self

    def release(self) -> None:
        if self.fd is None:
            return
        fd, self.fd = self.fd, None
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    def __enter__(self) -> Self:
        return self.acquire()

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.release()


def _test_path_from_env(name: str) -> pathlib.Path | None:
    configured = os.environ.get(name)
    if not configured:
        return None
    if "PYTEST_CURRENT_TEST" not in os.environ:
        raise ProfileConfigLockError(
            f"{name} is test-only and requires a pytest process"
        )
    path = pathlib.Path(configured)
    if path.is_symlink() or path.parent.is_symlink() or not path.parent.is_dir():
        raise ProfileConfigLockError(f"unsafe test profile-config path: {path}")
    return path


def _notify_test_lock_attempt(lock: pathlib.Path) -> None:
    target = _test_path_from_env(TEST_LOCK_ATTEMPT_ENV)
    if target is not None:
        target.write_text(str(lock) + "\n", encoding="utf-8")


def test_snapshot_barrier(label: str) -> None:
    """Pause a test process after its locked snapshot has been captured.

    This hook is inert outside pytest.  It exists so the regression suite can
    deterministically exercise the stale-snapshot interleaving that motivated
    this lock without widening the production interface.
    """

    selected_label = os.environ.get(TEST_BARRIER_LABEL_ENV)
    if selected_label and selected_label != label:
        return
    barrier = _test_path_from_env(TEST_BARRIER_ENV)
    if barrier is None:
        return
    ready = pathlib.Path(f"{barrier}.ready")
    resume = pathlib.Path(f"{barrier}.resume")
    ready.write_text(label + "\n", encoding="utf-8")
    try:
        timeout = float(os.environ.get(TEST_BARRIER_TIMEOUT_ENV, "15"))
    except ValueError as exc:
        raise ProfileConfigLockError(
            f"{TEST_BARRIER_TIMEOUT_ENV} must be a positive number"
        ) from exc
    deadline = time.monotonic() + timeout
    while not resume.is_file():
        if time.monotonic() >= deadline:
            raise ProfileConfigLockError(
                f"timed out waiting at test profile-config barrier: {barrier}"
            )
        time.sleep(0.02)
