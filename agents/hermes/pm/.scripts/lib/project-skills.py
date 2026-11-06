#!/usr/bin/env python3
"""Bind exact PM projects through a canonical writer and a live runtime adapter.

Project identity is independent of Git and of the desk's Skillex selection.
Discovery is checked separately using the actual pin in fresh processes.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

BLOCKED = 3
PROFILE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")


class BindingError(RuntimeError):
    def __init__(self, code, reason, **details):
        super().__init__(reason)
        self.code = code
        self.details = details


def regular(path):
    if not path.exists() and not path.is_symlink():
        raise FileNotFoundError(str(path))
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"regular non-symlink file required: {path}")
    return path.read_text(encoding="utf-8")


def canonical(value):
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError("an explicit project path is required")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise RuntimeError("project paths must be absolute")
    return path.resolve()


def runtime_pins(renderer):
    keys = {"HERMES_FLEET_REPO", "HERMES_FLEET_BIN"}
    pins = {key: os.environ.get(key) for key in keys}
    if not all(pins.values()):
        source = Path(__file__).parent / "parse-fleet-env.py"
        regular(source)
        spec = importlib.util.spec_from_file_location("project_skills_fleet_parser", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fleet_env = Path(os.environ.get("HERMES_FLEET_ENV", renderer.HERMES_HOME / "fleet.env"))
        # Parse only path assignments; never resolve or inspect credential values.
        text = regular(fleet_env)
        selected = "\n".join(line for line in text.splitlines() if re.match(
            r"^\s*(?:export\s+)?(?:HERMES_FLEET_REPO|HERMES_FLEET_BIN)=", line
        ))
        stored = dict(module.parse(selected, {}))
        pins = {key: pins[key] or stored.get(key) for key in keys}
    if not all(pins.values()):
        raise RuntimeError("actual HERMES_FLEET_REPO and HERMES_FLEET_BIN pins are required")
    repo, binary = (Path(pins[key]).expanduser() for key in ("HERMES_FLEET_REPO", "HERMES_FLEET_BIN"))
    if not repo.is_absolute() or repo.is_symlink() or not repo.is_dir():
        raise RuntimeError("pinned runtime repository must be a real absolute directory")
    # The ONE install (2026-10-17) execs the managed launcher <repo>/.hermes/bin/hermes; the venv
    # entry point is the pre-unification spelling. Either is the same install's own executable.
    if (binary not in (repo / ".venv/bin/hermes", repo / ".hermes/bin/hermes")
            or binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK)):
        raise RuntimeError("pinned HERMES_FLEET_BIN must be the executable in HERMES_FLEET_REPO/.hermes/bin/hermes "
                           "(or HERMES_FLEET_REPO/.venv/bin/hermes)")
    return repo, binary


RUNTIME_PROBE = r'''
import json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
request = json.load(sys.stdin)
from agent import skill_utils
from hermes_cli.config_defaults import DEFAULT_CONFIG
features = {key: key in (DEFAULT_CONFIG.get("skills") or {})
            for key in ("project_discovery", "trusted_project_dirs")}
api = {name: callable(getattr(skill_utils, name, None)) for name in
       ("find_project_root", "get_project_skills_dirs", "is_project_root_trusted")}
# The ONE precedence ordering: upstream folded get_scan_ordered_skills_dirs (removed as dead code,
# Hermes be5c6a2fd8) into get_skill_search_roots -> [(tier, dir), ...], project tier first.
search_roots = getattr(skill_utils, "get_skill_search_roots", None)
legacy_order = getattr(skill_utils, "get_scan_ordered_skills_dirs", None)
api["scan_ordered_skills_dirs"] = callable(search_roots) or callable(legacy_order)
def ordered_dirs():
    if callable(search_roots):
        return [str(d) for _tier, d in search_roots()]
    return [str(p) for p in legacy_order()]
result = {"cwd": os.getcwd(), "features": features, "api": api}
if all(api.values()):
    root = skill_utils.find_project_root()
    result.update(root=str(root) if root is not None else None,
                  trusted=skill_utils.is_project_root_trusted(Path(request["project_root"])),
                  project_dirs=[str(p) for p in skill_utils.get_project_skills_dirs()],
                  ordered_dirs=ordered_dirs())
    if request.get("skill"):
        from tools.skills_tool import skill_view
        # The normal support-file branch returns the lexical source path before
        # prerequisite/env capture, usage accounting and preprocessing can run.
        view = json.loads(skill_view(request["skill"], file_path="SKILL.md", preprocess=False))
        result["skill_view"] = {key: view.get(key) for key in ("success", "_source_path", "error")}
print(json.dumps(result))
'''


class ProfileSkillsRuntime:
    """Execute the actual resolver; hashes detect source changes during a run."""

    def source_evidence(self):
        required = ("tools/skills_tool.py", "agent/skill_utils.py", "hermes_cli/config_defaults.py")
        optional = ("agent/runtime_cwd.py", "hermes_constants.py", "hermes_cli/config.py",
                    "tools/skills_guard.py", "tools/path_security.py")
        paths = [self.repo / name for name in required]
        paths.extend(self.repo / name for name in optional if (self.repo / name).is_file())
        paths.append(self.binary)
        evidence = []
        for path in paths:
            regular(path)
            evidence.append({"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        return evidence

    def unchanged(self, renderer):
        if runtime_pins(renderer) != (self.repo, self.binary) or self.source_evidence() != self.sources:
            raise RuntimeError("pinned runtime paths or resolver source changed during assessment")

    def observe(self, profile, root, cwd, *, skill=None):
        try:
            process = subprocess.run(
                [str(self.python), "-I", "-B", "-c", RUNTIME_PROBE, str(self.repo)],
                input=json.dumps({"project_root": str(root), "skill": skill}),
                cwd=cwd, env={"HOME": str(Path.home()), "PATH": os.defpath,
                              "HERMES_HOME": str(profile), "PYTHONDONTWRITEBYTECODE": "1"},
                capture_output=True, text=True, timeout=20,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("pinned resolver probe timed out after 20 seconds") from error
        if process.returncode:
            raise RuntimeError(f"pinned resolver probe failed (exit {process.returncode})")
        try:
            return json.loads(process.stdout)
        except ValueError as error:
            raise RuntimeError("pinned resolver probe did not return JSON") from error

    def inspect(self, renderer):
        self.repo, self.binary = runtime_pins(renderer)
        self.python = self.repo / ".venv/bin/python"
        if not self.python.is_file() or not os.access(self.python, os.X_OK):
            raise RuntimeError("pinned runtime Python is unavailable")
        self.sources = self.source_evidence()
        with tempfile.TemporaryDirectory(prefix="hermes-project-capability-") as tmp:
            root, profile = Path(tmp) / "project", Path(tmp) / "profile"
            (root / ".git").mkdir(parents=True)
            name = "project-capability-proof"
            for directory in (root / ".agents/skills" / name, profile / "skills" / name):
                directory.mkdir(parents=True)
                (directory / "SKILL.md").write_text(
                    f"---\nname: {name}\ndescription: Disposable resolver fixture.\n---\nFixture.\n"
                )
            config = profile / "config.yaml"

            def settings(discovery, roots):
                config.write_text(json.dumps({"skills": {"external_dirs": [], "project_discovery": discovery,
                                                       "trusted_project_dirs": roots}}))

            settings(True, [str(root)])
            enabled = self.observe(profile, root, root, skill=name)
            features = enabled["features"]
            supported = all(features.values()) and all(enabled["api"].values())
            probes = {"enabled": enabled}
            if supported:
                expected_dir = str(root / ".agents/skills")
                supported = (enabled.get("root") == str(root) and enabled.get("trusted") is True
                             and expected_dir in enabled.get("project_dirs", [])
                             and enabled.get("ordered_dirs", [None])[0] == expected_dir
                             and enabled.get("skill_view", {}).get("success") is True
                             and enabled["skill_view"].get("_source_path") == str(root / ".agents/skills" / name / "SKILL.md"))
                settings(False, [str(root)])
                probes["disabled"] = self.observe(profile, root, root)
                settings(True, [])
                probes["untrusted"] = self.observe(profile, root, root)
                supported = (supported and probes["disabled"].get("project_dirs") == []
                             and probes["untrusted"].get("project_dirs") == [])
        self.unchanged(renderer)
        result = {"repo": str(self.repo), "bin": str(self.binary), "python": str(self.python),
                  "features": features, "adapter": "trusted-project-dirs", "supported": supported,
                  "source_evidence": self.sources, "capability_probes": probes}
        if not supported:
            result["blocker"] = {
                "code": "runtime_project_discovery_unverified" if all(features.values()) else "runtime_project_discovery_unsupported",
                "reason": "Pinned runtime execution did not prove exact-root trust, discovery toggles and lexical project skill precedence.",
            }
        return result


def registry_identity(registry, root, role, profile, agent_id, renderer, policy):
    if not registry.exists() and not registry.is_symlink():
        if agent_id is not None:
            raise BindingError("binding_registry_mismatch", "Registered PM inventory is no longer available.")
        return None
    regular(registry)
    document = policy.load_mapping(registry, renderer)
    agents = document.get("agents")
    if not isinstance(agents, dict):
        raise BindingError("binding_registry_mismatch", "Registry agents must be a mapping.")
    matches = [(key, row) for key, row in agents.items()
               if isinstance(row, dict) and row.get("profile_name") == profile]
    if not matches and agent_id is None:
        return None
    if len(matches) != 1:
        raise BindingError("binding_registry_mismatch", "Profile must have exactly one independently verified registry identity.")
    registered_id, row = matches[0]
    if (row.get("role") != "pm" or (agent_id is not None and registered_id != agent_id)
            or canonical(row.get("project_path")) != root or canonical(row.get("role_dir")) != role):
        raise BindingError("binding_registry_mismatch", "Registry profile/project/role identity disagrees with the explicit binding.")
    return registered_id


def binding(root_value, role_value, profile, agent_id, renderer, policy, registry):
    root = canonical(root_value)
    if root in (Path.home().resolve(), Path("/")) or not root.is_dir():
        raise RuntimeError("project root must be an existing project directory, never HOME or /")
    role = canonical(role_value)
    if role != root / "agents/hermes/pm":
        raise RuntimeError("role directory does not belong to the exact canonical project")
    registered_id = registry_identity(registry, root, role, profile, agent_id, renderer, policy)
    regular(role / "role.yaml")
    role_data = policy.load_mapping(role / "role.yaml", renderer)
    if not isinstance(role_data, dict) or role_data.get("role") != "pm" or role_data.get("profile") != profile:
        raise RuntimeError("role.yaml role/profile disagrees with the registered PM")
    declared_id = role_data.get("agent_id")
    if not isinstance(declared_id, str) or PROFILE_NAME.fullmatch(declared_id) is None:
        raise RuntimeError("role.yaml must declare an exact agent identity")
    if registered_id is not None and declared_id != registered_id:
        raise RuntimeError("role.yaml agent_id disagrees with the registered PM")
    manifest_path = root / ".project.json"
    if not manifest_path.exists() and not manifest_path.is_symlink():
        if registered_id is None:
            raise BindingError("binding_evidence_insufficient", f"Unregistered explicit root lacks independent manifest evidence: {manifest_path}",
                               manifest_status="missing", role_identity_status="verified", registry_identity_status="unregistered")
        manifest_status = "missing"
    else:
        manifest = json.loads(regular(manifest_path))
        if not isinstance(manifest, dict) or canonical(manifest.get("repo_path")) != root:
            raise RuntimeError(".project.json repo_path disagrees with the exact canonical project")
        entries = manifest.get("agents")
        claim = entries.get(declared_id) if isinstance(entries, dict) else None
        if not isinstance(claim, dict) or claim.get("role") != "pm" or claim.get("role_dir") != "agents/hermes/pm":
            raise RuntimeError(".project.json PM role claim disagrees with role.yaml")
        manifest_status = "verified"
    soul = renderer.PROFILES / profile / "SOUL.md"
    if soul.is_symlink():
        target = soul.resolve(strict=True)
        if not target.is_file() or not target.is_relative_to(role):
            raise BindingError("binding_soul_mismatch", "Profile SOUL symlink does not belong to the exact PM role.")
        soul_status, soul_target = "symlink", str(target)
    elif soul.is_file():
        soul_status, soul_target = "plain_file", None
    else:
        raise BindingError("binding_soul_missing", "Profile SOUL must be an existing plain file or an exact-role symlink.")
    skills = root / ".agents/skills"
    return {"project_root": str(root), "role_dir": str(role), "project_skills_dir": str(skills),
            "skills_directory_status": "present" if skills.is_dir() else "missing",
            "agent_id": declared_id, "manifest_status": manifest_status, "role_identity_status": "verified",
            "registry_identity_status": "verified" if registered_id is not None else "unregistered",
            "binding_source": "registry+role" if registered_id is not None else "manifest+role",
            "soul_status": soul_status, "soul_target": soul_target, "trust_eligible": True}


def config_enabled(config, root):
    skills = config.get("skills") or {}
    roots = skills.get("trusted_project_dirs") or []
    return (skills.get("project_discovery") is True and skills.get("external_dirs") == []
            and isinstance(roots, list) and str(root) in roots)


def discovery_status(observations, root):
    project = observations["project_cwd"]
    if project.get("root") is None:
        return "no_native_root"
    if project.get("root") != str(root):
        return "different_native_root"
    if project.get("project_dirs"):
        return "discovered"
    return "root_resolved_no_project_skills"


def targets(args, renderer, policy):
    if args.project_root or args.role_dir:
        if not args.profile or not args.project_root or not args.role_dir:
            raise RuntimeError("explicit project binding requires --profile, --project-root and --role-dir")
        return [(None, {"profile_name": args.profile, "project_path": args.project_root, "role_dir": args.role_dir})]
    regular(Path(args.registry))
    document = policy.load_mapping(Path(args.registry), renderer)
    agents = document.get("agents") if isinstance(document, dict) else None
    if not isinstance(agents, dict):
        raise RuntimeError("registry agents must be a mapping")
    rows = [(key, row) for key, row in agents.items() if isinstance(row, dict) and row.get("role") == "pm"]
    if args.profile:
        rows = [(key, row) for key, row in rows if row.get("profile_name") == args.profile]
        if len(rows) != 1:
            raise RuntimeError("profile must identify exactly one registered PM")
    return sorted(rows, key=lambda item: str(item[1].get("profile_name", "")))


def command(args, renderer, policy):
    rows = targets(args, renderer, policy)
    if not rows:
        raise RuntimeError("no registered PM profiles found")
    adapter = ProfileSkillsRuntime()
    try:
        runtime = adapter.inspect(renderer)
    except (OSError, ValueError, RuntimeError, SyntaxError) as error:
        runtime = {"supported": False, "blocker": {"code": "runtime_pin_invalid", "reason": str(error)}}
    report = {"schema": "hermes-project-skills/3", "status": "ok", "dry_run": args.dry_run,
              "runtime": runtime, "profiles": []}
    for agent_id, row in rows:
        name = row.get("profile_name")
        result = {"agent_id": agent_id, "profile": name, "project_root": row.get("project_path"),
                  "role_dir": row.get("role_dir"), "config_changed": False, "outcome": "blocked", "blockers": [],
                  "trust_eligible": False, "config_enabled": False}
        try:
            if not isinstance(name, str) or PROFILE_NAME.fullmatch(name) is None:
                raise RuntimeError("registered PM profile name is invalid")
            profile = renderer.PROFILES / name
            with renderer.PROFILE_LOCK.ProfileConfigLock(profile):
                # The same lock protects snapshot/validation as the real writer.
                snapshot = policy.policy_snapshot(profile, renderer)
                _, delta, base, current = snapshot
                # THE expected config (base + delta + renderer pins), never a local deep_merge: a
                # pinned desk is a pure render, and a pin-only difference is a stale render.
                if not any(renderer.is_render_of(current, base, candidate, name)
                           for candidate in (delta, policy.strict_delta(delta))):
                    result["blockers"].append({"code": "profile_config_drift", "reason": "check/absorb the generated config before project enablement"})
                try:
                    root = canonical(row.get("project_path"))
                    skills = root / ".agents/skills"
                    result.update({"project_root": str(root), "project_skills_dir": str(skills),
                                   "skills_directory_status": "present" if skills.is_dir() else "missing"})
                    result.update(binding(row.get("project_path"), row.get("role_dir"), name, agent_id, renderer, policy,
                                          Path(args.registry)))
                    result["config_enabled"] = config_enabled(current or {}, root)
                except (OSError, ValueError, RuntimeError) as error:
                    code = error.code if isinstance(error, BindingError) else "binding_role_missing" if isinstance(error, FileNotFoundError) else "binding_manifest_mismatch"
                    if isinstance(error, BindingError):
                        result.update(error.details)
                    result["blockers"].append({"code": code, "reason": str(error)})
                if not runtime["supported"]:
                    result["blockers"].append(runtime["blocker"])
                if not result["blockers"]:
                    observations = {"project_cwd": adapter.observe(profile, root, root),
                                    "role_cwd": adapter.observe(profile, root, Path(result["role_dir"]))}
                    result["resolver"] = observations
                    result["native_discovery_status"] = discovery_status(observations, root)
                    has_git_marker = (root / ".git").exists()
                    if has_git_marker and observations["project_cwd"].get("root") != str(root):
                        result["blockers"].append({"code": "project_root_unresolved",
                            "reason": "Pinned resolver from canonical project CWD does not resolve the exact registered root."})
                    if has_git_marker and observations["role_cwd"].get("root") != str(root):
                        result["blockers"].append({"code": "role_project_root_mismatch",
                            "reason": "Pinned resolver from role CWD does not resolve the canonical project; no ancestor or role trust was substituted."})
                if not result["blockers"]:
                    adapter.unchanged(renderer)
                    outcome = policy.set_policy_locked(profile, renderer, dry_run=args.dry_run,
                                                       project_root=root, snapshot=snapshot)
                    result.update(outcome=outcome, config_changed=outcome == "updated")
                    result["config_enabled_after_apply"] = True
                    if not args.dry_run:
                        result["config_enabled"] = True
                        after = {"project_cwd": adapter.observe(profile, root, root),
                                 "role_cwd": adapter.observe(profile, root, Path(result["role_dir"]))}
                        result["resolver_after"] = after
                        result["native_discovery_status"] = discovery_status(after, root)
                        adapter.unchanged(renderer)
        except renderer.PROFILE_LOCK.ProfileConfigLockError as error:
            result["blockers"].append({"code": "profile_lock_failed", "reason": str(error)})
        except (OSError, ValueError, RuntimeError) as error:
            result["blockers"].append({"code": "profile_invalid", "reason": str(error)})
        report["profiles"].append(result)
    blocked = [row for row in report["profiles"] if row["blockers"]]
    report["status"] = "partial" if blocked and len(blocked) < len(rows) else "blocked" if blocked else "ok"
    report["counts"] = {"requested_bindings": len(rows),
                        "registered_pms": sum(row.get("registry_identity_status") == "verified" for row in report["profiles"]),
                        "trust_eligible": sum(row["trust_eligible"] for row in report["profiles"]),
                        "config_enabled": sum(row["config_enabled"] for row in report["profiles"]),
                        "native_discovered": sum(row.get("native_discovery_status") == "discovered" for row in report["profiles"]),
                        "supported": len(rows) - len(blocked), "blocked": len(blocked),
                        "updated": sum(row["config_changed"] for row in report["profiles"]),
                        "missing_skill_dirs": sum(row.get("skills_directory_status") == "missing" for row in report["profiles"])}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for row in report["profiles"]:
            reasons = "; ".join(item["reason"] for item in row["blockers"])
            label = "BLOCKED" if row["blockers"] else row["outcome"]
            print(f"project skills {label} {row['profile']} -> {row['project_root']}: {reasons}")
    return BLOCKED if blocked else 0
