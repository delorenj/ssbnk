# Data models and filesystem state

ssbnk uses the filesystem as its durable state store. The `serve`, `cleanup`,
and `clipboard-bridge` commands share a small, explicit directory contract
instead of a database.

## Data tree

The default `SSBNK_DATA_DIR` is `/data`:

```text
/data/
├── hosted/                 # Publicly served assets
├── metadata/               # Root JSON sidecars for hosted assets
├── archive/
│   └── YYYY-MM-DD/         # Archived asset and sidecar pairs
└── state/
    ├── last-screenshot     # Latest hosted filename
    └── latest-url          # Latest public URL and clipboard trigger
```

`SSBNK_STATE_DIR` can place the state directory elsewhere, but the production
stack keeps it under `/data/state`.

## Screenshot metadata

Each stored asset normally has one JSON sidecar named `<uuid>.json` in
`metadata/`. The Go `ScreenshotMetadata` structure has this shape:

```json
{
  "id": "92ef3c67-b7d8-4fd2-b58e-4ccfb8521800",
  "original_name": "Screenshot 2026-08-27.png",
  "filename": "20260827-1430.png",
  "url": "https://ss.delo.sh/20260827-1430.png",
  "timestamp": "2026-08-27T14:30:00-04:00",
  "description": "optional",
  "batch_id": "optional",
  "preserve": false,
  "repo_name": "optional",
  "size": 12345
}
```

The API synthesizes minimal records for hosted assets that don't have a
sidecar. Cleanup, however, strictly decodes relevant metadata and fails before
mutation if a JSON file is malformed, contains unknown fields, has trailing
data, or contains an unsafe filename.

## Asset names

Local ingestion uses `YYYYMMDD-HHMM<extension>` and adds `-N` for collisions.
Current non-GIF screenshot handling gives destination files a `.png` suffix
without transcoding their bytes. Video ingestion produces `.gif` output.

## State markers

Successful ingestion atomically publishes two newline-terminated text files:

- `last-screenshot` contains a hosted basename such as
  `20260827-1430.png`.
- `latest-url` contains its public URL and triggers the clipboard bridge.

The service writes `last-screenshot` first so a bridge reacting to
`latest-url` always sees the matching filename. Cleanup repairs both markers
to a remaining hosted asset after archival or removes both when no hosted
image remains.

## Retention model

Cleanup applies two independent periods:

- `SSBNK_HOSTED_RETENTION_DAYS` controls when an unpreserved hosted file moves
  into today's archive. If unset, it falls back to the legacy
  `SSBNK_RETENTION_DAYS`, then 30 days.
- `SSBNK_ARCHIVE_RETENTION_DAYS` controls when a valid dated archive directory
  is deleted. It defaults to 30 days.

`preserve: true` prevents a hosted asset from being archived. Unknown archive
directory names are never age-deleted. Cleanup also prevents overwrites,
removes root metadata only when its asset is absent from hosted and retained
archive storage, and holds an exclusive lock on the data directory.
