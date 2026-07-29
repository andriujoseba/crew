/* fleet-floor/dev/whiteboard.js — the asset map.
 *
 * Every agent x room x state the renderer can produce, laid out as one grid:
 * agents across, room-and-state down. Nothing here draws a robot or a room —
 * it calls window.FLOORDEV, which is the same drawTarget and the same drawMini
 * the shipped page draws with. That is the whole point. An asset map with its
 * own copy of the art agrees with the app only until one of them is edited,
 * and then it quietly certifies the wrong picture.
 *
 * TWO maps, because the page has two views of a unit and both can be wrong:
 *
 *   room  — the console. FLOORDEV.render, one full room per tile.
 *   cell  — the god-view. FLOORDEV.renderMini, the whole card per tile.
 *
 * The cell map is the one that did not exist. The roster only ever exercises
 * seven of the cell's thirty-six combinations and the rest are unreachable in
 * a healthy fleet, so for fifteen loops the busiest view on the page was the
 * only one nobody could look at — which is exactly where a ghost sign, a desk
 * drawn through everybody's shins and an alert glyph pinned to empty air sat
 * undisturbed until someone patched ROSTER by hand to find them.
 *
 * Deterministic on purpose: the flicker, the rack LEDs and the film grain all
 * pull Math.random, so it is replaced with a seeded PRNG and re-seeded per
 * tile. The same commit renders the same PNG twice, and a pixel that moved
 * between two runs moved because the code moved.
 *
 * Query params (all optional):
 *   ?agents=claude,codex  ?rooms=builder  ?states=working  — slice the grids
 *   ?view=room|cell|both                                   — which maps (both)
 *   ?w=640                                                 — room tile width
 *   ?mw=336                                                — cell tile width
 *   ?t=8                                                   — animation time, seconds
 *   ?flat=1                                                — skip the chromatic split
 *   ?guides=1                                              — draw the declared layout
 */
(function () {
  var D = window.FLOORDEV;
  if (!D) { document.body.innerHTML = '<p style="color:#f66;font:14px monospace;padding:24px">FLOORDEV missing — build from src/ with build.sh</p>'; return; }

  var q = new URLSearchParams(location.search);
  var list = function (k, all) {
    var v = q.get(k); if (!v) return all;
    var want = v.split(',').map(function (s) { return s.trim(); }).filter(Boolean);
    return all.filter(function (x) { return want.indexOf(x) >= 0; });
  };
  var AGENTS = list('agents', D.AGENTS), ROOMS = list('rooms', D.ROOMS), STATES = list('states', D.STATES);
  var TW = Math.max(160, Number(q.get('w')) || 640);
  var TH = Math.round(TW * D.H / D.W);
  var MW = Math.max(160, Number(q.get('mw')) || (D.MINI ? D.MINI.W : 336));
  var MH = D.MINI ? Math.round(MW * D.MINI.H / D.MINI.W) : Math.round(MW * 0.75);
  var T = q.get('t') === null ? 8 : Number(q.get('t'));
  var FLAT = q.get('flat') === '1';
  var GUIDES = q.get('guides') === '1' && typeof D.guides === 'function';
  var VIEW = q.get('view') || 'both';
  var WANT_ROOM = VIEW === 'both' || VIEW === 'room';
  var WANT_CELL = (VIEW === 'both' || VIEW === 'cell') && typeof D.renderMini === 'function';

  /* The PRNG itself lives in dev/seed.js and is installed BEFORE app.js — it
     has to be, because app.js fixes the film grain, the motes, the steam and
     the floor haze at module load. Installing it here, from a script that by
     definition runs after app.js, left those four unseeded and differing on
     every page load. See seed.js. */
  var seedFor = window.__wbseed;
  if (!seedFor) { document.body.innerHTML = '<p style="color:#f66;font:14px monospace;padding:24px">dev/seed.js did not run before app.js — rebuild with build.sh</p>'; return; }

  /* The app is still running underneath — whiteboard.html IS the app plus a
     grid — and it was painting a whole fleet into the hidden stage every
     frame. Harmless when a cell was cheap; not harmless now that a cell
     renders rooms, because the map's tiles would queue behind the hidden
     view's. */
  if (typeof D.pause === 'function') D.pause();

  var root = document.getElementById('wb');
  var jobs = [];

  var cell = function (cls, html) { var d = document.createElement('div'); d.className = cls; if (html) d.innerHTML = html; return d; };

  var head = function (title, sub) {
    var h = document.createElement('div');
    h.className = 'wb-head';
    h.innerHTML = '<h1>' + title + '</h1><p>' +
      AGENTS.length + ' agents × ' + ROOMS.length + ' rooms × ' + STATES.length + ' states = <b>' +
      (AGENTS.length * ROOMS.length * STATES.length) + '</b> tiles · ' + sub + ' · t=' + T + 's</p>';
    root.appendChild(h);
  };

  /* One grid. `draw` is handed the canvas and the combination and is the only
     thing that differs between the two maps. */
  var buildGrid = function (idPrefix, tw, th, draw) {
    var grid = document.createElement('div');
    grid.className = 'wb-grid';
    grid.style.gridTemplateColumns = 'var(--rowlab) repeat(' + AGENTS.length + ', ' + tw + 'px)';
    root.appendChild(grid);

    grid.appendChild(cell('wb-corner'));
    AGENTS.forEach(function (a) { grid.appendChild(cell('wb-colhead wb-' + a, a)); });

    ROOMS.forEach(function (room) {
      STATES.forEach(function (state, si) {
        grid.appendChild(cell('wb-rowhead' + (si === 0 ? ' wb-roomtop' : ''),
          (si === 0 ? '<b>' + room + '</b>' : '') + '<span>' + state + '</span>'));
        AGENTS.forEach(function (agent) {
          var wrap = cell('wb-tile');
          var cv = document.createElement('canvas');
          cv.width = tw; cv.height = th;
          cv.id = idPrefix + agent + '-' + room + '-' + state;
          wrap.appendChild(cv);
          wrap.appendChild(cell('wb-cap', agent + ' · ' + room + ' · ' + state));
          grid.appendChild(wrap);
          jobs.push({ cv: cv, agent: agent, room: room, state: state, draw: draw, seed: idPrefix });
        });
      });
    });
  };

  if (WANT_ROOM) {
    head('FLEET FLOOR · ASSET MAP · ROOM',
      'the console view · rendered by <code>FLOORDEV.render</code> — the same <code>drawTarget</code> the app uses');
    buildGrid('tile-', TW, TH, function (j) {
      D.render(j.cv, { agent: j.agent, room: j.room, state: j.state, t: T, flat: FLAT });
      /* ?guides=1 lays the declared layout over the tile — the reserved sign,
         the free wall bays, the keep-clear column and the deck each room
         already carries. A prop that lands on one is then a visible mistake
         against a stated rule rather than something that looked free. */
      if (GUIDES) D.guides(j.cv, { room: j.room });
    });
  }
  if (WANT_CELL) {
    head('FLEET FLOOR · ASSET MAP · GOD-VIEW CELL',
      'the grid view · rendered by <code>FLOORDEV.renderMini</code> — the same <code>drawMini</code> the fleet grid uses');
    buildGrid('mini-', MW, MH, function (j) {
      D.renderMini(j.cv, { agent: j.agent, room: j.room, state: j.state, t: T });
    });
  }

  /* Render one tile per animation frame rather than all of them in one go:
     72 renders is several seconds of blocked main thread, and a screenshot
     tool that waits for load gets a page of blank canvases. */
  var done = 0;
  var step = function () {
    var j = jobs[done];
    seedFor(j.seed + j.agent + '|' + j.room + '|' + j.state);
    j.draw(j);
    done++;
    if (done < jobs.length) requestAnimationFrame(step);
    else { document.body.dataset.wbDone = '1'; }
  };
  if (jobs.length) requestAnimationFrame(step); else document.body.dataset.wbDone = '1';
})();
