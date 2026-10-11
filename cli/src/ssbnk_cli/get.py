from __future__ import annotations

import json
import sqlite3
from pathlib import Path

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}


def get_most_recent_screenshot(config: dict[str, str]) -> Path | None:
    """Resolve the most recent screenshot path using ssbnk state, directories, or ledger."""
    # 1. Check state marker in SSBNK_STATE_DIR
    state_dir = Path(config.get("SSBNK_STATE_DIR", "/data/state")).expanduser()
    marker_path = state_dir / "last-screenshot"

    if marker_path.is_file():
        try:
            marker = marker_path.read_text(encoding="utf-8").strip()
            if marker:
                # If marker is an absolute path and exists
                if marker.startswith("/"):
                    p = Path(marker)
                    if p.is_file():
                        return p.resolve()

                # If marker is a filename, search candidate hosted and screenshot locations
                filename = Path(marker).name
                search_dirs: list[Path] = []
                if raw_hosted := config.get("SSBNK_HOSTED_DIR", "").strip():
                    search_dirs.append(Path(raw_hosted).expanduser())
                elif raw_data := config.get("SSBNK_DATA_DIR", "").strip():
                    search_dirs.append(Path(raw_data).expanduser() / "hosted")
                if raw_screenshots := config.get("SSBNK_SCREENSHOT_DIR", "").strip():
                    search_dirs.append(Path(raw_screenshots).expanduser())

                for directory in search_dirs:
                    if directory.is_dir():
                        candidate = directory / filename
                        if candidate.is_file():
                            return candidate.resolve()
        except OSError:
            pass

    # 2. Filesystem scan fallback: check directories for latest image file
    candidates: list[Path] = []
    scan_dirs: list[Path] = []
    if raw_hosted := config.get("SSBNK_HOSTED_DIR", "").strip():
        scan_dirs.append(Path(raw_hosted).expanduser())
    elif raw_data := config.get("SSBNK_DATA_DIR", "").strip():
        scan_dirs.append(Path(raw_data).expanduser() / "hosted")
    if raw_screenshots := config.get("SSBNK_SCREENSHOT_DIR", "").strip():
        scan_dirs.append(Path(raw_screenshots).expanduser())

    seen_dirs: set[Path] = set()
    for directory in scan_dirs:
        try:
            resolved_dir = directory.resolve()
        except OSError:
            continue
        if resolved_dir in seen_dirs or not resolved_dir.is_dir():
            continue
        seen_dirs.add(resolved_dir)

        try:
            for entry in resolved_dir.iterdir():
                if entry.is_file() and entry.suffix.lower() in IMAGE_EXTENSIONS:
                    candidates.append(entry)
        except OSError:
            continue

    if candidates:
        # Sort by mtime descending
        candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        return candidates[0].resolve()

    # 3. Fallback: Check local SQLite ledger if present
    ledger_path = Path.home() / ".local/state/ssbnk/ledger.db"
    if ledger_path.is_file():
        try:
            conn = sqlite3.connect(ledger_path, timeout=2.0)
            try:
                row = conn.execute(
                    "SELECT identity FROM captures WHERE kind='image' ORDER BY capture_time DESC LIMIT 1"
                ).fetchone()
                if row:
                    identity = json.loads(row[0])
                    raw_path = identity.get("path")
                    if raw_path and Path(raw_path).is_file():
                        return Path(raw_path).resolve()
            finally:
                conn.close()
        except Exception:
            pass

    return None
