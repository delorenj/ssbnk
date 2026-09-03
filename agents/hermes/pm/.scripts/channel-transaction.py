#!/usr/bin/env python3
"""Commit one verified channel wiring as a crash-consistent transaction.

Raw credentials are never accepted.  This helper owns the canonical lock
ordering (registry, then profile), journals every candidate before mutation,
and compare-and-swaps each target against the exact state it observed.  A
crash is recovered on the next invocation; an unrelated edit is never erased.
"""

from __future__ import annotations

import argparse
import copy
import ctypes
import errno
import fcntl
import grp
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from typing import Any

import yaml


def load_profile_lock_module():
    source = pathlib.Path(__file__).parent / "lib" / "profile-config-lock.py"
    if source.is_symlink() or not source.is_file():
        raise RuntimeError(f"trusted profile config lock helper is unavailable: {source}")
    spec = importlib.util.spec_from_file_location(
        "pjangler_profile_config_lock", source
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load profile config lock helper: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROFILE_LOCK = load_profile_lock_module()


LIST_PATCH_KEY = "x-pjangler-merge"
CHANNEL_FIELDS = {
    "telegram": ("provisioning_status", "bot_username", "bot_id"),
    "slack": (
        "provisioning_status",
        "team_id",
        "team_name",
        "bot_user_id",
        "bot_id",
        "bot_username",
    ),
}
CHANNEL_REFERENCE_KEYS = {
    "telegram": ("TELEGRAM_BOT_TOKEN",),
    "slack": ("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"),
}
CHANNEL_ALLOWED_KEYS = {
    "telegram": "TELEGRAM_ALLOWED_USERS",
    "slack": "SLACK_ALLOWED_USERS",
}


@dataclass(frozen=True)
class FileState:
    existed: bool
    mode: int
    dev: int = 0
    ino: int = 0
    size: int = 0
    mtime_ns: int = 0
    nlink: int = 0
    sha256: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "existed": self.existed,
            "mode": self.mode,
            "dev": self.dev,
            "ino": self.ino,
            "size": self.size,
            "mtime_ns": self.mtime_ns,
            "nlink": self.nlink,
            "sha256": self.sha256,
        }

    @classmethod
    def from_json(cls, value: object) -> "FileState":
        if not isinstance(value, dict):
            raise TransactionRecoveryError("journal file state is not a mapping")
        expected = {
            "existed",
            "mode",
            "dev",
            "ino",
            "size",
            "mtime_ns",
            "nlink",
            "sha256",
        }
        if set(value) != expected:
            raise TransactionRecoveryError("journal file state has invalid fields")
        if not isinstance(value["existed"], bool):
            raise TransactionRecoveryError("journal file state existence is invalid")
        numeric = ("mode", "dev", "ino", "size", "mtime_ns", "nlink")
        if any(not isinstance(value[key], int) or isinstance(value[key], bool) for key in numeric):
            raise TransactionRecoveryError("journal file state numeric field is invalid")
        digest = value["sha256"]
        if not isinstance(digest, str) or (digest and not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise TransactionRecoveryError("journal file state digest is invalid")
        return cls(**value)


@dataclass(frozen=True)
class Snapshot:
    state: FileState
    content: bytes

    @property
    def existed(self) -> bool:
        return self.state.existed

    @property
    def mode(self) -> int:
        return self.state.mode


class TransactionConflict(RuntimeError):
    """A target changed outside this transaction."""


class TransactionRecoveryError(RuntimeError):
    """Protected recovery state is malformed or cannot be reconciled."""


class ExistingWiringUnavailable(RuntimeError):
    """The role has no verified durable wiring to reconcile."""


class ExistingWiringValidationUnavailable(RuntimeError):
    """Verified references exist but cannot currently be validated."""


class ExistingWiringAlreadyVerified(RuntimeError):
    """Preparation found verified wiring and deliberately made no change."""


def fail(message: str) -> "None":
    raise SystemExit(f"channel transaction failed: {message}")


def fsync_parent(path: pathlib.Path) -> None:
    unsupported = {errno.EINVAL, getattr(errno, "ENOTSUP", errno.EINVAL), errno.ENOSYS}
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    try:
        directory_fd = os.open(path.parent, flags)
    except OSError as exc:
        if exc.errno in unsupported:
            return
        raise
    try:
        try:
            os.fsync(directory_fd)
        except OSError as exc:
            if exc.errno not in unsupported:
                raise
    finally:
        os.close(directory_fd)


def fsync_directory(path: pathlib.Path) -> None:
    unsupported = {errno.EINVAL, getattr(errno, "ENOTSUP", errno.EINVAL), errno.ENOSYS}
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    directory_fd = os.open(path, flags)
    try:
        try:
            os.fsync(directory_fd)
        except OSError as exc:
            if exc.errno not in unsupported:
                raise
    finally:
        os.close(directory_fd)


def finite_timeout(name: str, fallback: str) -> float:
    raw = os.environ.get(name, fallback)
    try:
        value = float(raw)
    except ValueError as exc:
        raise TransactionRecoveryError(f"{name} must be a finite non-negative number") from exc
    if not math.isfinite(value) or value < 0:
        raise TransactionRecoveryError(f"{name} must be a finite non-negative number")
    return value


def directory_is_private_to_user(info: os.stat_result) -> bool:
    """Accept an owner-only directory or the account's private primary group."""

    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o002:
        return False
    if not stat.S_IMODE(info.st_mode) & 0o020:
        return True
    try:
        username = pwd.getpwuid(os.geteuid()).pw_name
        group = grp.getgrgid(info.st_gid)
        primary_members = {
            account.pw_name for account in pwd.getpwall() if account.pw_gid == info.st_gid
        }
    except (KeyError, OSError):
        return False
    return (set(group.gr_mem) | primary_members) <= {username}


class RegistryLock:
    """Symlink-safe canonical registry lock, acquired before the profile lock.

    During the caller migration this also recognizes the exact lock inode on an
    inherited descriptor.  It still calls ``flock`` itself, so direct helper
    invocation cannot bypass locking and an inherited *unlocked* descriptor is
    not trusted.
    """

    def __init__(self, registry: pathlib.Path):
        self.registry = registry
        self.path = registry.with_name(registry.name + ".lock")
        self.fd: int | None = None
        self.borrowed = False
        self.timeout = finite_timeout(
            "HERMES_REGISTRY_LOCK_TIMEOUT_SECONDS",
            os.environ.get("FLEET_LOCK_TIMEOUT_SECONDS", "30"),
        )

    def _inherited_matching_fd(self, opened: os.stat_result) -> int | None:
        try:
            names = os.listdir("/proc/self/fd")
        except OSError:
            names = [str(number) for number in range(3, 256)]
        for raw in names:
            if not raw.isdigit():
                continue
            candidate = int(raw)
            if candidate == self.fd:
                continue
            try:
                current = os.fstat(candidate)
            except OSError:
                continue
            if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                continue
            if not stat.S_ISREG(current.st_mode):
                continue
            try:
                fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            return candidate
        return None

    def __enter__(self) -> "RegistryLock":
        parent = self.path.parent
        if parent.is_symlink() or not parent.is_dir():
            raise TransactionRecoveryError(
                f"registry parent must be a real directory before locking: {parent}"
            )
        if self.path.is_symlink():
            raise TransactionRecoveryError(f"refusing registry lock symlink: {self.path}")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(self.path, flags, 0o600)
        self.fd = fd
        try:
            opened = os.fstat(fd)
            if not stat.S_ISREG(opened.st_mode):
                raise TransactionRecoveryError(
                    f"registry lock is not a regular file: {self.path}"
                )
            os.fchmod(fd, 0o600)
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError as exc:
                    inherited = self._inherited_matching_fd(opened)
                    if inherited is not None:
                        os.close(fd)
                        self.fd = inherited
                        self.borrowed = True
                        break
                    if time.monotonic() >= deadline:
                        raise TransactionRecoveryError(
                            f"timed out waiting for registry lock: {self.path}"
                        ) from exc
                    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
            locked = os.lstat(self.path)
            held = os.fstat(self.fd)
            if (locked.st_dev, locked.st_ino) != (held.st_dev, held.st_ino):
                raise TransactionRecoveryError(
                    f"registry lock identity changed while acquiring: {self.path}"
                )
            if self.registry.is_symlink():
                raise TransactionRecoveryError(
                    f"refusing registry symlink: {self.registry}"
                )
            if self.registry.exists() and not self.registry.is_file():
                raise TransactionRecoveryError(
                    f"registry is not a regular file: {self.registry}"
                )
            return self
        except BaseException:
            if self.fd is not None and not self.borrowed:
                os.close(self.fd)
            self.fd = None
            raise

    def __exit__(self, *_args: object) -> None:
        if self.fd is None:
            return
        fd, borrowed = self.fd, self.borrowed
        self.fd = None
        self.borrowed = False
        if borrowed:
            return
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def snapshot(path: pathlib.Path, default_mode: int) -> Snapshot:
    try:
        listed = os.lstat(path)
    except FileNotFoundError:
        return Snapshot(FileState(False, default_mode), b"")
    if stat.S_ISLNK(listed.st_mode):
        fail(f"refusing symlinked transaction path: {path}")
    if not stat.S_ISREG(listed.st_mode):
        fail(f"transaction path is not a regular file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            fail(f"transaction path is not a regular file: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        content = b"".join(chunks)
        finished = os.fstat(fd)
    finally:
        os.close(fd)
    relisted = os.lstat(path)
    identities = {
        (listed.st_dev, listed.st_ino),
        (opened.st_dev, opened.st_ino),
        (finished.st_dev, finished.st_ino),
        (relisted.st_dev, relisted.st_ino),
    }
    signatures = {
        (
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
            value.st_nlink,
            stat.S_IMODE(value.st_mode),
        )
        for value in (listed, opened, finished, relisted)
    }
    if (
        len(identities) != 1
        or len(signatures) != 1
        or finished.st_size != len(content)
    ):
        raise TransactionConflict(f"transaction path changed while snapshotting: {path}")
    state = FileState(
        True,
        stat.S_IMODE(finished.st_mode),
        finished.st_dev,
        finished.st_ino,
        finished.st_size,
        finished.st_mtime_ns,
        finished.st_nlink,
        hashlib.sha256(content).hexdigest(),
    )
    return Snapshot(state, content)


def current_state(path: pathlib.Path, default_mode: int) -> FileState:
    return snapshot(path, default_mode).state


def state_matches(path: pathlib.Path, expected: FileState) -> bool:
    try:
        return current_state(path, expected.mode) == expected
    except (OSError, SystemExit, TransactionConflict):
        return False


def state_same_inode_and_bytes(current: FileState, expected: FileState) -> bool:
    """Compare durable identity/content while allowing known hard-link counts."""

    return (
        current.existed == expected.existed
        and current.mode == expected.mode
        and current.dev == expected.dev
        and current.ino == expected.ino
        and current.size == expected.size
        and current.mtime_ns == expected.mtime_ns
        and current.sha256 == expected.sha256
    )


AT_FDCWD = -100
RENAME_NOREPLACE = 1
RENAME_EXCHANGE = 2
_LIBC = ctypes.CDLL(None, use_errno=True)
_RENAMEAT2 = getattr(_LIBC, "renameat2", None)
if _RENAMEAT2 is not None:
    _RENAMEAT2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    _RENAMEAT2.restype = ctypes.c_int


def renameat2(source: pathlib.Path, target: pathlib.Path, flags: int) -> None:
    """Linux atomic rename primitive used as the file-level CAS operation."""

    if _RENAMEAT2 is None:
        raise TransactionRecoveryError(
            "renameat2 is required for crash-safe channel compare-and-swap"
        )
    result = _RENAMEAT2(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(target),
        flags,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(source), str(target))


def atomic_exchange(source: pathlib.Path, target: pathlib.Path) -> None:
    renameat2(source, target, RENAME_EXCHANGE)


def atomic_move_noreplace(source: pathlib.Path, target: pathlib.Path) -> None:
    renameat2(source, target, RENAME_NOREPLACE)


def fault_boundary(_label: str) -> None:
    """No-op seam replaced only in copied test fixtures.

    Production code has no path-writing pause hook.  Process tests instrument a
    private copy of this function to stop or kill the helper at exact durable
    boundaries without widening the deployed interface.
    """

    # TEST_FIXTURE_FAULT_BOUNDARY


def strict_json_loads(content: str) -> dict[str, Any]:
    def unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise TransactionRecoveryError(f"duplicate journal key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(content, object_pairs_hook=unique_pairs)
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise TransactionRecoveryError(
            f"transaction journal is malformed: {type(exc).__name__}"
        ) from exc
    if not isinstance(value, dict):
        raise TransactionRecoveryError("transaction journal root is not a mapping")
    return value


class CrashConsistentTransaction:
    """Ordered, journaled compare-and-swap across channel-owned files."""

    SCHEMA_VERSION = 1
    JOURNAL_NAME = "journal.json"
    NEXT_JOURNAL_NAME = ".journal.next"

    def __init__(
        self,
        *,
        profile: pathlib.Path,
        registry: pathlib.Path,
        channel: str,
        agent_id: str,
        targets: dict[str, pathlib.Path],
        modes: dict[str, int],
    ):
        self.profile = profile
        self.registry = registry
        self.channel = channel
        self.agent_id = agent_id
        self.targets = targets
        self.modes = modes
        self.directory = profile.parent / f".{profile.name}.channel-transaction"
        self.journal_path = self.directory / self.JOURNAL_NAME
        self.journal: dict[str, Any] = {}

    def _validate_directory(self) -> None:
        if self.directory.is_symlink() or not self.directory.is_dir():
            raise TransactionRecoveryError(
                f"protected transaction path is not a real directory: {self.directory}"
            )
        info = os.lstat(self.directory)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise TransactionRecoveryError(
                f"protected transaction directory ownership/mode is unsafe: {self.directory}"
            )

    def _write_journal(self) -> None:
        self._validate_directory()
        payload = (json.dumps(self.journal, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
        temporary = self.directory / self.NEXT_JOURNAL_NAME
        if temporary.is_symlink():
            raise TransactionRecoveryError(
                f"refusing transaction journal symlink: {temporary}"
            )
        if temporary.exists():
            if not temporary.is_file():
                raise TransactionRecoveryError(
                    f"transaction journal staging path is unsafe: {temporary}"
                )
            temporary.unlink()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(temporary, flags, 0o600)
        try:
            os.fchmod(fd, 0o600)
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, self.journal_path)
        fsync_directory(self.directory)

    def _load_journal(self) -> dict[str, Any]:
        self._validate_directory()
        if self.journal_path.is_symlink() or not self.journal_path.is_file():
            raise TransactionRecoveryError(
                f"protected transaction journal is unavailable: {self.journal_path}"
            )
        if stat.S_IMODE(os.lstat(self.journal_path).st_mode) != 0o600:
            raise TransactionRecoveryError(
                f"protected transaction journal mode is unsafe: {self.journal_path}"
            )
        return strict_json_loads(self.journal_path.read_text(encoding="utf-8"))

    def _validate_journal_identity(self, journal: dict[str, Any]) -> None:
        if journal.get("schema_version") != self.SCHEMA_VERSION:
            raise TransactionRecoveryError("unsupported transaction journal schema")
        identity = journal.get("identity")
        if not isinstance(identity, dict):
            raise TransactionRecoveryError("transaction journal identity is invalid")
        expected = {
            "profile": str(self.profile),
            "registry": str(self.registry),
            "agent_id": self.agent_id,
        }
        for key, value in expected.items():
            if identity.get(key) != value:
                raise TransactionRecoveryError(
                    f"transaction journal {key} does not match this invocation"
                )
        targets = journal.get("targets")
        if not isinstance(targets, dict) or set(targets) != set(self.targets):
            raise TransactionRecoveryError("transaction journal target set is invalid")
        for key, path in self.targets.items():
            entry = targets[key]
            if not isinstance(entry, dict) or entry.get("path") != str(path):
                raise TransactionRecoveryError(
                    f"transaction journal path does not match for {key}"
                )
            FileState.from_json(entry.get("original"))

    def _artifact_inventory(
        self,
        journal: dict[str, Any],
        *,
        directory: pathlib.Path | None = None,
    ) -> tuple[dict[pathlib.Path, list[FileState]], dict[tuple[int, int], int]]:
        """Return allowed artifact states and actual known link counts."""

        artifact_directory = self.directory if directory is None else directory
        allowed: dict[pathlib.Path, list[FileState]] = {}
        per_target: dict[str, list[FileState]] = {}
        for key, entry in journal["targets"].items():
            states = [FileState.from_json(entry["original"])]
            if entry.get("protected") is not None:
                states.append(FileState.from_json(entry["protected"]))
            per_target[key] = states
        for operation in journal.get("operations", []):
            key = operation["target"]
            per_target[key].extend(
                [
                    FileState.from_json(operation["expected"]),
                    FileState.from_json(operation["desired"]),
                ]
            )
            staged = operation.get("staged")
            if isinstance(staged, str):
                allowed[artifact_directory / staged] = per_target[key]
        for key, entry in journal["targets"].items():
            recovery = entry.get("recovery")
            if isinstance(recovery, str):
                allowed[artifact_directory / recovery] = per_target[key]
            rollback_capture = entry.get("rollback_capture")
            if isinstance(rollback_capture, str):
                allowed[artifact_directory / rollback_capture] = per_target[key]

        counts: dict[tuple[int, int], int] = {}
        candidates = [*self.targets.values(), *allowed]
        for path in candidates:
            try:
                info = os.lstat(path)
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise TransactionConflict(f"unsafe transaction path appeared: {path}")
            identity = (info.st_dev, info.st_ino)
            counts[identity] = counts.get(identity, 0) + 1
        return allowed, counts

    def _validate_artifacts_no_discard(
        self,
        journal: dict[str, Any],
        *,
        directory: pathlib.Path | None = None,
    ) -> None:
        allowed, counts = self._artifact_inventory(journal, directory=directory)
        for path, states in allowed.items():
            if not path.exists():
                if path.is_symlink():
                    raise TransactionConflict(f"transaction artifact became a symlink: {path}")
                continue
            current = current_state(path, 0o600)
            if not any(state_same_inode_and_bytes(current, state) for state in states):
                raise TransactionConflict(
                    f"unknown inode in protected transaction artifact; retained: {path}"
                )
            if current.nlink != counts[(current.dev, current.ino)]:
                raise TransactionConflict(
                    f"unexpected hard-link alias for protected transaction artifact: {path}"
                )

    def _cleanup_directory(self, journal: dict[str, Any] | None = None) -> None:
        """Atomically detach, validate, and remove only known artifacts.

        A pathname writer racing cleanup is redirected into the empty directory
        exchanged into the canonical location.  The captured transaction tree
        is validated only after that exchange, so cleanup never performs a
        check-then-unlink against the live canonical pathname.
        """

        self._validate_directory()
        allowed = {self.JOURNAL_NAME, self.NEXT_JOURNAL_NAME}
        if journal is not None:
            self._validate_artifacts_no_discard(journal)
            targets = journal.get("targets", {})
            if isinstance(targets, dict):
                for entry in targets.values():
                    if isinstance(entry, dict) and isinstance(entry.get("recovery"), str):
                        allowed.add(entry["recovery"])
                    if isinstance(entry, dict) and isinstance(
                        entry.get("rollback_capture"), str
                    ):
                        allowed.add(entry["rollback_capture"])
            operations = journal.get("operations", [])
            if isinstance(operations, list):
                for operation in operations:
                    if isinstance(operation, dict) and isinstance(operation.get("staged"), str):
                        allowed.add(operation["staged"])
        for entry in tuple(self.directory.iterdir()):
            if entry.name not in allowed:
                raise TransactionRecoveryError(
                    f"unknown protected transaction artifact requires manual review: {entry}"
                )
            if entry.is_symlink() or (entry.exists() and not entry.is_file()):
                raise TransactionRecoveryError(
                    f"unsafe protected transaction artifact requires manual review: {entry}"
                )

        captured_info = os.lstat(self.directory)
        quarantine = self.directory.with_name(
            f"{self.directory.name}.cleanup-{uuid.uuid4().hex}"
        )
        os.mkdir(quarantine, 0o700)
        os.chmod(quarantine, 0o700)
        placeholder_info = os.lstat(quarantine)
        fsync_parent(quarantine)
        fault_boundary("cleanup-before-exchange")
        atomic_exchange(self.directory, quarantine)
        fsync_parent(self.directory)
        captured_after = os.lstat(quarantine)
        placeholder_after = os.lstat(self.directory)
        identities_ok = (
            (captured_after.st_dev, captured_after.st_ino)
            == (captured_info.st_dev, captured_info.st_ino)
            and (placeholder_after.st_dev, placeholder_after.st_ino)
            == (placeholder_info.st_dev, placeholder_info.st_ino)
        )
        try:
            if not identities_ok:
                raise TransactionConflict(
                    "transaction directory identity changed during atomic cleanup capture"
                )
            if journal is not None:
                self._validate_artifacts_no_discard(journal, directory=quarantine)
            for entry in tuple(quarantine.iterdir()):
                if entry.name not in allowed:
                    raise TransactionConflict(
                        f"unknown cleanup artifact retained: {entry}"
                    )
                if entry.is_symlink() or (entry.exists() and not entry.is_file()):
                    raise TransactionConflict(
                        f"unsafe cleanup artifact retained: {entry}"
                    )
        except BaseException:
            # Restore the captured tree with another atomic exchange.  If a
            # pathname writer populated the placeholder meanwhile, its files
            # move to the quarantine name and are deliberately retained.
            atomic_exchange(quarantine, self.directory)
            fsync_parent(self.directory)
            try:
                quarantine.rmdir()
            except OSError:
                pass
            raise

        # The captured directory has an unguessable sibling name and the
        # canonical pathname now designates a distinct empty directory.  Check
        # each inode again immediately before removal and remove the journal
        # last, leaving recovery evidence intact on any discrepancy.
        try:
            artifact_states, _counts = (
                self._artifact_inventory(journal, directory=quarantine)
                if journal is not None
                else ({}, {})
            )
            names = sorted(allowed - {self.JOURNAL_NAME, self.NEXT_JOURNAL_NAME})
            names.extend([self.NEXT_JOURNAL_NAME, self.JOURNAL_NAME])
            for name in names:
                artifact = quarantine / name
                try:
                    info = os.lstat(artifact)
                except FileNotFoundError:
                    continue
                if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                    raise TransactionConflict(
                        f"cleanup artifact changed and was retained: {artifact}"
                    )
                states = artifact_states.get(artifact)
                if states is not None:
                    current = current_state(artifact, 0o600)
                    if not any(
                        state_same_inode_and_bytes(current, expected)
                        for expected in states
                    ):
                        raise TransactionConflict(
                            f"cleanup artifact inode changed and was retained: {artifact}"
                        )
                artifact.unlink()
            fsync_directory(quarantine)
            quarantine.rmdir()
        except BaseException:
            # Keep the journal (removed last above) and any remaining recovery
            # artifacts at the canonical location if cleanup is interrupted.
            if quarantine.exists() and self.directory.exists():
                atomic_exchange(quarantine, self.directory)
                fsync_parent(self.directory)
                try:
                    quarantine.rmdir()
                except OSError:
                    pass
            raise
        try:
            self.directory.rmdir()
        except OSError as exc:
            raise TransactionConflict(
                f"new state appeared during cleanup and was retained: {self.directory}"
            ) from exc
        fsync_parent(self.directory)

    def _cleanup_incomplete_preparation(self) -> None:
        """Remove only an owned 0700 directory created before journal publish.

        Target mutation starts only after a complete ``ready`` journal exists,
        so a journal-less directory cannot represent a committed file write.
        """

        self._validate_directory()
        for entry in tuple(self.directory.iterdir()):
            if entry.name != self.NEXT_JOURNAL_NAME:
                raise TransactionRecoveryError(
                    f"journal-less transaction artifact requires manual review: {entry}"
                )
            if entry.is_symlink() or not entry.is_file():
                raise TransactionRecoveryError(
                    f"unsafe journal-less transaction artifact: {entry}"
                )
        for entry in tuple(self.directory.iterdir()):
            entry.unlink()
        fsync_directory(self.directory)
        self.directory.rmdir()
        fsync_parent(self.directory)

    @staticmethod
    def _operation_states(journal: dict[str, Any]) -> dict[str, list[tuple[int, FileState]]]:
        result: dict[str, list[tuple[int, FileState]]] = {}
        operations = journal.get("operations", [])
        if not isinstance(operations, list):
            raise TransactionRecoveryError("transaction journal operations are invalid")
        for index, operation in enumerate(operations):
            if not isinstance(operation, dict) or operation.get("index") != index:
                raise TransactionRecoveryError("transaction journal operation order is invalid")
            key = operation.get("target")
            if not isinstance(key, str):
                raise TransactionRecoveryError("transaction journal operation target is invalid")
            result.setdefault(key, []).append((index, FileState.from_json(operation.get("desired"))))
        return result

    def _record_conflicts(self, journal: dict[str, Any], conflicts: list[str]) -> None:
        journal["status"] = "conflict"
        journal["conflicts"] = sorted(set(conflicts))
        self.journal = journal
        self._write_journal()

    @staticmethod
    def _parse_intent(
        journal: dict[str, Any], operations: list[dict[str, Any]]
    ) -> tuple[int, str] | None:
        value = journal.get("intent")
        if value is None:
            return None
        if not isinstance(value, dict) or set(value) != {"index", "phase"}:
            raise TransactionRecoveryError("transaction journal intent is invalid")
        index = value.get("index")
        phase = value.get("phase")
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or not 0 <= index < len(operations)
            or phase
            not in {"before-syscall", "captured", "reversing", "reversed"}
        ):
            raise TransactionRecoveryError("transaction journal intent is invalid")
        return index, phase

    @staticmethod
    def _same(current: FileState, expected: FileState) -> bool:
        return current == expected or state_same_inode_and_bytes(current, expected)

    def _operation_slot(
        self, operation: dict[str, Any], *, required: bool = True
    ) -> pathlib.Path | None:
        raw = operation.get("staged")
        if raw is None and not required:
            return None
        if not isinstance(raw, str) or pathlib.Path(raw).name != raw:
            raise TransactionRecoveryError("transaction operation slot is invalid")
        return self.directory / raw

    def _target_artifacts(
        self, journal: dict[str, Any], key: str
    ) -> list[pathlib.Path]:
        entry = journal["targets"][key]
        result: list[pathlib.Path] = []
        for name_key in ("recovery", "rollback_capture"):
            raw = entry.get(name_key)
            if isinstance(raw, str):
                result.append(self.directory / raw)
        for operation in journal.get("operations", []):
            if operation.get("target") != key:
                continue
            slot = self._operation_slot(operation, required=False)
            if slot is not None:
                result.append(slot)
        return list(dict.fromkeys(result))

    def _find_original_artifact(
        self, journal: dict[str, Any], key: str, original: FileState
    ) -> tuple[pathlib.Path, FileState] | None:
        for path in self._target_artifacts(journal, key):
            state = current_state(path, original.mode)
            if state.existed and state_same_inode_and_bytes(state, original):
                return path, state
        return None

    def _forward_possible_states(
        self,
        journal: dict[str, Any],
        operations: list[dict[str, Any]],
        cursor: int,
        intent: tuple[int, str] | None,
    ) -> dict[str, list[FileState]]:
        """States this transaction may legitimately have installed at targets."""

        possible: dict[str, list[FileState]] = {
            key: [FileState.from_json(entry["original"])]
            for key, entry in journal["targets"].items()
        }
        for operation in operations[:cursor]:
            possible[operation["target"]].append(
                FileState.from_json(operation["desired"])
            )
        if intent is not None:
            index, _phase = intent
            operation = operations[index]
            possible[operation["target"]].extend(
                [
                    FileState.from_json(operation["expected"]),
                    FileState.from_json(operation["desired"]),
                ]
            )
        return possible

    def _reverse_external_forward_capture(
        self,
        journal: dict[str, Any],
        operation: dict[str, Any],
        target_state: FileState,
        slot_state: FileState,
    ) -> None:
        """Atomically return a displaced external inode to the target."""

        index = operation["index"]
        label = operation["label"]
        key = operation["target"]
        path = self.targets[key]
        kind = operation["kind"]
        slot = self._operation_slot(operation)
        assert slot is not None
        journal["intent"] = {"index": index, "phase": "reversing"}
        self.journal = journal
        self._write_journal()
        fault_boundary(f"reverse-intent:{index}:{label}")
        reversed_ok = False
        if kind == "replace":
            atomic_exchange(slot, path)
            fsync_parent(path)
            fsync_directory(self.directory)
            after_target = current_state(path, slot_state.mode)
            after_slot = current_state(slot, target_state.mode)
            reversed_ok = self._same(after_target, slot_state) and self._same(
                after_slot, target_state
            )
        elif kind == "delete":
            try:
                atomic_move_noreplace(slot, path)
            except OSError as exc:
                if exc.errno != errno.EEXIST:
                    raise
            else:
                fsync_parent(path)
                fsync_directory(self.directory)
                after_target = current_state(path, slot_state.mode)
                after_slot = current_state(slot, target_state.mode)
                reversed_ok = self._same(after_target, slot_state) and not after_slot.existed
        else:
            raise TransactionRecoveryError(
                f"cannot reverse transaction operation kind: {kind}"
            )
        journal["intent"] = {"index": index, "phase": "reversed"}
        self._write_journal()
        fault_boundary(f"reverse:{index}:{label}")
        detail = (
            f"{key}:external-capture-reversed"
            if reversed_ok
            else f"{key}:external-capture-raced"
        )
        self._record_conflicts(journal, [detail])
        raise TransactionConflict(
            "external state preserved after atomic capture conflict; protected "
            f"journal retained at {self.journal_path}"
        )

    def _resolve_inflight_capture(
        self,
        journal: dict[str, Any],
        operations: list[dict[str, Any]],
        intent: tuple[int, str] | None,
    ) -> None:
        """Resolve an interrupted or mismatched forward atomic syscall."""

        if intent is None:
            return
        index, phase = intent
        operation = operations[index]
        kind = operation["kind"]
        if kind not in {"replace", "delete"}:
            return
        expected = FileState.from_json(operation["expected"])
        desired = FileState.from_json(operation["desired"])
        path = self.targets[operation["target"]]
        slot = self._operation_slot(operation)
        assert slot is not None
        target_state = current_state(path, desired.mode)
        slot_state = current_state(slot, expected.mode)

        if kind == "replace":
            pre_syscall = self._same(target_state, expected) and self._same(
                slot_state, desired
            )
            captured_expected = self._same(target_state, desired) and self._same(
                slot_state, expected
            )
            reversed_external = self._same(slot_state, desired) and not (
                self._same(target_state, expected)
                or self._same(target_state, desired)
            )
            captured_external = self._same(target_state, desired) and not (
                self._same(slot_state, expected) or self._same(slot_state, desired)
            )
            if pre_syscall or captured_expected:
                return
            if captured_external:
                self._reverse_external_forward_capture(
                    journal, operation, target_state, slot_state
                )
            if reversed_external or phase == "reversed":
                self._record_conflicts(
                    journal, [f"{operation['target']}:external-capture-reversed"]
                )
                raise TransactionConflict(
                    "external state preserved after interrupted atomic reversal; "
                    f"journal retained at {self.journal_path}"
                )
        else:
            pre_syscall = self._same(target_state, expected) and not slot_state.existed
            captured_expected = not target_state.existed and self._same(
                slot_state, expected
            )
            reversed_external = (
                not slot_state.existed
                and target_state.existed
                and not self._same(target_state, expected)
            )
            captured_external = (
                not target_state.existed
                and slot_state.existed
                and not self._same(slot_state, expected)
            )
            if pre_syscall or captured_expected:
                return
            if captured_external:
                self._reverse_external_forward_capture(
                    journal, operation, target_state, slot_state
                )
            if reversed_external or phase == "reversed":
                self._record_conflicts(
                    journal, [f"{operation['target']}:external-capture-reversed"]
                )
                raise TransactionConflict(
                    "external state preserved after interrupted atomic reversal; "
                    f"journal retained at {self.journal_path}"
                )

        self._record_conflicts(
            journal, [f"{operation['target']}:ambiguous-inflight-topology"]
        )
        raise TransactionConflict(
            "ambiguous atomic transaction topology retained for recovery at "
            f"{self.journal_path}"
        )

    def _build_rollback(
        self,
        journal: dict[str, Any],
        possible: dict[str, list[FileState]],
    ) -> dict[str, Any]:
        """Classify all paths before the first rollback mutation."""

        self._validate_artifacts_no_discard(journal)
        actions: list[dict[str, Any]] = []
        conflicts: list[str] = []
        for key, entry in journal["targets"].items():
            path = pathlib.Path(entry["path"])
            original = FileState.from_json(entry["original"])
            current = current_state(path, original.mode)
            if self._same(current, original):
                continue
            known_current = any(self._same(current, state) for state in possible[key])
            if original.existed:
                source = self._find_original_artifact(journal, key, original)
                if source is None:
                    conflicts.append(f"{key}:missing-original-recovery-inode")
                    continue
                source_path, source_state = source
                if current.existed and known_current:
                    actions.append(
                        {
                            "key": key,
                            "kind": "exchange",
                            "target": str(path),
                            "source": str(source_path),
                            "expected_target": current.to_json(),
                            "expected_source": source_state.to_json(),
                        }
                    )
                elif not current.existed and any(
                    not state.existed for state in possible[key]
                ):
                    actions.append(
                        {
                            "key": key,
                            "kind": "restore-missing",
                            "target": str(path),
                            "source": str(source_path),
                            "expected_target": current.to_json(),
                            "expected_source": source_state.to_json(),
                        }
                    )
                else:
                    conflicts.append(f"{key}:external-state")
            elif not current.existed:
                continue
            elif known_current:
                capture_name = entry.get("rollback_capture")
                if not isinstance(capture_name, str):
                    conflicts.append(f"{key}:missing-rollback-capture")
                    continue
                capture = self.directory / capture_name
                capture_state = current_state(capture, current.mode)
                if capture_state.existed:
                    conflicts.append(f"{key}:occupied-rollback-capture")
                    continue
                actions.append(
                    {
                        "key": key,
                        "kind": "capture-created",
                        "target": str(path),
                        "source": str(capture),
                        "expected_target": current.to_json(),
                        "expected_source": capture_state.to_json(),
                    }
                )
            else:
                conflicts.append(f"{key}:external-state")
        if conflicts:
            self._record_conflicts(journal, conflicts)
            raise TransactionConflict(
                "external state preserved; protected transaction journal retained at "
                f"{self.journal_path}"
            )
        rollback = {"cursor": 0, "intent": None, "actions": actions}
        journal["rollback"] = rollback
        journal["status"] = "rolling-back"
        journal["intent"] = None
        self.journal = journal
        self._write_journal()
        return rollback

    def _parse_rollback(self, journal: dict[str, Any]) -> dict[str, Any]:
        rollback = journal.get("rollback")
        if not isinstance(rollback, dict) or set(rollback) != {
            "cursor",
            "intent",
            "actions",
        }:
            raise TransactionRecoveryError("transaction rollback journal is invalid")
        actions = rollback.get("actions")
        cursor = rollback.get("cursor")
        intent = rollback.get("intent")
        if (
            not isinstance(actions, list)
            or not isinstance(cursor, int)
            or isinstance(cursor, bool)
            or not 0 <= cursor <= len(actions)
        ):
            raise TransactionRecoveryError("transaction rollback cursor is invalid")
        if intent is not None and (
            not isinstance(intent, dict)
            or set(intent) != {"index", "phase"}
            or intent.get("index") != cursor
            or intent.get("phase")
            not in {"before-syscall", "captured", "reversing", "reversed"}
        ):
            raise TransactionRecoveryError("transaction rollback intent is invalid")
        for action in actions:
            if not isinstance(action, dict) or set(action) != {
                "key",
                "kind",
                "target",
                "source",
                "expected_target",
                "expected_source",
            }:
                raise TransactionRecoveryError("transaction rollback action is invalid")
            if action["kind"] not in {"exchange", "restore-missing", "capture-created"}:
                raise TransactionRecoveryError("transaction rollback action kind is invalid")
            FileState.from_json(action["expected_target"])
            FileState.from_json(action["expected_source"])
        return rollback

    def _rollback_action_conflict(
        self,
        journal: dict[str, Any],
        action: dict[str, Any],
        detail: str,
    ) -> "None":
        self._record_conflicts(journal, [f"{action['key']}:{detail}"])
        raise TransactionConflict(
            "newer state appeared during atomic rollback and was preserved; "
            f"journal retained at {self.journal_path}"
        )

    def _run_rollback_action(
        self,
        journal: dict[str, Any],
        rollback: dict[str, Any],
        index: int,
    ) -> None:
        action = rollback["actions"][index]
        key = action["key"]
        kind = action["kind"]
        target = pathlib.Path(action["target"])
        source = pathlib.Path(action["source"])
        expected_target = FileState.from_json(action["expected_target"])
        expected_source = FileState.from_json(action["expected_source"])
        target_state = current_state(target, expected_target.mode)
        source_state = current_state(source, expected_source.mode)

        if kind == "exchange":
            post = self._same(target_state, expected_source) and self._same(
                source_state, expected_target
            )
            pre = self._same(target_state, expected_target) and self._same(
                source_state, expected_source
            )
        elif kind == "restore-missing":
            post = self._same(target_state, expected_source) and not source_state.existed
            pre = not target_state.existed and self._same(source_state, expected_source)
        else:
            post = not target_state.existed and self._same(source_state, expected_target)
            pre = self._same(target_state, expected_target) and not source_state.existed

        if post:
            rollback["cursor"] = index + 1
            rollback["intent"] = None
            self._write_journal()
            fault_boundary(f"rollback-commit:{index}:{key}")
            return
        if not pre:
            self._rollback_action_conflict(journal, action, "rollback-topology-conflict")

        rollback["intent"] = {"index": index, "phase": "before-syscall"}
        self._write_journal()
        fault_boundary(f"rollback-intent:{index}:{key}")
        if kind == "exchange":
            atomic_exchange(source, target)
        elif kind == "restore-missing":
            try:
                atomic_move_noreplace(source, target)
            except OSError as exc:
                if exc.errno == errno.EEXIST:
                    self._rollback_action_conflict(
                        journal, action, "rollback-target-created"
                    )
                raise
        else:
            try:
                atomic_move_noreplace(target, source)
            except OSError as exc:
                if exc.errno == errno.EEXIST:
                    self._rollback_action_conflict(
                        journal, action, "rollback-capture-occupied"
                    )
                raise
        fsync_parent(target)
        fsync_directory(self.directory)
        rollback["intent"] = {"index": index, "phase": "captured"}
        self._write_journal()
        fault_boundary(f"rollback-capture:{index}:{key}")

        after_target = current_state(target, expected_target.mode)
        after_source = current_state(source, expected_source.mode)
        if kind == "exchange":
            valid = self._same(after_target, expected_source) and self._same(
                after_source, expected_target
            )
        elif kind == "restore-missing":
            valid = self._same(after_target, expected_source) and not after_source.existed
        else:
            valid = not after_target.existed and self._same(
                after_source, expected_target
            )
        if not valid:
            rollback["intent"] = {"index": index, "phase": "reversing"}
            self._write_journal()
            fault_boundary(f"rollback-reverse-intent:{index}:{key}")
            reverse_ok = False
            if kind == "exchange":
                atomic_exchange(source, target)
                reverse_target = current_state(target, after_source.mode)
                reverse_source = current_state(source, after_target.mode)
                reverse_ok = self._same(reverse_target, after_source) and self._same(
                    reverse_source, after_target
                )
            elif kind == "restore-missing":
                try:
                    atomic_move_noreplace(target, source)
                except OSError as exc:
                    if exc.errno != errno.EEXIST:
                        raise
                else:
                    reverse_ok = not target.exists() and self._same(
                        current_state(source, after_target.mode), after_target
                    )
            else:
                try:
                    atomic_move_noreplace(source, target)
                except OSError as exc:
                    if exc.errno != errno.EEXIST:
                        raise
                else:
                    reverse_ok = not source.exists() and self._same(
                        current_state(target, after_source.mode), after_source
                    )
            fsync_parent(target)
            fsync_directory(self.directory)
            rollback["intent"] = {"index": index, "phase": "reversed"}
            self._write_journal()
            fault_boundary(f"rollback-reverse:{index}:{key}")
            self._rollback_action_conflict(
                journal,
                action,
                "rollback-cas-reversed" if reverse_ok else "rollback-cas-raced",
            )

        rollback["cursor"] = index + 1
        rollback["intent"] = None
        self._write_journal()
        fault_boundary(f"rollback-commit:{index}:{key}")

    def _rollback(self, journal: dict[str, Any]) -> None:
        cursor = journal.get("cursor")
        operations = journal.get("operations", [])
        if (
            not isinstance(operations, list)
            or not isinstance(cursor, int)
            or isinstance(cursor, bool)
            or not 0 <= cursor <= len(operations)
        ):
            raise TransactionRecoveryError("transaction journal cursor is invalid")
        intent = self._parse_intent(journal, operations)
        if journal.get("status") != "rolling-back":
            self._resolve_inflight_capture(journal, operations, intent)
            possible = self._forward_possible_states(
                journal, operations, cursor, intent
            )
            rollback = self._build_rollback(journal, possible)
        else:
            rollback = self._parse_rollback(journal)

        self._validate_artifacts_no_discard(journal)
        for index in range(rollback["cursor"], len(rollback["actions"])):
            self._run_rollback_action(journal, rollback, index)

        originals = {
            key: FileState.from_json(entry["original"])
            for key, entry in journal["targets"].items()
        }
        for key, original in originals.items():
            if not self._same(current_state(self.targets[key], original.mode), original):
                self._record_conflicts(journal, [f"{key}:restore-verification-failed"])
                raise TransactionConflict(
                    f"rollback verification failed; journal retained at {self.journal_path}"
                )
        self._cleanup_directory(journal)
        for key, original in originals.items():
            if current_state(self.targets[key], original.mode) != original:
                raise TransactionRecoveryError(
                    f"rollback did not restore exact inode/link state for {key}"
                )

    def recover_if_needed(self) -> None:
        try:
            exists = self.directory.exists()
        except OSError as exc:
            raise TransactionRecoveryError(
                f"cannot inspect protected transaction directory: {type(exc).__name__}"
            ) from exc
        if not exists:
            if self.directory.is_symlink():
                raise TransactionRecoveryError(
                    f"refusing protected transaction symlink: {self.directory}"
                )
            return
        if self.directory.is_symlink():
            raise TransactionRecoveryError(
                f"refusing protected transaction symlink: {self.directory}"
            )
        if not self.journal_path.exists():
            self._cleanup_incomplete_preparation()
            return
        journal = self._load_journal()
        self._validate_journal_identity(journal)
        status = journal.get("status")
        if status == "preparing":
            conflicts = []
            for key, entry in journal["targets"].items():
                original = FileState.from_json(entry["original"])
                current = current_state(pathlib.Path(entry["path"]), original.mode)
                if not (
                    current == original
                    or (
                        original.existed
                        and state_same_inode_and_bytes(current, original)
                    )
                ):
                    conflicts.append(f"{key}:changed-during-preparation")
            if conflicts:
                self._record_conflicts(journal, conflicts)
                raise TransactionConflict(
                    f"incomplete preparation conflicts with live state; journal retained at {self.journal_path}"
                )
            try:
                self._cleanup_directory(journal)
            except TransactionConflict as exc:
                self._record_conflicts(journal, ["preparing:unsafe-recovery-artifact"])
                raise TransactionConflict(
                    f"incomplete preparation recovery artifact was retained: {exc}"
                ) from exc
            return
        if status == "committed":
            final = {
                key: FileState.from_json(entry["original"])
                for key, entry in journal["targets"].items()
            }
            for operation in journal.get("operations", []):
                final[operation["target"]] = FileState.from_json(operation["desired"])
            conflicts = [
                f"{key}:post-commit-divergence"
                for key, state in final.items()
                if not state_matches(self.targets[key], state)
            ]
            if conflicts:
                self._record_conflicts(journal, conflicts)
                raise TransactionConflict(
                    f"committed generation diverged; journal retained at {self.journal_path}"
                )
            self._cleanup_directory(journal)
            return
        if status not in {"ready", "running", "rolling-back", "conflict"}:
            raise TransactionRecoveryError(f"transaction journal status is invalid: {status}")
        self._operation_states(journal)
        self._rollback(journal)

    def prepare(
        self,
        originals: dict[str, Snapshot],
        specifications: list[tuple[str, str, bytes | None, int]],
    ) -> None:
        if self.directory.exists() or self.directory.is_symlink():
            raise TransactionRecoveryError(
                f"protected transaction directory was not recovered: {self.directory}"
            )
        parent = self.directory.parent
        parent_info = os.lstat(parent)
        if not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode):
            raise TransactionRecoveryError(
                f"transaction parent must be a real directory: {parent}"
            )
        if not directory_is_private_to_user(parent_info):
            raise TransactionRecoveryError(
                f"transaction parent ownership/mode is unsafe: {parent}"
            )
        os.mkdir(self.directory, 0o700)
        os.chmod(self.directory, 0o700)
        fsync_parent(self.directory)
        transaction_id = uuid.uuid4().hex
        targets: dict[str, Any] = {}
        for key, path in self.targets.items():
            original = originals[key].state
            targets[key] = {
                "path": str(path),
                "original": original.to_json(),
                "recovery": f"recovery-{key}" if original.existed else None,
                "rollback_capture": f"rollback-{key}",
                "protected": None,
            }
        self.journal = {
            "schema_version": self.SCHEMA_VERSION,
            "transaction_id": transaction_id,
            "status": "preparing",
            "identity": {
                "profile": str(self.profile),
                "registry": str(self.registry),
                "agent_id": self.agent_id,
                "channel": self.channel,
            },
            "targets": targets,
            "operations": [],
            "cursor": 0,
            "intent": None,
            "conflicts": [],
        }
        self._write_journal()

        transaction_dev = os.lstat(self.directory).st_dev
        for key, path in self.targets.items():
            parent_info = os.lstat(path.parent)
            if not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode):
                raise TransactionRecoveryError(
                    f"transaction target parent is unsafe for {key}: {path.parent}"
                )
            if parent_info.st_dev != transaction_dev or (
                originals[key].existed and originals[key].state.dev != transaction_dev
            ):
                raise TransactionRecoveryError(
                    f"transaction target is on a different filesystem: {path}"
                )

        # Every original recovery inode is created and validated before any
        # target mutation. Recovery links live only in the protected profile
        # journal directory, never beside tracked role files.
        for key, path in self.targets.items():
            original = originals[key]
            if not original.existed:
                continue
            if original.state.nlink != 1:
                raise TransactionRecoveryError(
                    f"transaction target already has a hard-link alias: {path}"
                )
            recovery = self.directory / targets[key]["recovery"]
            os.link(path, recovery, follow_symlinks=False)
            fault_boundary(f"recovery-link:{key}")
            protected_target = current_state(path, original.mode)
            protected_recovery = current_state(recovery, original.mode)
            if (
                not state_same_inode_and_bytes(protected_target, original.state)
                or protected_target.nlink != 2
                or protected_recovery != protected_target
            ):
                raise TransactionConflict(
                    f"transaction target changed while preparing recovery: {path}"
                )
            targets[key]["protected"] = protected_target.to_json()
        fsync_directory(self.directory)
        self._write_journal()

        expected = {
            key: (
                FileState.from_json(targets[key]["protected"])
                if original.existed
                else original.state
            )
            for key, original in originals.items()
        }
        operations: list[dict[str, Any]] = []
        for index, (label, key, content, mode) in enumerate(specifications):
            if key not in self.targets:
                raise TransactionRecoveryError(f"unknown transaction target: {key}")
            prior = expected[key]
            staged_name: str | None = None
            noop = False
            if content is None:
                desired = FileState(False, mode)
                noop = not prior.existed
                kind = "noop" if noop else "delete"
                if noop:
                    desired = prior
                else:
                    staged_name = f"capture-{index:02d}"
            else:
                digest = hashlib.sha256(content).hexdigest()
                if (
                    prior.existed
                    and prior.mode == mode
                    and prior.size == len(content)
                    and prior.sha256 == digest
                ):
                    desired = prior
                    noop = True
                    kind = "noop"
                else:
                    staged_name = f"candidate-{index:02d}"
                    staged = self.directory / staged_name
                    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
                    flags |= getattr(os, "O_NOFOLLOW", 0)
                    fd = os.open(staged, flags, mode)
                    try:
                        os.fchmod(fd, mode)
                        view = memoryview(content)
                        while view:
                            written = os.write(fd, view)
                            view = view[written:]
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                    desired = current_state(staged, mode)
                    if desired.dev != transaction_dev or desired.sha256 != digest:
                        raise TransactionRecoveryError(
                            f"staged transaction candidate validation failed: {label}"
                        )
                    kind = "create" if not prior.existed else "replace"
            operation = {
                "index": index,
                "label": label,
                "target": key,
                "expected": prior.to_json(),
                "desired": desired.to_json(),
                "staged": staged_name,
                "noop": noop,
                "kind": kind,
            }
            operations.append(operation)
            expected[key] = desired
        self.journal["operations"] = operations
        self.journal["status"] = "ready"
        self._write_journal()
        fault_boundary("prepared")

    def execute(self) -> None:
        journal = self.journal
        operations = journal["operations"]
        try:
            journal["status"] = "running"
            self._write_journal()
            for index, operation in enumerate(operations):
                key = operation["target"]
                path = self.targets[key]
                expected = FileState.from_json(operation["expected"])
                desired = FileState.from_json(operation["desired"])
                kind = operation["kind"]
                journal["intent"] = {"index": index, "phase": "before-syscall"}
                self._write_journal()
                fault_boundary(f"intent:{index}:{operation['label']}")
                staged_name = operation.get("staged")
                staged = self.directory / staged_name if isinstance(staged_name, str) else None
                displaced: FileState | None = None
                if kind == "noop":
                    if not state_matches(path, expected):
                        raise TransactionConflict(
                            f"compare-and-swap conflict at no-op {operation['label']}: {path}"
                        )
                elif kind == "create":
                    assert staged is not None
                    if not state_matches(staged, desired):
                        raise TransactionConflict(
                            f"staged candidate changed before {operation['label']}"
                        )
                    try:
                        atomic_move_noreplace(staged, path)
                    except OSError as exc:
                        if exc.errno == errno.EEXIST:
                            raise TransactionConflict(
                                f"compare-and-swap found a new external path at {operation['label']}: {path}"
                            ) from exc
                        raise
                elif kind == "replace":
                    assert staged is not None
                    if not state_matches(staged, desired):
                        raise TransactionConflict(
                            f"staged candidate changed before {operation['label']}"
                        )
                    atomic_exchange(staged, path)
                    displaced = current_state(staged, expected.mode)
                elif kind == "delete":
                    assert staged is not None
                    try:
                        atomic_move_noreplace(path, staged)
                    except OSError as exc:
                        if exc.errno == errno.ENOENT:
                            raise TransactionConflict(
                                f"compare-and-swap found a missing external path at {operation['label']}: {path}"
                            ) from exc
                        if exc.errno == errno.EEXIST:
                            raise TransactionRecoveryError(
                                f"protected capture slot already exists: {staged}"
                            ) from exc
                        raise
                    displaced = current_state(staged, expected.mode)
                else:
                    raise TransactionRecoveryError(
                        f"transaction operation kind is invalid: {kind}"
                    )
                if kind != "noop":
                    fsync_parent(path)
                    fsync_directory(self.directory)
                    journal["intent"] = {"index": index, "phase": "captured"}
                    self._write_journal()
                    fault_boundary(f"capture:{index}:{operation['label']}")

                if displaced is not None and displaced != expected:
                    # The atomic syscall captured an out-of-band inode. Reverse
                    # only through another atomic primitive; if a newer path
                    # appeared meanwhile, retain both artifacts and fail.
                    journal["intent"] = {"index": index, "phase": "reversing"}
                    self._write_journal()
                    fault_boundary(f"reverse-intent:{index}:{operation['label']}")
                    if kind == "replace":
                        atomic_exchange(staged, path)
                        reversed_slot = current_state(staged, desired.mode)
                        reversed_target = current_state(path, displaced.mode)
                        reversed_ok = (
                            reversed_slot == desired and reversed_target == displaced
                        )
                    else:
                        try:
                            atomic_move_noreplace(staged, path)
                        except OSError as exc:
                            if exc.errno == errno.EEXIST:
                                reversed_ok = False
                            else:
                                raise
                        else:
                            reversed_ok = state_matches(path, displaced) and not staged.exists()
                    fsync_parent(path)
                    fsync_directory(self.directory)
                    journal["intent"] = {"index": index, "phase": "reversed"}
                    self._write_journal()
                    fault_boundary(f"reverse:{index}:{operation['label']}")
                    if not reversed_ok:
                        raise TransactionConflict(
                            f"external state changed during atomic CAS reversal at {operation['label']}; protected artifacts retained"
                        )
                    raise TransactionConflict(
                        f"atomic compare-and-swap preserved external state at {operation['label']}: {path}"
                    )
                fault_boundary(f"write:{index}:{operation['label']}")
                if not state_matches(path, desired):
                    raise TransactionConflict(
                        f"transaction write verification failed for {operation['label']}: {path}"
                    )
                journal["cursor"] = index + 1
                journal["intent"] = None
                self._write_journal()
                fault_boundary(f"commit:{index}:{operation['label']}")
            journal["status"] = "committed"
            self._write_journal()
            fault_boundary("transaction-committed")
            self._cleanup_directory(journal)
        except BaseException:
            if journal.get("status") != "committed":
                self._rollback(journal)
            raise


def load_mapping(path: pathlib.Path, *, required: bool = True) -> dict:
    if path.is_symlink() or (required and not path.is_file()):
        fail(f"required mapping is unavailable: {path}")
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        fail(f"mapping root required: {path}")
    return data


def load_snapshot_mapping(
    path: pathlib.Path, original: Snapshot, *, required: bool = True
) -> dict:
    if not original.existed:
        if required:
            fail(f"required mapping is unavailable: {path}")
        return {}
    try:
        data = yaml.safe_load(original.content.decode("utf-8")) or {}
    except (UnicodeError, yaml.YAMLError) as exc:
        fail(f"invalid mapping snapshot {path}: {type(exc).__name__}")
    if not isinstance(data, dict):
        fail(f"mapping root required: {path}")
    return data


def plain_merge(base: dict, override: dict) -> dict:
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = plain_merge(result[key], value)
        elif key in result and isinstance(result[key], dict) and value is None:
            continue
        else:
            result[key] = copy.deepcopy(value)
    return result


def apply_list_patches(result: dict, directive: object) -> None:
    if directive is None:
        return
    if not isinstance(directive, dict) or not isinstance(directive.get("list_patches", {}), dict):
        fail(f"{LIST_PATCH_KEY}.list_patches must be a mapping")
    for dotted, rule in directive.get("list_patches", {}).items():
        if not isinstance(dotted, str) or not dotted or not isinstance(rule, dict):
            fail("invalid list patch")
        additions = rule.get("add", []) or []
        removals = rule.get("remove", []) or []
        if not isinstance(additions, list) or not isinstance(removals, list) or not all(
            isinstance(item, str) for item in [*additions, *removals]
        ):
            fail(f"list patch for {dotted} must contain string lists")
        cursor = result
        parts = dotted.split(".")
        for part in parts[:-1]:
            child = cursor.setdefault(part, {})
            if not isinstance(child, dict):
                fail(f"list patch parent for {dotted} is not a mapping")
            cursor = child
        current = cursor.get(parts[-1], []) or []
        if not isinstance(current, list):
            fail(f"list patch target {dotted} is not a list")
        removed = set(removals)
        merged = [item for item in current if item not in removed]
        for item in additions:
            if item not in merged:
                merged.append(item)
        cursor[parts[-1]] = merged


def merge(base: dict, delta: dict) -> dict:
    ordinary = {key: value for key, value in delta.items() if key != LIST_PATCH_KEY}
    result = plain_merge(base, ordinary)
    apply_list_patches(result, delta.get(LIST_PATCH_KEY))
    return result


def delta_comments(original: bytes) -> list[str]:
    comments: list[str] = []
    for line in original.decode("utf-8").splitlines() if original else []:
        if line.lstrip().startswith("#") and line not in comments:
            comments.append(line)
    standard = [
        "# Override-only delta for this Hermes profile.",
        "# Contains configuration and secret references only; secret values remain in 1Password.",
    ]
    return [*standard, *(line for line in comments if line not in standard)]


def render_delta(delta: dict, original: bytes) -> bytes:
    return (
        "\n".join(delta_comments(original))
        + "\n"
        + yaml.safe_dump(delta, sort_keys=False)
    ).encode("utf-8")


def render_generated(base: dict, delta: dict) -> bytes:
    header = (
        "# GENERATED FILE -- DO NOT EDIT.\n"
        "# source: fleet config.yaml + profile config.delta.yaml\n"
    )
    return (header + yaml.safe_dump(merge(base, delta), sort_keys=False)).encode("utf-8")


def update_role(original: bytes, channel: str, metadata: dict[str, str]) -> bytes:
    text = original.decode("utf-8")
    match = re.search(
        rf"(?ms)^{re.escape(channel)}:\s*\n(?P<body>(?:^[ \t]+.*\n?)*)", text
    )
    if not match:
        fail(f"{channel} metadata block missing from role.yaml")
    body = match.group("body")
    for key in CHANNEL_FIELDS[channel]:
        value = metadata[key]
        replacement = f"  {key}: {json.dumps(value)}"
        body, count = re.subn(
            rf"(?m)^\s+{re.escape(key)}:\s*.*$", lambda _: replacement, body, count=1
        )
        if count == 0:
            if body and not body.endswith("\n"):
                body += "\n"
            body += replacement + "\n"
    return (text[: match.start("body")] + body + text[match.end("body") :]).encode(
        "utf-8"
    )


def update_role_status(original: bytes, channel: str, status_value: str) -> bytes:
    text = original.decode("utf-8")
    match = re.search(
        rf"(?ms)^{re.escape(channel)}:\s*\n(?P<body>(?:^[ \t]+.*\n?)*)", text
    )
    if not match:
        fail(f"{channel} metadata block missing from role.yaml")
    body = match.group("body")
    replacement = f"  provisioning_status: {json.dumps(status_value)}"
    body, count = re.subn(
        r"(?m)^\s+provisioning_status:\s*.*$", lambda _: replacement, body, count=1
    )
    if count == 0:
        if body and not body.endswith("\n"):
            body += "\n"
        body += replacement + "\n"
    return (text[: match.start("body")] + body + text[match.end("body") :]).encode(
        "utf-8"
    )


def update_runtime_env(original: bytes, channel: str, allowed_value: str) -> bytes:
    text = original.decode("utf-8") if original else ""
    keys = [*CHANNEL_REFERENCE_KEYS[channel], CHANNEL_ALLOWED_KEYS[channel]]
    for key in keys:
        text = re.sub(
            rf"(?m)^\s*(?:export\s+)?#?\s*{re.escape(key)}\s*=.*(?:\n|$)",
            "",
            text,
        )
    text = text.rstrip("\n")
    if text:
        text += "\n"
    text += f"{CHANNEL_ALLOWED_KEYS[channel]}={json.dumps(allowed_value)}\n"
    return text.encode("utf-8")


def snapshot_allowed_value(original: Snapshot, channel: str) -> str:
    """Read the active nonsecret policy from the same locked transaction snapshot."""

    if not original.existed:
        return ""
    try:
        text = original.content.decode("utf-8")
    except UnicodeError as exc:
        fail(f"invalid {channel} runtime policy encoding: {type(exc).__name__}")
    key = CHANNEL_ALLOWED_KEYS[channel]
    match = re.search(
        rf"(?m)^\s*(?:export\s+)?{re.escape(key)}\s*=\s*(.*)$", text
    )
    if not match:
        return ""
    serialized = match.group(1).strip()
    try:
        value = json.loads(serialized)
    except json.JSONDecodeError:
        if len(serialized) >= 2 and serialized[0] == serialized[-1] == "'":
            value = serialized[1:-1]
        else:
            value = serialized
    if not isinstance(value, str) or any(character in value for character in "\r\n\0"):
        fail(f"invalid {channel} runtime allow-list policy")
    return value


def merge_managed(current: dict, update: dict) -> dict:
    result = copy.deepcopy(current)
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_managed(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def update_registry(
    original: bytes,
    channel: str,
    agent_id: str,
    role_dir: str,
    profile_name: str,
    metadata: dict[str, str],
) -> bytes:
    try:
        data = yaml.safe_load(original.decode("utf-8")) if original else None
    except (UnicodeError, yaml.YAMLError) as exc:
        fail(f"cannot safely inspect {channel} ownership registry: {type(exc).__name__}")
    data = data or {"schema_version": 1, "agents": {}}
    if not isinstance(data, dict) or not isinstance(data.get("agents", {}), dict):
        fail(f"cannot safely inspect {channel} ownership registry: invalid agents mapping")
    agents = data.setdefault("agents", {})
    for other_id, entry in agents.items():
        if other_id == agent_id or not isinstance(entry, dict):
            continue
        claim = entry.get(channel) or {}
        if not isinstance(claim, dict):
            continue
        if channel == "telegram" and str(claim.get("bot_id") or "") == metadata["bot_id"]:
            fail(f"Telegram bot identity is already assigned to agent {other_id}")
        if channel == "slack":
            same_bot = claim.get("bot_id") == metadata["bot_id"]
            same_team_user = (
                claim.get("team_id") == metadata["team_id"]
                and claim.get("bot_user_id") == metadata["bot_user_id"]
            )
            if same_bot or same_team_user:
                fail(f"Slack bot identity is already assigned to agent {other_id}")
    existing = agents.get(agent_id, {})
    if not isinstance(existing, dict):
        fail(f"registry entry for {agent_id} is not a mapping")
    managed = {
        "role_dir": role_dir,
        "profile_name": profile_name,
        channel: metadata,
    }
    updated = merge_managed(existing, managed)
    if updated == existing:
        return original
    agents[agent_id] = updated
    return yaml.safe_dump(data, sort_keys=False).encode("utf-8")


def parse_pairs(values: list[list[str]], expected: tuple[str, ...], label: str) -> dict[str, str]:
    pairs: dict[str, str] = {}
    for key, value in values:
        if key in pairs:
            fail(f"duplicate {label} key: {key}")
        pairs[key] = value
    if tuple(pairs) != expected:
        fail(f"{label} keys must be exactly: {', '.join(expected)}")
    return pairs


def existing_wiring(
    args: argparse.Namespace,
    originals: dict[pathlib.Path, Snapshot],
    delta_path: pathlib.Path,
    role_path: pathlib.Path,
) -> tuple[dict[str, str], dict[str, str]]:
    channel = args.channel
    role = load_snapshot_mapping(role_path, originals[role_path])
    role_channel = role.get(channel)
    if not isinstance(role_channel, dict) or role_channel.get("provisioning_status") != "verified":
        raise ExistingWiringUnavailable

    metadata: dict[str, str] = {}
    for key in CHANNEL_FIELDS[channel]:
        value = role_channel.get(key, "")
        if not isinstance(value, (str, int)) or isinstance(value, bool):
            fail(f"verified {channel} metadata field {key} is invalid")
        rendered = str(value)
        if key != "team_name" and not rendered:
            fail(f"verified {channel} metadata field {key} is missing")
        metadata[key] = rendered

    delta = load_snapshot_mapping(delta_path, originals[delta_path])
    try:
        secret_env = delta["secrets"]["onepassword"]["env"]
    except (KeyError, TypeError):
        fail(f"verified {channel} wiring has no 1Password environment mapping")
    if not isinstance(secret_env, dict):
        fail(f"verified {channel} 1Password environment mapping is invalid")
    references: dict[str, str] = {}
    for name in CHANNEL_REFERENCE_KEYS[channel]:
        reference = secret_env.get(name, "")
        if (
            not isinstance(reference, str)
            or not reference.startswith("op://")
            or any(character in reference for character in "\r\n\0")
        ):
            fail(f"verified {channel} reference {name} is missing or invalid")
        references[name] = reference

    validator = pathlib.Path(args.reference_validator or "")
    if validator.is_symlink() or not validator.is_file():
        raise ExistingWiringValidationUnavailable
    for reference in references.values():
        try:
            result = subprocess.run(
                [sys.executable, "-I", str(validator), "--validate-reference", reference],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ExistingWiringValidationUnavailable from exc
        if result.returncode != 0:
            raise ExistingWiringValidationUnavailable
    return references, metadata


def prepare_unconfigured(
    args: argparse.Namespace,
    originals: dict[str, Snapshot],
    delta_path: pathlib.Path,
    generated_path: pathlib.Path,
    base_path: pathlib.Path,
    role_path: pathlib.Path,
    marker_key: str,
    transaction: CrashConsistentTransaction,
    modes: dict[str, int],
) -> None:
    """Durably disable a never-verified channel without touching valid wiring."""

    role = load_snapshot_mapping(role_path, originals["role"])
    role_channel = role.get(args.channel)
    if isinstance(role_channel, dict) and role_channel.get("provisioning_status") == "verified":
        raise ExistingWiringAlreadyVerified

    base = load_mapping(base_path)
    delta = load_snapshot_mapping(delta_path, originals["delta"], required=False)
    platforms = delta.setdefault("platforms", {})
    if not isinstance(platforms, dict):
        fail("platforms delta must be a mapping")
    platform = platforms.setdefault(args.channel, {})
    if not isinstance(platform, dict):
        fail(f"platforms.{args.channel} delta must be a mapping")
    platform["enabled"] = False
    delta_content = render_delta(delta, originals["delta"].content)
    generated_content = render_generated(base, delta)
    role_content = update_role_status(
        originals["role"].content, args.channel, "deferred"
    )
    run_transaction(
        transaction,
        originals,
        [
            ("deferred-delta", "delta", delta_content, modes["delta"]),
            ("deferred-generated", "generated", generated_content, modes["generated"]),
            ("deferred-role", "role", role_content, originals["role"].mode),
            ("deferred-marker", marker_key, None, modes[marker_key]),
        ],
    )


def run_transaction(
    transaction: CrashConsistentTransaction,
    originals: dict[str, Snapshot],
    specifications: list[tuple[str, str, bytes | None, int]],
) -> None:
    try:
        transaction.prepare(originals, specifications)
        transaction.execute()
    except BaseException as exc:
        if transaction.directory.exists() and not isinstance(
            exc, (KeyboardInterrupt, SystemExit, TransactionConflict)
        ):
            try:
                transaction.recover_if_needed()
            except TransactionConflict:
                raise
        if (
            not transaction.directory.exists()
            and not isinstance(exc, (KeyboardInterrupt, SystemExit, TransactionConflict))
        ):
            raise TransactionRecoveryError(
                f"{exc}; all local channel files restored"
            ) from exc
        raise


def commit_locked(args: argparse.Namespace) -> None:
    channel = args.channel
    profile = pathlib.Path(args.profile)
    if profile.is_symlink() or not profile.is_dir():
        fail(f"profile root must be a real directory: {profile}")
    delta_path = profile / "config.delta.yaml"
    generated_path = profile / "config.yaml"
    base_path = profile.parent.parent / "config.yaml"
    role_path = pathlib.Path(args.role_yaml)
    registry_path = pathlib.Path(args.registry)
    env_path = pathlib.Path(args.runtime_env)
    marker_path = pathlib.Path(args.done_marker)
    expected_marker = role_path.parent / ".scripts" / f".done-{'30-telegram' if channel == 'telegram' else '31-slack'}"
    if marker_path != expected_marker:
        fail(f"done marker does not match the {channel} role contract")
    if (args.reconcile_existing or args.prepare_unconfigured) and (
        args.reference or args.metadata
    ):
        fail("snapshot-derived transaction modes do not accept reference inputs")
    if not args.reconcile_existing and not args.prepare_unconfigured:
        references = parse_pairs(
            args.reference, CHANNEL_REFERENCE_KEYS[channel], "reference"
        )
        metadata = parse_pairs(args.metadata, CHANNEL_FIELDS[channel], "metadata")
        if metadata["provisioning_status"] != "verified" or any(
            not metadata[key] for key in CHANNEL_FIELDS[channel] if key != "team_name"
        ):
            fail(f"{channel} verified metadata is incomplete")
        for reference in references.values():
            if not reference.startswith("op://") or any(
                ch in reference for ch in "\r\n\0"
            ):
                fail("invalid 1Password reference")

    targets = {
        "delta": delta_path,
        "generated": generated_path,
        "role": role_path,
        "registry": registry_path,
        "runtime_env": env_path,
        "telegram_marker": role_path.parent / ".scripts" / ".done-30-telegram",
        "slack_marker": role_path.parent / ".scripts" / ".done-31-slack",
    }
    modes = {
        "delta": 0o600,
        "generated": 0o600,
        "role": 0o644,
        "registry": 0o600,
        "runtime_env": 0o600,
        "telegram_marker": 0o600,
        "slack_marker": 0o600,
    }
    transaction = CrashConsistentTransaction(
        profile=profile,
        registry=registry_path,
        channel=channel,
        agent_id=args.agent_id,
        targets=targets,
        modes=modes,
    )
    transaction.recover_if_needed()
    originals = {key: snapshot(path, modes[key]) for key, path in targets.items()}
    originals_by_path = {path: originals[key] for key, path in targets.items()}
    marker_key = f"{channel}_marker"
    if args.prepare_unconfigured:
        PROFILE_LOCK.test_snapshot_barrier(f"channel-prepare:{channel}")
        prepare_unconfigured(
            args,
            originals,
            delta_path,
            generated_path,
            base_path,
            role_path,
            marker_key,
            transaction,
            modes,
        )
        return
    PROFILE_LOCK.test_snapshot_barrier(f"channel:{channel}")
    if args.reconcile_existing:
        references, metadata = existing_wiring(
            args, originals_by_path, delta_path, role_path
        )
        allowed_value = snapshot_allowed_value(originals["runtime_env"], channel)
    else:
        allowed_value = args.allowed_value
    base = load_mapping(base_path)
    delta = load_snapshot_mapping(delta_path, originals["delta"], required=False)
    onepassword = delta.setdefault("secrets", {}).setdefault("onepassword", {})
    if not isinstance(onepassword, dict):
        fail("secrets.onepassword delta must be a mapping")
    onepassword["enabled"] = True
    secret_env = onepassword.setdefault("env", {})
    if not isinstance(secret_env, dict):
        fail("secrets.onepassword.env delta must be a mapping")
    secret_env.update(references)
    platforms = delta.setdefault("platforms", {})
    if not isinstance(platforms, dict):
        fail("platforms delta must be a mapping")
    platform = platforms.setdefault(channel, {})
    if not isinstance(platform, dict):
        fail(f"platforms.{channel} delta must be a mapping")
    platform["enabled"] = False

    disabled_delta = render_delta(delta, originals["delta"].content)
    disabled_generated = render_generated(base, delta)
    role_content = update_role(originals["role"].content, channel, metadata)
    env_content = update_runtime_env(originals["runtime_env"].content, channel, allowed_value)
    registry_content = update_registry(
        originals["registry"].content,
        channel,
        args.agent_id,
        args.role_dir,
        args.profile_name,
        metadata,
    )
    platform["enabled"] = True
    enabled_delta = render_delta(delta, originals["delta"].content)
    enabled_generated = render_generated(base, delta)
    run_transaction(
        transaction,
        originals,
        [
            ("disabled-delta", "delta", disabled_delta, modes["delta"]),
            ("disabled-generated", "generated", disabled_generated, modes["generated"]),
            ("runtime-policy", "runtime_env", env_content, modes["runtime_env"]),
            ("role-identity", "role", role_content, originals["role"].mode),
            ("registry-identity", "registry", registry_content, modes["registry"]),
            ("enabled-delta", "delta", enabled_delta, modes["delta"]),
            ("enabled-generated", "generated", enabled_generated, modes["generated"]),
            ("completion-marker", marker_key, b"", originals[marker_key].mode),
        ],
    )


def commit(args: argparse.Namespace) -> None:
    profile = pathlib.Path(args.profile)
    registry = pathlib.Path(args.registry)
    try:
        # The helper owns this order. During migration, RegistryLock can adopt
        # the exact inherited lock description held by an unchanged shell
        # caller; direct invocation still acquires and validates it itself.
        with RegistryLock(registry):
            with PROFILE_LOCK.ProfileConfigLock(profile):
                commit_locked(args)
    except ExistingWiringUnavailable as exc:
        raise SystemExit(2) from exc
    except ExistingWiringValidationUnavailable as exc:
        raise SystemExit(75) from exc
    except ExistingWiringAlreadyVerified as exc:
        raise SystemExit(3) from exc
    except PROFILE_LOCK.ProfileConfigLockError as exc:
        fail(str(exc))
    except (OSError, TransactionConflict, TransactionRecoveryError) as exc:
        fail(str(exc))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--channel", choices=tuple(CHANNEL_FIELDS), required=True)
    result.add_argument("--profile", required=True)
    result.add_argument("--role-yaml", required=True)
    result.add_argument("--registry", required=True)
    result.add_argument("--runtime-env", required=True)
    result.add_argument("--done-marker", required=True)
    result.add_argument("--agent-id", required=True)
    result.add_argument("--role-dir", required=True)
    result.add_argument("--profile-name", required=True)
    result.add_argument("--allowed-value", default="")
    mode = result.add_mutually_exclusive_group()
    mode.add_argument("--reconcile-existing", action="store_true")
    mode.add_argument("--prepare-unconfigured", action="store_true")
    result.add_argument("--reference-validator")
    result.add_argument("--reference", nargs=2, action="append", default=[])
    result.add_argument("--metadata", nargs=2, action="append", default=[])
    return result


if __name__ == "__main__":
    commit(parser().parse_args())
