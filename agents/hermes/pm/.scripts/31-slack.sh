#!/usr/bin/env bash
# Opt-in, profile-local Slack Socket Mode provisioning.
#
# Slack credentials are invocation-only inputs.  Capture them before _lib.sh
# sources fleet.env so an accidentally shared fleet token can never provision a
# profile.  The non-secret allowed-user policy may still come from fleet.env.
INVOCATION_SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN-}"
INVOCATION_SLACK_APP_TOKEN="${SLACK_APP_TOKEN-}"
INVOCATION_SLACK_ALLOWED_USERS="${SLACK_ALLOWED_USERS-}"
INVOCATION_ENABLE_SLACK="${ENABLE_SLACK-${WIRE_SLACK-}}"
# Copy invocation-only inputs, then immediately clear their exported form.
# Resolving/sourcing _lib.sh executes PATH children; none may inherit channel
# credentials (or accidentally treat the invocation policy as fleet state).
unset SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS ENABLE_SLACK WIRE_SLACK

# Every channel write lands in the host-global profile root that 10-hermes-profile.sh
# creates. When that step is deferred the root does not exist yet, so there is no
# honest Slack state to record -- not even the disabled state, which is itself a
# write into the profile. Defer with it. This guard must precede _lib.sh because that
# library creates the role log and reads fleet configuration.
if [[ "${SKIP_HOST_STATE:-0}" == "1" ]]; then
  printf '%s\n' '[31] slack — DEFERRED (SKIP_HOST_STATE=1)' >&2
  exit 0
fi

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

SLACK_BOT_TOKEN="$INVOCATION_SLACK_BOT_TOKEN"
SLACK_APP_TOKEN="$INVOCATION_SLACK_APP_TOKEN"
if [[ -n "$INVOCATION_SLACK_ALLOWED_USERS" ]]; then
  SLACK_ALLOWED_USERS="$INVOCATION_SLACK_ALLOWED_USERS"
else
  SLACK_ALLOWED_USERS="${SLACK_ALLOWED_USERS-}"
fi
ENABLE_SLACK="$INVOCATION_ENABLE_SLACK"
unset INVOCATION_SLACK_BOT_TOKEN INVOCATION_SLACK_APP_TOKEN

PROFILE_HOME="$HOME/.hermes/profiles/$PROFILE_NAME"
profile_root_require_real "$PROFILE_HOME"
RUNTIME="$ROLE_DIR/runtime"
ENVF="$RUNTIME/.env"
mkdir -p "$RUNTIME"
[[ ! -L "$ENVF" ]] || die "refusing to write Slack credentials through symlink: $ENVF"

slack_reconcile_existing() {
  # Registry first, then the transaction helper's profile lock. The helper
  # snapshots and validates both refs plus role metadata inside this window.
  local rc=0
  fleet_lock_acquire
  trap 'fleet_lock_release' EXIT
  channel_transaction_slack_existing "$PROFILE_HOME" "$ENVF" || rc=$?
  fleet_lock_release
  trap - EXIT
  return "$rc"
}

slack_defer_if_unconfigured() {
  # Prepare and, when already verified, reconcile under one registry-lock
  # window. The helpers independently take the profile lock second.
  local prepare_rc=0 rc=0
  fleet_lock_acquire
  trap 'fleet_lock_release' EXIT
  channel_transaction_slack_prepare_unconfigured \
    "$PROFILE_HOME" "$ENVF" || prepare_rc=$?
  case "$prepare_rc" in
    0)
      fleet_lock_release
      trap - EXIT
      return 2
      ;;
    3)
      channel_transaction_slack_existing "$PROFILE_HOME" "$ENVF" || rc=$?
      ;;
    *)
      die "Slack deferred-state preparation transaction failed"
      ;;
  esac
  case "$rc" in
    0)
      fleet_lock_release
      trap - EXIT
      return 0
      ;;
    75)
      die "Slack 1Password reference validation is temporarily unavailable; preserved existing verified wiring for retry"
      ;;
    *)
      die "Slack verified wiring reconciliation transaction failed"
      ;;
  esac
}

slack_prepare_for_attempt() {
  # A new profile becomes explicitly disabled before remote verification. A
  # verified profile is a no-op so a failed rotation preserves active wiring.
  local rc=0
  fleet_lock_acquire
  trap 'fleet_lock_release' EXIT
  channel_transaction_slack_prepare_unconfigured \
    "$PROFILE_HOME" "$ENVF" || rc=$?
  fleet_lock_release
  trap - EXIT
  case "$rc" in
    0|3) return 0 ;;
    *) die "Slack deferred-state preparation transaction failed" ;;
  esac
}

truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Preserve and reconcile durable wiring across transient 1Password outages.
# An explicit token is a rotation request. With no tokens, the complete current
# ref/identity snapshot is taken only after registry -> profile locks are held.
if [[ -z "${SLACK_BOT_TOKEN:-}" && -z "${SLACK_APP_TOKEN:-}" ]]; then
  slack_reference_rc=0
  slack_reconcile_existing || slack_reference_rc=$?
  case "$slack_reference_rc" in
    0)
      log "[31] slack — existing verified 1Password wiring reconciled"
      exit 0
      ;;
    2) ;;
    75)
      die "Slack 1Password reference validation is temporarily unavailable; preserved existing verified wiring for retry"
      ;;
    *)
      die "Slack verified wiring reconciliation transaction failed"
      ;;
  esac
fi

# Establish explicit disabled state for a first-time credential attempt. The
# registry -> profile lock recheck preserves any already-verified wiring and
# prevents this preparation from racing a concurrent rotation.
if [[ -n "${SLACK_BOT_TOKEN:-}" || -n "${SLACK_APP_TOKEN:-}" ]]; then
  slack_prepare_for_attempt
fi

if [[ "${SKIP_SLACK:-0}" == "1" ]]; then
  slack_defer_rc=0
  slack_defer_if_unconfigured || slack_defer_rc=$?
  if [[ $slack_defer_rc -eq 2 ]]; then
    log "[31] slack — DEFERRED (SKIP_SLACK=1; no verified 1Password reference pair)"
  else
    log "[31] slack — existing verified 1Password wiring reconciled"
  fi
  exit 0
fi

if already_done 31-slack; then
  log "[31] existing completion marker preserved while Slack is reconciled"
fi

have_bot=0
have_app=0
[[ -n "$SLACK_BOT_TOKEN" ]] && have_bot=1
[[ -n "$SLACK_APP_TOKEN" ]] && have_app=1

if ! truthy "${ENABLE_SLACK:-0}" && (( ! have_bot && ! have_app )); then
  slack_defer_rc=0
  slack_defer_if_unconfigured || slack_defer_rc=$?
  if [[ $slack_defer_rc -eq 2 ]]; then
    log "[31] slack — deferred (opt in with ENABLE_SLACK=1 or supply both Slack tokens)"
  else
    log "[31] slack — existing verified 1Password wiring reconciled"
  fi
  exit 0
fi

if (( have_bot != have_app )) && ! truthy "${ENABLE_SLACK:-0}"; then
  die "Slack provisioning requires a dedicated SLACK_BOT_TOKEN and SLACK_APP_TOKEN pair"
fi

if truthy "${ENABLE_SLACK:-0}" && [[ -t 0 ]]; then
  if [[ -z "$SLACK_BOT_TOKEN" ]]; then
    read -r -s -p "Slack Bot User OAuth Token (xoxb-...): " SLACK_BOT_TOKEN
    echo >&2
  fi
  if [[ -z "$SLACK_APP_TOKEN" ]]; then
    read -r -s -p "Slack App-Level Socket Mode Token (xapp-...): " SLACK_APP_TOKEN
    echo >&2
  fi
fi

[[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_APP_TOKEN" ]] \
  || die "Slack provisioning requires both SLACK_BOT_TOKEN and SLACK_APP_TOKEN"
[[ "$SLACK_BOT_TOKEN" =~ ^xoxb-[A-Za-z0-9-]+$ ]] || die "SLACK_BOT_TOKEN must be a Bot User OAuth token (xoxb-...)"
[[ "$SLACK_APP_TOKEN" =~ ^xapp-[A-Za-z0-9-]+$ ]] || die "SLACK_APP_TOKEN must be an App-Level Socket Mode token (xapp-...)"

SLACK_ALLOWED_USERS="${SLACK_ALLOWED_USERS//[[:space:]]/}"
if [[ -n "$SLACK_ALLOWED_USERS" && "$SLACK_ALLOWED_USERS" != "*" \
      && ! "$SLACK_ALLOWED_USERS" =~ ^[UW][A-Z0-9]+(,[UW][A-Z0-9]+)*$ ]]; then
  die "SLACK_ALLOWED_USERS must be '*' or comma-separated Slack member IDs"
fi

log "[31] verifying Slack bot identity via auth.test"
auth_response="$({
  printf '%s\n' 'url = "https://slack.com/api/auth.test"'
  printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN"
  printf '%s\n' 'header = "Content-Type: application/x-www-form-urlencoded"'
  printf '%s\n' 'request = "POST"' 'fail' 'silent' 'show-error' \
    'connect-timeout = 10' 'max-time = 20' 'max-filesize = 1048576'
} | curl --config -)" \
  || die "Slack auth.test request failed"

identity=$(printf '%s' "$auth_response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit("Slack auth.test returned an invalid response")
if not data.get("ok"):
    error = str(data.get("error") or "unknown_error")
    safe = "".join(c for c in error if c.isalnum() or c in "_-.")[:80]
    raise SystemExit("Slack auth.test rejected the bot token ({})".format(safe or "unknown_error"))
values = [data.get(k, "") for k in ("team_id", "team", "user_id", "bot_id", "user")]
if not values[0] or not values[2] or not values[3]:
    raise SystemExit("Slack auth.test response omitted required identity fields")
print("\t".join(str(v).replace("\t", " ").replace("\n", " ") for v in values))
') || die "Slack bot identity verification failed"
IFS=$'\t' read -r slack_team_id slack_team_name slack_bot_user_id slack_bot_id slack_bot_username <<< "$identity"

# auth.test proves the bot installation/workspace, while bots.info provides the
# authoritative Slack app identity for that bot.  Correlation requires the
# app's users:read scope; missing scope is a hard, truthful deferred outcome.
log "[31] resolving Slack bot app identity via bots.info"
bot_info_response="$({
  printf '%s\n' 'url = "https://slack.com/api/bots.info"'
  printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN"
  printf '%s\n' 'header = "Content-Type: application/x-www-form-urlencoded"'
  printf 'data = "bot=%s"\n' "$slack_bot_id"
  printf '%s\n' 'request = "POST"' 'fail' 'silent' 'show-error' \
    'connect-timeout = 10' 'max-time = 20' 'max-filesize = 1048576'
} | curl --config -)" \
  || die "Slack bots.info request failed; Slack remains deferred"
slack_bot_app_id="$(printf '%s' "$bot_info_response" | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit("Slack bots.info returned an invalid response")
if not isinstance(data, dict) or not data.get("ok"):
    error = str(data.get("error") if isinstance(data, dict) else "unknown_error")
    if error == "missing_scope":
        raise SystemExit(
            "Slack bots.info requires users:read; add that bot scope, reinstall the app, and rerun"
        )
    safe = "".join(c for c in error if c.isalnum() or c in "_-." )[:80]
    raise SystemExit("Slack bots.info rejected identity lookup ({})".format(safe or "unknown_error"))
bot = data.get("bot")
app_id = bot.get("app_id") if isinstance(bot, dict) else None
if not isinstance(app_id, str) or not re.fullmatch(r"[A-Z][A-Z0-9]+", app_id):
    raise SystemExit("Slack bots.info response omitted a valid bot.app_id")
print(app_id)
')" || die "Slack bot app identity verification failed; Slack remains deferred"

# Socket Mode requires a separately authenticated app-level token. A valid bot
# token says nothing about the xapp credential, so prove that credential can
# open a connection before claiming ownership or persisting either secret. The
# token and Slack's returned WebSocket URL stay on anonymous pipes: neither is
# exposed through curl argv, child environments, logs, or durable files.
log "[31] verifying Slack Socket Mode app token via apps.connections.open"
slack_socket_app_id="$({
  printf '%s\n' 'url = "https://slack.com/api/apps.connections.open"'
  printf 'header = "Authorization: Bearer %s"\n' "$SLACK_APP_TOKEN"
  printf '%s\n' 'header = "Content-Type: application/x-www-form-urlencoded"'
  printf '%s\n' 'request = "POST"' 'fail' 'silent' 'show-error' \
    'connect-timeout = 10' 'max-time = 20' 'max-filesize = 1048576'
} | curl --config - | python3 -c '
import json, re, sys
from urllib.parse import parse_qs, urlparse
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit("Slack apps.connections.open returned an invalid response")
if not isinstance(data, dict) or not data.get("ok"):
    error = str(data.get("error") if isinstance(data, dict) else "unknown_error")
    safe = "".join(c for c in error if c.isalnum() or c in "_-." )[:80]
    raise SystemExit("Slack apps.connections.open rejected the app token ({})".format(safe or "unknown_error"))
url = data.get("url")
if not isinstance(url, str):
    raise SystemExit("Slack apps.connections.open response omitted a Socket Mode URL")
parsed = urlparse(url)
if parsed.scheme != "wss" or not parsed.netloc:
    raise SystemExit("Slack apps.connections.open response omitted a valid Socket Mode URL")
app_ids = parse_qs(parsed.query, keep_blank_values=True).get("app_id", [])
if len(app_ids) != 1 or not re.fullmatch(r"[A-Z][A-Z0-9]+", app_ids[0]):
    raise SystemExit("Slack Socket Mode URL omitted a valid app_id identity")
print(app_ids[0])
')" || die "Slack Socket Mode app-token verification failed; Slack remains deferred"

[[ "$slack_bot_app_id" == "$slack_socket_app_id" ]] \
  || die "Slack bot and Socket Mode tokens belong to different apps; Slack remains deferred"

# Reject credential reuse, token rotation onto an identity owned by another
# agent, and credentials parked in shared env files. The scan, durable identity
# claim, and profile credential write share one fleet-wide flock.
fleet_lock_acquire
trap 'fleet_lock_release' EXIT
python3 /dev/fd/3 "$REGISTRY_FILE" "$FLEET_ENV" "$ENVF" "$AGENT_ID" \
  "$slack_team_id" "$slack_bot_user_id" "$slack_bot_id" \
  "$ROLE_DIR" "$PROFILE_NAME" "$slack_team_name" "$slack_bot_username" \
  3<<'PYEOF' <<<"${SLACK_BOT_TOKEN}"$'\n'"${SLACK_APP_TOKEN}"
import os
import pathlib
import re
import sys
try:
    import yaml  # type: ignore
except ImportError:
    raise SystemExit("PyYAML is required for Slack fleet claims")

(
    registry_path,
    fleet_path,
    target_path,
    agent_id,
    team_id,
    user_id,
    bot_id,
    role_dir,
    profile_name,
    team_name,
    bot_username,
) = sys.argv[1:]
credential_lines = sys.stdin.read().splitlines()
if len(credential_lines) != 2 or not all(credential_lines):
    raise SystemExit("Slack ownership scan received an invalid credential pair")
bot_token, app_token = credential_lines
for metadata_path in (pathlib.Path("/proc/self/cmdline"), pathlib.Path("/proc/self/environ")):
    if metadata_path.is_file():
        metadata = metadata_path.read_bytes()
        if any(secret.encode() in metadata for secret in (bot_token, app_token)):
            raise SystemExit("Slack ownership scan detected credential exposure in process metadata")
target = pathlib.Path(target_path).resolve(strict=False)

def env_values(path):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return {}
    values = {}
    for key in ("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"):
        match = re.search(rf"(?m)^\s*(?:export\s+)?{key}\s*=\s*(.*)$", text)
        if match:
            value = match.group(1).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key] = value
    return values

owners = [("shared fleet environment", pathlib.Path(fleet_path))]
registry = pathlib.Path(registry_path)
if registry.is_symlink():
    raise SystemExit(f"refusing to update registry symlink: {registry}")
data = {"schema_version": 1, "agents": {}}
if registry.is_file():
    try:
        data = yaml.safe_load(registry.read_text(encoding="utf-8")) or data
    except Exception as exc:
        raise SystemExit(f"cannot safely inspect Slack ownership registry: {type(exc).__name__}")
if not isinstance(data, dict) or not isinstance(data.get("agents", {}), dict):
    raise SystemExit("cannot safely inspect Slack ownership registry: invalid agents mapping")
agents = data.setdefault("agents", {})
for other_id, entry in agents.items():
    if other_id == agent_id or not isinstance(entry, dict):
        continue
    slack = entry.get("slack") or {}
    if isinstance(slack, dict):
        same_user = user_id and slack.get("bot_user_id") == user_id
        same_bot = bot_id and slack.get("bot_id") == bot_id
        same_team_user = team_id and same_user and slack.get("team_id") == team_id
        if same_bot or same_team_user:
            raise SystemExit(f"Slack bot identity is already assigned to agent {other_id}")
    other_role_dir = entry.get("role_dir")
    if other_role_dir:
        owners.append((f"agent {other_id}", pathlib.Path(str(other_role_dir)) / "runtime" / ".env"))

home_value = os.environ.get("HOME", "")
if home_value:
    home = pathlib.Path(home_value)
    owners.append(("shared Hermes root", home / ".hermes" / ".env"))
    profiles = home / ".hermes" / "profiles"
    if profiles.is_dir():
        for profile in profiles.iterdir():
            owners.append((f"profile {profile.name}", profile / ".env"))

seen = set()
for owner, path in owners:
    resolved = path.resolve(strict=False)
    if resolved == target or resolved in seen:
        continue
    seen.add(resolved)
    values = env_values(path)
    if values.get("SLACK_BOT_TOKEN") == bot_token:
        raise SystemExit(f"Slack bot token is already assigned to {owner}")
    if values.get("SLACK_APP_TOKEN") == app_token:
        raise SystemExit(f"Slack app token is already assigned to {owner}")

# Read-only by design. The channel transaction repeats the identity conflict
# check under this same lock immediately before its recoverable registry write.
PYEOF

# Stage both credentials in one new 1Password item, verify both fields, then
# switch both profile refs with one atomic delta update.  A failed rotation
# leaves the previously active pair untouched.
ONEPASSWORD_ITEM_PREFIX="${HERMES_ONEPASSWORD_ITEM_PREFIX:-$(config_get fleet.onepassword_item_prefix 'hermes-agent')}"
slack_stage="$(stage_onepassword_secret_pair \
  "${ONEPASSWORD_ITEM_PREFIX}-${AGENT_ID}-slack-credentials" \
  slack_bot_token "$SLACK_BOT_TOKEN" \
  slack_app_token "$SLACK_APP_TOKEN")" \
  || die "Slack credential pair could not be staged and verified in 1Password"
if [[ "$slack_stage" != *$'\n'*$'\n'* ]]; then
  die "Slack credential-pair storage returned an invalid reference set"
fi
slack_staged_item_id="${slack_stage%%$'\n'*}"
slack_pair_references="${slack_stage#*$'\n'}"
slack_bot_reference="${slack_pair_references%%$'\n'*}"
slack_app_reference="${slack_pair_references#*$'\n'}"
[[ "$slack_app_reference" != *$'\n'* ]] \
  || die "Slack credential-pair storage returned too many references"
unset SLACK_BOT_TOKEN SLACK_APP_TOKEN

slack_transaction_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "${slack_staged_item_id:-}" ]]; then
    delete_staged_onepassword_item "$slack_staged_item_id" >/dev/null 2>&1 \
      || warn "    staged Slack item cleanup failed; archive manually by immutable item id"
  fi
  fleet_lock_release
  exit "$rc"
}
trap slack_transaction_exit EXIT

channel_transaction_slack \
  "$PROFILE_HOME" "$ENVF" "$slack_bot_reference" "$slack_app_reference" \
  "$slack_team_id" "$slack_team_name" "$slack_bot_user_id" \
  "$slack_bot_id" "$slack_bot_username" "$SLACK_ALLOWED_USERS" \
  || die "Slack local credential transaction failed"

slack_staged_item_id=""

fleet_lock_release
trap - EXIT

if [[ -z "$SLACK_ALLOWED_USERS" ]]; then
  warn "    Slack is wired but denies all inbound users until SLACK_ALLOWED_USERS is set"
fi
log "    verified Slack bot $slack_bot_username in $slack_team_name (profile-local credentials)"
