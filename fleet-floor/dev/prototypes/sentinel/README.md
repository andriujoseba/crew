# sentinel — "SQUIDDY" (SN-100) · prototype C

Standing-look prototype for the **sentinel ops role** of crew#128. A **role
droid** like the leader: no vendor colour — the sentinel's palette is red,
full stop.

**Current: `proto-c-squiddy.html`** (working / idle / offline buttons under
the canvas; `?state=X&t=N` renders a deterministic still). Drawn against the
actual Matrix sentinel reference (the Hot Toys 1/16 still and the fan render
the operator supplied) after two misses:

- `proto-a-argus.html` — smooth bell, eyes scattered politely. Verdict:
  *soft, not scary, not dangerous.*
- `proto-b-warform.html` — angular crab shield with thick jointed arms.
  Verdict: *worse — not the movie shape.*

## The concept (C)

What the reference actually is, honoured in the fleet grammar:

- **A bulbous skull pod**, not a bell and not a shield — overlapping
  organic shell lobes with seam cracks and rivets, hook-barb antennae on
  the crown, side sensor pods, a gouge across the left lobe, scorch up
  the right cheek.
- **The eyes are glossy red BERRIES in chrome sockets** — fifteen of
  them, different sizes, wrapped across a dark recessed face like spider
  eyes, each with its own specular glint and its own shimmer clock. One
  is **dead and cracked** and stays that way. Offline they all go to
  dead glass — and keep their glints, which is worse.
- **A fringe of small mandible claws** twitching under the chin.
- **A dozen long thin ribbed whips** — segmented conduit, S-curving in
  every direction, never straight, each tipped with a **three-prong
  grapple claw** with a red sensor. Standing translation of a thing
  that flies: it **perches on two of its own coiled whip-stacks** like a
  snake standing on its body; one strike whip hovers its grapple over
  the deck, one curls high past the skull, the rest flare around it.
- **Offline** the coils flatten, every whip falls and lies where it
  lands, the grapples close.

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
