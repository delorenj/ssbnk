from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass

from .session import desktop_session


@dataclass(frozen=True)
class CopyOutcome:
    status: str
    warning: str | None = None


def copy_native(text: str) -> CopyOutcome:
    session = desktop_session()
    if session == "gnome":
        return CopyOutcome(
            "unknown", "Enable the SSBNK GNOME companion for background clipboard writes"
        )
    command = (
        ["wl-copy", "--type", "text/plain;charset=utf-8"]
        if session == "hyprland"
        else ["xclip", "-selection", "clipboard", "-in"]
        if session == "x11"
        else []
    )
    if not command or not shutil.which(command[0]):
        return CopyOutcome("unknown", "Install the session clipboard backend; upload remains OK")
    try:
        subprocess.run(
            command,
            input=text.encode(),
            timeout=5,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return CopyOutcome("write-issued")
    except (OSError, subprocess.SubprocessError):
        return CopyOutcome(
            "unknown", "Clipboard write failed; use Retry copy without retransmission"
        )
