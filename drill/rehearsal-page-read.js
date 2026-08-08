/* drill/rehearsal-page-read.js — read the 0.1.2 page surfaces off a rendered
   floor, once, and print them as JSON for rehearsal-app.sh to assert on.
 *
 * IN-TREE ON PURPOSE. This was a heredoc written into `mktemp -d` and run from
 * there, and it could never work: CommonJS resolves `require` from the
 * SCRIPT's directory upward, never from the cwd, so `require('playwright-core')`
 * from /tmp had no path to $ROOT/node_modules — where .gitignore:11,
 * fleet-floor/README.md:247 and shared/docs/rehearsal.md:56 all say the module
 * is installed. The drill's own precondition probe could not catch it either,
 * because `node -e` DOES resolve from the cwd, which on a drill run is $ROOT.
 * The result was two hard FAILs on every host that installs the module where
 * this repo says to (claude-bot, #428). Living beside fleet-floor/test/
 * browser.js — the other node script the drill runs — makes resolution the
 * ordinary chain and needs no NODE_PATH.
 *
 * READ-ONLY. It clicks the two state filter chips, which repaint a canvas
 * scrim, and issues no /api/command request. Its calls appear in the receipt
 * slice rehearsal-app.sh checks after the walk.
 *
 * usage: node drill/rehearsal-page-read.js <url> [user] [pass]
 */
const { chromium } = require('playwright-core');
const [, , url, user, pass] = process.argv;
(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PW_CHROME, headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    httpCredentials: user ? { username: user, password: pass } : undefined,
  });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'load' });
  // Poll for the LIVE flip rather than guessing how long the first poll takes,
  // the same way the walk does: a fixed wait that expires early reads the demo
  // payload and every comparison below is then about the wrong fleet.
  for (let w = 0; w < 12000; w += 250) {
    if ((await page.locator('.demo-badge.live').count()) > 0) break;
    await page.waitForTimeout(250);
  }
  const live = (await page.locator('.demo-badge.live').count()) > 0;
  const tiles = (await page.locator('#tiles').textContent()).replace(/\s+/g, '');
  // #204's empty floor, read BEFORE the chips are touched. syncEmptyFloor keys
  // off ROSTER.length — the drawn set, not the filtered one — so a chip click
  // cannot move it; reading it first means the assertion never has to know
  // that. `on` is the class syncEmptyFloor toggles, and it is the difference
  // between "the panel is there but hidden" and "the operator sees it".
  const empty = await page.evaluate(() => {
    const el = document.getElementById('emptyfloor');
    if (!el) return { present: false, shown: false, text: '' };
    return {
      present: true,
      shown: el.classList.contains('on'),
      text: (el.textContent || '').replace(/\s+/g, ' ').trim(),
    };
  });
  const group = async (v) => {
    await page.locator(`.fchip[data-f="state"][data-v="${v}"]`).click();
    return (await page.evaluate(() => window.FLOORDEV.matched().slice())).sort();
  };
  const disarmed = await group('disarmed');
  const silent = await group('silent');
  await page.locator('.fchip[data-f="state"][data-v="all"]').click();
  console.log(JSON.stringify({ live, tiles, disarmed, silent, empty }));
  await browser.close();
})().catch((e) => { console.error(String((e && e.message) || e)); process.exit(1); });
