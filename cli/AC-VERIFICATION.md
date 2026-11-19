# SSBNK-4 CLI acceptance checks

Repair branch `ssbnk-4-cli-multi-get` extends the original multi-image change. Run from the worktree root:

```sh
cli/.venv/bin/python -m unittest discover -s cli/tests -v
```

Repair run: 16 tests passed (`OK`, 0.111s). The suite covers all eight ticket criteria: default and explicit counts, marker priority (including a missing absolute marker with a matching basename), newest-first directory ordering and tie-break, configured directory fallback and deduplication, malformed or missing ledger entries, exact stdout and single clipboard payload, fewer/no images, invalid counts and help, and no-copy/warning/quiet modes. Clipboard calls inside unit tests are mocked.

The **earlier independent review of commit `a55922280fb77759cb4a48a4e1a43f1c4b590ff3`** also executed the real CLI with three local test images and read back the Wayland clipboard with `wl-paste --no-newline`: exit 0, three stdout paths, and clipboard readback exactly matched the newline-joined stdout paths (without its trailing newline), including `old image.PNG`. That check predates this repair and is **not** a fresh clipboard check of the repair commit. The reviewer could not preserve the pre-existing clipboard contents; do not rerun its scratch probe on a user's clipboard. A safe post-repair clipboard check and independent review remain for the parent handoff.
