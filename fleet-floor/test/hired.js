/* fleet-floor/test/hired.js — the empty floor, and a box hired into it.
 *
 *   node hired.js <url> <fixture-file> <user> <pass>
 *
 * danmt's framing when #204 was filed: "a box that's not hired should not be
 * available in the fleet floor. In this case I'd expect an empty floor, then
 * triage appears." Both halves of that sentence are here, and neither can ride
 * the main walk: it runs against a fixture fleet of twenty-six boxes broken in
 * twenty-six ways, where "no console is drawn" and "the first console appears"
 * are both false by construction.
 *
 * So it gets its own roster of two — one box that answered and reported no
 * engine, one that does not exist yet — and its own copy of the stub's fleet
 * fixture, which is the file that decides what `box exec` answers with. Hiring
 * is simulated the only way it can be offline: rewrite that box's scenario
 * from `nothired` to `idle` and let the collector's next poll find an engine
 * where there was none. The page is NEVER reloaded across that flip, which is
 * the acceptance criterion — a console must appear without an operator
 * restarting `crew floor`.
 *
 * Everything below is read off the RENDERED PAGE: FLOORDEV.grid() reports the
 * cells the floor actually laid out, and the empty state is DOM. /api/fleet is
 * read exactly twice, and only to prove the fixture is the fixture — a walk
 * that asserted the filter through the API would be green on the regression
 * #203 recorded, where every collector assertion held while the page lied.
 */
const fs = require('fs');
const { chromium } = require('playwright-core');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , url, FIXTURE, USER, PASS] = process.argv;

let failed = 0;
const ok = (name, cond, detail = '') => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${!cond && detail ? '  — ' + String(detail).slice(0, 200) : ''}`);
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

  const cells = () => page.evaluate(() => window.FLOORDEV.grid().n);
  const tiles = () => page.evaluate(() =>
    [].map.call(document.querySelectorAll('#tiles .tile'), (t) => ({
      label: t.querySelector('.l').textContent.trim(),
      n: t.querySelector('.n').textContent.trim(),
    })));
  const tileN = async (label) => ((await tiles()).find((t) => t.label === label) || {}).n;
  const settle = async (pred, ms = 40000, every = 500) => {
    for (let w = 0; w < ms; w += every) {
      if (await pred()) return true;
      await page.waitForTimeout(every);
    }
    return false;
  };

  /* Wait for the page to go LIVE on the two-box roster. DEMO ships a static
     seven-box roster and draws seven cells, which would fail every assertion
     below for the right reason and pass "the floor is not empty" for the wrong
     one — so pin the declared count first, and only then read the grid. */
  const live = await settle(async () => (await tileN('units')) === '2');
  ok('hired: the page is live on the two-box roster', live,
     'tiles=' + JSON.stringify(await tiles()));

  const api = await page.evaluate(async () => {
    const r = await fetch(location.origin + '/api/fleet');
    return (await r.json()).units.map((u) => ({ box: u.box, hired: u.hired }));
  });
  ok('hired: the roster really is two boxes and neither is hired',
     api.length === 2 && api.every((u) => u.hired === 'no'), JSON.stringify(api));

  // ---- the empty floor ------------------------------------------------------
  ok('hired: an all-unhired roster draws no console', (await cells()) === 0,
     (await cells()) + ' cells laid out');
  /* The count is the "visible count rather than a silent omission" the issue
     asks for: a hidden box is omitted from the GRID and never from the PAGE.
     Both tiles, because either one alone tells half the story — `units` says
     what is declared, `hired` says how many of them made it onto the floor. */
  ok('hired: the empty floor still counts the declared boxes',
     (await tileN('units')) === '2', JSON.stringify(await tiles()));
  ok('hired: the empty floor says none of them is hired',
     (await tileN('hired')) === '0', JSON.stringify(await tiles()));

  const empty = await page.evaluate(() => {
    const el = document.querySelector('#emptyfloor');
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { on: el.classList.contains('on'), text: el.textContent.replace(/\s+/g, ' ').trim(),
             visible: r.width > 0 && r.height > 0 };
  });
  ok('hired: the empty floor is not a blank page', !!empty && empty.on && empty.visible,
     JSON.stringify(empty));
  /* The three things a fresh operator needs off a floor with nothing on it:
     that this is a state and not a failure, how many boxes were declared, and
     the command that turns one of them into a console. Argument 3 in #204's
     "why it is not obvious" is a requirement on the fix, and this is it. */
  ok('hired: the empty floor names the declared count',
     /\b2\b/.test((empty && empty.text) || ''), (empty && empty.text) || '');
  ok('hired: the empty floor names the command that populates it',
     /crew hire/.test((empty && empty.text) || ''), (empty && empty.text) || '');
  await page.screenshot({ path: (process.env.SHOT_DIR || '/tmp') + '/hired-empty.png' });

  // ---- ...then triage appears ----------------------------------------------
  /* The flip, and the whole reason this file owns a fixture copy: the stub
     reads it on every call, so rewriting one scenario hires that box for the
     collector's NEXT poll. No reload, no restart — the page below is the same
     page that just rendered the empty floor. */
  const before = fs.readFileSync(FIXTURE, 'utf8');
  fs.writeFileSync(FIXTURE, before.replace(/^hf-nothired\s+running\s+nothired$/m,
    'hf-nothired    running  idle'));
  ok('hired: the fixture flip really hired a box',
     /^hf-nothired\s+running\s+idle$/m.test(fs.readFileSync(FIXTURE, 'utf8')),
     fs.readFileSync(FIXTURE, 'utf8'));

  const appeared = await settle(async () => (await cells()) === 1);
  ok('hired: hiring a box makes its console appear on the next poll', appeared,
     (await cells()) + ' cells after the flip');
  ok('hired: it is the box that was hired',
     (await page.evaluate(() => window.FLOORDEV && ROSTER.map((u) => u.box).join(','))) === 'hf-nothired',
     await page.evaluate(() => ROSTER.map((u) => u.box).join(',')));
  /* The counts move with it, and only the right one moves: the fleet did not
     grow, so `units` still reads two. A declared count that tracked the grid
     would be the silent omission this issue exists to prevent. */
  ok('hired: the declared count is unchanged by hiring',
     (await tileN('units')) === '2', JSON.stringify(await tiles()));
  ok('hired: the hired count follows the console onto the floor',
     (await tileN('hired')) === '1', JSON.stringify(await tiles()));
  const gone = await page.evaluate(() => {
    const el = document.querySelector('#emptyfloor');
    return el ? { on: el.classList.contains('on'), text: el.textContent.trim() } : null;
  });
  ok('hired: the empty state clears once a console is drawn',
     !!gone && !gone.on && gone.text === '', JSON.stringify(gone));
  /* ...and the box that still does not exist is still SERVED. This is the
     drill's floor-vs-CLI agreement check reading the same payload: it fails a
     box outright with "not in /api/fleet", so a filter that reached the API
     would red a drill nothing in CI can run. */
  const after = await page.evaluate(async () => {
    const r = await fetch(location.origin + '/api/fleet');
    return (await r.json()).units.map((u) => ({ box: u.box, hired: u.hired }));
  });
  ok('hired: the box with no console is still carried by /api/fleet',
     after.length === 2 && after.some((u) => u.box === 'hf-absent' && u.hired === 'no'),
     JSON.stringify(after));
  await page.screenshot({ path: (process.env.SHOT_DIR || '/tmp') + '/hired-first.png' });

  ok('hired: no page errors', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));

  await browser.close();
  console.log(`  -- hired: ${failed ? failed + ' failed' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('HIRED HARNESS ERROR:', e.message); process.exit(2); });
