# Architecture — Scripts (Bash automation)

## Executive summary

`scripts/` holds the host-side and remote-machine automation around the watcher: the paste-image keyboard shortcut, the remote upload agent, retention cleanup, release tooling, and diagnostics. Roughly half the directory is legacy (Syncthing-era sync scripts, clipboard-bridge experiments, Docker-volume helpers) kept in-tree.

## Current scripts

| Script | Purpose | Key deps | Invocation |
|---|---|---|---|
| `paste-image.sh` | Ctrl+Shift+V handler: reads basename from `/tmp/ssbnk/last-screenshot`, resolves against `web/html/`, sets image on clipboard via `wl-copy --type <mime>`, simulates Ctrl+V with `ydotool key 29:1 47:1 47:0 29:0`, restores clipboard after 0.5 s. Sets `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` explicitly (GNOME shortcuts don't inherit session env) | wl-copy, wl-paste, ydotool, notify-send | Symlinked to `~/.local/bin/ssbnk-paste-image`, bound via dconf custom keybinding |
| `remote-screenshot-upload.sh` | Reference uploader for remote machines: recursively watches `SSBNK_SCREENSHOT_DIR` (colon-separated), POSTs images to `$SSBNK_HOST/upload` with `X-Upload-Key`, copies returned URL to local clipboard, writes `/tmp/ssbnk/last-screenshot` | inotifywait, curl, wl-copy/xclip | systemd user service (Linux) / launchd agent (macOS); config `~/.config/ssbnk/remote.env`. Header mentions fswatch/macOS but only inotifywait is implemented |
| `cleanup.sh` | Retention: moves files older than `SSBNK_RETENTION_DAYS` (default 30) to `archive/YYYY-MM-DD/`, skips `preserve: true`, archives metadata, prunes old archives and orphaned metadata | POSIX sh, stat, date, grep | crond in the `ssbnk-cleanup` container (`0 2 * * *`) |
| `detect-display-server.sh` | Wayland/X11 + clipboard-tooling diagnostic with install hints | — | Manual; also baked into the all-in-one image |
| `build-and-push.sh` | Maintainer release for the all-in-one image: builds root `Dockerfile`, pushes `ssbnk/ssbnk:<version>`+`:latest` to Docker Hub and `ghcr.io/delorenj/ssbnk` | docker | Manual; largely superseded by CI `docker-build.yml` and mise `push` (which push `delorenj/ssbnk-watcher` — note the Docker Hub org mismatch) |
| `run-ssbnk.sh` | Curl-pipe-bash quick start for the packaged image (`docker run --network host --privileged`) | docker | End-user install path, referenced by DEPLOYMENT.md |
| `generate-missing-metadata.sh` / `.go` | One-off backfill: create metadata JSON for hosted files lacking it (hardcoded `BASE_URL=https://ss.delo.sh`) | uuidgen / Go | Inside the watcher container, as needed |

## Legacy scripts (dead code in-tree)

- **Syncthing/"Bloodbank"-era:** `fast-screenshot-sync.sh`, `force-screenshot-sync.sh`, `sync-now.sh`, `local-screenshot-watcher.sh`, `instant-screenshot.sh` — watch `$HOME/ss` and poke the Syncthing REST API. Superseded by `remote-screenshot-upload.sh`.
- **Clipboard bridge experiments:** `clipboard-bridge.sh` (FIFO `/tmp/ssbnk-clipboard`), `clipboard-http.sh` (`nc -l -p 9999`), `setup-browser-bridge.sh` (FIFO `/tmp/ssbnk-browser` + `xdg-open`). Superseded by mounting the Wayland socket into the container — though the watcher still contains matching FIFO/HTTP fallback code.
- **Volume helpers:** `mount-volume.sh`, `umount-volume.sh`, `get-hosted-url.sh` — depend on the retired `ssbnk_data` named volume and the old `/hosted/` URL prefix.

## Security note

Four legacy sync scripts contain a **hardcoded Syncthing API key** committed to the repo (`fast-screenshot-sync.sh`, `force-screenshot-sync.sh`, `sync-now.sh`, `instant-screenshot.sh`). Rotate/purge if that Syncthing instance still exists; deleting the legacy cluster removes the exposure.

## Conventions

POSIX sh or bash, `set -e`, shellcheck-clean (per CONTRIBUTING.md). Scripts that touch the display server must set `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` themselves. Remote-machine installs keep config in `~/.config/ssbnk/remote.env` and binaries in `~/.local/bin/`.
