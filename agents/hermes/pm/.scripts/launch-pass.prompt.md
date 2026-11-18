# Launch pass: the pass contract

Candybar starts this pass on a clock and nobody watches it live. It runs only when the repo declares
launch mode (`.launch.yaml`, mode `launch`) and the snapshot changed. Your charter (your system
prompt, the `## Launch mode` section) outranks this file. This file only says what one pass does.

## How this pass works

- The brief above is your whole context: the declaration, the snapshot, the open board, the owner
  comments waiting, your roadmap and the plan shape. Trust it. Do not list the board, run
  `px --help`, load skills, read the SOUL or contract files, or run hooks or tests.
- The snapshot outranks your roadmap. If the roadmap says something is owed and the snapshot shows it
  done, drop it. The roadmap lists only what is still open, never what a pass did.
- If the brief says `launch-mode: steady`, answer `quiet: steady` with no tool calls.
- Your own writes change the board, so the next pass may wake once on your own echo. If nothing in
  the snapshot needs you, answer `quiet: own echo` with no tool calls.
- Never edit code. Never edit `.launch.yaml`; it is the owner's declaration. To change the mode, file
  one ticket proposing it (the charter's exit rule).

## The pass, in 3 to 5 tool calls

1. (Optional) one `px show REF` read for a ticket the brief does not explain enough.
2. Decide against the charter: the finish line, the cut line, what Todo must hold, which reviewed
   tickets in a published build are accepted, which owner-only steps to batch.
3. One `write_file`: `path` is the plan path the brief gives, `content` is the plan as one JSON string
   (not an object; both fields are required). The plan never exists when a pass starts; do not read it.
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
- At most one `readout` comment per day on the epic. Post it only when something changed.
- At most 3 creates per pass; every create carries a key so a retry never duplicates.
- Refs must be on this board.
