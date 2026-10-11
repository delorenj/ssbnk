from __future__ import annotations

import os
import shutil
import subprocess


def copy_to_wl_clipboard(text: str) -> tuple[bool, str | None]:
    """Copy text to Wayland clipboard using wl-copy.

    Returns (success, error_message).
    """
    if not shutil.which("wl-copy"):
        return False, "wl-copy command not found in PATH"

    env = os.environ.copy()
    env.setdefault("WAYLAND_DISPLAY", "wayland-0")
    if "XDG_RUNTIME_DIR" not in env:
        uid = os.getuid() if hasattr(os, "getuid") else 1000
        env["XDG_RUNTIME_DIR"] = f"/run/user/{uid}"

    try:
        proc = subprocess.run(
            ["wl-copy"],
            input=text.encode("utf-8"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=2.0,
            check=False,
        )
        if proc.returncode != 0:
            return False, f"wl-copy exited with code {proc.returncode}"
        return True, None
    except subprocess.TimeoutExpired:
        return False, "wl-copy timed out"
    except Exception as exc:
        return False, str(exc)
