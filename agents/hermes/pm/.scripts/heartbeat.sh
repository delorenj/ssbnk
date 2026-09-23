#!/usr/bin/env bash
# Unified agent heartbeat: continuous board-reconciliation sentinel pass +
# board-reconciliation pass.
#
# Runs often (systemd timer, ~1 min). Only invokes Hermes for a full
# reconciliation pass when local state says no worker is active, the worker
# heartbeat is stale, or the last full run is outside the cooldown window. The
# full pass executes the role's sentinel.prompt.md, which reasons about tickets
# through the ticket-provider adapter (Linear | Plane | Trello) — never a
# hardcoded backend. After the sentinel decision (skip OR full), it
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # agents/hermes/<role>
RUNTIME="$ROLE_DIR/runtime"
RUN_HOME="${HERMES_HOME:-$RUNTIME}"
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

# Hermes binary: explicit env > ~/.config/hermes-agent/hermes-bin > PATH.
HERMES_BIN="${HERMES_BIN:-${HERMES_FLEET_BIN:-}}"
if [[ -z "$HERMES_BIN" ]]; then
  if [[ -r "$HOME/.config/hermes-agent/hermes-bin" ]]; then
    HERMES_BIN="$(cat "$HOME/.config/hermes-agent/hermes-bin")"
  else
    HERMES_BIN="$(command -v hermes || echo hermes)"
  fi
fi

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
if status in {"active","delegated","working"} and session:
    process_active = False
    try:
        result = subprocess.run(["ps","-u",str(__import__("os").getuid()),"-o","pid=,command="],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        markers = ("codex exec","opencode run","auggie","gemini","kimi","copilot")
        process_active = any(((session and session in line) or (worktree and worktree in line))
            and any(m in line for m in markers) for line in result.stdout.splitlines())
    except Exception: process_active = False
    # Per-session liveness. zellij 0.44 has NO per-session log: there is one
    # global log under /tmp/zellij-$UID/zellij-log/. The path this used to read
    # (~/.local/state/zellij/sessions/<s>/zellij.log) never exists, so
    # log_recent was silently always False. session-metadata.kdl IS
    # per-session and is rewritten every serialization tick (60s default),
    # well inside the active_max_idle window. (Found and fixed in skillex-pm.)
    log_path = Path.home()/".cache"/"zellij"/"contract_version_1"/"session_info"/session/"session-metadata.kdl"
    log_recent = log_path.exists() and (now - log_path.stat().st_mtime) <= active_max_idle
    marker_recent = False
    last_activity = iso_epoch(state.get("last_activity_at")) or iso_epoch(state.get("updated_at"))
    if last_activity: marker_recent = (now - last_activity) <= active_max_idle
    if process_active and (log_recent or marker_recent):
        print("skip:active-worker"); raise SystemExit(0)
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

# Coexistence WIP=1 lease (momo E2/S2.3): don't full-drive if the human-drivable
# Momo holds it — it's driving the same board. A crashed holder's lease expires
# (ttl) so the board is never wedged. Release on any exit.
WIP_LOCK="$RUNTIME/wip-driver.lock"
if ! python3 "$ROLE_DIR/.scripts/momo-wip-lock.py" acquire "$WIP_LOCK" "hermes:$AGENT_ID" --ttl 3600 >/dev/null 2>&1; then
  printf '[heartbeat] WIP lease held by Momo — skipping full reconcile pass this tick\n'
  exit 0
fi
trap 'python3 "$ROLE_DIR/.scripts/momo-wip-lock.py" release "$WIP_LOCK" "hermes:$AGENT_ID" >/dev/null 2>&1 || true' EXIT

prompt="$(<"$PROMPT_FILE")"
set +e
env HERMES_HOME="$RUN_HOME" "$HERMES_BIN" chat -Q --source cron --max-turns 90 -q "$prompt"
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
