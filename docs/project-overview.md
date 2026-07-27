# Project Overview — ssbnk (ScreenShot Bank)

## Purpose

ssbnk is a self-hosted screenshot/screencast hosting service. It watches local folders, normalizes filenames, hosts assets, and exposes "latest" retrieval endpoints. Remote machines upload screenshots via an `/upload` API; the hosted URL is copied to the host clipboard automatically. Production instance: `https://ss.delo.sh`.

## Executive summary

A single Go binary is the core: it watches screenshot/screencast directories (fsnotify), converts videos to GIF (ffmpeg), stores assets plus JSON metadata sidecars, serves the assets/API/Astro UI over HTTP, and integrates with the host clipboard (Wayland/X11). Remote Tailnet machines run a Bash uploader that POSTs new screenshots. A cron container enforces retention. The whole stack is two containers behind Traefik with Let's Encrypt TLS, fronted by a Cloudflare Tunnel.

## Tech stack summary

| Part | Stack | Type |
|---|---|---|
| `watcher/` | Go 1.21, fsnotify, uuid, ffmpeg, net/http | backend |
| `ui/` | Astro 6, React 19, TypeScript, Tailwind 4, shadcn (@base-ui/react) | web |
| `web/` | Nginx (legacy 3-container architecture) | infra |
| `scripts/` | Bash/POSIX sh, inotifywait, wl-clipboard, ydotool | cli |

## Architecture type

Multi-part repository, event-driven single-process core. No database — the filesystem (`hosted/` + `metadata/` JSON sidecars) is the state. The watcher serves everything on port 80; Traefik handles routing/TLS.

## Repository structure

4 parts, documented separately — see [source-tree-analysis.md](./source-tree-analysis.md) and [project-parts.json](./project-parts.json). Integration between parts: [integration-architecture.md](./integration-architecture.md).

## Detailed documentation

- Architecture: [watcher](./architecture-watcher.md) · [ui](./architecture-ui.md) · [web](./architecture-web.md) · [scripts](./architecture-scripts.md)
- API: [api-contracts-watcher.md](./api-contracts-watcher.md)
- Data: [data-models-watcher.md](./data-models-watcher.md)
- UI components: [component-inventory-ui.md](./component-inventory-ui.md)
- Guides: [development](./development-guide.md) · [deployment](./deployment-guide.md)

## Current state highlights (as of 2026-07)

- Go tests are broken (`main_test.go` stale; misnamed test file ships in binary)
- A 9.8 MB compiled binary and a `main.go.backup` are tracked in git
- AGENTS.md and docs/API.md describe a retired architecture (Nginx container, React+Express UI, `/hosted/` prefix)
- Legacy scripts carry a hardcoded Syncthing API key
