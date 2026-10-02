#!/usr/bin/env python3
"""Pin a PM profile's skill discovery to its own Skillex-owned skills root.

Writes exactly one override, ``skills.external_dirs: []``, into the profile's
config.delta.yaml under the canonical renderer's profile lock, then regenerates
config.yaml only when it is a pure render of base + delta. Idempotent: a
profile that already carries the override is left byte-for-byte alone.
"""
import importlib.util
import os
from pathlib import Path
import sys
import uuid

OVERRIDE = "skills:\n  external_dirs: []\n"


def load_renderer(profile, source):
    os.environ["HERMES_FLEET_HOME"] = str(profile.parent.parent)
    spec = importlib.util.spec_from_file_location("pm_skills_renderer", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("canonical profile renderer unavailable")
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    return renderer


def strict_delta(delta):
    value = dict(delta)
    skills = value.get("skills")
    if skills is None:
        skills = {}
    if not isinstance(skills, dict):
        raise RuntimeError("skills delta must be a mapping")
    value["skills"] = {**skills, "external_dirs": []}
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


def set_policy(profile, source):
    renderer = load_renderer(profile, source)
    with renderer.PROFILE_LOCK.ProfileConfigLock(profile):
        path = profile / "config.delta.yaml"
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("regular profile delta required")
        text = path.read_text(encoding="utf-8")
        old_delta = renderer.load_yaml(path)
        if not isinstance(old_delta, dict):
            raise RuntimeError("profile delta must be a mapping")
        delta = strict_delta(old_delta)
        base = renderer.load_yaml(renderer.BASE)
        expected = renderer.deep_merge(base, delta)
        config = profile / "config.yaml"
        if config.is_symlink():
            raise RuntimeError("generated config must not be a symlink")
        current = renderer.load_yaml(config) if config.exists() else None
        rendered_before = current is None or current in (
            renderer.deep_merge(base, old_delta), expected
        )
        current_dirs = ((current or {}).get("skills") or {}).get("external_dirs")
        if not rendered_before and current_dirs != []:
            raise RuntimeError(
                "config.yaml has out-of-band drift; inspect with hermes-profile-config.py "
                "check and absorb it before enforcing the PM skills policy"
            )
        if old_delta != delta:
            renderer.backup([path, config], "skills-policy")
            proposed = candidate_text(text, old_delta)
            if proposed is None or (renderer.yaml.safe_load(proposed) or {}) != delta:
                proposed = leading_comments(text) + renderer.dump_yaml(delta)
            write_atomic(path, proposed)
        if rendered_before and current != expected:
            renderer.write_generated(config, expected)


if __name__ == "__main__":
    try:
        set_policy(Path(sys.argv[1]), Path(sys.argv[2]))
    except RuntimeError as error:
        print(f"skills-policy: {error}", file=sys.stderr)
        raise SystemExit(1)
