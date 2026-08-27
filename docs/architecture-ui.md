# UI architecture

The management UI is an Astro 7 static application with one React 19 island.
The canonical Docker build embeds its output at `/ui`, and `ssbnk serve`
delivers the UI and API from the same HTTP origin. There is no standalone
frontend service in production.

## Technology stack

The UI build uses these technologies:

| Category | Technology | Version or mode |
| --- | --- | --- |
| Framework | Astro | 7 |
| Interactive UI | React | 19 |
| Language | TypeScript | Strict configuration |
| Styling | Tailwind CSS | 4 |
| Components | shadcn with `@base-ui/react` | `base-nova` style |
| Build output | Static files | `ui/dist/` |

## Application structure

`ui/src/pages/index.astro` mounts
`ui/src/components/ScreenshotGallery.tsx` with `client:load`. The gallery is
the functional application surface: it fetches metadata, renders grid and list
views, formats sizes and dates, and provides offset pagination.

`ui/src/layouts/Layout.astro` provides the HTML shell. The shadcn toggle
components implement the view selector, and `ui/src/styles/global.css`
contains the Tailwind and theme tokens.

## API integration

The gallery requests:

```text
/api/screenshots?limit=48&offset=<offset>
```

`PUBLIC_API_URL` is optional. Its default is an empty string, which makes
requests same-origin in local and production containers. Set it only when you
intentionally run the Astro development server against a different API host.
The build removes a trailing slash before composing request URLs.

## Build and delivery

The UI builder stage runs `npm ci` and `npm run build`. The final image copies
`ui/dist/` to `/ui`. The Go server handles `/_astro/*`, `/favicon.svg`, and the
static `index.html` fallback.

CI builds the UI before publishing the image and rejects a build that contains
the production-only `ss.delo.sh` API hostname. This check prevents a local or
future deployment from silently calling the current production API.

## Development

Run the UI-only development server when you need Astro hot reload:

```bash
cd ui
npm ci
npm run dev
```

For integration work, use `mise run dev`. It builds the canonical image and
serves the embedded UI at `http://localhost:13143` by default. The UI package
has build and Astro validation scripts but no browser test suite.
