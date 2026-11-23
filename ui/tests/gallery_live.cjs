// Opt-in real-gallery proof: local built application, unmodified live GET data, isolated browser clipboard.
const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const https = require('node:https');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');

const dist = path.resolve(__dirname, '..', 'dist');
const upstream = 'https://ss.delo.sh';
const contentTypes = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };

function liveGet(requestPath) {
  return new Promise((resolve, reject) => {
    const request = https.get(`${upstream}${requestPath}`, { headers: { Accept: 'application/json' }, timeout: 12000 }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('Live gallery API timeout')));
    request.on('error', reject);
  });
}

async function run() {
  assert.equal(process.env.PUBLIC_API_URL || '', '', 'Use the default same-origin candidate build');
  const html = await fs.readFile(path.join(dist, 'index.html'));
  const buildHash = crypto.createHash('sha256').update(html).digest('hex');
  const proxyReads = [];
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1');
      if (req.method !== 'GET') { res.writeHead(405).end(); return; }
      if (url.pathname === '/api/screenshots') {
        const response = await liveGet(url.pathname + url.search);
        proxyReads.push({ path: url.pathname + url.search, status: response.status, sha256: crypto.createHash('sha256').update(response.body).digest('hex'), date: response.headers.date || null });
        res.writeHead(response.status, { 'Content-Type': response.headers['content-type'] || 'application/json', 'Cache-Control': 'no-store' }).end(response.body);
        return;
      }
      const requestedPath = url.pathname === '/' ? '/index.html' : url.pathname;
      const localPath = path.resolve(dist, '.' + requestedPath);
      if (!localPath.startsWith(dist + path.sep)) { res.writeHead(403).end(); return; }
      const file = await fs.readFile(localPath);
      res.writeHead(200, { 'Content-Type': contentTypes[path.extname(localPath)] || 'application/octet-stream' }).end(file);
    } catch (error) {
      res.writeHead(error.code === 'ENOENT' ? 404 : 502).end('Local preview or upstream read failed');
    }
  });
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  let browser;
  let page;
  let priorClipboard;
  let restored = false;
  let failure;
  let result;
  try {
    const env = { ...process.env };
    for (const key of ['DISPLAY', 'WAYLAND_DISPLAY', 'XAUTHORITY', 'XDG_RUNTIME_DIR']) delete env[key];
    browser = await chromium.launch({
      ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}),
      headless: true,
      env,
      args: ['--ozone-platform=headless'],
    });
    const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
    page = await context.newPage();
    const base = `http://127.0.0.1:${server.address().port}`;
    const [response] = await Promise.all([
      page.waitForResponse(response => response.url().startsWith(`${base}/api/screenshots?`)),
      page.goto(base),
    ]);
    assert.equal(response.status(), 200, 'Live gallery API must succeed');
    const data = await response.json();
    assert.ok(data.total >= 2 && Array.isArray(data.screenshots), 'Live gallery must have at least two records');
    const shots = data.screenshots.filter((shot, index, shots) =>
      shot.filename && /^https:\/\/ss\.delo\.sh\/[^\s]+$/.test(shot.url) && shots.findIndex(other => other.url === shot.url) === index);
    assert.ok(shots.length >= 2, 'Need two distinct absolute hosted URLs in real gallery response');
    const [first, second] = shots;
    assert.notEqual(first.filename, second.filename, 'Selectable filenames must differ');
    const firstBox = page.getByRole('checkbox', { name: `Select ${first.filename}`, exact: true });
    const secondBox = page.getByRole('checkbox', { name: `Select ${second.filename}`, exact: true });
    await firstBox.waitFor();
    await secondBox.waitFor();
    assert.equal(await page.getByRole('link', { name: `Open ${first.filename}`, exact: true }).getAttribute('href'), first.url);
    assert.equal(await page.getByRole('link', { name: `Open ${second.filename}`, exact: true }).getAttribute('href'), second.url);
    // Save the actual browser clipboard before any write. Never print its private contents.
    priorClipboard = await page.evaluate(() => navigator.clipboard.readText());
    assert.equal(typeof priorClipboard, 'string');
    const readClipboard = () => page.evaluate(() => navigator.clipboard.readText());
    const copy = page.getByRole('button', { name: /Copy links|Copying/ });
    assert.equal(await copy.isDisabled(), true);
    await secondBox.check();
    await firstBox.check();
    await copy.click();
    await page.getByRole('status').getByText('Copied 2 links.').waitFor();
    assert.equal(await readClipboard(), `${first.url}\n${second.url}`, 'Real multi-copy must preserve display order');
    await secondBox.uncheck();
    await copy.click();
    await page.getByRole('status').getByText('Copied 1 link.').waitFor();
    assert.equal(await readClipboard(), first.url, 'Real single-copy must match hosted URL');
    await firstBox.uncheck();
    assert.equal(await copy.isDisabled(), true);
    assert.equal(await readClipboard(), first.url, 'Deselecting last must preserve clipboard');
    assert.equal(proxyReads.length, 1, 'Application must load exactly one live API response');
    assert.equal(proxyReads[0].path, '/api/screenshots?limit=48&offset=0');
    assert.equal(proxyReads[0].status, 200);
    result = {
      outcome: 'PASS', target: 'fresh headless Chromium context; isolated clipboard; no DISPLAY/WAYLAND/XAUTHORITY/XDG_RUNTIME_DIR; 127.0.0.1 candidate dist with read-only live GET proxy',
      buildIndexSha256: buildHash, upstream, liveApi: proxyReads[0], total: data.total,
      selectedInClickOrder: [second.url, first.url], multiReadbackInDisplayOrder: [first.url, second.url],
      singleReadback: first.url, zeroSelectionDisabledAndPreserved: true,
    };
  } catch (error) { failure = error; }
  finally {
    if (priorClipboard !== undefined && page && !page.isClosed()) {
      try {
        await page.evaluate(text => navigator.clipboard.writeText(text), priorClipboard);
        assert.equal(await page.evaluate(() => navigator.clipboard.readText()), priorClipboard, 'Prior browser clipboard restoration failed');
        restored = true;
      } catch (error) {
        failure = failure ? new AggregateError([failure, error], 'AC8 and browser clipboard restoration failed') : error;
      }
    }
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
  if (failure) throw failure;
  assert.ok(restored, 'Must have read and restored prior browser clipboard');
  result.priorBrowserClipboardRestoredAndReadBack = restored;
  if (process.env.RECEIPT_PATH) await fs.writeFile(process.env.RECEIPT_PATH, JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify(result));
}

run().catch(error => { console.error(error); process.exitCode = 1; });
