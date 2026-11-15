#!/usr/bin/env bash
# Land the PM pass's own outputs (no dangling work, 2026-11-15).
#
# The sentinel pass writes evidence files (per-ticket reports, hourly
# sentinel-pass-*.md, launch readouts) into the PROJECT checkout. Nothing ever
# committed them: by 2026-11-15 gruvato's main checkout held 338 untracked
# evidence files, and every worker that later touched that checkout had to
# step around them. heartbeat.sh now runs this after every full pass.
#
# The checkout is SHARED: other agents may have dirty or staged files in it at
# any moment. So this script never merges, rebases, stashes, resets, checks out
# or reverts in the working tree. What it does, deterministically:
#   1. Only when HEAD is the default branch (main): never on a detached HEAD, a
#      side branch, or mid-merge/rebase/cherry-pick. Re-checked right before the
#      commit.
#   2. Collects modified and untracked, non-ignored files under the land paths
#      ONLY (role.yaml `land.paths`, ONE space-separated string, e.g.
#      `paths: "docs/reports _bmad-output/x"`; default: the BMAD issue evidence
#      dir and docs/operations/launch-readouts). Anything else in the checkout
#      belongs to someone else and is left alone. A path another agent has
#      staged is skipped too, so its index entry is never touched.
#   3. Skips a file written in the last LAND_QUIET_SECONDS (default 30): it may
#      still be mid-write. The next pass picks it up.
#   4. Commits exactly those paths (`git commit --only`), so nothing another
#      agent staged rides along. The global guard hooks run; if the batch is
#      refused, each file is retried alone and only refused files are unstaged
#      (they were unstaged before, so nothing of anyone else's is reset).
#   5. Pushes refs/heads/<default>, then fast-forwards the checkout to what it
#      pushed (--ff-only: it never merges in the worktree or leaves a merge in
#      progress, and changes nothing when another agent's dirty file is in the way). If origin moved, the merge is built with
#      `git merge-tree` and `git commit-tree` (object store only, the working
#      tree and index are untouched) and that merge is pushed; the local branch
#      simply ends up behind origin, which the next pull fast-forwards. A
#      conflicting merge is not attempted: it is logged and retried next pass.
#
# It never fails the heartbeat: every exit is 0. LAND_OUTPUTS=0 turns it off.
set -uo pipefail

ROLE_DIR="${ROLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROLE_YAML="$ROLE_DIR/role.yaml"
ROLE_YAML_READER="$ROLE_DIR/.scripts/lib/role-yaml.py"
QUIET="${LAND_QUIET_SECONDS:-30}"
NET_TIMEOUT="${LAND_NET_TIMEOUT_SECONDS:-120}"

log() { printf '[land-outputs] %s\n' "$*"; }
net() {  # bounded network git; a hung ssh must not hold the heartbeat lock or the board lease
  if command -v timeout >/dev/null 2>&1; then timeout "$NET_TIMEOUT" git "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$NET_TIMEOUT" git "$@"
  else git "$@"; fi
}

[[ "${LAND_OUTPUTS:-1}" == 0 ]] && { log "disabled (LAND_OUTPUTS=0)"; exit 0; }

repo="${REPO_ROOT:-}"
if [[ -z "$repo" ]]; then
  repo="$(git -C "$ROLE_DIR" rev-parse --show-toplevel 2>/dev/null)" || { log "not in a git repo; nothing to land"; exit 0; }
fi
cd "$repo" || exit 0

agent="$(python3 "$ROLE_YAML_READER" "$ROLE_YAML" agent_id 2>/dev/null || true)"
agent="${agent:-pm}"
paths_cfg="$(python3 "$ROLE_YAML_READER" "$ROLE_YAML" land.paths 2>/dev/null || true)"
paths_cfg="${LAND_PATHS:-${paths_cfg:-_bmad-output/implementation-artifacts/issue-evidence docs/operations/launch-readouts}}"

default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
default="${default#origin/}"; default="${default:-main}"
gitdir="$(git rev-parse --git-dir)"

on_default() {  # 0 when HEAD is refs/heads/$default and no multi-step operation is in progress
  local branch marker
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || { log "detached HEAD; not landing"; return 1; }
  [[ "$branch" == "$default" ]] || { log "on $branch, not $default; not landing"; return 1; }
  for marker in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
    [[ -e "$gitdir/$marker" ]] && { log "$marker in progress; not landing"; return 1; }
  done
  return 0
}
on_default || exit 0

RUNTIME_DIR="$ROLE_DIR/runtime"
BLOCKED_FILE="$RUNTIME_DIR/land-outputs-blocked.txt"
blocked() {  # leave a marker the next pass reports (the sentinel prompt reads it)
  mkdir -p "$RUNTIME_DIR" 2>/dev/null && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" > "$BLOCKED_FILE"
}
fast_forward() {  # fast-forward the shared checkout to $1 when that is safe; otherwise change nothing
  # --ff-only never creates a merge or leaves one in progress; it refuses (and changes
  # nothing) when another agent's dirty file is in the way.
  on_default >/dev/null || return 0
  git merge-base --is-ancestor "refs/heads/$default" "$1" 2>/dev/null || return 0
  [[ "$(git rev-parse "refs/heads/$default")" == "$(git rev-parse "$1")" ]] && return 0
  if git merge -q --ff-only "$1" >/dev/null 2>&1; then log "fast-forwarded $default"
  else log "could not fast-forward $default (another agent's dirty file is in the way); next pass retries"; fi
}

declare -a present=()
set -f   # land paths are literal, never globbed
for p in $paths_cfg; do
  case "$p" in /*|*..*) log "refusing land path $p (must be repo-relative)"; continue;; esac
  [[ -e "$p" ]] && present+=("$p")
done
set +f
(( ${#present[@]} )) || { log "no land paths exist here; nothing to land"; exit 0; }

# Paths someone has staged (an add, an rm --cached, a partial add) are theirs: skip them.
staged=$'\n'
while IFS= read -r -d '' f; do staged+="$f"$'\n'; done < <(git diff --cached --name-only -z -- "${present[@]}")

now="$(date +%s)"
declare -a files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  [[ "$staged" == *$'\n'"$f"$'\n'* ]] && continue
  m="$(stat -c %Y -- "$f" 2>/dev/null || stat -f %m -- "$f" 2>/dev/null || echo "$now")"
  (( now - m >= QUIET )) || continue
  files+=("$f")
done < <(git ls-files -z -m -o --exclude-standard -- "${present[@]}" | sort -zu)

commit_paths() {  # commit_paths <path>... ; 0 on success, unstages its own paths on refusal
  git add -- "$@" 2>/dev/null || { git reset -q -- "$@" 2>/dev/null; return 1; }
  if git commit -q --only -m "evidence($agent): land pass outputs ($# files)

Committed by .scripts/land-outputs.sh after the board pass, so the pass's own
evidence never dangles in the checkout. Paths: $paths_cfg" -- "$@" >/dev/null 2>"$gitdir/land-outputs-commit.err"; then
    return 0
  fi
  git reset -q -- "$@" 2>/dev/null || true
  return 1
}

if (( ${#files[@]} )); then
  if ! on_default; then
    : # the checkout moved under us; land nothing this pass
  elif commit_paths "${files[@]}"; then
    log "committed ${#files[@]} file(s)"
  else
    log "batch commit refused (guard hook or error); retrying file by file"
    landed=0
    for f in "${files[@]}"; do
      if on_default && commit_paths "$f"; then landed=$((landed + 1)); else log "REFUSED, left for a person: $f ($(tail -n 1 "$gitdir/land-outputs-commit.err" 2>/dev/null))"; blocked "guard refused $f"; fi
    done
    log "committed $landed of ${#files[@]} file(s) one at a time"
  fi
else
  log "nothing new under: $paths_cfg"
fi

# Push the local default branch (not HEAD: the checkout may have moved since), including an
# earlier pass's commit that failed to push.
local_ref="refs/heads/$default"
net fetch -q origin "$default" 2>/dev/null || { log "fetch failed; will push next pass"; exit 0; }
remote="refs/remotes/origin/$default"
ahead="$(git rev-list --count "$remote..$local_ref" 2>/dev/null || echo 0)"
if (( ahead == 0 )); then
  fast_forward "$remote"   # catch up after an earlier pass pushed a merge, or after others pushed
  exit 0
fi
target="$(git rev-parse "$local_ref")"
if ! git merge-base --is-ancestor "$remote" "$local_ref"; then
  # Origin moved. Build the merge in the object store only; never touch the shared worktree.
  if ! tree="$(git merge-tree --write-tree "$local_ref" "$remote" 2>/dev/null)"; then
    log "CONFLICT merging $default with origin/$default (or git too old for merge-tree --write-tree); $ahead commit(s) kept locally, a person must integrate them"
    blocked "local $default has $ahead commit(s) that conflict with origin/$default; integrate them by hand (land-outputs will not merge in the shared worktree)"
    exit 0
  fi
  target="$(git commit-tree "$tree" -p "$local_ref" -p "$remote" -m "Merge origin/$default into $default (land-outputs, $agent)

Co-Authored-By: land-outputs.sh <noreply@localhost>")" || { log "commit-tree failed; will retry next pass"; exit 0; }
fi
on_default || exit 0   # someone started a rebase/checkout meanwhile: push nothing this pass
if net push -q origin "$target:refs/heads/$default" 2>/dev/null; then
  log "pushed $ahead commit(s) to origin/$default"
  rm -f "$BLOCKED_FILE"
  fast_forward "$target"
else
  log "push failed; commit(s) kept locally for the next pass"
fi
exit 0
