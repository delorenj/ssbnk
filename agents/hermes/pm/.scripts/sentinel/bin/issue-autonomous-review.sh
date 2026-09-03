#!/usr/bin/env bash
# Provider-agnostic autonomous adversarial-review decision gate (act, don't wait).
#
# The rigorous, INDEPENDENT ADVERSARIAL review is the normal per-pass path: an
# adversarial microscope that couples the close gate with an independent-reviewer
# drift attestation. A clean adversarial
# verdict is acted on AUTONOMOUSLY -- the loop treats the ticket as done and
# moves on; it never parks the ticket waiting on the operator for approval or
# sign-off. Every adversarial check stays at full strength (locked-intent
# baseline, drift none|minor|significant with significant -> hold, any unresolved
# critical/high finding -> hold, independence, and the close gate as a hard
# automated lock). The ONLY thing removed is the human-approval stall.
#
# A default clean run (no --close) means the loop autonomously treats the ticket
# as done and leaves it in the review lane (the operator's deferred-QA queue).
# --close is OPTIONAL (operator QA sweep): closure goes through the
# ticket-provider adapter (tp transition <id> completed), so the same logic works
# on Linear | Plane | Trello.
#
# Protocol: .scripts/sentinel/docs/autonomous-delegated-review.md
#
# Usage: issue-autonomous-review.sh ISSUE_ID REPORT_FILE [--close]
#
# Exit codes: 0 accepted (treat as done; with --close, transitioned to completed)
#             3 held    2 usage/missing inputs
set -euo pipefail

if [[ "${1:-}" == "" || "${2:-}" == "" ]]; then
  printf 'Usage: %s ISSUE_ID REPORT_FILE [--close]\n' "$0" >&2; exit 2
fi
ISSUE="$1"; REPORT="$2"; CLOSE=0
[[ "${3:-}" == "--close" ]] && CLOSE=1
case "$ISSUE" in *[!A-Za-z0-9_-]*) printf 'Invalid issue id: %s\n' "$ISSUE" >&2; exit 2 ;; esac

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$BIN_DIR/.." && pwd)"          # .scripts/sentinel
SCRIPTS_DIR="$(cd "$ENGINE_DIR/.." && pwd)"      # .scripts
ROLE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
ROLE_YAML="$ROLE_DIR/role.yaml"
ROOT="$(git -C "$ROLE_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

CLOSE_GATE="$BIN_DIR/issue-close-gate.sh"
EVIDENCE="_bmad-output/implementation-artifacts/issue-evidence/$ISSUE.md"

role_mapping_value() {
  python3 - "$ROLE_YAML" "$1" "$2" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
section = sys.argv[2]
key = sys.argv[3]
text = path.read_text(encoding="utf-8") if path.is_file() else ""
lines = text.splitlines()
headers = [
    index
    for index, line in enumerate(lines)
    if re.fullmatch(rf"{re.escape(section)}:\s*(?:#.*)?", line)
]
if not headers:
    print("")
    raise SystemExit(0)
if len(headers) != 1:
    raise SystemExit(f"role config has duplicate top-level {section!r} mappings")
block = []
for line in lines[headers[0] + 1 :]:
    if line.strip() and not line[0].isspace() and not line.lstrip().startswith("#"):
        break
    block.append(line)
content = [
    line
    for line in block
    if line.strip() and not line.lstrip().startswith("#") and line[0].isspace()
]
if not content:
    print("")
    raise SystemExit(0)
direct_indent = min(len(line) - len(line.lstrip()) for line in content)
matches = []
for line in content:
    if len(line) - len(line.lstrip()) != direct_indent:
        continue
    match = re.fullmatch(rf"\s{{{direct_indent}}}{re.escape(key)}:\s*(.*?)\s*", line)
    if match:
        matches.append(match.group(1))
if len(matches) > 1:
    raise SystemExit(f"role config has duplicate {section}.{key} values")
value = matches[0] if matches else ""
value = re.sub(r"\s+#.*$", "", value).strip()
if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
    value = value[1:-1]
print(value.strip())
PY
}
# Informational only: recorded in the ticket comment, never a blocking wait.
# Default 0 (no grace); an operator may set grace_hours>0 to reintroduce one.
ROLE_GRACE_HOURS="$(role_mapping_value reconcile grace_hours)"
GRACE_HOURS="${RECONCILE_GRACE_HOURS:-$ROLE_GRACE_HOURS}"
GRACE_HOURS="$(printf '%s' "${GRACE_HOURS:-0}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
case "$GRACE_HOURS" in
  ''|*[!0-9]*)
    printf "AUTONOMOUS REVIEW: CONFIG INVALID - reconcile.grace_hours must be a nonnegative integer (got '%s').\n" "$GRACE_HOURS" >&2
    exit 3
    ;;
esac
GRACE_HOURS="$(python3 -c 'import sys; print(int(sys.argv[1]))' "$GRACE_HOURS")"

ROLE_AUTO="$(role_mapping_value reconcile auto_review)"
AUTO="${RECONCILE_AUTO_REVIEW:-$ROLE_AUTO}"
AUTO="$(printf '%s' "${AUTO:-true}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
case "$AUTO" in
  true|on) : ;;
  false|off)
    printf 'Autonomous review is disabled (reconcile.auto_review=%s).\n' "$AUTO" >&2
    exit 3
    ;;
  *)
    printf "AUTONOMOUS REVIEW: CONFIG INVALID - reconcile.auto_review must be true|on|false|off (got '%s').\n" "$AUTO" >&2
    exit 3
    ;;
esac
[[ -f "$REPORT" ]]   || { printf 'Missing review report file: %s\n' "$REPORT" >&2; exit 2; }
[[ -f "$EVIDENCE" ]] || { printf 'Missing issue evidence file: %s\n' "$EVIDENCE" >&2; exit 2; }

HOLD=""
hold() { HOLD="${HOLD}${HOLD:+; }$1"; }

# Structural parse of the review report (and the evidence's implementer
# identity): every required H2 exactly once, each authoritative field read
# only as a direct field of its own section. Lookalike bullets or examples in
# other sections can never stand in for -- or override -- the authoritative
# value, and duplicate/missing/blank sections or fields are rejected here,
# before any provider call.
PARSED=""
if ! PARSED="$(python3 - "$REPORT" "$EVIDENCE" <<'PY'
import re
import sys

report_path, evidence_path = sys.argv[1], sys.argv[2]

heading = re.compile(r"^(#{1,6})\s+(.*?)\s*$")


def parse_sections(path):
    with open(path, encoding="utf-8") as stream:
        lines = stream.read().splitlines()
    sections = {}
    order = []
    current = None
    for line in lines:
        match = heading.match(line)
        if match and len(match.group(1)) <= 2:
            current = match.group(2) if len(match.group(1)) == 2 else None
            if current is not None:
                sections.setdefault(current, [])
                order.append(current)
            continue
        if current is not None:
            sections[current].append(line)
    return sections, order


def direct_fields(sections, section, *names):
    found = []
    for line in sections.get(section, []):
        for name in names:
            match = re.fullmatch(
                r"\s*(?:[-*+]\s+)?" + re.escape(name) + r"\s*:\s*(.*?)\s*", line
            )
            if match:
                found.append(match.group(1))
                break
    return found


errors = []
out = {}

sections, order = parse_sections(report_path)
for name in (
    "Reviewer",
    "Locked Intent Baseline",
    "Drift Assessment",
    "Adversarial Findings",
    "Decision",
):
    count = order.count(name)
    if count == 0:
        errors.append(f"report missing section {name}")
    elif count > 1:
        errors.append(f"report has duplicate {name} sections")


def report_field(section, name):
    if order.count(section) != 1:
        return ""
    found = direct_fields(sections, section, name)
    if len(found) != 1:
        errors.append(
            f"report section {section} must contain exactly one"
            f" '{name}:' field (found {len(found)})"
        )
        return ""
    if not found[0]:
        errors.append(f"report field '{name}:' in section {section} is blank")
        return ""
    return found[0]


def first_token(value):
    tokens = value.split()
    return tokens[0].lower() if tokens else ""


out["reviewer"] = report_field("Reviewer", "Reviewer agent")
out["independent"] = first_token(report_field("Reviewer", "Independent of implementer"))
out["drift"] = first_token(report_field("Drift Assessment", "Drift assessment"))
out["findings"] = first_token(report_field("Adversarial Findings", "Critical/high findings"))
out["decision"] = first_token(report_field("Decision", "Decision"))

evidence_sections, evidence_order = parse_sections(evidence_path)
implementer = ""
if evidence_order.count("Issue") != 1:
    errors.append(
        "evidence must contain exactly one Issue section carrying the"
        " implementer identity"
    )
else:
    found = direct_fields(evidence_sections, "Issue", "Worker", "Implemented by")
    if len(found) != 1:
        errors.append(
            "evidence section Issue must contain exactly one implementer"
            " identity ('Worker:' / 'Implemented by:') field"
            f" (found {len(found)})"
        )
    elif not found[0]:
        errors.append("evidence implementer identity in section Issue is blank")
    else:
        implementer = found[0]
out["implementer"] = implementer

for key, value in out.items():
    print("F\t{}\t{}".format(key, value.replace("\t", " ").replace("\n", " ")))
for error in errors:
    print(f"E\t{error}")
PY
)"; then
  hold "review report could not be parsed"
fi

REVIEWER=""; INDEP=""; DRIFT=""; FINDINGS=""; DEC=""; IMPL=""
while IFS="$(printf '\t')" read -r kind key value; do
  case "$kind" in
    E) hold "$key" ;;
    F)
      case "$key" in
        reviewer) REVIEWER="$value" ;;
        independent) INDEP="$value" ;;
        drift) DRIFT="$value" ;;
        findings) FINDINGS="$value" ;;
        decision) DEC="$value" ;;
        implementer) IMPL="$value" ;;
      esac
      ;;
  esac
done <<EOF
$PARSED
EOF
REVIEWER="${REVIEWER:-unknown}"

[[ "$INDEP" == "yes" ]] || hold "reviewer did not attest independence"
[[ -n "$IMPL" && "$IMPL" == "$REVIEWER" ]] && hold "reviewer ($REVIEWER) is the implementer"

case "$DRIFT" in
  none|minor) : ;;
  significant) hold "significant drift from locked intent" ;;
  *) hold "drift assessment missing/invalid ('${DRIFT:-none-found}')"; DRIFT="${DRIFT:-unknown}" ;;
esac
[[ "$FINDINGS" == "none" ]] || hold "unresolved critical/high findings (or field missing)"
# Accept the keyword `accept` as clearing; tolerate the legacy `close`.
[[ "$DEC" == "accept" || "$DEC" == "close" ]] || hold "reviewer decision is not 'accept' (got '${DEC:-none}')"

GATE=fail
if sh "$CLOSE_GATE" "$ISSUE" "$ROOT" >/dev/null 2>&1 </dev/null; then GATE=pass; else hold "close gate failed"; fi

if [[ -n "$HOLD" ]]; then DECISION=held; else DECISION=accepted; fi

if [[ "$DECISION" == "held" ]]; then
  printf 'AUTONOMOUS REVIEW: HOLD for %s\nReasons: %s\n' "$ISSUE" "$HOLD" >&2
  exit 3
fi

PROV="$(role_mapping_value ticket_provider name)"; PROV="${PROV:-}"
if [[ "$CLOSE" -eq 1 ]]; then
  # Optional operator QA sweep: close through the ticket-provider adapter.
  if ! TICKET_PROVIDER="$PROV" bash -c '. "$1"; tp transition "$2" completed' _ "$SCRIPTS_DIR/lib/ticket-provider.sh" "$ISSUE" \
    >/dev/null 2>&1; then
    printf 'AUTONOMOUS REVIEW: CLOSE FAILED for %s - adapter transition failed; issue left open.\n' "$ISSUE" >&2
    exit 1
  fi

  COMMENT_ID=""
  if ! COMMENT_ID="$(TICKET_PROVIDER="$PROV" bash -c '. "$1"; tp comment "$2" "$3"' _ "$SCRIPTS_DIR/lib/ticket-provider.sh" "$ISSUE" \
    "Autonomously accepted by $REVIEWER under the independent adversarial-review protocol (drift: $DRIFT, gate: $GATE, grace ${GRACE_HOURS}h informational). Treated as done; review report: $REPORT." 2>/dev/null)"; then
    printf 'AUTONOMOUS REVIEW: CLOSE INCOMPLETE for %s - transition succeeded, but acceptance comment failed; issue may already be completed.\n' "$ISSUE" >&2
    exit 1
  fi
  if [[ ! "$COMMENT_ID" =~ [^[:space:]] ]]; then
    printf 'AUTONOMOUS REVIEW: CLOSE INCOMPLETE for %s - transition succeeded, but acceptance comment returned no id; comment write unproven and issue may already be completed.\n' "$ISSUE" >&2
    exit 1
  fi

  # Acceptance is an assertion about both required writes on this path, so no
  # acceptance-shaped output may escape until transition and comment succeed.
  printf 'AUTONOMOUS REVIEW: ACCEPTED - treat as done (no human wait) for %s (reviewer: %s | drift: %s | gate: %s)\n' \
    "$ISSUE" "$REVIEWER" "$DRIFT" "$GATE"
  printf 'Ticket %s transitioned to completed via adapter.\n' "$ISSUE"
else
  # Accepted: the loop autonomously treats the ticket as done and leaves it in
  # the review lane (deferred-QA queue). Record the autonomous acceptance via the
  # adapter -- no approval request, no "waiting on the operator".
  COMMENT_ID=""
  if ! COMMENT_ID="$(TICKET_PROVIDER="$PROV" bash -c '. "$1"; tp comment "$2" "$3"' _ "$SCRIPTS_DIR/lib/ticket-provider.sh" "$ISSUE" \
    "Autonomously accepted by $REVIEWER under the independent adversarial-review protocol (drift: $DRIFT, gate: $GATE, grace ${GRACE_HOURS}h informational). Treated as done; stays in the review lane (deferred-QA queue). Review report: $REPORT." 2>/dev/null)"; then
    printf 'AUTONOMOUS REVIEW: COMMENT FAILED for %s - acceptance comment was not recorded; issue left in review.\n' "$ISSUE" >&2
    exit 1
  fi
  if [[ ! "$COMMENT_ID" =~ [^[:space:]] ]]; then
    printf 'AUTONOMOUS REVIEW: COMMENT UNPROVEN for %s - acceptance comment returned no id; issue left in review.\n' "$ISSUE" >&2
    exit 1
  fi
  printf 'AUTONOMOUS REVIEW: ACCEPTED - treat as done (no human wait) for %s (reviewer: %s | drift: %s | gate: %s)\n' \
    "$ISSUE" "$REVIEWER" "$DRIFT" "$GATE"
  printf 'Accepted: ticket stays in the review lane (deferred-QA queue); the loop moves on.\n'
  printf 'Optional operator QA sweep: re-run with --close to transition %s to completed via the adapter.\n' "$ISSUE"
fi
exit 0
