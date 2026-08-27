#!/usr/bin/env bash
# Bind this agent to the repo's ONE ticket board.
#
# Source of truth is the repo-root .project.json `ticket_provider` block
# (written by the CommonProject base template). The model is:
#   ONE board per repo — the PM owns it, and its heartbeat reconciliation pass
# watches it. So we never mint a per-agent, role-suffixed board ("Foo PM" /
# "Foo Sentinel"). Instead:
#   1. If .project.json already names a board  -> BIND to it (no creation).
#   2. Otherwise (hermes run on a repo with no CommonProject board yet)
#      -> create ONE repo-named board and write it back into .project.json so
#         it becomes the SOT for every agent in this repo.
# Either way we register this agent under .project.json `agents` and mirror the
# binding into role.yaml for back-compat (80-registry.sh / 99-summary.sh).

# The caller's negative board grant is authoritative. Check it before sourcing
# _lib.sh so a skipped step cannot load fleet credentials, create logs/markers,
# inspect bindings, or reach a provider adapter.
if [[ "${SKIP_PLANE:-0}" == "1" ]]; then
  printf '%s\n' '[42] ticket provider — SKIPPED (SKIP_PLANE=1)' >&2
  exit 0
fi

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env
# shellcheck source=lib/ticket-provider.sh
source "$(dirname "$0")/lib/ticket-provider.sh"

already_done 42-ticket-provider && { log "[42] ticket provider already set up — skipping"; exit 0; }

# Locate the repo-root .project.json (the SOT).
REPO_ROOT="$(project_repo_path 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$ROLE_DIR/../../.." 2>/dev/null && pwd)"
PROJECT_JSON="$REPO_ROOT/.project.json"
ROLE_DIR_REL="${ROLE_DIR#"$REPO_ROOT"/}"

# pj <dotted.key> — read a string value from .project.json (empty if absent).
pj() {
  [ -f "$PROJECT_JSON" ] || { printf ''; return 0; }
  python3 - "$PROJECT_JSON" "$1" <<'PY'
import sys, json, pathlib
try:
    d = json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception:
    print(""); raise SystemExit(0)
cur = d
for k in sys.argv[2].split("."):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print(""); raise SystemExit(0)
print(cur if isinstance(cur, str) else "")
PY
}

# pj_write — merge board binding (optional) + this agent into .project.json.
# args: set_provider(0|1) provider board_id board_url workspace identifier team
pj_write() {
  REPO="$REPO" REPO_ROOT="$REPO_ROOT" AGENT_ID="$AGENT_ID" ROLE="$ROLE" \
  ROLE_DIR_REL="$ROLE_DIR_REL" PROJECT_DESC="${PROJECT_DESC:-}" \
  python3 - "$PROJECT_JSON" "$@" <<'PY'
import sys, os, json, pathlib
(path, set_provider, provider, board_id, board_url, workspace, identifier, team) = sys.argv[1:9]
p = pathlib.Path(path)
try:
    d = json.loads(p.read_text())
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
repo = os.environ.get("REPO", "")
d.setdefault("project_name", repo)
d.setdefault("project_slug", repo)
if not d.get("repo_path"):
    d["repo_path"] = os.environ.get("REPO_ROOT", "")
if set_provider == "1":
    tp = d.setdefault("ticket_provider", {})
    tp["type"] = provider
    if workspace:  tp["workspace"] = workspace
    if identifier: tp["identifier"] = identifier
    if board_id:   tp["board_id"] = board_id
    if board_url:  tp["board_url"] = board_url
    if team:       tp["team"] = team
ag = d.setdefault("agents", {})
entry = ag.get(os.environ["AGENT_ID"], {})
if not isinstance(entry, dict):
    entry = {}
entry.update({
    "role": os.environ["ROLE"],
    "role_dir": os.environ["ROLE_DIR_REL"],
    "provisioning_state": "provisioned",
})
ag[os.environ["AGENT_ID"]] = entry
p.write_text(json.dumps(d, indent=2) + "\n")
PY
  log "    .project.json updated (agent=$AGENT_ID)"
}

# Mirror the binding into role.yaml so legacy consumers keep working.
mirror_to_role_yaml() {
  # mirror_to_role_yaml <provider> <board_id> <board_url> <workspace> <identifier> <team>
  local provider="$1" bid="$2" burl="$3" ws="$4" ident="$5" team="$6"
  yaml_set ticket_provider.name "$provider" 2>/dev/null || true
  [ -n "$bid" ]  && yaml_set ticket_provider.board_id "$bid" 2>/dev/null || true
  [ -n "$burl" ] && yaml_set ticket_provider.board_url "$burl" 2>/dev/null || true
  case "$provider" in
    plane)
      [ -n "$bid" ] && echo "$bid" > "$ROLE_DIR/.scripts/.plane-project-id"
      [ -n "$ws" ]    && yaml_set ticket_provider.workspace "$ws" 2>/dev/null || true
      [ -n "$bid" ]   && yaml_set ticket_provider.project "$bid" 2>/dev/null || true
      [ -n "$ws" ]    && yaml_set plane.workspace "$ws" 2>/dev/null || true
      [ -n "$ident" ] && yaml_set plane.identifier "$ident" 2>/dev/null || true
      ;;
    trello)
      [ -n "$bid" ] && yaml_set ticket_provider.board "$bid" 2>/dev/null || true
      ;;
    linear)
      [ -n "$team" ] && yaml_set ticket_provider.team "$team" 2>/dev/null || true
      ;;
  esac
}

# ── Provider resolution ──────────────────────────────────────────────────
# An existing repo board (in .project.json) wins — every agent binds to it.
SOT_TYPE="$(pj ticket_provider.type)"
SOT_BOARD_ID="$(pj ticket_provider.board_id)"
SOT_URL="$(pj ticket_provider.board_url)"
SOT_WS="$(pj ticket_provider.workspace)"
SOT_IDENT="$(pj ticket_provider.identifier)"
SOT_TEAM="$(pj ticket_provider.team)"

# role.yaml provider comes from copier --data (the operator's pjangler choice).
ROLE_PROVIDER="$(yaml_get ticket_provider.name)"

if [ -n "$SOT_BOARD_ID" ]; then
  # ── BIND to the repo's existing board ──────────────────────────────────
  PROVIDER="${SOT_TYPE:-${ROLE_PROVIDER:-plane}}"
  if [ -n "$ROLE_PROVIDER" ] && [ "$ROLE_PROVIDER" != "$PROVIDER" ]; then
    warn "[42] requested provider '$ROLE_PROVIDER' but repo board is '$PROVIDER' (.project.json wins); binding to existing board"
  fi
  log "[42] binding $AGENT_ID to existing repo board (provider=$PROVIDER, id=$SOT_BOARD_ID)"
  mirror_to_role_yaml "$PROVIDER" "$SOT_BOARD_ID" "$SOT_URL" "$SOT_WS" "$SOT_IDENT" "$SOT_TEAM"
  pj_write 0 "$PROVIDER" "" "" "" "" ""   # register agent only; board already recorded
  mark_done 42-ticket-provider
  exit 0
fi

# ── No repo board yet: create ONE repo-named board (no role suffix) ───────
PROVIDER="${ROLE_PROVIDER:-${SOT_TYPE:-plane}}"
log "[42] no board in .project.json — bootstrapping a repo board (provider: $PROVIDER)"

# Repo-based identity, matching CommonProject's scheme (slug[:4] uppercased).
RAW=$(printf '%s' "$REPO" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')
while [ ${#RAW} -lt 2 ]; do RAW="${RAW}X"; done
IDENT="${SOT_IDENT:-${RAW:0:4}}"
# Board NAME = repo name, separators->space, title-cased. NOT display_name —
# display_name carries the role suffix and must never become the board name.
NAME="$(printf '%s' "$REPO" | tr '_-' '  ' | python3 -c 'import sys; print(" ".join(w[:1].upper()+w[1:] for w in sys.stdin.read().split()))')"
DESC="Ticket board for $REPO"

case "$PROVIDER" in
  linear)
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
      warn "[42] LINEAR_API_KEY not set; set role.yaml/.project.json ticket_provider.team and re-run ./.scripts/42-ticket-provider.sh"
      pj_write 1 linear "" "" "" "$IDENT" "$SOT_TEAM"
      mark_done 42-ticket-provider; exit 0
    fi
    OUT="$(tp resolve 2>/dev/null || true)"
    BID="$(printf '%s' "$OUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("board_id",""))
except Exception: print("")')"
    BURL="$(printf '%s' "$OUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("board_url",""))
except Exception: print("")')"
    if [ -n "$BID" ]; then
      mirror_to_role_yaml linear "$BID" "$BURL" "" "$IDENT" "$SOT_TEAM"
      pj_write 1 linear "$BID" "$BURL" "" "$IDENT" "$SOT_TEAM"
    else
      warn "[42] linear resolve returned no board; set ticket_provider.team and re-run"
      pj_write 1 linear "" "" "" "$IDENT" "$SOT_TEAM"
    fi
    ;;

  plane|trello)
    KEYVAR=PLANE_API_KEY; [ "$PROVIDER" = trello ] && KEYVAR=TRELLO_KEY
    if [[ -z "${!KEYVAR:-}" ]]; then
      warn "[42] $KEYVAR not set; skipping board creation. Set creds and re-run ./.scripts/42-ticket-provider.sh"
      pj_write 1 "$PROVIDER" "" "" "${SOT_WS:-$PLANE_WORKSPACE}" "$IDENT" ""
      mark_done 42-ticket-provider; exit 0
    fi
    OUT="$(tp create_board "$NAME" "$IDENT" "$DESC")" || die "create_board failed for $PROVIDER"
    BID="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("board_id",""))')"
    BURL="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("board_url",""))')"
    WS="${SOT_WS:-$PLANE_WORKSPACE}"
    [ "$PROVIDER" = trello ] && WS=""
    mirror_to_role_yaml "$PROVIDER" "$BID" "$BURL" "$WS" "$IDENT" ""
    pj_write 1 "$PROVIDER" "$BID" "$BURL" "$WS" "$IDENT" ""
    ;;

  *) die "unknown ticket provider: $PROVIDER (expected linear|plane|trello)" ;;
esac

mark_done 42-ticket-provider
