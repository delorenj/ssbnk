# Continuous ticket orchestration (sentinel engine)

Status: sentinel engine protocol (provider-agnostic)

## Krebs lifecycle v2 (2026-11-14): this engine no longer dispatches

The board has five lanes: Backlog, Todo, In Progress, Done, Cancelled. Lifecycle meaning lives
in labels (`lifecycle:triaged`, `lifecycle:review`, `lifecycle:needs-input`,
`lifecycle:blocked`, `agent:working`, `agent:failed`); see `~/code/33GOD/krebs/docs/lifecycle.md`.
**`krebs tick` is the only dispatcher**: two implementation slots per scope, triaged Todo
tickets in Todo order. The sentinel never delegates implementation workers, never moves a
ticket to `started`, and never spawns a worker. It orders Todo, applies verdicts (In Progress +
`lifecycle:review`: accepted closes, sent back returns to Todo with `returned: <criterion>`),
unblocks held tickets and keeps evidence current. Where this document says "review lane",
read In Progress + `lifecycle:review`.

One owner per ticket: never duplicate another owner's work. Tickets whose file scopes clearly
collide are sequenced with a `--blocks` relation. The short board-driver lease
(`board-lease.py`) is not a WIP limit; it only serializes board selection/transition passes.

When `heartbeat.sh` starts the pass it has already acquired that lease for the
agent under a per-pass owner (`hermes:<agent_id>:pass-<utc>-<pid>`) and says so in
a section appended to the prompt (the prompt is the carrier: `hermes chat` runs the
session in the host gateway, whose terminal never sees the launcher's
`HERMES_BOARD_LEASE_*` exports). The lease is then the agent's own:
check/refresh/release it, and re-acquire it after an early release, with that exact
owner and never under another name, because acquire is reentrant only for the
identical owner string and the agent's own lease would otherwise refuse it. An
agent acquiring with no launcher picks one owner for its turn
(`hermes:<agent_id>:<turn tag>`), writes it out literally and reuses it. Back off
whenever the lease is held fresh by any other owner (an interactive session, a job, another agent,
or another pass of the same desk): owners are unique per pass precisely so two
passes of one agent serialize instead of sharing the lease.

The sentinel owns the watch loop. Workers (codex, opencode, copilot, …), dispatched by
`krebs tick`, own implementation. The sentinel applies verdicts on handed-back work, and
still does not write application code or approve merges.

## Ticket access

All board access goes through the adapter (`tp`, from
`.scripts/lib/ticket-provider.sh`) and reasons in normalized states:
`backlog | unstarted | completed | cancelled` (read `started` only; never write it). Never call the provider
directly — the engine is identical across Linear, Plane, and Trello.

## Work-state feed

Every heartbeat/pass keeps `runtime/continuous-ticket-sentinel-state.json`
current and machine-readable: `source`, `agent_id`, `repo`, `ticket_provider`,
`status` (`idle|checking|active|blocked|stalled|error`), `active_issue`,
`summary`, `reason`, `session`, `worktree`, `updated_at`, `last_activity_at`,
`log_path`.

## Source order (each pass)

1. Active milestone (`tp active_milestone`) and issues (`tp list_issues`). Plane's
   issue list is project-wide: current-cycle visibility is exactly the rows with
   `in_active_milestone:true`, not every returned issue.
2. Local evidence under `_bmad-output/implementation-artifacts/issue-evidence/`.
3. Live worker state: zellij sessions, worktrees, branches, recent git.

When sources disagree, record a truth-check note and keep the issue open.

## Todo order (every pass)

Choose the order of Todo, not the next worker. Priority: owner-filed bugs and
launch work first (the Launch Director's cut line), then a blocked/review ticket needing only
agent-doable evidence repair, then an unblocked issue in the current milestone, then a small
high-priority Backlog issue when Todo is empty. Move at most 2 Backlog tickets up per pass.
Krebs dispatches the top triaged Todo tickets into free slots; sequence a ticket whose file
scope clearly collides with a running one via `--blocks`.

## Stop conditions

Stop without writing only when the board/evidence cannot be inspected, or the lease is held by
another owner. A ticket waiting only on a verdict is not a stop condition: apply the Launch
Director's verdict. A ticket held by `lifecycle:needs-input` or `lifecycle:blocked` waits for
its owner and holds no slot.

The loop never ends a pass with a delivered verdict unapplied.

## Review and closure

1. Run ticket verification.
2. Run the close gate: `.scripts/sentinel/bin/issue-close-gate.sh <ISSUE>`.
3. Apply the verdict (Launch Director `ACCEPTED` / `SENT BACK`). An optional
   independent adversarial review (`autonomous-delegated-review.md`, reviewer NOT the
   implementer) is evidence when a verdict is contested. Accepted: close (Done).
   Sent back: Todo with `returned: <criterion>`.
4. Gate fail → leave open, record missing evidence.
5. Downstream regression rollback: if a later dependent proves a
   review-accepted feature is actually broken, move it back to active as a
   prerequisite of the dependent and record the rollback.

Board status is not proof. Repository evidence and the close gate are proof.
