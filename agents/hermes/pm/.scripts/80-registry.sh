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
BOARD_SCOPE="$(yaml_get board_scope)"
case "$BOARD_SCOPE" in
  ""|owner) ;;
  \[*\]) ;;  # shared-board scoped mode: a list of repo:* labels (roles/pm.md); owner behaviour on its scope
  advisory) PLANE_PROJECT_ID="" ;;
  *) die "unsupported board_scope in role.yaml: $BOARD_SCOPE" ;;
esac

# A named agent declares WHO it is in role.yaml (`identity:`); the post is
# agent_id/profile. Project that declaration, validated, into the registry so
# every reader (10-hermes-profile.sh's memory pin, flume's profile observer,
# the SOUL composer) resolves the same personal bank. `{}` means an unnamed post.
ROLE_IDENTITY_READER="$ROLE_DIR/.scripts/lib/role-identity.py"
[[ -f "$ROLE_IDENTITY_READER" && ! -L "$ROLE_IDENTITY_READER" ]] \
  || die "trusted role identity reader is unavailable: $ROLE_IDENTITY_READER"
ROLE_IDENTITY_JSON="$(python3 -I "$ROLE_IDENTITY_READER" "$ROLE_YAML" "$AGENT_ID" "$PROFILE_NAME")" \
  || die "role.yaml identity block is invalid"

log "[80] appending to fleet registry: $REGISTRY_FILE"

BOARD_SCOPE="$BOARD_SCOPE" python3 - "$REGISTRY_FILE" "$AGENT_ID" "$REPO" "$ROLE" "$DISPLAY_NAME" \
  "$PROJECT_PATH" "$ROLE_DIR" "$PROFILE_NAME" \
  "$(yaml_get telegram.provisioning_status)" "$BOT_HANDLE" "$(yaml_get telegram.bot_id)" \
  "$(yaml_get slack.provisioning_status)" "$(yaml_get slack.team_id)" \
  "$(yaml_get slack.team_name)" "$(yaml_get slack.bot_user_id)" \
  "$(yaml_get slack.bot_id)" "$(yaml_get slack.bot_username)" \
  "$ROLE_YAML" \
  "$PLANE_WORKSPACE" "$PLANE_PROJECT_ID" "$(yaml_get plane.identifier)" \
  "$HERMES_BIN" "$HERMES_AGENT_REPO" "$HERMES_RUNTIME_GIT_URL" \
  "$HERMES_RUNTIME_GIT_REF" "$HERMES_RUNTIME_GIT_SHA" "$FLEET_ENV" \
  "$ROLE_IDENTITY_JSON" <<'PYEOF'
import datetime
import copy
import errno
import json
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
 slack_username, role_yaml, plane_ws, plane_id,
 plane_ident, hermes_bin, hermes_repo, hermes_git_url,
 hermes_git_ref, hermes_git_sha, fleet_env,
 identity_json) = sys.argv[1:29]
board_scope = os.environ.get("BOARD_SCOPE", "")
if board_scope not in ("", "owner", "advisory") and not (board_scope.startswith("[") and board_scope.endswith("]")):
    raise SystemExit(f"unsupported board_scope in role.yaml: {board_scope}")
if board_scope == "advisory":
    plane_id = ""  # claimants resolve ONLY by plane.project_id / plane.board_id
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


def role_bloodbank(role_path, agent):
    """The role's Bloodbank block, read by a YAML parser rather than a line scan.

    The shell `yaml_get` once scanned past the end of the `bloodbank:` block,
    so an absent key read a later `reconcile.enabled: false` and quarantined
    the agent. A parser cannot do that: the key is either in this mapping or
    it is not.

    Every field follows one rule: ABSENT means the canonical value, PRESENT
    must be that value's strict form, anything else is refused.
    - enabled: absent => true; `true`/`false` are themselves; any other present
      value (a string, `yes`, null, "") is refused.
    - gateway_scope: absent => "fleet", the only ingress there is. A role.yaml
      with no bloodbank block used to project "" here, and the fleet gateway's
      default-deny eligibility silently stopped routing to the agent.
    - target_agent_id: absent => this agent's id; a different id is refused.
    """
    try:
        role_doc = yaml.load(pathlib.Path(role_path).read_text(encoding="utf-8"), Loader=StrictRoleLoader)
    except yaml.YAMLError as exc:
        raise SystemExit(f"role.yaml is not valid YAML: {exc}")
    if not isinstance(role_doc, dict):
        raise SystemExit("role.yaml root must be a mapping")
    bloodbank = role_doc.get("bloodbank")
    if bloodbank is None:
        bloodbank = {}
    if not isinstance(bloodbank, dict):
        raise SystemExit("role.yaml bloodbank must be a mapping")
    if "enabled" not in bloodbank:
        enabled = True
    elif isinstance(bloodbank["enabled"], bool):
        enabled = bloodbank["enabled"]
    else:
        raise SystemExit("bloodbank.enabled must be the strict YAML boolean true or false")
    scope = bloodbank.get("gateway_scope", "fleet")
    if scope != "fleet":
        raise SystemExit("bloodbank.gateway_scope must be fleet: the fleet-shared gateway is the only Bloodbank ingress")
    target = bloodbank.get("target_agent_id", agent)
    if target != agent:
        raise SystemExit(f"bloodbank.target_agent_id must be this agent's id {agent!r}")
    return enabled, scope, target


bloodbank_enabled_value, bloodbank_scope, bloodbank_target = role_bloodbank(role_yaml, agent_id)
existing = agents.get(agent_id, {})
if not isinstance(existing, dict):
    raise SystemExit(f"fleet registry entry for {agent_id} must be a mapping")
provisioned_at = existing.get("provisioned_at")
if isinstance(provisioned_at, (datetime.datetime, datetime.date)):
    # PyYAML reads an unquoted timestamp (how most rows are written) as a
    # datetime; keep the original provisioning time instead of resetting it.
    provisioned_at = provisioned_at.isoformat()
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
  "plane": {"workspace": plane_ws, "identifier": plane_ident},
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
  # No `systemd` projection. Since 2026-10-11 ONE host gateway
  # (hermes-gateway.service) serves every profile; it is declared once by the
  # top-level registry `gateways` block, never per row. A per-agent
  # `systemd.gateway_unit` named a unit that does not exist (the daily report's
  # "gateway units unknown to systemd") and fed a raw try-restart in
  # fleet-sync.sh. Gateway state lives in role.yaml `service_state`
  # (70-systemd.sh writes it, 99-summary.sh reads it).
  "provisioned_at": provisioned_at,
}
if board_scope == "advisory":
    managed["board_scope"] = "advisory"
else:
    managed["plane"]["project_id"] = plane_id
# A channel the operator PARKED with `flume channel offline` stays parked: a
# re-provision from role.yaml never flips it back to verified. Only
# `flume channel online` lifts the park.
for _platform in ("telegram", "slack"):
    _prior = existing.get(_platform)
    if isinstance(_prior, dict) and _prior.get("provisioning_status") == "offline":
        managed[_platform]["provisioning_status"] = "offline"
        for _key in ("offline_since", "offline_reason"):
            if _prior.get(_key):
                managed[_platform][_key] = _prior[_key]

# Named agent: the stable identity and its personal bank. A post (no
# `identity:` in role.yaml) leaves both absent and keeps the compatibility
# bank agent-<profile>; see lib/role-identity.py for the validation rules.
try:
    identity = json.loads(identity_json or "{}")
except ValueError:
    raise SystemExit("role identity reader returned invalid JSON")
if not isinstance(identity, dict):
    raise SystemExit("role identity reader returned a non-mapping")
if identity:
    managed["identity"] = identity["name"]
    managed["hindsight"] = {
        "write_bank": identity["write_bank"],
        "recall_banks": list(identity["recall_banks"]),
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
if board_scope == "advisory":
    entry["plane"].pop("project_id", None)
    entry["plane"].pop("board_id", None)
else:
    entry.pop("board_scope", None)
if not identity and isinstance(entry.get("identity"), str):
    # role.yaml is the identity SSOT. A name it no longer declares is a stale
    # projection; drop it together with the personal bank it implied, so the
    # row falls back to the post's compatibility bank instead of lying.
    prior = entry.pop("identity")
    hindsight = entry.get("hindsight")
    if isinstance(hindsight, dict) and hindsight.get("write_bank") == f"agent-{prior}":
        entry.pop("hindsight", None)
# Retired managed schema, not extension metadata. consumer_unit would falsely
# advertise a second per-agent Bloodbank execution path; gateway_state and
# heartbeat_state (projected 2026-08-27 to 2026-09-23) duplicate role.yaml
# service_state under keys the handbook does not declare. heartbeat_timer names
# a retired unit; reprovisioning removes that old managed projection as well.
# gateway_unit (retired 2026-10-11) named the per-agent hermes-<agent>-gateway.service;
# the one host gateway is declared by the top-level `gateways` block instead.
RETIRED_SYSTEMD_KEYS = ("consumer_unit", "gateway_state", "gateway_unit", "heartbeat_state", "heartbeat_timer")
systemd = entry.get("systemd")
if isinstance(systemd, dict):
    for retired_key in RETIRED_SYSTEMD_KEYS:
        systemd.pop(retired_key, None)
    if not systemd:
        # Nothing managed is left; an extension key someone added survives.
        entry.pop("systemd", None)
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

# The row just written is the org chart's project_path: the input of the renderer's terminal.cwd pin.
# Step 10 rendered this profile BEFORE the row existed (a fresh hire) or while it named an older
# path, so the generated config.yaml is a faithful render with a stale pin. Re-render it through the
# canonical renderer -- the registry stays the one ordering truth, and nothing here re-derives the
# pin. `repin` rewrites a pin-only difference and refuses real out-of-band drift (absorb first).
PROFILE_RENDERER="${PROFILE_RENDERER:-$HERMES_TEMPLATE_REPO/scripts/hermes-profile-config.py}"
PIN_PROFILE_HOME="${HERMES_FLEET_HOME:-$HOME/.hermes}/profiles/$PROFILE_NAME"
if [[ -f "$PIN_PROFILE_HOME/config.delta.yaml" && ! -L "$PIN_PROFILE_HOME/config.delta.yaml" ]]; then
  [[ -f "$PROFILE_RENDERER" && ! -L "$PROFILE_RENDERER" ]] \
    || die "canonical config renderer required to pin the registered project: $PROFILE_RENDERER"
  if repin_output="$(HERMES_AGENTS_REGISTRY="$REGISTRY_FILE" \
      python3 -I "$PROFILE_RENDERER" repin --profile "$PROFILE_NAME" 2>&1)"; then
    log "    profile config pinned to the registry row: ${repin_output##*$'\n'}"
  else
    warn "    $PROFILE_NAME's config.yaml has out-of-band drift beyond renderer pins; its terminal.cwd is NOT pinned. Review first: hermes-profile-config.py absorb --profile $PROFILE_NAME --dry-run (this one profile only, never a sweep); if it keeps your secrets.* references, rerun it without --dry-run, then hermes-profile-config.py repin --profile $PROFILE_NAME"
    printf '%s\n' "$repin_output" >&2
  fi
fi

mark_done 80-registry
