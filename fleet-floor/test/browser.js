/* fleet-floor/test/browser.js — drive the real page and assert what it renders.
 *
 *   node browser.js <url> <outdir> [user] [pass]
 *   node browser.js file:///.../index.html shots        # DEMO mode
 *
 * playwright-core against the cached chromium; no browser download. Basic auth
 * goes through httpCredentials, NOT credentials in the URL — Chrome refuses to
 * build a Request from a document URL that carries them, which silently
 * strands the page in DEMO.
 *
 * Everything asserted here is something a screenshot cannot tell you: that a
 * control targeted the box the operator was looking at, that hostile log text
 * stayed text, that a disabled control is disabled. The screenshots are for
 * humans; the assertions are the test.
 */
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , URL_ARG, OUT_ARG, USER, PASS] = process.argv;
const url = URL_ARG || 'http://127.0.0.1:8791/';
const out = OUT_ARG || 'shots';

let pass = 0;
const fails = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fails.push(name); console.log(`  FAIL ${name}${detail ? '  — ' + String(detail).slice(0, 150) : ''}`); }
};
const eq = (name, want, got) => ok(name, String(want) === String(got), `expected [${want}] got [${got}]`);

(async () => {
  if (!fs.existsSync(CHROME)) { console.error('no chromium at ' + CHROME); process.exit(2); }
  fs.mkdirSync(out, { recursive: true });

  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    httpCredentials: USER ? { username: USER, password: PASS } : undefined,
  });
  const page = await ctx.newPage();

  const consoleErrors = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message));
  page.on('dialog', (d) => d.accept());          // confirm() guards

  const shot = (n) => page.screenshot({ path: path.join(out, n + '.png') });

  await page.goto(url, { waitUntil: 'load' });
  await page.waitForTimeout(3500);

  // There are two badges (floor bar + room HUD); goLive() marks both.
  const LIVE = (await page.locator('.demo-badge.live').count()) > 0;
  console.log(`  mode: ${LIVE ? 'LIVE' : 'DEMO'}`);

  // Record every command the page posts, so an assertion can name the box a
  // control actually addressed.
  await page.evaluate(() => {
    window.__sent = [];
    window.__opened = [];
    const _open = window.open;
    window.open = function (u) { window.__opened.push(u); return null; };
    const f = window.fetch;
    window.fetch = function (u, o) {
      if (o && o.method === 'POST') { try { window.__sent.push(JSON.parse(o.body)); } catch (e) {} }
      return f.apply(this, arguments);
    };
  });
  const sent = () => page.evaluate(() => window.__sent);
  const lastSent = async () => (await sent()).slice(-1)[0] || {};

  // ---- floor --------------------------------------------------------------
  /* The expected cell order comes from the collector, not from a test hook in
     the app: /api/fleet is the same list, in the same order, that the page
     laid the floor out from. In DEMO there is no collector, so there is
     nothing to compare against and the identity check is skipped. */
  const roster = LIVE
    ? await page.evaluate(async () => {
        const r = await fetch(location.origin + '/api/fleet');
        return (await r.json()).units.map((u) => ({ box: u.box, agent: u.agent, room: u.room, state: u.state }));
      })
    : Array.from({ length: 7 }, (_, i) => ({ box: null, agent: null, room: null, state: null }));
  ok('floor: roster rendered', roster.length > 0, roster.length + ' units');
  ok('floor: tiles populated', /units/.test(await page.locator('#tiles').textContent()));
  await shot('01-floor');

  // Cell geometry mirrors app.js drawFloor().
  const geom = await page.evaluate(() => ({
    CELLW: 336, CELLH: 252, GAPX: 28, GAPY: 26, MARGINL: 44,
    topY: Math.max(70, 64 + ((window.innerHeight - 222) - (2 * 252 + 26)) / 2),
    vw: window.innerWidth,
  }));
  /* The floor scrolls horizontally, so a viewport-sized walk silently skips the
     tail of any fleet bigger than ~8 boxes — which is where the awkward states
     tend to sit. Walk in two passes, camera pinned at each end, and take the
     union: camMax is computable from the same geometry drawFloor() uses. */
  const cols = Math.ceil(roster.length / 2);
  const totalW = geom.MARGINL * 2 + cols * geom.CELLW + (cols - 1) * geom.GAPX;
  const camMax = Math.max(0, totalW - geom.vw);
  const cellXY = (i, cam) => {
    const col = Math.floor(i / 2), row = i % 2;
    return {
      x: geom.MARGINL - cam + col * (geom.CELLW + geom.GAPX) + geom.CELLW / 2,
      y: geom.topY + row * (geom.CELLH + geom.GAPY) + geom.CELLH / 2,
    };
  };
  const onScreen = (i, cam) => { const { x } = cellXY(i, cam); return x > 10 && x < geom.vw - 10; };
  // The camera eases toward its target, so scrolling needs a settle wait.
  const scrollTo = async (cam) => {
    await page.mouse.move(geom.vw / 2, geom.topY + 40);
    await page.mouse.wheel(cam === 0 ? -(totalW + 2000) : totalW + 2000, 0);
    await page.waitForTimeout(1200);
  };
  const enter = async (i, cam) => {
    if (!onScreen(i, cam)) return null;
    const { x, y } = cellXY(i, cam);
    await page.mouse.click(x, y);
    await page.waitForTimeout(700);
    if ((await page.locator('body.room').count()) !== 1) return null;
    return (await page.locator('#c-target').textContent()).replace('▸ MESSAGE ', '').trim();
  };
  const leave = async () => { await page.keyboard.press('Escape'); await page.waitForTimeout(450); };

  // ---- identity: cell i must open box i, and its controls must target it ---
  // Two boxes can share an agent+role (nothing forbids it), so a console keyed
  // by anything but the box name silently shows — and CONTROLS — the wrong box.
  const visible = [];
  const seen = new Set();
  for (const cam of [0, camMax]) {
    if (cam > 0) await scrollTo(cam);
    for (let i = 0; i < roster.length; i++) {
      if (seen.has(i) || !onScreen(i, cam)) continue;
      const opened = await enter(i, cam);
      if (opened === null) continue;
      seen.add(i);
      visible.push({ i, cam, expect: roster[i].box, got: opened });
      await leave();
    }
  }
  await scrollTo(0);
  ok('nav: every visible cell opens', visible.length > 0, visible.length + ' entered');
  // Scrolling is what makes this meaningful: without it the tail of the fleet
  // is never clicked, and the tail is where the odd states live.
  ok('nav: the whole fleet is reachable by scrolling', visible.length === roster.length,
     `${visible.length}/${roster.length} cells reached`);
  if (LIVE) {
    const wrong = visible.filter((v) => v.expect !== v.got);
    ok('identity: cell opens its own box', wrong.length === 0,
       wrong.map((w) => `cell ${w.i} is ${w.expect} but opened ${w.got}`).join('; '));
    const distinct = new Set(visible.map((v) => v.got));
    ok('identity: no two cells open the same box', distinct.size === visible.length,
       `${visible.length} cells resolved to ${distinct.size} distinct boxes`);
  }

  if (LIVE && visible.length) {
    // The control must address the box on screen, not a lookalike.
    const target = visible[0];
    await scrollTo(target.cam);
    await enter(target.i, target.cam);
    await page.click('#a-pause');
    await page.waitForTimeout(1300);
    const s = await lastSent();
    eq('identity: pause targets the open box', target.expect, s.box);
    ok('ctl: pause posts pause/resume', /^(pause|resume)$/.test(s.action || ''), s.action);
    // Undo it: this is a real pause on a real box, and leaving it paused
    // changes the fleet the later tests in this suite walk into.
    if (s.action === 'pause') {
      await page.evaluate(async (b) => {
        await fetch(location.origin + '/api/command', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'resume', box: b }),
        });
      }, target.expect);
      await page.waitForTimeout(500);
    }
    await leave();
  }

  // ---- per-state rendering ------------------------------------------------
  const byState = {};
  for (const v of visible) {
    if (v.cam) await scrollTo(v.cam);
    await enter(v.i, v.cam);
    const st = (await page.locator('#modelabel').textContent()).trim();
    (byState[st] = byState[st] || []).push({
      box: v.got,
      current: (await page.locator('#w-current').textContent()).replace(/\s+/g, ' '),
      vitals: (await page.locator('#w-vitals').textContent()).replace(/\s+/g, ' '),
      pauseLabel: (await page.locator('#a-pause').textContent()).trim(),
      cron: ((await page.locator('#w-vitals').textContent()).match(/Cron\s*(\S+)/) || [])[1] || '',
    });
    await leave();
  }
  const down = byState.OFFLINE || [];
  ok('render: at least one down box in view', down.length > 0, Object.keys(byState).join(','));
  ok('render: down boxes state a reason',
     down.length > 0 && down.every((u) => /unreachable|stopped|SILENT|paused|not hired|not created|cron/i.test(u.current)),
     down.map((u) => u.box + ': ' + u.current.slice(0, 50)).join(' | '));
  if (LIVE) {
    // Self-consistency within one render: the vitals say whether the box is
    // paused, so the button must name the action that follows from it.
    const all = Object.values(byState).flat();
    const inconsistent = all.filter((u) =>
      /PAUSED/i.test(u.cron) !== /Resume/.test(u.pauseLabel));
    ok('render: the Pause label names the action the click sends',
       inconsistent.length === 0,
       inconsistent.map((u) => `${u.box} cron=${u.cron} label=${u.pauseLabel}`).join('; '));
    const pausedOnes = all.filter((u) => /PAUSED/i.test(u.cron));
    ok('render: a paused box offers Resume',
       pausedOnes.length > 0 && pausedOnes.every((u) => /Resume/.test(u.pauseLabel)),
       pausedOnes.map((u) => u.box + '=' + u.pauseLabel).join(',') || 'no paused box in view');
  }

  // ---- hostile log content must stay text ---------------------------------
  const hostile = visible.find((v) => /hostile/.test(v.got));
  if (hostile) {
    if (hostile.cam) await scrollTo(hostile.cam);
    await enter(hostile.i, hostile.cam);
    const injected = await page.evaluate(() => ({
      imgs: document.querySelectorAll('.rail-l img, .rail-r img').length,
      scripts: document.querySelectorAll('.rail-l script, .rail-r script').length,
      queueText: document.getElementById('w-queue').textContent,
      curText: document.getElementById('w-current').textContent,
    }));
    eq('xss: no injected <img>', 0, injected.imgs);
    eq('xss: no injected <script>', 0, injected.scripts);
    ok('xss: markup rendered as text',
       /<img|onerror|<script/.test(injected.queueText + injected.curText),
       (injected.queueText + ' | ' + injected.curText).slice(0, 120));
    await shot('06-hostile-escaped');
    await leave();
  }

  /* A box inside its FIRST session — cur set, sessions empty — is ordinary
     live telemetry (floor.py sets working whenever cur exists). The room's
     diagnostic hologram dereferenced sessions[0] unguarded, so opening this
     room threw inside the render loop, every frame. Three reviewers found it;
     136 checks did not, because no fixture could reach the state. */
  const firstRun = visible.find((v) => /firstrun/.test(v.got));
  if (LIVE && firstRun) {
    const before = consoleErrors.length;
    if (firstRun.cam) await scrollTo(firstRun.cam);
    await enter(firstRun.i, firstRun.cam);
    await page.waitForTimeout(2500);          // let the render loop run frames
    ok('first-run room renders without throwing',
       consoleErrors.length === before,
       consoleErrors.slice(before).slice(0, 2).join(' | '));
    ok('first-run room still shows its open session',
       /\d/.test(await page.locator('#w-current').textContent()),
       (await page.locator('#w-current').textContent()).replace(/\s+/g, ' ').slice(0, 60));
    await shot('07-first-run-room');
    await leave();
  }

  /* Live repo strings are full owner/repo. The link used to prefix the org
     unconditionally, yielding github.com/heavy-duty/heavy-duty%2Fcrew — and
     the old assertion only checked for the "heavy-duty/" prefix, which the
     BROKEN url also satisfied. Assert the whole URL. */
  if (LIVE && visible.length) {
    const withRepo = [];
    for (const v of visible) {
      if (v.cam) await scrollTo(v.cam);
      await enter(v.i, v.cam);
      // From the button's own text node: scraping the whole panel ran the
      // repo name into the next button's icon and produced "…crew◱".
      const repo = (await page.locator('#ac-repo').textContent()).match(/Open repo · (.+)$/);
      if (repo && repo[1].trim() !== '—') {
        await page.click('#ac-repo');
        await page.waitForTimeout(250);
        withRepo.push({ box: v.got, repo: repo[1].trim(), url: (await page.evaluate(() => window.__opened)).slice(-1)[0] });
        await leave();
        break;
      }
      await leave();
    }
    if (withRepo.length) {
      const { repo, url } = withRepo[0];
      ok('repo link is not double-prefixed', !/heavy-duty\/heavy-duty/.test(url || ''), url);
      ok('repo link does not escape the slash', !/%2F/i.test(url || ''), url);
      ok('repo link points at the actual repo',
         url === 'https://github.com/' + repo, `${url} for repo ${repo}`);
    } else {
      ok('repo link points at the actual repo', false, 'no unit exposed a repo');
    }
  }

  // ---- log overlay / demo lockout -----------------------------------------
  if (visible.length) {
    await scrollTo(visible[0].cam);
    await enter(visible[0].i, visible[0].cam);
    if (LIVE) {
      await page.click('#ac-logs');
      await page.waitForTimeout(1800);
      const shown = await page.locator('#logov').isVisible().catch(() => false);
      ok('logs: overlay opens (not a popup)', shown, (await page.locator('#livestat').textContent()).trim());
      if (shown) await shot('05-log-overlay');
      await page.keyboard.press('Escape');
      await page.waitForTimeout(400);
      ok('logs: Esc closes overlay and keeps the room',
         !(await page.locator('#logov').isVisible().catch(() => false))
         && (await page.locator('body.room').count()) === 1);
    } else {
      const woff = await page.evaluate(() =>
        ['g-start', 'g-stop', 'g-wake', 'a-pause', 'a-restart', 'c-send']
          .filter((id) => document.getElementById(id).classList.contains('woff')).length);
      eq('demo: all 6 controls disabled', 6, woff);
      eq('demo: message box disabled', true, await page.locator('#c-in').isDisabled());
      await shot('05-demo-disabled');
    }
    await shot('03-console');
    await leave();
  }

  /* Checked HERE, before the fleet-wide action below: that action deliberately
     targets an unreachable box, and the 500 it earns is a correct answer the
     browser always logs. Asserting cleanliness afterwards would mean either a
     permanently red test or a filter loose enough to hide a real error. */
  ok('no console errors', consoleErrors.length === 0, consoleErrors.slice(0, 2).join(' | '));
  const beforeFleet = consoleErrors.length;

  // ---- fleet-wide ---------------------------------------------------------
  if (LIVE) {
    await page.click('#g-wake');
    await page.waitForTimeout(2500);
    const msg = (await page.locator('#livestat').textContent()).trim();
    ok('fleet: wake-silent reports a result', /wake-silent/.test(msg), msg);
    // The partial failure must reach the operator as a named box, not a code.
    ok('fleet: a partial failure names the box', !/HTTP \d+$/.test(msg), msg);
    const added = consoleErrors.slice(beforeFleet);
    ok('fleet: only the expected 500 was logged',
       added.every((e) => /500/.test(e)), added.join(' | '));
  }

  await browser.close();
  console.log(`  -- browser: ${pass} ok, ${fails.length} failed`);
  process.exit(fails.length ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(2); });
