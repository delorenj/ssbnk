#!/usr/bin/env python3
"""Pin a PM profile's skill discovery to its own Skillex-owned skills root.

Writes exactly one override, ``skills.external_dirs: []``, into the profile's
config.delta.yaml under the canonical renderer's profile lock, then regenerates
config.yaml only when it is a pure render of base + delta. Idempotent: a
profile that already carries the override is left byte-for-byte alone.
"""
import copy
import importlib.util
import os
from pathlib import Path
import sys
import uuid

OVERRIDE = "skills:\n  external_dirs: []\n"


def load_renderer(profile, source):
    if source.is_symlink() or not source.is_file():
        raise RuntimeError("canonical profile renderer must be a regular non-symlink file")
    os.environ["HERMES_FLEET_HOME"] = str(profile.parent.parent)
    spec = importlib.util.spec_from_file_location("pm_skills_renderer", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("canonical profile renderer unavailable")
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    return renderer


def load_mapping(path, renderer):
    """Refuse duplicate keys rather than dropping an existing trust/reference."""
    class UniqueLoader(renderer.yaml.SafeLoader):
        pass

    def mapping(loader, node):
        loader.flatten_mapping(node)
        value = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node)
            if key in value:
                raise RuntimeError(f"duplicate config key in {path}")
            value[key] = loader.construct_object(value_node)
        return value

    UniqueLoader.add_constructor(renderer.yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
    try:
        value = renderer.yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueLoader)
    except renderer.yaml.YAMLError as error:
        raise RuntimeError(f"cannot parse config YAML: {path}") from error
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise RuntimeError("base, delta and generated config must be mappings")
    return value


def strict_delta(delta):
    value = copy.deepcopy(delta)
    skills = value.get("skills")
    if skills is None:
        skills = {}
    if not isinstance(skills, dict):
        raise RuntimeError("skills delta must be a mapping")
    value["skills"] = {**skills, "external_dirs": []}
    return value


def project_delta(delta, base, project_root, renderer):
    """Append exact project trust without freezing the inherited base list."""
    value = strict_delta(delta)
    skills = value["skills"]
    base_skills = base.get("skills") or {}
    if not isinstance(base_skills, dict):
        raise RuntimeError("fleet skills config must be a mapping")
    inherited = base_skills.get("trusted_project_dirs", []) or []
    explicit = skills.get("trusted_project_dirs", []) or []
    for roots in (inherited, explicit):
        if not isinstance(roots, list) or not all(isinstance(root, str) for root in roots):
            raise RuntimeError("skills.trusted_project_dirs must be a string list")
    directive = value.setdefault(renderer.LIST_PATCH_KEY, {})
    if not isinstance(directive, dict):
        raise RuntimeError("template merge directive must be a mapping")
    patches = directive.setdefault("list_patches", {})
    if not isinstance(patches, dict):
        raise RuntimeError("template list patches must be a mapping")
    patch = patches.setdefault("skills.trusted_project_dirs", {})
    if not isinstance(patch, dict):
        raise RuntimeError("project trust list patch must be a mapping")
    additions = patch.setdefault("add", [])
    removals = patch.get("remove", [])
    if not all(isinstance(roots, list) and all(isinstance(root, str) for root in roots)
               for roots in (additions, removals)):
        raise RuntimeError("project trust patches must be string lists")
    for root in (*explicit, str(project_root)):
        if root not in additions:
            additions.append(root)
    if str(project_root) in removals:
        patch["remove"] = [root for root in removals if root != str(project_root)]
    skills.pop("trusted_project_dirs", None)
    skills["project_discovery"] = True
    return value


def candidate_text(text, delta):
    """Keep the operator's comments: add the override as text when the delta
    has no skills block yet; otherwise keep the leading comment header and
    re-serialize the mapping."""
    if "skills" not in delta:
        lines = text.splitlines(keepends=True)
        body = [line for line in lines if line.strip() and not line.lstrip().startswith("#")]
        if [line.strip() for line in body] == ["{}"]:
            index = next(i for i, line in enumerate(lines) if line.strip() == "{}")
            return "".join(lines[:index]) + OVERRIDE + "".join(lines[index + 1:])
        if not body:
            return text + ("" if not text or text.endswith("\n") else "\n") + OVERRIDE
        return text + ("" if text.endswith("\n") else "\n") + "\n" + OVERRIDE
    return None


def leading_comments(text):
    header = []
    for line in text.splitlines(keepends=True):
        if line.strip() and not line.lstrip().startswith("#"):
            break
        header.append(line)
    return "".join(header)


def write_atomic(path, text):
    stage = path.parent / (".skills-policy-" + uuid.uuid4().hex)
    try:
        with stage.open("x", encoding="utf-8") as handle:
            os.chmod(stage, 0o600)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(stage, path)
    finally:
        stage.unlink(missing_ok=True)


def policy_snapshot(profile, renderer):
    """Read only while the caller holds the shared profile lock."""
    if profile.is_symlink() or not profile.is_dir():
        raise RuntimeError("profile root must be a real directory, not a symlink")
    path = profile / "config.delta.yaml"
    config = profile / "config.yaml"
    for target in (path, config, renderer.BASE):
        if target.is_symlink():
            raise RuntimeError(f"refusing config symlink: {target}")
        if target.exists() and not target.is_file():
            raise RuntimeError(f"regular config file required: {target}")
    if not path.is_file() or not renderer.BASE.is_file():
        raise RuntimeError("regular fleet base and profile delta required")
    text = path.read_text(encoding="utf-8")
    delta = load_mapping(path, renderer)
    base = load_mapping(renderer.BASE, renderer)
    current = load_mapping(config, renderer) if config.exists() else None
    if not isinstance(delta, dict) or not isinstance(base, dict) or (
        current is not None and not isinstance(current, dict)
    ):
        raise RuntimeError("base, delta and generated config must be mappings")
    renderer.PROFILE_LOCK.test_snapshot_barrier("skills-policy")
    return text, delta, base, current


def set_policy_locked(profile, renderer, *, dry_run=False, project_root=None, snapshot=None):
    """Strict loadout policy; no recursive lock acquisition or project rebind."""
    text, old_delta, base, current = snapshot if snapshot is not None else policy_snapshot(profile, renderer)
    path = profile / "config.delta.yaml"
    config = profile / "config.yaml"
    delta = strict_delta(old_delta) if project_root is None else project_delta(old_delta, base, project_root, renderer)
    # THE expected config (base + delta + every renderer pin). A bare deep_merge here refused every
    # pinned desk as drift and, on write, stripped its pin.
    expected = renderer.expected_config(base, delta, profile.name)
    if project_root is not None and (expected.get("skills") or {}).get("external_dirs") != []:
        raise RuntimeError("skills.external_dirs list patch conflicts with the strict profile loadout")
    if current is not None and not any(
        renderer.is_render_of(current, base, candidate, profile.name)
        for candidate in (old_delta, strict_delta(old_delta), delta)
    ):
        raise RuntimeError(
            "config.yaml has out-of-band drift; inspect with hermes-profile-config.py "
            "check, review `absorb --profile <name> --dry-run`, then absorb it before enforcing the PM skills policy"
        )
    changed = old_delta != delta or current != expected
    if dry_run or not changed:
        return "would-update" if changed else "unchanged"
    if old_delta != delta:
        proposed = candidate_text(text, old_delta)
        if proposed is None or (renderer.yaml.safe_load(proposed) or {}) != delta:
            proposed = leading_comments(text) + renderer.dump_yaml(delta)
        write_atomic(path, proposed)
    if current != expected:
        renderer.write_generated(config, expected)
    return "updated"


def set_policy(profile, source=None, *, renderer=None, dry_run=False):
    if renderer is None:
        renderer = load_renderer(profile, source)
    with renderer.PROFILE_LOCK.ProfileConfigLock(profile):
        return set_policy_locked(profile, renderer, dry_run=dry_run)


if __name__ == "__main__":
    try:
        set_policy(Path(sys.argv[1]), Path(sys.argv[2]))
    except RuntimeError as error:
        print(f"skills-policy: {error}", file=sys.stderr)
        raise SystemExit(1)
