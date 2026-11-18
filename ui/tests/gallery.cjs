const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const net = require('node:net');

const ui = path.resolve(__dirname, '..');
const boxName = n => `Select shot-${String(n).padStart(2, '0')}.svg`;

async function availablePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

async function run() {
  const port = await availablePort();
  const base = `http://127.0.0.1:${port}`;
  const fixture = spawn('python3', [path.join(__dirname, 'gallery_fixture.py'), path.join(ui, 'dist'), String(port)], { stdio: 'ignore' });
  let browser;
  try {
    browser = await chromium.launch({
      ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}),
      headless: true,
    });
    const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await context.newPage();
    const box = n => page.getByRole('checkbox', { name: boxName(n) });
    const copy = page.getByRole('button', { name: /Copy links|Copying/ });
    const clipboard = () => page.evaluate(() => navigator.clipboard.readText());
    await page.goto(base);
    await box(0).waitFor();
    assert.equal(await copy.isDisabled(), true);
    await box(0).focus();
    await page.keyboard.press('Space');
    assert.equal(await box(0).isChecked(), true);
    await page.keyboard.press('Space');
    assert.equal(await box(0).isChecked(), false);
    await page.evaluate(() => navigator.clipboard.writeText('sentinel'));
    await box(1).check();
    await box(0).check();
    await box(2).check();
    await box(1).uncheck();
    assert.equal(page.url(), `${base}/`);
    await page.getByRole('button', { name: 'List view' }).click();
    assert.equal(await box(0).isChecked(), true);
    const link = page.getByRole('link', { name: 'Open shot-00.svg' });
    assert.equal(await link.getAttribute('href'), '/shot-00.svg');
    const [asset] = await Promise.all([page.waitForEvent('popup'), link.click()]);
    await asset.waitForLoadState();
    assert.equal(new URL(asset.url()).pathname, '/shot-00.svg');
    await asset.close();
    assert.equal(await box(0).isChecked(), true);
    await box(3).check();
    await copy.click();
    await page.getByRole('status').getByText('Copied 2 links.').waitFor();
    assert.equal(await clipboard(), `${base}/shot-00.svg\n${base}/shot-03.svg`);
    await box(0).uncheck();
    await box(2).uncheck();
    await copy.click();
    await page.getByRole('status').getByText('Copied 1 link.').waitFor();
    assert.equal(await clipboard(), `${base}/shot-03.svg`);
    await box(3).uncheck();
    assert.equal(await copy.isDisabled(), true);
    assert.equal(await clipboard(), `${base}/shot-03.svg`);
    await page.getByRole('button', { name: 'Grid view' }).click();
    await box(4).check();
    await page.getByRole('button', { name: 'Next' }).click();
    await box(48).waitFor();
    assert.equal(await copy.isDisabled(), true);
    await box(48).check();
    await page.getByRole('button', { name: 'Previous' }).click();
    await box(4).waitFor();
    assert.equal(await box(4).isChecked(), false);
    await box(0).check();
    await page.reload();
    await box(0).waitFor();
    assert.equal(await box(0).isChecked(), false);

    // Only the deferred call is mocked: its release performs a real browser clipboard write.
    await page.evaluate(() => {
      const realWrite = navigator.clipboard.writeText.bind(navigator.clipboard);
      window.pendingCopies = [];
      Object.defineProperty(navigator, 'clipboard', {
        configurable: true,
        value: { writeText(text) {
          return new Promise((resolve, reject) => {
            window.pendingCopies.push({ text, release: () => realWrite(text).then(resolve, reject), reject });
          });
        } },
      });
    });
    await box(0).check();
    await copy.click();
    assert.equal(await page.evaluate(() => window.pendingCopies.length), 1);
    assert.equal(await page.getByRole('status').innerText(), '1 selected');
    assert.equal(await box(0).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Next' }).isDisabled(), true);
    assert.equal(await copy.isDisabled(), true);
    await page.getByRole('button', { name: 'List view' }).click();
    assert.equal(await box(0).isDisabled(), true);
    await box(0).dispatchEvent('change');
    await page.getByRole('button', { name: 'Next' }).dispatchEvent('click');
    assert.equal(await box(0).isChecked(), true);
    assert.equal(await page.getByText('1–48 of 49').count(), 1);
    await page.evaluate(() => window.pendingCopies.shift().release());
    await page.getByRole('status').getByText('Copied 1 link.').waitFor();
    await page.evaluate(() => { delete navigator.clipboard; });
    assert.equal(await clipboard(), `${base}/shot-00.svg`);
    assert.equal(await box(0).isDisabled(), false);
    assert.equal(await page.getByRole('button', { name: 'Next' }).isDisabled(), false);

    await page.evaluate(() => {
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
        writeText: () => new Promise((resolve, reject) => {
          window.rejectPendingCopy = () => reject(new DOMException('Denied', 'NotAllowedError'));
        }),
      } });
    });
    await copy.click();
    assert.equal(await box(0).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Next' }).isDisabled(), true);
    await page.evaluate(() => window.rejectPendingCopy());
    await page.getByRole('status').getByText(/Could not copy links/).waitFor();
    assert.equal(await box(0).isChecked(), true);
    assert.equal(await box(0).isDisabled(), false);
    assert.equal(await page.getByRole('button', { name: 'Next' }).isDisabled(), false);
    await page.evaluate(() => { delete navigator.clipboard; });
    await copy.click();
    await page.getByRole('status').getByText('Copied 1 link.').waitFor();
    assert.equal(await clipboard(), `${base}/shot-00.svg`);
    await page.evaluate(() => Object.defineProperty(navigator, 'clipboard', { configurable: true, value: undefined }));
    await copy.click();
    await page.getByRole('status').getByText(/Could not copy links/).waitFor();
    assert.equal(await box(0).isChecked(), true);
    await page.evaluate(() => { delete navigator.clipboard; });

    const empty = await context.newPage();
    await empty.route('**/api/screenshots?*', route => route.fulfill({ json: { screenshots: [], total: 0, limit: 48, offset: 0 } }));
    await empty.goto(base);
    await empty.getByText('0 screenshots').waitFor();
    assert.equal(await empty.getByRole('button', { name: /Copy links/ }).isDisabled(), true);
    await empty.close();
    console.log('PASS: real clipboard ordered/deduplicated multi/single/zero; keyboard, links, views, paging, reload, empty; delayed write locks selection/paging through success and rejection; denied/unavailable retry');
  } finally {
    if (browser) await browser.close();
    if (fixture.exitCode === null) fixture.kill();
    if (fixture.exitCode === null) await new Promise(resolve => fixture.once('exit', resolve));
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
