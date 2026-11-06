#!/usr/bin/env bash
# Make the host gateway agree with this agent's service_state.gateway. An agent has
# NO systemd unit of its own: one multiplexed gateway per host (hermes-gateway.service
# on Linux, ai.hermes.gateway on macOS; `hermes gateway run`, HERMES_HOME=<fleet root>,
# gateway.multiplex_profiles) serves every profile under <fleet root>/profiles. This
# step never writes or enables a per-agent gateway unit. It only
#   - retires what older templates left behind: the per-agent gateway unit
#     (hermes-<agent>-gateway.service), the per-agent heartbeat timer/service, and the
#     per-profile Bloodbank consumer;
#   - when a channel credential is verified, makes sure the host gateway is managed
#     by hermes-gateway.service (installed through the hermes CLI only if missing,
#     never restarted) and that it serves this profile, rescanning profiles/ through
#     its control socket (gateway/host_attach.py request_serve_profile).
# A retired per-agent unit whose process IS the live host gateway is disabled and
# deleted but not stopped (stopping it would take the whole fleet down); the operator
# is told to hand the gateway over with `hermes-gateway-restart`.
# On macOS (Darwin) the same contract runs through launchd: see the branch below.
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
# manager.
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
  if already_done 70-systemd; then
    log "[70] systemd — SKIPPED; existing completion marker preserved"
  else
    clear_done 70-systemd
    log "[70] systemd — DEFERRED (completion marker cleared)"
  fi
  exit 0
fi

# Legacy manifests defaulted reconciliation off and had no way to distinguish
# that default from an operator decision. The new explicit_opt_out sentinel is
# authoritative: migrate unmarked roles to the operational PM default, while a
# rendered/operator-recorded opt-out stays opted out on every rerun.
if [[ "$(yaml_get reconcile.explicit_opt_out)" == "true" ]]; then
  yaml_upsert_block_value reconcile enabled false bool
  log "    PM reconciliation explicit opt-out preserved"
else
  yaml_upsert_block_value reconcile enabled true bool
  yaml_upsert_block_value reconcile explicit_opt_out false bool
  log "    PM reconciliation enabled (operational default)"
fi

# macOS: launchd, one multiplexed gateway, no per-agent units.
#
# The live fleet standard is a single gateway per host serving every profile
# (gateway.multiplex_profiles), so there is nothing per-agent to install: no
# plist, no unit, no heartbeat. This role only declares whether the gateway
# should be live (service_state.gateway), and this step makes the host agree
# with that declaration through the fork's own CLI. Anything else is recorded
# as deferred. A gateway that cannot be shown healthy is never left running by
# this step.
if [[ "$(host_os)" == "Darwin" ]]; then
  yaml_upsert_block_value service_state heartbeat retired
  DESIRED_GATEWAY="$(yaml_get service_state.gateway)"
  legacy_plist="$HOME/Library/LaunchAgents/ai.hermes.gateway-${PROFILE_NAME:-$AGENT_ID}.plist"
  [[ ! -e "$legacy_plist" ]] \
    || warn "    per-profile gateway plist present (superseded by the multiplexed gateway): $legacy_plist; retire it with: hermes gateway migrate"
  if [[ "$DESIRED_GATEWAY" != "active" ]]; then
    yaml_upsert_block_value service_state gateway deferred
    log "[70] launchd — gateway deferred (service_state.gateway is '${DESIRED_GATEWAY:-unset}', not active); nothing installed"
    mark_done 70-systemd
    exit 0
  fi
  if [[ ! -x "$HERMES_BIN" ]]; then
    yaml_upsert_block_value service_state gateway deferred
    log "[70] launchd — gateway deferred: HERMES_BIN is not executable ($HERMES_BIN)"
    clear_done 70-systemd
    exit 0
  fi
  before="$(launchd_gateway_snapshot)"
  if [[ "$before" != "ok|supervised" ]]; then
    hermes_gateway_cli install --if-missing >/dev/null 2>&1 \
      || { yaml_upsert_block_value service_state gateway error; clear_done 70-systemd; die "hermes gateway install failed on launchd"; }
    # install --if-missing leaves an installed-but-unloaded job alone; start loads it.
    hermes_gateway_cli start >/dev/null 2>&1 || true
  fi
  if gw_health="$(launchd_wait_for_supervised)"; then
    yaml_upsert_block_value service_state gateway active
    log "[70] launchd — multiplexed gateway ai.hermes.gateway supervised and active"
    mark_done 70-systemd
    exit 0
  fi
  # Unhealthy. Only undo what this run created: a gateway that already had a
  # definition (loaded or not) may be serving other profiles, so it is reported,
  # never stopped.
  if [[ "$before" == "ok|not-installed" ]]; then
    hermes_gateway_cli stop >/dev/null 2>&1 || true
  fi
  yaml_upsert_block_value service_state gateway error
  clear_done 70-systemd
  die "launchd gateway did not become healthy (${gw_health#*|}); not leaving a crash loop running"
fi

PROFILE_ID="${PROFILE_NAME:-$AGENT_ID}"
GW_PATH="$SYS_DIR/$GW_UNIT"
GW_DROPIN="$GW_PATH.d"

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

# $RUNTIME/logs is repo-owned scaffolding the profile links to; keep it present.
mkdir -p "$RUNTIME/logs"

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

[[ -d "$PROFILE_HOME" && ! -L "$PROFILE_HOME" ]] \
  || die "named profile is not a real directory; run: flume remediate hermes.runtime-singleton '$REPO_ROOT'"

if already_done 70-systemd; then
  log "[70] systemd already reconciled — re-checking the host gateway"
fi

# The manual wrapper and credential launcher stay executable (heartbeat.sh is a
# retired no-op kept only for old installs).
chmod +x "$ROLE_DIR/.scripts/heartbeat.sh" "$ROLE_DIR/.scripts/credential-launch.sh" 2>/dev/null || true

# Per-agent gateway unit: RETIRED.
#
# Older templates wrote hermes-<agent>-gateway.service (ExecStart =
# credential-launch.sh gateway, HERMES_HOME = the profile) and enabled it whenever a
# channel credential was verified. Under the multiplexed host gateway that is
# destructive: the host already serves the profile, so the unit either refuses
# ("already serves profile ...", a restart loop) or, if it starts first, becomes the
# HOST OWNER serving every profile while the canonical hermes-gateway.service loops
# against it (2026-11-02: hiring tolt-pm did exactly that). So provisioning removes the
# unit, with the same discipline as the legacy consumer above: disable it, prove the
# state, delete the file, daemon-reload. The one exception is a unit whose process is
# the live host gateway (or cannot be proven not to be): it is disabled and its file
# removed, but never stopped, because stopping it would kill every profile's gateway.
HANDOVER_PENDING=0
HANDOVER_PID=""
retire_agent_gateway_unit() {
  local present=0 active_result enabled_result active_state enabled_state
  local verdict host_pid="" keep_running=0 contains_rc=0 reason=""
  [[ -e "$GW_PATH" || -L "$GW_PATH" || -e "$GW_DROPIN" ]] && present=1
  if ! systemd_user_available; then
    if [[ $present -eq 1 ]]; then
      warn "    systemd --user not available; removing the retired per-agent gateway unit files without a manager: $GW_UNIT"
      rm -f -- "$GW_PATH"
      rm -rf -- "$GW_DROPIN"
    fi
    return 0
  fi
  active_result="$(systemctl_user_unit_state is-active "$GW_UNIT")"
  enabled_result="$(systemctl_user_unit_state is-enabled "$GW_UNIT")"
  [[ "$active_result" != error\|* ]] \
    || die "cannot safely query per-agent gateway activity; preserving unit: ${active_result#*|}"
  [[ "$enabled_result" != error\|* ]] \
    || die "cannot safely query per-agent gateway enablement; preserving unit: ${enabled_result#*|}"
  active_state="${active_result#*|}"
  enabled_state="${enabled_result#*|}"
  [[ "$active_state" == "not-found" && "$enabled_state" == "not-found" ]] || present=1
  [[ $present -eq 1 ]] || return 0

  if [[ "$active_state" =~ ^(active|activating|reloading|deactivating)$ ]]; then
    verdict="$(host_gateway_probe "$PROFILE_ID" 0)"
    case "$verdict" in
      ok\|no-host)
        ;;                       # nothing is the host: this unit is just a stray gateway
      ok\|*\|*)
        host_pid="${verdict##*|}"
        contains_rc=0
        systemd_unit_contains_pid "$GW_UNIT" "$host_pid" || contains_rc=$?
        if [[ $contains_rc -eq 0 ]]; then
          keep_running=1
          reason="its process (PID $host_pid) is the live host gateway"
        elif [[ $contains_rc -eq 2 ]]; then
          keep_running=1
          reason="it could not be proven not to be the live host gateway (PID $host_pid)"
        fi
        ;;
      *)
        keep_running=1
        reason="the host gateway could not be probed (${verdict#*|})"
        ;;
    esac
  fi

  if [[ $keep_running -eq 1 ]]; then
    # NEVER --now: this process serves the fleet.
    if ! systemctl --user disable "$GW_UNIT" >/dev/null 2>&1 && [[ "$enabled_state" != "not-found" ]]; then
      die "per-agent gateway disable failed; preserving unit: $GW_UNIT"
    fi
  else
    if ! systemctl --user disable --now "$GW_UNIT" >/dev/null 2>&1 && [[ "$enabled_state" != "not-found" ]]; then
      die "per-agent gateway disable failed; preserving unit: $GW_UNIT"
    fi
    systemctl --user reset-failed "$GW_UNIT" >/dev/null 2>&1 || true
    active_result="$(systemctl_user_unit_state is-active "$GW_UNIT")"
    [[ "$active_result" =~ ^ok\|(inactive|failed|not-found)$ ]] \
      || die "per-agent gateway is not proven inactive; preserving unit: ${active_result#*|}"
  fi
  enabled_result="$(systemctl_user_unit_state is-enabled "$GW_UNIT")"
  [[ "$enabled_result" =~ ^ok\|(disabled|masked|masked-runtime|not-found)$ ]] \
    || die "per-agent gateway is not proven disabled; preserving unit: ${enabled_result#*|}"
  rm -f -- "$GW_PATH"
  rm -rf -- "$GW_DROPIN"
  systemctl --user daemon-reload >/dev/null 2>&1 \
    || warn "    systemd daemon-reload failed after per-agent gateway retirement"
  log "    retired per-agent gateway unit: $GW_UNIT"

  if [[ $keep_running -eq 1 ]]; then
    HANDOVER_PENDING=1
    HANDOVER_PID="$host_pid"
    warn "    ################################################################"
    warn "    LOUD WARNING: $GW_UNIT was disabled and its file deleted, but it was"
    warn "    NOT stopped: $reason."
    warn "    Stopping it would kill the gateway for every profile on this host."
    warn "    It keeps running outside any enabled unit until you hand the gateway"
    warn "    over to the canonical $HOST_GATEWAY_UNIT, e.g.:"
    warn "        hermes-gateway-restart --reason \"hand the host gateway to $HOST_GATEWAY_UNIT (retired $GW_UNIT)\""
    warn "    (the retired unit's process must exit first so $HOST_GATEWAY_UNIT can take the host)"
    warn "    ################################################################"
  fi
}
retire_agent_gateway_unit

# Heartbeat: RETIRED.
#
# Every agent used to get a 1-minute oneshot timer here. It was retired on
# 2026-09-17 because it did nothing. The board-reconciliation pass behind it is
# gated on role.yaml's `reconcile.enabled`, which was true in exactly one repo
# fleet-wide (and that timer was disabled), so every tick fell through to
# `maybe_checkpoint` — a no-op helper that has since been deleted along with
# runtime is a nested Git repo, which none are. The result was ~20,000 no-op
# invocations a day writing one identical log line; 33god-pm's heartbeat.log
# reached 3.8 MB of it.
#
# The three jobs a heartbeat appeared to do are owned elsewhere now:
#   liveness    -> the host gateway unit, hermes-gateway.service (Restart=always)
#   scheduling  -> Candybar, the single clock (retired 2026-10-11: no heartbeat
#                  timer, no per-agent timer, no private poll loop; recurring work
#                  is a Candybar manifest). Bloodbank carries the resulting
#                  command events (krebs pull-subscribes
#                  bloodbank.cmd.lifecycle.task.invoke); it is not the clock.
#   persistence -> krebs attempts/leases, which park a stalled ticket in
#                  "Needs Attention" instead of ticking forever
#
# Provisioning now REMOVES any heartbeat units it finds, so re-running this
# script on an older install cleans up rather than resurrecting them.
if systemd_user_available; then
  if [[ -f "$SYS_DIR/$HB_TIMER" || -f "$SYS_DIR/$HB_SVC" ]]; then
    systemctl --user disable --now "$HB_TIMER" >/dev/null 2>&1 || true
    systemctl --user stop "$HB_SVC" >/dev/null 2>&1 || true
    rm -f "$SYS_DIR/$HB_TIMER" "$SYS_DIR/$HB_SVC"
    log "    heartbeat retired: removed $HB_TIMER and $HB_SVC"
  fi
  systemctl --user daemon-reload
fi
yaml_upsert_block_value service_state heartbeat retired


# Gateway: record what the HOST gateway does for this profile.
#
# service_state.gateway says whether the gateway should be live (a verified channel
# credential). The host gateway is shared, so there is nothing per-agent to install:
# ensure it is managed by $HOST_GATEWAY_UNIT, never restart it, and show that it serves
# this profile. Anything else is recorded as deferred or error, like the launchd branch.
if [[ $gateway_ready -ne 1 ]]; then
  yaml_upsert_block_value service_state gateway deferred
  log "[70] systemd — gateway deferred: no verified channel credential; no per-agent unit is ever installed"
  mark_done 70-systemd
  exit 0
fi

if [[ ! -x "$HERMES_BIN" ]]; then
  yaml_upsert_block_value service_state gateway deferred
  clear_done 70-systemd
  log "[70] systemd — gateway deferred: HERMES_BIN is not executable ($HERMES_BIN)"
  exit 0
fi

if ! systemd_user_available; then
  yaml_upsert_block_value service_state gateway deferred
  clear_done 70-systemd
  warn "    systemd --user not available; the host gateway ($HOST_GATEWAY_UNIT) was not checked"
  exit 0
fi

host_enabled="$(systemctl_user_unit_state is-enabled "$HOST_GATEWAY_UNIT")"
if [[ "$host_enabled" == error\|* ]]; then
  yaml_upsert_block_value service_state gateway error
  clear_done 70-systemd
  die "cannot query the host gateway unit $HOST_GATEWAY_UNIT: ${host_enabled#*|}"
fi
host_created=0
if [[ "$host_enabled" == "ok|not-found" ]]; then
  # Only when it is MISSING. An installed unit is never reinstalled or restarted here.
  hermes_gateway_cli install --if-missing >/dev/null 2>&1 \
    || { yaml_upsert_block_value service_state gateway error; clear_done 70-systemd; die "hermes gateway install failed ($HOST_GATEWAY_UNIT is missing)"; }
  host_created=1
fi
host_active="$(systemctl_user_unit_state is-active "$HOST_GATEWAY_UNIT")"
if [[ "$host_active" =~ ^ok\|(inactive|failed|not-found)$ ]] \
   && [[ "$(host_gateway_probe "$PROFILE_ID" 0)" == "ok|no-host" ]]; then
  # Installed but not running and nobody else holds the host: start it (no restart of
  # anything live).
  hermes_gateway_cli start >/dev/null 2>&1 || true
fi

if host_verdict="$(host_gateway_wait_serving "$PROFILE_ID")"; then
  host_pid="${host_verdict##*|}"
  managed_rc=0
  systemd_unit_contains_pid "$HOST_GATEWAY_UNIT" "$host_pid" || managed_rc=$?
  if [[ $managed_rc -ne 0 ]]; then
    HANDOVER_PENDING=1
    HANDOVER_PID="${HANDOVER_PID:-$host_pid}"
    warn "    the host gateway (PID $host_pid) serves '$PROFILE_ID' but is NOT managed by $HOST_GATEWAY_UNIT"
    warn "    hand it over with: hermes-gateway-restart --reason \"hand the host gateway to $HOST_GATEWAY_UNIT\""
  fi
  yaml_upsert_block_value service_state gateway active
  log "[70] systemd — host gateway serves profile '$PROFILE_ID' (PID $host_pid); no per-agent unit"
  mark_done 70-systemd
  exit 0
fi

# Not shown serving. Only undo what this run created: an existing host gateway may be
# serving every other profile, so it is reported, never stopped.
if [[ $host_created -eq 1 ]]; then
  hermes_gateway_cli stop >/dev/null 2>&1 || true
fi
yaml_upsert_block_value service_state gateway error
clear_done 70-systemd
die "host gateway does not serve profile '$PROFILE_ID' (${host_verdict#*|}); not starting a per-agent gateway"
