/* fleet-floor/dev/whiteboard.js — the asset map.
 *
 * Every agent x room x state the renderer can produce, laid out as one grid:
 * agents across, room-and-state down. Nothing here draws a robot or a room —
 * it calls window.FLOORDEV.render, which is the same drawTarget the shipped
 * room view calls. That is the whole point. An asset map with its own copy of
 * the art agrees with the app only until one of them is edited, and then it
 * quietly certifies the wrong picture.
 *
 * Deterministic on purpose: the flicker, the rack LEDs and the film grain all
 * pull Math.random, so it is replaced with a seeded PRNG and re-seeded per
 * tile. The same commit renders the same PNG twice, and a pixel that moved
 * between two runs moved because the code moved.
 *
 * Query params (all optional):
 *   ?agents=claude,codex  ?rooms=builder  ?states=working  — slice the grid
 *   ?w=640                                                 — tile width
 *   ?t=8                                                   — animation time, seconds
 *   ?flat=1                                                — skip the chromatic split
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
  var T = q.get('t') === null ? 8 : Number(q.get('t'));
  var FLAT = q.get('flat') === '1';

  /* Seeded PRNG. Every tile starts from a seed derived from WHAT it is, not
     from how many tiles came before it, so slicing the grid with ?agents= does
     not change the tiles that remain. */
  var seed = 1;
  Math.random = function () {
    seed = (seed + 0x6D2B79F5) >>> 0;
    var t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  var seedFor = function (s) { var h = 2166136261; for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; };

  var root = document.getElementById('wb');
  var head = document.createElement('div');
  head.className = 'wb-head';
  head.innerHTML = '<h1>FLEET FLOOR · ASSET MAP</h1><p>' +
    AGENTS.length + ' agents × ' + ROOMS.length + ' rooms × ' + STATES.length + ' states = <b>' +
    (AGENTS.length * ROOMS.length * STATES.length) + '</b> tiles · rendered by <code>FLOORDEV.render</code> — the same <code>drawTarget</code> the app uses · t=' + T + 's</p>';
  root.appendChild(head);

  var grid = document.createElement('div');
  grid.className = 'wb-grid';
  grid.style.gridTemplateColumns = 'var(--rowlab) repeat(' + AGENTS.length + ', ' + TW + 'px)';
  root.appendChild(grid);

  var cell = function (cls, html) { var d = document.createElement('div'); d.className = cls; if (html) d.innerHTML = html; return d; };

  // column header: one per agent
  grid.appendChild(cell('wb-corner'));
  AGENTS.forEach(function (a) { grid.appendChild(cell('wb-colhead wb-' + a, a)); });

  var jobs = [];
  ROOMS.forEach(function (room) {
    STATES.forEach(function (state, si) {
      grid.appendChild(cell('wb-rowhead' + (si === 0 ? ' wb-roomtop' : ''),
        (si === 0 ? '<b>' + room + '</b>' : '') + '<span>' + state + '</span>'));
      AGENTS.forEach(function (agent) {
        var wrap = cell('wb-tile');
        var cv = document.createElement('canvas');
        cv.width = TW; cv.height = TH;
        cv.id = 'tile-' + agent + '-' + room + '-' + state;
        wrap.appendChild(cv);
        wrap.appendChild(cell('wb-cap', agent + ' · ' + room + ' · ' + state));
        grid.appendChild(wrap);
        jobs.push({ cv: cv, agent: agent, room: room, state: state });
      });
    });
  });

  /* Render one tile per animation frame rather than all of them in one go:
     36 full room renders is several seconds of blocked main thread, and a
     screenshot tool that waits for load gets a page of blank canvases. */
  var done = 0;
  var step = function () {
    var j = jobs[done];
    seed = seedFor(j.agent + '|' + j.room + '|' + j.state);
    D.render(j.cv, { agent: j.agent, room: j.room, state: j.state, t: T, flat: FLAT });
    done++;
    if (done < jobs.length) requestAnimationFrame(step);
    else { document.body.dataset.wbDone = '1'; }
  };
  if (jobs.length) requestAnimationFrame(step); else document.body.dataset.wbDone = '1';
})();
