/* fleet-floor/test/stale.js — kill the collector under a live page and assert
 * the page admits it.
 *
 *   node stale.js <url> <collector-pid> <user> <pass>
 *
 * A console that keeps rendering the last snapshot after its collector dies is
 * the most dangerous state this app can be in: a frozen fleet is
 * indistinguishable from a calm one, and every box on screen looks fine while
 * nobody is watching any of them. This is the page-level twin of the engine's
 * "silence = dead" rule, so it gets its own test rather than riding along in
 * the main walk (which must not have its collector shot halfway through).
 */
const { chromium } = require('playwright-core');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , url, pidArg, USER, PASS] = process.argv;
const pid = parseInt(pidArg, 10);

let failed = 0;
const ok = (name, cond, detail = '') => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${!cond && detail ? '  — ' + String(detail).slice(0, 140) : ''}`);
  if (!cond) failed++;
};

(async () => {
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1400, height: 900 },
    httpCredentials: { username: USER, password: PASS },
  });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'load' });
  await page.waitForTimeout(3500);

  ok('stale: page starts LIVE', (await page.locator('.demo-badge.live').count()) > 0,
     (await page.locator('.demo-badge').first().textContent()).trim());

  process.kill(pid, 'SIGKILL');
  console.log('  (collector killed; waiting for the page to notice)');

  // POLL_MS is 15s and STALE_AFTER is 2 missed polls, so the page must give up
  // within ~30s. Poll for the badge rather than sleeping a fixed 40s.
  let sawStale = false;
  for (let i = 0; i < 24; i++) {
    await page.waitForTimeout(2500);
    if ((await page.locator('.demo-badge.stale').count()) > 0) { sawStale = true; break; }
  }
  ok('stale: page marks itself STALE after the collector dies', sawStale,
     'badge=' + (await page.locator('.demo-badge').first().textContent()).trim());
  if (sawStale) {
    const status = (await page.locator('#livestat').textContent()).trim();
    ok('stale: says the collector is unreachable', /collector unreachable/i.test(status), status);
    ok('stale: names the snapshot it is frozen at', /\d{4}-\d{2}-\d{2}T/.test(status), status);
  }

  await browser.close();
  console.log(`  -- stale: ${failed ? failed + ' failed' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('STALE HARNESS ERROR:', e.message); process.exit(2); });
