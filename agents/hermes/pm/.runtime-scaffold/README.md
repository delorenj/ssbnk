# {{agent_id}} — runtime

This is the ignored, role-owned state for the **{{display_name}}** agent. The
actual HERMES_HOME is a real named directory under `~/.hermes/profiles/`, with
PJangler-managed links into this runtime. Back it up separately; it is not
published by project Git.

## What's in here

| Path | Tracked? | Purpose |
| --- | --- | --- |
| `config.yaml` | local | Legacy seed/delta; shared profile config comes from fleet root |
| `SOUL.md` | local | The agent's personality, evolves over time |
| `memories/MEMORY.md` | local | The condensed mental-model summary loaded each session |
| `memories/USER.md` | local | The operator's persona |
| `sessions/sessions.db` | local | SQLite store of conversations |
| `decisions/` | local | Agent-emitted decisions |
| `.env` | **no** | API keys + Telegram bot token (per-machine secret) |
| `auth.json` | **no** | Deprecated local OAuth store; named profiles use fleet auth fallback |
| `audio_cache/`, `image_cache/` | **no** | Regenerable caches |
| `sandboxes/` | **no** | Per-session ephemeral execution dirs |

Bloodbank ingress is fleet-shared. The fleet gateway discovers this profile
through `~/.hermes/agents-registry.yaml` and routes commands by
`data.target_agent_id`; this runtime has no consumer process or inbox bridge.

## Checkpoint cadence

- Heartbeat: systemd `--user` timer `hermes-{{agent_id}}-heartbeat.timer`. Each
  tick reconciles the ticket board (the PM's sentinel pass) and then, gated to
  at most once an hour, checkpoints this runtime.
- On session end: hermes Stop hook (TODO: hook script in `~/.hermes/hooks/`)

The heartbeat runner lives in the parent's `.scripts/heartbeat.sh`; it calls
`.scripts/checkpoint.sh` internally, which `git add -A`, commits only if dirty,
and pushes to `origin`.

## Restoring on a new machine

```bash
cd /path/to/parent-project
git submodule update --init --recursive
git -C agents/hermes/{{role}}/runtime lfs pull
# Provide the per-runtime secrets the submodule deliberately excluded:
cp ~/path/to/your/.env       agents/hermes/{{role}}/runtime/.env
# OAuth provider credentials are shared across the fleet. If needed, login once:
agents/hermes/{{role}}/hermes auth add openai-codex
agents/hermes/{{role}}/hermes status
```

## DO NOT manually edit on multiple machines

This repo is a single-writer system. Either run the agent on machine A or
machine B — not both. The checkpoint commit will fast-forward; concurrent
edits cause merge pain. If you really need to fork the agent (e.g. for
experimentation), branch this repo.
