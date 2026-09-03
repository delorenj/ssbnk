#!/usr/bin/env bash
# Create or reconcile the initial named Hermes profile without cloning secrets.
# The directory remains REAL. Step 20 delegates final shared-vs-owned link
# topology to `pj migrate hermes.runtime-singleton`; no template step may
# replace the profile itself with a symlink.

if [[ "${SKIP_HOST_STATE:-0}" == "1" ]]; then
  printf '%s\n' '[10] Hermes profile — DEFERRED (SKIP_HOST_STATE=1)' >&2
  exit 0
fi

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
load_role_env

PROFILE_HOME="$HOME/.hermes/profiles/$PROFILE_NAME"

# Older deployments made the named profile itself a symlink into project
# state.  Following that link here would make the cleanup below delete files
# from the link target before the singleton-runtime migration can preserve
# them.  Refuse the legacy topology before any profile mutation.
if [[ -L "$PROFILE_HOME" ]]; then
  die "legacy named profile symlink detected at $PROFILE_HOME; refusing mutation. Run: pj migrate hermes.runtime-singleton '$(project_repo_path 2>/dev/null || printf '%s' "$ROLE_DIR")'"
fi
PROFILE_DELTA_SEEDER="$ROLE_DIR/.scripts/lib/profile-config-seed.py"
[[ -f "$PROFILE_DELTA_SEEDER" && ! -L "$PROFILE_DELTA_SEEDER" ]] \
  || die "trusted profile config seed helper is unavailable: $PROFILE_DELTA_SEEDER"

already_done 10-hermes-profile \
  && log "[10] profile marker found — revalidating required profile contract"

# Skillex projects the canonical global catalog into ~/.agents/skills. These
# six skills are the immutable deployed PM contract, not optional suggestions.
# Validate the complete set before any profile mutation so a partial/missing
# projection cannot warn and then be falsely reported as provisioned.
CANONICAL_SKILLS_DIR="${CANONICAL_SKILLS_DIR:-$(config_get fleet.canonical_skills_dir "$HOME/.agents/skills")}"
CORE_RUNTIME_SKILLS=(
  33god-projects
  delonet-conventions
  delonet-dotenv
  hermes-pm-template-maintenance
  hindsight
  subagent-driven-development
)
OPTIONAL_RUNTIME_SKILLS_TEXT="${SYMLINKED_RUNTIME_SKILLS:-$(config_get fleet.symlinked_runtime_skills '')}"
read -r -a OPTIONAL_RUNTIME_SKILLS <<< "$OPTIONAL_RUNTIME_SKILLS_TEXT"
SYMLINKED_RUNTIME_SKILLS=("${CORE_RUNTIME_SKILLS[@]}")
for skill_name in "${OPTIONAL_RUNTIME_SKILLS[@]}"; do
  [[ -n "$skill_name" ]] || continue
  skill_present=0
  for required_name in "${SYMLINKED_RUNTIME_SKILLS[@]}"; do
    [[ "$required_name" == "$skill_name" ]] && { skill_present=1; break; }
  done
  [[ $skill_present -eq 1 ]] || SYMLINKED_RUNTIME_SKILLS+=("$skill_name")
done
missing_runtime_skills=()
for skill_name in "${SYMLINKED_RUNTIME_SKILLS[@]}"; do
  [[ -f "$CANONICAL_SKILLS_DIR/$skill_name/SKILL.md" ]] \
    || missing_runtime_skills+=("$skill_name")
done
if [[ ${#missing_runtime_skills[@]} -gt 0 ]]; then
  clear_done 10-hermes-profile
  die "required Skillex projection missing SKILL.md for: ${missing_runtime_skills[*]} (run the global Skillex sync, then rerun)"
fi
log "[10] required Skillex skills validated: ${SYMLINKED_RUNTIME_SKILLS[*]}"

log "[10] creating hermes profile: $PROFILE_NAME"

if [[ -d "$PROFILE_HOME" ]]; then
  log "    profile dir already exists; reusing"
else
  # `--clone` copies the default profile's .env before a provisioner can
  # inspect it, transiently materializing every credential in the new profile.
  # Start clean; required skills and the project SOUL are installed below.
  "$HERMES_BIN" profile create "$PROFILE_NAME" --no-alias
fi

# Strip any inherited gateway/runtime state so this profile boots clean.
rm -f "$PROFILE_HOME/gateway.pid" "$PROFILE_HOME/gateway_state.json" \
      "$PROFILE_HOME/processes.json" "$PROFILE_HOME/state.db" 2>/dev/null || true
# Belt-and-suspenders: if a profiles/ dir somehow exists, remove it
[[ -d "$PROFILE_HOME/profiles" ]] && rm -rf "$PROFILE_HOME/profiles"

# A new profile gets an empty Hermes-created .env. Existing profiles are never
# migrated opportunistically: if a legacy deployment still has raw channel
# credentials, fail closed and leave the approval-gated migration to the fleet
# operator. Only key names are reported; values are never printed.
PROFILE_ENV="$PROFILE_HOME/.env"
if [[ -f "$PROFILE_ENV" ]]; then
  python3 - "$PROFILE_ENV" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
keys = (
    "SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_SIGNING_SECRET",
    "TELEGRAM_BOT_TOKEN", "DISCORD_BOT_TOKEN",
)
found = []
for raw in p.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    name, sep, value = line.partition("=")
    if sep and name.strip() in keys and value.strip():
        found.append(name.strip())
if found:
    raise SystemExit(
        "raw channel credential assignments require the approval-gated "
        "1Password migration: " + ", ".join(sorted(set(found)))
    )
PYEOF
  [[ -L "$PROFILE_ENV" ]] || chmod 600 "$PROFILE_ENV"
fi

# Never persist a project-specific terminal.cwd through the named profile.
# The generated launchers pass TERMINAL_CWD process-locally instead.
#
# config.yaml is GENERATED, never hand-written and never a symlink to the fleet
# base. It is deep_merge(~/.hermes/config.yaml, <profile>/config.delta.yaml).
# The old symlink-to-base topology was actively harmful: Hermes' atomic writes
# use os.replace, which REPLACES a symlink with a regular file, so the first
# in-agent write (/model, onboarding, a config migration) silently detached the
# profile onto a frozen copy of an old base — and a symlink gave the profile no
# way to override anything in the first place.
#
# Seed an EMPTY delta: a new agent should be identical to the fleet base, and
# every line here is an override someone must justify later.
PROFILE_DELTA="$PROFILE_HOME/config.delta.yaml"
profile_delta_seed_result="$(
  python3 -I "$PROFILE_DELTA_SEEDER" --profile "$PROFILE_HOME"
)" || die "config.delta.yaml seed reconciliation failed"
if [[ "$profile_delta_seed_result" == "seeded" ]]; then
  log "    seeding empty config.delta.yaml (override-only SSOT)"
elif [[ "$profile_delta_seed_result" != "exists" ]]; then
  die "profile config seed helper returned an invalid result"
fi

# Pin the identity-memory bank explicitly rather than relying on the fleet
# bank_id_template (agent-{profile}). {profile} resolves through Hermes'
# get_active_profile_name(), which calls Path.resolve() on HERMES_HOME and
# requires a lowercase id sitting directly under profiles/. A symlinked profile
# dir or an uppercase name silently yields the literal "custom" — which would
# merge this agent's PRIVATE memory into a bank shared with every other agent
# that also failed to resolve.
PROFILE_MEM_CFG="$PROFILE_HOME/hindsight/config.json"
mkdir -p "$(dirname "$PROFILE_MEM_CFG")"
if [[ ! -f "$PROFILE_MEM_CFG" ]]; then
  log "    pinning identity-memory bank: agent-$PROFILE_NAME"
  printf '{\n  "bank_id": "agent-%s"\n}\n' "$PROFILE_NAME" > "$PROFILE_MEM_CFG"
  chmod 600 "$PROFILE_MEM_CFG"
fi

# Render config.yaml from base + delta when the renderer is available. Without
# it the profile still boots (Hermes reads whatever config.yaml exists), but it
# is not yet under inheritance and `pj audit` will say so.
PROFILE_RENDERER="${PROFILE_RENDERER:-$HOME/code/33GOD/hermes-agent-template/scripts/hermes-profile-config.py}"
if [[ -x "$PROFILE_RENDERER" || -f "$PROFILE_RENDERER" ]]; then
  log "    rendering config.yaml from fleet base + delta"
  python3 "$PROFILE_RENDERER" render --profile "$PROFILE_NAME" >/dev/null 2>&1 \
    || warn "    render failed; run hermes-profile-config.py render --profile $PROFILE_NAME"
else
  warn "    profile renderer not found at $PROFILE_RENDERER — config.yaml not rendered"
fi

# Canonical shared-skill source of truth + local PM fallback sync.
CANONICAL_PM_SKILL_SRC="$CANONICAL_SKILLS_DIR/subagent-driven-development"
LOCAL_PM_SKILL_DST="$PROFILE_HOME/skills/software-development/subagent-driven-development"

if [[ -d "$CANONICAL_SKILLS_DIR" ]]; then
  # skills.external_dirs is a FLEET setting and already lives in
  # ~/.hermes/config.yaml, so every rendered profile inherits it. Writing it
  # per-profile here would (a) be redundant, and (b) write into the GENERATED
  # config.yaml, where the next render discards it — the classic "I set it and
  # it reverted" trap. Verify inheritance instead of re-asserting it.
  if ! env HERMES_HOME="$PROFILE_HOME" "$HERMES_BIN" config get skills.external_dirs 2>/dev/null \
       | grep -qF "$CANONICAL_SKILLS_DIR"; then
    warn "    skills.external_dirs does not include $CANONICAL_SKILLS_DIR"
    warn "    add it to the FLEET base (~/.hermes/config.yaml), then: hermes-profile-config.py render --all"
  else
    log "    skills.external_dirs inherited from fleet base: $CANONICAL_SKILLS_DIR"
  fi

  # Ensure key PM/local-ops skills are symlinked into runtime/profile skills root.
  # This preserves canonical ownership and keeps updates instant across agents.
  mkdir -p "$PROFILE_HOME/skills"

  for skill_name in "${SYMLINKED_RUNTIME_SKILLS[@]}"; do
    src="$CANONICAL_SKILLS_DIR/$skill_name"
    dst="$PROFILE_HOME/skills/$skill_name"

    [[ -f "$src/SKILL.md" ]] \
      || die "required Skillex skill disappeared during provisioning: $src/SKILL.md"

    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      log "    runtime skill symlink already set: $dst -> $src"
      continue
    fi

    [[ -e "$dst" || -L "$dst" ]] && rm -rf "$dst"
    ln -s "$src" "$dst"
    log "    symlinked runtime skill: $dst -> $src"
  done
else
  die "canonical Skillex projection directory disappeared during provisioning: $CANONICAL_SKILLS_DIR"
fi

if [[ -f "$CANONICAL_PM_SKILL_SRC/SKILL.md" ]]; then
  log "    syncing canonical PM workflow skill -> $LOCAL_PM_SKILL_DST"
  mkdir -p "$LOCAL_PM_SKILL_DST"
  cp -f "$CANONICAL_PM_SKILL_SRC/SKILL.md" "$LOCAL_PM_SKILL_DST/SKILL.md"
else
  die "required canonical PM skill disappeared during provisioning: $CANONICAL_PM_SKILL_SRC/SKILL.md"
fi

# Install the project's SOUL.md into the profile so the agent loads it.
if [[ -f "$ROLE_DIR/SOUL.md" ]]; then
  cp "$ROLE_DIR/SOUL.md" "$PROFILE_HOME/SOUL.md"
  log "    installed SOUL.md into profile"
fi

mark_done 10-hermes-profile
