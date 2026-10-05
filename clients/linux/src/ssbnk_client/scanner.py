from __future__ import annotations

import hashlib
import os
import shutil
import time
from pathlib import Path

from .config import Configuration, private_directory
from .store import Capture, Identity, Store

IMAGES = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
VIDEOS = {".mp4", ".avi", ".mov", ".mkv", ".webm", ".flv", ".wmv"}
STAGING_BUDGET = 4 * 1024**3
FREE_FLOOR = 512 * 1024**2


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while data := source.read(1024 * 1024):
            digest.update(data)
    return digest.hexdigest()


class Scanner:
    def __init__(self, store: Store, outbox: Path) -> None:
        self.store = store
        self.outbox = private_directory(outbox)
        known = {capture.uuid for capture in store.captures()}
        for directory in self.outbox.iterdir():
            if directory.name not in known or not directory.is_dir() or directory.is_symlink():
                raise ValueError("Unclaimed outbox storage requires repair; stages were preserved")
        self.samples: dict[str, tuple[Identity, float]] = {}
        self.root_errors: dict[str, str] = {}

    @staticmethod
    def files(root: Path, kinds: set[str]) -> list[tuple[Identity, str]]:
        captures = []
        for path in sorted(root.iterdir()):
            if path.name.startswith(".") or path.is_symlink():
                continue
            kind = (
                "image"
                if path.suffix.lower() in IMAGES
                else "video"
                if path.suffix.lower() in VIDEOS
                else None
            )
            if kind is None or kind not in kinds:
                continue
            try:
                captures.append((Identity.current(path), kind))
            except (OSError, ValueError):
                continue
        return captures

    def reconcile(
        self,
        configuration: Configuration,
        existing: bool = False,
        existing_identities: set[str] | None = None,
    ) -> None:
        self.root_errors.clear()
        for root, kinds in configuration.roots().items():
            try:
                captures = self.files(root, kinds)
                for kind in kinds:
                    if not self.store.has_coverage(root, kind):
                        self.store.baseline(
                            root, kind, [identity for identity, media in captures if media == kind]
                        )
                captures = self.files(root, kinds)
                for identity, kind in captures:
                    backfill = existing or identity.key in (existing_identities or set())
                    if self.store.known(identity, include_baseline=backfill):
                        continue
                    previous = self.samples.get(identity.path)
                    if previous is None or previous[0] != identity:
                        self.samples[identity.path] = (identity, time.monotonic())
                        continue
                    required = 0.3 if kind == "image" else 3
                    if time.monotonic() - previous[1] < required:
                        continue
                    self.store.observe(identity, kind, configuration.api_origin, not backfill)
            except OSError:
                self.root_errors[str(root)] = (
                    "Capture folder unavailable; check path and permissions"
                )
        for capture in self.store.captures():
            if capture.phase == "deferred":
                self.stage(capture)

    def stage(self, capture: Capture) -> None:
        source = Path(capture.identity.path)
        try:
            if Identity.current(source) != capture.identity:
                self.store.transition(capture.uuid, phase="error", error="Deferred source changed")
                return
        except (OSError, ValueError):
            self.store.transition(capture.uuid, phase="error", error="Deferred source missing")
            return
        if capture.identity.size > (50 * 1024**2 if capture.kind == "image" else 1024**3):
            self.store.transition(
                capture.uuid, phase="error", error="Capture exceeds media input limit"
            )
            return
        reserved = self.store.reserved_bytes()
        directory = self.outbox / capture.uuid
        temporary = directory / ".stage"
        stage = directory / "capture"
        if capture.staged_path:
            if Path(capture.staged_path) != stage:
                self.store.transition(
                    capture.uuid, phase="error", error="Unsafe stage path; repair required"
                )
                return
            allocated = sum(path.stat().st_size for path in (temporary, stage) if path.exists())
            if allocated:
                self.store.transition(
                    capture.uuid, phase="error", error="Interrupted stage retained; repair required"
                )
                return
            reserved -= capture.identity.size
        available = shutil.disk_usage(self.outbox).free
        if (
            capture.identity.size > STAGING_BUDGET - reserved
            or available < capture.identity.size + FREE_FLOOR
        ):
            self.store.transition(
                capture.uuid, error="Staging deferred: free space or 4 GiB budget"
            )
            return
        directory = private_directory(directory)
        self._sync(self.outbox)
        self.store.transition(capture.uuid, staged_path=str(stage))
        try:
            digest = hashlib.sha256()
            written = 0
            with source.open("rb") as input_file, temporary.open("wb") as output:
                temporary.chmod(0o600)
                while data := input_file.read(
                    min(1024 * 1024, capture.identity.size - written + 1)
                ):
                    written += len(data)
                    if written > capture.identity.size:
                        raise ValueError("Source grew while staging")
                    output.write(data)
                    digest.update(data)
                output.flush()
                os.fsync(output.fileno())
            if (
                written != capture.identity.size
                or Identity.current(source) != capture.identity
                or file_hash(source) != digest.hexdigest()
            ):
                raise ValueError("Source changed while staging")
            os.replace(temporary, stage)
            self._sync(directory)
            self.store.transition(
                capture.uuid, phase="queued", sha256=digest.hexdigest(), error=None
            )
        except (OSError, ValueError) as error:
            temporary.unlink(missing_ok=True)
            self.store.transition(capture.uuid, phase="error", error=str(error))

    @staticmethod
    def _sync(directory: Path) -> None:
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def recover_stage(self, capture: Capture) -> bool:
        if capture.phase == "ready":
            return False
        stage = Path(capture.staged_path) if capture.staged_path else None
        expected = self.outbox / capture.uuid / "capture"
        if stage and (stage != expected or stage.is_symlink()):
            self.store.transition(
                capture.uuid, phase="error", error="Unsafe stage path; preserved for repair"
            )
            return False
        if stage and stage.exists():
            if not capture.sha256:
                self.store.transition(
                    capture.uuid, phase="error", error="Unverified stage requires repair"
                )
                return False
            if stage.stat().st_size == capture.identity.size and file_hash(stage) == capture.sha256:
                return True
            self.store.transition(
                capture.uuid, phase="error", error="Staged bytes changed; repair required"
            )
            return False
        try:
            if Identity.current(Path(capture.identity.path)) != capture.identity:
                raise ValueError("Original changed")
        except (OSError, ValueError):
            self.store.transition(
                capture.uuid,
                phase="error",
                error="Missing stage and unchanged original unavailable",
            )
            return False
        self.store.transition(capture.uuid, phase="deferred", staged_path=None)
        self.stage(self.store.get(capture.uuid))
        recovered = self.store.get(capture.uuid)
        if capture.sha256 and recovered.sha256 != capture.sha256:
            self.store.transition(
                capture.uuid, phase="error", error="Rebuilt stage differs from pinned input hash"
            )
            return False
        return recovered.phase == "queued"
