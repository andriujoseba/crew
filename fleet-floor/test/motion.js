/* fleet-floor/test/motion.js — the #226 acceptance criteria, held to.
 *
 *   node motion.js <url>            (normally file://.../index.html — DEMO's
 *                                    roster is static, which is exactly the
 *                                    "stable roster" the claims are about)
 *
 * The conference cell's portrait layer claims four checkable behaviors since
 * the deterministic-still redesign:
 *
 *   1. STEADY STATE IS FREE — with a stable roster, zero portrait builds per
 *      second once the cache is warm. The old design rebuilt every visible
 *      portrait every 0.3-3.5s; camstats().buildsLastSec is the receipt.
 *   2. MOTION IS BOUNDED — no portrait teleports. Between consecutive floor
 *      frames the portrait region's best vertical alignment never moves a
 *      whole pixel; the life is a sub-pixel composite-time bob. (Glitch
 *      artifacts are horizontal or local, so this metric does not see them —
 *      by construction the declared-glitch exemption is structural.)
 *   3. DEV RENDERS ARE DETERMINISTIC — renderMini twice with the same
 *      (unit, state, size, t) is byte-identical, and the forced-build path
 *      still bypasses the frame budget (a whole map renders in one call).
 *   4. REDUCED MOTION IS STILL — under prefers-reduced-motion the portrait
 *      region is static between frames: no bob, no glitch beats.
 */
const { chromium } = require('playwright-core');

const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
const [, , url] = process.argv;

let failed = 0;
const ok = (name, cond, detail = '') => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${!cond && detail ? '  — ' + String(detail).slice(0, 170) : ''}`);
  if (!cond) failed++;
};

(async () => {
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));
  await page.goto(url, { waitUntil: 'load' });
  // Warm: every visible still builds within a few frames (CAM_BUDGET-throttled).
  await page.waitForTimeout(2500);

  // ---- 1. zero steady-state builds ----
  const builds = await page.evaluate(() => new Promise((res) => {
    const s = [];
    const tick = () => {
      s.push(window.FLOORDEV.camstats().buildsLastSec);
      if (s.length < 4) setTimeout(tick, 700); else res(s);
    };
    setTimeout(tick, 1200); // past the last warm-up build's 1s window
  }));
  ok('steady state: zero portrait builds with a stable roster',
    builds.every((n) => n === 0), 'buildsLastSec samples: ' + builds.join(','));
  const stats = await page.evaluate(() => window.FLOORDEV.camstats());
  ok('camstats reports a warm cache', stats.cacheSize > 0, JSON.stringify(stats));

  // ---- 2. bounded motion on working + idle tiles ----
  const motion = await page.evaluate(() => new Promise((res) => {
    const D = window.FLOORDEV, g = D.grid();
    const cv = document.getElementById('scene'), c2 = cv.getContext('2d');
    const dpr = cv.width / innerWidth;
    // upper-centre of the tile: portrait, clear of every overlay group
    const regs = [0, 2].map((i) => ({
      x: Math.round((g.cell[i].x + g.tw * 0.30) * dpr), y: Math.round((g.cell[i].y + g.th * 0.16) * dpr),
      w: Math.round(g.tw * 0.40 * dpr), h: Math.round(g.th * 0.38 * dpr),
    }));
    const lum = (d, w, x, y) => { const k = (y * w + x) * 4; return d[k] * 0.5 + d[k + 1] + d[k + 2] * 0.25; };
    const prev = new Map(); const shifts = [[], []]; const deltas = [[], []];
    let n = 0;
    (function step() {
      regs.forEach((r, ri) => {
        const cur = c2.getImageData(r.x, r.y, r.w, r.h).data, pv = prev.get(ri);
        if (pv) {
          let ch = 0;
          for (let k = 0; k < cur.length; k += 16)
            if (Math.abs(cur[k] - pv[k]) + Math.abs(cur[k + 1] - pv[k + 1]) + Math.abs(cur[k + 2] - pv[k + 2]) > 30) ch++;
          let best = 0, bestSad = Infinity;
          for (let s = -8; s <= 8; s++) {
            let sad = 0, cnt = 0;
            for (let y = 10; y < r.h - 10; y += 3) for (let x = 2; x < r.w - 2; x += 5) { sad += Math.abs(lum(cur, r.w, x, y) - lum(pv, r.w, x, y + s)); cnt++; }
            sad /= cnt; if (sad < bestSad) { bestSad = sad; best = s; }
          }
          shifts[ri].push(best); deltas[ri].push(ch);
        }
        prev.set(ri, cur);
      });
      if (++n < 100) requestAnimationFrame(step); else res({ shifts, deltas });
    })();
  }));
  motion.shifts.forEach((sh, ri) => {
    const maxSh = Math.max(...sh.map(Math.abs));
    ok(`bounded motion: tile ${ri === 0 ? 0 : 2} never jumps a whole pixel between frames`,
      maxSh === 0, `max |shift| = ${maxSh}px over ${sh.length} frames`);
  });
  ok('the working portrait actually moves (composite bob is alive)',
    motion.deltas[0].filter((d) => d > 0).length > 10,
    `frames with change: ${motion.deltas[0].filter((d) => d > 0).length}`);

  // ---- 3. renderMini determinism + forced-build path ----
  const mini = await page.evaluate(() => {
    const D = window.FLOORDEV;
    const draw = () => {
      const c = document.createElement('canvas'); c.width = 960; c.height = 600;
      D.renderMini(c, { agent: 'grok', room: 'builder', state: 'working', t: 8.0, box: 'motion-golden' });
      return c;
    };
    const a = draw(), b = draw();
    const da = a.getContext('2d').getImageData(0, 0, 960, 600).data;
    const db = b.getContext('2d').getImageData(0, 0, 960, 600).data;
    let diff = 0;
    for (let i = 0; i < da.length; i++) if (da[i] !== db[i]) diff++;
    // forced-build proof: an unseen box must land its portrait THIS call —
    // sample the face region for non-backdrop pixels
    let lit = 0;
    for (let y = 150; y < 400; y += 4) for (let x = 380; x < 580; x += 4) {
      const k = (y * 960 + x) * 4;
      if (da[k] + da[k + 1] + da[k + 2] > 90) lit++;
    }
    return { diff, lit };
  });
  ok('renderMini is deterministic for fixed (unit, state, size, t)', mini.diff === 0,
    mini.diff + ' bytes differ');
  ok('renderMini forced-build path bypasses the frame budget', mini.lit > 40,
    'portrait region looks like backdrop: ' + mini.lit + ' lit samples');

  ok('no page errors', pageErrors.length === 0, pageErrors.join(' | '));
  await ctx.close();

  // ---- 4. reduced motion: portrait static between frames ----
  const rctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1, reducedMotion: 'reduce',
  });
  const rpage = await rctx.newPage();
  await rpage.goto(url, { waitUntil: 'load' });
  await rpage.waitForTimeout(2500);
  const still = await rpage.evaluate(() => new Promise((res) => {
    const D = window.FLOORDEV, g = D.grid();
    const cv = document.getElementById('scene'), c2 = cv.getContext('2d');
    const dpr = cv.width / innerWidth;
    const r = { x: Math.round((g.cell[0].x + g.tw * 0.30) * dpr), y: Math.round((g.cell[0].y + g.th * 0.16) * dpr),
                w: Math.round(g.tw * 0.40 * dpr), h: Math.round(g.th * 0.38 * dpr) };
    const grab = () => c2.getImageData(r.x, r.y, r.w, r.h).data;
    const frames = [];
    let n = 0;
    (function step() {
      frames.push(grab());
      if (++n < 30) requestAnimationFrame(step);
      else {
        let ch = 0;
        for (let f = 1; f < frames.length; f++) {
          const a = frames[f], p = frames[f - 1];
          for (let k = 0; k < a.length; k += 16)
            if (Math.abs(a[k] - p[k]) + Math.abs(a[k + 1] - p[k + 1]) + Math.abs(a[k + 2] - p[k + 2]) > 30) ch++;
        }
        res(ch);
      }
    })();
  }));
  ok('reduced motion: portrait region is static (no bob, no glitch beats)', still === 0,
    still + ' changed samples across 30 frames');
  await rctx.close();

  await browser.close();
  console.log(`-- motion: ${failed ? failed + ' FAILED' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('motion.js crashed:', e); process.exit(1); });
