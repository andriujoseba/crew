/* fleet-floor/test/transition.js — a box CHANGES STATE while its console is open.
 *
 *   node transition.js <url> <user> <pass>
 *
 * Every other page test enters a console, reads it, and leaves within a single
 * poll — so the console has only ever been tested as a snapshot. The thing an
 * operator actually does is stand in one and watch, which means the live-update
 * path (applyFleet -> populateDash while VIEW==="room") is the least-tested
 * code in the page and the place the pinned-focus logic now lives.
 *
 * The specific failure this looks for: a box goes down under an open console
 * and the console keeps its running-session timer, its queue and its green
 * vitals. That is the phantom-box bug's sibling — the box still exists, but
 * what is on screen stopped being true about it.
 */
const { chromium } = require('playwright-core');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , url, USER, PASS] = process.argv;

let failed = 0;
const ok = (name, cond, detail = '') => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${!cond && detail ? '  — ' + String(detail).slice(0, 170) : ''}`);
  if (!cond) failed++;
};

(async () => {
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    httpCredentials: { username: USER, password: PASS },
  });
  const page = await ctx.newPage();
  page.on('dialog', (d) => d.accept());
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));

  await page.goto(url, { waitUntil: 'load' });
  await page.waitForTimeout(3500);
  ok('transition: page starts LIVE', (await page.locator('.demo-badge.live').count()) > 0);

  // Find a box the collector currently calls "working" — it will have an open
  // session, so there is a running timer to go stale.
  const target = await page.evaluate(async () => {
    const r = await fetch(location.origin + '/api/fleet');
    const u = (await r.json()).units.filter((x) => x.state === 'working');
    return u.length ? u[0].box : null;
  });
  ok('transition: found a working box to watch', !!target, target || 'none working');
  if (!target) { await browser.close(); process.exit(failed ? 1 : 0); }

  // Walk the floor to that box's console.
  const geom = await page.evaluate(() => ({
    topY: Math.max(70, 64 + ((window.innerHeight - 222) - (2 * 252 + 26)) / 2),
    vw: window.innerWidth,
  }));
  const roster = await page.evaluate(async () => {
    const r = await fetch(location.origin + '/api/fleet');
    return (await r.json()).units.map((u) => u.box);
  });
  /* Scroll to the target rather than assuming it is on screen. Which box is
     "working" depends on what ran before this test, so a fixed assumption here
     makes the test fail for reasons that have nothing to do with the page —
     it did exactly that once, on cell 8 at x=1668. */
  const idx = roster.indexOf(target);
  const cols = Math.ceil(roster.length / 2);
  const totalW = 44 * 2 + cols * 336 + (cols - 1) * 28;
  const camMax = Math.max(0, totalW - geom.vw);
  const col = Math.floor(idx / 2), row = idx % 2;
  const xAt = (cam) => 44 - cam + col * (336 + 28) + 168;
  let cam = 0;
  if (xAt(0) > geom.vw - 10) {
    await page.mouse.move(geom.vw / 2, geom.topY + 40);
    await page.mouse.wheel(totalW + 2000, 0);       // pin the camera to the far end
    await page.waitForTimeout(1200);
    cam = camMax;
  }
  const x = xAt(cam), y = geom.topY + row * (252 + 26) + 126;
  ok('transition: target cell is reachable', x > 10 && x < geom.vw - 10,
     `cell ${idx} at x=${x} with cam=${cam}`);
  await page.mouse.click(x, y);
  await page.waitForTimeout(900);

  const before = await page.evaluate(() => ({
    box: document.getElementById('c-target').textContent.replace('▸ MESSAGE ', '').trim(),
    state: document.getElementById('modelabel').textContent.trim(),
    current: document.getElementById('w-current').textContent.replace(/\s+/g, ' '),
    pause: document.getElementById('a-pause').textContent.trim(),
    hasTimer: !!document.getElementById('cur-el'),
  }));
  ok('transition: console is open on the working box', before.box === target, `${before.box} vs ${target}`);
  ok('transition: it shows a running session', before.hasTimer && before.state === 'WORKING',
     `state=${before.state} timer=${before.hasTimer}`);

  // Take the box down THROUGH THE APP, which is how an operator would, and
  // then just keep standing there.
  await page.evaluate(async (name) => {
    await fetch(location.origin + '/api/command', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'power-off', box: name }),
    });
  }, target);
  console.log(`  (powered off ${target}; staying in its console)`);

  // Wait for the page to poll and re-render the room it is standing in.
  let updated = false;
  for (let i = 0; i < 24; i++) {
    await page.waitForTimeout(2500);
    const st = await page.evaluate(() =>
      document.getElementById('modelabel').textContent.trim());
    if (st !== 'WORKING') { updated = true; break; }
  }
  ok('transition: the open console notices the box went down', updated,
     'still WORKING after 60s');

  const after = await page.evaluate(() => ({
    view: document.body.className,
    box: document.getElementById('c-target').textContent.replace('▸ MESSAGE ', '').trim(),
    state: document.getElementById('modelabel').textContent.trim(),
    current: document.getElementById('w-current').textContent.replace(/\s+/g, ' '),
    vitals: document.getElementById('w-vitals').textContent.replace(/\s+/g, ' '),
    pause: document.getElementById('a-pause').textContent.trim(),
    hasTimer: !!document.getElementById('cur-el'),
  }));

  ok('transition: stays on the same box', after.box === target, `${after.box} vs ${target}`);
  // The running-session timer must be GONE: a counter still ticking up for a
  // box that is off is the most convincing wrong thing the console can show.
  ok('transition: the running-session timer is gone', !after.hasTimer, after.current);
  ok('transition: it says SILENT', /SILENT/i.test(after.current + ' ' + after.state),
     `state=${after.state} current=${after.current}`);
  ok('transition: it says WHY', /stopped|unreachable|crew up|paused|cron/i.test(after.current + ' ' + after.vitals),
     after.current);
  // Pause is meaningless on a box that is off; the control must flip with it.
  ok('transition: the Pause control flips to Resume', /Resume/.test(after.pause), after.pause);
  ok('transition: no page errors during the transition', pageErrors.length === 0,
     pageErrors.slice(0, 2).join(' | '));

  await page.screenshot({ path: (process.env.SHOT_DIR || '/tmp') + '/transition-after.png' });

  // Put it back, so a re-run starts from the same fleet.
  await page.evaluate(async (name) => {
    await fetch(location.origin + '/api/command', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'power-on', box: name }),
    });
  }, target);

  await browser.close();
  console.log(`  -- transition: ${failed ? failed + ' failed' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('TRANSITION HARNESS ERROR:', e.message); process.exit(2); });
