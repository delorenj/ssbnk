from __future__ import annotations

import fcntl
import os
from pathlib import Path

from .config import StateError, private_directory


class Singleton:
    def __init__(self, state_directory: Path) -> None:
        self.descriptor = os.open(
            private_directory(state_directory) / "client.lock",
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
            0o600,
        )
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(self.descriptor)
            raise StateError("SSBNK Client is already running in this graphical session") from error

    def close(self) -> None:
        os.close(self.descriptor)


def desktop_session() -> str:
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    if "gnome" in desktop:
        return "gnome"
    if os.environ.get("WAYLAND_DISPLAY") and (
        "hyprland" in desktop or os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    ):
        return "hyprland"
    if os.environ.get("DISPLAY") and os.environ.get("XDG_SESSION_TYPE") == "x11":
        return "x11"
    return "unsupported"
