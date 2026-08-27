# Development guide

Develop ssbnk in `/home/delorenj/code/ssbnk`. The repository contains the
application source, the canonical image build, and an isolated Compose stack
with disposable local data. Production configuration remains in `~/docker`.

## Prerequisites

Install the following tools:

- Go compatible with the `watcher/go.mod` directive;
- Node.js 22.12 or newer;
- Docker with Docker Compose;
- mise for the repository tasks; and
- 1Password CLI only when you need injected nondevelopment configuration.

The container includes `ffmpeg` and `wl-copy`. Install them on the host only if
you run the Go binary or desktop scripts directly.

## Verify the source

Run the complete source check from the repository root:

```bash
mise run test
```

The task runs these checks:

- `go test -race ./...` in `watcher/`;
- `npm ci` and a high-severity dependency audit in `ui/`;
- the Astro production build; and
- a guard that rejects the production-only `ss.delo.sh` hostname in the UI
  build output.

Run an individual check with `mise run test:go` or `mise run test:ui`.

## Run the development stack

Start the isolated stack with:

```bash
mise run dev
```

`dev:init` creates the ignored `.dev-data/` directories, and Compose builds the
canonical root `Dockerfile`. The public service listens on
`http://localhost:13143` by default. Override the port with
`SSBNK_DEV_PORT`.

The development stack has these properties:

- It doesn't join the production `proxy` network.
- It uses only `.dev-data/` bind mounts.
- It uses `development-only` as the default local upload key.
- It runs read-only with dropped capabilities and a writable `tmpfs`.
- Its maintenance service defaults to `cleanup --dry-run`.

Stop it with:

```bash
mise run dev:down
```

## Exercise ingestion

Place an image in `.dev-data/screenshots/`, then inspect the gallery or API:

```bash
curl http://localhost:13143/health
curl "http://localhost:13143/api/screenshots?limit=1"
```

Place a supported video in `.dev-data/screencasts/` to exercise `ffmpeg`
conversion. Generated assets, metadata, archives, and state markers stay under
`.dev-data/data/` and aren't tracked.

To test authenticated upload, send a real image body and the configured
development key:

```bash
curl \
  -H 'X-Upload-Key: development-only' \
  -F 'file=@/path/to/test-image.png' \
  http://localhost:13143/upload
```

## Preview cleanup

Run native cleanup against development data without mutating it:

```bash
mise run dev:cleanup
```

The command starts the maintenance profile and passes `--dry-run`. You can set
`SSBNK_HOSTED_RETENTION_DAYS` and `SSBNK_ARCHIVE_RETENTION_DAYS` to exercise
different policies.

## Test desktop clipboard delivery

The desktop bridge is optional during development. Start it only from a
Wayland session:

```bash
mise run dev:clipboard
```

Compose gives this service no network, read-only access to the development
state directory, and a bind mount for the exact Wayland socket. Writing a new
URL to `.dev-data/data/state/latest-url` through normal ingestion must update
the text clipboard.

## Run components directly

Use direct execution for focused debugging:

```bash
cd watcher
go run . serve
go run . cleanup --dry-run
go run . clipboard-bridge
```

When you run `serve` directly, set `SSBNK_SCREENSHOT_DIR`,
`SSBNK_SCREENCAST_DIR`, `SSBNK_DATA_DIR`, `SSBNK_STATE_DIR`,
`SSBNK_API_PORT`, and `SSBNK_URL` to writable local paths and values.

For Astro hot reload, start the Go API separately and run:

```bash
cd ui
SSBNK_DEV_API_URL=http://127.0.0.1:8080 npm run dev
```

The Astro development server proxies API, upload, hosted-image, and latest
routes to `SSBNK_DEV_API_URL`. The production build uses same-origin requests.

## Build the image

Build the canonical local image with:

```bash
mise run build
```

The task labels the build with the current Git revision and description and
tags it as `ssbnk:dev`. Production promotion happens through CI and the
deployment hub, not by running production Compose from this checkout.
