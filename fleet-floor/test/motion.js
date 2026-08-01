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

  // ---- 2. bounded motion on working + idle + offline tiles ----
  // DEMO roster: 0 = claude/triage/working, 2 = claude/reviewer/idle,
  // 6 = kimi/reviewer/offline (the roll is a declared artifact; it copies a
  // band sideways and never translates the portrait, so the vertical
  // alignment metric holds for it too).
  const TILES = [0, 2, 6];
  const motion = await page.evaluate((tiles) => new Promise((res) => {
    const D = window.FLOORDEV, g = D.grid();
    const cv = document.getElementById('scene'), c2 = cv.getContext('2d');
    const dpr = cv.width / innerWidth;
    // upper-centre of the tile: portrait, clear of every overlay group
    const regs = tiles.map((i) => ({
      x: Math.round((g.cell[i].x + g.tw * 0.30) * dpr), y: Math.round((g.cell[i].y + g.th * 0.16) * dpr),
      w: Math.round(g.tw * 0.40 * dpr), h: Math.round(g.th * 0.38 * dpr),
    }));
    const lum = (d, w, x, y) => { const k = (y * w + x) * 4; return d[k] * 0.5 + d[k + 1] + d[k + 2] * 0.25; };
    const prev = new Map(); const shifts = regs.map(() => []); const deltas = regs.map(() => []);
    let n = 0, lastT = 0;
    (function step(ts) {
      // A stalled RAF (loaded CI box) legitimately accumulates more than a
      // frame of bob; the criterion is per-FRAME, so a long gap is exempt.
      const gap = lastT && ts - lastT > 80; lastT = ts;
      regs.forEach((r, ri) => {
        const cur = c2.getImageData(r.x, r.y, r.w, r.h).data, pv = prev.get(ri);
        if (pv && !gap) {
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
    })(0);
  }), TILES);
  motion.shifts.forEach((sh, ri) => {
    const maxSh = Math.max(...sh.map(Math.abs));
    ok(`bounded motion: tile ${TILES[ri]} never jumps a whole pixel between frames`,
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
      return c.getContext('2d').getImageData(0, 0, 960, 600).data;
    };
    const da = draw(), db = draw();
    let diff = 0;
    for (let i = 0; i < da.length; i++) if (da[i] !== db[i]) diff++;
    // The second draw above is a cache HIT — identical bytes prove the
    // overlays, not the still. Evict the golden's key through the LRU (the
    // cache keeps ~64 entries; small dummies build fast) and draw again: a
    // REBUILT still must reproduce, which is the tCanon/beaconPulse pinning
    // actually under test.
    for (let i = 0; i < 80; i++) {
      const c = document.createElement('canvas'); c.width = 96; c.height = 60;
      D.renderMini(c, { agent: 'claude', room: 'triage', state: 'idle', t: 8.0, box: 'evict-' + i });
    }
    const dc = draw();
    let rediff = 0;
    for (let i = 0; i < dc.length; i++) if (da[i] !== dc[i]) rediff++;
    // forced-build proof: an unseen box must land its portrait THIS call —
    // sample the face region for non-backdrop pixels
    let lit = 0;
    for (let y = 150; y < 400; y += 4) for (let x = 380; x < 580; x += 4) {
      const k = (y * 960 + x) * 4;
      if (da[k] + da[k + 1] + da[k + 2] > 90) lit++;
    }
    return { diff, rediff, lit };
  });
  ok('renderMini is deterministic for fixed (unit, state, size, t)', mini.diff === 0,
    mini.diff + ' bytes differ');
  ok('a REBUILT still reproduces (cache evicted between draws)', mini.rediff === 0,
    mini.rediff + ' bytes differ after eviction');
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
  // Working tile 0 (bob + beats must be off) and offline tile 6 (the roll
  // and grain must be pinned, not wandering).
  const still = await rpage.evaluate(() => new Promise((res) => {
    const D = window.FLOORDEV, g = D.grid();
    const cv = document.getElementById('scene'), c2 = cv.getContext('2d');
    const dpr = cv.width / innerWidth;
    const regs = [0, 6].map((i) => ({
      x: Math.round((g.cell[i].x + g.tw * 0.30) * dpr), y: Math.round((g.cell[i].y + g.th * 0.16) * dpr),
      w: Math.round(g.tw * 0.40 * dpr), h: Math.round(g.th * 0.38 * dpr) }));
    const frames = regs.map(() => []);
    let n = 0;
    (function step() {
      regs.forEach((r, ri) => frames[ri].push(c2.getImageData(r.x, r.y, r.w, r.h).data));
      if (++n < 30) requestAnimationFrame(step);
      else {
        res(frames.map((fr) => {
          let ch = 0;
          for (let f = 1; f < fr.length; f++) {
            const a = fr[f], p = fr[f - 1];
            for (let k = 0; k < a.length; k += 16)
              if (Math.abs(a[k] - p[k]) + Math.abs(a[k + 1] - p[k + 1]) + Math.abs(a[k + 2] - p[k + 2]) > 30) ch++;
          }
          return ch;
        }));
      }
    })();
  }));
  ok('reduced motion: working portrait is static (no bob, no glitch beats)', still[0] === 0,
    still[0] + ' changed samples across 30 frames');
  ok('reduced motion: offline roll and grain are pinned', still[1] === 0,
    still[1] + ' changed samples across 30 frames');
  await rctx.close();

  await browser.close();
  console.log(`-- motion: ${failed ? failed + ' FAILED' : 'all ok'}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('motion.js crashed:', e); process.exit(1); });
