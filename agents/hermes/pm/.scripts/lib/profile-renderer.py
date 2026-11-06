#!/usr/bin/env python3
"""Find and load THE canonical profile renderer (``scripts/hermes-profile-config.py``).

A generated ``config.yaml`` is ``expected_config(base, delta, profile)``: the Hermes deep merge plus
every renderer pin (``terminal.cwd`` from the org chart, the codegraph ``--path``, ...). Only the
renderer knows that set, so every helper that compares or writes a generated config loads the
renderer through this file and calls ``renderer.expected_config`` / ``renderer.is_render_of``. None
of them may carry its own merge: four private copies once wrote configs that silently stripped the
``terminal.cwd`` pin (2026-10-18).

Search order:
  1. ``$PROFILE_RENDERER`` (what 10-hermes-profile.sh and the tests set);
  2. the checkout this file ships in (``template/.scripts/lib`` -> ``scripts/``), which is how the
     template repo itself and flume's vendored ``templates/hermes-agent`` resolve it;
  3. the host's canonical checkout: ``$HERMES_TEMPLATE_REPO``, ``[paths] template_repo`` in the host
     config.toml, else ``<code root>/33GOD/hermes-agent-template/scripts`` (a desk's
     deployed ``agents/hermes/pm/.scripts/lib`` copy has no renderer beside it).
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path

RENDERER_NAME = "hermes-profile-config.py"


def _configured_path(key: str) -> str:
    """[paths] <key> from the host config.toml, or "" (missing file/key, python < 3.11)."""
    try:
        import tomllib
    except ModuleNotFoundError:
        return ""
    config = Path(
        os.environ.get("HERMES_TEMPLATE_CONFIG")
        or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "hermes-agent-template" / "config.toml"
    )
    try:
        value = tomllib.loads(config.read_text(encoding="utf-8")).get("paths", {}).get(key, "")
    except (OSError, ValueError, AttributeError):
        return ""
    return value if isinstance(value, str) else ""


def candidates() -> list[Path]:
    found = []
    explicit = os.environ.get("PROFILE_RENDERER")
    if explicit:
        found.append(Path(explicit).expanduser())
    here = Path(__file__).resolve()
    if len(here.parents) > 3:
        found.append(here.parents[3] / "scripts" / RENDERER_NAME)
    # The host's canonical checkout: HERMES_TEMPLATE_REPO, then config.toml
    # [paths] template_repo, then <code_root>/33GOD/hermes-agent-template.
    repo = os.environ.get("HERMES_TEMPLATE_REPO") or _configured_path("template_repo")
    if repo:
        found.append(Path(repo).expanduser() / "scripts" / RENDERER_NAME)
    code_root = Path(os.environ.get("HERMES_CODE_ROOT") or _configured_path("code_root") or Path.home() / "code").expanduser()
    found.append(code_root / "33GOD" / "hermes-agent-template" / "scripts" / RENDERER_NAME)
    found.append(Path.home() / "code" / "33GOD" / "hermes-agent-template" / "scripts" / RENDERER_NAME)
    return found


def locate() -> Path:
    for path in candidates():
        if path.is_file() and not path.is_symlink():
            return path
    raise RuntimeError(
        "canonical profile renderer not found (set PROFILE_RENDERER): "
        + ", ".join(str(path) for path in candidates())
    )


def load(fleet_home: Path | str | None = None, *, name: str = "pjangler_profile_renderer"):
    """Import the renderer bound to *fleet_home* (its ``HERMES_FLEET_HOME``), without side effects.

    The renderer binds ``HERMES_HOME``/``BASE``/``PROFILES``/``REGISTRY`` at import, so the fleet home
    is set for the import only and the caller's environment is restored afterwards.
    """
    source = locate()
    previous = os.environ.get("HERMES_FLEET_HOME")
    if fleet_home is not None:
        os.environ["HERMES_FLEET_HOME"] = str(fleet_home)
    try:
        spec = importlib.util.spec_from_file_location(name, source)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"cannot load the canonical profile renderer: {source}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        if fleet_home is not None:
            if previous is None:
                os.environ.pop("HERMES_FLEET_HOME", None)
            else:
                os.environ["HERMES_FLEET_HOME"] = previous
    if not callable(getattr(module, "expected_config", None)):
        raise RuntimeError(f"profile renderer predates expected_config (update the template checkout): {source}")
    return module
