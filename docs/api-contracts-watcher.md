# API Contracts — Watcher

The Go watcher (`watcher/main.go`) serves all HTTP traffic on `SSBNK_API_PORT` (default `80` in the container). All routes pass through the `withHeaders` middleware, which sets:

- `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`
- Permissive CORS: `Access-Control-Allow-Origin: *`, methods `GET, POST, OPTIONS`, headers `Content-Type, X-Upload-Key, X-API-Key`
- Any `OPTIONS` preflight returns 200
- `Cache-Control: public, max-age=86400, immutable` for image paths

**Auth model:** Only `POST /upload` is authenticated (`X-Upload-Key`). Everything else is world-readable by design (personal host behind `ss.delo.sh`).

## Endpoints

### `GET /api/screenshots`

Paginated metadata listing, consumed by the management UI.

- **Query params:** `limit` (default 50), `offset` (default 0)
- **Auth:** none
- **Response 200:**

```json
{
  "screenshots": [ { "id": "uuid", "original_name": "...", "filename": "20260214-1147.png", "url": "https://ss.delo.sh/20260214-1147.png", "timestamp": "RFC3339", "size": 12345, "preserve": false } ],
  "total": 136,
  "offset": 0,
  "limit": 50
}
```

- Sorted by `timestamp` descending. Gap-fills hosted files that lack metadata with synthetic entries (`filename`, `url`, `timestamp`, `size` only).

### `GET /latest` and `/latest/{offset}`

Metadata-only lookup of the Nth most recent asset.

- **Behavior:** reads all `*.json` in the metadata dir, sorts by `timestamp` desc, returns **302 redirect** to the entry's `url`.
- **404:** `"Not found: offset is out of range"` — **500:** metadata dir unreadable.
- No filesystem validation — can redirect to a deleted file.

### `GET /hybrid` and `/hybrid/{offset}`

Metadata-first with filesystem fallback.

- Validates the referenced file exists in `hosted/`; if metadata is missing/inconsistent, scans `hosted/` directly (image extensions, sorted by **mtime** desc) and builds the URL from the filename.
- **404:** `"File not found at offset N. Available files: M"`

### `GET /stateless` and `/stateless/{offset}`

Filesystem-only lookup; never touches metadata. Same response shapes as `/hybrid`.

> Note: `/latest` sorts by stored metadata timestamp while `/stateless` sorts by file mtime — after cleanup or clock skew they can disagree on which file is "latest".

### `POST /upload`

Remote screenshot ingestion.

- **Auth:** header `X-Upload-Key` must equal env `SSBNK_UPLOAD_KEY`. Env unset → **503** `"Upload not configured"`; mismatch → **401**.
- **Request:** multipart form, field `file`, max **50 MB**. Allowed extensions: `.png .jpg .jpeg .gif .webp`.
- **Behavior:** saves to `hosted/` as `YYYYMMDD-HHMM<ext>` (collision suffix `-1`, `-2`, …), writes metadata, updates `/tmp/ssbnk/last-screenshot`, copies URL to clipboard.
- **Response 200:** `{"url": "...", "filename": "..."}`
- **Errors:** 405 non-POST, 400 bad form / missing file / disallowed extension.

### `GET /health`

Metadata/filesystem consistency check.

- **Response 200 (always 200):**

```json
{
  "status": "ok | warning",
  "metadata_count": 27,
  "actual_file_count": 27,
  "consistency_issues": ["Metadata references missing file: X", "Hosted file missing metadata: Y"],
  "timestamp": "RFC3339"
}
```

`consistency_issues` omitted when empty. Traefik's file-based dynamic config uses this endpoint for the load-balancer health check.

### Static routes

| Path | Serves |
|---|---|
| `/_astro/*`, `/favicon.svg` | Astro UI build from `SSBNK_UI_DIR` (default `/ui`) |
| `/{file}.png\|jpg\|jpeg\|gif\|webp` | Hosted asset from `DataDir/hosted` (root-level, **not** `/hosted/`) |
| everything else | `uiDir/index.html` (Astro SPA shell) |

## Legacy Nginx proxy mapping (`web/default.conf`)

In the older 3-container architecture, Nginx proxied only `/latest` and `/upload` to the watcher on `host.docker.internal:31243` (with `client_max_body_size 50m` on `/upload`). `/hybrid`, `/stateless`, and `/api/*` are **not** proxied there; `/health` is answered by Nginx itself. See `architecture-web.md`.
