from __future__ import annotations

import hashlib
import http.client
import json
import ssl
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlsplit

from .config import parse_origin
from .store import Capture


class UploadError(RuntimeError):
    def __init__(self, code: str, message: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable


def parse_receipt(value: Any, capture: Capture) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("version") != 2:
        raise UploadError("PROTOCOL", "Unsupported or invalid upload receipt")
    if (
        value.get("uuid") != capture.uuid
        or value.get("kind") != capture.kind
        or value.get("size") != capture.identity.size
        or value.get("sha256") != capture.sha256
        or value.get("profile") != capture.profile
    ):
        raise UploadError("PROTOCOL", "Receipt does not match this capture's immutable identity")
    offset = value.get("offset")
    attempt = value.get("attempt")
    state = value.get("state")
    if (
        type(offset) is not int
        or not 0 <= offset <= capture.identity.size
        or type(attempt) is not int
        or not 1 <= attempt <= 3
        or state
        not in ("receiving", "verifying", "queued", "processing", "ready", "failed", "expired")
    ):
        raise UploadError("PROTOCOL", "Receipt contains invalid state or bounds")
    if state in ("verifying", "queued", "processing", "ready") and (
        offset != capture.identity.size or not value.get("accepted_at")
    ):
        raise UploadError("PROTOCOL", "Accepted receipt is incomplete")
    if (capture.receipt or {}).get("accepted_at") and state == "receiving":
        raise UploadError("STATE_CONFLICT", "Accepted UUID regressed to receiving; repair required")
    result = value.get("result")
    if state == "ready":
        if not isinstance(result, dict) or result.get("metadata_id") != capture.uuid:
            raise UploadError("PROTOCOL", "Ready receipt lacks committed metadata")
        filename = result.get("filename")
        if (
            not isinstance(filename, str)
            or "/" in filename
            or "\\" in filename
            or not filename.startswith(capture.uuid + ".")
        ):
            raise UploadError("PROTOCOL", "Ready filename does not belong to this UUID")
        if result.get("url") != capture.origin + "/" + filename or result.get(
            "availability"
        ) not in ("available", "expired"):
            raise UploadError("PROTOCOL", "Ready URL or availability is invalid")
        if capture.kind == "video" and result.get("media_type") != "image/gif":
            raise UploadError("PROTOCOL", "Recording result is not the required GIF")
    elif result is not None:
        raise UploadError("PROTOCOL", "Non-ready receipt contains a result")
    return value


class UploadClient:
    def __init__(self, origin: str, credential: str) -> None:
        self.origin = parse_origin(origin)
        self.credential = credential

    def request(
        self,
        method: str,
        path: str,
        body: bytes = b"",
        headers: dict[str, str] | None = None,
        chunk: bool = False,
    ) -> tuple[int, Any]:
        parsed = urlsplit(self.origin)
        if parsed.hostname is None:
            raise UploadError("ORIGIN", "API origin has no hostname")
        connection: http.client.HTTPConnection
        if parsed.scheme == "https":
            connection = http.client.HTTPSConnection(
                parsed.hostname, parsed.port, timeout=10, context=ssl.create_default_context()
            )
        else:
            connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=10)
        try:
            connection.connect()
            if connection.sock is None:
                raise UploadError("NETWORK", "Connection could not be established", True)
            connection.sock.settimeout(60 if chunk else 15)
            connection.request(
                method,
                path,
                body,
                {
                    "X-Upload-Key": self.credential,
                    "Content-Length": str(len(body)),
                    **(headers or {}),
                },
            )
            response = connection.getresponse()
            data = response.read(65537)
            if len(data) > 65536:
                raise UploadError("PROTOCOL", "Server response exceeds control-body limit")
            if 300 <= response.status < 400:
                raise UploadError("REDIRECT", "Redirect refused; configure the final HTTPS origin")
            try:
                value = json.loads(data)
            except (ValueError, UnicodeDecodeError) as error:
                if response.status >= 500:
                    raise UploadError(
                        "PROXY", "Proxy or origin temporarily unavailable", True
                    ) from error
                raise UploadError(
                    "UPGRADE_REQUIRED", "Server upgrade required: v2 JSON API unavailable"
                ) from error
            if response.status == 401:
                raise UploadError("UNAUTHORIZED", "Upload credential rejected; fix vault reference")
            if response.status >= 400 and response.status not in (404, 409, 410):
                failure = value.get("error", {}) if isinstance(value, dict) else {}
                code = str(failure.get("code", "SERVER"))
                raise UploadError(
                    code, f"Server rejected upload: {code}", bool(failure.get("retryable"))
                )
            return response.status, value
        except (TimeoutError, OSError, http.client.HTTPException) as error:
            raise UploadError(
                "NETWORK", "Network interrupted; reconcile this UUID before retry", True
            ) from error
        finally:
            connection.close()

    def capabilities(self) -> dict[str, Any]:
        status, value = self.request("GET", "/api/uploads/capabilities")
        if status != 200 or not isinstance(value, dict) or value.get("version") != 2:
            raise UploadError("UPGRADE_REQUIRED", "Server upgrade required; no SSH fallback")
        limits = value.get("limits", {})
        chunk = limits.get("default_chunk_bytes")
        if type(chunk) is not int or not 65536 <= chunk <= 4 * 1024 * 1024:
            raise UploadError("PROTOCOL", "Invalid advertised chunk limit")
        return value

    def status(self, capture: Capture) -> tuple[int, dict[str, Any] | None]:
        status, value = self.request("GET", "/api/uploads/" + capture.uuid)
        if status == 404:
            return status, None
        if status == 410:
            raise UploadError("UPLOAD_EXPIRED", "UUID expired permanently; never silently recreate")
        if status != 200:
            raise UploadError("PROTOCOL", "Unexpected upload status")
        return status, parse_receipt(value, capture)

    def reserve(self, capture: Capture) -> dict[str, Any]:
        descriptor = {
            "version": 2,
            "original_name": original_basename(capture.identity.path),
            "kind": capture.kind,
            "size": capture.identity.size,
            "sha256": capture.sha256,
            "capture_time": datetime.fromtimestamp(capture.capture_time, UTC).isoformat(),
            "profile": capture.profile,
        }
        status, value = self.request(
            "PUT",
            "/api/uploads/" + capture.uuid,
            json.dumps(descriptor).encode(),
            {"Content-Type": "application/json"},
        )
        if status == 409:
            raise UploadError("UUID_CONFLICT", "UUID descriptor conflicts; repair is required")
        if status not in (200, 201):
            raise UploadError("PROTOCOL", "Reservation was not acknowledged")
        return parse_receipt(value, capture)

    def send_chunk(self, capture: Capture, offset: int, data: bytes) -> dict[str, Any] | None:
        status, value = self.request(
            "PUT",
            "/api/uploads/" + capture.uuid + "/chunks",
            data,
            {
                "Upload-Offset": str(offset),
                "Upload-Chunk-SHA256": hashlib.sha256(data).hexdigest(),
            },
            chunk=True,
        )
        if status == 409:
            return None
        if status != 200:
            raise UploadError("PROTOCOL", "Chunk was not durably acknowledged")
        return parse_receipt(value, capture)

    def retry(self, capture: Capture) -> dict[str, Any]:
        expected = (capture.receipt or {}).get("attempt")
        status, value = self.request(
            "POST",
            "/api/uploads/" + capture.uuid + "/retry",
            json.dumps({"expectedAttempt": expected}).encode(),
            {"Content-Type": "application/json"},
        )
        if status not in (200, 202):
            raise UploadError(
                "ATTEMPT_CONFLICT", "Processor retry requires UUID reconciliation", True
            )
        return parse_receipt(value, capture)

    def complete(self, capture: Capture) -> dict[str, Any]:
        status, value = self.request("POST", "/api/uploads/" + capture.uuid + "/complete")
        if status == 409:
            raise UploadError("STATE_CONFLICT", "Completion requires reconciliation", True)
        if status not in (200, 202):
            raise UploadError("PROTOCOL", "Acceptance was not acknowledged")
        return parse_receipt(value, capture)


def original_basename(path: str) -> str:
    return path.rsplit("/", 1)[-1]
