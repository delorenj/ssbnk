# SSBNK-6 copy-race candidate evidence

## Identity and scope

- Verified UI identity: `git -C ui rev-parse --show-toplevel` resolves to this worktree's repository root. The UI files are tracked in the top-level repository; the older `AGENTS.md` statement that `ui/` is a nested repository is stale.
- Branch: `ssbnk-6-copy-race-regression`, isolated from the dirty main checkout. Base: `9446b5ef7180e7dc7492e3fded544afb8d8e95f1`. Resolve the final candidate with `git rev-parse HEAD` in this worktree; this note is committed with the candidate.
- Changed scope: `ui/tests/gallery.cjs`, `ui/tests/gallery_live.cjs`, `ui/tests/README.md`, and this evidence note. `ui/src/components/ScreenshotGallery.tsx` is unchanged.

## Guard audit

The existing `copyInFlight` ref is set synchronously before issuing `navigator.clipboard.writeText` and is cleared in `finally` after the write settles. `copySelection` refuses a second write while it is set. Both `toggleSelection` and `changePage` return while it is set; `changePage` calls `clearSelection`, which also refuses while copying. Selection inputs, paging buttons, and Copy are disabled while copying. The generation check prevents stale feedback, but the ref/disabled guards are what keep selection and paging from changing while an issued write remains pending. Success reports the link count; rejection preserves selection, unlocks controls, and offers permission/retry guidance. This behavior was already present at the base revision, so no production-source repair was justified.

## Local regression (fixture, not the real application)

From `ui/` in this isolated worktree: `npm ci --no-audit --no-fund`, `npm run build`, then `NODE_PATH="$TMPDIR/ssbnk-6-browser-deps/node_modules" CHROME_EXECUTABLE="$HOME/.local/bin/google-chrome" node tests/gallery.cjs` with Playwright 1.65.1 installed into `$TMPDIR/ssbnk-6-browser-deps`. Node 26.5.0; Python 3.14.9. Build exit 0, one static page; Astro/Vite deprecation warnings. Browser regression exit 0:

```
PASS: real clipboard ordered/deduplicated multi/single/zero; keyboard, links, views, paging, reload, empty; delayed write locks selection/paging through success and rejection; denied/unavailable retry
```

The runner serves the built UI over loopback with 49 synthetic SVG screenshot records (one duplicate URL). It reads back the *isolated headless browser's actual clipboard* for ordered/deduplicated multi-copy, single-copy, no-selection preservation, and delayed success. It tests grid/list keyboard toggling, selection across view switches, asset navigation, paging/reload selection clearing, pending-write attempted deselection/paging by directly dispatched events including keyboard, a pending second Copy, rejection without clipboard mutation, unlock/retry, denied/unavailable clipboard and an empty gallery. Delayed timing, rejection, unavailable clipboard, and empty API are injected; normal success and delayed-success release use real `navigator.clipboard.writeText` plus `readText`. These are local fixture assertions, not real hosted-gallery or desktop clipboard evidence.

## Real application / live gallery AC8 proof (2026-11-22 EST; final live HTTP Date 2026-11-23 03:25:36 GMT)

From `ui/` in this worktree, with the default same-origin `PUBLIC_API_URL` (unset), run `npm run build`; then run `NODE_PATH=/home/delorenj/.hermes/profiles/ssbnk-pm/cache/scratch/ssbnk-6-browser-deps/node_modules CHROME_EXECUTABLE=/home/delorenj/.local/bin/google-chrome RECEIPT_PATH=/home/delorenj/.hermes/profiles/ssbnk-pm/cache/scratch/ssbnk-6-final-live-receipt-v2.json node tests/gallery_live.cjs` (use a fresh receipt filename on rerun). The runner serves the exact built candidate `ui/dist/` on an ephemeral 127.0.0.1 port and read-only proxies only `/api/screenshots?limit=48&offset=0` by unmodified HTTPS GET from `https://ss.delo.sh`. No API fixture, intercepted browser request, rewritten response, or mocked clipboard API is involved. This is **local application preview using live gallery data**, not a production deployment or proof that the older production index runs this candidate.

Target was a fresh isolated headless Chromium context. The launch environment strips `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, and `XDG_RUNTIME_DIR` and uses headless Ozone, not the host desktop clipboard/focus. The runner first reads and retains actual browser clipboard text privately (never logs it); in `finally` it restores that exact text via actual `navigator.clipboard.writeText` and confirms with actual `readText`. Its receipt records `priorBrowserClipboardRestoredAndReadBack: true`. Browser permissions are enabled; there is no monkeypatch or mocked readback. Only this browser clipboard was touched.

Live API returned 200, 245 total, response SHA-256 `42621a6cdfb82827fb8870d88ce910c90132130011108c3203c31b9b7d3c23c1`; built `dist/index.html` SHA-256 `3d1a9879aaaf4d872dda6661710be97d4d1c4fc89f419f4294bbee706c9fe441`. Clicked second then first checkbox; actual Copy multi readback was, in display order:

```
https://ss.delo.sh/20261122-2303.png
https://ss.delo.sh/20261122-0128-1.png
```

After deselecting the second, actual single Copy readback was `https://ss.delo.sh/20261122-2303.png`. Deselecting the last disabled Copy and preserved that browser clipboard text. Restoration then read back the original browser text exactly. The same final build passed `npm run build` (one page; Astro/Vite deprecation warnings), documented fixture `node tests/gallery.cjs`, and the live runner, all exit 0. Logs: `/home/delorenj/.hermes/profiles/ssbnk-pm/cache/scratch/ssbnk-6-final-build.log`, `/home/delorenj/.hermes/profiles/ssbnk-pm/cache/scratch/ssbnk-6-final-fixture.log`, `/home/delorenj/.hermes/profiles/ssbnk-pm/cache/scratch/ssbnk-6-final-live-v2.log`; structured receipt: `/home/delorenj/.hermes/profiles/ssbnk-pm/cache/scratch/ssbnk-6-final-live-receipt-v2.json`.

AC8 browser/real-gallery proof is satisfied for this local candidate, not the host desktop or deployed service. Independent spec and quality review of the final committed candidate remain for the parent before publication; no deploy, restart, push, merge, or ticket closure was performed.
