from __future__ import annotations

import queue
import random
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, TypeVar

from .clipboard import CopyOutcome, copy_native
from .config import Configuration
from .credentials import CredentialError, resolve_credential
from .legacy import LegacyHandover, legacy_processes_inactive, qualify_capture
from .scanner import Scanner
from .store import Capture, Store
from .upload import UploadClient, UploadError

NetworkResult = TypeVar("NetworkResult")


class Worker:
    def __init__(
        self,
        state_directory: Path,
        configuration: Configuration,
        publish: Callable[[dict[str, Any]], None],
        copy: Callable[[str, str], CopyOutcome] = lambda _identifier, url: copy_native(url),
        credentials: Callable[[str], str] = resolve_credential,
    ) -> None:
        self.state_directory = state_directory
        self.configuration = configuration
        self.publish = publish
        self.copy = copy
        self.credentials = credentials
        self.commands: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=128)
        self.stopping = threading.Event()
        self.network_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="ssbnk-http")
        self.thread = threading.Thread(target=self.run, name="ssbnk-queue-owner", daemon=True)
        self.existing = False
        self.backfill_targets: set[str] = set()
        self.processor_retries: set[str] = set()
        self.store: Store
        self.scanner: Scanner

    def network(self, operation: Callable[[], NetworkResult]) -> NetworkResult:
        future = self.network_executor.submit(operation)
        while not future.done():
            self.drain_commands()
            self.stopping.wait(0.05)
        return future.result()

    def submit(self, command: str, value: Any = None) -> None:
        self.commands.put_nowait((command, value))

    def snapshot(self) -> None:
        captures = self.store.captures()
        rows = []
        for capture in captures:
            result = (capture.receipt or {}).get("result")
            rows.append(
                {
                    "uuid": capture.uuid,
                    "filename": Path(capture.identity.path).name,
                    "time": capture.capture_time,
                    "kind": capture.kind,
                    "state": "OK"
                    if capture.phase == "ready"
                    else "queued"
                    if capture.phase == "deferred"
                    else "error"
                    if capture.phase == "error"
                    else "uploading"
                    if capture.phase in ("verifying", "processing")
                    else capture.phase,
                    "detail": capture.error or capture.copy_warning or capture.phase,
                    "url": result.get("url") if result else None,
                    "availability": result.get("availability") if result else None,
                }
            )
        self.publish(
            {
                "version": 1,
                "revision": int(self.store.setting("revision", "0")),
                "rows": rows,
                "latest_order": max(
                    (capture.order for capture in captures if capture.auto_copy), default=0
                ),
                "root_errors": self.scanner.root_errors,
                "handover": self.store.setting("handover"),
                "copy_fence": int(self.store.setting("copy_fence", "0")),
                "handover_error": self.store.setting("handover_error"),
            }
        )

    def run(self) -> None:
        try:
            self.store = Store(self.state_directory / "ledger.sqlite")
            with self.store.transaction():
                self.store.connection.execute(
                    "UPDATE captures SET copy_consumed=1 WHERE phase='ready'"
                )
            self.scanner = Scanner(self.store, self.state_directory / "outbox")
            if not legacy_presence() and self.store.setting("handover") == "pending":
                self.store.set_setting("handover", "not-required")
            for capture in self.store.captures():
                if capture.phase == "ready" and capture.staged_path:
                    Path(capture.staged_path).unlink(missing_ok=True)
                    self.store.transition(capture.uuid, staged_path=None)
            while not self.stopping.is_set():
                self.drain_commands()
                try:
                    self.configuration = self.configuration.parsed()
                    self.scanner.reconcile(
                        self.configuration, existing_identities=self.backfill_targets
                    )
                    self.backfill_targets = {
                        identity
                        for identity in self.backfill_targets
                        if not self.store.connection.execute(
                            "SELECT 1 FROM captures WHERE identity=?", (identity,)
                        ).fetchone()
                    }
                    self.snapshot()
                    if self.store.setting("handover") in ("not-required", "complete"):
                        for capture in self.store.due():
                            self.transfer(capture)
                            if self.stopping.is_set():
                                break
                except (ValueError, CredentialError) as error:
                    self.publish({"version": 1, "error": str(error), "rows": []})
                self.stopping.wait(2)
        except Exception as error:
            self.publish(
                {
                    "version": 1,
                    "error": (
                        f"Client stopped safely: {type(error).__name__}; state preserved for repair"
                    ),
                    "rows": [],
                }
            )
        finally:
            self.network_executor.shutdown(wait=True, cancel_futures=True)
            if hasattr(self, "store"):
                self.store.close()

    def drain_commands(self) -> None:
        while True:
            try:
                command, value = self.commands.get_nowait()
            except queue.Empty:
                return
            if command == "configuration":
                self.configuration = value
            elif command == "existing":
                self.backfill_targets.clear()
                for root, kinds in self.configuration.roots().items():
                    try:
                        self.backfill_targets.update(
                            identity.key for identity, _ in self.scanner.files(root, kinds)
                        )
                    except OSError:
                        continue
            elif command == "copy":
                self.copy_capture(str(value), manual=True)
            elif command == "retry":
                capture = self.store.get(str(value))
                if capture.phase == "error":
                    if capture.receipt and capture.receipt.get("state") == "failed":
                        self.processor_retries.add(capture.uuid)
                    self.store.transition(capture.uuid, phase="queued", next_attempt=0, error=None)
            elif command == "copy_ack":
                identifier, status = value
                self.store.transition(
                    identifier,
                    copy_warning=None
                    if status in ("write-issued", "read-back-observed")
                    else "Copy acknowledgement unknown; use Retry copy",
                )
            elif command == "handover":
                try:
                    migration = LegacyHandover(
                        self.store,
                        self.configuration,
                        self.state_directory,
                        self.credentials,
                        lambda directory, key: qualify_capture(
                            self.store, directory, self.configuration.api_origin, key
                        ),
                    )
                    migration.execute(confirmed=value is True)
                    self.scanner.reconcile(self.configuration)
                except (ValueError, UploadError, CredentialError):
                    self.store.set_setting("handover", "pending")
                    self.store.set_setting(
                        "handover_error",
                        "Handover failed; legacy rollback preserved and replacement remains gated",
                    )
            elif command == "stop":
                self.stopping.set()
            self.snapshot()

    def transfer(self, capture: Capture) -> None:
        if (
            capture.phase != "ready"
            and not (capture.receipt or {}).get("accepted_at")
            and not self.scanner.recover_stage(capture)
        ):
            self.snapshot()
            return
        capture = self.store.get(capture.uuid)
        try:
            credential = self.credentials(self.configuration.credential_reference)
            client = UploadClient(capture.origin, credential)
            capabilities = self.network(client.capabilities)
            _, receipt = self.network(lambda: client.status(capture))
            if receipt is None:
                if capture.receipt and (
                    capture.receipt.get("accepted_at")
                    or capture.receipt.get("offset") == capture.identity.size
                ):
                    raise UploadError(
                        "UPLOAD_UNKNOWN", "Accepted UUID is missing; storage repair required"
                    )
                receipt = self.network(lambda: client.reserve(capture))
            self.persist_receipt(capture, receipt)
            capture = self.store.get(capture.uuid)
            if receipt["state"] == "ready":
                return
            if receipt["state"] == "failed":
                failure = receipt.get("error", {})
                if capture.uuid in self.processor_retries and failure.get("retryable"):
                    receipt = self.network(lambda: client.retry(capture))
                    self.persist_receipt(capture, receipt)
                    self.processor_retries.discard(capture.uuid)
                    return
                raise UploadError(
                    str(failure.get("code", "PROCESSOR")),
                    "Server processor failed; explicit Retry required",
                )
            if receipt["state"] != "receiving":
                self.store.transition(capture.uuid, next_attempt=time.time() + 2)
                return
            if capture.staged_path is None:
                raise UploadError("STAGE", "Verified stage is unavailable")
            with Path(capture.staged_path).open("rb") as source:
                offset = receipt["offset"]
                source.seek(offset)
                data = source.read(
                    min(
                        capabilities["limits"]["default_chunk_bytes"],
                        capture.identity.size - offset,
                    )
                )
            self.store.transition(capture.uuid, phase="uploading")
            self.snapshot()
            if data:
                receipt = self.network(lambda: client.send_chunk(capture, offset, data))
                if receipt is None:
                    self.store.transition(capture.uuid, next_attempt=time.time() + 2)
                    return
                self.persist_receipt(capture, receipt)
            if self.store.get(capture.uuid).offset == capture.identity.size:
                receipt = self.network(lambda: client.complete(capture))
                self.persist_receipt(capture, receipt)
            self.store.transition(capture.uuid, next_attempt=0)
        except CredentialError as error:
            self.store.transition(capture.uuid, phase="error", error=str(error))
        except UploadError as error:
            delay = min(30, 2 ** min(capture.attempt, 5)) * random.uniform(0.8, 1.2)
            self.store.transition(
                capture.uuid,
                phase="queued" if error.retryable else "error",
                error=str(error),
                next_attempt=time.time() + delay,
            )
        except OSError:
            self.store.transition(capture.uuid, phase="error", error="Local stage is unavailable")
        finally:
            self.snapshot()

    def persist_receipt(self, capture: Capture, receipt: dict[str, Any]) -> None:
        state = receipt["state"]
        phase = (
            "ready"
            if state == "ready"
            else "error"
            if state == "failed"
            else "queued"
            if state in ("receiving", "queued")
            else state
        )
        self.store.transition(
            capture.uuid,
            receipt=receipt,
            offset=receipt["offset"],
            phase=phase,
            attempt=receipt["attempt"],
            error=None,
        )
        self.snapshot()
        if phase != "ready":
            return
        self.copy_capture(capture.uuid)
        if capture.staged_path:
            stage = Path(capture.staged_path)
            stage.unlink(missing_ok=True)
            self.scanner._sync(stage.parent)
            self.store.transition(capture.uuid, staged_path=None)

    def copy_capture(self, identifier: str, manual: bool = False) -> None:
        capture = self.store.get(identifier)
        if manual:
            self.store.fence_copies()
            self.snapshot()
        if manual and capture.receipt:
            try:
                client = UploadClient(
                    capture.origin, self.credentials(self.configuration.credential_reference)
                )
                _, receipt = self.network(lambda: client.status(capture))
                if receipt:
                    self.store.transition(identifier, receipt=receipt)
            except (UploadError, CredentialError):
                self.store.transition(
                    identifier, copy_warning="Availability could not be confirmed; Retry copy later"
                )
                return
        claimed = self.store.claim_copy(identifier, manual)
        if claimed is None:
            return
        self.snapshot()
        result = (claimed.receipt or {})["result"]
        outcome = self.copy(identifier, result["url"])
        self.store.transition(identifier, copy_warning=outcome.warning)
        self.snapshot()


def legacy_presence() -> bool:
    paths = [
        Path.home() / ".config/systemd/user/ssbnk-remote-upload.service",
        Path.home() / ".config/ssbnk/remote.env",
    ]
    return any(path.exists() for path in paths) or not legacy_processes_inactive()
