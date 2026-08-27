# ssbnk documentation

This documentation describes the current single-image ssbnk architecture. The
source repository owns the application, frontend, image build, development
stack, tests, and release workflow. The deployment hub at `~/docker` owns the
production image digest, Compose topology, secrets injection, mounts, routing,
and systemd schedules.

## Project summary

The current system has these defining properties:

- **Runtime:** one `ssbnk` binary and one canonical container image.
- **Commands:** `serve`, `cleanup [--dry-run]`, and `clipboard-bridge`.
- **Backend:** Go, `fsnotify`, `net/http`, and `ffmpeg`.
- **Frontend:** Astro 7 with a React 19 gallery, embedded in the image.
- **State:** files in `hosted/`, `metadata/`, `archive/`, and `state/`.
- **Production:** `https://ss.delo.sh`, routed to the `serve` container.

## Architecture documentation

Use these pages to understand the implementation and its contracts:

- [Project overview](./project-overview.md)
- [Integration architecture](./integration-architecture.md)
- [Go service architecture](./architecture-watcher.md)
- [UI architecture](./architecture-ui.md)
- [Supporting scripts](./architecture-scripts.md)
- [Source tree analysis](./source-tree-analysis.md)
- [UI component inventory](./component-inventory-ui.md)
- [Data models](./data-models-watcher.md)
- [HTTP API contract](./api-contracts-watcher.md)
- [Project parts metadata](./project-parts.json)

## Operational guides

Use these guides for day-to-day work:

- [Development guide](./development-guide.md)
- [Deployment guide](./deployment-guide.md)

## Historical documentation

The following files remain for context, but they don't describe the current
runtime:

- [Legacy API page](./API.md) points to the current API contract.
- [Retired Nginx architecture](./architecture-web.md) records why the old web
  tier was removed.
- [Latest endpoint investigation](./latest-endpoint-investigation-report.md)
  is historical evidence from the November 2025 routing incident.
- [Initial project scan](./project-scan-report.json) records the July 2026
  documentation scan and intentionally retains its original observations.

## Start developing

Run the verified source checks, then start the isolated development stack:

```bash
mise run test
mise run dev
```

The development service listens on `http://localhost:13143` by default. Read
the [development guide](./development-guide.md) for data directories, optional
desktop integration, and cleanup previews.
