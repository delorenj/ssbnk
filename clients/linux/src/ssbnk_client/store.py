from __future__ import annotations

import json
import sqlite3
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .config import StateError, private_directory


@dataclass(frozen=True)
class Identity:
    path: str
    size: int
    modified_ns: int
    device: int
    inode: int

    @classmethod
    def current(cls, path: Path) -> Identity:
        resolved = path.resolve(strict=True)
        stat = resolved.stat()
        if not resolved.is_file() or stat.st_size <= 0:
            raise ValueError("Capture is not a nonempty regular file")
        return cls(str(resolved), stat.st_size, stat.st_mtime_ns, stat.st_dev, stat.st_ino)

    @property
    def key(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class Capture:
    uuid: str
    identity: Identity
    kind: str
    capture_time: float
    order: int
    origin: str
    profile: str
    phase: str
    staged_path: str | None
    sha256: str | None
    offset: int
    attempt: int
    next_attempt: float
    error: str | None
    receipt: dict[str, Any] | None
    auto_copy: bool
    copy_consumed: bool
    copy_warning: str | None


class Store:
    def __init__(self, path: Path) -> None:
        private_directory(path.parent)
        self.connection = sqlite3.connect(path, timeout=5)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA synchronous=FULL")
        version = self.connection.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, 2):
            self.connection.close()
            raise StateError(f"Unsupported ledger version {version}; preserved for repair")
        if version == 0:
            tables = self.connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
            if tables:
                raise StateError("Unversioned ledger is not empty; preserved for repair")
            self.connection.executescript("""
                BEGIN IMMEDIATE;
                CREATE TABLE coverage(root TEXT, kind TEXT, PRIMARY KEY(root,kind));
                CREATE TABLE baseline(identity TEXT PRIMARY KEY, root TEXT, kind TEXT);
                CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE captures(
                    uuid TEXT PRIMARY KEY, identity TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK(kind IN ('image','video')),
                    capture_time REAL NOT NULL, capture_order INTEGER NOT NULL UNIQUE,
                    origin TEXT NOT NULL, profile TEXT NOT NULL,
                    phase TEXT NOT NULL CHECK(phase IN
                        ('deferred','queued','uploading','verifying','processing','ready','error')),
                    staged_path TEXT, sha256 TEXT, offset INTEGER NOT NULL DEFAULT 0,
                    attempt INTEGER NOT NULL DEFAULT 1, next_attempt REAL NOT NULL DEFAULT 0,
                    error TEXT, receipt TEXT, auto_copy INTEGER NOT NULL,
                    copy_consumed INTEGER NOT NULL DEFAULT 0, copy_warning TEXT
                );
                INSERT INTO settings VALUES('revision','0');
                INSERT INTO settings VALUES('copy_fence','0');
                INSERT INTO settings VALUES('handover','pending');
                PRAGMA user_version=2;
                COMMIT;
            """)
        if self.connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise StateError("SQLite ledger integrity check failed; preserved for repair")
        path.chmod(0o600)

    def close(self) -> None:
        self.connection.close()

    @contextmanager
    def transaction(self) -> Iterator[None]:
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.connection.execute(
                "UPDATE settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'"
            )
            self.connection.commit()
        except BaseException:
            self.connection.rollback()
            raise

    def setting(self, key: str, default: str = "") -> str:
        row = self.connection.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return str(row[0]) if row else default

    def set_setting(self, key: str, value: str) -> None:
        with self.transaction():
            self.connection.execute(
                "INSERT INTO settings VALUES(?,?) ON CONFLICT(key) "
                "DO UPDATE SET value=excluded.value",
                (key, value),
            )

    def has_coverage(self, root: Path, kind: str) -> bool:
        return (
            self.connection.execute(
                "SELECT 1 FROM coverage WHERE root=? AND kind=?", (str(root), kind)
            ).fetchone()
            is not None
        )

    def baseline(self, root: Path, kind: str, identities: list[Identity]) -> None:
        with self.transaction():
            self.connection.executemany(
                "INSERT OR IGNORE INTO baseline VALUES(?,?,?)",
                [(identity.key, str(root), kind) for identity in identities],
            )
            self.connection.execute("INSERT OR IGNORE INTO coverage VALUES(?,?)", (str(root), kind))

    def known(self, identity: Identity, include_baseline: bool = False) -> bool:
        if self.connection.execute(
            "SELECT 1 FROM captures WHERE identity=?", (identity.key,)
        ).fetchone():
            return True
        return (
            not include_baseline
            and self.connection.execute(
                "SELECT 1 FROM baseline WHERE identity=?", (identity.key,)
            ).fetchone()
            is not None
        )

    def observe(self, identity: Identity, kind: str, origin: str, auto_copy: bool) -> Capture:
        with self.transaction():
            order = self.connection.execute(
                "SELECT COALESCE(MAX(capture_order),0)+1 FROM captures"
            ).fetchone()[0]
            identifier = str(uuid.uuid4())
            self.connection.execute(
                """INSERT INTO captures(uuid,identity,kind,capture_time,capture_order,origin,
                profile,phase,auto_copy) VALUES(?,?,?,?,?,?,?,'deferred',?)""",
                (
                    identifier,
                    identity.key,
                    kind,
                    identity.modified_ns / 1e9,
                    order,
                    origin,
                    "original" if kind == "image" else "gif-30s-10fps-640",
                    int(auto_copy),
                ),
            )
        return self.get(identifier)

    @staticmethod
    def _capture(row: sqlite3.Row) -> Capture:
        return Capture(
            uuid=row["uuid"],
            identity=Identity(**json.loads(row["identity"])),
            kind=row["kind"],
            capture_time=row["capture_time"],
            order=row["capture_order"],
            origin=row["origin"],
            profile=row["profile"],
            phase=row["phase"],
            staged_path=row["staged_path"],
            sha256=row["sha256"],
            offset=row["offset"],
            attempt=row["attempt"],
            next_attempt=row["next_attempt"],
            error=row["error"],
            receipt=json.loads(row["receipt"]) if row["receipt"] else None,
            auto_copy=bool(row["auto_copy"]),
            copy_consumed=bool(row["copy_consumed"]),
            copy_warning=row["copy_warning"],
        )

    def get(self, identifier: str) -> Capture:
        row = self.connection.execute(
            "SELECT * FROM captures WHERE uuid=?", (identifier,)
        ).fetchone()
        if row is None:
            raise StateError("Capture no longer exists in durable ledger")
        return self._capture(row)

    def captures(self) -> list[Capture]:
        return [
            self._capture(row)
            for row in self.connection.execute(
                "SELECT * FROM captures ORDER BY capture_time DESC,capture_order DESC,uuid DESC"
            )
        ]

    def transition(self, identifier: str, **values: Any) -> Capture:
        allowed = {
            "phase",
            "staged_path",
            "sha256",
            "offset",
            "attempt",
            "next_attempt",
            "error",
            "receipt",
            "copy_consumed",
            "copy_warning",
        }
        if not values or not values.keys() <= allowed:
            raise ValueError("Invalid capture transition")
        if "receipt" in values:
            values["receipt"] = json.dumps(values["receipt"], sort_keys=True)
        assignments = ",".join(f"{name}=?" for name in values)
        with self.transaction():
            self.connection.execute(
                f"UPDATE captures SET {assignments} WHERE uuid=?", (*values.values(), identifier)
            )
        return self.get(identifier)

    def reserved_bytes(self) -> int:
        row = self.connection.execute(
            "SELECT COALESCE(SUM(json_extract(identity,'$.size')),0) FROM captures "
            "WHERE staged_path IS NOT NULL"
        ).fetchone()
        return int(row[0])

    def fence_copies(self) -> None:
        observed = self.connection.execute(
            "SELECT COALESCE(MAX(capture_order),0) FROM captures"
        ).fetchone()[0]
        with self.transaction():
            self.connection.execute(
                "UPDATE settings SET value=? WHERE key='copy_fence'", (str(observed),)
            )
            self.connection.execute(
                "UPDATE captures SET copy_consumed=1 WHERE capture_order<=?", (observed,)
            )

    def claim_copy(self, identifier: str, manual: bool = False) -> Capture | None:
        capture = self.get(identifier)
        result = (capture.receipt or {}).get("result", {})
        if capture.phase != "ready" or result.get("availability") != "available":
            return None
        observed = self.connection.execute(
            "SELECT COALESCE(MAX(capture_order),0) FROM captures WHERE auto_copy=1"
        ).fetchone()[0]
        fence = int(self.setting("copy_fence", "0"))
        if not manual and (
            not capture.auto_copy or capture.copy_consumed or capture.order < max(observed, fence)
        ):
            return None
        with self.transaction():
            self.connection.execute(
                "UPDATE settings SET value=? WHERE key='copy_fence'", (str(max(observed, fence)),)
            )
            self.connection.execute(
                "UPDATE captures SET copy_consumed=1,copy_warning='Copy acknowledgement unknown' "
                "WHERE uuid=?",
                (identifier,),
            )
        return self.get(identifier)

    def due(self, now: float | None = None) -> list[Capture]:
        instant = time.time() if now is None else now
        return [
            capture
            for capture in reversed(self.captures())
            if capture.phase not in ("ready", "error", "deferred")
            and capture.next_attempt <= instant
        ]
