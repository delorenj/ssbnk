---
title: 'Native macOS menu-bar sync client'
type: 'feature'
created: '2026-09-03'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'a0a7114f54c34b8db1b8ab84db769192d891728a'
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
- [x] `clients/macos/Package.swift`, `Sources/SSBNKClient/{SSBNKClientApp,AppModel,Configuration,CommandRunner}.swift` -- create the menu-bar-only app, persisted non-secret configuration, launch-at-login control, and safe process execution.
- [x] `clients/macos/Sources/SSBNKClient/{CaptureScanner,TransferQueue,HealthMonitor}.swift` -- implement stable-file classification, first-run baseline, atomic persistent ledger/outbox, retry, rsync routing, and the composite health state.
- [x] `clients/macos/Sources/SSBNKClient/{MenuView,SettingsView,LegacyMigration}.swift` -- expose status/actions/mappings and safely disable the legacy LaunchAgent and remove its credential config after successful replacement.
- [x] `clients/macos/Tests/SSBNKClientTests/` -- cover configuration, classification, baseline/deduplication, queue recovery, health reduction, retry scheduling, and exact command arguments with fakes.
- [x] `clients/macos/scripts/build-dmg.sh`, `clients/macos/Resources/Info.plist`, `clients/macos/README.md`, `.gitignore`, `mise.toml` -- assemble, Developer-ID sign, verify, and document the untracked `clients/macos/dist/SSBNK-Client.dmg` artifact.

**Acceptance Criteria:**
- Given the current Mac and server settings, when the app opens, then its menu displays both source-to-destination mappings and Healthy only after both local paths, public health, batch SSH, remote write access, and latest sync state pass.
- Given one newly created PNG and one MOV in the shared capture folder, when each becomes stable, then each appears once in the public gallery through its correct server watch root while both Mac originals remain.
- Given the legacy uploader is active, when the new client first becomes healthy and migration is confirmed, then the old launch job is disabled and no plaintext upload credential remains.
- Given a reboot or temporary network failure, when connectivity returns, then launch-at-login restores the client and pending work completes without replaying delivered captures.
- Given the physical Apple Silicon Mac, when the package script runs, then `swift test`, signature verification, DMG mounting, installation, launch, and menu-bar interaction all succeed.

## Spec Change Log

- 2026-09-03 — Implemented, adversarially reviewed, packaged, installed, and exercised on `carries-macbook-air`; added Command Line Tools-compatible Swift Testing after native XCTest was found unavailable.

## Review Triage Log

- `patch` (high) — transactional queue persistence and recovery: fixed the stale-index crash after a successful rsync, surfaced retry-state persistence failures, validated/quarantined incompatible state, rebuilt missing pending-ledger entries, reconciled outbox manifests, and added regression coverage. Covers blind-hunter 1, 3, and 18 plus edge-case-hunter 19, 22-27 and verification-gap 7.
- `patch` (high) — capture identity and baseline correctness: verified source/staged bytes, added inode/creation identity, made cancellation propagate, protected an initially changing baseline file, allowed first-call Sync Existing, skipped stability delays for known originals, and stopped path-only baselines from hiding replacement captures. Covers blind-hunter 4, 5, 9-11 plus edge-case-hunter 7, 9, 10, 13, 21, and 26 plus verification-gap 3-4.
- `patch` (high) — scan and watcher liveness: retained dirty events while busy, periodically rescanned unstable files, continued after per-file staging failures, and reopened invalidated/recreated watch directories while reflecting watcher failure in health. Covers blind-hunter 6-8 plus edge-case-hunter 4, 6, 8, 11, and 12.
- `patch` (high) — configuration/health concurrency: serialized connection tests, snapshotted configuration per cycle, cleared/discarded stale health, gated invalid transfers, made scan errors visible in status, and required a fresh current-configuration health report before legacy retirement. Covers blind-hunter 12, 15-16 plus edge-case-hunter 2-5, 18, and 20.
- `patch` (high) — process and endpoint health: replaced pipe buffering with private file-backed capture, added process deadlines, decoded the health payload and rejected warning/non-2xx/invalid responses, and covered every health prerequisite independently. Covers blind-hunter 14 and 17 plus edge-case-hunter 14-16 plus verification-gap 6.
- `patch` (medium) — lifecycle and migration edges: handled pending login-item approval, detected/booted a loaded legacy job without its plist, and proved failed bootout preserves both legacy artifacts. Covers blind-hunter 19 plus edge-case-hunter 1 and 17 plus verification-gap 8.
- `patch` (medium) — verification adoption and packaging: added the Swift suite to the aggregate mise test, covered forced retry, required an installed Developer ID Application identity, and signed both app and DMG. Covers edge-case-hunter 30 plus verification-gap 1 and 5.
- `dismissed` (medium) — blind-hunter 2: a power loss after remote rsync completion but before local ledger persistence can replay. The consequence is real, but eliminating that distributed commit window requires a server ingestion acknowledgment/idempotency protocol, which would edit the approved no-server/API boundary; the client retains the recoverable at-least-once behavior selected by the spec.
- `dismissed` (medium) — edge-case-hunter 27: local staging, remote delivery, and cleanup cannot form one atomic transaction across two machines. Transactional local state and manifest recovery were added; a stronger atomicity claim requires changing the approved server contract.
- `dismissed` (medium) — edge-case-hunter 28: rsync success precedes asynchronous watcher ingestion. The server watch-root handoff is the approved contract and clipboard/URL correlation is explicitly out of scope; actual PNG/MOV ingestion remains a required physical acceptance test.
- `dismissed` (medium) — edge-case-hunter 29: the reboot replay claim is the same unavoidable unacknowledged remote-commit window, not a locally patchable defect within the frozen server boundary.
- `dismissed` (low) — blind-hunter 13: requiring `lastSuccessAt` would prevent a clean first launch from becoming Healthy until a user creates a capture. The approved initial latest-sync state is no queued failure, while route readiness is established by the explicit health, SSH, and write probes.
- `dismissed` (low) — blind-hunter 20: the package script is not claimed to prove interactive behavior; the spec separately requires native build/sign/mount followed by physical installation, launch, menu interaction, and live media proof.
- `dismissed` (low) — verification-gap 2: startup-to-watch behavior cannot be proven by the cross-platform component suite alone, but it is not being treated as verified; native launch and filesystem-event behavior remain explicit physical acceptance checks.
- `dismissed` (low) — edge-case-hunter 31: structural package verification is intentionally followed by the separate physical Mac launch/menu/live-transfer verification, so no acceptance evidence is inferred from mounting and codesign alone.

## Design Notes

The server consumes and deletes its watched-folder inputs, so the client cannot mirror retained originals directly. It must baseline and ledger source identities, stage only unseen stable files in an app-owned outbox, and remove only an outbox copy after rsync succeeds. Normal rsync temporary-file rename behavior is required so the watcher never sees a partially written screenshot.

## Verification

**Commands:**
- `mise run test` — passed Go race tests/vet/govulncheck, UI audit/static build, and all 40 macOS client tests.
- `ssh carries-macbook-air 'cd /tmp/ssbnk-macos-client.OW0wke && swift test'` — 40 tests in six Swift Testing suites passed with Apple Swift 6.3.3 and Command Line Tools only.
- `clients/macos/scripts/build-dmg.sh` on `carries-macbook-air` — built arm64, Developer-ID signed the app and DMG, mounted the DMG, and passed strict signature verification for the mounted app.
- Installed `/Applications/SSBNK Client.app` — Mach-O arm64, `LSUIElement=true`, Application Type `UIElement`, and Accessibility status label `SSBNK Client, Healthy`; quit/reinstall/relaunch preserved state without replay.
- Live mixed-media proof — `SSBNK Client E2E 20260903T213000Z ü.png` entered `/media/screenshots` once and serves as `https://ss.delo.sh/20260903-2129.png`; the matching MOV entered `/media/screencasts` once, converted once, and serves as `https://ss.delo.sh/20260903-2130.gif`. Both originals remain on the Mac and the queue is empty.
- Legacy cutover — verified the upload credential's 1Password copy, unloaded `gui/502/sh.delo.ss.remote-upload`, and removed only its LaunchAgent plist and plaintext `remote.env`. The app remains Healthy afterward.
- The desktop was locked during final automation. Accessibility successfully queried and pressed the enabled status item, but the user-controlled launch-at-login toggle remains available rather than being silently enabled.

## Suggested Review Order

**Entry and state machine**

- A menu-only SwiftUI entry point starts synchronization immediately and exposes health accessibly.
  [`SSBNKClientApp.swift:7`](../../clients/macos/Sources/SSBNKClient/SSBNKClientApp.swift#L7)

- One MainActor model serializes scans, retries, health checks, settings, and migration.
  [`AppModel.swift:40`](../../clients/macos/Sources/SSBNKClient/AppModel.swift#L40)

- Pending work drains against immutable configuration snapshots to prevent stale health.
  [`AppModel.swift:257`](../../clients/macos/Sources/SSBNKClient/AppModel.swift#L257)

**Durable media pipeline**

- The scanner baselines first launch and stages only stable shared-folder media.
  [`CaptureScanner.swift:193`](../../clients/macos/Sources/SSBNKClient/CaptureScanner.swift#L193)

- The actor-backed queue atomically records staging, retry, recovery, and delivery state.
  [`TransferQueue.swift:118`](../../clients/macos/Sources/SSBNKClient/TransferQueue.swift#L118)

- Argument-array commands enforce batch SSH and route media without source deletion.
  [`CommandRunner.swift:153`](../../clients/macos/Sources/SSBNKClient/CommandRunner.swift#L153)

**Health, UI, and migration**

- Composite health requires local storage, public status, SSH, and both writable roots.
  [`HealthMonitor.swift:148`](../../clients/macos/Sources/SSBNKClient/HealthMonitor.swift#L148)

- The menu exposes mappings, queue state, controls, and actionable health.
  [`MenuView.swift:5`](../../clients/macos/Sources/SSBNKClient/MenuView.swift#L5)

- Legacy retirement gates deletion on fresh health and explicit confirmation.
  [`LegacyMigration.swift:68`](../../clients/macos/Sources/SSBNKClient/LegacyMigration.swift#L68)

- Settings centralize mappings, launch-at-login, and guarded legacy retirement.
  [`SettingsView.swift:39`](../../clients/macos/Sources/SSBNKClient/SettingsView.swift#L39)

**Packaging and proof**

- A pinned Swift Testing distribution keeps Command Line Tools verification reproducible.
  [`Package.swift:5`](../../clients/macos/Package.swift#L5)

- Packaging tests, signs, mounts, and re-verifies an arm64 DMG.
  [`build-dmg.sh:1`](../../clients/macos/scripts/build-dmg.sh#L1)

- Mixed-media tests prove routing, Unicode handling, retention, and deduplication.
  [`CaptureScannerTests.swift:63`](../../clients/macos/Tests/SSBNKClientTests/CaptureScannerTests.swift#L63)

- Recovery tests exercise offline retry, corrupted state, restaging, and transactional failures.
  [`TransferQueueTests.swift:8`](../../clients/macos/Tests/SSBNKClientTests/TransferQueueTests.swift#L8)

- The aggregate repository gate now includes the macOS suite.
  [`mise.toml:87`](../../mise.toml#L87)
