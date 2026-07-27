# Project Documentation Index — ssbnk

Generated: 2026-07-24 (deep scan, initial)

## Project Overview

- **Type:** multi-part with 4 parts
- **Primary Language:** Go (core), TypeScript (UI), Bash (automation)
- **Architecture:** event-driven single-process core; filesystem-as-database; two-container Docker stack behind Traefik
- **Production:** `https://ss.delo.sh`

## Quick Reference

#### Watcher/API (`watcher`) — backend

- **Tech Stack:** Go 1.21, fsnotify, google/uuid, ffmpeg (subprocess)
- **Root:** `watcher/` · **Entry:** `watcher/main.go`
- Single binary: fsnotify ingestion + HTTP API + static hosting + UI serving + host clipboard

#### Management UI (`ui`) — web

- **Tech Stack:** Astro 6, React 19, TypeScript, Tailwind 4, shadcn (@base-ui/react)
- **Root:** `ui/` (own .git repo) · **Entry:** `ui/src/pages/index.astro`
- Static build served by the watcher; one gallery screen calling `/api/screenshots`

#### Nginx Hosting (`web`) — infra (legacy)

- **Tech Stack:** Nginx
- **Root:** `web/` · Retired 3-container architecture; only in the packaged all-in-one image
- `web/html/` holds the live hosted assets

#### Automation (`scripts`) — cli

- **Tech Stack:** Bash/POSIX sh, inotifywait, wl-clipboard, ydotool, curl
- **Root:** `scripts/` · Current: paste-image, remote upload, cleanup; ~half legacy

## Generated Documentation

- [Project Overview](./project-overview.md)
- [Architecture — Watcher](./architecture-watcher.md)
- [Architecture — UI](./architecture-ui.md)
- [Architecture — Web (Nginx, legacy)](./architecture-web.md)
- [Architecture — Scripts](./architecture-scripts.md)
- [Source Tree Analysis](./source-tree-analysis.md)
- [Component Inventory — UI](./component-inventory-ui.md)
- [Development Guide](./development-guide.md)
- [Deployment Guide](./deployment-guide.md)
- [API Contracts — Watcher](./api-contracts-watcher.md)
- [Data Models — Watcher](./data-models-watcher.md)
- [Integration Architecture](./integration-architecture.md)
- [Project Parts Metadata](./project-parts.json)

## Existing Documentation

- [README](../README.md) — project readme
- [CONTRIBUTING](../CONTRIBUTING.md) — contribution guidelines (style, PR process, manual test checklist)
- [DEPLOYMENT](../DEPLOYMENT.md) — deployment guide (partially superseded by deployment-guide.md)
- [CHANGELOG](../CHANGELOG.md) — release history
- [API.md](./API.md) — ⚠️ outdated: documents `/hosted/` prefix and misses `/upload`, `/hybrid`, `/stateless`, `/health`, `/api/screenshots`; use api-contracts-watcher.md instead
- [latest-endpoint-investigation-report.md](./latest-endpoint-investigation-report.md) — Nov 2025 Traefik incident postmortem (older 3-container layout)
- [ui/README.md](../ui/README.md) — stock Astro starter readme
- [AGENTS.md](../AGENTS.md) — agent instructions (⚠️ partially stale: "React + Express" UI, Nginx proxy on 31243)

## Getting Started

```bash
cp .env.example .env            # or let mise's enter hook run: op inject -i .env.op > .env
docker compose up -d            # full stack (watcher + cleanup)
mise run test                   # watcher tests (currently broken — see development-guide.md)
cd ui && npm install && npm run dev   # UI dev server on :4321
```

New contributors: read [project-overview.md](./project-overview.md) → [architecture-watcher.md](./architecture-watcher.md) → [development-guide.md](./development-guide.md).
