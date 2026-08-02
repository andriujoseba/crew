/* fleet-floor/test/stopped.js — a fleet nobody armed must raise no alarm.
 *
 *   node stopped.js <url> <user> <pass>
 *
 * The collector's own log for a disarmed fleet reads `polled 3 units (0 silent,
 * 3 paused/disarmed)`. The page showed SILENT for all three, in alert colour,
 * with the counter tile pulsing (#203). Every OTHER assertion about that split
 * can ride the main walk, because the fixture fleet has one disarmed box among
 * seventeen — but this one cannot: "the alarm counter reads zero" is a claim
 * about a fleet with nothing to alarm about, and the fixture fleet is full of
 * genuinely broken boxes on purpose.
 *
 * So it gets its own roster of two: one disarmed, one paused. Its collector is
 * the fast-polling one test/run.sh already stands up for the churn and
 * transition tests, whose roster file is a scratch copy the tests are allowed
 * to rewrite — a fourth collector for two boxes would cost CI a minute to
 * assert what this asserts in seconds.
 *
 * The stage counts are CANVAS text and unreachable from the DOM, which is a
 * large part of why this regression lived: nothing could read them. They come
 * back through FLOORDEV.stages(), the same dev hook the walk already uses for
 * the floor camera, returning exactly the array drawFloorHeader paints.
 */
const { chromium } = require('playwright-core');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , url, USER, PASS] = process.argv;

let failed = 0;
const ok = (name, cond, detail = '') => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${!cond && detail ? '  — ' + String(detail).slice(0, 160) : ''}`);
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
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));
  await page.goto(url, { waitUntil: 'load' });

  /* Wait for the page to go LIVE on the two-box roster rather than sleeping a
     fixed interval: run.sh has already waited for the collector to report two
     units, but the page's own first poll can still be a second away, and DEMO's
     static roster would satisfy every count below for the wrong reason. */
  let live = false;
  for (let i = 0; i < 24; i++) {
    await page.waitForTimeout(1000);
    live = await page.evaluate(async () => {
      const n = document.querySelectorAll('#tiles .tile').length;
      const u = document.querySelector('#tiles .tile .n');
      return n > 0 && u && u.textContent.trim() === '2';
    });
    if (live) break;
  }
  ok('stopped: the page is live on the two-box roster', live,
     'tiles=' + (await page.locator('#tiles').textContent()).replace(/\s+/g, ' '));

  /* The API is read ONCE, and only to prove the fixture is the fixture: if the
     collector is not actually reporting a disarmed box and a paused one, every
     assertion below would pass against a fleet that never tested anything. It
     is not consulted for a single rendering claim — that is the whole point of
     this file. */
  const api = await page.evaluate(async () => {
    const r = await fetch(location.origin + '/api/fleet');
    return (await r.json()).units.map((u) => ({ box: u.box, paused: !!u.paused, disarmed: !!u.disarmed }));
  });
  ok('stopped: the roster really is two deliberately-stopped boxes',
     api.length === 2 && api.every((u) => u.disarmed) && api.some((u) => u.paused)
       && api.some((u) => !u.paused),
     JSON.stringify(api));

  const tiles = await page.evaluate(() =>
    [].map.call(document.querySelectorAll('#tiles .tile'), (t) => ({
      label: t.querySelector('.l').textContent.trim(),
      n: t.querySelector('.n').textContent.trim(),
      alert: t.classList.contains('alert'),
    })));
  const silent = tiles.find((t) => t.label === 'silent');
  const dis = tiles.find((t) => t.label === 'disarmed');
  ok('stopped: the HUD carries a silent tile and a disarmed one', !!silent && !!dis,
     JSON.stringify(tiles));
  if (silent) {
    ok('stopped: the alert-coloured counter reads 0', silent.n === '0', JSON.stringify(tiles));
    /* tl()'s fourth argument. The pulsing red border is the fleet's one
       "look at this now" mark; a fleet the operator disarmed must not be able
       to raise it, which is #189's whole argument about what the alarm costs. */
    ok('stopped: the silent tile does not pulse', silent.alert === false, JSON.stringify(tiles));
  }
  if (dis) {
    ok('stopped: both boxes are counted as disarmed', dis.n === '2', JSON.stringify(tiles));
    ok('stopped: the disarmed tile never pulses', dis.alert === false, JSON.stringify(tiles));
  }

  const stages = await page.evaluate(() => window.FLOORDEV.stages().map((s) => s[0]));
  ok('stopped: the stage counts read 0 SILENT', stages.includes('0 SILENT'), stages.join(' · '));
  ok('stopped: the stage counts name the two disarmed boxes',
     stages.includes('2 DISARMED'), stages.join(' · '));
  /* The alarm survives, from the other side: nothing here should be alerting,
     so the ALERT counter must not have been prepended at all. */
  ok('stopped: no ALERT counter on a fleet with nothing wrong',
     !stages.some((s) => /ALERT/.test(s)), stages.join(' · '));

  ok('stopped: no page errors', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));

  await browser.close();
  console.log(`  -- stopped: ${failed ? failed + ' failed' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('STOPPED HARNESS ERROR:', e.message); process.exit(2); });
