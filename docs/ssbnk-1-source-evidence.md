# SSBNK-1 source evidence (branch-only)

This records source checks, not acceptance or deployment proof. No live desktop paste, remote upload, reboot, or production change was performed for this branch. The implementation is not approved for main until an independent quality gate is rerun.

| Criterion / behavior | Source evidence | Live evidence |
| --- | --- | --- |
| Remote screenshot upload from Linux and macOS starts at login | Installer and uploader wiring documented in `docs/remote-clipboard-setup.md`; no fresh install test | Untested. An enabled/active Linux unit previously observed does not prove a fresh screenshot or reboot. macOS agent not verified. |
| Remote upload publishes hosted image, bare filename and URL state | `watcher/upload_test.go` asserts response, byte-identical hosted file, decodable PNG, filename and URL markers | Untested end-to-end on either device; no sub-two-second timing proof. |
| Host desktop bridge copies upload URL, including repeated URL publication | `watcher/state_test.go` exercises atomic marker, retry and repeated-publication bridge calls through injected `Copy` | Real Wayland clipboard ownership and desktop-session bridge startup untested. |
| Paste-image inserts latest image and restores the original text | `scripts/test-paste-image.sh` shims `wl-copy`, `wl-paste`, `ydotool`; checks image write, key sequence and byte-identical text restoration (including trailing newlines and empty text) | No GNOME focus, actual image insertion, or Ctrl+V-before/after proof. |
| Missing marker/image, unreadable clipboard and failed restoration | Shell shim tests nonzero/notification/no mutation on early failures; restoration failure is nonzero with notification and stderr, leaving image offered; failed key injection still restores text | No real notification/ydotool/Wayland failure-path proof. |
| Local screenshot supersedes latest remote image | `watcher/state_test.go` checks local hosted decodable image and filename/URL state | No live host screenshot or paste proof. |
| URL resolves to actual hosted image | Unit tests check hosted bytes and markers; no HTTP fetch from production | Untested publicly hosted URL or real remote-to-host bytes. |
| Remote services survive reboot and resume fresh upload | No reboot test | Untested on both machines. |

Source checks in this worktree: `bash -n scripts/paste-image.sh scripts/test-paste-image.sh` (exit 0); `bash scripts/test-paste-image.sh` (exit 0, `paste-image shell contract passed`); `cd watcher && mise exec -- go test ./...` (exit 0, `ok ssbnk-watcher 6.886s`, then cached on rerun); `cd watcher && mise exec -- gofmt -d upload_test.go state_test.go` (exit 0, no diff); `git diff --check` (exit 0). Shell tests use text shims, not a real PNG or live clipboard; Go tests use a generated and decoded 2×2 PNG, not a desktop paste. An initial combined invocation from `watcher/` failed because the script paths were wrong; a later combined invocation from repository root failed because Go module tests must run in `watcher/`. Each check was then rerun from its correct directory and passed.

`docs/remote-clipboard-setup.md` is the current source guide for this branch. Protected `AGENTS.md` remains stale and contradictory pending authorization; it and `CLAUDE.md` were not edited. Production compose/mounts, remote device and desktop checks require separate operator approval and evidence.
