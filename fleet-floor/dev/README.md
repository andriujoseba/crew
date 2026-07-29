# The whiteboard

`dev/whiteboard.html` is the **asset map**: every robot, in every room, in
every state — 4 × 3 × 3 = **36 tiles** — on one page.

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

## It does not own a copy of the art

This is the whole point, so it is worth being blunt about it: **whiteboard.js
draws nothing.** It lays out canvases and calls `FLOORDEV.render`, which calls
the same `drawTarget` in `src/app.js` that the room view calls. `build.sh`
builds `whiteboard.html` from the same `src/` that `index.html` is built from.

There is exactly one claude, one codex, one grok, one kimi, one builder bay,
one review lab and one dispatch room in this repo, and both pages show you
those. An asset map with its own renderer would agree with the app right up
until either was edited, and would then quietly certify a picture nobody ships.

So: **improve a robot in `src/app.js` and it improves everywhere at once** —
the console, the god-view thumbnails, and this map.

## Slicing it

The full 36 takes a few seconds to render — each tile is a complete room. Query
params cut it down, and raise the tile size for close work:

| param | example | what it does |
|---|---|---|
| `agents` | `?agents=codex,kimi` | only these units |
| `rooms` | `?rooms=builder` | only these rooms |
| `states` | `?states=offline` | only these states |
| `w` | `?w=1280` | tile width in px (default 640) |
| `t` | `?t=8` | animation time in seconds |
| `flat` | `?flat=1` | skip the chromatic split |

```
whiteboard.html?agents=grok&rooms=builder&states=working&w=1280
```

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

The same commit therefore renders the same PNG twice, and a pixel that moved
between two runs moved because the code moved. That is what makes a before/after
of these rooms worth looking at.

## The map

[`ASSETMAP.md`](ASSETMAP.md) — the current 36 tiles, as one image.
