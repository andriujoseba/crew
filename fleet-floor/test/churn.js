/* fleet-floor/test/churn.js — the roster changes under a page that is already open.
 *
 *   node churn.js <url> <roster-file> <user> <pass>
 *
 * The collector re-reads fleet.roster every poll, so a box can appear, vanish
 * or be renamed while an operator is standing in its console. That is not
 * hypothetical: `crew new`, an edited roster and a renamed box all do it, and
 * the console keeps a pinned focus across polls ON PURPOSE (so a poll does not
 * yank the view back to the floor every 15s). The question this asks is what
 * that pinned focus does when the thing it is pinned to stops existing.
 *
 * A console that keeps rendering a box which is no longer in the fleet is the
 * same failure as a frozen fleet that looks calm: plausible, wrong, and silent.
 */
const { chromium } = require('playwright-core');
const fs = require('fs');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , url, rosterFile, USER, PASS] = process.argv;

let failed = 0;
const ok = (name, cond, detail = '') => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${!cond && detail ? '  — ' + String(detail).slice(0, 160) : ''}`);
  if (!cond) failed++;
};

(async () => {
  const original = fs.readFileSync(rosterFile, 'utf8');
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    httpCredentials: { username: USER, password: PASS },
  });
  const page = await ctx.newPage();
  page.on('dialog', (d) => d.accept());

  try {
    await page.goto(url, { waitUntil: 'load' });
    await page.waitForTimeout(3500);
    ok('churn: page starts LIVE', (await page.locator('.demo-badge.live').count()) > 0);

    // Stand in the first cell's console — where the first cell IS comes from
    // the floor's own layout hook, not a re-derivation of its constants.
    const c0 = await page.evaluate(() => {
      const g = window.FLOORDEV.grid();
      return { x: g.cell[0].x + g.tw / 2, y: g.cell[0].y + g.th / 2 };
    });
    await page.mouse.click(c0.x, c0.y);
    await page.waitForTimeout(900);
    const focused = (await page.locator('#c-target').textContent()).replace('▸ MESSAGE ', '').trim();
    ok('churn: a console is open', (await page.locator('body.room').count()) === 1, focused);

    // Now delete that box from the roster, exactly as an operator editing
    // fleet.roster would, and let the collector's next poll pick it up.
    const kept = original.split('\n').filter((l) => !l.trim().startsWith(focused));
    fs.writeFileSync(rosterFile, kept.join('\n'));
    console.log(`  (removed ${focused} from the roster; waiting for a poll)`);

    let gone = false;
    for (let i = 0; i < 20; i++) {
      await page.waitForTimeout(2000);
      const inFleet = await page.evaluate(async (name) => {
        const r = await fetch(location.origin + '/api/fleet');
        return (await r.json()).units.some((u) => u.box === name);
      }, focused);
      if (!inFleet) { gone = true; break; }
    }
    ok('churn: collector drops the removed box', gone, 'still present after 40s');

    /* Poll until the page reacts rather than sleeping past one poll interval:
       an 18s wait against a 15s poll is a margin that a slow CI runner eats. */
    for (let i = 0; i < 20; i++) {
      await page.waitForTimeout(2000);
      const v = await page.evaluate(() => document.body.className);
      if (v === 'floor') break;                 // bounced — the reaction we expect
    }

    const state = await page.evaluate(() => ({
      view: document.body.className,
      target: document.getElementById('c-target').textContent,
      status: (document.getElementById('livestat') || {}).textContent || '',
      current: document.getElementById('w-current').textContent.replace(/\s+/g, ' '),
      vitals: document.getElementById('w-vitals').textContent.replace(/\s+/g, ' '),
    }));

    // Either acceptable outcome: bounced back to the floor, or still in the
    // room but SAYING the box is gone. What must not happen is a console that
    // looks like a healthy, quiet box.
    const bounced = state.view === 'floor';
    const admits = /no longer in the fleet|removed|not in the roster|gone/i.test(
      state.status + ' ' + state.current + ' ' + state.vitals);
    ok('churn: the page does not show a phantom box', bounced || admits,
       `view=${state.view} status="${state.status}" current="${state.current}"`);
    // Bouncing silently would be its own small mystery ("why am I on the
    // floor?"), so the reason has to name the box that went away.
    ok('churn: it says WHICH box went away', state.status.includes(focused),
       `status="${state.status}"`);
    // And the floor must still be usable, not left holding a stale unit.
    const stillListed = await page.evaluate((n) => {
      const t = document.getElementById('opslist');
      return t ? t.textContent.includes(n) : false;
    }, focused);
    ok('churn: the removed box is gone from active operations', !stillListed, focused);

    await page.screenshot({ path: (process.env.SHOT_DIR || '/tmp') + '/churn-after-removal.png' });
  } finally {
    fs.writeFileSync(rosterFile, original);
    await browser.close();
  }

  console.log(`  -- churn: ${failed ? failed + ' failed' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('CHURN HARNESS ERROR:', e.message); process.exit(2); });
