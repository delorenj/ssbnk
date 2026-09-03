---
title: 'Native macOS menu-bar sync client'
type: 'feature'
created: '2026-09-03'
status: 'draft'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The current Mac client is an ad-hoc shell bundle watching the stale `/Users/delorenj/Screenshots` path, uploads images only, exposes no status, and leaves a plaintext HTTP credential behind. Native macOS captures now land in `/Users/delorenj/Pictures/Screenshots`, with screenshots and recordings sharing that folder.

**Approach:** Ship an arm64-native, Developer-ID-signed `SSBNK Client.app` in a DMG. A menu-bar interface will validate local capture settings and the SSH/rsync route, classify stable new images and videos into a persistent outbox, transfer each once to its exact server watch root, and report Healthy, Syncing, or Needs Attention.

## Boundaries & Constraints

**Always:** Preserve Mac originals; support one local folder serving both media types; baseline existing files on first launch; persist queue and delivery state across restarts; invoke `/usr/bin/ssh` and `/usr/bin/rsync` with argument arrays and batch-mode SSH; deliver atomically without `--inplace`; route supported image formats to `/home/delorenj/Pictures/Screenshots` and video formats to `/home/delorenj/Videos/Screencasts`; expose configured mappings, queue depth, last success/error, Test Connection, Sync Now, Sync Existing, launch-at-login, and folder selection; retire the legacy agent and raw upload credential only after the new route is healthy.

**Never:** Change the server ingestion API or production mounts; delete capture originals; periodically mirror the source directory; use `--delete`, `--remove-source-files`, shell-concatenated commands, LAN IPs, an HTTP upload key, Homebrew runtime dependencies, or auto-import pre-existing captures. App Store sandboxing, Intel support, clipboard URL correlation, and public notarization are outside this first package; notarization can follow once a notarytool keychain profile exists.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| First launch | Capture folder already has files | Record a baseline; upload nothing; show both routes | Missing folder or SSH route yields Needs Attention with a specific remedy |
| New capture | Stable supported image or video, including spaces/Unicode | Copy to the correct outbox, rsync to the matching watch root, retain original, record delivery | Retry queued copy with bounded backoff and retain actionable last error |
| Shared source | Images and MOV/MP4 files arrive in one directory | Classify by extension and send each to its distinct server target | Unsupported files are ignored and never queued |
| Restart/offline | Pending queue, sleep, network loss, or app restart | Recover queue and resume without rescanning delivered originals | Health stays degraded until SSH/write checks and a sync succeed |
| Explicit history | User chooses Sync Existing | Queue supported current files once after confirmation | Deduplicate against delivered ledger and pending outbox |

</frozen-after-approval>

## Code Map

- `scripts/install-remote-client.sh:137-310` -- reuse macOS launchd/TCC and end-to-end validation knowledge; do not extend the credential uploader.
- `scripts/remote-screenshot-upload.sh:89-177` -- reuse stability/retry semantics; current implementation is image-only HTTP/fswatch.
- `watcher/main.go:84-117,659-817,948-1020` -- source of truth for direct watch-root events, supported extensions, source deletion, stability, and conversion behavior; read-only for this feature.
- `/home/delorenj/docker/stacks/utils/ssbnk/compose.yml` -- read-only production mapping evidence: host screenshot and screencast roots map to `/media/screenshots` and `/media/screencasts`.
- `clients/macos/` -- new native client, tests, assembly scripts, and operator documentation.
- `mise.toml` -- add Mac build/test/package tasks without changing Linux service tasks.

## Tasks & Acceptance

**Execution:**
- [ ] `clients/macos/Package.swift`, `Sources/SSBNKClient/{SSBNKClientApp,AppModel,Configuration,CommandRunner}.swift` -- create the menu-bar-only app, persisted non-secret configuration, launch-at-login control, and safe process execution.
- [ ] `clients/macos/Sources/SSBNKClient/{CaptureScanner,TransferQueue,HealthMonitor}.swift` -- implement stable-file classification, first-run baseline, atomic persistent ledger/outbox, retry, rsync routing, and the composite health state.
- [ ] `clients/macos/Sources/SSBNKClient/{MenuView,SettingsView,LegacyMigration}.swift` -- expose status/actions/mappings and safely disable the legacy LaunchAgent and remove its credential config after successful replacement.
- [ ] `clients/macos/Tests/SSBNKClientTests/` -- cover configuration, classification, baseline/deduplication, queue recovery, health reduction, retry scheduling, and exact command arguments with fakes.
- [ ] `clients/macos/scripts/build-dmg.sh`, `clients/macos/Resources/Info.plist`, `clients/macos/README.md`, `.gitignore`, `mise.toml` -- assemble, Developer-ID sign, verify, and document the untracked `clients/macos/dist/SSBNK-Client.dmg` artifact.

**Acceptance Criteria:**
- Given the current Mac and server settings, when the app opens, then its menu displays both source-to-destination mappings and Healthy only after both local paths, public health, batch SSH, remote write access, and latest sync state pass.
- Given one newly created PNG and one MOV in the shared capture folder, when each becomes stable, then each appears once in the public gallery through its correct server watch root while both Mac originals remain.
- Given the legacy uploader is active, when the new client first becomes healthy and migration is confirmed, then the old launch job is disabled and no plaintext upload credential remains.
- Given a reboot or temporary network failure, when connectivity returns, then launch-at-login restores the client and pending work completes without replaying delivered captures.
- Given the physical Apple Silicon Mac, when the package script runs, then `swift test`, signature verification, DMG mounting, installation, launch, and menu-bar interaction all succeed.

## Spec Change Log

## Review Triage Log

## Design Notes

The server consumes and deletes its watched-folder inputs, so the client cannot mirror retained originals directly. It must baseline and ledger source identities, stage only unseen stable files in an app-owned outbox, and remove only an outbox copy after rsync succeeds. Normal rsync temporary-file rename behavior is required so the watcher never sees a partially written screenshot.

## Verification

**Commands:**
- `ssh carries-macbook-air 'cd /tmp/ssbnk-macos-client && swift test'` -- all deterministic unit tests pass on Swift 6.3.3 after staging `clients/macos/` there.
- `clients/macos/scripts/build-dmg.sh` on `carries-macbook-air` -- produces a signed arm64 DMG and passes `codesign --verify --deep --strict`.
- Physical smoke test -- app launches without a Dock icon, reaches Healthy, survives relaunch, transfers one PNG and one MOV, and `https://ss.delo.sh/health` plus the rendered gallery confirm ingestion.
