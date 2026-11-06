#!/usr/bin/env bash
# Unified agent heartbeat: continuous board-reconciliation sentinel pass +
# board-reconciliation pass.
#
# RETIRED AS A SCHEDULE (2026-09-17 the per-agent systemd timer; 2026-10-11 the
# single-clock rule): nothing installs a heartbeat timer, cron entry or loop for
# this script any more. Recurring work is a Candybar manifest (the one clock);
# this script only runs when something invokes it on purpose. Do not create a
# second clock for it. Historical behaviour follows. Only invokes Hermes for a full
# reconciliation pass when local state says no worker is active, the worker
# heartbeat is stale, or the last full run is outside the cooldown window. The
# full pass executes the role's sentinel.prompt.md, which reasons about tickets
# through the ticket-provider adapter (Linear | Plane | Trello) — never a
# hardcoded backend. After the sentinel decision (skip OR full), it
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # agents/hermes/<role>
RUNTIME="$ROLE_DIR/runtime"
# The role launcher is the ONE place that knows how to boot this desk: it resolves
# HERMES_HOME to the NAMED PROFILE (~/.hermes/profiles/<profile>), pins
# TERMINAL_CWD to the repo root and CODEX_HOME, loads the fleet env, unsets the
# chat bot tokens and refuses a missing or symlinked profile. Hermes is only ever
# run through it. (This script used to default HERMES_HOME to runtime/, which is
# not a Hermes home: a bare run died with "the gateway exited with status 1".)
ROLE_LAUNCHER="$ROLE_DIR/hermes"
PROMPT_FILE="$ROLE_DIR/.scripts/sentinel.prompt.md"
STATE_FILE="$RUNTIME/continuous-ticket-sentinel-state.json"
LOCK_FILE="$RUNTIME/continuous-ticket-sentinel.lock"
ROLE_YAML="$ROLE_DIR/role.yaml"
FLEET_ENV="${HERMES_FLEET_ENV:-$HOME/.hermes/fleet.env}"
FLEET_ENV_LIBRARY="$ROLE_DIR/.scripts/lib/fleet-env.sh"
FLEET_ENV_PARSER="$ROLE_DIR/.scripts/lib/parse-fleet-env.py"
LOG_FILE="$RUNTIME/logs/heartbeat.log"

if [[ ! -f "$FLEET_ENV_LIBRARY" || -L "$FLEET_ENV_LIBRARY" \
   || ! -f "$FLEET_ENV_PARSER" || -L "$FLEET_ENV_PARSER" ]]; then
  echo "heartbeat: trusted fleet environment loader unavailable" >&2
  exit 1
fi
# shellcheck source=lib/fleet-env.sh
builtin source "$FLEET_ENV_LIBRARY"
load_fleet_environment "$FLEET_ENV" "$FLEET_ENV_PARSER"

# The Hermes binary is the launcher's business too (HERMES_BIN > fleet.env >
# config.toml > the shared install); a caller's HERMES_BIN still wins there.

# Session source for the pass. `hermes chat --source` takes only a LOCAL creation
# surface (cli, tui, gui, acp, tool, oneshot): `cron` is a label the profile
# scheduler stamps on its own admitted runs (gateway/session_cron.py, hermes
# `cron run`), so a client-created session tagged `cron` is refused by the state
# store with "invalid_params". This pass is a deliberate machine-paced run, not a
# scheduler fire. It is a finite `chat -q` run, which Hermes stores as `oneshot`
# (gateway/session_policy.py SURFACES, hermes_cli/gateway_chat.py): hidden from
# the human session pickers, but still in the agent's own `session_search`, so the
# PM can later answer "what did your last board pass do?". (`tool` is for
# third-party integrations and is hidden from session_search too.)
SESSION_SOURCE="${SENTINEL_SESSION_SOURCE:-oneshot}"
case "$SESSION_SOURCE" in
  cli|tui|gui|acp|tool|oneshot) ;;
  *)
    printf 'heartbeat: SENTINEL_SESSION_SOURCE=%s is not a creatable Hermes session source (cli|tui|gui|acp|tool|oneshot; "cron" is scheduler-owned)\n' "$SESSION_SOURCE" >&2
    exit 2
    ;;
esac

ACTIVE_MAX_IDLE_SECONDS="${SENTINEL_ACTIVE_MAX_IDLE_SECONDS:-600}"
FULL_RUN_COOLDOWN_SECONDS="${SENTINEL_FULL_RUN_COOLDOWN_SECONDS:-300}"
BLOCKED_FULL_RUN_COOLDOWN_SECONDS="${SENTINEL_BLOCKED_FULL_RUN_COOLDOWN_SECONDS:-900}"


# Every role.yaml read goes through lib/role-yaml.py, the block-scoped walker
# _lib.sh's yaml_get uses. The readers it replaces matched a one-part key at ANY
# indentation anywhere in the file, and ended a block at the first blank line.
ROLE_YAML_READER="$ROLE_DIR/.scripts/lib/role-yaml.py"
if [[ ! -f "$ROLE_YAML_READER" || -L "$ROLE_YAML_READER" ]]; then
  echo "heartbeat: trusted role.yaml reader unavailable" >&2
  exit 1
fi
yaml_get() {
  python3 "$ROLE_YAML_READER" "$ROLE_YAML" "$1"
}

# True only when role.yaml's reconcile: block says enabled: true. Scoped to that
# block, so an unrelated `enabled:` leaf elsewhere in the file can't flip it on.
reconcile_enabled() {
  local value
  value="$(yaml_get reconcile.enabled)"
  if [[ "${value,,}" == "true" ]]; then printf 'true\n'; else printf 'false\n'; fi
}

AGENT_ID="$(yaml_get agent_id)"
# The desk this pass boots, from the same role.yaml the lease owner and prompt come
# from (credential-launch.sh reads the same key). The launcher would otherwise take
# a caller's HERMES_PROFILE_NAME (a Kanban worker pins its own), and another
# profile would drive this board under this agent's lease and prompt.
PROFILE_NAME="$(yaml_get profile)"
PROFILE_NAME="${PROFILE_NAME:-$AGENT_ID}"
REPO_NAME="$(yaml_get repo)"
PROVIDER="$(yaml_get ticket_provider.name)"

repo_root() {
  local dir="$ROLE_DIR"
  for _ in 1 2 3 4 5; do
    dir="$(dirname "$dir")"
    if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then printf '%s\n' "$dir"; return 0; fi
  done
  return 1
}
REPO_ROOT="$(repo_root)"
cd "$REPO_ROOT"
# A repo with no .project.json has no Krebs execution mode: it is legacy.
EXECUTION_MODE="$(python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); print((json.loads(p.read_text()) if p.is_file() else {}).get("execution",{}).get("mode","legacy"))' "$REPO_ROOT/.project.json")"
if [[ "$EXECUTION_MODE" == managed || "$EXECUTION_MODE" == shadow ]]; then
  KREBS_PLANNER_ENABLED="$(reconcile_enabled)" exec python3 "$ROLE_DIR/.scripts/managed-execution.py" "$REPO_ROOT"
fi

mkdir -p "$RUNTIME/logs"

# Single-run lock. Prefer flock (Linux); fall back to an atomic mkdir lock so
# this also works on macOS, which doesn't ship flock.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    printf '[heartbeat] another heartbeat/full run is active; skipping\n'; exit 0
  fi
else
  LOCK_DIR="$LOCK_FILE.d"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Steal a stale lock older than 60 minutes (a crashed run left it behind).
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null \
        || { printf '[heartbeat] another run active; skipping\n'; exit 0; }
    else
      printf '[heartbeat] another heartbeat/full run is active; skipping\n'; exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
fi

# Reconcile gate: the autonomous board-reconciliation pass runs only when
# role.yaml's reconcile.enabled is true. Deployed PMs default on; setting it
# false explicitly opts out of the autonomous board pass.
if [[ "$(reconcile_enabled)" != "true" ]]; then
  printf '[heartbeat] reconcile disabled (reconcile.enabled != true) — nothing to do\n'
  exit 0
fi

if [[ ! -x "$ROLE_LAUNCHER" || -d "$ROLE_LAUNCHER" ]]; then
  printf 'heartbeat: role launcher %s is missing or not executable\n' "$ROLE_LAUNCHER" >&2
  printf '  fix: flume remediate hermes.pm-scaffold <repo> (rewrites the hermes launcher)\n' >&2
  exit 1
fi

decision="$(
  python3 - "$STATE_FILE" "$ACTIVE_MAX_IDLE_SECONDS" "$FULL_RUN_COOLDOWN_SECONDS" "$BLOCKED_FULL_RUN_COOLDOWN_SECONDS" <<'PYEOF'
import json, subprocess, sys, time
from pathlib import Path
state_path = Path(sys.argv[1]); active_max_idle = int(sys.argv[2])
full_run_cooldown = int(sys.argv[3]); blocked_full_run_cooldown = int(sys.argv[4])
now = time.time()
state = {}
if state_path.exists():
    try: state = json.loads(state_path.read_text())
    except Exception: state = {}
session = str(state.get("session") or ""); status = str(state.get("status") or "")
worktree = str(state.get("worktree") or "")
def iso_epoch(value):
    if not value: return 0
    try: return time.mktime(time.strptime(str(value).replace("Z","+0000"), "%Y-%m-%dT%H:%M:%S%z"))
    except Exception:
        try:
            from datetime import datetime
            return datetime.fromisoformat(str(value).replace("Z","+00:00")).timestamp()
        except Exception: return 0
if status in {"blocked","stalled","error"}:
    last_blocked_run = (float(state.get("last_full_run_epoch") or 0)
        or iso_epoch(state.get("last_runner_completed_at")) or iso_epoch(state.get("updated_at")))
    if last_blocked_run and (now - last_blocked_run) < blocked_full_run_cooldown:
        print("skip:blocker-cooldown"); raise SystemExit(0)
# No "a worker is already running, skip" gate: a PM orchestrates many tickets in
# parallel, so a healthy worker on one ticket must never stop a pass that would
# dispatch a different ready ticket. The cooldown below is the only throttle.
last_full_run = float(state.get("last_full_run_epoch") or 0)
if last_full_run and (now - last_full_run) < full_run_cooldown: print("skip:cooldown")
else: print("run:full")
PYEOF
)"

write_state() {  # write_state <json-merge-via-python args...>
  python3 - "$STATE_FILE" "$AGENT_ID" "$REPO_NAME" "$LOG_FILE" "$@" "$PROVIDER"
}

case "$decision" in
  skip:*)
    write_state "$decision" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone
from pathlib import Path
path = Path(sys.argv[1]); agent_id, repo, log_path, decision, provider = sys.argv[2:7]
state = json.loads(path.read_text()) if path.exists() else {}
now_iso = datetime.fromtimestamp(time.time(), timezone.utc).isoformat()
state.update({"source":"hermes-continuous-ticket-sentinel","agent_id":agent_id,"repo":repo,
    "ticket_provider":provider,"log_path":log_path,"last_heartbeat_at":now_iso,"last_decision":decision})
state.setdefault("updated_at", now_iso); state.setdefault("summary", state.get("reason") or decision)
tmp = path.with_suffix(path.suffix + ".tmp"); tmp.write_text(json.dumps(state, indent=2, sort_keys=True)+"\n"); tmp.replace(path)
PYEOF
    printf '[heartbeat] %s\n' "$decision"
    exit 0
    ;;
esac

write_state "$decision" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone
from pathlib import Path
path = Path(sys.argv[1]); agent_id, repo, log_path, decision, provider = sys.argv[2:7]
state = json.loads(path.read_text()) if path.exists() else {}
now = time.time()
state.update({"source":"hermes-continuous-ticket-sentinel","agent_id":agent_id,"repo":repo,
    "ticket_provider":provider,"status":"checking",
    "summary":"PM is reconciling the ticket board, evidence, and worker state.",
    "log_path":log_path,"last_heartbeat_at":datetime.fromtimestamp(now,timezone.utc).isoformat(),
    "last_decision":decision,"last_full_run_epoch":now,
    "last_full_run_started_at":datetime.fromtimestamp(now,timezone.utc).isoformat()})
tmp = path.with_suffix(path.suffix + ".tmp"); tmp.write_text(json.dumps(state, indent=2, sort_keys=True)+"\n"); tmp.replace(path)
PYEOF

# Board-driver lease (momo E2/S2.3; not a WIP limit): serializes short board
# selection/transition passes. Don't full-drive if the human-drivable Momo (or any
# other owner) holds it fresh — it's driving the same board right now. A crashed
# holder's lease expires (ttl) so the board is never wedged. Release on any exit.
#
# THIS LAUNCHER HOLDS THE LEASE FOR THE AGENT. It tells the agent so (a literal
# section appended to the prompt) because the PM's SOUL says "acquire before
# driving": under a fresh owner name that acquire is refused by this very lease,
# and the PM concluded a sibling pass was running and backed off, zero dispatch.
# The agent's rule is: the lease is yours, refresh/release (and, after an early
# release, re-acquire) it with this exact owner, never under another name; only a
# different owner means back off. Acquire is reentrant only for the identical
# owner string.
#
# The owner is unique PER PASS (hermes:<agent_id>:pass-<utc>-<pid>), never the bare
# hermes:<agent_id>: a gateway turn of this same agent (Telegram, a Bloodbank or
# Momo-crank delegation) is a different driver and acquires under its own unique
# owner. A shared owner string would make both acquires "reentrant", two drivers
# would write the board at once, and the first release would drop the lease out
# from under the other. With one owner per pass they serialize like any two
# drivers, and the exit trap below can only release this pass's own lease.
#
# The handoff is the prompt section. HERMES_BOARD_LEASE_* are exported too, but only
# for scripts this process runs directly: `hermes chat` is a client of the host
# gateway, which runs the PM's tools, and a client's HERMES_* names never reach
# that session's terminal (agent/session_client_env.py).
WIP_LOCK="$RUNTIME/wip-driver.lock"
LEASE_OWNER="hermes:$AGENT_ID:pass-$(date -u +%Y%m%dT%H%M%SZ)-$$"
LEASE_TTL=3600
LEASE_CLI="$ROLE_DIR/.scripts/momo-wip-lock.py"
if ! lease_out="$(python3 "$LEASE_CLI" acquire "$WIP_LOCK" "$LEASE_OWNER" --ttl "$LEASE_TTL" 2>&1)"; then
  printf '[heartbeat] board-driver lease not ours (%s) — skipping full reconcile pass this tick\n' "$lease_out"
  exit 0
fi
# Replaces the mkdir-lock trap of the no-flock (macOS) path, so it removes that too.
trap 'python3 "$LEASE_CLI" release "$WIP_LOCK" "$LEASE_OWNER" >/dev/null 2>&1 || true; [[ -z "${LOCK_DIR:-}" ]] || rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
export HERMES_BOARD_LEASE_PATH="$WIP_LOCK" HERMES_BOARD_LEASE_OWNER="$LEASE_OWNER" HERMES_BOARD_LEASE_TTL="$LEASE_TTL"

lease_cmd="python3 $LEASE_CLI"
prompt="$(<"$PROMPT_FILE")"
prompt+=$'\n\n## Board-driver lease for THIS pass (already held for you)\n\n'
prompt+="The launcher that started this pass already acquired the board-driver lease for you, as owner \`$LEASE_OWNER\` (ttl ${LEASE_TTL}s). It is YOURS for this whole pass. That exact string is you; write it out literally in every lease command (your terminal does not see the launcher's environment, so never omit the owner). Never acquire the lease under any other owner name: your own lease would refuse it, and that refusal is not a sibling pass."$'\n\n'
prompt+="\`\`\`bash"$'\n'
prompt+="$lease_cmd held    $WIP_LOCK $LEASE_OWNER   # 0 = still yours"$'\n'
prompt+="$lease_cmd refresh $WIP_LOCK $LEASE_OWNER   # during a long board pass"$'\n'
prompt+="$lease_cmd release $WIP_LOCK $LEASE_OWNER   # before waiting on workers"$'\n'
prompt+="$lease_cmd acquire $WIP_LOCK $LEASE_OWNER --ttl $LEASE_TTL   # write the board again after releasing"$'\n'
prompt+="\`\`\`"$'\n\n'
prompt+="Releasing early is fine; when the workers finish and you need to write the board again (Review, Done, a hold), re-acquire with exactly \`$LEASE_OWNER\` as above. If that acquire answers HELD by any other owner (\`momo\`, another agent, or another pass or turn of your own desk under a different owner string), another driver is writing the board: do not write it, and leave the transition for the next pass. The launcher's own release at exit is a no-op once you have released."$'\n'
set +e
HERMES_PROFILE_NAME="$PROFILE_NAME" "$ROLE_LAUNCHER" chat -Q --source "$SESSION_SOURCE" --max-turns 90 -q "$prompt"
status=$?
set -e

runner_exit="$(
  python3 - "$STATE_FILE" "$status" "$AGENT_ID" "$REPO_NAME" "$LOG_FILE" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone
from pathlib import Path
path = Path(sys.argv[1]); exit_code = int(sys.argv[2]); agent_id, repo, log_path = sys.argv[3:6]
state = json.loads(path.read_text()) if path.exists() else {}
now_iso = datetime.fromtimestamp(time.time(), timezone.utc).isoformat()
state.update({"source":"hermes-continuous-ticket-sentinel","agent_id":agent_id,"repo":repo,
    "log_path":log_path,"last_heartbeat_at":now_iso})
state["last_runner_exit_code"] = exit_code; state["last_runner_completed_at"] = now_iso
state.setdefault("last_full_run_epoch", time.time())
if state.get("status") == "checking":
    state["status"] = "idle" if exit_code == 0 else "error"
    state["summary"] = ("PM completed the reconciliation pass without claiming work."
        if exit_code == 0 else "PM reconciliation failed; inspect the heartbeat log.")
    state.setdefault("updated_at", now_iso)
tmp = path.with_suffix(path.suffix + ".tmp"); tmp.write_text(json.dumps(state, indent=2, sort_keys=True)+"\n"); tmp.replace(path)
print(0 if state.get("status") in {"active","blocked","stalled","idle"} else exit_code)
PYEOF
)"
exit "$runner_exit"
