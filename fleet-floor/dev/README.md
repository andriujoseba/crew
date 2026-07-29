# The whiteboard

`dev/whiteboard.html` is the **asset map**: every robot, in every room, in
every state — 4 × 3 × 3 = **36 tiles** — on one page, **twice**: once as the
console renders it, once as the god-view grid renders it. 72 tiles.

Open it. No server, no build tools, no network, same as `index.html`:

```sh
open fleet-floor/dev/whiteboard.html
```

## Why it exists

The robots and the rooms are the hardest part of this page to change safely.
They are drawn procedurally, they only appear a fraction at a time (one unit
per console, one row of thumbnails per floor), and half the states are ones a
healthy fleet never enters — so the way to find out that the offline kimi lost
its face was to break the fleet. The map puts all 36 on one screen, which is
the difference between *checking* a change and *hoping* about it.

## Two maps, because there are two views

| map | hook | draws |
|---|---|---|
| room | `FLOORDEV.render` | the console — one full room per tile |
| cell | `FLOORDEV.renderMini` | the god-view — the whole card per tile |

The cell map is the newer of the two, and it exists because its absence cost
something real. For fifteen loops the room had a map and the cell had none, so
the busiest view on the page — the god-view is what the console opens on — was
also the only one nobody could look at. The roster exercises seven of the
cell's thirty-six combinations; reviewing the other twenty-nine meant patching
`ROSTER` by hand. What sat there undisturbed the whole time was a 7%-opacity
`SECTOR-7` painted straight onto a bare wall, a desk drawn through every
walker's shins, and an alert glyph pinned to the top of the sprite's bounding
box, which is the head for two of the four units and empty air for the other
two.

The cell renders the real room now — same `drawTarget`, cached as a still —
so a room fix reaches it by construction rather than by being ported. The map
is what proves that stayed true.

## It does not own a copy of the art

This is the whole point, so it is worth being blunt about it: **whiteboard.js
draws nothing.** It lays out canvases and calls `FLOORDEV.render` and
`FLOORDEV.renderMini`, which call the same `drawTarget` and the same `drawMini`
in `src/app.js` that the two views call. `build.sh` builds `whiteboard.html`
from the same `src/` that `index.html` is built from.

There is exactly one claude, one codex, one grok, one kimi, one builder bay,
one review lab and one dispatch room in this repo, and both pages show you
those. An asset map with its own renderer would agree with the app right up
until either was edited, and would then quietly certify a picture nobody ships.

So: **improve a robot in `src/app.js` and it improves everywhere at once** —
the console, the god-view thumbnails, and this map.

That sentence was true of the robots and false of the rooms for fifteen loops,
and saying it anyway is how nobody noticed: the god-view cell was a second room
renderer that shared the robot sprite and no room code at all, so wall, sign,
lighting and prop fixes landed in the console and stopped there. The cell draws
the real room now. The claim is structural again rather than aspirational —
and the cell map is what will catch it the next time it stops being true.

## Slicing it

The full 36 takes a few seconds to render — each tile is a complete room. Query
params cut it down, and raise the tile size for close work:

| param | example | what it does |
|---|---|---|
| `agents` | `?agents=codex,kimi` | only these units |
| `rooms` | `?rooms=builder` | only these rooms |
| `states` | `?states=offline` | only these states |
| `view` | `?view=cell` | which maps: `room`, `cell` or `both` (default) |
| `w` | `?w=1280` | room tile width in px (default 640) |
| `mw` | `?mw=672` | cell tile width in px (default 336) |
| `t` | `?t=8` | animation time in seconds |
| `flat` | `?flat=1` | skip the chromatic split |
| `guides` | `?guides=1` | draw the declared layout over each room tile |

```
whiteboard.html?agents=grok&rooms=builder&states=working&w=1280
```

## The layout, drawn

`?guides=1` puts `LAYOUT` on the picture: the reserved sign, the two free wall
bays, the deck each room already carries, the fixed structure, and the **unit
envelope** — the union of `FLOORDEV.unitBox` across all 36 combinations, which
is the alpha extent of the sprite the renderer actually draws rather than a
number somebody estimated.

That distinction is not pedantry. The first hand-written version of the
envelope was 220px wide and wrong twice over: narrower than codex, whose six
legs splay to 273px, and wide enough to overlap the pegboard — a rule invented
to stop collisions, colliding. Writing the deck down found another one the same
afternoon: the builder's conveyor started ten pixels inside the workbench top,
four pixels tall, both surfaces dark, and fifteen loops of looking had not
caught it.

Re-derive the envelope by running the hook; do not nudge it by eye.

## Determinism

The flicker, the rack LEDs and the film grain all pull `Math.random`, so the
whiteboard replaces it with a seeded PRNG and re-seeds per tile from *what the
tile is* — not from how many tiles came before it, so slicing the grid does not
change the tiles that remain. The lamp and the weld sparks are the only state
that survives a frame, and both are reset and warmed a fixed number of frames.

**The PRNG is [`seed.js`](seed.js), and `build.sh` inlines it before `app.js`.
That order is load-bearing.** `app.js` fixes the film-grain texture, the motes,
the steam and the floor haze at module *load*, so a PRNG installed by
`whiteboard.js` — a separate `<script>`, necessarily running after `app.js` —
is already too late for all four. It was, and two renders of one commit
differed by ~1.8% of pixels, uniformly, across all 36 tiles: the per-tile
seeding worked perfectly and hid behind a grain texture that was never the same
twice. Verified after the fix at 0 of 37 images differing.

The cell map needed one more fix of the same shape before it was worth
building: the miniature's offline holo panel flickered off raw `Math.random`,
which is invisible in the app and would have made all twelve offline cell tiles
differ between two renders of one commit. Verified across two browser launches
at **72 of 72 tiles identical**, full-page PNGs sharing a sha256.

The same commit therefore renders the same PNG twice, and a pixel that moved
between two runs moved because the code moved. That is what makes a before/after
of these rooms worth looking at.

## The map

[`ASSETMAP.md`](ASSETMAP.md) — the current 36 tiles, as one image.
[`LOOPS.md`](LOOPS.md) — the fifteen polish loops, each with before/after stills.
[`GIFS.md`](GIFS.md) — baseline to loop 15 as one animation per robot and room.
