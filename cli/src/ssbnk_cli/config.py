from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class ConfigVar:
    key: str
    value: str
    source: str  # "env", ".env", "config.json", or "default"
    is_secret: bool = False

    def display_value(self, reveal_secrets: bool = False) -> str:
        if not self.is_secret or reveal_secrets or not self.value:
            return self.value
        if self.value.startswith("op://"):
            return self.value
        return "********"


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse a simple KEY=VALUE dotenv file without external dependencies."""
    results: dict[str, str] = {}
    if not path.is_file():
        return results

    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return results

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if (val.startswith('"') and val.endswith('"')) or (
            val.startswith("'") and val.endswith("'")
        ):
            val = val[1:-1]
        if key:
            results[key] = val
    return results


def find_env_files() -> list[tuple[Path, str]]:
    """Locate possible .env configuration files in order of discovery."""
    candidates: list[tuple[Path, str]] = []

    # Current working directory and parent paths
    cwd = Path.cwd()
    for parent in [cwd, *cwd.parents]:
        env_path = parent / ".env"
        if env_path.is_file():
            candidates.append((env_path, ".env"))
            break

    # Standard ssbnk config locations
    home = Path.home()
    remote_env = home / ".config/ssbnk/remote.env"
    if remote_env.is_file():
        candidates.append((remote_env, "remote.env"))

    user_env = home / ".config/ssbnk/.env"
    if user_env.is_file():
        candidates.append((user_env, "~/.config/ssbnk/.env"))

    return candidates


def load_desktop_json_config() -> dict[str, str]:
    """Load ~/.config/ssbnk/config.json if present."""
    config_file = Path.home() / ".config/ssbnk/config.json"
    if not config_file.is_file():
        return {}
    try:
        data = json.loads(config_file.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return {}
        mapping: dict[str, str] = {}
        if "screenshot_directory" in data:
            mapping["SSBNK_SCREENSHOT_DIR"] = str(data["screenshot_directory"])
        if "recording_directory" in data:
            mapping["SSBNK_SCREENCAST_DIR"] = str(data["recording_directory"])
        if "api_origin" in data:
            mapping["SSBNK_URL"] = str(data["api_origin"])
            mapping["SSBNK_HOST"] = str(data["api_origin"])
        if "credential_reference" in data:
            mapping["SSBNK_UPLOAD_KEY"] = str(data["credential_reference"])
        return mapping
    except Exception:
        return {}


def get_default_config() -> dict[str, str]:
    """Compute default configuration values based on system state."""
    home = Path.home()
    host_data = home / "data/ssbnk"
    default_data_dir = str(host_data) if host_data.is_dir() else "/data"
    default_hosted_dir = str(host_data / "hosted") if host_data.is_dir() else f"{default_data_dir}/hosted"
    default_state_dir = str(host_data / "state") if host_data.is_dir() else f"{default_data_dir}/state"

    screenshots = home / "Pictures/Screenshots"
    screencasts = home / "Videos/Screencasts"

    uid = os.getuid() if hasattr(os, "getuid") else 1000

    return {
        "SSBNK_URL": "https://ss.delo.sh",
        "SSBNK_DOMAIN": "ss.delo.sh",
        "SSBNK_DATA_DIR": default_data_dir,
        "SSBNK_HOSTED_DIR": default_hosted_dir,
        "SSBNK_STATE_DIR": default_state_dir,
        "SSBNK_SCREENSHOT_DIR": str(screenshots) if screenshots.is_dir() else "/media/screenshots",
        "SSBNK_SCREENCAST_DIR": str(screencasts) if screencasts.is_dir() else "/media/screencasts",
        "SSBNK_API_PORT": "80",
        "SSBNK_UI_DIR": "/ui",
        "SSBNK_RETENTION_DAYS": "30",
        "SSBNK_HOSTED_RETENTION_DAYS": "30",
        "SSBNK_ARCHIVE_RETENTION_DAYS": "30",
        "SSBNK_UPLOAD_KEY": "",
        "SSBNK_HOST": "https://ss.delo.sh",
        "WAYLAND_DISPLAY": "wayland-0",
        "XDG_RUNTIME_DIR": f"/run/user/{uid}",
        "DISPLAY": ":0",
    }


def is_secret_key(key: str) -> bool:
    upper = key.upper()
    return any(secret_term in upper for secret_term in ("KEY", "SECRET", "TOKEN", "PASSWORD"))


def load_all_config() -> dict[str, ConfigVar]:
    """Resolve and return all configuration variables with source tracking."""
    defaults = get_default_config()
    desktop_config = load_desktop_json_config()

    file_configs: dict[str, tuple[str, str]] = {}
    for env_path, label in find_env_files():
        parsed = parse_env_file(env_path)
        for k, v in parsed.items():
            if (k.startswith("SSBNK_") or k in defaults) and k not in file_configs:
                file_configs[k] = (v, label)

    all_keys = set(defaults.keys()) | set(file_configs.keys()) | set(desktop_config.keys())
    for k in os.environ:
        if k.startswith("SSBNK_") or k in defaults:
            all_keys.add(k)

    config_vars: dict[str, ConfigVar] = {}

    for k in sorted(all_keys):
        is_secret = is_secret_key(k)
        if k in os.environ:
            config_vars[k] = ConfigVar(key=k, value=os.environ[k], source="env", is_secret=is_secret)
        elif k in file_configs:
            val, label = file_configs[k]
            config_vars[k] = ConfigVar(key=k, value=val, source=label, is_secret=is_secret)
        elif k in desktop_config:
            config_vars[k] = ConfigVar(
                key=k, value=desktop_config[k], source="config.json", is_secret=is_secret
            )
        elif k in defaults:
            config_vars[k] = ConfigVar(
                key=k, value=defaults[k], source="default", is_secret=is_secret
            )

    return config_vars


def get_config_map() -> dict[str, str]:
    """Return a simple dictionary of key -> value for all configuration items."""
    return {k: var.value for k, var in load_all_config().items()}
