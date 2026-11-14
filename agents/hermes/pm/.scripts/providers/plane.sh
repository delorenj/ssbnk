#!/usr/bin/env sh
# Plane ticket-provider adapter.
#
# Credentials:  PLANE_API_KEY or PLANE_<WORKSPACE>_API_KEY (raw at runtime or
#               an op:// reference resolved immediately before use)
# Endpoint:     PLANE_BASE       (default https://plane.delo.sh)
# Board binding (repo-root .project.json `ticket_provider:`):
#   workspace: <workspace-slug>      (or env PLANE_WORKSPACE)
#   board_id:  <project-uuid>        (set by create_board / 42-ticket-provider)
#   timezone:  <IANA timezone>       optional project calendar override
# Lane names (role.yaml `ticket_provider:`, each optional): backlog, unstarted,
#   started, completed (default "Done"), cancelled (default "Cancelled"). An
#   unnamed lane resolves only when its state group has exactly one member.
#
# Krebs lifecycle v2 (krebs/spec/lifecycle.v2.yaml): every board has the five
# stock lanes (Backlog, Todo, In Progress, Done, Cancelled); what the retired
# lanes meant now lives in labels. So two normalized targets are label writes:
#   in_review          the handback: the started lane (In Progress) plus
#                      lifecycle:review, waiting for a verdict.
#   awaiting_decision  a hold: plus lifecycle:needs-input, lane unchanged, on a
#                      Todo or In Progress ticket only (krebs tick is the one
#                      thing that moves Todo -> In Progress). Aliases:
#                      needs_attention, waiting_reply.
# The labels must already exist on the board (every board carries all six);
# they are never created here. Every other target is a plain lane move, and
# krebs tick strips a lifecycle:review left outside In Progress.
#
# Rate limiting: reads retry HTTP 429 up to PLANE_READ_MAX_ATTEMPTS (default 4)
# times, sleeping the server's Retry-After capped at PLANE_429_MAX_DELAY
# (default 30s). Mutations are never retried in the transport layer, and
# transition sends at most ONE PATCH: without a version/precondition guard a
# repeated PATCH can stomp a concurrent actor, so the live read-back after the
# single attempt is the only success proof. PLANE_MAX_PAGES bounds every
# paginated collection (default 1000). All numeric overrides are validated
# before any request.
#
# Plane model:  project = board, cycle = milestone, state.group in
#   backlog|unstarted|started|completed|cancelled.
#
# NOTE: REST paths follow Plane's v1 public API. Verify against a live board on
# first use; state/cycle naming varies per workspace.
set -eu

OP="${1:-}"; shift 2>/dev/null || true
ROLE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROLE_YAML="$ROLE_DIR/role.yaml"
BASE="${PLANE_BASE:-https://plane.delo.sh}"

# Managed/shadow execution owns every mutation; stop before credential fallback.
EXECUTION_MODE="$(python3 - "$ROLE_DIR" <<'PYMODE'
import json, pathlib, sys
for parent in [pathlib.Path(sys.argv[1]), *pathlib.Path(sys.argv[1]).parents]:
    path=parent/'.project.json'
    if path.exists():
        print(json.loads(path.read_text()).get('execution',{}).get('mode','legacy')); break
PYMODE
)"
case "$EXECUTION_MODE" in
  managed|shadow)
    case "$OP" in
      resolve|describe_board|list_issues|list_states|list_labels|active_milestone|get_issue) ;;
      *) echo "plane: $EXECUTION_MODE lifecycle writes require px task through Krebs" >&2; exit 78 ;;
    esac ;;
esac


FLEET_ENV="${HERMES_FLEET_ENV:-$HOME/.hermes/fleet.env}"

die() { echo "plane: $*" >&2; exit 1; }
need_key() { [ -n "${PLANE_API_KEY:-}" ] || die "PLANE_API_KEY is not set"; }

validated_uint() {
  setting="$1"; value="$2"; minimum="$3"; maximum="$4"
  case "$value" in ''|*[!0-9]*) die "$setting must be an integer from $minimum through $maximum" ;; esac
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ] \
    || die "$setting must be an integer from $minimum through $maximum"
  printf '%s' "$value"
}

workspace_key() {
  key="$(printf '%s' "${1:-default}" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
  [ -n "$key" ] || key="DEFAULT"
  printf 'PLANE_%s_API_KEY' "$key"
}

# dotenv_value FILE KEY — read one exact dotenv assignment as inert data.
# Never source the shared fleet file: it may contain unrelated command
# substitutions or credential helpers that this provider must not execute.
dotenv_value() {
  python3 - "$1" "$2" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = ""
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    name, sep, candidate = line.partition("=")
    if sep and name.strip() == key:
        candidate = candidate.strip()
        if len(candidate) >= 2 and candidate[0] == candidate[-1] and candidate[0] in "'\"":
            candidate = candidate[1:-1]
        value = candidate
        break
print(value, end="")
PY
}

# Resolve an approved secret reference only after selecting the exact provider
# key. The shared dotenv stays inert and the resolved value exists only in this
# provider process.
resolve_secret_value() {
  value="${1:-}"
  case "$value" in
    op://*)
      command -v op >/dev/null 2>&1 || die "1Password CLI is required for the configured Plane credential"
      op read "$value" || die "failed to resolve the configured Plane credential"
      ;;
    *) printf '%s' "$value" ;;
  esac
}

tp_cfg() {
  [ -f "$ROLE_YAML" ] || return 0
  python3 - "$ROLE_YAML" "$1" <<'PY'
import sys, re, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'(?ms)^ticket_provider:\s*$(.*?)(?=^\S)', text + "\n\x00")
block = m.group(1) if m else ""
mm = re.search(rf'(?m)^\s*{re.escape(sys.argv[2])}:\s*"?([^"\n]*)"?\s*$', block)
print(mm.group(1).strip() if mm else "")
PY
}

# pj_cfg KEY — read ticket_provider.<KEY> from the repo-root .project.json (the
# SOT), walking up from the role dir. This is preferred over role.yaml so all of
# a repo's agents resolve to the same board.
pj_cfg() {
  python3 - "$ROLE_DIR" "$1" <<'PY'
import sys, json, pathlib
start = pathlib.Path(sys.argv[1]).resolve(); key = sys.argv[2]
for parent in [start, *start.parents]:
    f = parent / ".project.json"
    if f.is_file():
        try: tp = (json.loads(f.read_text()).get("ticket_provider") or {})
        except Exception: tp = {}
        print(tp.get(key, "") if isinstance(tp, dict) else ""); break
else:
    print("")
PY
}

# Board binding: .project.json (SOT) first, then legacy role.yaml, then env.
WS="$(pj_cfg workspace)"; [ -n "$WS" ] || WS="$(tp_cfg workspace)"; WS="${WS:-${PLANE_WORKSPACE:-}}"
PROJ="$(pj_cfg board_id)"; [ -n "$PROJ" ] || PROJ="$(tp_cfg project)"; [ -n "$PROJ" ] || PROJ="$(tp_cfg board_id)"
SM_DONE="$(tp_cfg completed)"; SM_DONE="${SM_DONE:-Done}"
SM_CANCELLED="$(tp_cfg cancelled)"; SM_CANCELLED="${SM_CANCELLED:-Cancelled}"
SM_STARTED="$(tp_cfg started)"
SM_UNSTARTED="$(tp_cfg unstarted)"
SM_BACKLOG="$(tp_cfg backlog)"
LABEL_REVIEW="lifecycle:review"
LABEL_NEEDS_INPUT="lifecycle:needs-input"
CALENDAR_TZ="$(pj_cfg timezone)"; [ -n "$CALENDAR_TZ" ] || CALENDAR_TZ="$(tp_cfg timezone)"
CALENDAR_TZ="${CALENDAR_TZ:-${TICKET_PROVIDER_TIMEZONE:-${TZ:-}}}"
API="$BASE/api/v1/workspaces/$WS"

READ_MAX_ATTEMPTS="$(validated_uint PLANE_READ_MAX_ATTEMPTS "${PLANE_READ_MAX_ATTEMPTS:-4}" 1 20)"
RETRY_DEFAULT_DELAY="$(validated_uint PLANE_429_RETRY_DELAY "${PLANE_429_RETRY_DELAY:-1}" 0 3600)"
RETRY_MAX_DELAY="$(validated_uint PLANE_429_MAX_DELAY "${PLANE_429_MAX_DELAY:-30}" 0 3600)"
MAX_PAGES="$(validated_uint PLANE_MAX_PAGES "${PLANE_MAX_PAGES:-1000}" 1 1000)"

if [ -z "${PLANE_API_KEY:-}" ]; then
  KEY="$(workspace_key "$WS")"
  PLANE_API_KEY="$(printenv "$KEY" 2>/dev/null || true)"
  if [ -z "${PLANE_API_KEY:-}" ] && [ -f "$FLEET_ENV" ]; then
    PLANE_API_KEY="$(dotenv_value "$FLEET_ENV" "$KEY")"
  fi
fi
PLANE_API_KEY="$(resolve_secret_value "${PLANE_API_KEY:-}")"
export PLANE_API_KEY

# api METHOD PATH [JSON_BODY] — call Plane REST, print response body.
# Reads (GET) are idempotent: on HTTP 429 they retry a bounded number of times,
# sleeping the server's Retry-After (capped, default when absent). Mutations
# are never retried here — a caller must check whether a failed mutation landed
# before repeating it. Any non-2xx outcome dies with the explicit status.
api() {
  need_key
  method="$1"; path="$2"; body="${3:-}"
  max_attempts=1
  case "$method" in GET) max_attempts="$READ_MAX_ATTEMPTS" ;; esac
  api_scratch="$(mktemp -d "${TMPDIR:-/tmp}/plane-api.XXXXXX")" \
    || die "could not create API scratch directory"
  response_file="$api_scratch/response"
  headers_file="$api_scratch/headers"
  cleanup_api_scratch() {
    rm -f "$response_file" "$headers_file"
    rmdir "$api_scratch" 2>/dev/null || true
  }
  trap cleanup_api_scratch 0
  trap 'cleanup_api_scratch; exit 129' HUP
  trap 'cleanup_api_scratch; exit 130' INT
  trap 'cleanup_api_scratch; exit 143' TERM
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    : > "$response_file"
    : > "$headers_file"
    curl_exit=0
    if [ -n "$body" ]; then
      captured="$(curl -sS -o "$response_file" -D "$headers_file" -w '%{http_code}' -X "$method" "$API/$path" \
        -H "X-API-Key: $PLANE_API_KEY" -H "Content-Type: application/json" \
        -H "User-Agent: curl/8.0" \
        -d "$body")" || curl_exit=$?
    else
      captured="$(curl -sS -o "$response_file" -D "$headers_file" -w '%{http_code}' -X "$method" "$API/$path" \
        -H "X-API-Key: $PLANE_API_KEY" \
        -H "User-Agent: curl/8.0")" || curl_exit=$?
    fi
    if [ "$curl_exit" -ne 0 ]; then
      cleanup_api_scratch
      trap - 0 HUP INT TERM
      die "$method $path failed at transport (curl exit $curl_exit)"
    fi
    case "$captured" in
      [1-5][0-9][0-9])
        status="$captured"
        ;;
      *)
        cleanup_api_scratch
        trap - 0 HUP INT TERM
        die "$method $path returned invalid HTTP status ${captured:-empty}"
        ;;
    esac
    output="$(cat "$response_file")"
    if [ "$status" = 429 ] && [ "$attempt" -lt "$max_attempts" ]; then
      delay="$(python3 - "$headers_file" "$RETRY_DEFAULT_DELAY" "$RETRY_MAX_DELAY" <<'PY'
import datetime
import email.utils
import math
import sys

raw = ""
with open(sys.argv[1], encoding="utf-8", errors="replace") as stream:
    for line in stream:
        name, _, value = line.partition(":")
        if name.strip().lower() == "retry-after":
            raw = value.strip()
fallback = int(sys.argv[2])
maximum = int(sys.argv[3])
if raw.isdigit():
    delay = int(raw)
else:
    try:
        target = email.utils.parsedate_to_datetime(raw)
        if target.tzinfo is None:
            target = target.replace(tzinfo=datetime.timezone.utc)
        delay = max(
            0,
            math.ceil(
                (target - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
            ),
        )
    except (TypeError, ValueError, OverflowError):
        delay = fallback
print(min(delay, maximum))
PY
)"
      sleep "$delay"
      continue
    fi
    case "$status" in
      2*)
        printf '%s' "$output"
        cleanup_api_scratch
        trap - 0 HUP INT TERM
        return 0
        ;;
    esac
    detail="$(printf '%s' "$output" | head -c 300 | tr '\n' ' ')"
    cleanup_api_scratch
    trap - 0 HUP INT TERM
    die "$method $path failed (HTTP $status)${detail:+: $detail}"
  done
}

# api_all PATH — GET every page of a Plane list endpoint and print one merged
# JSON array. Plane v1 paginates with a next_cursor query token and a
# next_page_results flag; bare-list and single-page responses pass through.
api_all() {
  path="$1"
  page_scratch="$(mktemp -d "${TMPDIR:-/tmp}/plane-pages.XXXXXX")" \
    || die "could not create pagination scratch directory"
  pages_file="$page_scratch/pages"
  cursors_file="$page_scratch/cursors"
  : > "$pages_file"
  : > "$cursors_file"
  cleanup_page_scratch() {
    rm -f "$pages_file" "$cursors_file"
    rmdir "$page_scratch" 2>/dev/null || true
  }
  trap cleanup_page_scratch 0
  trap 'cleanup_page_scratch; exit 129' HUP
  trap 'cleanup_page_scratch; exit 130' INT
  trap 'cleanup_page_scratch; exit 143' TERM
  cursor=""
  page_count=0
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le "$MAX_PAGES" ] \
      || die "pagination for $path exceeded PLANE_MAX_PAGES=$MAX_PAGES"
    case "$path" in *\?*) sep="&" ;; *) sep="?" ;; esac
    if [ -n "$cursor" ]; then
      encoded_cursor="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$cursor")"
      page_path="$path${sep}cursor=$encoded_cursor"
    else
      page_path="$path"
    fi
    if ! page="$(api GET "$page_path")"; then
      cleanup_page_scratch
      trap - 0 HUP INT TERM
      return 1
    fi
    printf '%s\0' "$page" >> "$pages_file"
    page_meta="$(printf '%s' "$page" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if isinstance(d,list):
    print("done")
elif isinstance(d,dict):
    more=d.get("next_page_results", False)
    if more is True:
        cursor=str(d.get("next_cursor") or "")
        if not cursor:
            raise SystemExit("plane: pagination reported another page without a cursor")
        print("next\t"+cursor)
    else:
        print("done")
else:
    raise SystemExit("plane: paginated endpoint returned neither an object nor a list")')"
    case "$page_meta" in
      done) break ;;
      next*) next="${page_meta#*	}" ;;
      *) die "invalid pagination metadata for $path" ;;
    esac
    cursor_fingerprint="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$next")"
    if grep -Fqx "$cursor_fingerprint" "$cursors_file"; then
      die "pagination cursor for $path repeated"
    fi
    printf '%s\n' "$cursor_fingerprint" >> "$cursors_file"
    cursor="$next"
  done
  python3 - "$pages_file" <<'PY'
import json
import pathlib
import sys

rows = []
for chunk in pathlib.Path(sys.argv[1]).read_bytes().split(b"\0"):
    if not chunk:
        continue
    d = json.loads(chunk)
    if isinstance(d, list):
        rows.extend(d)
    elif isinstance(d, dict):
        rows.extend(d.get("results") or [])
print(json.dumps(rows))
PY
  cleanup_page_scratch
  trap - 0 HUP INT TERM
}

# Select the one date-current cycle. An empty result is explicit and must never
# fall back to the first historical cycle returned by Plane.
current_cycle() {
  CALENDAR_TZ="$CALENDAR_TZ" TICKET_PROVIDER_NOW="${TICKET_PROVIDER_NOW:-}" python3 -c 'import sys,json,datetime,os
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
tz_name=os.environ.get("CALENDAR_TZ", "").strip()
try:
    calendar_tz=ZoneInfo(tz_name) if tz_name else (datetime.datetime.now().astimezone().tzinfo or datetime.timezone.utc)
except (ZoneInfoNotFoundError, ValueError):
    raise SystemExit(f"plane: invalid project timezone {tz_name!r}")
clock=os.environ.get("TICKET_PROVIDER_NOW", "").strip()
if clock:
    try: now=datetime.datetime.fromisoformat(clock.replace("Z", "+00:00"))
    except ValueError: raise SystemExit(f"plane: invalid TICKET_PROVIDER_NOW {clock!r}")
    if now.tzinfo is None: raise SystemExit("plane: TICKET_PROVIDER_NOW must include a UTC offset")
else:
    now=datetime.datetime.now(datetime.timezone.utc)
today=now.astimezone(calendar_tz).date()
def boundary(value):
    try: return datetime.date.fromisoformat(str(value)[:10])
    except (TypeError, ValueError): return None
def current(c):
    start,end=boundary(c.get("start_date")),boundary(c.get("end_date"))
    return bool(start and end and start <= today <= end)
active=sorted((c for c in rows if current(c)), key=lambda c:(str(c.get("start_date") or ""),str(c.get("id") or "")), reverse=True)
m=active[0] if active else {}
print(json.dumps({"id":m.get("id", ""),"name":m.get("name", ""),"state":"active" if m else "inactive"}))'
}

# Operator aliases -> their canonical normalized target. Aliases never own a
# concrete lane name, so they cannot drift away from role.yaml.
canonical_state_target() {
  case "$1" in
    needs_attention|waiting_reply) printf 'awaiting_decision\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Normalized target -> LANE (the lane band it lands in, empty when the lane
# does not change) and LABEL (the lifecycle label it adds, empty for none).
state_target_plan() {
  case "$1" in
    backlog|unstarted|started|completed|cancelled) LANE="$1"; LABEL="" ;;
    in_review)         LANE=started; LABEL="$LABEL_REVIEW" ;;
    awaiting_decision) LANE="";      LABEL="$LABEL_NEEDS_INPUT" ;;
    *) die "invalid normalized state: $1" ;;
  esac
}

# pick_lane BAND NORMALIZED — read the project's states JSON on stdin and print
# exactly one concrete Plane state as JSON {id,state,state_type}. A configured
# name must exist in the band's group; it never falls back to another state in
# the same group. An unnamed band is safe only when its group has one member.
pick_lane() {
  case "$1" in
    completed) nm="$SM_DONE" ;;
    cancelled) nm="$SM_CANCELLED" ;;
    started)   nm="$SM_STARTED" ;;
    unstarted) nm="$SM_UNSTARTED" ;;
    backlog)   nm="$SM_BACKLOG" ;;
    *) die "invalid lane band: $1" ;;
  esac
  GRP="$1" NM="$nm" WANT="$2" python3 -c 'import sys,json,os
d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
grp=os.environ["GRP"]; nm=os.environ.get("NM","").strip(); want=os.environ["WANT"]
grouped=[s for s in rows if s.get("group")==grp]
if nm:
    candidates=[s for s in grouped if str(s.get("name","")).strip().casefold()==nm.casefold()]
    if len(candidates) != 1:
        raise SystemExit(f"plane: exact Plane state {nm!r} for normalized {want!r} was not resolved uniquely in group {grp!r}")
else:
    candidates=grouped
    if len(candidates) != 1:
        names=", ".join(str(s.get("name") or "") for s in candidates) or "none"
        raise SystemExit(f"plane: normalized state {want!r} is ambiguous in group {grp!r} ({names}); configure ticket_provider.{grp}")
state_id=str(candidates[0].get("id") or "")
if not state_id:
    raise SystemExit(f"plane: resolved Plane state for normalized {want!r} has no id")
print(json.dumps({"id":state_id,"state":str(candidates[0].get("name") or ""),
                  "state_type":str(candidates[0].get("group") or "")},
                 separators=(",",":")))'
}

# pick_label NAME — read the project's labels JSON on stdin and print the id of
# the one label with exactly that name. Lifecycle labels are board furniture:
# a missing one is refused, never created here.
pick_label() {
  LABEL_NAME="$1" python3 -c 'import sys,json,os
d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
name=os.environ["LABEL_NAME"]
hits=[str(x["id"]) for x in rows if isinstance(x,dict) and x.get("id") and x.get("name")==name]
if len(hits) != 1:
    detail="does not exist" if not hits else "matches more than one label"
    raise SystemExit(f"plane: lifecycle label {name!r} {detail} on this board; every lifecycle v2 board carries it (add it with px or Plane, never here)")
print(hits[0])'
}

# All Plane ops except the explicit-workspace read below require the bound
# workspace API key; fail fast and clean before any pipe.
case "$OP" in describe_board) ;; *) need_key ;; esac

case "$OP" in
  resolve)
    [ -n "$WS" ] || die "workspace not set (.project.json ticket_provider.workspace or PLANE_WORKSPACE)"
    [ -n "$PROJ" ] || die "project not set (.project.json ticket_provider.board_id; run 42-ticket-provider.sh)"
    PROJECT_DETAIL="$(api GET "projects/$PROJ/")"
    LIVE_IDENTIFIER="$(printf '%s' "$PROJECT_DETAIL" | python3 -c 'import sys,json
try: print(str(json.load(sys.stdin).get("identifier") or ""))
except Exception: print("")')"
    [ -n "$LIVE_IDENTIFIER" ] || die "live Plane project omitted its authoritative identifier"
    printf '{"provider":"plane","board_id":"%s","board_url":"%s/%s/projects/%s/issues/","identifier":"%s"}\n' \
      "$PROJ" "$BASE" "$WS" "$PROJ" "$LIVE_IDENTIFIER"
    ;;

  active_milestone)
    [ -n "$PROJ" ] || die "project not set"
    api_all "projects/$PROJ/cycles/" | current_cycle
    ;;

  resolve_state)
    # Read-only validation of a configured transition target; never mutates.
    # A hold leaves the lane unchanged, so its id/state/state_type are empty.
    TARGET="$(canonical_state_target "${1:?usage: resolve_state <normalized-state>}")"
    state_target_plan "$TARGET"
    [ -n "$PROJ" ] || die "ticket_provider.project not set"
    LANE_JSON='{"id":"","state":"","state_type":""}'
    [ -z "$LANE" ] || LANE_JSON="$(api_all "projects/$PROJ/states/" | pick_lane "$LANE" "$TARGET")"
    LABEL_ID=""
    [ -z "$LABEL" ] || LABEL_ID="$(api_all "projects/$PROJ/labels/" | pick_label "$LABEL")"
    printf '%s' "$LANE_JSON" | NORMALIZED="$TARGET" LABEL="$LABEL" LABEL_ID="$LABEL_ID" python3 -c 'import json,os,sys
out=json.load(sys.stdin); out["normalized"]=os.environ["NORMALIZED"]
if os.environ["LABEL"]:
    out["label"]=os.environ["LABEL"]; out["label_id"]=os.environ["LABEL_ID"]
print(json.dumps(out,separators=(",",":")))'
    ;;

  list_labels)
    [ -n "$PROJ" ] || die "project not set"
    api_all "projects/$PROJ/labels/" | python3 -c 'import json,sys
rows=json.load(sys.stdin)
print(json.dumps([{"id":x["id"],"name":x["name"]} for x in rows if isinstance(x,dict) and x.get("id") and x.get("name")]))'
    ;;

  list_issues)
    [ -n "$PROJ" ] || die "project not set"
    # Plane v1 returns issue.state as a bare UUID, so join against the states map.
    STATES="$(api_all "projects/$PROJ/states/")"
    LABELS="$(api_all "projects/$PROJ/labels/")"
    ISSUES="$(api_all "projects/$PROJ/issues/")"
    MILESTONE="$(api_all "projects/$PROJ/cycles/" | current_cycle)"
    MILESTONE_ID="$(printf '%s' "$MILESTONE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id", ""))')"
    MILESTONE_ISSUES='[]'
    if [ -n "$MILESTONE_ID" ]; then
      MILESTONE_ISSUES="$(api_all "projects/$PROJ/cycles/$MILESTONE_ID/cycle-issues/")"
    fi
    printf '%s\0%s\0%s\0%s\0%s' "$STATES" "$LABELS" "$ISSUES" "$MILESTONE" "$MILESTONE_ISSUES" \
      | BASE="$BASE" WS="$WS" PROJ="$PROJ" python3 -c 'import sys,json,os
parts=sys.stdin.buffer.read().split(b"\0",4)
srows=json.loads(parts[0] or "{}"); srows=srows if isinstance(srows,list) else srows.get("results", []) if isinstance(srows,dict) else []
smap={s.get("id"):(s.get("name",""),s.get("group","")) for s in srows}
label_rows=json.loads(parts[1] or "[]")
label_rows=label_rows if isinstance(label_rows,list) else label_rows.get("results", [])
label_map={str(x["id"]):str(x["name"]) for x in label_rows if isinstance(x,dict) and x.get("id") and x.get("name")}
label_names=list(label_map.values())
def labels(issue):
    raw=issue.get("labels") or []
    if not isinstance(raw,list): raise SystemExit("plane: issue labels were not a list")
    names=[]
    for item in raw:
        identifier=str(item.get("id") or "") if isinstance(item,dict) else str(item)
        supplied=item.get("name") if isinstance(item,dict) else None
        if identifier:
            name=label_map.get(identifier)
            if not name: raise SystemExit(f"plane: issue label {identifier!r} could not be resolved on project")
            if supplied is not None and supplied != name: raise SystemExit(f"plane: issue label {identifier!r} name disagreed with project catalog")
        else:
            name=supplied
            if not isinstance(name,str) or label_names.count(name) != 1:
                raise SystemExit(f"plane: issue label {identifier!r} could not be resolved uniquely on project")
        if name not in names: names.append(name)
    return names
def relations(issue):
    return {k:issue[k] for k in ("parent", "parent_id", "relations", "issue_relations", "blocked_by", "blocking", "depends_on", "dependencies") if k in issue}
d=json.loads(parts[2] or "{}"); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
milestone=json.loads(parts[3] or "{}"); milestone_id=str(milestone.get("id") or ""); milestone_name=str(milestone.get("name") or "")
md=json.loads(parts[4] or "{}"); mrows=md if isinstance(md,list) else md.get("results", []) if isinstance(md,dict) else []
member_ids={str(issue.get("id") or "") for issue in mrows}
base,ws,proj=os.environ["BASE"],os.environ["WS"],os.environ["PROJ"]
out=[]
for n in rows:
    iid=n.get("id","")
    state=n.get("state",""); state=state.get("id") if isinstance(state,dict) else state
    name,group=smap.get(state,("",""))
    out.append({"id":iid,"key":n.get("sequence_id",iid),
                "title":n.get("name",""),"state":name,"state_type":group,
                "labels":labels(n), **relations(n),
                "updated_at":n.get("updated_at",""),"assignee":"",
                "active_milestone_id":milestone_id,
                "active_milestone_name":milestone_name,
                "in_active_milestone":bool(milestone_id and str(iid) in member_ids),
                "url":base+"/"+ws+"/projects/"+proj+"/issues/"+str(iid)})
print(json.dumps(out))'
    ;;

  get_issue)
    ID="${1:?usage: get_issue <id>}"
    STATES="$(api_all "projects/$PROJ/states/")"
    LABELS="$(api_all "projects/$PROJ/labels/")"
    ISSUE="$(api GET "projects/$PROJ/issues/$ID/")"
    COMM="$(api_all "projects/$PROJ/issues/$ID/comments/" 2>/dev/null || echo '[]')"
    ATTACH="$(api_all "projects/$PROJ/issues/$ID/issue-attachments/" 2>/dev/null || echo '[]')"
    # Relations (blocked_by, blocking, relates_to, duplicate, start_*/finish_*) live on
    # their own endpoint, never on the issue row. Plane answers from both ends of a
    # row, so one read sees every relation the item takes part in (px link list reads
    # the same). Each related item is hydrated to key/title/state so a PM can tell an
    # open blocker from a finished one. A failed read is reported, never hidden as "none".
    REL_ERR=""
    REL="$(api GET "projects/$PROJ/work-items/$ID/relations/" 2>/dev/null)" || { REL='{}'; REL_ERR="relations endpoint could not be read"; }
    RELATED=""
    for pair in $(printf '%s' "$REL" | PROJ="$PROJ" python3 -c 'import sys,json,os
d=json.loads(sys.stdin.read() or "{}")
seen=set()
for rows in (d.values() if isinstance(d,dict) else []):
    for r in (rows if isinstance(rows,list) else []):
        rid=str((r or {}).get("issue_id") or (r or {}).get("id") or "")
        pid=str((r or {}).get("project_id") or (r or {}).get("project") or os.environ["PROJ"])
        if rid and (pid,rid) not in seen:
            seen.add((pid,rid)); print(pid+":"+rid)' 2>/dev/null); do
      rp="${pair%%:*}"; ri="${pair#*:}"
      row="$(api GET "projects/$rp/issues/$ri/" 2>/dev/null)" || row="{\"id\":\"$ri\",\"unreadable\":true}"
      RELATED="$RELATED$(printf '%s' "$row" | tr -d '\n')
"
    done
    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s' "$STATES" "$LABELS" "$ISSUE" "$COMM" "$ATTACH" "$REL" "$RELATED" "$REL_ERR" | python3 -c 'import sys,json,re
parts=sys.stdin.buffer.read().split(b"\0",7)
srows=json.loads(parts[0] or "{}"); srows=srows if isinstance(srows,list) else srows.get("results", []) if isinstance(srows,dict) else []
smap={s.get("id"):(s.get("name",""),s.get("group","")) for s in srows}
label_rows=json.loads(parts[1] or "[]")
label_rows=label_rows if isinstance(label_rows,list) else label_rows.get("results", [])
label_map={str(x["id"]):str(x["name"]) for x in label_rows if isinstance(x,dict) and x.get("id") and x.get("name")}
label_names=list(label_map.values())
i=json.loads(parts[2] or "{}"); c=json.loads(parts[3] or "[]"); a=json.loads(parts[4] or "[]")
raw=i.get("labels") or []
if not isinstance(raw,list): raise SystemExit("plane: issue labels were not a list")
labels=[]
for item in raw:
    identifier=str(item.get("id") or "") if isinstance(item,dict) else str(item)
    supplied=item.get("name") if isinstance(item,dict) else None
    if identifier:
        name=label_map.get(identifier)
        if not name: raise SystemExit(f"plane: issue label {identifier!r} could not be resolved on project")
        if supplied is not None and supplied != name: raise SystemExit(f"plane: issue label {identifier!r} name disagreed with project catalog")
    else:
        name=supplied
        if not isinstance(name,str) or label_names.count(name) != 1:
            raise SystemExit(f"plane: issue label {identifier!r} could not be resolved uniquely on project")
    if name not in labels: labels.append(name)
relations={k:i[k] for k in ("parent", "parent_id", "issue_relations", "blocked_by", "blocking", "depends_on", "dependencies") if k in i}
rel=json.loads(parts[5] or "{}"); rel=rel if isinstance(rel,dict) else {}
related={}
for line in (parts[6] or b"").decode().splitlines():
    if not line.strip(): continue
    r=json.loads(line); related[str(r.get("id",""))]=r
def hydrate(r):
    rid=str((r or {}).get("issue_id") or (r or {}).get("id") or ""); x=related.get(rid,{})
    st=x.get("state",""); st=st.get("id") if isinstance(st,dict) else st
    sname,sgroup=smap.get(st,("",""))
    out={"id":rid,"key":x.get("sequence_id",""),"title":x.get("name",""),"state":sname,"state_type":sgroup,
         "project_id":str((r or {}).get("project_id") or x.get("project") or "")}
    if x.get("unreadable"): out["unreadable"]=True
    return out
relations["relations"]={t:[hydrate(r) for r in rows_] for t,rows_ in rel.items() if isinstance(rows_,list) and rows_}
if parts[7]: relations["relations_error"]=parts[7].decode()
rows=c if isinstance(c,list) else c.get("results", []) if isinstance(c,dict) else []
arows=a if isinstance(a,list) else a.get("results", []) if isinstance(a,dict) else []
def strip(h): return re.sub(r"<[^>]+>","",h or "").strip()
state=i.get("state",""); state=state.get("id") if isinstance(state,dict) else state
name,group=smap.get(state,("",""))
desc=strip(i.get("description_html",""))
cs=[{"id":x.get("id",""),"body":strip(x.get("comment_html","")),"author":""} for x in rows]
ats=[]
for x in arows:
    attrs=x.get("attributes") or {}
    ats.append({"id":x.get("id",""),"name":attrs.get("name",x.get("name","")),
                "type":attrs.get("type",x.get("type","")),
                "size":attrs.get("size",x.get("size",0)),"asset":x.get("asset",""),
                "url":x.get("asset_url",x.get("url","")),
                "created_at":x.get("created_at",""),"updated_at":x.get("updated_at",""),
                "is_uploaded":x.get("is_uploaded",False)})
print(json.dumps({"id":i.get("id",""),"key":i.get("sequence_id",""),"title":i.get("name",""),
                  "description":desc,"acceptance":desc,
                  "state":name,"state_type":group,"labels":labels,**relations,
                  "comments":cs,"attachments":ats}))'
    ;;

  comment)
    ID="${1:?usage: comment <id> <body>}"; BODY="${2:?}"
    api POST "projects/$PROJ/issues/$ID/comments/" \
      "$(python3 -c 'import json,sys; print(json.dumps({"comment_html":"<p>"+sys.argv[1]+"</p>"}))' "$BODY")" \
      | EXPECTED_ID="$ID" python3 -c 'import sys,json,os
comment=json.load(sys.stdin)
if not isinstance(comment,dict):
    raise SystemExit("plane: comment response was not an object")
comment_id=comment.get("id")
if not isinstance(comment_id,str) or not comment_id.strip():
    raise SystemExit("plane: comment response omitted its comment id")
for key in ("issue", "issue_id"):
    if key not in comment:
        continue
    linked=comment[key]
    linked_id=linked.get("id") if isinstance(linked,dict) else linked
    if not isinstance(linked_id,str) or linked_id.strip()!=os.environ["EXPECTED_ID"]:
        raise SystemExit("plane: comment response identified a different issue")
print(comment_id.strip())'
    ;;

  transition)
    ID="${1:?usage: transition <id> <normalized-state>}"
    TARGET="$(canonical_state_target "${2:?usage: transition <id> <normalized-state>}")"
    state_target_plan "$TARGET"
    [ -n "$PROJ" ] || die "ticket_provider.project not set"
    STATES="$(api_all "projects/$PROJ/states/")"
    SID=""; LABEL_ID=""
    if [ -n "$LANE" ]; then
      LANE_JSON="$(printf '%s' "$STATES" | pick_lane "$LANE" "$TARGET")"
      SID="$(printf '%s' "$LANE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    fi
    if [ -z "$LABEL" ]; then
      BODY="$(printf '{"state":"%s"}' "$SID")"
    else
      LABEL_ID="$(api_all "projects/$PROJ/labels/" | pick_label "$LABEL")"
      # Plane's issue PATCH replaces the whole labels list, so the issue is
      # read immediately before the write and only this label is added to that
      # fresh set: agent:working and lifecycle:triaged written by others survive.
      FRESH="$(api GET "projects/$PROJ/issues/$ID/")"
      PLAN="$(printf '%s\0%s' "$FRESH" "$STATES" | EXPECTED_ID="$ID" SID="$SID" LABEL_ID="$LABEL_ID" TARGET="$TARGET" python3 -c 'import json,os,sys
parts=sys.stdin.buffer.read().split(b"\0",1)
target=os.environ["TARGET"]; sid=os.environ["SID"]; label_id=os.environ["LABEL_ID"]
try:
    issue=json.loads(parts[0] or b"{}")
except ValueError as exc:
    raise SystemExit(f"plane: pre-write read was not valid JSON ({exc}); nothing was written")
if not isinstance(issue,dict) or str(issue.get("id") or "") != os.environ["EXPECTED_ID"]:
    raise SystemExit("plane: pre-write read did not identify the requested issue; nothing was written")
srows=json.loads(parts[1] or b"[]"); srows=srows if isinstance(srows,list) else srows.get("results", []) if isinstance(srows,dict) else []
groups={str(s.get("id") or ""):str(s.get("group") or "") for s in srows}
state=issue.get("state",""); state=str(state.get("id") or "") if isinstance(state,dict) else str(state or "")
group=groups.get(state) or "unknown"
if not sid and group not in ("unstarted","started"):
    raise SystemExit(f"plane: {target} is a hold and applies only to a Todo or In Progress ticket (this one is in group {group!r}); nothing was written")
raw=issue.get("labels") or []
if not isinstance(raw,list):
    raise SystemExit("plane: issue labels were not a list; nothing was written")
ids=[]
for item in raw:
    ident=str(item.get("id") or "") if isinstance(item,dict) else str(item)
    if ident and ident not in ids: ids.append(ident)
body={}
if sid: body["state"]=sid
if label_id not in ids: body["labels"]=ids+[label_id]
if body:
    print("patch\t"+json.dumps(body,separators=(",",":")))
else:
    sequence=str(issue.get("sequence_id") or "")
    if not sequence:
        raise SystemExit("plane: pre-write read omitted its sequence id")
    print("noop\t"+sequence)')"
      case "$PLAN" in
        noop*) printf 'ok %s\n' "${PLAN#*	}"; exit 0 ;;
        patch*) BODY="${PLAN#*	}" ;;
        *) die "transition could not plan its write; nothing was written" ;;
      esac
    fi
    # Without a version or precondition guard, a repeated PATCH can stomp a
    # concurrent actor, so exactly one PATCH mutation attempt is ever sent.
    # The live read-back after that attempt is the only success proof: an exact
    # same-issue match on the intended state id (and the intended label, when
    # the target adds one) yields `ok`. A 2xx PATCH whose read-back disagrees
    # is reported as concurrent divergence; an ambiguous (transport-level or
    # non-2xx) PATCH may still be confirmed landed by an exact read-back. Any
    # other read-back outcome fails without a second PATCH.
    # Subshell: a transport-level die inside api must not kill this op.
    if ( api PATCH "projects/$PROJ/issues/$ID/" "$BODY" ) >/dev/null; then
      PATCH_2XX=1
    else
      PATCH_2XX=0
    fi
    if ! READBACK="$(api GET "projects/$PROJ/issues/$ID/")"; then
      die "transition read-back failed after the single PATCH attempt; refusing to repeat the PATCH"
    fi
    if ! READBACK_RESULT="$(printf '%s' "$READBACK" | EXPECTED_ID="$ID" EXPECTED_SID="$SID" EXPECTED_LABEL="$LABEL_ID" python3 -c 'import sys,json,os
try:
    d=json.load(sys.stdin)
except (TypeError, ValueError) as exc:
    raise SystemExit(f"plane: transition read-back was not valid JSON: {exc}")
if not isinstance(d,dict) or str(d.get("id") or "") != os.environ["EXPECTED_ID"]:
    raise SystemExit("plane: transition read-back did not identify the requested issue")
sid=os.environ["EXPECTED_SID"]; label_id=os.environ["EXPECTED_LABEL"]
state=d.get("state", "")
actual=str(state.get("id") or "") if isinstance(state,dict) else str(state or "")
if sid and not actual:
    raise SystemExit("plane: transition read-back omitted its state id")
raw=d.get("labels") or []
labels={str(x.get("id") or "") if isinstance(x,dict) else str(x) for x in (raw if isinstance(raw,list) else [])}
if sid and actual != sid:
    print("mismatch\tstate\t"+actual)
elif label_id and label_id not in labels:
    print("mismatch\tlabel\t"+label_id)
else:
    sequence=str(d.get("sequence_id") or "")
    if not sequence:
        raise SystemExit("plane: transition read-back omitted its sequence id")
    print("match\t"+sequence)')"; then
      die "transition read-back could not be verified after the single PATCH attempt; refusing to repeat the PATCH"
    fi
    case "$READBACK_RESULT" in
      match*)
        printf 'ok %s\n' "${READBACK_RESULT#*	}"
        ;;
      mismatch*)
        DETAIL="${READBACK_RESULT#*	}"; KIND="${DETAIL%%	*}"; ACTUAL="${DETAIL#*	}"
        if [ "$KIND" = label ]; then
          WHAT="read-back labels did not include $LABEL ($ACTUAL)"
        else
          WHAT="read-back state $ACTUAL did not match intended state id $SID"
        fi
        if [ "$PATCH_2XX" -eq 1 ]; then
          die "transition $WHAT after a 2xx PATCH response; concurrent divergence suspected; refusing to claim the transition completed"
        fi
        die "transition PATCH outcome was ambiguous and the $WHAT; refusing to claim the transition completed"
        ;;
      *)
        die "transition read-back returned an invalid verification outcome; refusing to repeat the PATCH"
        ;;
    esac
    ;;

  describe_board)
    # Read-only board lookup against an EXPLICIT workspace argument, so the
    # .project.json / role.yaml / env workspace precedence can never silently
    # query the wrong workspace. Emits Plane's own identifier, never a guess.
    DWS="${1:?usage: describe_board <workspace> <board_id>}"
    DBID="${2:?usage: describe_board <workspace> <board_id>}"
    DKEYVAR="$(workspace_key "$DWS")"
    DKEY="$(printenv "$DKEYVAR" 2>/dev/null || true)"
    if [ -z "$DKEY" ] && [ -f "$FLEET_ENV" ]; then
      DKEY="$(dotenv_value "$FLEET_ENV" "$DKEYVAR")"
    fi
    [ -n "$DKEY" ] || DKEY="${PLANE_API_KEY:-}"
    DKEY="$(resolve_secret_value "$DKEY")"
    [ -n "$DKEY" ] || die "no Plane API key for workspace '$DWS' (looked for $DKEYVAR)"
    DETAIL="$(curl -fsS "$BASE/api/v1/workspaces/$DWS/projects/$DBID/" \
      -H "X-API-Key: $DKEY" -H "User-Agent: curl/8.0")" \
      || die "describe_board failed for $DWS/$DBID"
    printf '%s' "$DETAIL" | WS="$DWS" BID="$DBID" python3 -c 'import sys, json, os
d = json.load(sys.stdin)
ident = str(d.get("identifier") or "")
if not ident:
    raise SystemExit("plane: live Plane project omitted its authoritative identifier")
print(json.dumps({
    "board_id": str(d.get("id") or os.environ["BID"]),
    "identifier": ident,
    "workspace": os.environ["WS"],
    "name": str(d.get("name") or ""),
}))'
    ;;

  create_board)
    NAME="${1:?usage: create_board <name> <ident> <desc>}"; IDENT="${2:-}"; DESC="${3:-}"
    [ -n "$WS" ] || die "workspace not set"
    EXIST="$(api_all "projects/?per_page=200" | NAME="$NAME" IDENT="$IDENT" python3 -c 'import sys,json,os
d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
name=os.environ["NAME"].strip().lower(); ident=os.environ["IDENT"].upper()
# Repo NAME is the primary key — links an existing repo board even if its
# identifier differs (Plane does not enforce unique names, so this prevents
# duplicate boards). Fall back to identifier match; empty -> create new.
pid=next((p["id"] for p in rows if str(p.get("name","")).strip().lower()==name), "")
if not pid and ident:
    pid=next((p["id"] for p in rows if (p.get("identifier") or "").upper()==ident), "")
print(pid)')"
    LIVE_IDENTIFIER=""
    if [ -n "$EXIST" ]; then PID="$EXIST"; else
      CREATED="$(api POST "projects/" \
        "$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"identifier":sys.argv[2],"description":sys.argv[3]}))' "$NAME" "$IDENT" "$DESC")")"
      PID="$(printf '%s' "$CREATED" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')"
      LIVE_IDENTIFIER="$(printf '%s' "$CREATED" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("identifier","") or "")')"
    fi
    [ -n "$PID" ] || die "create_board failed"
    if [ -z "$LIVE_IDENTIFIER" ]; then
      DETAIL="$(api GET "projects/$PID/")"
      LIVE_IDENTIFIER="$(printf '%s' "$DETAIL" | python3 -c 'import sys,json
try: print(str(json.load(sys.stdin).get("identifier") or ""))
except Exception: print("")')"
    fi
    [ -n "$LIVE_IDENTIFIER" ] || die "live Plane project omitted its authoritative identifier"
    printf '{"board_id":"%s","board_url":"%s/%s/projects/%s/issues/","identifier":"%s"}\n' \
      "$PID" "$BASE" "$WS" "$PID" "$LIVE_IDENTIFIER"
    ;;

  create_issue)
    # File a new ticket on the bound board. Board/workspace come from resolved
    # config, never from an argument. Deliberately NOT idempotent by default:
    # two issues may legitimately share a title. Pass --if-absent to reuse an
    # issue whose title already matches exactly (case-insensitive) instead.
    #
    # Scope: a shared board routes work by exactly one scope label per ticket
    # (e.g. repo:forge). The new ticket is stamped with this role's scope:
    #   --scope <label>                  explicit; must be one of role.yaml board_scope
    #   role.yaml board_scope: [<one>]   the role's own scope
    #   .project.json ticket_provider.scope_label   the repo's scope
    # A role whose board_scope lists several labels must pass --scope. With none
    # of these set the board has no scope convention and no label is stamped.
    # The label must already exist on the board (never created here), and an
    # --if-absent match only counts inside the same scope, so a same-titled
    # ticket in another repo's scope is never reused.
    IF_ABSENT=0; SCOPE_ARG=""
    while :; do
      case "${1:-}" in
        --if-absent) IF_ABSENT=1; shift ;;
        --scope) [ -n "${2:-}" ] || die "usage: create_issue [--if-absent] [--scope <label>] <title> [description]"; SCOPE_ARG="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    TITLE="${1:?usage: create_issue [--if-absent] [--scope <label>] <title> [description]}"; DESC="${2:-}"
    [ -n "$WS" ] || die "workspace not set (.project.json ticket_provider.workspace or PLANE_WORKSPACE)"
    [ -n "$PROJ" ] || die "project not set (.project.json ticket_provider.board_id; run 42-ticket-provider.sh)"
    SCOPE="$(python3 - "$ROLE_YAML" "$SCOPE_ARG" "$(pj_cfg scope_label)" <<'PYSCOPE'
import json, pathlib, re, sys
role_yaml, explicit, project_scope = sys.argv[1:4]
declared = []
p = pathlib.Path(role_yaml)
if p.is_file():
    text = p.read_text()
    m = re.search(r'(?m)^board_scope:[ \t]*(.*)$', text)
    if m:
        inline = m.group(1).strip()
        if inline.startswith("["):
            try: declared = [str(x) for x in json.loads(inline)]
            except ValueError: declared = [x.strip().strip("'\"") for x in inline.strip("[]").split(",") if x.strip()]
        elif inline:
            declared = [inline.strip("'\"")]
        else:
            block = text[m.end():]
            for line in block.splitlines():
                mm = re.match(r'^\s+-\s*(.+?)\s*$', line)
                if mm: declared.append(mm.group(1).strip("'\""))
                elif line.strip() and not line.startswith((" ", "\t")): break
if explicit:
    if declared and explicit not in declared:
        sys.exit(f"plane: --scope {explicit!r} is not in this role's board_scope {declared}")
    print(explicit)
elif len(declared) == 1:
    print(declared[0])
elif len(declared) > 1:
    sys.exit(f"plane: board_scope lists {declared}; pass --scope <label> to say which one this ticket belongs to")
else:
    print(project_scope)
PYSCOPE
)" || exit 1
    SCOPE_ID=""
    if [ -n "$SCOPE" ]; then
      SCOPE_ID="$(api_all "projects/$PROJ/labels/" | SCOPE="$SCOPE" python3 -c 'import sys,json,os
d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
hits=[str(x["id"]) for x in rows if isinstance(x,dict) and x.get("id") and x.get("name")==os.environ["SCOPE"]]
print(hits[0] if len(hits)==1 else ("AMBIGUOUS" if hits else ""))')"
      [ -n "$SCOPE_ID" ] || die "scope label '$SCOPE' does not exist on this board; create it on the board (px or Plane), never ad hoc here"
      [ "$SCOPE_ID" != AMBIGUOUS ] || die "scope label '$SCOPE' matches more than one board label"
    fi
    IID=""; SEQ=""; CREATED=true
    if [ "$IF_ABSENT" = 1 ]; then
      HIT="$(api_all "projects/$PROJ/issues/?per_page=200" | TITLE="$TITLE" SCOPE_ID="$SCOPE_ID" python3 -c 'import sys,json,os
d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("results", []) if isinstance(d,dict) else []
want=os.environ["TITLE"].strip().lower(); sid=os.environ["SCOPE_ID"]
def ids(i): return {str(x.get("id") if isinstance(x,dict) else x) for x in (i.get("labels") or [])}
m=next((i for i in rows if (i.get("name") or "").strip().lower()==want and (not sid or sid in ids(i))), None)
print((str(m.get("id","")) + " " + str(m.get("sequence_id","") or "")) if m else "")')"
      if [ -n "$HIT" ]; then IID="${HIT%% *}"; SEQ="${HIT#* }"; CREATED=false; fi
    fi
    if [ -z "$IID" ]; then
      NEW="$(api POST "projects/$PROJ/issues/" \
        "$(python3 -c 'import html,json,sys
body={"name": sys.argv[1]}
desc=sys.argv[2]
if desc: body["description_html"]="<p>"+html.escape(desc)+"</p>"
if sys.argv[3]: body["labels"]=[sys.argv[3]]
print(json.dumps(body))' "$TITLE" "$DESC" "$SCOPE_ID")" \
        | SCOPE_ID="$SCOPE_ID" python3 -c 'import sys,json,os
d=json.load(sys.stdin); sid=os.environ["SCOPE_ID"]
got={str(x.get("id") if isinstance(x,dict) else x) for x in (d.get("labels") or [])}
print(str(d.get("id","")) + " " + str(d.get("sequence_id","") or "") + " " + ("ok" if (not sid or sid in got) else "unstamped"))')"
      IID="${NEW%% *}"; REST="${NEW#* }"; SEQ="${REST%% *}"
      [ -n "$IID" ] || die "create_issue failed"
      [ "${REST##* }" = ok ] || die "created issue $SEQ ($IID) but Plane did not apply scope label '$SCOPE'; label it by hand before anyone routes it"
    fi
    [ -n "$IID" ] || die "create_issue failed"
    SCOPE_JSON="null"; [ -z "$SCOPE" ] || SCOPE_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$SCOPE")"
    printf '{"issue_id":"%s","key":"%s","issue_url":"%s/%s/projects/%s/issues/%s","created":%s,"scope_label":%s}\n' \
      "$IID" "$SEQ" "$BASE" "$WS" "$PROJ" "$IID" "$CREATED" "$SCOPE_JSON"
    ;;

  *) die "unknown op: $OP" ;;
esac
