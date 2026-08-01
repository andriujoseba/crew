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

- **A bilobed cranium**, drawn to the operator's own outline (the blue
  overlay on PR #230): **two humps with a saddle dipping between them**,
  flanks bulging out and down, the mass tapering to a rounded chin. That
  dip is the whole shape — a flat oval carapace over a straight brow bar
  reads as a *tick*, which is what the previous revision was. The brow is
  therefore not one horizontal ledge but **two ridges, one per lobe**,
  meeting in the saddle and throwing a **V** of shadow into the eye field.
  The face bowl follows the organic outline instead of being a hexagon.
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

## Renders — proto C

| working | idle | offline |
|---|---|---|
| ![working](renders/C-working.png) | ![idle](renders/C-idle.png) | ![offline](renders/C-offline.png) |

## Prior rounds (superseded)

| B working | B offline | A working |
|---|---|---|
| ![B working](renders/B-working.png) | ![B offline](renders/B-offline.png) | ![A working](renders/A-working.png) |
