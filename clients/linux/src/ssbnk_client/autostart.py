from __future__ import annotations

import os
from pathlib import Path

from .config import private_directory

DESKTOP_ENTRY = """[Desktop Entry]
Type=Application
Name=SSBNK Client
Comment=Deliver captures and copy their hosted URLs
Exec=ssbnk-client
Icon=camera-photo-symbolic
Terminal=false
Categories=Utility;Graphics;
X-GNOME-Autostart-enabled=true
"""


def set_launch_at_login(enabled: bool) -> None:
    root = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "autostart"
    target = private_directory(root) / "ssbnk-client.desktop"
    if not enabled:
        target.unlink(missing_ok=True)
        return
    descriptor = os.open(target, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(DESKTOP_ENTRY)
        output.flush()
        os.fsync(output.fileno())
