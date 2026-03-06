# ScreenShot Bank (ssbnk)

## Project Overview
**ssbnk** is a self-hosted screenshot/screencast hosting service. It watches local folders, normalizes filenames, hosts assets with Nginx, and exposes "latest" retrieval endpoints. Remote machines upload screenshots via the `/upload` API, and the URL is copied to the host clipboard automatically.

Core stack:
- **Watcher/API**: Go (`/watcher`)
- **Static hosting**: Nginx (`/web`)
- **Management UI**: React + Express (`/ui`)
- **Remote uploaders**: Bash scripts on remote machines (`/scripts`)

## Core Components

### 1) Watcher (`/watcher`)
- Watches screenshot and screencast directories via fsnotify.
- Converts videos to GIF (`ffmpeg`) and stores metadata JSON in `watcher-data/metadata/`.
- Copies URL to host clipboard on both local screenshots and remote uploads.
- Writes last screenshot filename to `/tmp/ssbnk/last-screenshot` for paste-image support.
- Endpoints:
  - `/latest` metadata-driven lookup
  - `/hybrid` metadata + filesystem fallback
  - `/stateless` filesystem-only lookup
  - `/upload` remote upload endpoint (requires `X-Upload-Key` header)
  - `/health` metadata/file consistency status

### 2) Management UI (`/ui`)
- React/TypeScript/Vite + Tailwind + shadcn/ui.
- Express server for API routes.

### 3) Web Server (`/web`)
- Serves hosted assets from `web/html` with Nginx config in `web/default.conf` and `web/nginx.conf`.
- Proxies `/upload`, `/latest`, `/hybrid`, `/stateless`, `/health` to watcher on port 31243.

### 4) Scripts (`/scripts`)
- `paste-image.sh`: Ctrl+Shift+V shortcut handler. Sets image data on clipboard, simulates Ctrl+V via ydotool, restores original clipboard. Symlinked to `~/.local/bin/ssbnk-paste-image`.
- `remote-screenshot-upload.sh`: Reference script for remote machines. Uses inotifywait (Linux) or fswatch (macOS).
- `cleanup.sh`: Retention-based cleanup run by the ssbnk-cleanup container via cron.

### 5) Remote Upload Services
Deployed on Tailnet machines to auto-upload screenshots:
- **tiny-chungus** (Arch Linux): systemd user service at `~/.config/systemd/user/ssbnk-remote-upload.service`
- **carries-macbook-air** (macOS): launchd agent at `~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist`
- Config: `~/.config/ssbnk/remote.env` on each remote machine

## Key Implementation Details
- `/tmp/ssbnk/last-screenshot` contains just the **filename** (not a full path). The paste-image script resolves it relative to the project's `web/html/` directory.
- The watcher container mounts `./web/html` as `/data/hosted`. Container paths don't exist on the host.
- Clipboard access from the container works via mounted Wayland socket + `network_mode: host` + `privileged: true`.
- GNOME custom shortcuts don't inherit `WAYLAND_DISPLAY` or `XDG_RUNTIME_DIR`, so `paste-image.sh` sets these explicitly.
- GNOME/Wayland doesn't support `wtype`. Use `ydotool` for input simulation.

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
- Go tests: `cd watcher && go test ./...`
- UI tests: `cd ui && npm test`
- Hosted files: `web/html/`
- Metadata: `watcher-data/metadata/`
- Ensure `.env` uses a real, existing host screenshot directory for `SSBNK_SCREENSHOT_DIR`.
