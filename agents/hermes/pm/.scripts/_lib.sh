# shellcheck shell=bash
# Common helpers sourced by every numbered provisioning step.

set -euo pipefail

# These three are set by Copier into the rendered role.yaml; we re-derive them
# here so each script is callable in isolation (e.g. for repair runs).
ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE_YAML="$ROLE_DIR/role.yaml"
PROV_LOG="$ROLE_DIR/.scripts/.provision.log"

mkdir -p "$ROLE_DIR/.scripts"

# Logging
log()  { local msg="[$(date +%H:%M:%S)] $*"; printf '\033[36m%s\033[0m\n' "$msg" >&2; printf '%s\n' "$msg" >> "$PROV_LOG"; }
warn() { local msg="[$(date +%H:%M:%S)] $*"; printf '\033[33m%s\033[0m\n' "$msg" >&2; printf '%s\n' "$msg" >> "$PROV_LOG"; }
err()  { local msg="[$(date +%H:%M:%S)] $*"; printf '\033[31m%s\033[0m\n' "$msg" >&2; printf '%s\n' "$msg" >> "$PROV_LOG"; }
die()  { err "$*"; exit 1; }

# Read a single field from role.yaml. Requires python3 (no yaml dep).
yaml_get() {
  # yaml_get  KEY[.SUBKEY]    e.g.  yaml_get role,  yaml_get telegram.bot_username
  local key="$1"
  python3 - "$ROLE_YAML" "$key" <<'PYEOF'
import sys, re, pathlib
path, key = sys.argv[1:3]
text = pathlib.Path(path).read_text()
parts = key.split(".")
# Trivial YAML walker — handles flat and one-level nested keys.
indent = -1
prefix = ""
for part in parts[:-1]:
    indent += 2
    prefix += part + ":"
    m = re.search(rf"(?m)^{re.escape(part)}:\s*$", text)
    if not m:
        sys.exit(0)
    text = text[m.end():]
key = parts[-1]
m = re.search(rf'(?m)^\s*{re.escape(key)}:\s*"?([^"\n]*)"?\s*$', text)
if m:
    print(m.group(1).strip())
PYEOF
}

# Apply a sed substitution to role.yaml in-place. Used to record IDs after
# external provisioning steps return them.
yaml_set() {
  # yaml_set KEY VALUE   (supports flat and one-level nested keys)
  local key="$1" val="$2"
  python3 - "$ROLE_YAML" "$key" "$val" <<'PYEOF'
import json, pathlib, re, sys

path, key, val = sys.argv[1:4]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
parts = key.split(".")
if len(parts) not in (1, 2) or any(
    not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", part) for part in parts
):
    sys.exit(f"yaml_set: unsupported key '{key}'")

lines = text.splitlines(keepends=True)
start, end, parent_indent = 0, len(lines), -1
if len(parts) == 2:
    parent, leaf = parts
    parents = []
    for index, raw in enumerate(lines):
        line = raw.rstrip("\r\n")
        match = re.fullmatch(rf"( *){re.escape(parent)}:\s*(?:#.*)?", line)
        if match and len(match.group(1)) == 0:
            parents.append(index)
    if len(parents) != 1:
        sys.exit(f"yaml_set: parent '{parent}' not found uniquely in {path}")
    parent_index = parents[0]
    parent_indent = 0
    start = parent_index + 1
    for index in range(start, len(lines)):
        candidate = lines[index].rstrip("\r\n")
        if not candidate.strip() or candidate.lstrip().startswith("#"):
            continue
        indent = len(candidate) - len(candidate.lstrip(" "))
        if indent <= parent_indent:
            end = index
            break
else:
    leaf = parts[0]

targets = []
for index in range(start, end):
    raw = lines[index]
    line = raw.rstrip("\r\n")
    match = re.match(rf"^( *){re.escape(leaf)}:\s*", line)
    if not match:
        continue
    indent = len(match.group(1))
    if (parent_indent < 0 and indent == 0) or (parent_indent >= 0 and indent > parent_indent):
        targets.append((index, match.group(1)))
if len(targets) != 1:
    sys.exit(f"yaml_set: key '{key}' not found uniquely in {path}")

index, indent = targets[0]
ending = "\r\n" if lines[index].endswith("\r\n") else "\n" if lines[index].endswith("\n") else ""
lines[index] = f"{indent}{leaf}: {json.dumps(val, ensure_ascii=False)}{ending}"
p.write_text("".join(lines), encoding="utf-8")
PYEOF
}

# Upsert one scalar below a top-level mapping without requiring the mapping to
# have existed in an older rendered role.yaml. This is intentionally narrower
# than a general YAML editor: lifecycle scripts use it only for safe, generated
# status metadata such as service_state.gateway.
yaml_upsert_block_value() {
  # yaml_upsert_block_value PARENT KEY VALUE [string|bool]
  python3 - "$ROLE_YAML" "$1" "$2" "$3" "${4:-string}" <<'PYEOF'
import json, pathlib, re, sys

path, parent, key, value, kind = sys.argv[1:6]
if not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", item) for item in (parent, key)):
    raise SystemExit("yaml_upsert_block_value: unsafe key")
if kind == "bool":
    if value not in {"true", "false"}:
        raise SystemExit("yaml_upsert_block_value: invalid boolean")
    rendered_value = value
elif kind == "string":
    rendered_value = json.dumps(value, ensure_ascii=False)
else:
    raise SystemExit("yaml_upsert_block_value: unsupported scalar type")
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
match = re.search(
    rf"(?ms)^{re.escape(parent)}:\s*\n(?P<body>(?:^[ \t]+.*\n?)*)", text
)
replacement = f"  {key}: {rendered_value}"
if match:
    body = match.group("body")
    body, count = re.subn(
        rf"(?m)^[ \t]+{re.escape(key)}:\s*.*$", replacement, body, count=1
    )
    if count == 0:
        if body and not body.endswith("\n"):
            body += "\n"
        body += replacement + "\n"
    text = text[: match.start("body")] + body + text[match.end("body") :]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"\n{parent}:\n{replacement}\n"
p.write_text(text, encoding="utf-8")
PYEOF
}

# Test whether an ignored dotenv file contains one non-empty exact assignment.
# Values remain inside the child process and are never printed or imported into
# the provisioning shell.
dotenv_has_nonempty() {
  python3 - "$1" "$2" <<'PYEOF'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or not path.is_file() or path.is_symlink():
    raise SystemExit(1)
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    name, sep, value = line.partition("=")
    if not sep or name.strip() != key:
        continue
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    raise SystemExit(0 if value else 1)
raise SystemExit(1)
PYEOF
}

# Persist one process-only value to 1Password. The helper prints only the
# resulting op:// reference; the value crosses stdin and an anonymous pipe.
store_onepassword_secret() {
  # store_onepassword_secret ITEM_NAME VALUE
  local item="$1" value="$2" vault
  vault="${HERMES_ONEPASSWORD_VAULT:-$(config_get fleet.onepassword_vault 'DeLoSecrets')}"
  [[ -n "$vault" ]] || die "fleet.onepassword_vault is required for channel credentials"
  [[ -f "$ROLE_DIR/.scripts/store-onepassword-secret.py" ]] \
    || die "trusted 1Password storage helper is missing"
  printf '%s' "$value" \
    | python3 -I "$ROLE_DIR/.scripts/store-onepassword-secret.py" "$vault" "$item"
}

# Stage one credential in a new immutable 1Password item. Output is two lines:
# item id, then op:// reference. Nothing is active until the channel transaction
# commits that reference.
stage_onepassword_secret() {
  # stage_onepassword_secret ITEM_PREFIX FIELD VALUE
  local item="$1" field="$2" value="$3" vault
  vault="${HERMES_ONEPASSWORD_VAULT:-$(config_get fleet.onepassword_vault 'DeLoSecrets')}"
  [[ -n "$vault" ]] || die "fleet.onepassword_vault is required for channel credentials"
  [[ -f "$ROLE_DIR/.scripts/store-onepassword-secret.py" ]] \
    || die "trusted 1Password storage helper is missing"
  printf '%s' "$value" \
    | python3 -I "$ROLE_DIR/.scripts/store-onepassword-secret.py" \
        --store-staged "$vault" "$item" "$field"
}

# Stage a credential pair with one atomic 1Password item create. Output is
# immutable item id followed by both verified op:// references.
stage_onepassword_secret_pair() {
  # stage_onepassword_secret_pair ITEM_NAME FIELD_ONE VALUE_ONE FIELD_TWO VALUE_TWO
  local item="$1" field_one="$2" value_one="$3" field_two="$4" value_two="$5" vault
  vault="${HERMES_ONEPASSWORD_VAULT:-$(config_get fleet.onepassword_vault 'DeLoSecrets')}"
  [[ -n "$vault" ]] || die "fleet.onepassword_vault is required for channel credentials"
  [[ -f "$ROLE_DIR/.scripts/store-onepassword-secret.py" ]] \
    || die "trusted 1Password storage helper is missing"
  printf '%s\n%s' "$value_one" "$value_two" \
    | python3 -I "$ROLE_DIR/.scripts/store-onepassword-secret.py" \
        --store-pair "$vault" "$item" "$field_one" "$field_two"
}

delete_staged_onepassword_item() {
  # delete_staged_onepassword_item IMMUTABLE_ITEM_ID
  local item_id="$1" vault
  vault="${HERMES_ONEPASSWORD_VAULT:-$(config_get fleet.onepassword_vault 'DeLoSecrets')}"
  [[ -n "$vault" && -n "$item_id" ]] || return 1
  python3 -I "$ROLE_DIR/.scripts/store-onepassword-secret.py" \
    --delete-item-id "$vault" "$item_id"
}

# Update one supported profile override and immediately regenerate config.yaml
# from fleet base + delta.  Keeping both operations in one helper prevents the
# first deploy and fleet-sync paths from disagreeing about which file is the
# source of truth.
profile_config_delta_update() {
  # profile_config_delta_update PROFILE_HOME secret-ref ENV_NAME OP_REFERENCE
  # profile_config_delta_update PROFILE_HOME secret-ref-pair ENV REF ENV REF
  # profile_config_delta_update PROFILE_HOME channel-enabled telegram|slack true|false
  # profile_config_delta_update PROFILE_HOME voice PLUGIN VOICE
  local profile_lock_tool="$ROLE_DIR/.scripts/lib/profile-config-lock.py"
  [[ -f "$profile_lock_tool" && ! -L "$profile_lock_tool" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  if [[ "${2:-}" == "voice" ]]; then
    [[ $# -eq 4 ]] || die "voice requires a profile, plugin, and voice"
    local voice_tool="$ROLE_DIR/.scripts/lib/voice-config.py"
    [[ -f "$voice_tool" && ! -L "$voice_tool" ]] \
      || die "trusted PM voice config helper is unavailable"
    python3 -I "$voice_tool" reconcile \
      --base "$1/../../config.yaml" \
      --delta "$1/config.delta.yaml" \
      --generated "$1/config.yaml" \
      --plugin "$3" \
      --voice "$4"
    return
  fi
  python3 - "$profile_lock_tool" "$@" <<'PYEOF'
import atexit, copy, importlib.util, os, pathlib, re, sys, tempfile
try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required for Hermes profile config")

lock_source = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("pjangler_profile_config_lock", lock_source)
if spec is None or spec.loader is None:
    raise SystemExit(f"cannot load profile config lock helper: {lock_source}")
profile_lock_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile_lock_module)
profile = pathlib.Path(sys.argv[2])
profile_lock = profile_lock_module.ProfileConfigLock(profile)
try:
    profile_lock.acquire()
except profile_lock_module.ProfileConfigLockError as exc:
    raise SystemExit(str(exc)) from exc
atexit.register(profile_lock.release)
# A profile root is a security boundary.  Never follow the legacy symlink form:
# even a read would escape the named profile and a later atomic replace could
# mutate shared/runtime state.  Migration must happen in the lifecycle step.
if profile.is_symlink():
    raise SystemExit(
        f"refusing symlinked profile root: {profile}; "
        "run the pjangler Hermes runtime-singleton migration before provisioning channels"
    )
if not profile.is_dir():
    raise SystemExit(f"required profile root is unavailable: {profile}")
args = sys.argv[3:]
if not args:
    raise SystemExit("profile config update mode is required")
mode = args[0]
base_path = profile.parent.parent / "config.yaml"
delta_path = profile / "config.delta.yaml"
generated_path = profile / "config.yaml"

def load(path):
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"required config source is unavailable: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"config source must be a mapping: {path}")
    return data

LIST_PATCH_KEY = "x-pjangler-merge"

def plain_merge(base, override):
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = plain_merge(result[key], value)
        elif key in result and isinstance(result[key], dict) and value is None:
            continue
        else:
            result[key] = copy.deepcopy(value)
    return result

def apply_list_patches(result, directive):
    if directive is None:
        return
    if not isinstance(directive, dict) or not isinstance(directive.get("list_patches", {}), dict):
        raise SystemExit(f"{LIST_PATCH_KEY}.list_patches must be a mapping")
    for dotted, rule in directive.get("list_patches", {}).items():
        if not isinstance(dotted, str) or not dotted or not isinstance(rule, dict):
            raise SystemExit("invalid list patch")
        additions = rule.get("add", []) or []
        removals = rule.get("remove", []) or []
        if not isinstance(additions, list) or not isinstance(removals, list) or not all(
            isinstance(item, str) for item in [*additions, *removals]
        ):
            raise SystemExit(f"list patch for {dotted} must contain string lists")
        cursor = result
        parts = dotted.split(".")
        for part in parts[:-1]:
            child = cursor.setdefault(part, {})
            if not isinstance(child, dict):
                raise SystemExit(f"list patch parent for {dotted} is not a mapping")
            cursor = child
        current = cursor.get(parts[-1], []) or []
        if not isinstance(current, list):
            raise SystemExit(f"list patch target {dotted} is not a list")
        removed = set(removals)
        merged = [item for item in current if item not in removed]
        for item in additions:
            if item not in merged:
                merged.append(item)
        cursor[parts[-1]] = merged

def merge(base, override):
    directive = override.get(LIST_PATCH_KEY)
    ordinary = {key: value for key, value in override.items() if key != LIST_PATCH_KEY}
    result = plain_merge(base, ordinary)
    apply_list_patches(result, directive)
    return result

def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.is_symlink():
            path.unlink()
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try: os.unlink(temporary)
        except FileNotFoundError: pass
        raise

base = load(base_path)
if delta_path.exists():
    delta = load(delta_path)
else:
    delta = {}
if mode == "secret-ref":
    if len(args) != 3:
        raise SystemExit("secret-ref requires an environment name and reference")
    name, value = args[1:]
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
        raise SystemExit("invalid secret environment variable name")
    if not value.startswith("op://") or any(ch in value for ch in "\r\n\0"):
        raise SystemExit("invalid 1Password reference")
    onepassword = delta.setdefault("secrets", {}).setdefault("onepassword", {})
    if not isinstance(onepassword, dict):
        raise SystemExit("secrets.onepassword delta must be a mapping")
    onepassword["enabled"] = True
    env = onepassword.setdefault("env", {})
    if not isinstance(env, dict):
        raise SystemExit("secrets.onepassword.env delta must be a mapping")
    env[name] = value
elif mode == "secret-ref-pair":
    if len(args) != 5:
        raise SystemExit("secret-ref-pair requires two environment/reference pairs")
    name_one, value_one, name_two, value_two = args[1:]
    pairs = ((name_one, value_one), (name_two, value_two))
    if name_one == name_two:
        raise SystemExit("secret-ref-pair environment names must be distinct")
    for env_name, reference in pairs:
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", env_name):
            raise SystemExit("invalid secret environment variable name")
        if not reference.startswith("op://") or any(ch in reference for ch in "\r\n\0"):
            raise SystemExit("invalid 1Password reference")
    onepassword = delta.setdefault("secrets", {}).setdefault("onepassword", {})
    if not isinstance(onepassword, dict):
        raise SystemExit("secrets.onepassword delta must be a mapping")
    onepassword["enabled"] = True
    env = onepassword.setdefault("env", {})
    if not isinstance(env, dict):
        raise SystemExit("secrets.onepassword.env delta must be a mapping")
    # Both refs enter the same in-memory document and one atomic delta write.
    for env_name, reference in pairs:
        env[env_name] = reference
elif mode == "channel-enabled":
    if len(args) != 3:
        raise SystemExit("channel-enabled requires a channel and boolean")
    name, value = args[1:]
    if name not in {"telegram", "slack"}:
        raise SystemExit("unsupported channel enablement key")
    if value not in {"true", "false"}:
        raise SystemExit("channel enablement must be true or false")
    platforms = delta.setdefault("platforms", {})
    if not isinstance(platforms, dict):
        raise SystemExit("platforms delta must be a mapping")
    channel = platforms.setdefault(name, {})
    if not isinstance(channel, dict):
        raise SystemExit(f"platforms.{name} delta must be a mapping")
    channel["enabled"] = value == "true"
else:
    raise SystemExit("unsupported profile config delta update")
existing_comments = []
if delta_path.is_file() and not delta_path.is_symlink():
    for line in delta_path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("#") and line not in existing_comments:
            existing_comments.append(line)
standard_comments = [
    "# Override-only delta for this Hermes profile.",
    "# Contains configuration and secret references only; secret values remain in 1Password.",
]
comments = [*standard_comments, *(line for line in existing_comments if line not in standard_comments)]
atomic_write(delta_path, "\n".join(comments) + "\n" + yaml.safe_dump(delta, sort_keys=False))
header = (
    "# GENERATED FILE -- DO NOT EDIT.\n"
    "# source: fleet config.yaml + profile config.delta.yaml\n"
)
atomic_write(generated_path, header + yaml.safe_dump(merge(base, delta), sort_keys=False))
PYEOF
}

profile_voice_contract_set() {
  # profile_voice_contract_set PROFILE_HOME PLUGIN VOICE
  profile_config_delta_update "$1" voice "$2" "$3"
}

profile_root_require_real() {
  # profile_root_require_real PROFILE_HOME
  [[ ! -L "$1" ]] \
    || die "refusing symlinked profile root: $1; run the pjangler Hermes runtime-singleton migration before provisioning channels"
  [[ -d "$1" ]] || die "required profile root is unavailable: $1"
}

profile_onepassword_ref_exists() {
  # profile_onepassword_ref_exists PROFILE_HOME ENV_NAME
  # This is a read-only service eligibility probe. Channel transactions do not
  # use it: their refs and identity are captured under registry -> profile lock.
  python3 - "$1/config.delta.yaml" "$2" <<'PYEOF'
import pathlib, sys
try:
    import yaml
except ImportError:
    raise SystemExit(1)
path = pathlib.Path(sys.argv[1])
if not path.is_file() or path.is_symlink():
    raise SystemExit(1)
try:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    ref = data["secrets"]["onepassword"]["env"].get(sys.argv[2], "")
except (KeyError, TypeError, ValueError, yaml.YAMLError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(ref, str) and ref.startswith("op://") else 1)
PYEOF
}

profile_onepassword_ref_get() {
  # profile_onepassword_ref_get PROFILE_HOME ENV_NAME
  python3 - "$1/config.delta.yaml" "$2" <<'PYEOF'
import pathlib, sys
try:
    import yaml
    data = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")) or {}
    reference = data["secrets"]["onepassword"]["env"].get(sys.argv[2], "")
except Exception:
    reference = ""
if not isinstance(reference, str) or not reference.startswith("op://"):
    raise SystemExit(1)
print(reference)
PYEOF
}

profile_onepassword_ref_validate() {
  # profile_onepassword_ref_validate PROFILE_HOME ENV_NAME
  # Return 0 when the reference resolves, 2 when no syntactically valid
  # mapping exists, and 75 when a valid mapping cannot currently be checked.
  # This is a read-only service eligibility probe, never a transaction input.
  local reference helper="$ROLE_DIR/.scripts/store-onepassword-secret.py"
  [[ -f "$helper" ]] || return 75
  reference="$(profile_onepassword_ref_get "$1" "$2")" || return 2
  if python3 -I "$helper" --validate-reference "$reference" >/dev/null 2>&1; then
    return 0
  fi
  return 75
}

channel_transaction_telegram() {
  # channel_transaction_telegram PROFILE_HOME RUNTIME_ENV REF USERNAME BOT_ID ALLOWED
  local helper="$ROLE_DIR/.scripts/channel-transaction.py"
  [[ -f "$helper" && ! -L "$helper" ]] || die "trusted channel transaction helper is missing"
  [[ -f "$ROLE_DIR/.scripts/lib/profile-config-lock.py" \
      && ! -L "$ROLE_DIR/.scripts/lib/profile-config-lock.py" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  python3 -I "$helper" \
    --channel telegram \
    --profile "$1" \
    --role-yaml "$ROLE_YAML" \
    --registry "$REGISTRY_FILE" \
    --runtime-env "$2" \
    --done-marker "$ROLE_DIR/.scripts/.done-30-telegram" \
    --agent-id "$AGENT_ID" \
    --role-dir "$ROLE_DIR" \
    --profile-name "$PROFILE_NAME" \
    --allowed-value "$6" \
    --reference TELEGRAM_BOT_TOKEN "$3" \
    --metadata provisioning_status verified \
    --metadata bot_username "$4" \
    --metadata bot_id "$5"
}

channel_transaction_telegram_existing() {
  # channel_transaction_telegram_existing PROFILE_HOME RUNTIME_ENV
  # Caller holds the fleet registry lock; the helper acquires the profile lock
  # and reads refs plus role metadata only after both locks are held.
  local helper="$ROLE_DIR/.scripts/channel-transaction.py"
  local validator="$ROLE_DIR/.scripts/store-onepassword-secret.py"
  [[ -f "$helper" && ! -L "$helper" ]] \
    || die "trusted channel transaction helper is missing"
  [[ -f "$validator" && ! -L "$validator" ]] \
    || die "trusted 1Password reference validator is missing"
  [[ -f "$ROLE_DIR/.scripts/lib/profile-config-lock.py" \
      && ! -L "$ROLE_DIR/.scripts/lib/profile-config-lock.py" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  python3 -I "$helper" \
    --channel telegram \
    --profile "$1" \
    --role-yaml "$ROLE_YAML" \
    --registry "$REGISTRY_FILE" \
    --runtime-env "$2" \
    --done-marker "$ROLE_DIR/.scripts/.done-30-telegram" \
    --agent-id "$AGENT_ID" \
    --role-dir "$ROLE_DIR" \
    --profile-name "$PROFILE_NAME" \
    --reconcile-existing \
    --reference-validator "$validator"
}

channel_transaction_telegram_prepare_unconfigured() {
  # Caller holds the fleet registry lock. The helper disables only a channel
  # whose locked role snapshot is not verified; exit 3 means verified/no-op.
  local helper="$ROLE_DIR/.scripts/channel-transaction.py"
  [[ -f "$helper" && ! -L "$helper" ]] \
    || die "trusted channel transaction helper is missing"
  [[ -f "$ROLE_DIR/.scripts/lib/profile-config-lock.py" \
      && ! -L "$ROLE_DIR/.scripts/lib/profile-config-lock.py" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  python3 -I "$helper" \
    --channel telegram \
    --profile "$1" \
    --role-yaml "$ROLE_YAML" \
    --registry "$REGISTRY_FILE" \
    --runtime-env "$2" \
    --done-marker "$ROLE_DIR/.scripts/.done-30-telegram" \
    --agent-id "$AGENT_ID" \
    --role-dir "$ROLE_DIR" \
    --profile-name "$PROFILE_NAME" \
    --prepare-unconfigured
}

channel_transaction_slack() {
  # channel_transaction_slack PROFILE ENV BOT_REF APP_REF TEAM_ID TEAM_NAME USER_ID BOT_ID USERNAME ALLOWED
  local helper="$ROLE_DIR/.scripts/channel-transaction.py"
  [[ -f "$helper" && ! -L "$helper" ]] || die "trusted channel transaction helper is missing"
  [[ -f "$ROLE_DIR/.scripts/lib/profile-config-lock.py" \
      && ! -L "$ROLE_DIR/.scripts/lib/profile-config-lock.py" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  python3 -I "$helper" \
    --channel slack \
    --profile "$1" \
    --role-yaml "$ROLE_YAML" \
    --registry "$REGISTRY_FILE" \
    --runtime-env "$2" \
    --done-marker "$ROLE_DIR/.scripts/.done-31-slack" \
    --agent-id "$AGENT_ID" \
    --role-dir "$ROLE_DIR" \
    --profile-name "$PROFILE_NAME" \
    --allowed-value "${10}" \
    --reference SLACK_BOT_TOKEN "$3" \
    --reference SLACK_APP_TOKEN "$4" \
    --metadata provisioning_status verified \
    --metadata team_id "$5" \
    --metadata team_name "$6" \
    --metadata bot_user_id "$7" \
    --metadata bot_id "$8" \
    --metadata bot_username "$9"
}

channel_transaction_slack_existing() {
  # channel_transaction_slack_existing PROFILE_HOME RUNTIME_ENV
  # Caller holds the fleet registry lock; the helper acquires the profile lock
  # and reads refs plus role metadata only after both locks are held.
  local helper="$ROLE_DIR/.scripts/channel-transaction.py"
  local validator="$ROLE_DIR/.scripts/store-onepassword-secret.py"
  [[ -f "$helper" && ! -L "$helper" ]] \
    || die "trusted channel transaction helper is missing"
  [[ -f "$validator" && ! -L "$validator" ]] \
    || die "trusted 1Password reference validator is missing"
  [[ -f "$ROLE_DIR/.scripts/lib/profile-config-lock.py" \
      && ! -L "$ROLE_DIR/.scripts/lib/profile-config-lock.py" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  python3 -I "$helper" \
    --channel slack \
    --profile "$1" \
    --role-yaml "$ROLE_YAML" \
    --registry "$REGISTRY_FILE" \
    --runtime-env "$2" \
    --done-marker "$ROLE_DIR/.scripts/.done-31-slack" \
    --agent-id "$AGENT_ID" \
    --role-dir "$ROLE_DIR" \
    --profile-name "$PROFILE_NAME" \
    --reconcile-existing \
    --reference-validator "$validator"
}

channel_transaction_slack_prepare_unconfigured() {
  # Caller holds the fleet registry lock. The helper disables only a channel
  # whose locked role snapshot is not verified; exit 3 means verified/no-op.
  local helper="$ROLE_DIR/.scripts/channel-transaction.py"
  [[ -f "$helper" && ! -L "$helper" ]] \
    || die "trusted channel transaction helper is missing"
  [[ -f "$ROLE_DIR/.scripts/lib/profile-config-lock.py" \
      && ! -L "$ROLE_DIR/.scripts/lib/profile-config-lock.py" ]] \
    || die "trusted PM profile config lock helper is unavailable"
  python3 -I "$helper" \
    --channel slack \
    --profile "$1" \
    --role-yaml "$ROLE_YAML" \
    --registry "$REGISTRY_FILE" \
    --runtime-env "$2" \
    --done-marker "$ROLE_DIR/.scripts/.done-31-slack" \
    --agent-id "$AGENT_ID" \
    --role-dir "$ROLE_DIR" \
    --profile-name "$PROFILE_NAME" \
    --prepare-unconfigured
}

# ─── Distributable config (~/.config/hermes-agent-template/config.toml) ──────
# Single source of truth for environment-specific defaults so this template can
# be handed to someone else without editing any script. Ship config.example.toml
# is copied here on first provision (see .scripts/01-config.sh).
HERMES_TEMPLATE_CONFIG="${HERMES_TEMPLATE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hermes-agent-template/config.toml}"
export HERMES_TEMPLATE_CONFIG

# config_get <dotted.key> [default]   — print a value from config.toml (paths are
# tilde-expanded; arrays are space-joined). Falls back to [default] when the file,
# python3, or the key is missing. Always exits 0 so it's safe under `set -e`.
config_get() {
  local key="$1" def="${2:-}"
  if [[ ! -f "$HERMES_TEMPLATE_CONFIG" ]] || ! command -v python3 >/dev/null 2>&1; then
    printf '%s' "$def"; return 0
  fi
  python3 - "$HERMES_TEMPLATE_CONFIG" "$key" "$def" <<'PYEOF' || printf '%s' "$def"
import sys, os
try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    print(sys.argv[3], end=""); sys.exit(0)
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "rb") as f:
        cur = tomllib.load(f)
except Exception:
    print(default, end=""); sys.exit(0)
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default, end=""); sys.exit(0)
if isinstance(cur, list):
    cur = " ".join(str(x) for x in cur)
else:
    cur = str(cur)
print(os.path.expanduser(cur), end="")
PYEOF
  return 0
}

# Re-export role fields into the environment for the rest of the script.
load_role_env() {
  ROLE=$(yaml_get role)
  REPO=$(yaml_get repo)
  AGENT_ID=$(yaml_get agent_id)
  DISPLAY_NAME=$(yaml_get display_name)
  BOT_HANDLE=$(yaml_get telegram.bot_username)
  PROFILE_NAME=$(yaml_get profile)

  # Plane workspace: empty in role.yaml -> resolve from config.toml.
  PLANE_WORKSPACE=$(yaml_get plane.workspace)
  [[ -n "$PLANE_WORKSPACE" ]] || PLANE_WORKSPACE=$(config_get plane.workspace "33god")

  # Runtime repo: role.yaml stores the bare repo name plus an optional owner.
  # Older manifests stored "owner/name" directly in github_repo; honor both.
  RUNTIME_REPO=$(yaml_get runtime.github_repo)
  if [[ "$RUNTIME_REPO" != */* ]]; then
    local owner; owner=$(yaml_get runtime.github_owner)
    [[ -n "$owner" ]] || owner=$(config_get github.runtime_repo_owner "delorenj")
    RUNTIME_REPO="$owner/$RUNTIME_REPO"
  fi

  export ROLE REPO AGENT_ID DISPLAY_NAME BOT_HANDLE \
         PLANE_WORKSPACE RUNTIME_REPO PROFILE_NAME
}

# Skip a step if previously completed (idempotent reruns).
already_done() {
  local marker="$ROLE_DIR/.scripts/.done-$1"
  [[ -f "$marker" ]]
}
mark_done() {
  touch "$ROLE_DIR/.scripts/.done-$1"
}
clear_done() {
  # Remove only the marker for the explicitly deferred step.  This lets a
  # later activation reconcile that phase without disturbing completed,
  # unrelated provisioning state.
  rm -f -- "$ROLE_DIR/.scripts/.done-$1"
}

# The parser protocol, unsafe-family scrub, complete framing validation, and
# atomic environment apply live in one reusable library shared by provisioners,
# launchers, and maintenance commands.
FLEET_ENV_LIBRARY="$ROLE_DIR/.scripts/lib/fleet-env.sh"
FLEET_ENV_PARSER="$ROLE_DIR/.scripts/lib/parse-fleet-env.py"
if [[ ! -f "$FLEET_ENV_LIBRARY" || -L "$FLEET_ENV_LIBRARY" ]]; then
  builtin printf 'fleet environment loader rejected: trusted library is unavailable\n' >&2
  return 1
fi
# shellcheck source=lib/fleet-env.sh
builtin source "$FLEET_ENV_LIBRARY"

# Fleet source-of-truth (shared across all wrappers/provisioners).
# Every default below resolves as: env var > fleet.env > config.toml > fallback.
# Invocation authority is not fleet configuration. Capture the caller's board
# gate before importing fleet.env so that file cannot weaken an MCP/CLI
# SKIP_PLANE decision or re-enable credentials by assigning SKIP_PLANE=0.
PJANGLER_INVOCATION_SKIP_PLANE="${SKIP_PLANE:-0}"
FLEET_ENV="${HERMES_FLEET_ENV:-$(config_get fleet.fleet_env "$HOME/.hermes/fleet.env")}"

# A direct CLI caller may not have passed through the MCP parent boundary. The
# shared loader hardens both before parser startup and again after atomic import.
if ! load_fleet_environment "$FLEET_ENV" "$FLEET_ENV_PARSER"; then
  return 1
fi
SKIP_PLANE="$PJANGLER_INVOCATION_SKIP_PLANE"
unset PJANGLER_INVOCATION_SKIP_PLANE
scrub_subprocess_interpreter_injection

# fleet.env is allowed to supply provider credentials only for an explicitly
# board-authorized invocation. A no-board/deferred phase must remove every
# supported provider alias after sourcing and before any Python, Hermes,
# systemd, provider, or other child process can inherit it.
scrub_ticket_provider_authority() {
  local key
  unset PLANE_API_KEY TRELLO_KEY TRELLO_TOKEN LINEAR_API_KEY
  while IFS= read -r key; do
    case "$key" in
      PLANE_*_API_KEY) unset "$key" ;;
    esac
  done < <(compgen -A variable PLANE_)
}
if [[ "$SKIP_PLANE" == "1" ]]; then
  scrub_ticket_provider_authority
fi
# Identity-bearing chat credentials are never fleet-scoped. Platform wiring
# steps capture explicit invocation values before sourcing this library and
# restore only those values afterward; all other provisioning steps stay clean.
unset TELEGRAM_BOT_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN

# Tools we expect on the host
HERMES_BIN="${HERMES_BIN:-${HERMES_FLEET_BIN:-$(config_get fleet.hermes_bin "$HOME/.local/share/hermes-agent/releases/0408fec7a153e6c32c064acd2b8053917f1525f1/.venv/bin/hermes")}}"
HERMES_AGENT_REPO="${HERMES_AGENT_REPO:-${HERMES_FLEET_REPO:-$(config_get fleet.hermes_repo "$HOME/.local/share/hermes-agent/releases/0408fec7a153e6c32c064acd2b8053917f1525f1")}}"
PJANGLER_BIN="${PJANGLER_BIN:-$(config_get fleet.pjangler_bin "pj")}"
HERMES_RUNTIME_GIT_URL="${HERMES_RUNTIME_GIT_URL:-$(config_get fleet.hermes_git_url 'https://github.com/delorenj/hermes-agent.git')}"
HERMES_RUNTIME_GIT_REF="${HERMES_RUNTIME_GIT_REF:-$(config_get fleet.hermes_git_ref 'main')}"
HERMES_RUNTIME_GIT_SHA="${HERMES_RUNTIME_GIT_SHA:-$(config_get fleet.hermes_git_sha '0408fec7a153e6c32c064acd2b8053917f1525f1')}"
HERMES_OAUTH_FILE="${HERMES_OAUTH_FILE:-${HERMES_FLEET_OAUTH_FILE:-$(config_get fleet.oauth_file "$HOME/.hermes/auth.json")}}"
CODEX_HOME="${CODEX_HOME:-${HERMES_FLEET_CODEX_HOME:-$(config_get fleet.codex_home "$HOME/.codex")}}"
# Prefer a scaffold vendored into this agent directory; fall back to the configured template path.
RUNTIME_SCAFFOLD_DIR="${RUNTIME_SCAFFOLD_DIR:-$ROLE_DIR/.runtime-scaffold}"
if [[ ! -d "$RUNTIME_SCAFFOLD_DIR" ]]; then
  RUNTIME_SCAFFOLD_DIR="${HERMES_TEMPLATE_RUNTIME_SCAFFOLD:-$(config_get fleet.runtime_scaffold_dir "$HOME/code/hermes-agent-template/runtime-scaffold")}"
fi
REGISTRY_FILE="${REGISTRY_FILE:-${HERMES_FLEET_REGISTRY_FILE:-$(config_get fleet.registry_file "$HOME/.hermes/agents-registry.yaml")}}"

# Cross-process serialization for fleet identity claims and registry updates.
# The lock file may remain on disk; flock ownership is kernel-scoped, so a
# crashed provisioner cannot leave a permanently stale lock.
FLEET_LOCK_FD=""
fleet_lock_acquire() {
  command -v flock >/dev/null 2>&1 || die "flock is required for safe fleet registry updates"
  local lock_file="${REGISTRY_FILE}.lock"
  mkdir -p "$(dirname "$lock_file")"
  [[ ! -L "$lock_file" ]] || die "refusing fleet lock symlink: $lock_file"
  exec {FLEET_LOCK_FD}>"$lock_file"
  chmod 600 "$lock_file"
  if [[ -n "${PJANGLER_TEST_FLEET_LOCK_BARRIER:-}" ]]; then
    [[ -n "${PYTEST_CURRENT_TEST:-}" ]] \
      || die "PJANGLER_TEST_FLEET_LOCK_BARRIER is test-only and requires pytest"
    local barrier_file="$PJANGLER_TEST_FLEET_LOCK_BARRIER"
    local barrier_parent="${barrier_file%/*}"
    local barrier_timeout="${PJANGLER_TEST_FLEET_LOCK_BARRIER_TIMEOUT_SECONDS:-15}"
    [[ "$barrier_parent" != "$barrier_file" ]] || barrier_parent="."
    [[ ! -L "$barrier_file" && ! -L "$barrier_parent" && -d "$barrier_parent" ]] \
      || die "unsafe test fleet-lock barrier path: $barrier_file"
    [[ "$barrier_timeout" =~ ^[1-9][0-9]*$ ]] \
      || die "PJANGLER_TEST_FLEET_LOCK_BARRIER_TIMEOUT_SECONDS must be a positive integer"
    printf '%s\n' 'fleet-prelock' > "${barrier_file}.ready"
    local barrier_started=$SECONDS
    while [[ ! -f "${barrier_file}.resume" ]]; do
      (( SECONDS - barrier_started < barrier_timeout )) \
        || die "timed out waiting at test fleet-lock barrier: $barrier_file"
      sleep 0.02
    done
  fi
  if [[ -n "${PJANGLER_TEST_FLEET_LOCK_ATTEMPT:-}" ]]; then
    [[ -n "${PYTEST_CURRENT_TEST:-}" ]] \
      || die "PJANGLER_TEST_FLEET_LOCK_ATTEMPT is test-only and requires pytest"
    local attempt_file="$PJANGLER_TEST_FLEET_LOCK_ATTEMPT"
    [[ ! -L "$attempt_file" && ! -L "$(dirname "$attempt_file")" \
        && -d "$(dirname "$attempt_file")" ]] \
      || die "unsafe test fleet-lock attempt path: $attempt_file"
    printf '%s\n' "$lock_file" > "$attempt_file"
  fi
  flock -w "${FLEET_LOCK_TIMEOUT_SECONDS:-30}" "$FLEET_LOCK_FD" \
    || die "timed out waiting for fleet registry lock: $lock_file"
}

fleet_lock_release() {
  if [[ "${FLEET_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    flock -u "$FLEET_LOCK_FD" 2>/dev/null || true
    exec {FLEET_LOCK_FD}>&-
  fi
  FLEET_LOCK_FD=""
}

# Bloodbank / NATS
BLOODBANK_NATS_HOST="${BLOODBANK_NATS_HOST:-$(config_get bloodbank.nats_host '127.0.0.1')}"
BLOODBANK_NATS_PORT="${BLOODBANK_NATS_PORT:-$(config_get bloodbank.nats_port '4222')}"
BLOODBANK_COMPOSE_DIR="${BLOODBANK_COMPOSE_DIR:-$(config_get bloodbank.compose_dir "$HOME/code/33GOD/bloodbank")}"

# Plane
PLANE_BASE="${PLANE_BASE:-$(config_get plane.base 'https://plane.delo.sh')}"
if [[ "$SKIP_PLANE" != "1" ]]; then
  PLANE_API_KEY="${PLANE_API_KEY:-${PLANE_33GOD_API_KEY:-}}"
fi

export FLEET_ENV HERMES_BIN HERMES_AGENT_REPO PJANGLER_BIN HERMES_RUNTIME_GIT_URL \
       HERMES_RUNTIME_GIT_REF HERMES_RUNTIME_GIT_SHA HERMES_OAUTH_FILE CODEX_HOME \
       RUNTIME_SCAFFOLD_DIR REGISTRY_FILE \
       BLOODBANK_NATS_HOST BLOODBANK_NATS_PORT BLOODBANK_COMPOSE_DIR \
       PLANE_BASE SKIP_PLANE
if [[ "$SKIP_PLANE" != "1" ]]; then
  export PLANE_API_KEY
fi

# systemd --user health check. Accept running/degraded/starting — only one
# broken unit shouldn't disqualify the rest of the user manager.
systemd_user_available() {
  command -v systemctl >/dev/null || return 1
  local state; state=$(systemctl --user is-system-running 2>&1)
  [[ "$state" =~ ^(running|degraded|starting|maintenance)$ ]]
}

# Query one systemd user-unit state without conflating every non-zero exit with
# an inactive/disabled unit. Output is `ok|<state>` only for documented
# state/exit-code pairs; D-Bus, manager, and arbitrary query failures become
# `error|<safe summary>` so retirement callers can fail closed.
systemctl_user_unit_state() {
  local query="$1" unit="$2" output rc first_line
  command -v systemctl >/dev/null 2>&1 \
    || { printf 'error|systemctl unavailable'; return 0; }
  set +e
  output="$(LC_ALL=C systemctl --user "$query" "$unit" 2>&1)"
  rc=$?
  set -e
  first_line="${output%%$'\n'*}"
  first_line="${first_line//$'\t'/ }"
  first_line="${first_line//|/}"
  case "$query:$rc:$first_line" in
    is-active:0:active|is-active:0:reloading|is-active:0:activating|is-active:0:deactivating)
      printf 'ok|%s' "$first_line" ;;
    is-active:3:inactive|is-active:3:failed)
      printf 'ok|%s' "$first_line" ;;
    is-active:4:inactive)
      printf 'ok|not-found' ;;
    is-enabled:0:enabled|is-enabled:0:enabled-runtime|is-enabled:0:linked|is-enabled:0:linked-runtime|is-enabled:0:alias|is-enabled:0:static|is-enabled:0:indirect|is-enabled:0:generated|is-enabled:0:transient)
      printf 'ok|%s' "$first_line" ;;
    is-enabled:1:disabled|is-enabled:1:masked|is-enabled:1:masked-runtime)
      printf 'ok|%s' "$first_line" ;;
    is-enabled:4:not-found)
      printf 'ok|not-found' ;;
    *)
      [[ -n "$first_line" ]] || first_line="exit $rc with no state"
      printf 'error|%s' "$first_line" ;;
  esac
}

# Read-only live health checks for the unit states lifecycle scripts persist in
# role.yaml.  They deliberately include process result, main exit status,
# restart count, and activation/substate; `is-active` alone can briefly report
# success for a launcher that is already on its way to exit 78.
systemctl_user_show() {
  # systemctl_user_show UNIT PROPERTY...
  local unit="$1" output rc first_line
  shift
  local -a arguments=(--user show "$unit" --no-pager)
  local property
  for property in "$@"; do arguments+=("--property=$property"); done
  set +e
  output="$(LC_ALL=C systemctl "${arguments[@]}" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    first_line="${output%%$'\n'*}"
    first_line="${first_line//$'\t'/ }"
    first_line="${first_line//|/}"
    [[ -n "$first_line" ]] || first_line="exit $rc with no state"
    printf 'error|%s' "$first_line"
    return 0
  fi
  printf 'ok|%s' "$output"
}

systemd_service_health_snapshot() {
  # systemd_service_health_snapshot UNIT running|oneshot
  local unit="$1" kind="$2" active enabled shown payload
  local load_state="" active_state="" sub_state="" result=""
  local exec_status="" restarts="" key value
  active="$(systemctl_user_unit_state is-active "$unit")"
  enabled="$(systemctl_user_unit_state is-enabled "$unit")"
  [[ "$active" == "ok|active" ]] \
    || { printf 'error|activity=%s' "${active#*|}"; return 0; }
  [[ "$enabled" =~ ^ok\|(enabled|enabled-runtime)$ ]] \
    || { printf 'error|enablement=%s' "${enabled#*|}"; return 0; }
  shown="$(systemctl_user_show "$unit" LoadState ActiveState SubState Result ExecMainStatus NRestarts)"
  [[ "$shown" == ok\|* ]] || { printf '%s' "$shown"; return 0; }
  payload="${shown#ok|}"
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) load_state="$value" ;;
      ActiveState) active_state="$value" ;;
      SubState) sub_state="$value" ;;
      Result) result="$value" ;;
      ExecMainStatus) exec_status="$value" ;;
      NRestarts) restarts="$value" ;;
    esac
  done <<< "$payload"
  [[ "$load_state" == loaded && "$active_state" == active \
     && "$result" == success && "$exec_status" == 0 \
     && "$restarts" =~ ^[0-9]+$ ]] \
    || { printf 'error|load=%s active=%s sub=%s result=%s status=%s restarts=%s' \
         "$load_state" "$active_state" "$sub_state" "$result" "$exec_status" "$restarts"; return 0; }
  if [[ "$kind" == running && "$sub_state" != running ]]; then
    printf 'error|substate=%s' "$sub_state"
    return 0
  fi
  printf 'ok|%s' "$restarts"
}

systemd_timer_health_snapshot() {
  # systemd_timer_health_snapshot TIMER HEARTBEAT_SERVICE
  local timer="$1" service="$2" active enabled shown payload
  local load_state="" active_state="" sub_state="" key value
  local svc_shown svc_payload svc_load="" svc_active="" svc_sub=""
  local svc_result="" svc_status="" svc_restarts=""
  local svc_started="" svc_exited=""
  active="$(systemctl_user_unit_state is-active "$timer")"
  enabled="$(systemctl_user_unit_state is-enabled "$timer")"
  [[ "$active" == "ok|active" ]] \
    || { printf 'error|timer-activity=%s' "${active#*|}"; return 0; }
  [[ "$enabled" =~ ^ok\|(enabled|enabled-runtime)$ ]] \
    || { printf 'error|timer-enablement=%s' "${enabled#*|}"; return 0; }
  shown="$(systemctl_user_show "$timer" LoadState ActiveState SubState)"
  [[ "$shown" == ok\|* ]] || { printf '%s' "$shown"; return 0; }
  payload="${shown#ok|}"
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) load_state="$value" ;;
      ActiveState) active_state="$value" ;;
      SubState) sub_state="$value" ;;
    esac
  done <<< "$payload"
  [[ "$load_state" == loaded && "$active_state" == active \
     && "$sub_state" =~ ^(waiting|running|elapsed)$ ]] \
    || { printf 'error|timer-load=%s active=%s sub=%s' "$load_state" "$active_state" "$sub_state"; return 0; }

  # Inspect the latest oneshot result separately from the timer.  An inactive
  # (dead) service with Result=success/ExecMainStatus=0 is the healthy steady
  # state between ticks; failed/78 is never accepted.
  svc_shown="$(systemctl_user_show "$service" LoadState ActiveState SubState Result \
    ExecMainStatus NRestarts ExecMainStartTimestampMonotonic \
    ExecMainExitTimestampMonotonic)"
  [[ "$svc_shown" == ok\|* ]] || { printf '%s' "$svc_shown"; return 0; }
  svc_payload="${svc_shown#ok|}"
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) svc_load="$value" ;;
      ActiveState) svc_active="$value" ;;
      SubState) svc_sub="$value" ;;
      Result) svc_result="$value" ;;
      ExecMainStatus) svc_status="$value" ;;
      NRestarts) svc_restarts="$value" ;;
      ExecMainStartTimestampMonotonic) svc_started="$value" ;;
      ExecMainExitTimestampMonotonic) svc_exited="$value" ;;
    esac
  done <<< "$svc_payload"
  # A oneshot is healthy only after its main process has exited successfully.
  # systemd initializes Result=success/ExecMainStatus=0 before the first exit,
  # so accepting activating/start would turn a pre-exit sample into a false
  # completion claim. Monotonic start/exit timestamps prove a real invocation
  # completed and also make a new invocation visible to the stability window.
  [[ "$svc_load" == loaded && "$svc_active" == inactive \
     && "$svc_sub" == dead \
     && "$svc_result" == success && "$svc_status" == 0 \
     && "$svc_restarts" =~ ^[0-9]+$ \
     && "$svc_started" =~ ^[1-9][0-9]*$ \
     && "$svc_exited" =~ ^[1-9][0-9]*$ \
     && "$svc_exited" -ge "$svc_started" ]] \
    || { printf 'error|heartbeat-load=%s active=%s sub=%s result=%s status=%s restarts=%s started=%s exited=%s' \
         "$svc_load" "$svc_active" "$svc_sub" "$svc_result" "$svc_status" \
         "$svc_restarts" "$svc_started" "$svc_exited"; return 0; }
  printf 'ok|timer=%s:result=%s:status=%s:restarts=%s:started=%s:exited=%s' \
    "$sub_state" "$svc_result" "$svc_status" "$svc_restarts" "$svc_started" "$svc_exited"
}

systemd_gateway_deferred_snapshot() {
  local unit="$1" active enabled
  active="$(systemctl_user_unit_state is-active "$unit")"
  enabled="$(systemctl_user_unit_state is-enabled "$unit")"
  if [[ "$active" == "ok|inactive" \
     && "$enabled" =~ ^ok\|(disabled|masked|masked-runtime)$ ]]; then
    printf 'ok|deferred'
  else
    printf 'error|enablement=%s activity=%s' "${enabled#*|}" "${active#*|}"
  fi
}

systemd_wait_for_stable_health() {
  # systemd_wait_for_stable_health CHECK_FUNCTION ARGS...
  local checker="$1"
  shift
  local attempts="${SYSTEMD_STABILIZATION_ATTEMPTS:-6}"
  local required="${SYSTEMD_STABLE_SAMPLES:-3}"
  local interval="${SYSTEMD_STABILIZATION_INTERVAL_SECONDS:-1}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$required" =~ ^[1-9][0-9]*$ \
     && "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || { printf 'error|invalid stabilization settings'; return 1; }
  (( attempts >= required )) \
    || { printf 'error|stabilization attempts must cover required samples'; return 1; }
  local sample="" previous="" last_error="" stable=0 attempt
  local ever_healthy=0 unstable_after_health=0
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    sample="$($checker "$@")"
    if [[ "$sample" == ok\|* ]]; then
      if [[ -z "$previous" ]]; then
        previous="$sample"
        stable=1
      elif [[ "$sample" == "$previous" ]]; then
        stable=$((stable + 1))
      else
        (( ever_healthy == 0 )) || unstable_after_health=1
        previous="$sample"
        stable=1
      fi
      ever_healthy=1
    else
      [[ -z "$sample" ]] || last_error="$sample"
      (( ever_healthy == 0 )) || unstable_after_health=1
      previous=""
      stable=0
    fi
    if (( attempt < attempts )) && [[ "$interval" != 0 ]]; then
      sleep "$interval"
    fi
  done
  # Never return early: every configured sample belongs to the declared
  # observation window. Once a unit looked healthy, a later failure, restart,
  # or invocation timestamp change makes the whole window unstable.
  if (( stable >= required && unstable_after_health == 0 )); then
    printf '%s' "$sample"
    return 0
  fi
  printf '%s' "${last_error:-${sample:-error|no health sample}}"
  return 1
}

# Resolve project repo path (the repo that holds agents/hermes/<role>/).
# Walk up from $ROLE_DIR until we find a git root that isn't us.
project_repo_path() {
  # Structured provisioners know the project root even before a fresh target
  # receives its own .git directory. Accept only a root that contains this
  # exact role path; otherwise fail closed instead of walking into a parent
  # checkout and mutating its manifest.
  if [[ -n "${PJANGLER_PROJECT_ROOT:-}" ]]; then
    local explicit role_real
    explicit="$(cd "$PJANGLER_PROJECT_ROOT" 2>/dev/null && pwd -P)" || return 1
    role_real="$(cd "$ROLE_DIR" 2>/dev/null && pwd -P)" || return 1
    case "$role_real" in
      "$explicit"/agents/hermes/*) printf '%s\n' "$explicit"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  local d="$ROLE_DIR"
  [[ -d "$d/.git" || -f "$d/.git" ]] && { echo "$d"; return 0; }
  for _ in 1 2 3 4 5; do
    d="$(dirname "$d")"
    [[ -d "$d/.git" || -f "$d/.git" ]] && { echo "$d"; return 0; }
  done
  return 1
}
