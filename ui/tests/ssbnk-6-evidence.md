# SSBNK-6 copy-race candidate evidence

## Identity and scope

- Verified UI identity: `git -C ui rev-parse --show-toplevel` resolves to this worktree's repository root. The UI files are tracked in the top-level repository; the older `AGENTS.md` statement that `ui/` is a nested repository is stale.
- Branch: `ssbnk-6-copy-race-regression`, isolated from the dirty main checkout. Base: `9446b5ef7180e7dc7492e3fded544afb8d8e95f1`. Resolve the final candidate with `git rev-parse HEAD` in this worktree; this note is committed with the candidate.
- Changed scope: `ui/tests/gallery.cjs`, `ui/tests/README.md`, and this evidence note. `ui/src/components/ScreenshotGallery.tsx` is unchanged.

## Guard audit

The existing `copyInFlight` ref is set synchronously before issuing `navigator.clipboard.writeText` and is cleared in `finally` after the write settles. `copySelection` refuses a second write while it is set. Both `toggleSelection` and `changePage` return while it is set; `changePage` calls `clearSelection`, which also refuses while copying. Selection inputs, paging buttons, and Copy are disabled while copying. The generation check prevents stale feedback, but the ref/disabled guards are what keep selection and paging from changing while an issued write remains pending. Success reports the link count; rejection preserves selection, unlocks controls, and offers permission/retry guidance. This behavior was already present at the base revision, so no production-source repair was justified.

## Local regression (fixture, not the real application)

From `ui/` in this isolated worktree: `npm ci --no-audit --no-fund`, `npm run build`, then `NODE_PATH="$TMPDIR/ssbnk-6-browser-deps/node_modules" CHROME_EXECUTABLE="$HOME/.local/bin/google-chrome" node tests/gallery.cjs` with Playwright 1.65.1 installed into `$TMPDIR/ssbnk-6-browser-deps`. Node 26.5.0; Python 3.14.9. Build exit 0, one static page; Astro/Vite deprecation warnings. Browser regression exit 0:

```
PASS: real clipboard ordered/deduplicated multi/single/zero; keyboard, links, views, paging, reload, empty; delayed write locks selection/paging through success and rejection; denied/unavailable retry
```

The runner serves the built UI over loopback with 49 synthetic SVG screenshot records (one duplicate URL). It reads back the *isolated headless browser's actual clipboard* for ordered/deduplicated multi-copy, single-copy, no-selection preservation, and delayed success. It tests grid/list keyboard toggling, selection across view switches, asset navigation, paging/reload selection clearing, pending-write attempted deselection/paging by directly dispatched events including keyboard, a pending second Copy, rejection without clipboard mutation, unlock/retry, denied/unavailable clipboard and an empty gallery. Delayed timing, rejection, unavailable clipboard, and empty API are injected; normal success and delayed-success release use real `navigator.clipboard.writeText` plus `readText`. These are local fixture assertions, not real hosted-gallery or desktop clipboard evidence.

## Outstanding acceptance proof

No deployed build, live watcher restart, real-gallery selection, or host clipboard/focus operation was performed. AC8 still requires a safely coordinated window to load the exact post-repair candidate against real hosted gallery data, perform both single- and multi-select Copy using the actual browser/desktop clipboard, read back absolute hosted URLs in display order, verify deselection preserves the clipboard, and restore its prior contents. A fixture/mock pass does **not** waive that requirement. Independent spec and quality review of this exact candidate remain for the parent before publication; do not close the ticket based on this note.
