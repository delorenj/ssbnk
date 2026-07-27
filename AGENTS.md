# ScreenShot Bank (ssbnk)

## Project Overview
**ssbnk** is a self-hosted screenshot/screencast hosting service. It watches local folders, normalizes filenames, hosts assets, and exposes "latest" retrieval endpoints. Remote machines upload screenshots via the `/upload` API, and the URL is copied to the host clipboard automatically.

Core stack:
- **Watcher/API**: Go (`/watcher`) — serves everything: assets, API, and the built UI
- **Management UI**: Astro + React (`/ui`) — static build served by the watcher
- **Static hosting**: Nginx (`/web`) — LEGACY, only in the packaged all-in-one image
- **Remote uploaders**: Bash scripts on remote machines (`/scripts`)

Full generated docs live in `docs/` (start at `docs/index.md`).

## Core Components

### 1) Watcher (`/watcher`)
- Watches screenshot and screencast directories via fsnotify.
- Converts videos to GIF (`ffmpeg`) and stores metadata JSON in `watcher-data/metadata/`.
- Copies URL to host clipboard on both local screenshots and remote uploads.
- Writes last screenshot filename to `/tmp/ssbnk/last-screenshot` for paste-image support.
- Endpoints (all served by the watcher on `SSBNK_API_PORT`, default 80):
  - `/api/screenshots` paginated JSON listing for the UI (`limit`/`offset`)
  - `/latest` metadata-driven lookup (302 redirect)
  - `/hybrid` metadata + filesystem fallback
  - `/stateless` filesystem-only lookup
  - `/upload` remote upload endpoint (requires `X-Upload-Key` header)
  - `/health` metadata/file consistency status
  - Hosted assets served root-level (`/<file>.png`), unknown paths fall through to the UI's `index.html`

### 2) Management UI (`/ui`)
- Astro 6 + React 19 + TypeScript + Tailwind 4 + shadcn (on @base-ui/react).
- Static build (`npm run build` → `dist/`); the watcher serves it from `SSBNK_UI_DIR` (default `/ui`). No separate UI server.
- Single screen: `ScreenshotGallery.tsx` calling `GET /api/screenshots`. `ui/` has its own `.git` (nested repo).

### 3) Web Server (`/web`) — LEGACY
- Nginx configs from the retired 3-container architecture; only used inside the packaged all-in-one image (root `Dockerfile`, supervisord).
- Proxies only `/upload` and `/latest` to the watcher on port 31243. The current `compose.yml` stack has no Nginx container.
- `web/html/` holds the live hosted assets.

### 4) Scripts (`/scripts`)
- `paste-image.sh`: Ctrl+Shift+V shortcut handler. Sets image data on clipboard, simulates Ctrl+V via ydotool, restores original clipboard. Symlinked to `~/.local/bin/ssbnk-paste-image`.
- `remote-screenshot-upload.sh`: Uploader for remote machines. Uses inotifywait (Linux) or fswatch (macOS) to watch for new screenshots and POST them to the upload endpoint (with retries and event dedupe).
- `install-remote-client.sh`: Interactive installer for remote machines — deps, `~/.config/ssbnk/remote.env`, systemd user service (Linux) or launchd agent (macOS), guided macOS privacy (TCC) grant flow, end-to-end test.
- `cleanup.sh`: Retention-based cleanup run by the ssbnk-cleanup container via cron.

### 5) Remote Upload Services
Deployed on Tailnet machines to auto-upload screenshots:
- **tiny-chungus** (Arch Linux): systemd user service at `~/.config/systemd/user/ssbnk-remote-upload.service`
- **carries-macbook-air** (macOS): launchd agent at `~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist`
- Config on remote machines: `~/.config/ssbnk/remote.env` (contains `SSBNK_HOST`, `SSBNK_UPLOAD_KEY`, `SSBNK_SCREENSHOT_DIR`)

## Key Implementation Details
- `/tmp/ssbnk/last-screenshot` contains just the **filename** (not a full path). The paste-image script resolves it relative to the project's `web/html/` directory.
- The watcher container mounts `/home/delorenj/data/ssbnk/hosted` as `/data/hosted` (hardcoded host paths in `compose.yml`). Container paths like `/data/hosted/file.png` don't exist on the host.
- Clipboard access from the container works via the mounted Wayland socket (`${XDG_RUNTIME_DIR}` → `/run/user/1000`) + `wl-copy`; X11 socket as fallback. The watcher also has FIFO (`/tmp/ssbnk-clipboard`) and HTTP (`localhost:9999`) clipboard fallbacks with no host-side listeners anymore.
- GNOME custom shortcuts don't inherit `WAYLAND_DISPLAY` or `XDG_RUNTIME_DIR`, so `paste-image.sh` sets these explicitly.
- GNOME/Wayland doesn't support `wtype` (virtual-keyboard protocol). Use `ydotool` for input simulation instead.

## Build and Run
```bash
# full stack
docker compose up -d

# rebuild watcher after changes
docker compose up -d --build ssbnk-watcher

# watcher only (local dev)
cd watcher && go run main.go

# ui
cd ui && npm install && npm run dev
```

## Dev/Test Conventions
- Go tests: `cd watcher && go test ./...` (or `mise run test`)
- UI has **no test script** — `npm run build` is the smoke check
- Hosted files: `web/html/` (production: `/home/delorenj/data/ssbnk/hosted`)
- Metadata: `watcher-data/metadata/` (production: `/home/delorenj/data/ssbnk/metadata`)
- Ensure `.env` uses a real, existing host screenshot directory for `SSBNK_SCREENSHOT_DIR`.
