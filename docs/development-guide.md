# Development Guide

## Prerequisites

- Go 1.21+ (watcher)
- Node >= 22.12.0 (UI)
- Docker + Docker Compose (full stack)
- `ffmpeg` on the host if running the watcher outside Docker
- Wayland session with `wl-clipboard` + `ydotool` for clipboard/paste features (X11 fallback: `xclip`)
- [mise](https://mise.jdx.dev) (optional, task runner) + 1Password CLI (`op`) — the mise enter hook injects `.env` from `.env.op`

## Environment setup

```bash
cp .env.example .env   # or rely on: op inject -i .env.op > .env  (automatic via mise)
```

Required `.env` keys: `SSBNK_DOMAIN`, `SSBNK_UPLOAD_KEY`, `SSBNK_SCREENSHOT_DIR`, `SSBNK_SCREENCAST_DIR` (must be real host directories), optionally `SSBNK_RETENTION_DAYS`.

## Common tasks (mise)

| Command | What it does |
|---|---|
| `mise run build` | `docker build -t delorenj/ssbnk-watcher:latest -f watcher/Dockerfile .` |
| `mise run push` | Push watcher image to Docker Hub |
| `mise run deploy` | `cd /home/delorenj/docker/stacks/utils/ssbnk && docker compose pull && up -d ssbnk-watcher` |
| `mise run test` | `cd watcher && go test ./...` |
| `mise run dev` | `cd watcher && go run main.go` |
| `mise run version[:bump\|bump-minor\|bump-major\|check\|sync]` | Semver workflow (`.mise/scripts/versioning.sh`) |

## Full stack (Docker)

```bash
docker compose up -d                    # watcher + cleanup
docker compose up -d --build ssbnk-watcher   # rebuild after Go changes
```

The compose stack needs the external Docker network `proxy` (Traefik) to exist.

## Watcher only (local dev)

```bash
cd watcher && go run main.go
```

Set `SSBNK_SCREENSHOT_DIR`, `SSBNK_SCREENCAST_DIR`, `SSBNK_DATA_DIR`, `SSBNK_API_PORT`, `SSBNK_URL` as needed (defaults assume container paths).

## UI (local dev)

```bash
cd ui && npm install && npm run dev     # Astro dev server on localhost:4321
npm run build                           # static build → ui/dist
```

`PUBLIC_API_URL` (build-time) points the gallery at an API base; defaults to `https://ss.delo.sh`. **There is no `npm test` script** despite older docs referencing one.

## Tests — known broken state

- `cd watcher && go test ./...` currently **fails to compile**: `main_test.go` uses removed `Config` fields `WatchDir`/`VideoWatchDir` (now `ScreenshotDir`/`ScreencastDir`).
- `test_hybrid_endpoints.go` contains real endpoint tests but is misnamed (doesn't end in `_test.go`), so `go test` ignores it while it ships in the production binary. Rename to `*_test.go` and fix its benchmark helpers to activate it.

## Code style (from CONTRIBUTING.md)

- Go: `gofmt`, `golint`
- Shell: `shellcheck`, `set -e`
- Conventional commits (`feat/fix/docs/style/refactor/test/chore`), feature branches, PR template with X11+Wayland manual test checklist

## Useful diagnostics

```bash
scripts/detect-display-server.sh    # Wayland/X11 + clipboard tooling check
curl http://localhost/health        # metadata vs. hosted-file consistency
```
