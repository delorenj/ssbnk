#!/usr/bin/env bash
# Secret-free launcher for the per-agent HEARTBEAT pass. Decrypted values are read
# only from the service manager's volatile credential directory and never printed
# or written.
#
# GATEWAY MODE IS RETIRED (2026-10-11). It used to be a per-agent unit's ExecStart
# (`gateway run --replace`). Since then ONE host unit, hermes-gateway.service,
# serves every profile and execs the hermes binary directly, never this script. A
# per-agent unit pointing here would `--replace` and take over the host gateway
# (james-brennan-pm 2026-10-20 blocked Bloodbank for 3h; tolt-pm 2026-11-02 put
# the host unit in a ~975-restart loop), so `gateway` now refuses unconditionally.
set -euo pipefail

mode="${1:-}"
if [[ "$mode" == "gateway" ]]; then
  {
    printf 'credential-launch: gateway mode is retired and refuses to run.\n'
    printf '  ONE host gateway, hermes-gateway.service, serves every profile; a per-agent\n'
    printf '  `gateway run --replace` would take it over. Profiles are attached through the\n'
    printf '  control socket (~/.hermes/gateway.sock). To pick up a change, run once:\n'
    printf '      hermes-gateway-restart --reason "<why>"\n'
  } >&2
  exit 64
fi
[[ "$mode" == "heartbeat" ]] \
  || { printf 'credential-launch: expected heartbeat (gateway mode is retired)\n' >&2; exit 2; }

ROLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROLE_YAML="$ROLE_DIR/role.yaml"

# The block-scoped walker _lib.sh's yaml_get uses (lib/role-yaml.py). This
# launcher was the gateway's ExecStart, so it calls the reader directly instead
# of sourcing _lib.sh and its fleet environment. The regex reader it replaces
# ended a block at the first blank line and kept trailing comments.
ROLE_YAML_READER="$ROLE_DIR/.scripts/lib/role-yaml.py"
[[ -f "$ROLE_YAML_READER" && ! -L "$ROLE_YAML_READER" ]] \
  || { printf 'credential-launch: trusted role.yaml reader is unavailable\n' >&2; exit 1; }
yaml_get() {
  python3 "$ROLE_YAML_READER" "$ROLE_YAML" "$1"
}

AGENT_ID="$(yaml_get agent_id)"
PROFILE_NAME="$(yaml_get profile)"
[[ -n "$AGENT_ID" && -n "$PROFILE_NAME" ]] \
  || { printf 'credential-launch: incomplete role identity\n' >&2; exit 2; }
[[ -n "${HERMES_BIN:-}" && -x "$HERMES_BIN" ]] \
  || { printf 'credential-launch: HERMES_BIN is not executable\n' >&2; exit 1; }

FLEET_HOME="${HERMES_FLEET_HOME:-$HOME/.hermes}"
PROFILE_HOME="$FLEET_HOME/profiles/${PROFILE_NAME:-$AGENT_ID}"
[[ -d "$PROFILE_HOME" && ! -L "$PROFILE_HOME" ]] \
  || { printf 'credential-launch: named profile is not a real directory\n' >&2; exit 1; }
export HERMES_HOME="$PROFILE_HOME"

if ! REPO_ROOT="$(git -C "$ROLE_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  REPO_ROOT="$ROLE_DIR"
fi
export TERMINAL_CWD="$REPO_ROOT"

# Do not forward a stale/raw channel value inherited from the service manager,
# login shell, or a legacy runtime EnvironmentFile. Hermes hydrates the named
# profile's validated 1Password references after this launcher execs it.
unset TELEGRAM_BOT_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN

load_credential() {
  local credential_id="$1" env_name="$2" credential_file value
  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { printf 'credential-launch: invalid credential environment name\n' >&2; exit 2; }
  credential_file="${CREDENTIALS_DIRECTORY:-}/$credential_id"
  [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "$credential_file" ]] || return 0
  value="$(<"$credential_file")"
  printf -v "$env_name" '%s' "$value"
  export "$env_name"
  unset value
}

MODEL_KEY_ENV="$(yaml_get model.key_env)"
if [[ -n "$MODEL_KEY_ENV" ]]; then
  load_credential model_api_key "$MODEL_KEY_ENV"
fi

exec "$ROLE_DIR/.scripts/heartbeat.sh"
