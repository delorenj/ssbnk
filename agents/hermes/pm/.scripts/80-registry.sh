#!/usr/bin/env bash
# Append this agent's entry to the global fleet registry.

if [[ "${SKIP_HOST_STATE:-0}" == "1" ]]; then
  printf '%s\n' '[80] fleet registry — DEFERRED (SKIP_HOST_STATE=1)' >&2
  exit 0
fi

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

fleet_lock_acquire
trap 'fleet_lock_release' EXIT

[[ ! -L "$REGISTRY_FILE" ]] || die "refusing to update registry symlink: $REGISTRY_FILE"
mkdir -p "$(dirname "$REGISTRY_FILE")"
if [[ ! -f "$REGISTRY_FILE" ]]; then
  cat > "$REGISTRY_FILE" <<'YAML'
# Hermes agent fleet registry.
# One entry per provisioned agent. Managed by hermes-agent-template/.scripts/80-registry.sh.
schema_version: 1
agents: {}
YAML
fi

PROJECT_PATH="$(project_repo_path)" || PROJECT_PATH=""
PLANE_PROJECT_ID="$(cat "$ROLE_DIR/.scripts/.plane-project-id" 2>/dev/null || true)"

log "[80] appending to fleet registry: $REGISTRY_FILE"

python3 - "$REGISTRY_FILE" "$AGENT_ID" "$REPO" "$ROLE" "$DISPLAY_NAME" \
  "$PROJECT_PATH" "$ROLE_DIR" "$PROFILE_NAME" \
  "$(yaml_get telegram.provisioning_status)" "$BOT_HANDLE" "$(yaml_get telegram.bot_id)" \
  "$(yaml_get slack.provisioning_status)" "$(yaml_get slack.team_id)" \
  "$(yaml_get slack.team_name)" "$(yaml_get slack.bot_user_id)" \
  "$(yaml_get slack.bot_id)" "$(yaml_get slack.bot_username)" \
  "$ROLE_YAML" "$(yaml_get bloodbank.gateway_scope)" \
  "$(yaml_get bloodbank.target_agent_id)" \
  "$PLANE_WORKSPACE" "$PLANE_PROJECT_ID" "$(yaml_get plane.identifier)" \
  "$HERMES_BIN" "$HERMES_AGENT_REPO" "$HERMES_RUNTIME_GIT_URL" \
  "$HERMES_RUNTIME_GIT_REF" "$HERMES_RUNTIME_GIT_SHA" "$FLEET_ENV" \
  "hermes-${AGENT_ID}-gateway.service" "hermes-${AGENT_ID}-heartbeat.timer" \
  "$(yaml_get service_state.gateway)" "$(yaml_get service_state.heartbeat)" <<'PYEOF'
import datetime
import copy
import errno
import os
import pathlib
import re
import sys
import tempfile
try:
    import yaml  # type: ignore
except ImportError:
    sys.exit("PyYAML required; pip install pyyaml")
(path, agent_id, repo, role, display, project, role_dir, profile,
 telegram_status, bot, telegram_bot_id,
 slack_status, slack_team_id, slack_team_name, slack_user_id, slack_bot_id,
 slack_username, role_yaml, bloodbank_scope, bloodbank_target, plane_ws, plane_id,
 plane_ident, hermes_bin, hermes_repo, hermes_git_url,
 hermes_git_ref, hermes_git_sha, fleet_env, gw, heartbeat,
 gateway_state, heartbeat_state) = sys.argv[1:34]
p = pathlib.Path(path)
if p.is_symlink():
    raise SystemExit(f"refusing to update registry symlink: {p}")
data = yaml.safe_load(p.read_text(encoding="utf-8")) or {"schema_version": 1, "agents": {}}
if not isinstance(data, dict):
    raise SystemExit("fleet registry root must be a mapping")
agents = data.setdefault("agents", {})
if not isinstance(agents, dict):
    raise SystemExit("fleet registry agents must be a mapping")


class StrictRoleLoader(yaml.SafeLoader):
    """YAML with only `true`/`false` as booleans and no duplicate keys.

    PyYAML's YAML 1.1 resolver turns `yes`, `on` and `True` into booleans,
    which would be activation-by-coercion; here they stay strings and are
    refused. A duplicated key is refused too, because last-wins would let a
    second `bloodbank:` block silently discard the first one's quarantine.
    """


StrictRoleLoader.yaml_implicit_resolvers = {
    first: [(tag, rx) for tag, rx in resolvers if tag != "tag:yaml.org,2002:bool"]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
StrictRoleLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$"), list("tf")
)


def construct_unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise SystemExit(f"role.yaml has a duplicate key {key!r} ({key_node.start_mark})")
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)


StrictRoleLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_unique_mapping
)


def role_bloodbank_enabled(role_path):
    """bloodbank.enabled, read by a YAML parser rather than a line scan.

    The shell `yaml_get` once scanned past the end of the `bloodbank:` block,
    so an absent key read a later `reconcile.enabled: false` and quarantined
    the agent. A parser cannot do that: the key is either in this mapping or
    it is not. No key means enabled; only an explicit `false` quarantines; any
    other present value (a string, `yes`, null, "") is refused.
    """
    try:
        role_doc = yaml.load(pathlib.Path(role_path).read_text(encoding="utf-8"), Loader=StrictRoleLoader)
    except yaml.YAMLError as exc:
        raise SystemExit(f"role.yaml is not valid YAML: {exc}")
    if not isinstance(role_doc, dict):
        raise SystemExit("role.yaml root must be a mapping")
    bloodbank = role_doc.get("bloodbank")
    if bloodbank is None:
        return True
    if not isinstance(bloodbank, dict):
        raise SystemExit("role.yaml bloodbank must be a mapping")
    if "enabled" not in bloodbank:
        return True
    if isinstance(bloodbank["enabled"], bool):
        return bloodbank["enabled"]
    raise SystemExit("bloodbank.enabled must be the strict YAML boolean true or false")


bloodbank_enabled_value = role_bloodbank_enabled(role_yaml)
existing = agents.get(agent_id, {})
if not isinstance(existing, dict):
    raise SystemExit(f"fleet registry entry for {agent_id} must be a mapping")
provisioned_at = existing.get("provisioned_at")
if not isinstance(provisioned_at, str) or not provisioned_at:
    provisioned_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
managed = {
  # The RUNTIME this row describes. Emitted on every provision so a re-provision
  # can never drop the field back to an assumption: the registry states the
  # runtime, it is not inferred from the fact that this template wrote the row.
  "repo": repo, "role": role, "type": "hermes", "display_name": display,
  "project_path": project, "role_dir": role_dir,
  "profile_name": profile,
  "telegram": {
    "provisioning_status": telegram_status,
    "bot_username": bot,
    "bot_id": telegram_bot_id,
  },
  "slack": {
    "provisioning_status": slack_status,
    "team_id": slack_team_id,
    "team_name": slack_team_name,
    "bot_user_id": slack_user_id,
    "bot_id": slack_bot_id,
    "bot_username": slack_username,
  },
  "bloodbank": {
    "enabled": bloodbank_enabled_value,
    "gateway_scope": bloodbank_scope,
    "target_agent_id": bloodbank_target,
  },
  "plane": {"workspace": plane_ws, "project_id": plane_id, "identifier": plane_ident},
  # No `runtime_repo`. An agent runtime is host-local and may hold secrets and
  # mutable state (PJAN-41); it is never a Git repository, never a submodule, and
  # never pushed anywhere. Durability belongs to Hindsight.
  "hermes": {
    "bin": hermes_bin,
    "repo": hermes_repo,
    "git_url": hermes_git_url,
    "git_ref": hermes_git_ref,
    "git_sha": hermes_git_sha,
    "fleet_env": fleet_env,
  },
  "systemd": {
    "gateway_unit": gw,
    "heartbeat_timer": heartbeat,
    "gateway_state": gateway_state,
    "heartbeat_state": heartbeat_state,
  },
  "provisioned_at": provisioned_at,
}

def merge_managed(current, update):
    result = copy.deepcopy(current)
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_managed(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result

entry = merge_managed(existing, managed)
# This is retired managed schema, not extension metadata.  Keeping it would
# falsely advertise a second per-agent Bloodbank execution path.
systemd = entry.get("systemd")
if isinstance(systemd, dict):
    systemd.pop("consumer_unit", None)
agents[agent_id] = entry
rendered = yaml.safe_dump(data, sort_keys=False)
p.parent.mkdir(parents=True, exist_ok=True)

def fsync_parent(target):
    unsupported = {errno.EINVAL, getattr(errno, "ENOTSUP", errno.EINVAL), errno.ENOSYS}
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    try:
        directory_fd = os.open(target.parent, flags)
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

fd, temporary = tempfile.mkstemp(prefix=f".{p.name}.registry-", dir=p.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, p)
    os.chmod(p, 0o600)
    fsync_parent(p)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PYEOF

fleet_lock_release
trap - EXIT

mark_done 80-registry
