from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from urllib.parse import urlsplit


class StateError(RuntimeError):
    pass


def private_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.stat().st_uid != os.getuid():
        raise StateError(f"Unsafe private directory: {path}")
    path.chmod(0o700)
    return path


def atomic_json(path: Path, value: object) -> None:
    private_directory(path.parent)
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def parse_origin(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("API origin cannot contain credentials, query or fragment")
    if parsed.path not in ("", "/") or not parsed.hostname:
        raise ValueError("Use an API origin, not an endpoint path")
    if parsed.scheme != "https" and not (
        parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1")
    ):
        raise ValueError("HTTPS is required except for explicit loopback development")
    return value.rstrip("/")


@dataclass(frozen=True)
class Configuration:
    screenshot_directory: str
    recording_directory: str
    api_origin: str = "https://ss.delo.sh"
    credential_reference: str = ""
    launch_at_login: bool = False
    version: int = 2

    def parsed(self) -> Configuration:
        if self.version != 2:
            raise StateError(f"Unsupported configuration version {self.version}")
        if not self.screenshot_directory.strip() or not self.recording_directory.strip():
            raise ValueError("Choose both capture folders")
        parse_origin(self.api_origin)
        if not self.credential_reference.startswith("op://DeLoSecrets/"):
            raise ValueError("Use a DeLoSecrets op:// credential reference")
        if any(c in self.credential_reference for c in "\r\n\x00"):
            raise ValueError("Invalid vault reference")
        return replace(self, api_origin=parse_origin(self.api_origin))

    def roots(self) -> dict[Path, set[str]]:
        roots: dict[Path, set[str]] = {}
        for kind, raw in (
            ("image", self.screenshot_directory),
            ("video", self.recording_directory),
        ):
            root = Path(raw).expanduser().resolve()
            roots.setdefault(root, set()).add(kind)
        return roots

    @classmethod
    def defaults(cls) -> Configuration:
        return cls(
            str(Path.home() / "Pictures/Screenshots"), str(Path.home() / "Videos/Screencasts")
        )

    @classmethod
    def load(cls, path: Path) -> Configuration:
        if not path.exists():
            return cls.defaults()
        try:
            value = json.loads(path.read_text())
            if not isinstance(value, dict):
                raise StateError("Configuration must be a JSON object")
            return cls(**value)
        except (ValueError, TypeError) as error:
            raise StateError("Saved settings are corrupt; preserved for repair") from error

    def save(self, path: Path) -> None:
        atomic_json(path, asdict(self.parsed()))


def xdg_paths() -> tuple[Path, Path]:
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "ssbnk"
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "ssbnk"
    return private_directory(config), private_directory(state)
