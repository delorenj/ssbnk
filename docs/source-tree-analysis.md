# Source tree analysis

The source repository has two application areas and a small set of host-client
utilities. It deliberately excludes production Compose and systemd ownership,
which live in `/home/delorenj/docker/stacks/utils/ssbnk`.

```text
ssbnk/
├── Dockerfile                     # Canonical Go plus Astro image
├── compose.dev.yml                # Isolated development and profile services
├── mise.toml                      # Test, build, dev, and version tasks
├── .dockerignore                  # Excludes tooling and generated data
├── .github/workflows/
│   └── docker-build.yml           # Test and multi-architecture image publish
│
├── watcher/                       # Go package for every runtime command
│   ├── cli.go                     # serve, cleanup, clipboard-bridge dispatch
│   ├── main.go                    # Ingestion, conversion, HTTP API, static UI
│   ├── state.go                   # Atomic markers and Wayland bridge
│   ├── cleanup.go                 # Native retention engine
│   ├── *_test.go                  # CLI, API, state, and cleanup tests
│   └── go.mod / go.sum
│
├── ui/                            # Astro and React static frontend
│   ├── astro.config.mjs           # React, Tailwind, and local API proxy
│   ├── package.json / package-lock.json
│   └── src/
│       ├── pages/index.astro
│       ├── layouts/Layout.astro
│       ├── components/ScreenshotGallery.tsx
│       ├── components/ui/
│       └── styles/global.css
│
├── scripts/                       # Host and remote-client helpers
│   ├── paste-image.sh
│   ├── remote-screenshot-upload.sh
│   ├── install-remote-client.sh
│   └── generate-missing-metadata.{go,sh}
│
├── docs/                          # Architecture, contracts, and guides
└── assets/                        # Project branding and legal pages
```

Agent framework and project-management directories are repository tooling, not
application runtime. `.dev-data/`, UI build output, logs, state databases, and
local environment material are ignored and excluded from the image context.

## Runtime entry points

The primary entry points are:

- `/usr/local/bin/ssbnk serve` for the public application;
- `/usr/local/bin/ssbnk cleanup [--dry-run]` for maintenance;
- `/usr/local/bin/ssbnk clipboard-bridge` for host clipboard delivery;
- `ui/src/pages/index.astro` for the static browser application;
- `scripts/paste-image.sh` for the desktop paste shortcut; and
- `scripts/remote-screenshot-upload.sh` for remote clients.

The root image uses `ssbnk` as its entry point and `serve` as its default
command. Compose selects the other roles without building another image.

## Repository boundary

The source tree doesn't contain a production `compose.yml`. This absence is an
architectural guardrail: local development uses `compose.dev.yml`, while the
central deployment hub stores the exact production image digest and host
integration.

The deleted `web/`, packaged Compose, watcher-specific Dockerfile, supervisor
configuration, and shell cleanup entry point belong to the retired
architecture. [Retired Nginx architecture](./architecture-web.md) preserves a
short historical explanation without presenting those files as deployable.
