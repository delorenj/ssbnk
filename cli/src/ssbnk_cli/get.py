from __future__ import annotations

import json
import sqlite3
from pathlib import Path

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}


def _image_path(path: Path) -> Path | None:
    try:
        if path.suffix.lower() in IMAGE_EXTENSIONS and path.is_file():
            return path.resolve()
    except (OSError, RuntimeError):
        pass
    return None


def _image_directories(config: dict[str, str]) -> list[Path]:
    directories: list[Path] = []
    if raw_hosted := config.get("SSBNK_HOSTED_DIR", "").strip():
        directories.append(Path(raw_hosted).expanduser())
    elif raw_data := config.get("SSBNK_DATA_DIR", "").strip():
        directories.append(Path(raw_data).expanduser() / "hosted")
    if raw_screenshots := config.get("SSBNK_SCREENSHOT_DIR", "").strip():
        directories.append(Path(raw_screenshots).expanduser())
    return directories


def _marked_image(config: dict[str, str], directories: list[Path]) -> Path | None:
    marker_path = Path(config.get("SSBNK_STATE_DIR", "/data/state")).expanduser() / "last-screenshot"
    try:
        marker = marker_path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return None
    if not marker:
        return None
    if Path(marker).is_absolute():
        return _image_path(Path(marker))
    filename = Path(marker).name
    for directory in directories:
        if candidate := _image_path(directory / filename):
            return candidate
    return None


def _directory_images(directories: list[Path]) -> list[Path]:
    images: dict[Path, int] = {}
    seen_dirs: set[Path] = set()
    for directory in directories:
        try:
            resolved_dir = directory.resolve()
            if resolved_dir in seen_dirs or not resolved_dir.is_dir():
                continue
            seen_dirs.add(resolved_dir)
            for entry in resolved_dir.iterdir():
                if image := _image_path(entry):
                    try:
                        images[image] = image.stat().st_mtime_ns
                    except OSError:
                        continue
        except (OSError, RuntimeError):
            continue
    return sorted(images, key=lambda p: (-images[p], str(p)))


def _ledger_images() -> list[Path]:
    ledger_path = Path.home() / ".local/state/ssbnk/ledger.db"
    if not ledger_path.is_file():
        return []
    images: list[Path] = []
    try:
        conn = sqlite3.connect(ledger_path, timeout=2.0)
        try:
            rows = conn.execute(
                "SELECT identity FROM captures WHERE kind='image' "
                "ORDER BY capture_time DESC, rowid DESC"
            )
            for (raw_identity,) in rows:
                try:
                    raw_path = json.loads(raw_identity).get("path")
                    if raw_path and (image := _image_path(Path(raw_path).expanduser())):
                        images.append(image)
                except (TypeError, ValueError, OSError):
                    continue
        finally:
            conn.close()
    except (OSError, sqlite3.Error):
        return []
    return images


def get_recent_screenshots(config: dict[str, str], count: int = 1) -> list[Path]:
    """Return distinct local images, with the marker first and ledger only if directories are empty."""
    if count < 1:
        raise ValueError("count must be positive")
    directories = _image_directories(config)
    marker = _marked_image(config, directories)
    directory_images = _directory_images(directories)
    results: list[Path] = []
    seen: set[Path] = set()
    for image in ([marker] if marker else []) + (
        directory_images if directory_images else _ledger_images()
    ):
        if image not in seen:
            seen.add(image)
            results.append(image)
            if len(results) == count:
                break
    return results


def get_most_recent_screenshot(config: dict[str, str]) -> Path | None:
    """Keep the single-image lookup API for existing callers."""
    results = get_recent_screenshots(config)
    return results[0] if results else None
