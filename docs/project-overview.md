# ssbnk project overview

ssbnk is a self-hosted screenshot and screencast service. It ingests local
files or authenticated uploads, normalizes their names, writes metadata,
serves the files and gallery, and publishes the latest hosted URL for an
isolated desktop clipboard bridge.

## Runtime model

One Go binary provides three commands:

- `ssbnk serve` watches media directories, handles uploads, serves the HTTP
  API, serves hosted assets, and serves the embedded Astro UI. Running `ssbnk`
  without a command is equivalent to `ssbnk serve`.
- `ssbnk cleanup [--dry-run]` applies hosted-file and archive retention,
  removes orphaned metadata, and repairs the latest state markers.
- `ssbnk clipboard-bridge` watches `/data/state/latest-url` and copies each new
  URL to the Wayland clipboard.

The canonical `Dockerfile` builds the Go binary and Astro static assets into
one image. Production runs that same immutable image with different commands
and permissions for the public service, cleanup job, and clipboard bridge.

## Architecture boundaries

The two repositories have different responsibilities:

- `/home/delorenj/code/ssbnk` owns application behavior, tests, the canonical
  `Dockerfile`, `compose.dev.yml`, task definitions, and image publishing.
- `/home/delorenj/docker/stacks/utils/ssbnk` owns the production image digest,
  Compose services, host paths, secret references, Traefik labels, and systemd
  units.

This split keeps development next to the source while preserving a single
versioned operations hub for every deployed stack. Production never builds
from a relative application checkout.

## Technology summary

The build combines a small set of established tools:

| Area | Technology | Role |
| --- | --- | --- |
| Runtime | Go 1.26 module, `fsnotify`, `net/http` | Ingestion, API, cleanup, and state bridge |
| Media | `ffmpeg` | Screencast-to-GIF conversion |
| UI | Astro 7, React 19, TypeScript, Tailwind CSS 4 | Static screenshot gallery |
| Image | Multi-stage Docker build on Alpine 3.22 | One deployable artifact |
| Development | Docker Compose and mise | Isolated local stack and checks |
| Production | Docker Compose, systemd, Traefik, 1Password | Digest-pinned operation |

## Data and security model

ssbnk doesn't use a database. The `/data` tree contains hosted assets,
metadata sidecars, dated archives, and two small state markers. The public
service mounts media and application data, but it receives no display socket.
Only the network-disabled clipboard bridge receives the exact Wayland socket
and read-only state directory. The cleanup job also has no network.

`POST /upload` requires `SSBNK_UPLOAD_KEY`. Production injects the value at
runtime through the deployment hub's 1Password environment template; the
source repository contains no credential value.

## Related documentation

Use the following documents for implementation detail:

- [Integration architecture](./integration-architecture.md)
- [Go service architecture](./architecture-watcher.md)
- [UI architecture](./architecture-ui.md)
- [Data models](./data-models-watcher.md)
- [Development guide](./development-guide.md)
- [Deployment guide](./deployment-guide.md)
