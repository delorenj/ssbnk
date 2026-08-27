# ssbnk (ScreenShot Bank)

Fast, self-hosted screenshot ingestion and sharing. A single Go binary watches
local screenshot folders, accepts authenticated remote uploads, serves the API
and bundled Astro gallery, converts screencasts to GIFs, and manages retention.

## One image, three commands

The canonical `delorenj/ssbnk` image contains the Go service, compiled frontend,
native cleanup implementation, ffmpeg, and the Wayland clipboard helper.

| Command | Responsibility |
| --- | --- |
| `ssbnk serve` | Watch files, ingest uploads, serve assets/API/UI, and publish desktop state |
| `ssbnk cleanup` | Archive and expire data in one bounded run (`--dry-run` supported) |
| `ssbnk clipboard-bridge` | Watch desktop state and copy the latest hosted URL with `wl-copy` |

No argument defaults to `serve`.

## Architecture

```text
local screenshot dirs ─┐
remote POST /upload ───┼─> ssbnk serve ─> /data ─> API + bundled Astro UI
browser / Traefik ─────┘         │
                                 └─> /data/state/latest-url
                                                │
                              isolated clipboard-bridge
                              (exact Wayland socket only)

systemd timer ─> compose run --rm cleanup ─> /data
```

The public service never receives the host's Wayland runtime directory or X11
socket. The optional bridge runs as the desktop user, has no network, and gets
only the exact Wayland socket plus read-only state.

## Development

Requirements: Docker Compose v2 and mise. The repository pins Go 1.26.7 and
Node 22 for reproducible local checks.

```bash
mise run test          # Go race/vet/vulnerability checks + production UI build
mise run build         # canonical local image: ssbnk:dev
mise run dev           # isolated stack on http://127.0.0.1:13143
mise run dev:cleanup   # native cleanup dry-run against .dev-data only
mise run dev:down
```

Development data lives under ignored `.dev-data/`. The source repository's
[`compose.dev.yml`](compose.dev.yml) is deliberately not a production manifest.

For UI-only work, start the Go service on `127.0.0.1:8080`, then run
`npm run dev` in `ui/`. Astro proxies API and hosted-image requests to that
backend. `PUBLIC_API_URL` is optional; production defaults to same-origin.

## Source versus deployment ownership

| Repository | Owns |
| --- | --- |
| `~/code/ssbnk` | Go/UI source, tests, Dockerfile, dev Compose, release workflow |
| `~/docker` | Pinned production digest, mounts, routing, secrets references, systemd units, rollback history |

This split keeps the application independently buildable while every running
stack remains visible and auditable in the central DeLoContainers hub. See
[`DEPLOYMENT.md`](DEPLOYMENT.md).

## API

| Endpoint | Method | Description |
| --- | --- | --- |
| `/api/screenshots` | GET | Paginated gallery metadata |
| `/latest[/N]` | GET | Metadata-driven latest screenshot redirect |
| `/hybrid[/N]` | GET | Metadata with filesystem fallback |
| `/stateless[/N]` | GET | Filesystem-only lookup |
| `/upload` | POST | Remote upload; requires `X-Upload-Key` |
| `/health` | GET | Service and metadata consistency status |

## Remote clients and paste-image helper

Run `scripts/install-remote-client.sh` from a clone to install the Linux or
macOS upload watcher. Credentials belong in the client's private runtime config,
not this repository.

`scripts/paste-image.sh` reads the canonical state marker and puts the image
payload on the Wayland clipboard before simulating paste. Its host data roots
can be overridden with `SSBNK_STATE_DIR` and `SSBNK_HOSTED_DIR`.

## License

[MIT](LICENSE)
