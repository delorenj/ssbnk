# Polish pass: the QA-cycle contract

Candybar starts this pass on a clock (the declaration's `polish.cadence`, default every 15 minutes)
and nobody watches it live. It runs only when the repo declares polish mode (`.launch.yaml`,
mode `polish`). Every fire is one QA cycle: the snapshot's `qa-slot` line changes every slot, so the
agent wakes every slot, around the clock. Your charter (your system prompt, the `## Polish mode`
section) outranks this file. This file only says what one cycle does.

Polish is the hectic exploratory-QA mode: the product works, and the mission is the user experience.
You are looking for ANYTHING, no matter how small, that can be improved or fixed. There are no rules
about what is ticketable: if you have an idea for an improvement, you create the ticket.

## How this cycle works

- The brief above is your starting context: the declaration (with the optional `polish:` hints:
  focus areas, repo QA commands, wip lanes, todo depth), the snapshot with the metrics line, the open
  board, the open polish ticket titles, the untagged comments waiting (a hint, never owner approval),
  your roadmap and the plan shape. Trust it. Do not list the board or run `px --help`.
- Explore the product. Run the declaration's `polish.qa` commands when present (an exploratory
  harness, e2e, screenshots), read the UI or gameplay code, skim recent commits and diffs, logs and
  screenshots you can produce. Look with fresh eyes: an element that blocks another, physics that
  feel wrong, copy that confuses, a slow screen, an inconsistent control.
- File what you find as creates. The title convention is `[area:kind] ...` with free-form lowercase
  words inside the brackets, e.g. `[ux:improvement] The location of the X element sometimes blocks Y`
  or `[physics:tweak] It is possible to apply an unrealistically high force to the cue ball`. The
  bracket words live INSIDE the title, never as a colon label (board-taxonomy keeps colon labels a
  closed axis). The driver adds the bare-word `polish` label itself.
- Dedupe first: the brief lists the open polish ticket titles. A finding already ticketed gets a
  comment with the new evidence, never a second ticket.
- Polish creates land in Backlog. Each cycle also tops Todo up to the declaration's `todo_depth`
  (default 2 x wip) with the highest-value polish tickets, best first (one `move` per ticket), so
  Krebs always has lanes to dispatch.
- Verdicts on polish tickets in review (In Progress + `lifecycle:review`) are yours, exactly as in
  launch mode: ACCEPTED closes with the evidence, SENT BACK names the failing criterion in a comment.
- Keep the roadmap short: what you explored this cycle and what to check next, nothing else. The
  metrics ledger (`runtime/polish-metrics.json`) is the driver's, never yours to write.
- Never edit code. Never edit `.launch.yaml`; it is the owner's declaration.

## The cycle, then the plan

1. Explore: the QA commands, the code, the diffs, the logs. This is the one pass that is expected to
   run repo commands before writing its plan.
2. (Optional) one `px show REF` read for a ticket the brief does not explain enough.
3. One `write_file`: `path` is the plan path the brief gives, `content` is the plan as one JSON
   string (not an object; both fields are required). The plan never exists when a cycle starts.
   Writes: creates for new findings, comments with new evidence, moves that top Todo up to
   `todo_depth`, verdict closes or send-backs on reviewed polish tickets, a short roadmap.
4. One `terminal` call: the `--apply` command the brief gives. The driver takes the board-driver
   lease, tags every comment, enforces the allowed ops, the lanes, the write cap and the create cap,
   releases the lease, writes your roadmap, updates the metrics ledger and prints a receipt line per
   write. Its output is your read-back. Do not check the board afterwards. Each apply is one QA cycle
   in the metrics, even with zero writes.
5. If the driver says `LEASE HELD`, nothing was written and the plan is kept: run the same `--apply`
   once more, then stop and say so.

Then your final answer: the cycle note, under 20 lines: what you explored, what you filed, Todo
depth now, anything left for the next cycle.

## Quiet answers

- `launch-mode: develop` in the brief: answer `quiet: develop` with no tool calls.
- `launch-mode: live`: answer `quiet: live` with no tool calls.
- Woken but nothing in the snapshot or the product needs you: answer `quiet: own echo` with no tool
  calls.

## Rules the driver enforces, so do not argue with them

- Every create gets the bare-word `polish` label, idempotency source `polish-pass` and a default key
  `polish:<hash>`; an explicit `key` still wins.
- Caps while polishing: 8 creates and 20 writes per cycle.
- `move` is Backlog or Todo only. In Progress is Krebs' lane; a ticket in review is handled by the
  verdict rules, not by moving it.
- A ticket carrying `agent:working` has a live turn on it: it is never moved, closed or cancelled.
- A ticket carrying `lifecycle:human` is the owner's: no write of any op lands on it.
- `comment`, `close` and `cancel` need a `text`.
- Create labels are bare words, or `risk:`, `needs:`, `xp:`; any other colon label is dropped.
- The launch dashboard is launch-only: `dashboard` ops in a polish plan are refused.
- A repo may keep its own notes in `.scripts/launch-pass.repo.md`; the brief prints them right after
  this file. They add to this contract and never override your charter.
