# Go service architecture

The `watcher/` package builds one `ssbnk` binary. Its command dispatcher keeps
the long-running web service, one-shot retention maintenance, and desktop
clipboard integration in a single versioned artifact while letting Compose
isolate each role.

## Command surface

The binary accepts the following commands:

| Command | Lifecycle | Responsibility |
| --- | --- | --- |
| `ssbnk` or `ssbnk serve` | Long-running | Watch, ingest, convert, host, and serve the UI and API |
| `ssbnk cleanup` | One-shot | Apply retention and repair state markers |
| `ssbnk cleanup --dry-run` | One-shot, read-only | Validate data and print the planned actions |
| `ssbnk clipboard-bridge` | Long-running | Copy new `latest-url` values with `wl-copy` |
| `ssbnk help` | One-shot | Print command help |

Invalid commands and invalid arguments exit with status 2. Runtime failures
exit with status 1.

## Source layout

The Go runtime is split by responsibility:

- `watcher/cli.go` dispatches commands and reads common configuration.
- `watcher/main.go` implements ingestion, media conversion, HTTP routes, and
  static serving.
- `watcher/state.go` publishes atomic state markers and implements the
  clipboard bridge.
- `watcher/cleanup.go` plans and executes native retention cleanup.
- Files ending in `_test.go` cover the command surface, endpoints, state
  publication, clipboard retries, ingestion, and cleanup safety.

## Serve architecture

`serve` creates the hosted and metadata directories, watches the configured
screenshot and screencast directories with `fsnotify`, and starts the HTTP
server. It handles create and rename events in goroutines so one ingestion
doesn't block later filesystem events.

The ingestion paths are:

- Screenshots receive a `YYYYMMDD-HHMM` name with a collision suffix when
  needed. Non-GIF screenshots use a `.png` destination name.
- Fresh GIFs are moved directly into hosted storage.
- Videos are monitored for size and modification-time stability, converted to
  a ten-second looping GIF with `ffmpeg`, and then stored.
- Authenticated HTTP uploads accept PNG, JPEG, GIF, and WebP files up to 50 MB.

Local screenshot and screencast ingestion removes the source file after the
hosted copy succeeds. Those source mounts must therefore be read-write.

Each successful path stores the asset, writes a `ScreenshotMetadata` sidecar,
and publishes the `last-screenshot` and `latest-url` markers. Desktop failures
don't invalidate the stored upload.

## HTTP architecture

The Go `net/http` server listens on `SSBNK_API_PORT`, which defaults to port 80.
It serves the management UI, hosted assets, and API from one origin. The
current routes are documented in the
[HTTP API contract](./api-contracts-watcher.md).

All responses receive basic security headers and permissive CORS headers.
Image responses also receive a one-day immutable cache directive. Traefik
terminates production TLS and forwards directly to this server.

## State publication and clipboard isolation

`serve` never invokes a desktop command. It writes state through temporary
files and atomic renames in this order:

1. `/data/state/last-screenshot` receives the hosted filename.
2. `/data/state/latest-url` receives the public URL and acts as the trigger.

`clipboard-bridge` watches the state directory with `fsnotify` and polls every
two seconds by default. It reads the current URL at startup, ignores values
already copied successfully, and retries failed writes during polling. Each
`wl-copy` invocation has a two-second default timeout.

You can tune the bridge with `SSBNK_CLIPBOARD_POLL_INTERVAL` and
`SSBNK_CLIPBOARD_TIMEOUT`, using Go duration syntax such as `500ms` or `3s`.

## Native cleanup architecture

Cleanup uses a plan-then-mutate design. It obtains a nonblocking exclusive
lock on the data directory, strictly decodes relevant JSON metadata, validates
every destination, and constructs the full action set before changing files.

The command then performs these operations:

1. Move hosted files older than `SSBNK_HOSTED_RETENTION_DAYS` into today's
   dated archive unless any matching metadata has `preserve: true`.
2. Move every matching JSON sidecar beside its archived asset.
3. Delete archive directories older than `SSBNK_ARCHIVE_RETENTION_DAYS` only
   when their names are valid `YYYY-MM-DD` dates.
4. Remove root metadata whose asset exists in neither hosted nor retained
   archive storage.
5. Repair or clear the state markers when the previous latest asset moved.

Cleanup refuses target collisions and rolls back completed moves if a later
move fails. `--dry-run` prints the same plan without mutating the data tree.
The legacy `SSBNK_RETENTION_DAYS` variable remains a fallback for hosted-file
retention.

## Container image

The root `Dockerfile` is the only application image definition. It builds the
Go executable, builds the Astro UI, copies both into Alpine 3.22, installs
`ffmpeg` and `wl-clipboard`, and runs as UID and GID 1000. The image entry point
is `/usr/local/bin/ssbnk`, and its default command is `serve`.

The public container doesn't mount a Wayland or X11 socket. Production reuses
the image for a network-disabled clipboard bridge and network-disabled cleanup
job. See the [deployment guide](./deployment-guide.md).
