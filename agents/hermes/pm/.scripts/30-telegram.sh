#!/usr/bin/env bash
# Capture a BotFather token and wire it into the runtime profile.
#
# Telegram credentials are invocation-only inputs. Capture them before _lib.sh
# sources fleet.env so a token parked in shared fleet state can never provision
# or be silently reused by a profile. The non-secret allow-list may be shared.
INVOCATION_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN-}"
INVOCATION_TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS-}"
# Invocation credentials may have arrived as exported variables.  Remove them
# before even resolving/sourcing _lib.sh: that path invokes utilities and loads
# fleet state, and no child involved in setup should inherit a raw token.
unset TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS

# Every channel write lands in the host-global profile root that 10-hermes-profile.sh
# creates. When that step is deferred the root does not exist yet, so there is no
# honest Telegram state to record -- not even the disabled state, which is itself a
# write into the profile. Defer with it. This guard must precede _lib.sh because that
# library creates the role log and reads fleet configuration.
if [[ "${SKIP_HOST_STATE:-0}" == "1" ]]; then
  printf '%s\n' '[30] telegram — DEFERRED (SKIP_HOST_STATE=1)' >&2
  exit 0
fi

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

TELEGRAM_BOT_TOKEN="$INVOCATION_TELEGRAM_BOT_TOKEN"
if [[ -n "$INVOCATION_TELEGRAM_ALLOWED_USERS" ]]; then
  TELEGRAM_ALLOWED_USERS="$INVOCATION_TELEGRAM_ALLOWED_USERS"
else
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS-}"
fi
unset INVOCATION_TELEGRAM_BOT_TOKEN INVOCATION_TELEGRAM_ALLOWED_USERS

PROFILE_HOME="$HOME/.hermes/profiles/$PROFILE_NAME"
profile_root_require_real "$PROFILE_HOME"
RUNTIME="$ROLE_DIR/runtime"
ENVF="$RUNTIME/.env"
mkdir -p "$RUNTIME"
[[ ! -L "$ENVF" ]] || die "refusing to write Telegram credentials through symlink: $ENVF"

telegram_reconcile_existing() {
  # Registry first, then the transaction helper's profile lock. The helper
  # snapshots and validates refs plus role metadata only inside this window.
  local rc=0
  fleet_lock_acquire
  trap 'fleet_lock_release' EXIT
  channel_transaction_telegram_existing "$PROFILE_HOME" "$ENVF" || rc=$?
  fleet_lock_release
  trap - EXIT
  return "$rc"
}

telegram_defer_if_unconfigured() {
  # Prepare and, when already verified, reconcile under one registry-lock
  # window. The helpers independently take the profile lock second.
  local prepare_rc=0 rc=0
  fleet_lock_acquire
  trap 'fleet_lock_release' EXIT
  channel_transaction_telegram_prepare_unconfigured \
    "$PROFILE_HOME" "$ENVF" || prepare_rc=$?
  case "$prepare_rc" in
    0)
      fleet_lock_release
      trap - EXIT
      return 2
      ;;
    3)
      channel_transaction_telegram_existing "$PROFILE_HOME" "$ENVF" || rc=$?
      ;;
    *)
      die "Telegram deferred-state preparation transaction failed"
      ;;
  esac
  case "$rc" in
    0)
      fleet_lock_release
      trap - EXIT
      return 0
      ;;
    75)
      die "Telegram 1Password reference validation is temporarily unavailable; preserved existing verified wiring for retry"
      ;;
    *)
      die "Telegram verified wiring reconciliation transaction failed"
      ;;
  esac
}

telegram_prepare_for_attempt() {
  # A new profile becomes explicitly disabled before remote verification. A
  # verified profile is a no-op so a failed rotation preserves active wiring.
  local rc=0
  fleet_lock_acquire
  trap 'fleet_lock_release' EXIT
  channel_transaction_telegram_prepare_unconfigured \
    "$PROFILE_HOME" "$ENVF" || rc=$?
  fleet_lock_release
  trap - EXIT
  case "$rc" in
    0|3) return 0 ;;
    *) die "Telegram deferred-state preparation transaction failed" ;;
  esac
}

# A valid durable mapping survives a transient 1Password outage. If the caller
# supplied no rotation value, adopt/revalidate the complete current wiring
# under registry -> profile locks. No ref or identity snapshot escapes that
# window.
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  telegram_reference_rc=0
  telegram_reconcile_existing || telegram_reference_rc=$?
  case "$telegram_reference_rc" in
    0)
      log "[30] telegram — existing verified 1Password wiring reconciled"
      exit 0
      ;;
    2) ;;
    75)
      die "Telegram 1Password reference validation is temporarily unavailable; preserved existing verified wiring for retry"
      ;;
    *)
      die "Telegram verified wiring reconciliation transaction failed"
      ;;
  esac
fi

# Establish explicit disabled state for a first-time credential attempt. This
# recheck is serialized with rotations: existing verified wiring is preserved,
# while an unconfigured profile is disabled before any fallible remote check.
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  telegram_prepare_for_attempt
fi

if [[ "${SKIP_TELEGRAM:-0}" == "1" ]]; then
  telegram_defer_rc=0
  telegram_defer_if_unconfigured || telegram_defer_rc=$?
  if [[ $telegram_defer_rc -eq 2 ]]; then
    log "[30] telegram — DEFERRED (SKIP_TELEGRAM=1; no verified 1Password reference)"
  else
    log "[30] telegram — existing verified 1Password wiring reconciled"
  fi
  exit 0
fi

if already_done 30-telegram; then
  log "[30] existing completion marker preserved while Telegram is reconciled"
fi

cat >&2 <<EOF

╭─ BotFather steps for @$BOT_HANDLE ─────────────────────────────────────╮
│ 1. Open Telegram, message @BotFather                                   │
│ 2. /newbot                                                             │
│ 3. Display name:   $DISPLAY_NAME                                       │
│ 4. Username:       $BOT_HANDLE  (must end in _bot)                     │
│ 5. Copy the HTTP API token from the reply.                             │
│ 6. /setjoingroups → Disable                                            │
│ 7. /setprivacy    → Disable                                            │
╰────────────────────────────────────────────────────────────────────────╯

EOF

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -t 0 ]]; then
  read -r -s -p "Paste the bot token for @$BOT_HANDLE (or empty to skip): " TELEGRAM_BOT_TOKEN
  echo >&2
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  telegram_defer_rc=0
  telegram_defer_if_unconfigured || telegram_defer_rc=$?
  if [[ $telegram_defer_rc -eq 2 ]]; then
    warn "    no token provided; Telegram step deferred"
    warn "    re-run later with a profile-dedicated TELEGRAM_BOT_TOKEN invocation"
  else
    log "[30] telegram — existing verified 1Password wiring reconciled"
  fi
  exit 0
fi

# Sanity check
if [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  die "token doesn't look like a Telegram bot token"
fi
log "    verifying token..."
# Keep the credential out of process argv and environment. curl reads its
# complete request description from an anonymous stdin pipe.
info="$({
  printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$TELEGRAM_BOT_TOKEN"
  printf '%s\n' 'fail' 'silent' 'show-error'
} | curl --config -)" \
  || die "Telegram getMe request failed"
identity=$(printf '%s' "$info" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit("Telegram getMe returned an invalid response")
result = data.get("result") or {}
if not data.get("ok") or not result.get("id") or not result.get("username"):
    raise SystemExit("Telegram rejected the bot token or omitted identity fields")
print("{}\t{}".format(
    result.get("id"), str(result.get("username")).replace(chr(9), " ").replace(chr(10), " ")
))
') || die "Telegram bot identity verification failed"
IFS=$'\t' read -r bot_id bot_username <<< "$identity"
log "    verified: @$bot_username (id=$bot_id)"

# Resolve operator's allowed user id before taking the fleet claim lock.
if [[ -z "${TELEGRAM_ALLOWED_USERS:-}" && -f "$HOME/.hermes/.env" ]]; then
  TELEGRAM_ALLOWED_USERS=$(grep -E '^[[:space:]]*#?[[:space:]]*TELEGRAM_ALLOWED_USERS=' "$HOME/.hermes/.env" \
    | tail -1 | sed -E 's/^[[:space:]]*#?[[:space:]]*TELEGRAM_ALLOWED_USERS=//; s/^"//; s/"$//')
fi
if [[ -z "${TELEGRAM_ALLOWED_USERS:-}" && -t 0 ]]; then
  read -r -p "Your Telegram user id (allow-list for this bot): " TELEGRAM_ALLOWED_USERS
fi
if [[ -z "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
  warn "    Telegram is wired but denies all inbound users until TELEGRAM_ALLOWED_USERS is set"
fi

# Reject token reuse, token rotation onto an identity owned by another agent,
# and credentials parked in shared fleet/root env files. The scan, durable
# identity claim, and profile credential write share one fleet-wide flock.
fleet_lock_acquire
trap 'fleet_lock_release' EXIT
python3 /dev/fd/3 "$REGISTRY_FILE" "$FLEET_ENV" "$ENVF" "$AGENT_ID" "$bot_id" \
  "$ROLE_DIR" "$PROFILE_NAME" "$bot_username" \
  3<<'PYEOF' <<<"$TELEGRAM_BOT_TOKEN"
import os
import pathlib
import re
import sys
try:
    import yaml  # type: ignore
except ImportError:
    raise SystemExit("PyYAML is required for Telegram fleet claims")

(
    registry_path,
    fleet_path,
    target_path,
    agent_id,
    bot_id,
    role_dir,
    profile_name,
    bot_username,
) = sys.argv[1:]
token = sys.stdin.read()
if token.endswith("\n"):
    token = token[:-1]
if not token:
    raise SystemExit("Telegram ownership scan received no credential")
for metadata_path in (pathlib.Path("/proc/self/cmdline"), pathlib.Path("/proc/self/environ")):
    if metadata_path.is_file() and token.encode() in metadata_path.read_bytes():
        raise SystemExit("Telegram ownership scan detected credential exposure in process metadata")
target = pathlib.Path(target_path).resolve(strict=False)

def env_token(path):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    match = re.search(
        r"(?m)^\s*(?:export\s+)?TELEGRAM_BOT_TOKEN\s*=\s*(.*)$", text
    )
    if not match:
        return None
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value

owners = [("shared fleet environment", pathlib.Path(fleet_path))]
registry = pathlib.Path(registry_path)
if registry.is_symlink():
    raise SystemExit(f"refusing to update registry symlink: {registry}")
data = {"schema_version": 1, "agents": {}}
if registry.is_file():
    try:
        data = yaml.safe_load(registry.read_text(encoding="utf-8")) or data
    except Exception as exc:
        raise SystemExit(f"cannot safely inspect Telegram ownership registry: {type(exc).__name__}")
if not isinstance(data, dict) or not isinstance(data.get("agents", {}), dict):
    raise SystemExit("cannot safely inspect Telegram ownership registry: invalid agents mapping")
agents = data.setdefault("agents", {})
for other_id, entry in agents.items():
    if other_id == agent_id or not isinstance(entry, dict):
        continue
    telegram = entry.get("telegram") or {}
    if isinstance(telegram, dict) and str(telegram.get("bot_id") or "") == bot_id:
        raise SystemExit(f"Telegram bot identity is already assigned to agent {other_id}")
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
    if env_token(path) == token:
        raise SystemExit(f"Telegram bot token is already assigned to {owner}")

# This phase is intentionally read-only. The later channel transaction repeats
# identity-conflict validation under the same lock before committing registry
# metadata, so a failed vault stage cannot leave a false ownership claim.
PYEOF

# Stage the credential in a new immutable 1Password item. The helper verifies
# the staged field and returns the immutable item id plus reference; no local
# ownership/config state has changed yet.
ONEPASSWORD_ITEM_PREFIX="${HERMES_ONEPASSWORD_ITEM_PREFIX:-$(config_get fleet.onepassword_item_prefix 'hermes-agent')}"
telegram_stage="$(stage_onepassword_secret \
  "${ONEPASSWORD_ITEM_PREFIX}-${AGENT_ID}-telegram-bot-token" \
  telegram_bot_token "$TELEGRAM_BOT_TOKEN")" \
  || die "Telegram credential could not be staged and verified in 1Password"
if [[ "$telegram_stage" != *$'\n'* ]]; then
  die "Telegram credential staging returned an invalid result"
fi
telegram_staged_item_id="${telegram_stage%%$'\n'*}"
telegram_reference="${telegram_stage#*$'\n'}"
[[ "$telegram_reference" != *$'\n'* ]] \
  || die "Telegram credential staging returned too many references"
unset TELEGRAM_BOT_TOKEN

# From here until commit, any failure archives the staged item by immutable id
# and releases the fleet lock. The transaction itself keeps the platform
# disabled while committing refs, role metadata, runtime policy, and registry;
# activation and the done marker are its final writes.
telegram_transaction_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "${telegram_staged_item_id:-}" ]]; then
    delete_staged_onepassword_item "$telegram_staged_item_id" >/dev/null 2>&1 \
      || warn "    staged Telegram item cleanup failed; archive manually by immutable item id"
  fi
  fleet_lock_release
  exit "$rc"
}
trap telegram_transaction_exit EXIT

channel_transaction_telegram \
  "$PROFILE_HOME" "$ENVF" "$telegram_reference" \
  "$bot_username" "$bot_id" "${TELEGRAM_ALLOWED_USERS:-}" \
  || die "Telegram local credential transaction failed"

telegram_staged_item_id=""

fleet_lock_release
trap - EXIT

log "    wired @$bot_username (id=$bot_id) through 1Password reference"
