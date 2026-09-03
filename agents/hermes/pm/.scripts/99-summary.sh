#!/usr/bin/env bash
# Print a reconciliation summary derived from durable role/service state.
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

GW_UNIT="hermes-${AGENT_ID}-gateway.service"
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
if [[ "$HB_STATE" == "active" || "$GW_STATE" =~ ^(active|deferred)$ ]]; then
  if systemd_user_available; then
    if [[ "$HB_STATE" == "active" ]]; then
      hb_live="$(systemd_timer_health_snapshot "$HB_TIMER" "hermes-${AGENT_ID}-heartbeat.service")"
      [[ "$hb_live" == ok\|* ]] || HB_STATE="error (stale active claim)"
    fi
    if [[ "$GW_STATE" == "active" ]]; then
      gw_live="$(systemd_service_health_snapshot "$GW_UNIT" running)"
      [[ "$gw_live" == ok\|* ]] || GW_STATE="error (stale active claim)"
    elif [[ "$GW_STATE" == "deferred" ]]; then
      gw_live="$(systemd_gateway_deferred_snapshot "$GW_UNIT")"
      [[ "$gw_live" == "ok|deferred" ]] || GW_STATE="error (stale deferred claim)"
    fi
  else
    [[ "$HB_STATE" != "active" ]] || HB_STATE="unverified (user manager unavailable)"
    [[ "$GW_STATE" != "active" && "$GW_STATE" != "deferred" ]] \
      || GW_STATE="unverified (user manager unavailable)"
  fi
fi

case "$HB_STATE:$GW_STATE" in
  active:active) MODE="OPERATIONAL" ;;
  active:deferred) MODE="OPERATIONAL_WITH_GATEWAY_DEFERRED" ;;
  installed:installed|installed:deferred) MODE="INSTALLED_NOT_ACTIVE" ;;
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
│  Slack credential through the provisioner; do not start $GW_UNIT manually.
EOF
elif [[ "$GW_STATE" == "active" ]]; then
  printf '│  Gateway log:    journalctl --user -fu %s\n' "$GW_UNIT" >&2
fi

cat >&2 <<'EOF'
│
╰────────────────────────────────────────────────────────────────────────╯

EOF
mark_done 99-summary
