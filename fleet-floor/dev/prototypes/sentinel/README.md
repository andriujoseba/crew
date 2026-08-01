# sentinel — "SQUIDDY" (SN-100) · prototype C

Standing-look prototype for the **sentinel ops role** of crew#128. A **role
droid** like the leader: no vendor colour — the sentinel's palette is red,
full stop.

**Current: `proto-c-squiddy.html`** (working / idle / offline buttons under
the canvas; `?state=X&t=N` renders a deterministic still). Drawn against the
actual Matrix sentinel reference the operator supplied, then taken through
**ten render loops** — five structural, five detail — against
`~/pw-harness/droids.js`.

Two earlier rounds are kept as history: `proto-a-argus.html` (a smooth bell
— *soft, not scary*) and `proto-b-warform.html` (an angular crab shield —
*worse, not the movie shape*).

## The concept

**It flies.** Alive it hovers with nothing touching the deck, holding
station on a slow figure-of-eight drift, one soft shadow pooled far below.
Dead it is on the floor. (The earlier coil-stack "feet" are gone — a
sentinel that stands on furniture isn't a sentinel.)

- **A squared, wide, squat, symmetric skull.** Two round bumps over a
  notch read as a backside at any size, so the crown is cut like a
  machined casting: a narrow steep notch on the centre line, a nearly
  **flat plateau** across each hump, and a **hard shoulder corner** into
  the flank. Corners are filleted with small radii up top so they stay
  crisp, and generous radii round the chin where the casting really is
  round.
- **The base shape.** The shape comes from danmt's blue
  overlay on PR #230 — traced out of the screenshot pixel by pixel and
  mapped into canvas space through the eye cluster (kept as `TARGET` /
  `target-outline.json`; render with `?outline=1` to see it). But the
  trace is the *intent*, not the geometry: a freehand line is asymmetric,
  and shipping that wobble literally was its own mistake. So the head is
  authored as a symmetric **half-profile, mirrored** — `HALF[]` in the
  source — pulled wider and flatter than the trace, with the saddle dip
  cut to about a third of what the trace showed. ~202 x 124.
- **The head stays at 1:1 and is the small end of the unit.** The whips
  are the mass and own the frame. They are drawn as real **tapered tubes**
  — a body polygon down both offsets of the spine, lit crown, shadowed
  belly, cross-stroke ribs — because at this gauge a row of ellipses
  stops overlapping cleanly and the limb comes out scalloped like a
  feather.
- **The root hub is an assembly, not a plinth**: an armoured collar under
  the chin, a ribbed drum with a caged lit core, outboard mount ears,
  slung hoses and bolts.
- **Front limbs are mounted in the open; back limbs are not.** The same
  division codex uses for its legs. Eight whips run out from *behind* the
  hull with the hub covering where they meet it — no attachment to sell.
  The **four in front** each get a real mechanism: a bolted mount plate,
  a dark socket cup with a **ball joint** and its lit crescent, a clamp
  collar biting the limb's first segment, a stub ram (sleeve, then
  polished rod) and a feed line off the drum. The mount is drawn *after*
  its limb so it visibly clamps it. Eight sockets along the drum's lower
  edge account for the back limbs.
- **Nothing under the chin reads as a mouth.** Tapered spikes along a jaw
  line are teeth, and lit edges on them are a grin. What hangs there is a
  cluster of short matte manipulator stubs at mixed depths and gauges,
  with no highlight on any of them, sitting in their own shadow.
- **Volume, not a mask**: one modelling pass clipped to the silhouette
  puts the highlight on the left-of-centre crown and drives a terminator
  down the right flank, so the head turns away from the light at its own
  edges instead of sitting flat.
- **Fifteen glossy red berry-eyes in chrome sockets**, different sizes,
  packed across a deep recessed face bowl. Each has its own glint,
  shimmer clock and socket polish; a scan wave sweeps them when working.
  One is **dead and cracked**. Offline they all go to dead glass and keep
  their glints — worse.
- **A fringe of tapered mandible fangs** under the jaw, curling inward,
  each on its own twitch clock, each with a lit honed edge.
- **Machine surface**: louvre bank on the left lobe, bolted inspection
  hatch on the right, panel lines crossing the seams, rivets, seam
  cracks, a crown gouge, cheek scorch.
- **A dozen ribbed whips** — lit crown, shadowed belly — S-curving in
  every direction, tipped with three-prong grapple claws with red sensor
  hubs. One thrown high past the skull, one reaching forward-down.
- **Offline**: the hull drops to the deck, every whip crumples at its own
  height and folds back on itself, the grapples close, and the service
  beacon rakes the lobe arris and the brow lip.

Written in the fleet-floor grammar — canvas 2D, `plate()`/rim/emissive
buffers, no assets, no deps — so it ports into a `buildSentinel()` in
`fleet-floor/src/app.js` the way JUGGERNAUT ported into `buildKimi()`.

## The room — the static gallery

![the gallery](renders/room-gallery.png)

A dead monitoring room. Same checklist as the bridge, answered in the
negative at every point — this room's equivalent of a lit `SECTOR-7` board is
a board with half its tube gone.

- **Sixteen screens on rack uprights, every one showing snow.** Each has its
  own roll speed, phase and drift so the wall never reads as tiled wallpaper,
  plus a sweeping roll bar, scanlines, tube vignetting, a raking glass
  highlight, and its own weak spill into the room
- **`MON-4 / SIGNAL GALLERY · NO FEED`** — guttering, half the fitting dark
- **One tube cracked and dead**: a black face with a star fracture
- **Tape labels** on every third bezel — somebody's job, once
- **The operator's station, empty**: a shelf, a dead console with one pilot
  light, and the chair pushed back and turned away
- **One failing ceiling tube** strobing on a hard beat — the only cool light
  in the room that is not a dead signal
- **Cable spaghetti** pooling on the deck and running off-frame, a dumped
  coil, and the wall returned by the floor as blurred smears
- **Framed opening** and vignette, matching the bridge's treatment

The noise is one shared 64px tile sampled per screen — sixteen live noise
canvases a frame would cost more than the unit does.

## Round 5 — ten loops on detail, not on composition

Same diagnosis as the flag bridge, further along. The hall was `#05070b` top
to bottom and every fitting in it drawn at alpha `0.05`–`0.26`, so the room
was a black field with screens floating on it. Here the logic is even simpler
than on the bridge: **the screens are the room's light**, so the wall has to
be a surface they can visibly fall on.

1. **The grade** — base value up, a cold key from the screen wall itself,
   occlusion into the corners.
2. **The monitors** — twenty-four of these are the room's signature prop and
   each was a rectangle of noise with a 1px stroke: they read as paper tiles
   glued to a wall. Now a moulded case with a lit top and shadowed chin, a
   bezel with real depth, a **curved** glass face (the highlight bends, which
   is the one cue that separates a screen from a printed rectangle), corner
   screws, a tally lamp and a worn tape label.
3. **The racks** — the uprights were 12px black bars drawn *after* the
   screens, so the structure crossed in front of the monitors it was holding.
   Rebuilt as 19" rack steel with a punched hole column and a shelf rail per
   row, drawn **first** so the screens sit in front of it.
4. **What is on the screens** — twenty-four identical fields of snow read as
   one texture. A gallery that has lost its feeds still varies in *how* each
   one failed: colour bars, a frozen test card, a camera still limping along
   in another room, some gone to black, one over-driven.
5. **The light** — the ceiling fitting was a flat bar; now a real batten with
   end caps, suspension drops and a wire guard. And the wall of televisions
   now washes the steel it is bolted to, flickering.
6. **The cabling** — a signal gallery *is* its cabling and this room had two
   hairlines. Vertical looms down the rack bays, zip-tie clamps, and four
   passes per run so a cable has a crown, a belly and a shadow.
7. **The signage board** — `MON-4` was a 34px sliver at alpha `0.14`; the room
   was effectively unnamed. Built to the bridge's spec, but **failing**: half
   the backlight is dead and the whole sign guts. Placement corrected twice —
   the grade's own corner occlusion ate it at `x=44`, and it collided with the
   top row of monitors at `y=36`.
8. **The operator's station and the door** — the one piece of human furniture
   was five flat rectangles; it carries the story, so the desk, the still-live
   console, the shoved-aside keyboard and the cold mug all had to read. The
   door was three black rectangles — the second-largest object in frame — and
   now has a flanged frame, jamb bolts, a dogging lever and a compartment
   number.
9. **The patch panel** — outside the screens the room had no local colour at
   all. Drilled jack field, per-row tallies, and patch leads in saturated
   sleeve colours with real weight and plug bodies.
10. **The deck** — left behind by loop 1, and reflecting none of the
    twenty-four televisions above it. The old reflection pass was a
    `globalAlpha 0.1` source-over wash: invisible, and the wrong operator for
    a reflection, which *adds* light to a surface.

## Renders — proto C

| working | idle | offline |
|---|---|---|
| ![working](renders/C-working.png) | ![idle](renders/C-idle.png) | ![offline](renders/C-offline.png) |

## Prior rounds (superseded)

| B working | B offline | A working |
|---|---|---|
| ![B working](renders/B-working.png) | ![B offline](renders/B-offline.png) | ![A working](renders/A-working.png) |
