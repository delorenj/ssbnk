from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from .config import Configuration
from .store import Identity, Store
from .upload import UploadClient, UploadError, parse_receipt

ALLOWED = {"SSBNK_HOST", "SSBNK_SCREENSHOT_DIR", "SSBNK_SCREENCAST_DIR"}
SERVICE = "ssbnk-remote-upload.service"


def parse_legacy_values(path: Path, allowed: set[str]) -> dict[str, str]:
    if path.stat().st_size > 65536:
        raise ValueError("Legacy configuration exceeds import bound")
    values = {}
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"(?:export\s+)?([A-Z_]+)=(.*)", line.strip())
        if not match or match[1] not in allowed:
            continue
        value = match[2].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if any(character in value for character in "$`\x00\r\n"):
            raise ValueError("Legacy import contains executable syntax; it was not executed")
        values[match[1]] = value
    return values


def import_nonsecret_legacy(path: Path) -> dict[str, str]:
    return parse_legacy_values(path, ALLOWED)


def legacy_processes_inactive() -> bool:
    for directory in Path("/proc").iterdir():
        if not directory.name.isdigit():
            continue
        try:
            if directory.stat().st_uid != os.getuid():
                continue
            with (directory / "cmdline").open("rb") as process:
                command = process.read(16384)
            if b"remote-screenshot-upload.sh" in command:
                return False
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            return False
    return True


def service_command(*arguments: str) -> bool:
    try:
        result = subprocess.run(
            ["systemctl", "--user", *arguments],
            timeout=15,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class LegacyHandover:
    def __init__(
        self,
        store: Store,
        configuration: Configuration,
        state_directory: Path,
        credentials: Callable[[str], str],
        controlled_test: Callable[[Path, str], None],
        command: Callable[..., bool] = service_command,
        inactive: Callable[[], bool] = legacy_processes_inactive,
        legacy_file: Path | None = None,
    ) -> None:
        self.store, self.configuration, self.state_directory = store, configuration, state_directory
        self.credentials, self.controlled_test = credentials, controlled_test
        self.command, self.inactive = command, inactive
        self.legacy_file = legacy_file or Path.home() / ".config/ssbnk/remote.env"

    def execute(self, confirmed: bool) -> None:
        if not confirmed:
            raise ValueError("Explicit confirmation is required before disabling the old uploader")
        credential = self.credentials(self.configuration.credential_reference)
        if self.legacy_file.exists():
            old = parse_legacy_values(self.legacy_file, {"SSBNK_UPLOAD_KEY"}).get(
                "SSBNK_UPLOAD_KEY"
            )
            if (
                not old
                or hashlib.sha256(old.encode()).digest()
                != hashlib.sha256(credential.encode()).digest()
            ):
                raise ValueError(
                    "Verified vault migration must match the legacy credential; file preserved"
                )
        self.store.set_setting("handover_vault_verified", "true")
        legacy_roots = []
        if self.legacy_file.exists():
            values = import_nonsecret_legacy(self.legacy_file)
            legacy_roots = [
                Path(value).expanduser().resolve()
                for value in values.get("SSBNK_SCREENSHOT_DIR", "").split(":")
                if value
            ]
        controlled = self.state_directory / "handover-test"
        controlled.mkdir(mode=0o700, exist_ok=True)
        if any(
            controlled.resolve().is_relative_to(root)
            for root in [*legacy_roots, *self.configuration.roots()]
        ):
            raise ValueError("Controlled test must be outside both clients' watched roots")
        self.controlled_test(controlled, credential)
        boundary = {
            "version": 1,
            "time": time.time(),
            "roots": [str(root) for root in self.configuration.roots()],
        }
        self.store.set_setting("handover_boundary", json.dumps(boundary))
        was_active = self.command("is-active", "--quiet", SERVICE)
        was_enabled = self.command("is-enabled", "--quiet", SERVICE)
        self.store.set_setting(
            "handover_rollback", json.dumps({"active": was_active, "enabled": was_enabled})
        )
        try:
            if not self.command("disable", "--now", SERVICE):
                raise ValueError("Could not disable legacy uploader; replacement remains gated")
            if self.command("is-active", "--quiet", SERVICE) or not self.inactive():
                raise ValueError("Legacy inactivity was not confirmed; replacement remains gated")
            self.store.set_setting("handover", "complete")
            self.store.set_setting("handover_error", "")
        except BaseException:
            if was_enabled:
                self.command("enable", SERVICE)
            if was_active:
                self.command("start", SERVICE)
            self.store.set_setting("handover", "pending")
            raise


def qualify_capture(store: Store, directory: Path, origin: str, credential: str) -> None:
    import struct
    import zlib

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack("!I", len(payload))
            + kind
            + payload
            + struct.pack("!I", zlib.crc32(kind + payload))
        )

    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack("!IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00"))
        + chunk(b"IEND", b"")
    )
    path = directory / f"controlled-{time.time_ns()}.png"
    path.write_bytes(data)
    path.chmod(0o600)
    capture = store.observe(Identity.current(path), "image", origin, False)
    digest = hashlib.sha256(data).hexdigest()
    capture = store.transition(capture.uuid, sha256=digest, phase="queued")
    client = UploadClient(origin, credential)
    client.capabilities()
    receipt = client.reserve(capture)
    chunk_receipt = client.send_chunk(capture, receipt["offset"], data)
    if chunk_receipt is None:
        _, chunk_receipt = client.status(capture)
    if chunk_receipt is None:
        raise ValueError("Controlled chunk was not durably acknowledged")
    receipt = client.complete(capture)
    deadline = time.monotonic() + 180
    while receipt["state"] != "ready":
        if receipt["state"] in ("failed", "expired") or time.monotonic() >= deadline:
            raise ValueError("Controlled capture did not reach committed ready state")
        time.sleep(2)
        _, polled = client.status(capture)
        if polled is None:
            raise ValueError("Controlled UUID disappeared")
        receipt = polled
    receipt = parse_receipt(receipt, capture)
    if receipt["result"]["sha256"] != digest or receipt["result"]["availability"] != "available":
        raise UploadError("PROTOCOL", "Controlled output differs from test input")
    store.transition(capture.uuid, phase="ready", receipt=receipt, copy_consumed=True)
