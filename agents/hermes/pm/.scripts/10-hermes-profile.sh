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
# global/project union. PM roots do not admit local overrides.
PROJECT_PATH="$(project_repo_path)" \
  || die "cannot resolve the owning project; set PJANGLER_PROJECT_ROOT explicitly"
[[ -f "$PROJECT_PATH/.agents/skills.json" ]] \
  || die "project selection is missing: $PROJECT_PATH/.agents/skills.json; run skillex init --project '$PROJECT_PATH'"
SKILLEX_BIN="${SKILLEX_BIN:-skillex}"
command -v "$SKILLEX_BIN" >/dev/null 2>&1 \
  || die "install a Skillex build supporting profile sync --skillex-only"
"$SKILLEX_BIN" profile sync --help | grep -q -- --skillex-only \
  || die "Skillex is stale; install the policy-capable build before provisioning"

PROFILE_RENDERER="${PROFILE_RENDERER:-$HOME/code/33GOD/hermes-agent-template/scripts/hermes-profile-config.py}"
SKILLS_POLICY="$ROLE_DIR/.scripts/lib/skills-policy.py"
[[ -f "$SKILLS_POLICY" && ! -L "$SKILLS_POLICY" ]] \
  || die "trusted PM skills policy helper is unavailable: $SKILLS_POLICY"
CUTOVER_HINT="python3 ~/code/skillex/scripts/hermes-skillex-cutover.py --profile $PROFILE_NAME --project '$PROJECT_PATH' --registry-root ~/code/skillex --renderer ~/code/33GOD/hermes-agent-template/scripts/hermes-profile-config.py (preview, then --apply)"

# Read-only Skillex preflight of an existing profile. Exit 0 is converged and
# exit 6 is a pending sync (a selection change or catalog bump), which is what
# this step exists to apply. Anything else (a refusal, an invalid manifest, a
# legacy whole-root link) stops here, before any profile mutation.
SKILLEX_SHOW_JSON=""
skillex_preflight() {
  local rc=0
  SKILLEX_SHOW_JSON="$("$SKILLEX_BIN" profile show "$PROFILE_NAME" --project "$PROJECT_PATH" --json)" || rc=$?
  if [[ $rc -ne 0 && $rc -ne 6 ]]; then
    printf '%s\n' "$SKILLEX_SHOW_JSON"
    die "legacy/invalid skills (skillex profile show exit $rc); use the preservation-first Skillex cutover: $CUTOVER_HINT"
  fi
}

# Strict sync: preview first, then apply. Both refuse foreign skills/ content
# and non-empty skills.external_dirs without changing anything.
strict_skill_sync() {
  "$SKILLEX_BIN" profile sync "$PROFILE_NAME" --project "$PROJECT_PATH" \
    --skillex-only --dry-run || die "strict skill preflight refused; no profile state changed"
  "$SKILLEX_BIN" profile sync "$PROFILE_NAME" --project "$PROJECT_PATH" \
    --skillex-only || die "strict skill sync refused"
}

log "[10] creating hermes profile: $PROFILE_NAME"

STRICT_DESK=0
if [[ -d "$PROFILE_HOME" ]]; then
  # A live desk is never re-onboarded opportunistically and never reset: no
  # state, PID or database is deleted here, whatever the provision marker says.
  skillex_preflight
  if [[ -e "$PROFILE_HOME/.skillex-only" || -L "$PROFILE_HOME/.skillex-only" ]]; then
    [[ -f "$PROFILE_HOME/.skillex-only" && ! -L "$PROFILE_HOME/.skillex-only" ]] \
      || die "strict policy marker must be a regular file: $PROFILE_HOME/.skillex-only"
    STRICT_DESK=1
  else
    # Not yet strict: either a desk whose first provisioning stopped part way
    # (resume it below), or a legacy desk carrying local skills. Only the
    # preservation-first cutover may move local skills; refuse those here.
    python3 -I - "$SKILLEX_SHOW_JSON" <<'PYEOF' \
      || die "legacy/invalid skills: local entries need the preservation-first Skillex cutover: $CUTOVER_HINT"
import json, sys
# Hermes bookkeeping that is never a skill (mirrors Skillex's strict policy).
files = {".usage.json", ".usage.json.lock", ".curator_state", ".curator_suppressed", ".sync_state"}
dirs = {".curator_backups"}
data = (json.loads(sys.argv[1]) or {}).get("data") or {}
foreign = [
    item["name"] for item in data.get("preserved") or []
    if not (item.get("kind") == "file" and item["name"] in files)
    and not (item.get("kind") == "directory" and item["name"] in dirs)
]
if foreign:
    print("local skills/ entries: " + ", ".join(sorted(foreign)), file=sys.stderr)
    raise SystemExit(1)
PYEOF
    log "    existing profile is not yet Skillex-only; resuming provisioning"
  fi
else
  # `--clone` copies the default profile's .env before a provisioner can
  # inspect it, transiently materializing every credential in the new profile.
  # Start clean; required skills and the project SOUL are installed below.
  "$HERMES_BIN" profile create "$PROFILE_NAME" --no-alias --no-skills
fi


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

# An established Skillex-only desk is converged in place: keep discovery
# isolated (a no-op when the delta already says so), then apply any pending
# selection or catalog change. Its config, SOUL, memory pin and runtime state
# are left byte-for-byte alone.
if [[ "$STRICT_DESK" == "1" ]]; then
  [[ -f "$PROFILE_RENDERER" && ! -L "$PROFILE_RENDERER" ]] \
    || die "canonical config renderer required for PM skill policy: $PROFILE_RENDERER"
  python3 -I "$SKILLS_POLICY" "$PROFILE_HOME" "$PROFILE_RENDERER" \
    || die "could not keep isolated PM discovery"
  strict_skill_sync
  mark_done 10-hermes-profile
  exit 0
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

# A named travelling agent declares WHO it is in role.yaml (`identity:`), and
# its durable personal bank follows the name, never the post/profile. role.yaml
# is the source; 80-registry.sh projects it into the registry. This step runs
# BEFORE step 80, so it reads role.yaml first and only falls back to a registry
# declaration for rows named before role.yaml carried the block.
ROLE_IDENTITY_READER="$ROLE_DIR/.scripts/lib/role-identity.py"
[[ -f "$ROLE_IDENTITY_READER" && ! -L "$ROLE_IDENTITY_READER" ]] \
  || die "trusted role identity reader is unavailable: $ROLE_IDENTITY_READER"
ROLE_IDENTITY_JSON="$(python3 -I "$ROLE_IDENTITY_READER" "$ROLE_YAML" "$AGENT_ID" "$PROFILE_NAME")" \
  || die "role.yaml identity block is invalid"
DECLARED_PERSONAL_BANK="$(python3 - "$REGISTRY_FILE" "$AGENT_ID" "$ROLE_IDENTITY_JSON" <<'PYEOF'
import json
import pathlib
import re
import sys

registry, agent_id, role_identity_json = sys.argv[1:4]
role_identity = json.loads(role_identity_json or "{}")
entry = {}
path = pathlib.Path(registry)
if path.is_file() and not path.is_symlink():
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

if role_identity:
    # role.yaml wins. A disagreeing registry row is stale until step 80
    # re-projects it; say so, but do not refuse the pin the SSOT asks for.
    if identity is not None and identity != role_identity["name"]:
        print(f"registry names {agent_id} {identity!r}; role.yaml says "
              f"{role_identity['name']!r} and wins (step 80 converges the row)", file=sys.stderr)
    elif bank is not None and bank != role_identity["write_bank"]:
        print(f"registry pins {agent_id} to {bank!r}; role.yaml says "
              f"{role_identity['write_bank']!r} and wins (step 80 converges the row)", file=sys.stderr)
    print(role_identity["write_bank"])
    raise SystemExit(0)

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
)" || die "named-agent bank declaration is invalid (role.yaml identity or $REGISTRY_FILE)"

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

# Name the bank template the identity bank starts from (config.toml
# [hindsight] agent_bank_template). The Hindsight provider imports it the
# first time the agent's session touches a bank with no mission, and never
# over one that already has a mission, so a travelling named agent keeps what
# its bank already knows. Without it a new agent bank extracts unsteered.
if [[ -f "$PROFILE_RENDERER" ]]; then
  python3 "$PROFILE_RENDERER" memory-template --profile "$PROFILE_NAME" >/dev/null \
    && log "    recorded identity bank template (applied on the agent's first session)" \
    || warn "    could not record the identity bank template; run hermes-profile-config.py memory-template --profile $PROFILE_NAME"
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

# New and resumed profiles override any fleet external roots before activation,
# then Skillex publishes the strict markers with the first strict sync.
[[ -f "$PROFILE_RENDERER" && ! -L "$PROFILE_RENDERER" ]] \
  || die "canonical config renderer required for PM skill policy: $PROFILE_RENDERER"
python3 -I "$SKILLS_POLICY" "$PROFILE_HOME" "$PROFILE_RENDERER" \
  || die "could not establish isolated PM discovery"
strict_skill_sync

mark_done 10-hermes-profile
