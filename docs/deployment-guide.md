# Deployment guide

Production deployment is intentionally separate from application development.
The source repository builds the canonical image; the DeLoContainers hub pins
qualified releases by digest and defines how they run on this host. Candidate
source or local artifacts are not proof of production promotion.

## Remote-client candidate status (2026-10-05)

The new HTTP tray clients are **candidates, not a completed rollout**. No
production promotion or remote-client installation has been performed for this
work. The development host is Linux/Ubuntu 25.10 with GNOME Shell 49; it does
not qualify any of the target native desktop platforms.

| Target | Outstanding qualification |
| --- | --- |
| macOS 13+ on Apple Silicon | Native SwiftUI build/UI, Developer ID signing/DMG, installation/login, and paste into another focused application |
| Ubuntu 24.04 / GNOME Shell 46; Ubuntu 26.04 / Shell 50 | Native GTK/GI, ACTIVE companion, Wayland background copy and actual paste, login/logout, lock/unlock and reconnect; supported X11 session checks |
| Current Omarchy / Hyprland / Waybar | Arch `makepkg` build, package install/uninstall, real tray/session/autostart, and actual clipboard paste |

Debian and GNOME bundle files in `clients/linux/dist/` are local candidate
artifacts, not package-install or native-session evidence. Arch packaging and
package-install tests remain unqualified. Core tests, Linux-host Swift tests,
mocks, and Xvfb do not qualify Mac UI or GNOME/Hyprland Wayland paste. The Mac
packaging script signs but does **not** notarize; no signing/notarization claim
is implied here. See [candidate gaps](#candidate-gaps-against-the-approved-plan)
before attempting handover.

## Ownership boundary

Use these repositories for distinct changes:

| Repository | Owns |
| --- | --- |
| `/home/delorenj/code/ssbnk` | Go, UI and client source, tests, client packaging, `Dockerfile`, `compose.dev.yml`, mise tasks, and image CI |
| `/home/delorenj/docker/stacks/utils/ssbnk` | Production digest, Compose services, mounts, secret references, Traefik routing, and systemd units |

Don't copy application source or a cleanup script into the deployment hub.
Don't put production host paths, live image promotion, or service scheduling in
the source repository.

## Canonical image

The root source `Dockerfile` publishes one image at
`docker.io/delorenj/ssbnk`. It contains:

- `/usr/local/bin/ssbnk`, with `serve`, `cleanup`, and `clipboard-bridge`;
- the Astro static build at `/ui`;
- `ffmpeg` for screencast conversion; and
- `wl-copy` for the isolated clipboard role.

CI publishes `sha-<commit>`, semantic-version, and default-branch tags to
Docker Hub and GitHub Container Registry. Production Compose uses a tag plus
its `sha256` digest so a registry tag change cannot alter a running deployment.

## Production services

The production Compose file reuses the pinned image in three roles:

| Service | Command | Network | Sensitive mounts |
| --- | --- | --- | --- |
| `ssbnk` | `serve` | External `proxy` | Media input and `/data`; no display socket |
| `clipboard` | `clipboard-bridge` | `none` | Read-only `/data/state` and the exact Wayland socket |
| `cleanup` | `cleanup` | `none` | Read-write `/data`; maintenance profile only |

All roles run as UID and GID 1000 with a read-only root filesystem, dropped
capabilities, and `no-new-privileges`. The public service receives a small
writable `/tmp` mount for temporary work. Resumable inputs and prepared media
outputs belong under `/data/spool`, never in that small tmpfs. Only the public
service joins the Traefik network, and it exposes no host port.

Canonical production hosted and metadata directories remain
`/home/delorenj/data/ssbnk/hosted` and `/home/delorenj/data/ssbnk/metadata`, under
the container's `/data` mount. The retired source-tree `web/html/` and Nginx
layout are not deployment targets.

The screenshot and screencast source mounts are intentionally read-write.
Successful ingestion removes the original after storing the hosted copy, so a
read-only source mount would silently change the service into an accumulating
copy-only workflow.

The cleanup role receives the production `SSBNK_URL` and explicit
`SSBNK_STATE_DIR=/data/state`. These values let it repair a latest marker even
when the chosen remaining asset doesn't have metadata.

The clipboard service mounts one path:

```text
${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}
```

It doesn't mount the full runtime directory or `/tmp/.X11-unix`, and it has no
network. The public service can't access the desktop session.

## Secrets and routing

The deployment hub keeps `SSBNK_UPLOAD_KEY` as an `op://` reference in
`.env.op`. The system service launches the public Compose operation through
`op run`, so the credential exists only in that runtime environment. The
cleanup and clipboard units don't receive the upload key.

Traefik routes `https://ss.delo.sh` to port 80 of the public service on the
external `proxy` network. The application serves the UI, API, and hosted assets
directly. There is no Nginx or frontend proxy inside the stack.

## systemd operation

Versioned units under `/home/delorenj/docker/systemd` and
`/home/delorenj/docker/systemd/user` control three lifecycles:

- `docker-stack-ssbnk.service` validates the production environment, pulls the
  pinned image, and starts the public service.
- The cleanup timer invokes a one-shot service that runs the maintenance
  profile with `ssbnk cleanup`.
- The `ssbnk-clipboard.service` user unit follows the graphical session and
  starts only the network-disabled desktop profile.

The timer runs daily at 02:00 local time and uses `Persistent=true`, so a missed
run occurs after the host returns. Scheduling stays outside the image; the
cleanup container exits after one execution.

## Server-first upgrade and promotion

The procedure below is for a later authorized promotion; it has not been
performed for these candidates. Keep the old image/digest and old uploader
available until native qualification and controlled handover succeed.

1. Complete source checks, isolated protocol/media recovery checks, image build,
   and native client/package qualification. Local development uses `mise run dev`
   with `compose.dev.yml` and `.dev-data`, never production media.
2. Land the source release and record its published `sha-<commit>` tag and
   `sha256` digest. Update the exact reference in the deployment hub, validate
   the rendered configuration without printing secrets, and publish that change.
3. Upgrade the **server and cleanup role before enabling new client submissions**.
   Preserve `/data/spool` across restarts. The serve process requires writable
   spool, hosted and metadata directories on one filesystem supporting hard
   links and directory sync, plus enough free space for live reservations and
   the 512 MiB floor. Do not split these onto separate mounts or delete journals
   to recover capacity. Use consistent `SSBNK_UPLOAD_*` limits in serve and cleanup:
   cleanup also validates journals before protecting unfinished publications.
4. Restart the stack systemd service and graphical-session clipboard service so
   all roles use the promoted image. Inspect health/logs and authenticated
   `GET /api/uploads/capabilities` through the **final HTTPS origin**. Require
   version 2 and processing readiness. Confirm `SSBNK_URL` exactly matches the
   clients' API origin: both clients reject result URLs from a different origin.
5. Verify the actual Traefik/Cloudflare route's body limits, request/response
   timeouts, raw PUT bodies, explicit lengths and upload headers. Exercise a
   normal chunk, a short final chunk, lost-ACK/status recovery, restart, image
   readiness and GIF conversion. Application limits do not establish the zone's
   proxy limits; a 1 GiB recording is many small requests, not one large POST.
6. Check the public UI, `/health`, legacy image `/upload`, local intake, state
   publication, and the separate host clipboard role. Preview cleanup with
   `--dry-run`; cleanup must protect unfinished publication and leave live spool
   input ownership to serve.
7. Only then set up a qualified remote client and perform the
   [one-uploader handover](#one-uploader-handover-and-rollback) for that machine.

A legacy server's UI fallback or public `/health` success is insufficient.
An unavailable/invalid v2 capabilities response means **server upgrade
required**. The clients never silently switch to SSH/rsync or legacy `/upload`.

For image rollback, stop new submissions first, retain the spool and receipts,
and revert the deployment pin to the recorded prior digest. A pre-v2 image
cannot resume v2 sessions: stop the tray clients rather than abandoning their
UUIDs/stages or recreating accepted work. Coordinate cleanup rollback as well;
older cleanup must not delete unfinished v2 publication. Verify health and use
the controlled client rollback below before restoring legacy uploading.

## Remote tray client setup

The current candidates are `clients/macos` and `clients/linux`. They retain
client originals, stage private copies, and obtain capture-specific hosted
image/GIF URLs over authenticated HTTP v2. They need no SSH access, server
filesystem mounts, or access to the server's Wayland session.

### Build and installation prerequisites

These are commands for later builds/qualification, not checks run by this
documentation change. Use disposable target systems before installing on
remote machines.

| Candidate artifact | Build task | Requirements |
| --- | --- | --- |
| `clients/macos/dist/SSBNK-Client.dmg` | `mise run package:macos` | macOS on arm64, Swift 6.3.3, Apple packaging tools, available `Developer ID Application: …` identity selected by `DEVELOPER_ID_APPLICATION` |
| `clients/linux/dist/ssbnk-client_0.1.0_all.deb` | `mise run package:linux:deb` | Distro Python 3.12+, `dpkg-deb` |
| Arch package under `clients/linux/dist/` | `mise run package:linux:arch` | Disposable Arch system with `makepkg` and native build/runtime dependencies; current script uses `--nodeps`, so it is not a dependency/install test |
| `clients/linux/dist/ssbnk@delo.sh.shell-extension.zip` | `mise run package:linux:gnome` | Distro `gnome-extensions pack` tooling; no substitute zip build |

Other source tasks are `test:go`, `test:ui`, `test:macos`, `build:macos`,
`test:linux`, `lint:linux`, and `typecheck:linux`. Linux tests use `python3`;
Ruff/mypy tasks use pinned tools via `uvx`, which must be installed. GI is a
**distro desktop dependency**, not a pip dependency assumed present in a mise
Python environment.

| Native Linux runtime | Declared dependencies |
| --- | --- |
| Debian/Ubuntu | `python3` (>=3.12), `python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-ayatanaappindicator3-0.1`, `ca-certificates`, `xdg-utils`, `wl-clipboard`, `xclip` |
| Arch/Omarchy | `python`, `python-gobject`, `gtk3`, `libayatana-appindicator`, `ca-certificates`, `xdg-utils`, `wl-clipboard`, `xclip` |

Both Linux manifests include both clipboard utilities. GNOME uses its Shell
companion instead of either utility for background clipboard writes; Hyprland
uses `wl-copy`; the supported non-GNOME X11 path uses `xclip`. Install and
authorize **1Password CLI (`op`) separately** on either platform; the packages
do not provide it.

Once qualified, open the Mac DMG, copy **SSBNK Client.app** to Applications,
and launch it. Use **Options → Launch at login** only after setup; if macOS
requires approval, approve SSBNK Client in **System Settings → General → Login
Items** and verify a fresh login. Developer ID signing failures stop packaging;
the script never falls back to ad-hoc signing and performs no notarization.
Linux packages install `/usr/bin/ssbnk-client`, `/usr/lib/ssbnk-client`, and an
application-menu entry. Candidate install commands, from the source root:

```bash
# Debian/Ubuntu candidate; resolve native dependencies through apt.
sudo apt install ./clients/linux/dist/ssbnk-client_0.1.0_all.deb

# Arch candidate; substitute the actual artifact produced by makepkg.
sudo pacman -U /path/to/actual-built-ssbnk-client.pkg.tar.zst
```

Run Linux **SSBNK Client** from the graphical application menu or a terminal
inside the target graphical session, not through SSH or a headless user unit.
The singleton refuses a second process against the same state directory.
Package removal does not replace a controlled handover or reset the ledger.

### Folders, origin, and vault reference

1. Open **Options** on Mac, or **Options / Show all history** on Linux. Choose
   screenshot and recording folders independently with **Choose…**. Point the
   capture tools at those same folders; the clients don't change capture-tool
   destinations or add capture hotkeys. Defaults are `~/Pictures/Screenshots`
   and `~/Videos/Screencasts`; create/select real readable directories. The
   clients scan supported files directly in the chosen roots, not recursively.
   Images: PNG/JPEG/GIF/WebP. Recording candidates: MP4/AVI/MOV/MKV/WebM/FLV/WMV;
   extension recognition does not bypass server probing or resource limits.
2. Use `https://ss.delo.sh` as the API **origin**, not `/upload`, `/health`, or
   an API path. HTTPS is mandatory outside explicit loopback development. The
   server's `SSBNK_URL` must generate URLs at this exact origin; even loopback
   hostname aliases must agree.
3. Store the matching upload credential in DeLoSecrets and paste the actual
   secret reference into **DeLoSecrets reference**. For example,
   `op://DeLoSecrets/<existing-item-id>/credential` is a **placeholder**, not
   a provisioned item or known UUID. Copy the real item/field reference from
   1Password; do not paste a raw key into client settings or add it to files.
4. Unlock/authorize 1Password CLI for the graphical session. `op` must be on
   the launched app's PATH, including launch-at-login, not just an interactive
   shell's PATH. Both clients run bounded `op read` through memory pipes with
   a 15-second deadline and redacted credential errors; they don't use
   temporary stdout files. No real upload-key item reference has been verified
   for these instructions; the placeholder is not sufficient for setup. Missing
   CLI, denied access, timeout or 401 needs a vault/session remedy, then explicit
   Retry.
5. Save settings before testing. Mac **Test connection** uses saved settings
   and authenticated capabilities. Linux checks capabilities during delivery;
   use the authenticated example in the [API contract](./api-contracts-watcher.md)
   for a separate preflight. Never print resolved keys, enable shell tracing,
   or use curl trace/verbose output for authenticated requests.

On macOS, protected folders may require consent in **System Settings →
Privacy & Security → Files and Folders** for SSBNK Client. Verify actual reads
in the app/login context; a Terminal grant or the old Bash uploader's grant is
not evidence that the app has access. On Linux, check directory traversal/read
permissions and writable private config/state storage. An unavailable root is
reported separately; the other root and already staged transfers can continue.
Choosing the same physical folder or symlink aliases for both kinds does not
queue the same capture twice.

### Baseline, staging, and history

First setup of a canonical root/media kind baselines existing files instead of
backfilling them. Newly selected, previously unseen folders do the same.
Ordinary restart preserves coverage and reconciles missed captures; it doesn't
baseline the folder again. **Sync existing** explicitly queues baselined files,
skips identities already queued/delivered, and disables automatic clipboard
copying for that backfill. It is not a bulk clipboard replay.

Each client stages within a 4 GiB budget with a 512 MiB free-space floor and
fixed 50 MiB image/1 GiB recording input limits. At capacity it preserves
undelivered stages and shows deferred/queued work with a space remedy rather
than deleting it. Deferred originals must remain unchanged until staged;
changed/missing originals become explicit errors. Once verified, staged bytes
remain authoritative if the original is moved/deleted. A missing stage can
only be rebuilt from the matching unchanged original.

State is private and local:

- Mac: `~/Library/Application Support/SSBNK Client/`, including
  `configuration.json`, `sync-state.json`, and `Outbox/`.
- Linux: `$XDG_CONFIG_HOME/ssbnk/configuration.json` and
  `$XDG_STATE_HOME/ssbnk/{ledger.sqlite,outbox/}`; defaults are `~/.config` and
  `~/.local/state` respectively. The ledger uses SQLite WAL.

Do not clear these to retry: they carry UUIDs, offsets, coverage and copy
claims. Corrupt/future queue state stops delivery for repair rather than
resetting history. Attempted transfers keep their original origin/profile
through settings changes. Mac v1 pending UUIDs/stages and baseline coverage
migrate; old rsync-delivered entries remain legacy/unverified, with no invented
hosted URL, retransmission or automatic copy.

Tray/history rows show filename, time, media kind and semantic icon/text:
**queued**, **uploading** (including verification/conversion), **error**, and
**OK**. Rows have deterministic newest-first ordering; Mac currently orders
by client observation time, while Linux uses source modification time. OK
requires a persisted ready receipt, not accepted bytes or a `202` response.
Click a successful row or **Copy** to copy its exact result URL; **Open** and
upload **Retry** are separate actions.

Both media kinds auto-copy on the originating client when the newest eligible
observed capture becomes ready. An older GIF finishing late must not overwrite
a newer capture's link; manual Copy fences previously observed work. Restored
successful history and Sync existing do not auto-copy. Clipboard failure keeps
OK plus a warning/**Retry copy**, never retransmission. A durable copy claim
precedes the native write: a crash in between may miss that copy, so use manual
Copy/Retry copy rather than expecting replay on restart. Expired result URLs
remain history but are not eligible for copying. Mac writes URL text through
`NSPasteboard.general`; Linux uses the session-specific backends below. This
copies text only, with no simulated paste or image-data insertion.

### Ubuntu GNOME Shell 46/50 companion

The companion `ssbnk@delo.sh` supports **Shell 46 and 50 in its manifest**;
Ubuntu 24.04/GNOME46 and Ubuntu 26.04/GNOME50 are the qualification targets.
Other versions, including this host's GNOME49, are not qualified. Do not disable
extension version checks to claim support.

Install the separately built bundle as the desktop user, then log out and
start a new graphical session before enabling/checking it:

```bash
gnome-extensions install --force clients/linux/dist/ssbnk@delo.sh.shell-extension.zip
# After logging out and back in, in the target GNOME session:
gnome-extensions enable ssbnk@delo.sh
gnome-extensions info ssbnk@delo.sh
```

Require **State: ACTIVE**, launch the Python SSBNK Client, and verify its panel
history connects. The Shell companion supplies the native panel menu and
`St.Clipboard` **CLIPBOARD** writes via a credential-free session D-Bus adapter;
it doesn't handle upload keys or use PRIMARY. GNOME sessions suppress the
Ayatana indicator; without the companion the accessible GTK window remains,
uploads can finish, and copy shows a remedy. There is no focus-stealing
`wl-copy` fallback or simulated paste on GNOME.

The extension currently acknowledges `write-issued` or `unknown`, not proven
read-back or paste. Verify actual paste into another focused application,
plus client restart, extension disable/re-enable, lock/unlock and logout/login.
Reconnection must not replay consumed copy attempts. Shell ACTIVE alone is
not clipboard qualification.

**Launch in my graphical session at login** is opt-in and writes the user's
XDG autostart `ssbnk-client.desktop`. Verify login/logout on the target session;
do not reuse the legacy `default.target` uploader service, which lacks a
reliable graphical bus/display environment.

### Omarchy / Hyprland / Waybar and X11

Omarchy uses the Ayatana/StatusNotifier indicator and a **Waybar tray host**,
not the GNOME extension. The desktop window remains available when tray
support is missing. Enable tray support through the user's normal Waybar
configuration; the package doesn't edit Waybar/Hyprland configuration.

Clipboard writes use `wl-copy` with the **inherited** Hyprland session
environment. Do not hardcode `WAYLAND_DISPLAY`, `DISPLAY`, `XDG_RUNTIME_DIR`,
or copy another host's session paths. The supported non-GNOME X11 backend uses
`xclip -selection clipboard`; GNOME, even on X11, still takes the companion
path. An unsupported session/missing backend leaves an OK upload plus copy
remedy.

The login checkbox writes XDG autostart only. Confirm that the chosen
Omarchy/UWSM session actually processes it; where it doesn't, add one explicit
user-owned graphical-session entry, for example `uwsm app -- ssbnk-client`,
through that session's normal autostart route. Choose one launch route, not
both, and verify it on the disposable target. No automatic UWSM/Hyprland config
edit or headless service installation is implemented.

### One-uploader handover and rollback

Do not run the old script/rsync client and the tray client against the same
capture roots. Detection of legacy files/services/processes gates automatic
submission; staging may still occur. Keep the old uploader, its service/plist,
and configuration until controlled testing and verified vault migration
succeed. The candidate gaps below currently block claiming this handover safe
or qualified.

The implemented confirmation flows are Mac **Options → Verify handover… →
Verify and cut over** and Linux **Legacy handover…**. They resolve the vault
key, compare it with an existing legacy key in memory, upload a generated
controlled PNG outside the new roots, require that UUID's ready receipt/hash,
and persist a boundary before disabling the named legacy service. Linux also
checks legacy roots; Mac's missing legacy-root check is a gap below:

- Mac: launchd `sh.delo.ss.remote-upload`; bootout/disable, verify missing
  service and no detected legacy process, then mark handover complete.
- Linux: systemd user `ssbnk-remote-upload.service`; disable `--now`, verify
  inactive/no detected legacy process, then mark handover complete. Prior
  enabled/active flags are recorded for rollback.

These flows preserve legacy credential files; neither revokes the shared key.
Linux handover parses bounded nonsecret assignments without sourcing the env
file; it doesn't populate the Options fields automatically. Mac migrates its
old JSON settings and reads only the legacy key for the vault comparison.
Neither flow is permission to execute `remote.env` or silently migrate its
secret. A controlled HTTP PNG proves neither recording conversion nor target
clipboard paste: qualify both separately before confirmation.

The approved handover also requires **verified inactivity and explicit
boundary reconciliation**, including captures arriving during cutover, without
baselining them away. Until the gaps below are resolved, keep replacement
submissions gated and don't promise duplicate-free cutover. If a handover
fails while disabling the old service, the flow attempts to re-enable/restart
it; verify that restoration actually succeeded. For a later manual rollback,
quit/disable the new client's login route **first**, preserve its ledger/outbox,
and only then restore the old service/plist and verify one active uploader.
Don't reset the UUID ledger, delete `remote.env` before a verified migration,
or rotate/revoke a key shared with other clients.

### Legacy script compatibility and ClipCascade

`scripts/remote-screenshot-upload.sh` remains an image-only `/upload` client;
capture originals remain on the remote machine and it attempts clipboard copying
from the synchronous response. It has no durable v2 queue, recording support
or same-UUID recovery after a lost reply. `scripts/install-remote-client.sh`
installs that **legacy** uploader, not the tray packages; it sources
`~/.config/ssbnk/remote.env` and can write a plaintext upload key. Do not use it
for new tray setup or rerun it during handover. Existing plaintext migration
must be verified in 1Password without writing a new raw-key file; these docs
and the candidates do not claim that cleanup has occurred.

ClipCascade is **optional ordinary clipboard synchronization only**. If
separately working, it may sync text after SSBNK writes the normal local
clipboard. SSBNK neither depends on it nor repairs, restores, configures, or
integrates with it. Test SSBNK's originating clipboard independently.

## Candidate gaps against the approved plan

Source inspection found these limits; they are blockers, not completed plan
features:

- **Handover:** both clients persist boundaries, but neither consumes that
  boundary to reconcile cutover captures. Mac's controlled-test root check
  covers new roots, not legacy roots imported from `remote.env`. Process
  detection looks for `remote-screenshot-upload.sh`, while the legacy installer
  names the installed executable `ssbnk-remote-upload`; independently launched
  copies can therefore escape that check. Linux also doesn't verify disabled
  state after its disable call. One-uploader/boundary/rollback qualification is
  still required.
- **Mac Retry after handover:** `retryCapture` blocks whenever legacy presence
  remains, even after completed handover. Preserved `remote.env`/plist can keep
  manual upload Retry blocked while automatic processing is allowed.
- **Mac history time:** `createdAt`/`capture_time` use observation/enqueue time,
  not source capture time. This differs from the plan's capture-time ordering.
- **Retry policy:** Mac maps all HTTP 5xx (including structured nonretryable
  storage uncertainty) to transient retry and has no retry jitter. Linux
  jitters after capping, so a nominal 30-second delay can reach 36 seconds;
  its retry exponent uses the receipt attempt rather than a network-failure
  counter. Retry behavior differs from the approved jittered exponential
  policy capped at 30 seconds.
- **Readiness preflight:** neither transfer path gates on
  `processing_ready: false`, even though Mac Test connection uses it for health.
  Require readiness and a real media test as an operator preflight.
- **Linux responsiveness:** scanner/hashing share the queue-owning worker;
  manual Copy/Retry commands may wait during staging, despite the network
  wait path draining commands. Native responsiveness and GI/session behavior
  still need qualification.

Native targets, signing, Arch build/install, target paste, authorized `op`
access in the app/login environment, consistent server origin and storage
placement, and real proxy-path checks remain prerequisites. This document
update runs no commands and claims no deployments, installs, or passing
qualification checks.

## Historical routing evidence

The [latest endpoint investigation](./latest-endpoint-investigation-report.md)
documents a November 2025 incident and an older layout. Keep it as evidence,
but don't use its Nginx or multi-container details as the current runbook.
