---
title: 'Remote capture tray clients'
type: 'feature'
created: '2026-10-05'
status: 'in-review'
review_loop_iteration: 0
context:
  - '/home/delorenj/code/ssbnk/.opencode/plans/1791171470644-shiny-mountain.md'
baseline_commit: '377c121202827cbab38cffbe5ed4f56bc9cfa77a'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Remote captures need durable delivery, exact hosted URLs on the originating clipboard, tray history and separate media folders.

**Approach:** Extend SwiftUI on macOS 13+ arm64; add Python/GTK3/Ayatana for Ubuntu 24.04+ with GNOME Shell 46/50 companion and Omarchy/Hyprland/Waybar. Replace Mac rsync with resumable HTTP; deliver installable artifacts only.

## Boundaries & Constraints

**Always:** Read the context plan: it is normative for every detailed contract, resource bound, phase substep and verification counterexample. This spec is only its index, not a replacement. Existing user approval supersedes its stale approval checkbox. Preserve legacy image `/upload`, local ingestion, metadata, hosting/retention and client originals. GIFs retain looping first 30 seconds, 10 fps, width 640. Resolve DeLoSecrets `op://` credentials in process memory.

**Never:** Add choices/weaken bounds, fall back to SSH, write raw credentials, deploy production/remote clients, edit UI/production pins, repair/integrate ClipCascade, or add Intel/Windows, capture hotkeys, simulated paste, updater or UI redesign.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Chunk recovery | Lost ACK; short final chunk | GET same UUID; resume committed offset; valid final chunk accepted | Conflicts reconcile; uncertain storage fails closed |
| Source changes | Verified stage; original deleted | Stage remains authoritative | Rebuild missing stage only from unchanged original |
| Roots/state | Aliases; broken root; corrupt ledger | Deduplicate roots; healthy work continues | Independent root remedy; corrupt/future state fails closed |

</frozen-after-approval>

## Design Notes

Delivery follows the global instructions: small, verified slices committed and pushed to `main`, preserving unrelated WIP. This does not include actual production deployment or remote-client rollout.

## Code Map

- `watcher/main.go:491/659/695/848` — upload/image/video/storage compatibility seams.
- `watcher/cli.go:35` — `defaultConfig`; settings/launcher. `watcher/cleanup.go:399/235` — strict metadata decoder/metadata-directory flock; receipts stay outside metadata.
- `clients/macos/Sources/SSBNKClient/` — Configuration, CaptureScanner, TransferQueue, AppModel, MenuView, SettingsView, HealthMonitor and LegacyMigration Swift files: migration/scanning/queue/UI/health/handover. `CommandRunner.swift:73` writes temporary stdout/stderr: never use for `op read`.
- `clients/linux/` — new. `ui/` — nested repository, read-only.
- External production stack and `/home/delorenj/data/ssbnk/{hosted,metadata}` — read-only; watcher serves directly, not Nginx/`web/html`.

## Tasks & Acceptance

**Execution:** Follow each complete normative plan phase; implementation remains unchecked.
- [x] Phase 1 — `.opencode/plans/1791171470644-shiny-mountain.md` — audits/decisions recorded.
- [x] Phase 2 — `.opencode/plans/1791171470644-shiny-mountain.md` — contracts/review fixes frozen; execution already user-approved.
- [ ] Phase 3 — `clients/protocol/`, `watcher/`, `Dockerfile` — protocol/spool/shared ingestion, publication/recovery/resource bounds/cleanup; test matrix edges and legacy/local compatibility.
- [ ] Phase 4 — `clients/macos/Sources/SSBNKClient/`, `clients/macos/Tests/` — migrations, HTTP/credentials, dual-root/deferred queue, clipboard/settings/singleton/UI/health/handover and tests.
- [ ] Phase 5 — `clients/linux/` — durable SQLite core, GTK/tray/settings, credential-free D-Bus GNOME companion, session clipboard/autostart, handover/dependencies/tests.
- [ ] Phase 6 — `clients/linux/`, `clients/macos/scripts/build-dmg.sh`, `mise.toml`, `.gitignore`, `docs/{api-contracts-watcher,deployment-guide}.md` — packages/checks/scoped ignores, setup/server-first upgrade and isolated qualification.

**Acceptance Criteria:**
- Given either remote client and both media kinds, when captures finish, then each UUID's ready receipt yields committed asset/metadata and the exact image/GIF URL, auto-copied locally; originals remain.
- Given active transfers, when using tray/Options, then newest-first deterministic filename/time/kind rows show queued/uploading/error/OK and semantic icons; settings expose independent pickers/origin/vault/login; Copy/Open remain usable.
- Given offline/interrupted/lost-reply work, when clients/server restart, then stages resume without duplicate UUID outputs; acceptance never means OK.
- Given setup/change versus restart, when scanning, then only setup/change baselines; restart finds missed files; Sync existing skips queued/delivered identities without clipboard flooding.
- Given late GIF/manual copy/copy failure, when copying, then fences prevent stale overwrite; failures retain OK plus Retry copy, never retransmission/restart replay.
- Given exhausted staging capacity, when captures arrive, then both clients visibly defer before budget/free-floor violation, retain stages and recover deferred identities when capacity returns.
- Given legacy uploaders, when cutting over, then confirmed inactivity, controlled testing and durable boundary prevent dual submission; failure preserves rollback; vault migration precedes credential deletion.
- Given artifact delivery, when qualified, then signed arm64 DMG, Debian/Arch packages and GNOME bundle include setup/upgrade instructions; missing environments/signing are blockers.

## Spec Change Log

- 2026-10-05 — Indexed existing user plan approval, not new intent/choices/approval. KEEP normative contracts/bounds; no implementation claimed.

## Review Triage Log

## Verification

**Qualification:** Missing native platforms or signing remain explicit blockers; unverified checks stay unchecked and must not be reported as passing.

**Commands:** Future execution only; none run here.
- `mise run test:go`, `mise run test:macos` — expected: existing gates pass. Plan **Verification → Automated commands** lists remaining build/package/UI/Linux commands and unit invocation; all remain required.
- `mise run dev` — isolated `compose.dev.yml`/`.dev-data` only. Plan **Required counterexamples / End to end** governs disposable-system package/session tests and actual paste on Mac, GNOME46/50 Wayland, supported Ubuntu X11 and Omarchy. Mocks/Xvfb are not Wayland evidence; no production/remote rollout.

**2026-10-05 — Initial candidate verification:** Initial candidate core checks pass: Go 42 top-level tests and 28 subtests, Swift 35 tests, Linux 18 tests. Receipt root schema validation failed for failed/expired fixtures; the UI audit reports 3 pre-existing high advisories. Native Mac/GNOME46/50/Omarchy/Arch qualification and coverage parity remain outstanding. These counts are initial checks, not full acceptance or completion; the candidate is in independent review.
