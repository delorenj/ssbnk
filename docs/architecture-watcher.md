# Architecture — Watcher (Go backend)

## Executive summary

A single Go binary (`watcher/main.go`, ~1400 LOC) is the entire ssbnk runtime: it watches screenshot/screencast directories with fsnotify, normalizes and hosts the assets, converts videos to GIF via ffmpeg, writes JSON metadata sidecars, serves an HTTP API plus the Astro management UI, and integrates with the host clipboard. Deployed as the `ssbnk-watcher` container behind Traefik at `ss.delo.sh`.

## Technology stack

| Category | Technology | Version | Justification |
|---|---|---|---|
| Language | Go | 1.21 | Single static binary, goroutines for watch/HTTP concurrency |
| File watching | fsnotify | v1.7.0 | Standard Go filesystem events |
| IDs | google/uuid | v1.6.0 | Metadata sidecar filenames |
| HTTP | net/http | stdlib | No framework; one `withHeaders` middleware |
| Video | ffmpeg | subprocess | Video→GIF with palette gen/use |
| Clipboard | wl-clipboard / xclip | subprocess | Host clipboard from inside container via mounted sockets |
| Container | Alpine + multi-stage | — | `watcher/Dockerfile`: go-builder → ui-builder → runtime |

## Architecture pattern

Single-process event-driven service. One fsnotify watcher goroutine dispatches ingestion goroutines; an HTTP server goroutine serves reads. State is the filesystem itself (`hosted/` + `metadata/`) — no database, no in-memory index.

## Ingestion pipeline

- **Images** (png/jpg/jpeg/gif/webp, Create or Rename events): 100 ms debounce → `processScreenshot` → renamed to `YYYYMMDD-HHMM.png` (collision suffix `-N`), copied to `hosted/`, original deleted, metadata written, `/tmp/ssbnk/last-screenshot` updated, URL copied to clipboard.
  - **GIF special case:** a `.gif` with mtime < 5 s is assumed to be a fresh video conversion — moved keeping its name, plus notification sound + browser open. (Racy heuristic; a slow real-GIF save can be misrouted.)
- **Videos** (mp4/avi/mov/mkv/webm/flv/wmv): `trackVideoFile` waits for size/mtime stability (6×500 ms polls, escalates to 12, 10-min cap, exclusive-open check) → `processVideo` → ffmpeg (`-t 10 -vf "fps=10,scale=640:-1:lanczos,palettegen/paletteuse" -loop 0`, up to 3 retries) → GIF moved to `hosted/`, original video deleted.
- **Remote uploads:** `POST /upload` (X-Upload-Key auth, 50 MB) → same storage/metadata/clipboard path.

## API design

See [api-contracts-watcher.md](./api-contracts-watcher.md). Highlights: `/api/screenshots` (paginated JSON for the UI), `/latest` (metadata-only), `/hybrid` (metadata + filesystem fallback), `/stateless` (filesystem-only), `/upload` (only authenticated endpoint), `/health` (consistency check, always 200). Hosted assets served root-level; unknown paths fall through to the Astro `index.html`.

## Data architecture

See [data-models-watcher.md](./data-models-watcher.md). One `ScreenshotMetadata` JSON per asset in `metadata/<uuid>.json`; filesystem is the source of truth for bytes. `description`/`batch_id`/`repo_name` fields are declared but never set.

## Component overview

- `main()` — env config, watcher setup, starts API server, blocks on `select{}`
- Event loop (`main.go:80-112`) — dispatch on Create/Rename
- `processScreenshot` / `processVideo` / `trackVideoFile` — ingestion
- `handle*` functions — HTTP API (see contracts doc)
- `copyToClipboard` — wl-copy → xclip → FIFO → HTTP fallback chain
- `writeLastScreenshotPath` — paste-image bridge
- `logMemoryUsage` — logs MemStats every 30 s forever (debug leftover)

## Deployment

Built by `watcher/Dockerfile` (3-stage, includes the Astro UI build) → `delorenj/ssbnk-watcher`. Compose service on the external `proxy` network with Traefik labels; Wayland/X11 sockets and `/tmp/ssbnk` bind-mounted for host integration. See [deployment-guide.md](./deployment-guide.md).

## Testing strategy

Intended: `go test ./...` (mise `test`). **Current state: broken.** `main_test.go` doesn't compile (stale `Config` field names); `test_hybrid_endpoints.go` is misnamed so its real endpoint tests never run but ship in the binary. Manual testing per CONTRIBUTING.md's X11+Wayland checklist.

## Known risks / debt

- `watcher/ssbnk-watcher`: 9.8 MB compiled binary tracked in git (ignore rule inert — already tracked)
- `watcher/main.go.backup`: stale backup tracked in git
- Blocking FIFO opens (`/tmp/ssbnk-clipboard`, `/tmp/ssbnk-browser`) can hang goroutines indefinitely
- Non-GIF files are force-renamed to `.png` without transcoding
- Non-recursive directory watch; no graceful shutdown
- All read endpoints unauthenticated with permissive CORS (by design)
