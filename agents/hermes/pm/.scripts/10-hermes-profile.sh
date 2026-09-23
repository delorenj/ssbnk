#!/usr/bin/env bash
# Create or reconcile the initial named Hermes profile without cloning secrets.
# The directory remains REAL. Step 20 delegates final shared-vs-owned link
# topology to `flume remediate hermes.runtime-singleton`; no template step may
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
  die "legacy named profile symlink detected at $PROFILE_HOME; refusing mutation. Run: flume remediate hermes.runtime-singleton '$(project_repo_path 2>/dev/null || printf '%s' "$ROLE_DIR")'"
fi
PROFILE_DELTA_SEEDER="$ROLE_DIR/.scripts/lib/profile-config-seed.py"
[[ -f "$PROFILE_DELTA_SEEDER" && ! -L "$PROFILE_DELTA_SEEDER" ]] \
  || die "trusted profile config seed helper is unavailable: $PROFILE_DELTA_SEEDER"

already_done 10-hermes-profile \
  && log "[10] profile marker found — revalidating required profile contract"

# Select this role's owning project explicitly. Skillex alone resolves the
# global/project union and owns its recorded children; runtime-local entries win.
PROJECT_PATH="$(project_repo_path)" \
  || die "cannot resolve the owning project; set PJANGLER_PROJECT_ROOT explicitly"
[[ -f "$PROJECT_PATH/.agents/skills.json" ]] \
  || die "project selection is missing: $PROJECT_PATH/.agents/skills.json; run skillex init --project '$PROJECT_PATH'"
command -v mise >/dev/null 2>&1 \
  || die "mise and Node.js 24+ are required for @delorenj/skillex@0.1.1"

log "[10] creating hermes profile: $PROFILE_NAME"

if [[ -d "$PROFILE_HOME" ]]; then
  log "    profile dir already exists; reusing"
else
  # `--clone` copies the default profile's .env before a provisioner can
  # inspect it, transiently materializing every credential in the new profile.
  # Start clean; required skills and the project SOUL are installed below.
  "$HERMES_BIN" profile create "$PROFILE_NAME" --no-alias
fi

# Activate before touching unrelated profile state. The profile and its skills
# directory remain real; Skillex refuses a legacy whole-directory link with an
# actionable migration finding. Its receipts live outside the project in XDG state.
if ! mise exec npm:@delorenj/skillex@0.1.1 -- skillex profile sync "$PROFILE_NAME" \
    --hermes-root "$HOME/.hermes" --project "$PROJECT_PATH"; then
  clear_done 10-hermes-profile
  die "Skillex profile sync failed; resolve its findings and rerun this step"
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
PROFILE_RENDERER="${PROFILE_RENDERER:-$HOME/code/33GOD/hermes-agent-template/scripts/hermes-profile-config.py}"

# A named travelling agent declares its durable bank in the registry. Read that
# declaration by agent id, never by profile/post name. The registry is written
# by step 80, so an absent row is the normal first-provision path for legacy PMs.
DECLARED_PERSONAL_BANK="$(python3 - "$REGISTRY_FILE" "$AGENT_ID" <<'PYEOF'
import pathlib
import re
import sys

registry, agent_id = sys.argv[1:3]
path = pathlib.Path(registry)
if not path.is_file() or path.is_symlink():
    raise SystemExit(0)
try:
    import yaml
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    entry = (document.get("agents") or {}).get(agent_id) or {}
except Exception as exc:
    raise SystemExit(f"cannot read fleet registry for {agent_id}: {exc}")
if not isinstance(entry, dict):
    raise SystemExit(f"fleet registry entry for {agent_id} must be a mapping")
identity = entry.get("identity")
hindsight = entry.get("hindsight")
bank = hindsight.get("write_bank") if isinstance(hindsight, dict) else None
if identity is not None and (not isinstance(identity, str) or not identity.strip()):
    raise SystemExit(f"fleet registry identity for {agent_id} must be a non-empty string")
if identity is not None and bank is None:
    raise SystemExit(f"named agent {agent_id} must declare hindsight.write_bank")
if bank is not None:
    if not isinstance(bank, str) or re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", bank) is None:
        raise SystemExit(f"hindsight.write_bank for {agent_id} must be a lower-case bank identifier")
    if identity is not None and bank != f"agent-{identity}":
        raise SystemExit(f"hindsight.write_bank for {agent_id} must be agent-{identity}")
    print(bank)
PYEOF
)" || die "named-agent bank declaration is invalid in $REGISTRY_FILE"

if [[ -n "$DECLARED_PERSONAL_BANK" ]]; then
  [[ -f "$PROFILE_RENDERER" ]] \
    || die "named-agent bank declaration requires the canonical profile renderer: $PROFILE_RENDERER"
  log "    pinning declared identity-memory bank: $DECLARED_PERSONAL_BANK"
  python3 "$PROFILE_RENDERER" memory-pin --profile "$PROFILE_NAME" --bank-id "$DECLARED_PERSONAL_BANK" \
    >/dev/null || die "canonical profile renderer could not pin $DECLARED_PERSONAL_BANK"
elif [[ ! -f "$PROFILE_MEM_CFG" ]]; then
  log "    pinning compatibility identity-memory bank: agent-$PROFILE_NAME"
  printf '{\n  "bank_id": "agent-%s"\n}\n' "$PROFILE_NAME" > "$PROFILE_MEM_CFG"
  chmod 600 "$PROFILE_MEM_CFG"
fi

# Render config.yaml from base + delta when the renderer is available. Without
# it the profile still boots (Hermes reads whatever config.yaml exists), but it
# is not yet under inheritance and `pj audit` will say so.
if [[ -x "$PROFILE_RENDERER" || -f "$PROFILE_RENDERER" ]]; then
  log "    rendering config.yaml from fleet base + delta"
  python3 "$PROFILE_RENDERER" render --profile "$PROFILE_NAME" >/dev/null 2>&1 \
    || warn "    render failed; run hermes-profile-config.py render --profile $PROFILE_NAME"
else
  warn "    profile renderer not found at $PROFILE_RENDERER — config.yaml not rendered"
fi

# Install the project's SOUL.md into the profile so the agent loads it.
if [[ -f "$ROLE_DIR/SOUL.md" ]]; then
  cp "$ROLE_DIR/SOUL.md" "$PROFILE_HOME/SOUL.md"
  log "    installed SOUL.md into profile"
fi

mark_done 10-hermes-profile
