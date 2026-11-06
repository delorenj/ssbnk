#!/usr/bin/env bash
# Print a reconciliation summary derived from durable role/service state.
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

GW_UNIT="$HOST_GATEWAY_UNIT"
HB_TIMER="hermes-${AGENT_ID}-heartbeat.timer"
GW_STATE="$(yaml_get service_state.gateway)"
HB_STATE="$(yaml_get service_state.heartbeat)"
TELEGRAM_STATE="$(yaml_get telegram.provisioning_status)"
SLACK_STATE="$(yaml_get slack.provisioning_status)"
RECONCILE_STATE="$(yaml_get reconcile.enabled)"
RECONCILE_OPT_OUT="$(yaml_get reconcile.explicit_opt_out)"
BOARD_ID="$(yaml_get ticket_provider.board_id)"

# Reconcile durable claims with live unit truth at presentation time.  A stale
# role.yaml must never turn an exited launcher or failed heartbeat into an
# operational summary.
if [[ "$GW_STATE" =~ ^(active|deferred)$ && "$(host_os)" == "Darwin" ]]; then
  # launchd: one multiplexed gateway for the host, not a per-agent unit.
  GW_UNIT="ai.hermes.gateway (launchd, multiplexed)"
  if [[ "$GW_STATE" == "active" ]]; then
    [[ "$(launchd_gateway_snapshot)" == "ok|supervised" ]] || GW_STATE="error (stale active claim)"
  fi
elif [[ "$GW_STATE" =~ ^(active|deferred)$ ]]; then
  # systemd: also one multiplexed host gateway, never a per-agent unit.
  if [[ "$GW_STATE" == "active" ]]; then
    gw_live="$(host_gateway_probe "${PROFILE_NAME:-$AGENT_ID}" 0)"
    [[ "$gw_live" == ok\|serving\|* ]] || GW_STATE="error (stale active claim)"
  fi
fi

# The per-agent heartbeat is retired, so the gateway alone decides whether this
# agent is operational. An agent with a healthy gateway can receive a Bloodbank
# command; there is nothing else for a timer to prove.
case "$GW_STATE" in
  active) MODE="OPERATIONAL" ;;
  deferred) MODE="OPERATIONAL_WITH_GATEWAY_DEFERRED" ;;
  installed) MODE="INSTALLED_NOT_ACTIVE" ;;
  *) MODE="INCOMPLETE" ;;
esac

cat >&2 <<EOF

╭─ Hermes deployment: $AGENT_ID ───────────────────────────────────────╮
│
│  Mode:           $MODE
│  Gateway:        $GW_STATE  ($GW_UNIT)
│  Heartbeat:      $HB_STATE  ($HB_TIMER)
│  Reconciliation: $RECONCILE_STATE  (explicit opt-out: ${RECONCILE_OPT_OUT:-false})
│  Telegram:       $TELEGRAM_STATE
│  Slack:          $SLACK_STATE
│  Board:          ${BOARD_ID:-deferred}
│  Runtime:        $ROLE_DIR/runtime   (pure-local, ignored)
│  Hermes bin:     $HERMES_BIN
│  Fleet env:      $FLEET_ENV
│
EOF

if [[ "$TELEGRAM_STATE" == "verified" ]]; then
  printf '│  Talk:           @%s  (Telegram DM)\n' "$BOT_HANDLE" >&2
fi
if [[ "$SLACK_STATE" == "verified" ]]; then
  printf '│  Slack bot:      %s\n' "$(yaml_get slack.bot_username)" >&2
fi
printf '│  Shell:          %s/hermes chat "status"\n' "$ROLE_DIR" >&2

if [[ "$GW_STATE" == "deferred" ]]; then
  cat >&2 <<EOF
│
│  Gateway activation is deferred. Store and verify a dedicated Telegram or
│  Slack credential through the provisioner. No per-agent gateway is ever
│  started: the host gateway ($GW_UNIT) serves every profile.
EOF
elif [[ "$GW_STATE" == "active" ]]; then
  if [[ "$(host_os)" == "Darwin" ]]; then
    printf '│  Gateway log:    tail -f %s/logs/gateway.log\n' "${HERMES_FLEET_HOME:-$HOME/.hermes}" >&2
  else
    printf '│  Gateway log:    journalctl --user -fu %s\n' "$GW_UNIT" >&2
  fi
fi

cat >&2 <<'EOF'
│
╰────────────────────────────────────────────────────────────────────────╯

EOF
mark_done 99-summary
