# Integration Architecture

How the four parts communicate. The watcher is the hub: every other part either calls its HTTP API or shares filesystem/OS-level channels with it.

```
                 ┌─────────────────────────────┐
  Remote machines│  scripts/                   │
  (tiny-chungus, │  remote-screenshot-upload.sh│
   macbook-air)  └────────────┬────────────────┘
                              │ POST /upload (X-Upload-Key, multipart ≤50MB)
                              ▼
┌──────────┐  HTTPS    ┌──────────────────────────────┐
│ Cloudflare│────────▶│ Traefik (proxy network)       │
│ Tunnel   │ *.delo.sh │  ss.delo.sh → :80, /health    │
└──────────┘           └──────────────┬───────────────┘
                                      ▼
                       ┌──────────────────────────────┐
                       │ watcher (Go, :80)             │
                       │  /api/screenshots /latest     │
                       │  /hybrid /stateless /upload   │
                       │  /health + static hosting + UI│
                       └──┬───────┬────────┬─────────┬─┘
            fsnotify watch│       │        │         │ serves
                          ▼       │        ▼         ▼
                 /media/screenshots│   /data/hosted  ui/ (Astro dist)
                 /media/screencasts│   /data/metadata  → GET /api/screenshots
                                   │        ▲            (same origin in prod)
              clipboard (Wayland   │        │ retention
              socket mount, FIFO,  │   ┌────┴─────────┐
              HTTP :9999 fallbacks)│   │ ssbnk-cleanup │ (cron 02:00,
                                   │   │ cleanup.sh    │  archive >30d)
                                   ▼   └───────────────┘
                    /tmp/ssbnk/last-screenshot (shared bind mount)
                                   │
                                   ▼
                    scripts/paste-image.sh (host, Ctrl+Shift+V)
                    wl-copy image data → ydotool Ctrl+V → restore clipboard
```

## Integration points

| From | To | Type | Details |
|---|---|---|---|
| Remote machines | watcher `/upload` | REST | Multipart POST, `X-Upload-Key` header auth, 50 MB cap; URL returned in JSON and copied to remote clipboard |
| UI (browser) | watcher `/api/screenshots` | REST | `limit`/`offset` pagination; `PUBLIC_API_URL` build-time base (default `https://ss.delo.sh`); same-origin in production since watcher serves the Astro build |
| Browser/clients | watcher `/latest` `/hybrid` `/stateless` | REST | 302 redirect to asset URL; offset path param |
| Traefik | watcher `/health` | Health check | File-based dynamic config; expects 200 + JSON status |
| watcher | host clipboard | OS channel | Wayland socket bind-mount + `wl-copy` (X11: `xclip`); fallbacks: FIFO `/tmp/ssbnk-clipboard`, HTTP `localhost:9999` |
| watcher | `paste-image.sh` | Shared file | `/tmp/ssbnk/last-screenshot` (basename only), `/tmp/ssbnk` bind-mounted to host |
| watcher | ffmpeg | Subprocess | Video→GIF: `-t 10 -vf "fps=10,scale=640:-1:lanczos,palettegen/paletteuse" -loop 0`, 3 retries |
| cleanup container | hosted/metadata/archive | Shared volumes | POSIX file ops only; honors `preserve: true` in metadata JSON |
| watcher (legacy) | Nginx `web/` | Reverse proxy | Retired: `/latest` + `/upload` → `host.docker.internal:31243`. Only relevant to the packaged all-in-one image |

## Auth flow

- **Upload:** shared secret `SSBNK_UPLOAD_KEY` in env on both sides; watcher rejects with 503 if unconfigured, 401 on mismatch.
- **Everything else:** unauthenticated by design (personal host). The legacy Nginx config has an `X-API-Key` stub on `/api/` and `/` that 403s empty keys but implements no real auth.

## Data flow (local screenshot)

1. Screenshot lands in `/media/screenshots` → fsnotify Create/Rename
2. Watcher waits 100 ms, normalizes name to `YYYYMMDD-HHMM.png`, copies to `hosted/`, deletes original
3. Metadata JSON written to `metadata/<uuid>.json`
4. `/tmp/ssbnk/last-screenshot` updated (basename)
5. URL copied to clipboard (wl-copy), notification sound, browser open (video/GIF path)

## Data flow (remote upload)

1. Remote machine's uploader detects new file (inotifywait) → POST `/upload`
2. Watcher stores, writes metadata + last-screenshot, copies URL to **host** clipboard
3. Remote machine copies returned URL to its **local** clipboard
