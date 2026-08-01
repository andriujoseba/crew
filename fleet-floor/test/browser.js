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
/* FLOOR_TEST_READONLY=1 — render and navigate, but never touch a control.
   This walk is written for the stub fleet, where clicking Pause costs nothing.
   Against a REAL fleet (drill/rehearsal-app.sh) the same clicks pause a live
   box and start stopped ones, so the drill runs us in this mode unless the
   operator explicitly opted into control. */
const READONLY = process.env.FLOOR_TEST_READONLY === '1';
/* Whether the fleet under the page is the STUB fixture or a real one.
   test/run.sh drives fixtures/roster.txt, whose contents are guaranteed: there
   IS a box with hostile log text, one inside its first session, and several
   offline. Those are the states the page's worst bugs lived in, so "that box
   was not reachable" must be a loud failure there -- otherwise the checks that
   depend on it silently do not run and the suite stays green.

   The drill points the same walk at a REAL fleet, which has no box named
   hostile or firstrun, and when healthy has nothing offline at all. Asserting
   the fixture's contents there fails on every host, forever -- for the good
   reason that the fleet is fine. kimi-bot caught this: the guard is right for
   the suite and wrong unconditionally, so it is gated rather than removed. */
const FIXTURE = process.env.FLOOR_TEST_FIXTURE === '1';
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
  /* Actionable, because the old message ("no chromium at <playwright cache>")
     named a path that playwright-core NEVER populates — it ships without
     browsers on purpose — and said nothing about the variable that fixes it.
     A system Chrome is invisible here unless PW_CHROME points at it. */
  if (!fs.existsSync(CHROME)) {
    console.error('no browser at ' + CHROME);
    console.error('playwright-core ships without browsers; point PW_CHROME at an installed one, e.g.');
    console.error('  PW_CHROME=/usr/bin/google-chrome-stable   (or /opt/google/chrome/chrome, /usr/bin/chromium)');
    process.exit(2);
  }
  fs.mkdirSync(out, { recursive: true });

  /* FLOOR_TEST_HEADED=1 shows the browser, FLOOR_TEST_SLOWMO=<ms> paces it.
     Both exist so a human can WATCH the walk drive the page — there was no way
     to, and the screenshots are a poor substitute for seeing a control land.
     Headed mode needs a display, so it stays opt-in and CI never sets it. */
  const HEADED = process.env.FLOOR_TEST_HEADED === '1';
  const SLOWMO = Number(process.env.FLOOR_TEST_SLOWMO || 0) || 0;
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    slowMo: SLOWMO,
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
  // Poll for the LIVE flip rather than guessing how long the first poll takes:
  // a fixed wait that expires early mislabels the MODE, and every branch below
  // is then testing the wrong thing. DEMO legitimately never flips, so the
  // timeout is the answer there, not a failure.
  for (let w = 0; w < 12000; w += 250) {
    if ((await page.locator('.demo-badge.live').count()) > 0) break;
    await page.waitForTimeout(250);
  }
  // There are two badges (floor bar + room HUD); goLive() marks both.
  const LIVE = (await page.locator('.demo-badge.live').count()) > 0;
  console.log(`  mode: ${LIVE ? 'LIVE' : 'DEMO'}${READONLY ? ' (read-only: controls not exercised)' : ''}`);

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
  /* Not just "the word units appears": that is true of an empty fleet too,
     because the tiles always render. Assert the count matches the roster. */
  const tilesText = (await page.locator('#tiles').textContent()).replace(/\s+/g, '');
  const tileUnits = (tilesText.match(/(\d+)units/) || [])[1];
  ok('floor: the unit tile matches the fleet size',
     LIVE ? String(roster.length) === tileUnits : /^[1-9]/.test(tileUnits || ''),
     `tile says ${tileUnits}, roster has ${roster.length}`);
  await shot('01-floor');

  /* Cell geometry comes from the layout itself: FLOORDEV.grid() reports where
     every roster cell IS under the camera as it stands, plus the camera range.
     The test used to mirror drawFloor()'s constants and re-derive positions,
     and every layout change broke the mirror silently — the conference-grid
     rework (vertical scroll, window-sized tiles) is exactly the kind of change
     that would have clicked thin air for a whole walk. */
  const gridAt = () => page.evaluate(() => window.FLOORDEV.grid());
  const g0 = await gridAt();
  const vh = await page.evaluate(() => window.innerHeight);
  const camMax = g0.camMax;
  /* A slot is clickable when its centre is clear of the fixed chrome: the
     fleet bar (top) and the ops bar (bottom 152px) both overlay the canvas. */
  const CHROME_TOP = 80, CHROME_BOT = 170;
  const slotsOnScreen = async () => {
    const g = await gridAt();
    return g.cell
      .map((c) => ({ i: c.i, x: c.x + g.tw / 2, y: c.y + g.th / 2 }))
      .filter((c) => c.y >= CHROME_TOP && c.y <= vh - CHROME_BOT);
  };
  // The floor scrolls VERTICALLY; a viewport-sized walk steps the camera down.
  const stepPx = Math.max(150, vh - g0.th - CHROME_TOP - CHROME_BOT);
  // The camera eases toward its target, so scrolling needs a settle wait.
  // Absolute positioning: rewind to 0 first, then wheel forward by `cam`, so
  // the camera lands somewhere known rather than "as far as it got".
  /* #195 landed an independent fix for the same race while this PR was in
     review, from the other end: FLOORDEV.cam() is a real hook, and settleCam
     takes the target to converge ON rather than inferring convergence from a
     window global. That is the better mechanism and it wins the merge — this
     branch's version, which polled `window.floorCam` because app.js is inlined
     as a classic script, is dropped. Both were chasing the same symptom; #195's
     comment records "15/17 boxes reached, twice, on an idle box". */
  /* The camera IS readable now: FLOORDEV.cam() (the whiteboard hook postdates
     the "reading the real camera would need a test hook" decision below, and
     the hook exists regardless). The fixed waits this replaced covered ~4
     easing frames on a slow machine — the camera lands half-scrolled and a
     cell-centre click falls in a gap: that was "15/17 boxes reached", twice,
     on an idle box. (When this was written, a console dwell also expired
     every visible portrait still, making post-Escape frames build-heavy;
     stills are deterministic and permanent since #226, but the easing-vs-
     fixed-wait race is real on its own.) Poll convergence; on timeout click
     anyway — every caller still verifies by outcome. */
  const camAt = () => page.evaluate(() => window.FLOORDEV.cam());
  const settleCam = async (want) => {
    for (let w = 0; w < 8000; w += 60) {
      if (Math.abs((await camAt()) - want) < 0.75) return true;
      await page.waitForTimeout(60);
    }
    return false;
  };
  const scrollTo = async (cam) => {
    await page.mouse.move(700, Math.min(vh - CHROME_BOT, 400));
    await page.mouse.wheel(0, -(g0.totalH + 2000));
    await settleCam(0);
    if (cam > 0) {
      await page.mouse.wheel(0, cam);
      await settleCam(Math.min(cam, camMax));
    }
  };
  /* POLL, never sleep-and-hope. A fixed 700 ms for the room to open and 1200 ms
     for the easing camera to settle is a margin, not a guarantee: on a loaded
     CI runner a slow frame silently skipped a cell and the reachability count
     failed. That produced two intermittent red heads on this PR (the paused-box
     walk, then this one), which is how a suite teaches people to ignore it.
     One retry per cell, because a miss is nearly always a frame, not a bug. */
  const settle = async (pred, ms = 6000, every = 100) => {
    for (let w = 0; w < ms; w += every) {
      if (await pred()) return true;
      await page.waitForTimeout(every);
    }
    return false;
  };
  // Back out of a console to the floor. Every open/close pair goes through
  // this, including the ones inside the search below: leaving a console open
  // makes the next click land inside it instead of on a cell.
  const leave = async () => {
    await page.keyboard.press('Escape');
    await settle(async () => (await page.locator('body.floor').count()) === 1, 4000);
  };
  /* NEVER click while a console is open.
     `leave()` ran only after a SUCCESSFUL read, so a click whose room opened
     just after its settle window closed left the console up. The next click
     then landed INSIDE that console, where `body.room` is present and
     `#c-target` still names the PREVIOUS box — so the settle reported success
     and the walk recorded a read of a box it had already seen, while the cell
     it was aiming at was never visited. That is `16 reads -> 16 distinct,
     roster 17` with a DIFFERENT box missing each run (ff-nothired, ff-noauth,
     ff-disarmed across four), and it gets likelier with every cell added,
     because every cell is another chance for one settle to lose its race.
     Escape is idempotent on the floor, so this costs one DOM read per click
     and removes the class: whatever room appears after a click can only have
     come from that click. */
  const ensureFloor = async () => {
    if ((await page.locator('body.floor').count()) === 1) return;
    await leave();
  };
  // Re-open a unit recorded by the scan, by the position it was found at.
  /* Re-entry SEARCHES for the box; it does not replay a position.
     Saved (x, y, cam) cannot reliably reproduce a unit: scrollTo eases and
     clamps, so the same coordinates under a slightly different camera open a
     neighbour. Verifying that (the previous fix) correctly turned a silent
     mis-assertion into an honest failure — `expected ff-firstrun, got null` —
     but the replay itself is the unsound part. Try the saved spot first as a
     fast path, then fall back to scanning slots until the wanted box opens. */
  const openHere = async (x, y) => {
    // Same guard as the scan (grok, round 1): re-entry can inherit a late-open
    // room just as the walk could, and then reports the PREVIOUS box as this
    // click's result. Closing the class on one half only leaves it live on the
    // other, and enterAt()'s fast path is exactly where a stale console is
    // most likely — it clicks a remembered position straight after a scroll.
    await ensureFloor();
    await page.mouse.click(x, y);
    const opened = await settle(async () =>
      (await page.locator('body.room').count()) === 1
      && ((await page.locator('#c-target').textContent()) || '').includes('MESSAGE'), 4000);
    if (!opened) return null;
    return (await page.locator('#c-target').textContent()).replace('▸ MESSAGE ', '').trim();
  };
  const enterAt = async (v) => {
    // fast path: where we found it last time
    await scrollTo(v.cam);
    let got = await openHere(v.x, v.y);
    if (got === v.got) return got;
    if (got !== null) await leave();
    // search: every on-screen slot at every camera step until the box appears
    for (let cam = 0; ; cam = Math.min(cam + stepPx, camMax)) {
      await scrollTo(cam);
      for (const sl of await slotsOnScreen()) {
        got = await openHere(sl.x, sl.y);
        if (got === v.got) { v.x = sl.x; v.y = sl.y; v.cam = cam; return got; }
        if (got !== null) await leave();
      }
      if (cam >= camMax) break;
    }
    return null;
  };

  // ---- identity: cell i must open box i, and its controls must target it ---
  // Two boxes can share an agent+role (nothing forbids it), so a console keyed
  // by anything but the box name silently shows — and CONTROLS — the wrong box.
  /* Scan the floor in steps rather than assuming every cell is visible from
     one end or the other. Two fixed passes (cam 0 and cam max) left a middle
     cell unreachable once the fleet grew to 15 — and only on a slower runner,
     where the camera lerp had not fully settled, so it passed locally and went
     red in CI. Step until every index has been opened or progress stops. */
  /* Walk by RESULT, not by assumed camera position.
     The previous version computed each cell's x from the `cam` it had just
     requested — but scrollTo() eases and clamps, so the camera is not exactly
     where it was asked to be, and the click landed on a neighbour ("cell 8 is
     ff-nothired but opened ff-stopped", "15 cells resolved to 14 distinct
     boxes"). Reading the real camera would need a test hook in production
     code, so instead: click each on-screen SLOT, record whichever box actually
     opens, and assert the two properties that do not require knowing the
     camera —
       coverage: every roster box is reachable, and
       ordering: boxes read in layout order are consecutive in the roster,
     which is what catches a cell rendering another unit's identity. */
  const visible = [];
  const seenBox = new Map();          // box -> first {i-ish slot} we saw it at
  const orderViolations = [];


  for (let cam = 0; ; cam = Math.min(cam + stepPx, camMax)) {
    await scrollTo(cam);
    const readHere = [];              // boxes read at this scroll position, in layout order
    /* Every slot the grid reports is a real roster cell — the layout hook
       enumerates cells, not grid positions, so there is no "half-empty last
       column" case to special-case around. A slot that will not open is a
       lost race, not an absence — retry it once with a longer budget instead
       of silently recording the box as unreachable. */
    for (const sl of await slotsOnScreen()) {
      let opened = false;
      for (const budget of [4000, 8000]) {
        await ensureFloor();
        await page.mouse.click(sl.x, sl.y);
        opened = await settle(async () =>
          (await page.locator('body.room').count()) === 1
          && ((await page.locator('#c-target').textContent()) || '').includes('MESSAGE'), budget);
        if (opened) break;
      }
      // A room that opened after its settle window must not be left up for
      // the next click to land in.
      if (!opened) { await ensureFloor(); continue; }
      const box = (await page.locator('#c-target').textContent()).replace('▸ MESSAGE ', '').trim();
      readHere.push({ box, i: sl.i });
      if (!seenBox.has(box)) {
        seenBox.set(box, true);
        visible.push({ x: sl.x, y: sl.y, cam, got: box, expect: box });
      }
      await leave();
    }
    // Ordering: layout order must follow roster order. A cell rendering some
    // other unit's identity breaks this without needing the camera value.
    const idx = readHere.map((r) => roster.findIndex((u) => u.box === r.box));
    for (let k = 1; k < idx.length; k++) {
      // Increasing, not consecutive: a slot that failed to open is skipped,
      // which leaves a gap and is not a rendering fault. Going BACKWARDS or
      // repeating is — that is a cell showing another unit's identity.
      if (idx[k] >= 0 && idx[k - 1] >= 0 && idx[k] <= idx[k - 1]) {
        orderViolations.push(`${readHere[k - 1].box}(#${idx[k - 1]}) then ${readHere[k].box}(#${idx[k]})`);
      }
    }
    if (seenBox.size >= roster.length) break;
    if (cam >= camMax) break;
  }
  await scrollTo(0);

  ok('nav: layout order follows roster order', orderViolations.length === 0,
     orderViolations.slice(0, 3).join('; '));

  ok('nav: cells open', visible.length > 0, visible.length + ' distinct boxes entered');
  // Scrolling is what makes this meaningful: without it the tail of the fleet
  // is never clicked, and the tail is where the odd states live.
  /* Name the boxes that were missed. "16/17" says a walk failed; it does not
     say whether the renderer dropped a cell, the cell would not open, or the
     scan never reached it — and those want three different fixes. */
  const missed = roster.map((u) => u.box).filter((b) => !seenBox.has(b));
  ok('nav: the whole fleet is reachable by scrolling', seenBox.size === roster.length,
     `${seenBox.size}/${roster.length} boxes reached` +
     (missed.length ? ` — never opened: ${missed.join(', ')}` : ''));
  if (LIVE) {
    // Every roster box appears exactly once across the scan. Combined with the
    // ordering check above, that is the identity property without needing to
    // know where the camera actually is.
    const distinct = new Set(visible.map((v) => v.got));
    ok('identity: every box appears exactly once', distinct.size === visible.length
       && distinct.size === roster.length,
       `${visible.length} reads → ${distinct.size} distinct, roster ${roster.length}`);
    const strays = visible.filter((v) => !roster.some((u) => u.box === v.got));
    ok('identity: no box outside the roster was rendered', strays.length === 0,
       strays.map((v) => v.got).join(','));
  }

  if (LIVE && visible.length && !READONLY) {
    // The control must address the box on screen, not a lookalike.
    const target = visible[0];
    const reopened = await enterAt(target);
    // Assert we are actually in the room before driving a control: a null
    // re-entry used to fall through and click a hidden #a-pause, which failed
    // as a 30s Playwright timeout rather than as a legible test failure.
    ok('identity: the target console re-opens', reopened === target.got,
       `expected ${target.got}, got ${reopened}`);
    await page.click('#a-pause');
    await settle(async () => (await sent()).length > 0, 8000);
    const s = await lastSent();
    eq('identity: pause targets the open box', target.expect, s.box);
    ok('ctl: pause posts pause/resume', /^(pause|resume)$/.test(s.action || ''), s.action);
    // Undo it: this is a real pause on a real box, and leaving it paused
    // changes the fleet the later tests in this suite walk into.
    if (s.action === 'pause') {          // never send a bare resume: on a box an
                                         // operator had parked, that un-parks it
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
    const opened = await enterAt(v);
    // A missed click would otherwise attribute the PREVIOUS console's readings
    // to this box, and every per-state assertion below would be about the
    // wrong unit.
    if (opened !== v.got) { if (opened !== null) await leave(); continue; }
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
  // ---- the three tiers must be VISIBLE, not merely served ----------------
  // Every field below is in /api/fleet and asserted in cases.sh. That proves
  // the collector computed it; it says nothing about whether an operator can
  // see it. The gh column regressed exactly this way — probe.sh stopped
  // emitting "ok", the page still tested for it, and every healthy box
  // rendered "gh ✗" while every collector assertion stayed green.
  const allSeen = Object.keys(byState).reduce((a, k) => a.concat(byState[k]), []);
  if (LIVE && allSeen.length) {
    // Asserted by SHAPE, because this block is gated on LIVE alone and LIVE
    // only means "the page flipped to real data" — true on a real host as much
    // as against the stub. The previous form pinned `0.4.1` and `deadbee`,
    // which are stub-box fixture constants (test/stub-box:84,431), so on a real
    // fleet — rendering its own VERSION — it could not pass by construction. It
    // failed every real-host drill while reading as an app defect (#190, #202).
    // The exact-constant form still runs, under LIVE && FIXTURE below, which is
    // the only place those values are true.
    //
    // What survives here is the regression this exists to catch: stampVersion
    // (src/app.js) maps `crew@X.Y.Z[-suffix]` to the version alone, so a leaked
    // `crew@` prefix means the raw stamp reached the tile, and `unknown` means
    // it could not parse one. Both are anchored on the Engine label rather than
    // searched loose in the vitals string, or the check would match on a
    // neighbouring field and report the wrong tier.
    ok('render: engine shows the version without provenance',
       allSeen.some((u) => /Engine\s*\d+\.\d+\.\d+/.test(u.vitals)) &&
         allSeen.every((u) => !/Engine\s*(?:crew@|unknown)/.test(u.vitals)),
       allSeen.map((u) => u.box + ': ' + u.vitals).join(' | '));
    ok('render: the heartbeat is on screen',
       allSeen.every((u) => /Heartbeat/.test(u.vitals)),
       allSeen.filter((u) => !/Heartbeat/.test(u.vitals)).map((u) => u.box).join(','));
    // A live round-trip renders as "12ms · 4s ago". Asserting the ms shape
    // rather than the label proves a real value reached the DOM.
    const pinged = allSeen.filter((u) => /Heartbeat\s*\d+ms/.test(u.vitals));
    ok('render: at least one box shows a measured round-trip',
       pinged.length > 0,
       allSeen.map((u) => u.box + ': ' + (u.vitals.match(/Heartbeat\s*(\S+)/) || [])[1]).join(' | '));
    // The regression guard. "gh ?" is legitimate (an unhired box), "gh ✗" is
    // legitimate (a real rejection) — but not for every box at once, which is
    // what a vocabulary mismatch produces.
    const ticked = allSeen.filter((u) => /gh ✓/.test(u.vitals));
    ok('render: healthy boxes show gh ✓, not a blanket ✗',
       ticked.length > 0,
       allSeen.map((u) => u.box + ': ' + (u.vitals.match(/Box\s*(\S+ \S+)/) || [])[1]).join(' | '));
  }
  if (LIVE && FIXTURE) {
    // The exact-constant half of the engine assertion above. The stub stamps
    // `crew@0.4.1 (deadbee)` (test/stub-box:84), so this is the one run where
    // provenance-stripping can be checked against a KNOWN input: the version
    // must render and the provenance token must not. A real fleet cannot make
    // this claim — its stamp carries whatever provenance it carries — which is
    // why the live block above asserts shape instead.
    ok('render: the fixture engine renders 0.4.1 with its provenance stripped',
       allSeen.some((u) => /Engine\s*0\.4\.1/.test(u.vitals)) &&
         allSeen.every((u) => !/deadbee/.test(u.vitals)),
       allSeen.map((u) => u.box + ': ' + u.vitals).join(' | '));
    // FIXTURE-gated: a real fleet has no box wedged on purpose, and should not.
    const stuck = allSeen.find((u) => /ff-stuck/.test(u.box));
    ok('render: the stuck box was reachable', !!stuck,
       'no ff-stuck among ' + allSeen.length + ' consoles');
    if (stuck) {
      // It is STATE=working with a live session, so without this the panel
      // showed an ordinary elapsed timer and the box read as healthy.
      ok('render: a stuck lock says STUCK in the session panel',
         /STUCK/.test(stuck.current), stuck.current.slice(0, 90));
      ok('render: the stuck panel names how long the lock has been held',
         /lock held/.test(stuck.current), stuck.current.slice(0, 90));
    }
  }

  const down = byState.OFFLINE || [];
  // The fixture guarantees offline boxes; a healthy real fleet guarantees the
  // opposite, and "everything is up" must not read as a test failure.
  if (FIXTURE) {
    ok('render: at least one down box in view', down.length > 0, Object.keys(byState).join(','));
  }
  if (down.length > 0) {
    ok('render: down boxes state a reason',
       down.every((u) => /unreachable|stopped|SILENT|paused|not hired|not created|cron/i.test(u.current)),
       down.map((u) => u.box + ': ' + u.current.slice(0, 50)).join(' | '));
  } else {
    console.log('  --   no offline box in this fleet; nothing to state a reason for');
  }
  if (LIVE) {
    // Self-consistency within one render: the vitals say whether the box is
    // paused, so the button must name the action that follows from it.
    const all = Object.values(byState).flat();
    const inconsistent = all.filter((u) =>
      /PAUSED/i.test(u.cron) !== /Resume/.test(u.pauseLabel));
    ok('render: the Pause label names the action the click sends',
       inconsistent.length === 0,
       inconsistent.map((u) => `${u.box} cron=${u.cron} label=${u.pauseLabel}`).join('; '));
  }

  /* Pause a box HERE rather than relying on one being paused in the fixture:
     the collector-side tests run `wake-silent`, which resumes every offline
     box — including the fixture's paused one — so "is something paused right
     now" depends on what ran before this. Make the state, assert it, undo it.

     Truth comes from the API (u.paused), not from scraping Cron text out of a
     CSS grid's textContent — that scrape was brittle and is what put CI red.
     Both are re-read together each iteration, so there is no window where a
     label captured earlier is compared against a flag fetched later. */
  if (LIVE && visible.length && !READONLY) {
    /* The victim must be a box a pause can actually MOVE. Since #188 a box with
       no armed tick.sh line answers 200 `nothing to pause` — correctly; an
       action with nothing to do is not a refusal — so landing on the fixture's
       disarmed box would sit out all fourteen polls below waiting for a
       `paused` that is never coming, and report the renderer as broken. The
       name says nothing about this: `disarmed` is the flag the collector
       derives from the box's own crontab count, so ask the API, in keeping with
       the rest of this block. Falls back to the old choice if nothing is armed,
       rather than silently skipping the assertion. */
    const armed = await page.evaluate(async () => {
      const r = await fetch(location.origin + '/api/fleet');
      return (await r.json()).units.filter((u) => !u.disarmed).map((u) => u.box);
    });
    const reachable = visible.filter((v) => !/unreach|wedged|absent|stopped/.test(v.got));
    const victim = reachable.find((v) => armed.includes(v.got)) || reachable[0] || visible[0];
    const cmd = (action, box) => page.evaluate(async ([a, b]) => {
      const r = await fetch(location.origin + '/api/command', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: a, box: b }),
      });
      return r.status;
    }, [action, box]);

    const pauseStatus = await cmd('pause', victim.got);
    ok('ctl: pause command accepted', pauseStatus === 200, `HTTP ${pauseStatus}`);

    let checked = false;
    for (let i = 0; i < 14; i++) {
      await page.waitForTimeout(2500);
      const apiPaused = await page.evaluate(async (b) => {
        const r = await fetch(location.origin + '/api/fleet');
        const u = (await r.json()).units.find((x) => x.box === b);
        return u ? !!u.paused : null;
      }, victim.got);
      if (!apiPaused) continue;               // collector has not re-polled yet
      const opened = await enterAt(victim);
      if (opened !== victim.got) {           // clicked the wrong cell — retry
        if (opened !== null) await leave();
        continue;
      }
      const label = (await page.locator('#a-pause').textContent()).trim();
      await leave();
      // The page can lag the collector by one poll; only assert once it agrees.
      if (/Resume/.test(label)) {
        ok('render: a paused box offers Resume', /Resume/.test(label),
           `${victim.got} label=${label}`);
        checked = true;
        break;
      }
    }
    if (!checked) {
      ok('render: a paused box offers Resume', false,
         `${victim.got}: page never showed Resume while the API reported paused`);
    }
    await cmd('resume', victim.got);
    await page.waitForTimeout(500);
  }

  // ---- hostile log content must stay text ---------------------------------
  const hostile = visible.find((v) => /hostile/.test(v.got));
  if (FIXTURE && LIVE && !hostile) {
    // Silent coverage loss is worse than a loud failure: without this, the XSS
    // checks below simply would not run and the suite would still be green.
    // FIXTURE-gated -- a real fleet has no such box, and should not.
    ok('xss: the hostile-log box was reachable', false,
       `no unit matching /hostile/ among ${visible.length} reached boxes`);
  }
  if (hostile) {
    if ((await enterAt(hostile)) !== hostile.got) {
      ok('xss: hostile console re-opened', false, `could not re-open ${hostile.got}`);
    } else {
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
  }

  /* A box inside its FIRST session — cur set, sessions empty — is ordinary
     live telemetry (floor.py sets working whenever cur exists). The room's
     diagnostic hologram dereferenced sessions[0] unguarded, so opening this
     room threw inside the render loop, every frame. Three reviewers found it;
     136 checks did not, because no fixture could reach the state. */
  const firstRun = visible.find((v) => /firstrun/.test(v.got));
  if (FIXTURE && LIVE && !firstRun) {
    ok('first-run: the first-session box was reachable', false,
       `no unit matching /firstrun/ among ${visible.length} reached boxes`);
  }
  if (LIVE && firstRun) {
    const before = consoleErrors.length;
    const frOpened = await enterAt(firstRun);
    ok('first-run console re-opened', frOpened === firstRun.got,
       `expected ${firstRun.got}, got ${frOpened}`);
    if (frOpened !== firstRun.got) { await leave(); }
    else {
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
  }

  /* Live repo strings are full owner/repo. The link used to prefix the org
     unconditionally, yielding github.com/heavy-duty/heavy-duty%2Fcrew — and
     the old assertion only checked for the "heavy-duty/" prefix, which the
     BROKEN url also satisfied. Assert the whole URL. */
  if (LIVE && visible.length) {
    const withRepo = [];
    for (const v of visible) {
      // Skip a unit we could not re-open rather than reading whichever console
      // happened to be on screen — that is exactly how the wrong repo string
      // would get asserted as correct.
      if ((await enterAt(v)) !== v.got) continue;
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
    } else if (FIXTURE) {
      // Fixture-gated for the same reason as the offline-box demand above: the
      // fixture guarantees a unit with a repo, a real fleet does not. A host
      // whose boxes are all idle with no history and no repos.txt would fail
      // here for a reason that says nothing about the page.
      //
      // Unlike the hostile/first-run cases this one is DEFENSIVE, not
      // demonstrated: I could not drive a stub fleet into it, because the repo
      // string comes from session and queue lines rather than from `::repos`,
      // so every box with any history still exposes one. Gated on the argument,
      // not on a reproduction -- worth stating plainly rather than implying the
      // same evidence as the other two.
      ok('repo link points at the actual repo', false, 'no unit exposed a repo');
    } else {
      console.log('  --   no unit exposed a repo; nothing to check a repo link against');
    }
  }

  // ---- log overlay / demo lockout -----------------------------------------
  if (visible.length) {
    const l0 = await enterAt(visible[0]);
    ok('logs: console re-opened for the overlay check', l0 === visible[0].got,
       `expected ${visible[0].got}, got ${l0}`);
    if (LIVE && l0 === visible[0].got) {
      await page.click('#ac-logs');
      await settle(async () => await page.locator('#logov').isVisible().catch(() => false), 8000);
      const shown = await page.locator('#logov').isVisible().catch(() => false);
      ok('logs: overlay opens (not a popup)', shown, (await page.locator('#livestat').textContent()).trim());
      if (shown) await shot('05-log-overlay');
      await page.keyboard.press('Escape');
      await settle(async () => !(await page.locator('#logov').isVisible().catch(() => false)), 4000);
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
  if (LIVE && !READONLY) {
    await page.click('#g-wake');
    /* Poll until the status is TERMINAL. Reading it a fixed 2.5s after the
       click asserted the optimistic "wake-silent…" in-flight message, while
       the action itself takes >=8s against the wedged fixture — three
       assertions that could not fail. */
    let msg = '';
    for (let i = 0; i < 30; i++) {
      await page.waitForTimeout(1000);
      msg = (await page.locator('#livestat').textContent()).trim();
      if (/ok$|FAILED|failed/.test(msg)) break;
    }
    ok('fleet: wake-silent reaches a terminal status', /ok$|FAILED|failed/.test(msg), msg);
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
