# Source Tree Analysis

Multi-part repository. Four documented parts: `watcher/` (Go backend), `ui/` (Astro/React frontend), `web/` (Nginx configs — legacy architecture), `scripts/` (Bash automation). Excludes agent-tooling dotdirs, `_bmad*`, and `watcher-data/` (runtime output).

```
ssbnk/
├── compose.yml                     # Dev/maintainer stack: watcher + cleanup, Traefik labels
├── docker-compose.packaged.yml     # All-in-one consumer stack (supervisord: nginx+watcher+cron)
├── Dockerfile                      # All-in-one image (nginx:alpine + supervisord) — NOT used by compose.yml
├── mise.toml                       # Tasks: build/tag/push/deploy/test/dev/version*
├── .mise/scripts/versioning.sh     # Semver workflow backing mise version tasks
├── .github/workflows/
│   ├── docker-build.yml            # CI: multi-arch builds of both images → Docker Hub + GHCR
│   ├── opencode.yml                # /oc comment-triggered AI agent
│   └── opencode-review.yml         # Automatic AI PR review
│
├── watcher/                        # PART: watcher (Go backend) — the core service
│   ├── main.go                     # ENTRY POINT (1392 LOC): fsnotify loop + HTTP API + clipboard
│   ├── main_test.go                # Broken: references removed Config fields (doesn't compile)
│   ├── test_hybrid_endpoints.go    # Misnamed — real tests that never run, compiled into binary
│   ├── main.go.backup              # Stale tracked backup — dead weight
│   ├── ssbnk-watcher               # Compiled 9.8MB binary accidentally tracked in git
│   ├── go.mod / go.sum             # fsnotify v1.7.0, google/uuid v1.6.0
│   └── Dockerfile                  # 3-stage: Go build → Astro UI build → alpine runtime (used by compose.yml)
│
├── ui/                             # PART: ui (Astro 6 + React 19) — has its own .git (separate repo)
│   ├── astro.config.mjs            # react() integration + @tailwindcss/vite; static output
│   ├── package.json                # Scripts: dev/build/preview (astro). NO test script
│   ├── components.json             # shadcn config (style base-nova, @base-ui/react primitives)
│   ├── tsconfig.json               # strict; alias @/* → ./src/*
│   └── src/
│       ├── pages/index.astro       # ENTRY: sole page, mounts gallery island
│       ├── layouts/Layout.astro    # HTML shell, dark mode forced
│       ├── components/
│       │   ├── ScreenshotGallery.tsx  # The entire app: grid/list gallery + pagination
│       │   ├── Welcome.astro       # Unused starter leftover
│       │   └── ui/                 # shadcn primitives (button, card, toggle, toggle-group)
│       ├── lib/utils.ts            # cn()
│       └── styles/global.css       # Tailwind 4 CSS-first config, shadcn neutral theme
│
├── web/                            # PART: web (Nginx — legacy 3-container architecture)
│   ├── nginx.conf                  # http-level: security headers, CORS, rate-limit zone
│   ├── default.conf                # server ss.delo.sh:80; proxies /latest + /upload → watcher:31243
│   └── html/                       # ~136 hosted asset files (runtime data, served root-level by watcher)
│
├── scripts/                        # PART: scripts (Bash automation)
│   ├── paste-image.sh              # CURRENT: Ctrl+Shift+V handler (wl-copy + ydotool)
│   ├── remote-screenshot-upload.sh # CURRENT: reference uploader for remote machines (inotifywait → POST /upload)
│   ├── cleanup.sh                  # CURRENT: retention cron (runs in ssbnk-cleanup container)
│   ├── detect-display-server.sh    # CURRENT: Wayland/X11 diagnostic
│   ├── build-and-push.sh           # Maintainer release script for all-in-one image
│   ├── generate-missing-metadata.{sh,go}  # One-off metadata backfill (hardcoded ss.delo.sh)
│   ├── run-ssbnk.sh                # Curl-pipe-bash installer for packaged image
│   └── [legacy] fast-screenshot-sync.sh, force-screenshot-sync.sh, sync-now.sh,
│       local-screenshot-watcher.sh, instant-screenshot.sh,   # Syncthing/"Bloodbank"-era
│       clipboard-bridge.sh, clipboard-http.sh, setup-browser-bridge.sh,  # superseded experiments
│       mount-volume.sh, umount-volume.sh, get-hosted-url.sh  # dead volume-mount helpers
│
├── assets/logo/                    # Branding + privacy.html / terms.html
├── docs/                           # This documentation set (+ API.md, investigation report)
├── watcher-data/                   # Runtime metadata output (local dev)
├── README.md / CONTRIBUTING.md / DEPLOYMENT.md / CHANGELOG.md
└── AGENTS.md / CLAUDE.md / GEMINI.md   # Agent instructions (CLAUDE/GEMINI symlinked to AGENTS)
```

## Critical folders

| Folder | Why it matters |
|---|---|
| `watcher/` | The entire runtime: one Go binary does watching, conversion, hosting, API, UI serving, clipboard |
| `ui/src/components/` | The whole frontend is `ScreenshotGallery.tsx`; `ui/` subdir has unused scaffold |
| `web/html/` | Live hosted assets — runtime data, not source |
| `scripts/` | Half current automation, half legacy — see table in `architecture-scripts.md` |

## Entry points

- **Container:** `watcher/Dockerfile` CMD `./watcher` → `main()` in `watcher/main.go` (fsnotify loop + `startAPIServer` on `:80`)
- **UI dev:** `cd ui && npm run dev` (Astro, localhost:4321)
- **Host keyboard shortcut:** `scripts/paste-image.sh` via `~/.local/bin/ssbnk-paste-image` symlink
- **Remote machines:** `scripts/remote-screenshot-upload.sh` under systemd user service / launchd agent

## Integration points

- Watcher → host clipboard: Wayland socket bind-mounted into container (`wl-copy`), FIFO/HTTP fallbacks
- Watcher → host file: `/tmp/ssbnk/last-screenshot` (shared bind mount) → `paste-image.sh`
- Remote machines → watcher: `POST /upload` with `X-Upload-Key`
- UI → watcher: `GET /api/screenshots` (same origin in production — watcher serves the Astro build)
- Traefik → watcher: external `proxy` network, `Host(ss.delo.sh)`, LE TLS; file-based dynamic config with `/health` check
