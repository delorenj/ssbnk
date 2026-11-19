# shellcheck shell=bash
# Ticket-provider adapter dispatcher — the single seam between the Scrum Master
# sentinel engine and a concrete ticket system (Plane | Trello).
#
# The engine NEVER calls a provider directly. It calls `tp <op> [args...]`,
# which dispatches to providers/<provider>.sh. Repo-root .project.json owns the
# provider/board binding; role.yaml is not an authority for dispatch.
#
# Contract (operations every provider must implement):
#   resolve                       -> JSON {provider, board_id, board_url}
#   active_milestone              -> JSON {id, name, state}
#   list_issues                   -> JSON [ {id,key,title,state,state_type,
#                                            updated_at,assignee,url,...}, ... ]
#                                    (plane also: labels:[name...] resolved through
#                                    the project catalog, and parent when present)
#   get_issue <issue-ref>         -> JSON {id,key,title,description,acceptance,
#                                          state,state_type,comments:[...],
#                                          attachments:[...]}
#                                    (plane also: labels, parent, and
#                                    relations:{blocked_by|blocking|relates_to|...:
#                                    [{id,key,title,state,state_type}]}; a failed
#                                    relations read sets relations_error)
#   resolve_state <normalized>    -> JSON {id,state,state_type,normalized}
#                                    Read-only validation of a configured
#                                    transition target; never mutates an issue.
#                                    (plane also: label,label_id for a target
#                                    that adds a lifecycle label; a hold leaves
#                                    the lane unchanged, so its id/state/
#                                    state_type are empty)
#   comment <issue-ref> <body>    -> prints comment id
#   transition <issue-ref> <normalized>
#                                 -> resolves id/human key, then moves issue; normalized in
#                                     backlog|unstarted|started|in_review|completed|
#                                     cancelled|awaiting_decision;
#                                    needs_attention/waiting_reply are aliases
#                                    for awaiting_decision. On Plane (Krebs
#                                    lifecycle v2, five stock lanes) in_review
#                                    is In Progress + lifecycle:review and
#                                    awaiting_decision is a hold:
#                                    +lifecycle:needs-input, lane unchanged.
#                                    (lifecycle:human is the owner's own hold:
#                                    never written, and a label write onto a
#                                    ticket carrying it is refused.)
#   create_board <name> <id> <d>  -> JSON {board_id, board_url}
#   describe_board <ws> <board_id>
#                                 -> JSON {board_id, identifier, workspace,
#                                          name}
#                                    Read-only lookup against an EXPLICIT
#                                    workspace, so no ambient binding can send
#                                    the query elsewhere. `identifier` is
#                                    whatever the provider itself reports, and
#                                    is empty when the provider mints none
#                                    (Trello). Never a locally-computed guess.
#   create_issue [--if-absent] <title> [desc]
#                                 -> JSON {issue_id, key, issue_url, created}
#                                    Files a new ticket on the bound board.
#                                    NOT idempotent by default (two issues may
#                                    share a title); --if-absent reuses an exact
#                                    title match and reports created:false.
#                                    plane: stamps the role's scope label
#                                    (role.yaml board_scope, else .project.json
#                                    scope_label; --scope <label> picks one when
#                                    board_scope lists several) and reports
#                                    scope_label; --if-absent matches only
#                                    inside that scope.
#
# Each provider reads its credentials from the environment (see providers/*.sh
# headers) and the board binding from repo-root .project.json.

# Read the human key prefix from the project binding. Plane list_issues exposes
# sequence_id as a number while people use PREFIX-number; the dispatcher owns
# that provider-neutral seam so callers never have to know the native id shape.
tp_project_identifier() {
  local role_dir
  role_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  python3 - "$role_dir" <<'PY' 2>/dev/null
import json
import pathlib
import sys

start = pathlib.Path(sys.argv[1]).resolve()
for parent in [start, *start.parents]:
    manifest = parent / ".project.json"
    if manifest.is_file():
        try:
            provider = json.loads(manifest.read_text()).get("ticket_provider") or {}
            print(str(provider.get("identifier") or ""))
        except Exception:
            print("")
        break
else:
    print("")
PY
}

# Resolve an id, provider key, or project-prefixed numeric key against the
# normalized list contract. Mutating operations fail before reaching a provider
# if the reference is absent or ambiguous.
tp_resolve_issue_reference() {
  local name="$1" impl="$2" reference="$3" identifier issues
  identifier="$(tp_project_identifier)"
  issues="$(TICKET_PROVIDER="$name" sh "$impl" list_issues)" || return 1
  TP_REFERENCE="$reference" TP_IDENTIFIER="$identifier" python3 -c 'import json,os,sys
reference=os.environ["TP_REFERENCE"].strip(); identifier=os.environ.get("TP_IDENTIFIER", "").strip()
try:
    data=json.load(sys.stdin)
except Exception as exc:
    raise SystemExit(f"tp: could not resolve issue reference {reference!r}: list_issues returned invalid JSON ({exc})")
rows=data if isinstance(data,list) else data.get("results", []) if isinstance(data,dict) else []
want=reference.casefold(); matches=[]
for issue in rows:
    native=str(issue.get("id") or "").strip(); key=str(issue.get("key") or "").strip()
    aliases={native.casefold(), key.casefold()}
    if identifier and key.isdigit():
        aliases.add(f"{identifier}-{key}".casefold())
    if native and want in aliases:
        matches.append(native)
matches=list(dict.fromkeys(matches))
if len(matches) != 1:
    detail="not found" if not matches else "ambiguous"
    raise SystemExit(f"tp: could not resolve issue reference {reference!r}: {detail}")
print(matches[0])' <<EOF
$issues
EOF
}

# Resolve the provider from the repo-root .project.json (the SOT). A provisioner
# can supply a provider explicitly only when the manifest has no type yet.
# No missing or malformed binding defaults to Plane.
tp_provider_name() {
  # .project.json ticket_provider.type — walk up from the role dir to repo root.
  local role_dir
  role_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  if [ -n "$role_dir" ]; then
    python3 - "$role_dir" <<'PY' 2>/dev/null
import sys, json, pathlib
start = pathlib.Path(sys.argv[1]).resolve()
for parent in [start, *start.parents]:
    f = parent / ".project.json"
    if f.is_file():
        try:
            value = json.loads(f.read_text())
            if not isinstance(value, dict):
                print("__TP_INVALID_MANIFEST__")
            else:
                binding = value.get("ticket_provider", {})
                if not isinstance(binding, dict):
                    print("__TP_INVALID_MANIFEST__")
                elif "type" not in binding or binding["type"] == "":
                    board = binding.get("board_id", "")
                    if not isinstance(board, str) or board.strip():
                        print("__TP_UNTYPED_BOUND__")
                    else:
                        print("__TP_ABSENT_BINDING__")
                else:
                    print(binding["type"] if isinstance(binding["type"], str) else "__TP_INVALID_MANIFEST__")
        except Exception:
            print("__TP_INVALID_MANIFEST__")
        break
else:
    print("__TP_NO_MANIFEST__")
PY
  fi
}

# A canonical manifest with no board must not fall through to a stale role.yaml
# board. Only board creation and explicit board lookup can run without one.
tp_board_id() {
  local role_dir
  role_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  python3 - "$role_dir" <<'PY' 2>/dev/null
import json, pathlib, sys
start = pathlib.Path(sys.argv[1]).resolve()
for parent in [start, *start.parents]:
    f = parent / ".project.json"
    if f.is_file():
        try:
            binding = json.loads(f.read_text()).get("ticket_provider")
            print(binding.get("board_id") if isinstance(binding, dict) and isinstance(binding.get("board_id"), str) else "")
        except Exception:
            print("")
        break
else:
    print("")
PY
}

# Read canonical Plane workspace without consulting role.yaml or ambient env.
# An empty canonical workspace cannot authorize a board-bound Plane request.
tp_plane_workspace() {
  local role_dir
  role_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  python3 - "$role_dir" <<'PY' 2>/dev/null
import json, pathlib, sys
start = pathlib.Path(sys.argv[1]).resolve()
for parent in [start, *start.parents]:
    f = parent / ".project.json"
    if f.is_file():
        try:
            binding = json.loads(f.read_text()).get("ticket_provider")
            workspace = binding.get("workspace") if isinstance(binding, dict) else None
            print(workspace.strip() if isinstance(workspace, str) else "")
        except Exception:
            print("")
        break
else:
    print("")
PY
}

# Directory holding provider implementations (sibling of this lib).
tp_providers_dir() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/../providers\n' "$here"
}

# Dispatch one operation to the active provider.
tp() {
  local op="${1:-}"; shift || true
  [ -n "$op" ] || { echo "tp: missing operation" >&2; return 2; }

  # Reject blank references before provider discovery or list_issues. Besides
  # being invalid input, an empty value can equal a provider's missing `key`
  # field and must never become authority to read or mutate that issue.
  case "$op" in
    resolve_state)
      [ "$#" -eq 1 ] || { echo "tp: resolve_state requires one normalized state" >&2; return 2; }
      if [[ "$1" =~ ^[[:space:]]*$ ]]; then
        echo "tp: resolve_state requires one normalized state" >&2
        return 2
      fi
      tp_is_valid_state "$1" || { echo "tp: invalid normalized state '$1'" >&2; return 2; }
      ;;
    get_issue|comment|transition)
      [ "$#" -ge 1 ] || { echo "tp: $op requires a non-blank issue reference" >&2; return 2; }
      if [[ "$1" =~ ^[[:space:]]*$ ]]; then
        echo "tp: $op requires a non-blank issue reference" >&2
        return 2
      fi
      ;;
  esac

  if [ "$op" = transition ]; then
    [ "$#" -ge 2 ] || { echo "tp: transition requires a normalized state" >&2; return 2; }
    tp_is_valid_state "$2" || { echo "tp: invalid normalized state '$2'" >&2; return 2; }
  fi

  local name impl
  name="$(tp_provider_name)"
  case "$name" in
    __TP_NO_MANIFEST__|__TP_ABSENT_BINDING__|"")
      if [ "${TP_PROVISIONING:-0}" = "1" ]; then name="${TICKET_PROVIDER:-}"; else name=""; fi
      ;;
    __TP_INVALID_MANIFEST__|__TP_UNTYPED_BOUND__)
      echo "tp: unsupported ticket provider binding in .project.json; supported: plane, trello" >&2
      return 2
      ;;
    *)
      if [ -n "${TICKET_PROVIDER:-}" ] && [ "$TICKET_PROVIDER" != "$name" ]; then
        echo "tp: explicit provider conflicts with .project.json ticket_provider.type" >&2
        return 2
      fi
      ;;
  esac
  case "$name" in
    plane|trello) ;;
    *) echo "tp: unsupported ticket provider '$name' (supported: plane, trello)" >&2; return 2 ;;
  esac
  impl="$(tp_providers_dir)/${name}.sh"

  if [ ! -f "$impl" ]; then
    echo "tp: unknown ticket provider '$name' (no $impl)" >&2
    return 2
  fi

  case "$op" in
    create_board|describe_board) ;;
    *)
      if [ -z "$(tp_board_id)" ]; then
        echo "tp: .project.json ticket_provider.board_id is missing; refusing board-bound $op" >&2
        return 2
      fi
      if [ "$name" = plane ] && [ -z "$(tp_plane_workspace)" ]; then
        echo "tp: .project.json ticket_provider.workspace is missing; refusing board-bound $op" >&2
        return 2
      fi
      ;;
  esac

  case "$op" in
    get_issue|comment|transition)
      local reference native_id
      reference="$1"; shift
      native_id="$(tp_resolve_issue_reference "$name" "$impl" "$reference")" || return 1
      set -- "$native_id" "$@"
      ;;
  esac

  TICKET_PROVIDER="$name" sh "$impl" "$op" "$@"
}

# Normalized states the engine reasons in. Adapters map these to provider terms.
# The six neutral states every board has, then awaiting_decision and its two
# aliases (needs_attention, waiting_reply). Plane boards follow Krebs lifecycle
# v2 (krebs/spec/lifecycle.v2.yaml): five stock lanes, with review and holds
# carried by labels, so plane.sh lands in_review in In Progress plus
# lifecycle:review and awaiting_decision as +lifecycle:needs-input in place.
# lifecycle:human is the owner's hold: agents never add, remove or work it.
# Trello maps both to lanes named in role.yaml.
TP_STATES="backlog unstarted started in_review completed cancelled awaiting_decision needs_attention waiting_reply"

tp_is_valid_state() {
  case " $TP_STATES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}
