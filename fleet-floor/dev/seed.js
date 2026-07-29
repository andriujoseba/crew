/* fleet-floor/dev/seed.js — deterministic Math.random, installed BEFORE app.js.
 *
 * This has to run first, and that is the whole point of it being its own file.
 * app.js builds four things at module load, off Math.random, before any render
 * happens:
 *
 *   noise      a 220x220 film-grain texture, composited into EVERY frame
 *   motes      90 dust particles
 *   steam      26 vent puffs
 *   floorHaze  5 drifting fog bodies
 *
 * whiteboard.js used to install the PRNG itself, but it is a separate <script>
 * that necessarily runs after app.js — so all four were already fixed, from the
 * real Math.random, and differed on every page load. The per-tile seeding
 * underneath was working perfectly and hiding behind a grain texture that was
 * never the same twice: two renders of one commit differed by ~1.8% of pixels,
 * uniformly, across all 36 tiles.
 *
 * That is below the change a real edit makes, so it never produced a wrong
 * conclusion — but it is exactly the noise floor that would swallow the small
 * ones, and "the same commit renders the same image twice" has to be true or
 * the whole before/after method is decoration.
 *
 * Shipped only in dev/whiteboard.html. index.html keeps the real Math.random.
 */
(function () {
  var seed = 0x9e3779b9;
  function rnd() {
    seed = (seed + 0x6D2B79F5) >>> 0;
    var t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  Math.random = rnd;
  /* Re-seed from a string, so a tile's seed comes from WHAT IT IS rather than
     from how many tiles preceded it — slicing the grid with ?agents= then does
     not disturb the tiles that remain. */
  window.__wbseed = function (s) {
    var h = 2166136261;
    s = String(s);
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
    seed = h >>> 0;
  };
})();
