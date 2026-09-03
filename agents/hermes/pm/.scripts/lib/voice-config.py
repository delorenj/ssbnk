#!/usr/bin/env python3
"""Reconcile the PM Vox delta without freezing inherited fleet plugins.

Commit 52d9445 accidentally copied the then-current fleet plugin list into
profile deltas.  Those files had no provenance marker.  This tool is shared by
first-run provisioning and fleet-sync and contains the sealed historical base
needed to distinguish that generated snapshot from an intentional replacement.
"""

from __future__ import annotations

import argparse
import copy
import errno
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import tempfile
from dataclasses import dataclass

import yaml


def load_profile_lock_module():
    source = pathlib.Path(__file__).with_name("profile-config-lock.py")
    if source.is_symlink() or not source.is_file():
        raise RuntimeError(f"trusted profile config lock helper is unavailable: {source}")
    spec = importlib.util.spec_from_file_location(
        "pjangler_profile_config_lock", source
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load profile config lock helper: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROFILE_LOCK = load_profile_lock_module()


LIST_PATCH_KEY = "x-pjangler-merge"
MIGRATION_KEY = "plugins_enabled_52d9445"
LEGACY_PROVENANCE_KEY = "plugins_enabled_snapshot"

# Byte-order-equivalent plugin set emitted by 52d9445 for the deployed fleet
# base. The digest is deliberately sealed next to the values: changing either
# requires adding a new historical record, never silently redefining existing
# provenance.
SEALED_HISTORICAL_BASES = (
    {
        "id": "delo-fleet-52d9445-generated-2026-08",
        "sha256": "99656898b5bc80a24c42cdf0720abb9042d86bd8415fbbab534282d245dd618e",
        "plugins": (
            "bloodbank-platform",
            "copilot-provider",
            "fal",
            "gemini-provider",
            "google_meet",
            "kimi-coding-provider",
            "ntfy-platform",
            "openai-codex",
            "openrouter",
            "self-hosted",
            "slack-platform",
            "teams-platform",
            "teams_pipeline",
            "telegram-platform",
            "tts/vox",
            "web-brave-free",
            "web-tavily",
        ),
    },
)


class ContractError(RuntimeError):
    """A malformed config cannot be reconciled automatically."""


class UnresolvedLegacySnapshot(ContractError):
    """An unmarked legacy list cannot be classified safely."""


@dataclass(frozen=True)
class FileSnapshot:
    existed: bool
    content: bytes
    mode: int


def canonical_digest(values: tuple[str, ...]) -> str:
    payload = json.dumps(values, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


for _record in SEALED_HISTORICAL_BASES:
    if canonical_digest(_record["plugins"]) != _record["sha256"]:
        raise RuntimeError(f"sealed plugin history digest mismatch: {_record['id']}")


def require_regular(path: pathlib.Path, *, required: bool = True) -> None:
    if path.is_symlink():
        raise ContractError(f"refusing symlinked config path: {path}")
    if required and not path.is_file():
        raise ContractError(f"required config source is unavailable: {path}")
    if path.exists() and not path.is_file():
        raise ContractError(f"config path is not a regular file: {path}")


def load_mapping(path: pathlib.Path, *, required: bool = True) -> dict:
    require_regular(path, required=required)
    if not path.exists():
        return {}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise ContractError(f"invalid YAML in {path}: {type(exc).__name__}") from exc
    if not isinstance(data, dict):
        raise ContractError(f"config root must be a mapping: {path}")
    return data


def plain_merge(base: dict, override: dict) -> dict:
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = plain_merge(result[key], value)
        elif key in result and isinstance(result[key], dict) and value is None:
            continue
        else:
            result[key] = copy.deepcopy(value)
    return result


def apply_list_patches(result: dict, directive: object) -> None:
    if directive is None:
        return
    if not isinstance(directive, dict):
        raise ContractError(f"{LIST_PATCH_KEY} must be a mapping")
    patches = directive.get("list_patches", {})
    if not isinstance(patches, dict):
        raise ContractError(f"{LIST_PATCH_KEY}.list_patches must be a mapping")
    for dotted, rule in patches.items():
        if not isinstance(dotted, str) or not dotted or not isinstance(rule, dict):
            raise ContractError("invalid list patch")
        additions = rule.get("add", []) or []
        removals = rule.get("remove", []) or []
        if not isinstance(additions, list) or not isinstance(removals, list) or not all(
            isinstance(item, str) for item in [*additions, *removals]
        ):
            raise ContractError(f"list patch for {dotted} must contain string lists")
        cursor = result
        parts = dotted.split(".")
        for part in parts[:-1]:
            child = cursor.setdefault(part, {})
            if not isinstance(child, dict):
                raise ContractError(f"list patch parent for {dotted} is not a mapping")
            cursor = child
        current = cursor.get(parts[-1], []) or []
        if not isinstance(current, list):
            raise ContractError(f"list patch target {dotted} is not a list")
        removed = set(removals)
        merged = [item for item in current if item not in removed]
        for item in additions:
            if item not in merged:
                merged.append(item)
        cursor[parts[-1]] = merged


def merge(base: dict, delta: dict) -> dict:
    ordinary = {key: value for key, value in delta.items() if key != LIST_PATCH_KEY}
    result = plain_merge(base, ordinary)
    apply_list_patches(result, delta.get(LIST_PATCH_KEY))
    return result


def role_transform(values: tuple[str, ...], role_plugin: str) -> tuple[str, ...]:
    transformed: list[str] = []
    for entry in (*values, role_plugin):
        if entry == "tts/voxxy" or entry in transformed:
            continue
        transformed.append(entry)
    return tuple(transformed)


def string_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ContractError(f"{label} must be a string list")
    return value


def ensure_patch(delta: dict) -> tuple[dict, list[str], list[str]]:
    directive = delta.setdefault(LIST_PATCH_KEY, {})
    if not isinstance(directive, dict):
        raise ContractError(f"{LIST_PATCH_KEY} must be a mapping")
    patches = directive.setdefault("list_patches", {})
    if not isinstance(patches, dict):
        raise ContractError(f"{LIST_PATCH_KEY}.list_patches must be a mapping")
    patch = patches.setdefault("plugins.enabled", {})
    if not isinstance(patch, dict):
        raise ContractError("plugins.enabled list patch must be a mapping")
    additions = patch.setdefault("add", [])
    removals = patch.setdefault("remove", [])
    return directive, string_list(additions, "plugins.enabled add patch"), string_list(
        removals, "plugins.enabled remove patch"
    )


def migrate_marked_snapshot(
    delta: dict,
    directive: dict,
    additions: list[str],
    removals: list[str],
    explicit: list[str] | None,
    role_plugin: str,
) -> bool:
    migrations = directive.get("migrations", {})
    if not isinstance(migrations, dict):
        raise ContractError(f"{LIST_PATCH_KEY}.migrations must be a mapping")
    marker = migrations.get(LEGACY_PROVENANCE_KEY)
    if marker is None:
        return False
    if not isinstance(marker, dict):
        raise ContractError(f"{LEGACY_PROVENANCE_KEY} migration must be a mapping")
    if marker.get("source") != "pjangler-52d9445":
        raise ContractError(f"{LEGACY_PROVENANCE_KEY} has unknown provenance")
    inherited = string_list(marker.get("inherited"), f"{LEGACY_PROVENANCE_KEY}.inherited")
    state = marker.get("state", "pending")
    if state == "completed":
        return True
    if state != "pending" or explicit is None:
        raise ContractError(f"{LEGACY_PROVENANCE_KEY} is not safely migratable")
    inherited_role = set(role_transform(tuple(inherited), role_plugin))
    for entry in explicit:
        if (
            entry not in inherited_role
            and entry not in {role_plugin, "tts/voxxy"}
            and entry not in additions
            and entry not in removals
        ):
            additions.append(entry)
    plugins = delta["plugins"]
    plugins.pop("enabled")
    if not plugins:
        delta.pop("plugins", None)
    marker["state"] = "completed"
    return True


def classify_unmarked_snapshot(
    delta: dict,
    directive: dict,
    additions: list[str],
    explicit: list[str],
    role_plugin: str,
) -> None:
    migrations = directive.setdefault("migrations", {})
    if not isinstance(migrations, dict):
        raise ContractError(f"{LIST_PATCH_KEY}.migrations must be a mapping")
    existing = migrations.get(MIGRATION_KEY)
    if existing is not None:
        if not isinstance(existing, dict):
            raise ContractError(f"{MIGRATION_KEY} must be a mapping")
        if existing.get("source") != "pjangler-52d9445" or existing.get("state") != "completed":
            raise ContractError(f"{MIGRATION_KEY} has invalid provenance")
        mode = existing.get("mode")
        if mode == "explicit-replacement":
            return
        if mode == "inherited-snapshot" and "enabled" not in (delta.get("plugins") or {}):
            return
        raise ContractError(f"{MIGRATION_KEY} state does not match plugins.enabled")

    explicit_set = set(explicit)
    matches: list[tuple[dict, tuple[str, ...]]] = []
    for record in SEALED_HISTORICAL_BASES:
        transformed = role_transform(record["plugins"], role_plugin)
        if set(transformed).issubset(explicit_set):
            matches.append((record, transformed))
    if len(matches) > 1:
        raise UnresolvedLegacySnapshot(
            "unmarked plugins.enabled matches multiple sealed 52d histories; "
            "manual provenance selection is required"
        )
    if len(matches) == 1:
        record, inherited = matches[0]
        inherited_set = set(inherited)
        for entry in explicit:
            if entry not in inherited_set and entry not in additions:
                additions.append(entry)
        plugins = delta["plugins"]
        plugins.pop("enabled")
        if not plugins:
            delta.pop("plugins", None)
        migrations[MIGRATION_KEY] = {
            "source": "pjangler-52d9445",
            "state": "completed",
            "mode": "inherited-snapshot",
            "sealed_base_id": record["id"],
            "sealed_base_sha256": record["sha256"],
        }
        return

    # A list containing no historical inherited member (apart from the
    # role-owned Vox plugin) is demonstrably an operator replacement. A partial
    # historical overlap is ambiguous: it might be an unknown generated fleet
    # snapshot, so preserve its bytes and require manual provenance instead of
    # silently freezing or deleting entries.
    omissions = [
        set(role_transform(record["plugins"], role_plugin)) - explicit_set
        for record in SEALED_HISTORICAL_BASES
    ]
    historical_inherited = set().union(
        *(
            set(role_transform(record["plugins"], role_plugin)) - {role_plugin}
            for record in SEALED_HISTORICAL_BASES
        )
    )
    if omissions and all(missing for missing in omissions) and not (
        explicit_set & historical_inherited
    ):
        migrations[MIGRATION_KEY] = {
            "source": "pjangler-52d9445",
            "state": "completed",
            "mode": "explicit-replacement",
        }
        return
    raise UnresolvedLegacySnapshot(
        "unmarked plugins.enabled only partially matches sealed 52d history; "
        "preserved it unchanged and requires manual provenance before Vox can be verified"
    )


def reconcile_delta(delta: dict, plugin: str, voice: str) -> None:
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", plugin):
        raise ContractError("invalid TTS plugin name")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", voice):
        raise ContractError("invalid TTS voice name")
    plugins = delta.get("plugins") or {}
    if not isinstance(plugins, dict):
        raise ContractError("plugins delta must be a mapping")
    explicit: list[str] | None = None
    if "enabled" in plugins:
        explicit = string_list(plugins["enabled"], "plugins.enabled delta")
    directive, additions, removals = ensure_patch(delta)
    role_plugin = f"tts/{plugin}"
    marked = migrate_marked_snapshot(
        delta, directive, additions, removals, explicit, role_plugin
    )
    if explicit is not None and not marked:
        classify_unmarked_snapshot(delta, directive, additions, explicit, role_plugin)
    additions[:] = [entry for entry in additions if entry not in {role_plugin, "tts/voxxy"}]
    additions.append(role_plugin)
    removals[:] = [entry for entry in removals if entry != role_plugin]
    if "tts/voxxy" not in removals:
        removals.append("tts/voxxy")
    tts = delta.setdefault("tts", {})
    if not isinstance(tts, dict):
        raise ContractError("tts delta must be a mapping")
    tts.pop("voxxy", None)
    tts["provider"] = plugin
    tts["voice"] = voice
    provider = tts.setdefault(plugin, {})
    if not isinstance(provider, dict):
        raise ContractError(f"tts.{plugin} delta must be a mapping")
    provider["voice"] = voice


def comments(original: bytes) -> list[str]:
    existing: list[str] = []
    for line in original.decode("utf-8").splitlines() if original else []:
        if line.lstrip().startswith("#") and line not in existing:
            existing.append(line)
    standard = [
        "# Override-only delta for this Hermes profile.",
        "# Contains configuration and secret references only; secret values remain in 1Password.",
    ]
    return [*standard, *(line for line in existing if line not in standard)]


def render_delta(delta: dict, original: bytes) -> bytes:
    return (
        "\n".join(comments(original))
        + "\n"
        + yaml.safe_dump(delta, sort_keys=False)
    ).encode("utf-8")


def render_generated(base: dict, delta: dict) -> bytes:
    header = (
        "# GENERATED FILE -- DO NOT EDIT.\n"
        "# source: fleet config.yaml + profile config.delta.yaml\n"
    )
    return (header + yaml.safe_dump(merge(base, delta), sort_keys=False)).encode("utf-8")


def snapshot(path: pathlib.Path, mode: int) -> FileSnapshot:
    require_regular(path, required=False)
    if not path.exists():
        return FileSnapshot(False, b"", mode)
    return FileSnapshot(True, path.read_bytes(), stat.S_IMODE(path.stat().st_mode))


def fsync_parent(path: pathlib.Path) -> None:
    unsupported = {errno.EINVAL, getattr(errno, "ENOTSUP", errno.EINVAL), errno.ENOSYS}
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    try:
        directory_fd = os.open(path.parent, flags)
    except OSError as exc:
        if exc.errno in unsupported:
            return
        raise
    try:
        try:
            os.fsync(directory_fd)
        except OSError as exc:
            if exc.errno not in unsupported:
                raise
    finally:
        os.close(directory_fd)


def atomic_write(path: pathlib.Path, content: bytes, mode: int = 0o600) -> None:
    require_regular(path, required=False)
    if path.is_file() and path.read_bytes() == content and stat.S_IMODE(path.stat().st_mode) == mode:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.voice-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, mode)
        fsync_parent(path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def restore(path: pathlib.Path, original: FileSnapshot) -> None:
    if original.existed:
        atomic_write(path, original.content, original.mode)
    elif path.is_file() or path.is_symlink():
        path.unlink()
        fsync_parent(path)


def paths(args: argparse.Namespace) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    base = pathlib.Path(args.base)
    delta = pathlib.Path(args.delta)
    generated = pathlib.Path(args.generated)
    profile = delta.parent
    if profile.is_symlink() or not profile.is_dir():
        raise ContractError(
            f"profile root must be a real directory: {profile}; run the pjangler "
            "Hermes runtime-singleton migration first"
        )
    require_regular(base)
    require_regular(delta, required=False)
    require_regular(generated, required=False)
    return base, delta, generated


def reconcile(args: argparse.Namespace) -> int:
    profile = pathlib.Path(args.delta).parent
    with PROFILE_LOCK.ProfileConfigLock(profile):
        base_path, delta_path, generated_path = paths(args)
        base = load_mapping(base_path)
        delta_original = snapshot(delta_path, 0o600)
        generated_original = snapshot(generated_path, 0o600)
        PROFILE_LOCK.test_snapshot_barrier("voice")
        delta = load_mapping(delta_path, required=False)
        reconcile_delta(delta, args.plugin, args.voice)
        delta_content = render_delta(delta, delta_original.content)
        generated_content = render_generated(base, delta)
        try:
            atomic_write(delta_path, delta_content)
            atomic_write(generated_path, generated_content)
        except BaseException:
            restore(generated_path, generated_original)
            restore(delta_path, delta_original)
            raise
    return 0


def check(args: argparse.Namespace) -> int:
    try:
        profile = pathlib.Path(args.delta).parent
        with PROFILE_LOCK.ProfileConfigLock(profile):
            base_path, delta_path, generated_path = paths(args)
            base = load_mapping(base_path)
            original_delta = load_mapping(delta_path, required=False)
            expected_delta = copy.deepcopy(original_delta)
            reconcile_delta(expected_delta, args.plugin, args.voice)
            generated = load_mapping(generated_path, required=False)
            if expected_delta == original_delta and generated == merge(
                base, expected_delta
            ):
                print("ok")
            else:
                print("drift")
    except UnresolvedLegacySnapshot as exc:
        print(f"manual|{exc}")
    except ContractError as exc:
        print(f"manual|{exc}")
    except PROFILE_LOCK.ProfileConfigLockError as exc:
        print(f"manual|{exc}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("check", "reconcile"):
        child = subparsers.add_parser(command)
        child.add_argument("--base", required=True)
        child.add_argument("--delta", required=True)
        child.add_argument("--generated", required=True)
        child.add_argument("--plugin", required=True)
        child.add_argument("--voice", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return check(args) if args.command == "check" else reconcile(args)
    except UnresolvedLegacySnapshot as exc:
        raise SystemExit(f"unresolved legacy plugin drift: {exc}") from exc
    except ContractError as exc:
        raise SystemExit(str(exc)) from exc
    except PROFILE_LOCK.ProfileConfigLockError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    raise SystemExit(main())
