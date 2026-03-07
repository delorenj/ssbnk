# ScreenShot Bank (ssbnk)

## Project Overview
**ssbnk** is a self-hosted screenshot/screencast hosting service. It watches local folders, normalizes filenames, hosts assets with Nginx, and exposes "latest" retrieval endpoints.

Core stack:
- **Watcher/API**: Go (`/watcher`)
- **Static hosting**: Nginx (`/web`)
- **Management UI**: React + Express (`/ui`)

## Core Components
### 1) Watcher (`/watcher`)
- Watches screenshot and screencast directories.
- Converts videos to GIF (`ffmpeg`) and stores metadata JSON in `watcher-data/metadata/`.
- Endpoints:
  - `/latest` metadata-driven lookup
  - `/hybrid` metadata + filesystem fallback
  - `/stateless` filesystem-only lookup
  - `/upload` remote upload endpoint
  - `/health` metadata/file consistency status

### 2) Management UI (`/ui`)
- React/TypeScript/Vite + Tailwind + shadcn/ui.
- Express server for API routes.

### 3) Web Server (`/web`)
- Serves hosted assets from `web/html` with Nginx config in `web/default.conf` and `web/nginx.conf`.

## Recent Commits (origin/main)
- `f96fda2`: merge sync from remote `main`.
- `c6e249d`: watcher fix for screenshot reliability.
  - Screenshot events now handle `Create` **and** `Rename`.
  - Screenshot processing runs in a goroutine so fsnotify loop is not blocked.
  - Clipboard command execution now has a timeout to avoid watcher deadlocks.
- `e94ad09`: removed `/hosted/` URL prefix usage in watcher output/log flow.
- `143c99f`: corrected screenshot/screencast volume mount paths in Compose.

## Build and Run
```bash
# full stack
docker compose up -d

# watcher only
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
