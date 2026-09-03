#!/usr/bin/env bash
# Install systemd --user units: profile gateway and fused heartbeat timer
# (board-reconciliation sentinel pass + gated runtime checkpoint, one tick).
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

if [[ "$ROLE" == "reporter" ]]; then
  log "[70] reporter systemd — gateway/consumer intentionally not installed"
  log "    use the reporter runtime's explicit install command after credential and policy preflight"
  yaml_upsert_block_value service_state gateway not-applicable
  yaml_upsert_block_value service_state heartbeat not-applicable
  mark_done 70-systemd
  exit 0
fi

# Resolve expected paths without creating directories or querying the user
# manager.  A legacy skip-created marker is complete only when all units exist.
RUNTIME="$ROLE_DIR/runtime"
FLEET_HOME="${HERMES_FLEET_HOME:-$HOME/.hermes}"
PROFILE_HOME="$FLEET_HOME/profiles/${PROFILE_NAME:-$AGENT_ID}"
REPO_ROOT="$(project_repo_path)" || REPO_ROOT="$ROLE_DIR"

SYS_DIR="$HOME/.config/systemd/user"
GW_UNIT="hermes-${AGENT_ID}-gateway.service"
HB_SVC="hermes-${AGENT_ID}-heartbeat.service"
HB_TIMER="hermes-${AGENT_ID}-heartbeat.timer"

# Local-only provisioning must not inspect or mutate the host user manager.
# Honor the explicit skip before creating unit directories or querying legacy
# unit state; cleanup remains fail-closed whenever systemd management is active.
if [[ "${SKIP_SYSTEMD:-0}" == "1" ]]; then
  if already_done 70-systemd \
     && [[ -f "$SYS_DIR/$GW_UNIT" && -f "$SYS_DIR/$HB_SVC" && -f "$SYS_DIR/$HB_TIMER" ]]; then
    log "[70] systemd — SKIPPED; existing complete unit set preserved"
  else
    clear_done 70-systemd
    log "[70] systemd — DEFERRED (completion marker cleared)"
  fi
  exit 0
fi

# Legacy manifests defaulted reconciliation off and had no way to distinguish
# that default from an operator decision. The new explicit_opt_out sentinel is
# authoritative: migrate unmarked roles to the operational PM default, while a
# rendered/operator-recorded opt-out remains checkpoint-only on every rerun.
if [[ "$(yaml_get reconcile.explicit_opt_out)" == "true" ]]; then
  yaml_upsert_block_value reconcile enabled false bool
  log "    PM reconciliation explicit opt-out preserved"
else
  yaml_upsert_block_value reconcile enabled true bool
  yaml_upsert_block_value reconcile explicit_opt_out false bool
  log "    PM reconciliation enabled (operational default)"
fi

# Render every caller-controlled systemd scalar through the same data-only
# serializer used by fleet backfill. This validation happens before mkdir,
# systemctl, or unit writes, so CR/LF/NUL cannot create a second directive and
# spaces/quotes/backslashes/specifier bytes remain exact.
PYTHON_BIN="$(builtin type -P python3)" || die "python3 is unavailable for systemd unit serialization"
systemd_value() {
  "$PYTHON_BIN" -I "$FLEET_ENV_PARSER" --systemd-value "$1" \
    || die "systemd value validation failed"
}
systemd_scalar() {
  "$PYTHON_BIN" -I "$FLEET_ENV_PARSER" --systemd-scalar "$1" \
    || die "systemd scalar validation failed"
}
systemd_environment() {
  "$PYTHON_BIN" -I "$FLEET_ENV_PARSER" --systemd-environment "$1" "$2" \
    || die "systemd environment validation failed"
}
systemd_exec_value() {
  "$PYTHON_BIN" -I "$FLEET_ENV_PARSER" --systemd-exec-value "$1" \
    || die "systemd ExecStart value validation failed"
}
GW_DESCRIPTION="$(systemd_scalar "Hermes Gateway — $DISPLAY_NAME")"
HB_DESCRIPTION="$(systemd_scalar "Hermes Heartbeat (reconcile + checkpoint) — $DISPLAY_NAME")"
TIMER_DESCRIPTION="$(systemd_scalar "Heartbeat (reconcile + checkpoint) for $AGENT_ID")"
ENV_HERMES_HOME="$(systemd_environment HERMES_HOME "$PROFILE_HOME")"
ENV_HERMES_BIN="$(systemd_environment HERMES_BIN "$HERMES_BIN")"
ENV_CODEX_HOME="$(systemd_environment CODEX_HOME "$CODEX_HOME")"
ENV_TERMINAL_CWD="$(systemd_environment TERMINAL_CWD "$REPO_ROOT")"
WORKING_DIRECTORY="$(systemd_scalar "$REPO_ROOT")"
RUNTIME_ENV_FILE="$(systemd_scalar "-$RUNTIME/.env")"
GW_LOG_OUTPUT="$(systemd_scalar "append:$RUNTIME/logs/gateway.systemd.log")"
HB_LOG_OUTPUT="$(systemd_scalar "append:$RUNTIME/logs/heartbeat.log")"
GW_EXEC_START="$(systemd_exec_value "$ROLE_DIR/.scripts/credential-launch.sh")"
HB_EXEC_START="$GW_EXEC_START"

# A model credential may be supplied through systemd's encrypted credential
# store. Chat-channel values are never materialized here: Hermes resolves their
# profile-scoped op:// references natively at process startup.
CREDENTIAL_DIR="${HERMES_SYSTEMD_CREDENTIAL_DIR:-$HOME/.config/hermes-agent/credentials}"
MODEL_CREDENTIAL="$CREDENTIAL_DIR/${AGENT_ID}-model-api-key.cred"
GW_CREDENTIAL_LINES=""
HB_CREDENTIAL_LINES=""
if [[ -f "$MODEL_CREDENTIAL" ]]; then
  [[ -n "$(yaml_get model.key_env)" ]] \
    || die "encrypted model credential exists but model.key_env is blank in role.yaml"
  command -v systemd-creds >/dev/null 2>&1 \
    || die "encrypted model credential exists but systemd-creds is unavailable"
  GW_CREDENTIAL_LINES="${GW_CREDENTIAL_LINES}${GW_CREDENTIAL_LINES:+$'\n'}LoadCredentialEncrypted=$(systemd_value "model_api_key:$MODEL_CREDENTIAL")"
  HB_CREDENTIAL_LINES="LoadCredentialEncrypted=$(systemd_value "model_api_key:$MODEL_CREDENTIAL")"
fi

# A gateway is eligible only when at least one channel identity is verified AND
# both the named-profile mapping and the referenced 1Password value resolve.
# Role metadata alone is not sufficient: a stale done marker must never revive
# a credential-less crash loop.
gateway_ready=0
gateway_validation_unavailable=0
if [[ "$(yaml_get telegram.provisioning_status)" == "verified" ]] \
   && profile_onepassword_ref_exists "$PROFILE_HOME" TELEGRAM_BOT_TOKEN; then
  telegram_reference_rc=0
  profile_onepassword_ref_validate "$PROFILE_HOME" TELEGRAM_BOT_TOKEN \
    || telegram_reference_rc=$?
  if [[ $telegram_reference_rc -eq 0 ]]; then
    gateway_ready=1
  elif [[ $telegram_reference_rc -eq 75 ]]; then
    gateway_validation_unavailable=1
  fi
fi
if [[ "$(yaml_get slack.provisioning_status)" == "verified" ]] \
   && profile_onepassword_ref_exists "$PROFILE_HOME" SLACK_BOT_TOKEN \
   && profile_onepassword_ref_exists "$PROFILE_HOME" SLACK_APP_TOKEN; then
  slack_bot_reference_rc=0
  slack_app_reference_rc=0
  profile_onepassword_ref_validate "$PROFILE_HOME" SLACK_BOT_TOKEN \
    || slack_bot_reference_rc=$?
  profile_onepassword_ref_validate "$PROFILE_HOME" SLACK_APP_TOKEN \
    || slack_app_reference_rc=$?
  if [[ $slack_bot_reference_rc -eq 0 && $slack_app_reference_rc -eq 0 ]]; then
    gateway_ready=1
  elif [[ $slack_bot_reference_rc -eq 75 || $slack_app_reference_rc -eq 75 ]]; then
    gateway_validation_unavailable=1
  fi
fi
if [[ $gateway_ready -eq 0 && $gateway_validation_unavailable -eq 1 ]]; then
  die "channel 1Password validation is temporarily unavailable; preserving existing gateway state for retry"
fi

# Singleton-runtime contract: units set HERMES_HOME to the agent's NAMED PROFILE
# dir, never the raw runtime path — Hermes derives profile identity and shared
# fleet auth from the unresolved HERMES_HOME. $RUNTIME stays correct for
# EnvironmentFile and logs: those are the repo-owned side the profile links to.
mkdir -p "$SYS_DIR" "$RUNTIME/logs"

# Upgrade remediation must run before honoring a legacy done marker. Older
# templates installed one per-profile Bloodbank consumer; leaving even one
# enabled races the fleet-shared durable gateway and can duplicate execution.
LEGACY_CONSUMER_UNIT="hermes-${AGENT_ID}-consumer.service"
LEGACY_CONSUMER_PATH="$SYS_DIR/$LEGACY_CONSUMER_UNIT"
legacy_consumer_present=0
[[ -e "$LEGACY_CONSUMER_PATH" || -L "$LEGACY_CONSUMER_PATH" ]] \
  && legacy_consumer_present=1
if command -v systemctl >/dev/null 2>&1; then
  legacy_active_result="$(systemctl_user_unit_state is-active "$LEGACY_CONSUMER_UNIT")"
  legacy_enabled_result="$(systemctl_user_unit_state is-enabled "$LEGACY_CONSUMER_UNIT")"
  [[ "$legacy_active_result" != error\|* ]] \
    || die "cannot safely query legacy consumer activity; preserving unit: ${legacy_active_result#*|}"
  [[ "$legacy_enabled_result" != error\|* ]] \
    || die "cannot safely query legacy consumer enablement; preserving unit: ${legacy_enabled_result#*|}"
  legacy_active_state="${legacy_active_result#*|}"
  legacy_enabled_state="${legacy_enabled_result#*|}"
  [[ "$legacy_active_state" == "not-found" && "$legacy_enabled_state" == "not-found" ]] \
    || legacy_consumer_present=1
elif [[ $legacy_consumer_present -eq 1 ]]; then
  die "systemctl is unavailable; cannot safely retire legacy consumer: $LEGACY_CONSUMER_UNIT"
fi
if [[ $legacy_consumer_present -eq 1 ]]; then
  systemctl --user disable --now "$LEGACY_CONSUMER_UNIT" >/dev/null 2>&1 \
    || die "legacy consumer disable failed; preserving unit: $LEGACY_CONSUMER_UNIT"
  legacy_active_result="$(systemctl_user_unit_state is-active "$LEGACY_CONSUMER_UNIT")"
  legacy_enabled_result="$(systemctl_user_unit_state is-enabled "$LEGACY_CONSUMER_UNIT")"
  [[ "$legacy_active_result" == "ok|inactive" ]] \
    || die "legacy consumer is not proven inactive; preserving unit: ${legacy_active_result#*|}"
  [[ "$legacy_enabled_result" == "ok|disabled" ]] \
    || die "legacy consumer is not proven disabled; preserving unit: ${legacy_enabled_result#*|}"
  rm -f -- "$LEGACY_CONSUMER_PATH"
  if systemd_user_available; then
    systemctl --user daemon-reload >/dev/null 2>&1 \
      || warn "    systemd daemon-reload failed after legacy consumer retirement"
  fi
  log "    retired legacy per-profile Bloodbank consumer: $LEGACY_CONSUMER_UNIT"
fi

if already_done 70-systemd; then
  if [[ -f "$SYS_DIR/$GW_UNIT" && -f "$SYS_DIR/$HB_SVC" && -f "$SYS_DIR/$HB_TIMER" ]]; then
    log "[70] systemd already installed — reconciling unit definitions"
  else
    clear_done 70-systemd
    log "    stale/incomplete systemd marker cleared — reconciling required units"
  fi
fi

# The heartbeat runner (board-reconciliation sentinel pass + gated checkpoint)
# and the checkpoint helper both render into the role dir; just ensure they are
# executable. heartbeat.sh calls checkpoint.sh internally.
HEARTBEAT_BIN="$ROLE_DIR/.scripts/heartbeat.sh"
CREDENTIAL_LAUNCHER="$ROLE_DIR/.scripts/credential-launch.sh"
chmod +x "$HEARTBEAT_BIN" "$CREDENTIAL_LAUNCHER" "$ROLE_DIR/.scripts/checkpoint.sh" 2>/dev/null || true

[[ -d "$PROFILE_HOME" && ! -L "$PROFILE_HOME" ]] \
  || die "named profile is not a real directory; run: pj migrate hermes.runtime-singleton '$REPO_ROOT'"

# Gateway unit
#
# StartLimit* belongs in [Unit], not [Service] — systemd only still parses it
# under [Service] for backwards compatibility. Without it, Restart=on-failure
# retries forever and a gateway that can never start (bad token, bad config)
# sits in `activating` indefinitely instead of settling into `failed`, so
# `systemctl --user --failed` never lists it and neither the sentinel nor a
# human ever sees the crashloop. That is exactly how the fleet accumulated
# 10,427 invisible restarts. 5 tries in 5 minutes, then stop and report failed.
cat > "$SYS_DIR/$GW_UNIT" <<UNIT
[Unit]
Description=$GW_DESCRIPTION
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
$ENV_HERMES_HOME
$ENV_HERMES_BIN
$ENV_CODEX_HOME
$ENV_TERMINAL_CWD
EnvironmentFile=$RUNTIME_ENV_FILE
$GW_CREDENTIAL_LINES
ExecStart=$GW_EXEC_START gateway
Restart=on-failure
RestartSec=10
StandardOutput=$GW_LOG_OUTPUT
StandardError=$GW_LOG_OUTPUT

[Install]
WantedBy=default.target
UNIT

# Fused heartbeat: board-reconciliation sentinel pass + gated runtime checkpoint.
# Frequent ticks (1 min); heartbeat.sh's own cooldown/lock logic rate-limits the
# full Hermes pass, and the checkpoint is gated to ~hourly inside the runner.
# The per-agent EnvironmentFiles load ticket-provider creds for the sentinel pass.
cat > "$SYS_DIR/$HB_SVC" <<UNIT
[Unit]
Description=$HB_DESCRIPTION
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$WORKING_DIRECTORY
$ENV_HERMES_HOME
$ENV_HERMES_BIN
$ENV_CODEX_HOME
$ENV_TERMINAL_CWD
EnvironmentFile=-%h/.config/hermes-agent/env
EnvironmentFile=-%h/.hermes/env
EnvironmentFile=-%h/.hermes/hermes-agent.env
EnvironmentFile=-%h/.hermes/${AGENT_ID}.env
EnvironmentFile=$RUNTIME_ENV_FILE
$HB_CREDENTIAL_LINES
ExecStart=$HB_EXEC_START heartbeat
TimeoutStartSec=45min
StandardOutput=$HB_LOG_OUTPUT
StandardError=$HB_LOG_OUTPUT
UNIT
cat > "$SYS_DIR/$HB_TIMER" <<UNIT
[Unit]
Description=$TIMER_DESCRIPTION

[Timer]
OnBootSec=1min
OnUnitInactiveSec=1min
Unit=$HB_SVC
Persistent=true

[Install]
WantedBy=timers.target
UNIT

if systemd_user_available; then
  systemctl --user daemon-reload
  if systemctl --user enable --now "$HB_TIMER" >/dev/null 2>&1; then
    # The timer's first scheduled tick can be a minute away. Run the oneshot
    # once now so deployment proves the heartbeat command itself completed;
    # timer activity alone is not an operational postcondition.
    if ! systemctl --user start "$HB_SVC" >/dev/null 2>&1; then
      systemctl --user disable --now "$HB_TIMER" >/dev/null 2>&1 || true
      yaml_upsert_block_value service_state heartbeat error
      clear_done 70-systemd
      die "required heartbeat oneshot failed its deployment probe: $HB_SVC"
    fi
    if hb_health="$(systemd_wait_for_stable_health \
        systemd_timer_health_snapshot "$HB_TIMER" "$HB_SVC")"; then
      yaml_upsert_block_value service_state heartbeat active
      log "    heartbeat enabled + active with healthy latest result: $HB_TIMER"
    else
      systemctl --user disable --now "$HB_TIMER" >/dev/null 2>&1 || true
      yaml_upsert_block_value service_state heartbeat error
      clear_done 70-systemd
      die "heartbeat did not stabilize healthy: $hb_health"
    fi
  else
    yaml_upsert_block_value service_state heartbeat error
    clear_done 70-systemd
    die "failed to enable/start required heartbeat timer: $HB_TIMER"
  fi

  if [[ $gateway_ready -eq 1 ]]; then
    if systemctl --user enable --now "$GW_UNIT" >/dev/null 2>&1; then
      if gw_health="$(systemd_wait_for_stable_health \
          systemd_service_health_snapshot "$GW_UNIT" running)"; then
        yaml_upsert_block_value service_state gateway active
        log "    credentialed gateway enabled + active and stabilized: $GW_UNIT"
      else
        systemctl --user disable --now "$GW_UNIT" >/dev/null 2>&1 || true
        systemctl --user reset-failed "$GW_UNIT" >/dev/null 2>&1 || true
        yaml_upsert_block_value service_state gateway error
        clear_done 70-systemd
        die "credentialed gateway did not stabilize healthy: $gw_health"
      fi
    else
      yaml_upsert_block_value service_state gateway error
      clear_done 70-systemd
      die "failed to enable/start credentialed gateway: $GW_UNIT"
    fi
  else
    systemctl --user disable --now "$GW_UNIT" >/dev/null 2>&1 \
      || die "could not enforce deferred gateway disablement: $GW_UNIT"
    systemctl --user reset-failed "$GW_UNIT" >/dev/null 2>&1 || true
    gw_deferred_health="$(systemd_gateway_deferred_snapshot "$GW_UNIT")"
    if [[ "$gw_deferred_health" == "ok|deferred" ]]; then
      yaml_upsert_block_value service_state gateway deferred
      log "    gateway deferred: disabled + inactive until a channel credential is verified"
    else
      yaml_upsert_block_value service_state gateway error
      clear_done 70-systemd
      die "gateway deferral was not proven disabled + inactive ($gw_deferred_health)"
    fi
  fi
else
  warn "    systemd --user not available; units installed at $SYS_DIR but not enabled"
  yaml_upsert_block_value service_state heartbeat installed
  if [[ $gateway_ready -eq 1 ]]; then
    yaml_upsert_block_value service_state gateway installed
  else
    yaml_upsert_block_value service_state gateway deferred
  fi
fi

mark_done 70-systemd
