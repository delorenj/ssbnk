# Component Inventory — UI

Single-page Astro app; the React island `ScreenshotGallery` is the entire functional surface. shadcn primitives are built on `@base-ui/react` (not Radix), style `base-nova`, neutral base color.

## Application components

| Component | File | Category | Purpose |
|---|---|---|---|
| ScreenshotGallery | `ui/src/components/ScreenshotGallery.tsx` | Display | The app: fetches `/api/screenshots?limit=48&offset=N`, renders lazy-loaded thumbnail grid or list, offset pagination (Previous/Next), byte-size + date formatting, item count header, loading state. Links each item to its asset URL. No error UI. |
| Layout | `ui/src/layouts/Layout.astro` | Layout | HTML shell: imports `global.css`, forces `class="dark"`, title "ssbnk", favicon |
| index page | `ui/src/pages/index.astro` | Page | Mounts `<ScreenshotGallery client:load />` |
| Welcome | `ui/src/components/Welcome.astro` | — | **Unused** Astro starter leftover |

## shadcn/ui primitives (`ui/src/components/ui/`)

| Component | Used? | Notes |
|---|---|---|
| ToggleGroup / ToggleGroupItem | ✅ (gallery view switcher) | Context shares variant/size/spacing/orientation |
| Toggle | ✅ (via ToggleGroup) | `toggleVariants` cva |
| Button | ❌ | Full cva variant set (default/outline/secondary/ghost/destructive/link; sizes xs→icon-lg); gallery uses raw `<button>` instead |
| Card (Header/Title/Description/Action/Content/Footer) | ❌ | Scaffold |

## Utilities

| File | Purpose |
|---|---|
| `ui/src/lib/utils.ts` | `cn()` = clsx + tailwind-merge |

## Design system elements

- Tailwind 4 CSS-first config (`src/styles/global.css`): `@import "tailwindcss"` + `tw-animate-css` + `shadcn/tailwind.css`
- shadcn neutral theme as oklch CSS variables (`:root`, `.dark`), `@theme inline` token mapping, `@custom-variant dark`
- Geist Variable font via `@fontsource-variable/geist`
- Dark mode forced on; no theme switcher
- Icons: inline SVGs in the gallery; `lucide-react` available per shadcn config
