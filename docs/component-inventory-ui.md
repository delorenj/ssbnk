# UI component inventory

The Astro application has one React island. `ScreenshotGallery` is the entire
functional surface, and a small shadcn layer provides its view switcher.

## Application components

The current application uses these components:

| Component | File | Purpose |
| --- | --- | --- |
| `ScreenshotGallery` | `ui/src/components/ScreenshotGallery.tsx` | Fetch metadata, render grid or list views, paginate, and link to hosted assets |
| `Layout` | `ui/src/layouts/Layout.astro` | Provide the HTML shell, global styles, title, and dark theme |
| Index page | `ui/src/pages/index.astro` | Mount `ScreenshotGallery` with `client:load` |
| `Welcome` | `ui/src/components/Welcome.astro` | Unused Astro starter component |

The gallery requests the same-origin `/api/screenshots` endpoint by default,
shows 48 items per page, lazy-loads thumbnails, and formats byte sizes and
timestamps. Fetch failures currently log to the console and don't render a
dedicated error state.

## shadcn components

The `ui/src/components/ui/` directory contains these primitives:

| Component | Used | Purpose |
| --- | ---: | --- |
| `ToggleGroup` and `ToggleGroupItem` | Yes | Select grid or list view |
| `Toggle` | Yes | Implement toggle-group items through `@base-ui/react` |
| `Button` | No | Retained shadcn scaffold |
| `Card` family | No | Retained shadcn scaffold |

## Design system

The interface uses Tailwind CSS 4, the shadcn `base-nova` style, neutral OKLCH
tokens, Geist Variable, and `@base-ui/react` primitives. Dark mode is currently
fixed on; there is no theme switcher.
