#!/usr/bin/env python3
"""Seed a named profile's override delta under the shared profile lock."""

from __future__ import annotations

import argparse
import errno
import importlib.util
import os
import pathlib
import stat
import tempfile

SEED_CONTENT = (
    "# Override-only delta for this Hermes profile.\n"
    "# Merged over ~/.hermes/config.yaml to produce config.yaml (which is GENERATED).\n"
    "# Empty == identical to the fleet base. Add ONLY what must differ.\n"
    "{}\n"
).encode("utf-8")


def load_profile_lock_module():
    source = pathlib.Path(__file__).parent / "profile-config-lock.py"
    if source.is_symlink() or not source.is_file():
        raise RuntimeError(
            f"trusted profile config lock helper is unavailable: {source}"
        )
    spec = importlib.util.spec_from_file_location(
        "pjangler_profile_config_lock", source
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load profile config lock helper: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROFILE_LOCK = load_profile_lock_module()


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


def seed(profile: pathlib.Path) -> str:
    with PROFILE_LOCK.ProfileConfigLock(profile):
        PROFILE_LOCK.test_snapshot_barrier("seed")
        if profile.is_symlink() or not profile.is_dir():
            raise RuntimeError(f"profile root must be a real directory: {profile}")
        target = profile / "config.delta.yaml"
        if target.is_symlink():
            raise RuntimeError(f"refusing config delta symlink: {target}")
        if target.exists():
            if not target.is_file():
                raise RuntimeError(f"config delta is not a regular file: {target}")
            return "exists"

        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".config.delta.yaml.seed-", dir=profile
        )
        temporary = pathlib.Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(SEED_CONTENT)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target)
            os.chmod(target, stat.S_IRUSR | stat.S_IWUSR)
            fsync_parent(target)
        except BaseException:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
            raise
        return "seeded"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        print(seed(pathlib.Path(args.profile)))
    except PROFILE_LOCK.ProfileConfigLockError as exc:
        raise SystemExit(f"profile config seed failed: {exc}") from exc
    except (OSError, RuntimeError) as exc:
        raise SystemExit(f"profile config seed failed: {exc}") from exc


if __name__ == "__main__":
    main()
