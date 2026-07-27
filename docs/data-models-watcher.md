# Data Models — Watcher

ssbnk has no database. State lives in two directories under `SSBNK_DATA_DIR` (default `/data`):

- `hosted/` — the served asset files (one per screenshot/GIF)
- `metadata/` — one JSON sidecar per asset, named `<uuid>.json`
- `archive/` (host-side, cleanup only) — retention archive organized as `YYYY-MM-DD/`

## `ScreenshotMetadata` (watcher/main.go:23-34)

Written by `saveMetadata` with `json.MarshalIndent` (2-space), mode 0644:

```json
{
  "id":            "uuid — matches the metadata filename",
  "original_name": "source filename before normalization",
  "filename":      "hosted filename, e.g. 20260214-1147.png",
  "url":           "BaseURL + filename",
  "timestamp":     "RFC3339",
  "description":   "omitempty — declared but never set by any code path",
  "batch_id":      "omitempty — declared but never set",
  "preserve":      false,
  "repo_name":     "omitempty — declared but never set",
  "size":          12345
}
```

- `description`, `batch_id`, `repo_name` are struct-only leftovers; the backfill tools (`scripts/generate-missing-metadata.*`) also omit them.
- `preserve: true` is honored by `scripts/cleanup.sh` (skips archiving) but nothing currently sets it.
- Gap-fill entries synthesized by `/api/screenshots` contain only `filename`, `url`, `timestamp`, `size`.

## File naming

`YYYYMMDD-HHMM<ext>` (minute granularity, local time), with `-N` collision suffixes. Non-GIF screenshots are copied to `hosted/` with a forced `.png` extension **regardless of actual format** — a `.jpg`/`.webp` upload becomes `.png`-named with non-PNG bytes (browsers sniff content, so it works, but the name lies).

## `/tmp/ssbnk/last-screenshot`

Contains just the **basename** of the most recently ingested file (no newline, mode 0644). Written after every successful ingestion (screenshot, GIF, video, upload). The `/tmp/ssbnk` dir is bind-mounted into the watcher container so the host-side `scripts/paste-image.sh` can resolve the filename against `web/html/`.

## Retention (`scripts/cleanup.sh`)

Runs daily at 02:00 in the `ssbnk-cleanup` Alpine container. `SSBNK_RETENTION_DAYS` (default 30):

1. Moves hosted files older than retention to `archive/YYYY-MM-DD/` (skips `preserve: true`)
2. Archives matching metadata
3. Deletes archive dirs older than retention
4. Removes orphaned metadata
