#!/usr/bin/env sh
# Provider-agnostic close gate. Verifies an issue's evidence file is complete
# before any closure (manual or autonomous). Pure gate: it reports PASS/FAIL on
# stdout/stderr and via the exit code, and publishes nothing.
#
# Usage: issue-close-gate.sh ISSUE_ID [REPO_ROOT]
set -eu

if [ "${1:-}" = "" ]; then
  printf 'Usage: %s ISSUE_ID [REPO_ROOT]\n' "$0" >&2
  exit 2
fi
ISSUE="$1"
case "$ISSUE" in *[!A-Za-z0-9_-]*) printf 'Invalid issue id: %s\n' "$ISSUE" >&2; exit 2 ;; esac

BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROLE_YAML="$BIN_DIR/../../../role.yaml"
ROLE_REPO="$(sed -n 's/^repo:[[:space:]]*//p' "$ROLE_YAML" 2>/dev/null | head -n1 | tr -d '"' | tr -d '\r')"
ROOT="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT"
ROOT="$(pwd -P)"
PROJECT_MANIFEST="$ROOT/.project.json"
if [ -e "$PROJECT_MANIFEST" ] || [ -L "$PROJECT_MANIFEST" ]; then
  [ -f "$PROJECT_MANIFEST" ] || {
    printf 'Project manifest is not a regular file: %s\n' "$PROJECT_MANIFEST" >&2
    exit 1
  }
  REPO_SLUG="$(python3 - "$PROJECT_MANIFEST" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    document = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"close gate: malformed project manifest {path}: {exc}")
slug = document.get("project_slug") if isinstance(document, dict) else None
if not isinstance(slug, str) or not slug.strip():
    raise SystemExit(f"close gate: project manifest {path} has no non-blank project_slug")
print(slug.strip())
PY
)" || exit 1
else
  REPO_SLUG="$(basename "$ROOT")"
fi
if [ -n "$ROLE_REPO" ] && [ "$ROLE_REPO" != "$REPO_SLUG" ]; then
  printf 'Installed role repo %s disagrees with target project slug %s.\n' "$ROLE_REPO" "$REPO_SLUG" >&2
  exit 1
fi

FILE="_bmad-output/implementation-artifacts/issue-evidence/$ISSUE.md"
FAIL=0

if [ ! -f "$FILE" ]; then
  printf 'Missing issue evidence file: %s\n' "$FILE" >&2
  exit 1
fi

# Structural parse: every required H2 exactly once, and each authoritative
# field read only as a direct field of its own section. Lookalike lines in
# other sections can never stand in for -- or override -- the authoritative
# value (an authoritative `no`/`hold` always fails the gate). The implementer
# identity is defined as exactly one nonblank `Worker:` / `Implemented by:`
# field in the Issue section; duplicates, blanks, and conflicting spellings
# are rejected.
GATE_PROBLEMS=""
if ! GATE_PROBLEMS="$(python3 - "$FILE" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    lines = stream.read().splitlines()

REQUIRED = [
    "Issue",
    "Acceptance Criteria",
    "Repo Changes",
    "Verification",
    "Ledger Update",
    "Known Gaps",
    "Close Recommendation",
]

heading = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
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

problems = []
for name in REQUIRED:
    count = order.count(name)
    if count == 0:
        problems.append(f"Missing required evidence: {name}")
    elif count > 1:
        problems.append(f"Duplicate required evidence section: {name}")


def direct_fields(section, *names):
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


def first_token(value):
    tokens = value.split()
    return tokens[0].lower() if tokens else ""


if order.count("Ledger Update") == 1:
    found = direct_fields("Ledger Update", "Ledger updated")
    if len(found) != 1:
        problems.append(
            "Expected exactly one 'Ledger updated:' field in '## Ledger Update'"
            f" (found {len(found)})."
        )
    elif first_token(found[0]) != "yes":
        problems.append("Ledger update is not marked yes.")

if order.count("Close Recommendation") == 1:
    found = direct_fields("Close Recommendation", "Close recommendation")
    if len(found) != 1:
        problems.append(
            "Expected exactly one 'Close recommendation:' field in"
            f" '## Close Recommendation' (found {len(found)})."
        )
    elif first_token(found[0]) != "ready":
        problems.append("Close recommendation is not ready.")

if order.count("Issue") == 1:
    found = direct_fields("Issue", "Worker", "Implemented by")
    if len(found) != 1:
        problems.append(
            "Expected exactly one implementer identity ('Worker:' /"
            f" 'Implemented by:') in '## Issue' (found {len(found)})."
        )
    elif not found[0]:
        problems.append("The implementer identity in '## Issue' is blank.")

for problem in problems:
    print(problem)
PY
)"; then
  printf 'Evidence file could not be parsed: %s\n' "$FILE" >&2
  exit 1
fi
if [ -n "$GATE_PROBLEMS" ]; then
  printf '%s\n' "$GATE_PROBLEMS" >&2
  FAIL=1
fi

if grep -Eiq 'TBD|TODO|not run|pending|unknown' "$FILE"; then
  printf 'Evidence file still contains unresolved placeholders or unverified work.\n' >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nCLOSE GATE: FAIL for %s\n' "$ISSUE" >&2
  exit 1
fi

printf 'CLOSE GATE: PASS for %s (repo: %s)\n' "$ISSUE" "$REPO_SLUG"
