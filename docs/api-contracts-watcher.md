# HTTP API contract

`ssbnk serve` exposes the API, hosted assets, and embedded UI on
`SSBNK_API_PORT`, which defaults to 80. Production routes this server through
Traefik at `https://ss.delo.sh`.

## Common response behavior

Every route receives these headers:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: SAMEORIGIN`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, X-Upload-Key, X-API-Key`

Any `OPTIONS` request returns status 200. Hosted image responses also receive
`Cache-Control: public, max-age=86400, immutable`.

Only `POST /upload` requires authentication. Other read endpoints are public
by design.

## `GET /api/screenshots`

This endpoint returns metadata for the gallery.

| Query parameter | Default | Validation |
| --- | ---: | --- |
| `limit` | 50 | Positive integer |
| `offset` | 0 | Nonnegative integer |

Invalid values fall back to their defaults. Results sort by timestamp in
descending order. Hosted files without metadata receive synthesized entries.

```json
{
  "screenshots": [
    {
      "id": "92ef3c67-b7d8-4fd2-b58e-4ccfb8521800",
      "original_name": "Screenshot.png",
      "filename": "20260827-1430.png",
      "url": "https://ss.delo.sh/20260827-1430.png",
      "timestamp": "2026-08-27T14:30:00-04:00",
      "preserve": false,
      "size": 12345
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 50
}
```

## `GET /latest` and `GET /latest/{offset}`

This endpoint sorts decoded root metadata by stored timestamp and returns a
302 redirect to the selected record's URL. It doesn't validate the hosted file
before redirecting.

- An out-of-range offset returns status 404.
- An unreadable metadata directory returns status 500.

## `GET /hybrid` and `GET /hybrid/{offset}`

This endpoint tries metadata first and verifies that the referenced file
exists. If metadata is missing or inconsistent, it scans hosted images by file
modification time. Success returns a 302 redirect. A missing offset returns
status 404 with the available file count.

## `GET /stateless` and `GET /stateless/{offset}`

This endpoint ignores metadata and selects directly from hosted image files by
modification time. It returns the same redirect and 404 forms as `/hybrid`.

## `POST /upload`

This endpoint accepts an authenticated multipart image upload.

The request contract is:

- Header `X-Upload-Key` and `SSBNK_UPLOAD_KEY` are SHA-256 hashed, then compared
  in constant time.
- Multipart field `file` must contain PNG, JPEG, GIF, or WebP bytes.
- The file maximum is 50 MiB, with one additional MiB permitted for multipart
  overhead.
- Server-side content sniffing determines the accepted type and destination
  extension; the client filename and declared MIME type aren't trusted.

Success stores the asset and metadata, atomically publishes
`last-screenshot` and `latest-url`, and returns status 200:

```json
{
  "url": "https://ss.delo.sh/20260827-1430.png",
  "filename": "20260827-1430.png"
}
```

State publication is best-effort. A missing clipboard bridge doesn't turn a
valid upload into a failure.

The main error responses are:

| Status | Condition |
| ---: | --- |
| 400 | Invalid multipart input, missing file, or read failure |
| 401 | Upload key mismatch |
| 405 | Method other than `POST` |
| 413 | Request or file exceeds the configured maximum |
| 415 | Bytes aren't an accepted image type |
| 500 | Asset or metadata storage failure |
| 503 | `SSBNK_UPLOAD_KEY` isn't configured |

## `GET /health`

This endpoint compares root metadata with hosted files and always returns
status 200 when the handler runs. `status` is `warning` when inconsistencies
exist and `ok` otherwise.

```json
{
  "status": "ok",
  "metadata_count": 47,
  "actual_file_count": 47,
  "timestamp": "2026-08-27T14:30:00-04:00"
}
```

`consistency_issues` appears only when the check finds missing sidecars or
missing hosted assets.

## Static routes

The same Go server handles static content:

| Path | Content |
| --- | --- |
| `/_astro/*` and `/favicon.svg` | Embedded Astro build from `SSBNK_UI_DIR` |
| Root image paths | Files from `<SSBNK_DATA_DIR>/hosted` |
| Other paths | Astro `index.html` fallback |

Hosted assets are root-level URLs, not `/hosted/{filename}`.
