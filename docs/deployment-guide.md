# Deployment Guide

Two distribution paths exist. The maintainer's own deployment uses path A.

## A. Dev/maintainer stack — `compose.yml` (current production)

Two services, built from source:

**`ssbnk-watcher`** (built from `watcher/Dockerfile`, 3-stage: Go build → Astro UI build → Alpine runtime with ffmpeg/xclip/wl-clipboard/xdg-utils, non-root user `ssbnk`, EXPOSE 80):

- Volumes:
  - `${SSBNK_SCREENSHOT_DIR}:/media/screenshots`, `${SSBNK_SCREENCAST_DIR}:/media/screencasts`
  - `/home/delorenj/data/ssbnk/hosted:/data/hosted`, `/home/delorenj/data/ssbnk/metadata:/data/metadata` (hardcoded host paths)
  - `/tmp/ssbnk:/tmp/ssbnk` (shared with host `paste-image.sh`)
  - `${XDG_RUNTIME_DIR:-/run/user/1000}:/run/user/1000:rw` (Wayland socket for clipboard), `/tmp/.X11-unix` (X11 fallback)
- Env: `SSBNK_URL=https://${SSBNK_DOMAIN}`, container-side dirs, `SSBNK_API_PORT=80`, `SSBNK_UPLOAD_KEY`, display vars
- Network: external `proxy`; Traefik labels `Host(`${SSBNK_DOMAIN}`)`, `websecure`, `tls.certresolver=letsencrypt`, LB port 80

**`ssbnk-cleanup`** (`alpine:latest`): crond running `scripts/cleanup.sh` daily at 02:00 against `/data/hosted`, `/data/metadata`, `/data/archive`; `SSBNK_RETENTION_DAYS` (default 30).

The single watcher binary serves **everything**: hosted assets (root-level), the Astro UI, and all API endpoints. **There is no Nginx container in this stack** — `web/` configs are from the retired 3-container architecture.

Production instance: `/home/delorenj/docker/stacks/utils/ssbnk/compose.yml` (same shape, pulls `delorenj/ssbnk-watcher:latest`); `mise run deploy` updates it.

### Domain / TLS

- Production domain: `ss.delo.sh`, TLS via Traefik `letsencrypt` on `websecure`
- `*.delo.sh` reaches Traefik through a Cloudflare Tunnel
- After a Nov 2025 incident (Traefik Docker provider broken: "client version 1.24 too old"), routing uses a **file-based Traefik dynamic config** (`~/docker/trunk-main/core/traefik/traefik-data/dynamic/ssbnk.yml`) with security headers and a `/health` LB health check. See `docs/latest-endpoint-investigation-report.md`.

## B. Packaged all-in-one — `docker-compose.packaged.yml` + root `Dockerfile`

Consumer distribution: single container (`delorenj/ssbnk:latest`, also pushed as `ssbnk/ssbnk` via `build-and-push.sh`) running **supervisord** with three programs: Nginx, `ssbnk-watcher`, cleanup cron. Nginx serves `web/` configs; the watcher listens internally on 31243.

- `VOLUME ["/media", "/data"]`; named volume `ssbnk_data:/data`
- Install path: `scripts/run-ssbnk.sh` (curl-pipe-bash)
- **Known defect:** the packaged compose sets both `network_mode: host` and `networks: [proxy]` + Traefik labels — host networking wins, so the Traefik routing as labeled cannot work.
- The root Dockerfile builds only `watcher/main.go` (no UI) — behind the watcher Dockerfile feature-wise.

## Remote upload machines

Each client machine runs the uploader (`scripts/remote-screenshot-upload.sh` → `~/.local/bin/ssbnk-remote-upload`), installed by `scripts/install-remote-client.sh`:

- Config: `~/.config/ssbnk/remote.env` (`SSBNK_HOST`, `SSBNK_UPLOAD_KEY`, `SSBNK_SCREENSHOT_DIR` — colon-separated)
- **Linux (e.g. tiny-chungus, Arch):** systemd user service `~/.config/systemd/user/ssbnk-remote-upload.service`; requires `inotify-tools`
- **macOS (e.g. carries-macbook-air):** launchd agent `~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist`; requires `fswatch` (Homebrew). If the watch dir is Desktop/Documents/Downloads, macOS TCC requires a one-time privacy grant — the installer walks the user through System Settings and polls until granted.

The uploader watches for new screenshots (inotifywait on Linux, fswatch on macOS), waits for file-size stability, dedupes concurrent events, and `POST`s to `$SSBNK_HOST/upload` with `X-Upload-Key` (up to `SSBNK_UPLOAD_RETRIES`, default 3). On success the hosted URL is copied to the remote clipboard and the local path written to `/tmp/ssbnk/last-screenshot`; the local file is kept.

## CI/CD

`.github/workflows/docker-build.yml` (push to main, `v*` tags, PRs):

- `build-watcher`: `watcher/Dockerfile` → `$DOCKERHUB_USERNAME/ssbnk-watcher` + GHCR, multi-arch amd64/arm64
- `build-packaged`: root `Dockerfile` → image `ssbn`/`ssbnk`, same registries, plus Docker Hub README sync
- Secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

Also: `opencode.yml` / `opencode-review.yml` (AI agent + PR review via Kimi).

Release flow: `mise run version:bump-*` → CHANGELOG → tag → CI builds/pushes → `mise run deploy`.
