# Architecture — UI (Astro/React management interface)

## Executive summary

The management UI is a single-screen Astro 6 app with one React 19 island: a paginated screenshot gallery backed by the watcher's `/api/screenshots` endpoint. It builds to static files that the watcher serves itself (`SSBNK_UI_DIR`, default `/ui`) — there is no separate UI server. Early-stage but functional. **Note:** `ui/` contains its own `.git` directory (separate repository nested in this one).

## Technology stack

| Category | Technology | Version | Justification |
|---|---|---|---|
| Framework | Astro | ^6.0.5 | Static output, islands architecture |
| UI library | React | ^19.2.4 | Via `@astrojs/react` ^5.0.0 |
| Language | TypeScript | strict | `astro/tsconfigs/strict`, alias `@/* → ./src/*` |
| Styling | Tailwind CSS | ^4.2.1 | Vite plugin, CSS-first config |
| Components | shadcn (base-nova) | ^4.0.8 | On `@base-ui/react` ^1.3.0 primitives (not Radix) |
| Font | Geist Variable | @fontsource-variable | — |
| Node | >= 22.12.0 | engines | ESM (`"type": "module"`) |

## Architecture pattern

Static prerendering (no SSR adapter, no output mode set). One page (`src/pages/index.astro`) mounts one island (`<ScreenshotGallery client:load />`) inside `Layout.astro` (dark mode forced). `astro.config.mjs` is minimal: `react()` integration + `@tailwindcss/vite`. No dev-server proxy customization (dev on localhost:4321).

## Data flow

`ScreenshotGallery.tsx` fetches `GET ${API_BASE}/api/screenshots?limit=48&offset=N` where `API_BASE = PUBLIC_API_URL` (build-time env, default `https://ss.delo.sh`; no `.env` file exists in `ui/`). Response: `{screenshots[], total, offset, limit}`. In production this is same-origin because the watcher serves the built UI. Fetch failures only `console.error` — no error UI.

## Component overview

| Component | Status | Purpose |
|---|---|---|
| `pages/index.astro` | used | Sole page; mounts the gallery |
| `layouts/Layout.astro` | used | HTML shell, `class="dark"`, title "ssbnk" |
| `components/ScreenshotGallery.tsx` | used | The entire app: grid/list toggle, lazy thumbnails, offset pagination, size/date formatting |
| `components/ui/toggle-group.tsx`, `toggle.tsx` | used | View-mode switcher (`@base-ui/react` + context) |
| `components/ui/button.tsx`, `card.tsx` | **unused** | shadcn scaffold; gallery uses raw `<button>` |
| `components/Welcome.astro`, `assets/*` | **unused** | Astro starter leftovers |
| `lib/utils.ts` | used | `cn()` |

## Styling

Tailwind 4 CSS-first in `src/styles/global.css`: `@import "tailwindcss"`, `tw-animate-css`, `shadcn/tailwind.css`, Geist font; shadcn neutral theme as oklch CSS variables for `:root`/`.dark`, `@theme inline` mapping, `@custom-variant dark`.

## Build & deployment

`npm run build` → `dist/`. The watcher Dockerfile's `ui-builder` stage runs `npm ci && npm run build` and copies `dist` into the runtime image at `/ui`; the watcher serves `/_astro/*`, `/favicon.svg`, and `index.html` fallback. Dev: `npm run dev`. **No test script exists.**

## Maturity & debt

Functional single screen with a real backend contract; everything else is starter scaffolding (stock README, unused components). No tests, no env file, no error states, no theme switcher. Older docs (AGENTS.md) describe a retired "React + Express + Vite" stack — the Astro rewrite replaced it.
