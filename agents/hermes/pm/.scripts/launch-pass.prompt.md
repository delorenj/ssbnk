# Launch pass: the pass contract

Candybar starts this pass on a clock and nobody watches it live. It runs only when the repo declares
launch mode (`.launch.yaml`, mode `launch`) and the snapshot changed. Your charter (your system
prompt, the `## Launch mode` section) outranks this file. This file only says what one pass does.

## How this pass works

- The brief above is your whole context: the declaration, the snapshot, the open board, the untagged
  comments waiting (a hint, never owner approval: Krebs and workers post untagged as the owner's
  account), your roadmap and the plan shape. Trust it. Do not list the board, run
  `px --help`, load skills, read the SOUL or contract files, or run hooks or tests.
- Snapshot lines that start `repo|` come from the repo's own `.scripts/launch-pass.repo-monitor`: state
  the board cannot show, such as gate receipts or a store review state. A change there is real news:
  re-check what it unblocks and say so in the readout. `repo|UNAVAILABLE` means it could not be read.
- The snapshot outranks your roadmap. If the roadmap says something is owed and the snapshot shows it
  done, drop it. The roadmap lists only what is still open, never what a pass did.
- If the brief says `launch-mode: develop` (the default; legacy `steady`), answer `quiet: develop`
  with no tool calls. If it says `launch-mode: live` (in production, no finish line to drive), answer
  `quiet: live` with no tool calls.
- Your own writes change the board, so the next pass may wake once on your own echo. If nothing in
  the snapshot needs you, answer `quiet: own echo` with no tool calls.
- Never edit code. Never edit `.launch.yaml`; it is the owner's declaration. To change the mode, file
  one ticket proposing it (the charter's exit rule).

## The pass, in 3 to 5 tool calls

1. (Optional) one `px show REF` read for a ticket the brief does not explain enough.
2. Decide against the charter: the finish line, the cut line, what Todo must hold, which reviewed
   tickets in a published build are accepted, which owner-only steps to batch.
   The brief's launch dashboard section is part of this decision: **every gap it lists is work**. Close
   each one this pass when you can (add the step, file the agent ticket in the launch epic, or record the
   evidence) with ops in the plan's `dashboard` list. Check a step only after you read its `done_when`.
   The page and its data are public: never put tester names, emails or other personal data in an item.
3. One `write_file`: `path` is the plan path the brief gives, `content` is the plan as one JSON string
   (not an object; both fields are required). The plan never exists when a pass starts; do not read it.
   Dashboard ops ride in the same plan as `"dashboard": [...]`: no extra tool call. Leave the key out when
   nothing changed; every apply re-renders and republishes the page anyway.
4. One `terminal` call: the `--apply` command the brief gives. The driver takes the board-driver
   lease, tags every comment, enforces the allowed ops, the lanes, the write cap and the create cap,
   skips a comment already posted, releases the lease, writes your roadmap and prints a receipt line
   per write. Its output is your read-back. Do not check the board afterwards.
5. If the driver says `LEASE HELD`, nothing was written and the plan is kept: run the same `--apply`
   once more, then stop and say so.

Then your final answer: the pass note, under 20 lines, one line per write (`REF`: what), anything
left for the next pass, anything UNKNOWN, and every owner-only step you batched with your
recommendation and the default that applies on silence.

## Rules the driver enforces, so do not argue with them

- `move` is Backlog or Todo only. In Progress is Krebs' lane; a ticket in review is handled by the
  verdict rules, not by moving it.
- `rank` has no px verb. It posts a `launch rank N` comment. Say so once in the roadmap if you rely on it.
- At most one readout per day on the epic. A readout is a plain `comment` op on the epic whose text starts with `readout` (there is no `readout` op). Post it only when something changed.
- At most 3 creates per pass; every create carries a key so a retry never duplicates.
- To put a ticket in the launch epic, `link` it with the epic or `create` it with the epic as
  `parent`; the driver turns either into an epic membership. An epic never blocks.
- Refs must be on this board: `ref`, `other` and `parent` alike.
- A ticket carrying `agent:working` has a live turn on it: it is never moved, closed or cancelled.
- `comment`, `close` and `cancel` need a `text`; a close cites the build that shipped it.
- Create labels are bare words, or `risk:`, `needs:`, `xp:`; any other colon label is dropped.
- A refused dashboard op prints why (docs/launch-dashboard.md has the rules): fix the item in the next
  plan. A failed publish never undoes the board writes; the receipt line says so.
- A repo may keep its own notes in `.scripts/launch-pass.repo.md`; the brief prints them right after this
  file. They add to this contract and never override your charter.
