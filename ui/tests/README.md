# Gallery browser regression

Run from `ui/` with Node >=22.12, Python 3, and a headless Chrome/Chromium browser:

```sh
npm ci
npm run build
npm install --prefix "$HOME/.cache/ssbnk-browser-deps" --no-save --package-lock=false playwright@1.65.1
# Use an installed Chrome/Chromium, or omit this variable after installing Playwright's browser.
NODE_PATH="$HOME/.cache/ssbnk-browser-deps/node_modules" CHROME_EXECUTABLE=/path/to/chrome node tests/gallery.cjs
```

For Playwright's managed browser instead, run `$HOME/.cache/ssbnk-browser-deps/node_modules/.bin/playwright install chromium`, then omit `CHROME_EXECUTABLE`. The script starts a loopback fixture on an available port and stops it and the browser on exit. No watcher, production assets, or live clipboard is touched. Real Chromium clipboard writes and reads are asserted for normal success and delayed-success cases; only delayed timing, permission rejection, clipboard absence, and empty API response are controlled mocks.

## Verified on 2026-11-22 (SSBNK-6 candidate)

From the isolated `ssbnk-6-copy-race-regression` worktree based on `9446b5ef7180e7dc7492e3fded544afb8d8e95f1`, `npm ci --no-audit --no-fund`, `npm run build`, and the documented `NODE_PATH=... CHROME_EXECUTABLE=... node tests/gallery.cjs` command passed in `ui/` (Node 26.5.0, Playwright 1.65.1, installed Google Chrome). The build produced one static page with Astro/Vite deprecation warnings. The regression additionally checks list-view keyboard toggling, direct clicks on disabled selection/Copy controls during delayed success and rejection, no second pending write, and clipboard preservation after rejection. See [ssbnk-6-evidence.md](ssbnk-6-evidence.md) for candidate identity, guard audit, and the separate real-application clipboard-readback gap. This fixture is not a deployed application or desktop proof.

## Verified on 2026-11-18

`npm run build` completed (Astro static build, one page). `NODE_PATH=... CHROME_EXECUTABLE=... node tests/gallery.cjs` returned:

```
PASS: real clipboard ordered/deduplicated multi/single/zero; keyboard, links, views, paging, reload, empty; delayed write locks selection/paging through success and rejection; denied/unavailable retry
```

The deferred write preserves selected controls and disables checkboxes/paging before settlement; direct dispatched change/click events also cannot alter selection/page. After real clipboard write resolves, controls unlock and success appears; rejection preserves selection and unlocks for retry. Existing Astro/Vite deprecation warnings did not fail the build.
