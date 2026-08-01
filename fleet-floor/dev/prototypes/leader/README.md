# leader — "ADMIRAL" (LD-01) · prototype A

Standing-look prototype for the **leader (foreman) agent** of crew#225. The
first **role droid**: its identity is the chair, not a vendor — so it wears
no vendor colour anywhere. Antique command brass is the role's palette.

Open `proto-a-admiral.html` in a browser (working / idle / offline buttons
under the canvas; `?state=X&t=N` renders a deterministic still).

## The concept

An admiral at **parade rest**: legs planted shoulder-width, arms clasped
behind the back, chin up. The leader never writes code, so it carries no
tools — the silhouette is chest, boards and cap.

Operator direction, revision one: the crimson command sash read *dictator*
and is gone. Rank now lives where a flag officer carries it — the cap, the
boards, and gold oak-leaf filigree on the bill — and the surface carries
the wars instead:

- **The cap is armour, not a hat** — crown, brass-corded band and
  laurel-and-star crest are helmet plates; the glossy bill wears the
  admiral's scrambled eggs and has a **notch shot out of its edge**
- **Hard slit optics** under the bill, lids cut on the glare angle; a
  **crack runs from the bill notch through the visor glass to the cheek**
- Greatcoat torso: double brass closure studs, **eight dulled service
  ribbons (one half torn away)**, a bent-wing breast crest, and a
  **bead-welded replacement plate** that doesn't quite match the coat
- Stepped shoulder boards with four rank bars — the **left board's brass
  edge broken by an old hit**; grime weeps from the pauldron bolts
- Scorched coat hem, patched thigh armour, scuffed boot braid, chipped
  boots — worn gold trouser stripes in place of the old crimson
- **The chassis shows at every joint** (revision two): power cables
  looping out of the collar and diving into the lower back, twin
  head-tilt pistons at the neck, hydraulic rams down each upper arm,
  true elbow joints (ring, hub bolt, guard horn, grease weep), hoses
  swinging under the arm pits, hip coil shocks and actuator rods on the
  pelvis, outboard knee springs, return hoses down the calves, ribbed
  ankle gaiters, intake gills low on the coat sides
- **Chad geometry** (revision three, against claude's unit as the
  benchmark): a faceted chest — raised centre slab with the side panels
  angled away from it, so light breaks over three planes; big trapezoid
  pauldrons that drape down over the arms rather than jutting out level;
  wider boards, chunkier thighs and boots with their own toe caps; a
  head and cap scaled up to hold against the shoulders
- **Surface**: rivet rows down both coat seams, intake grilles on the
  flanks (clear of the stud rows), knee bolts, grime weeps
- **Offline it stays at attention** — an admiral does not slump; the
  crest dies, the optics go dark, the service beacon rakes the cap

Written in the fleet-floor grammar — canvas 2D, `plate()`/rim/emissive
buffers, no assets, no deps — so it ports into a `buildLeader()` in
`fleet-floor/src/app.js` the way JUGGERNAUT ported into `buildKimi()`.

## The room — the flag bridge

The leader stands where a battleship is commanded from: an armoured gallery
with a raked window band looking out on deep nothing, riveted plate courses,
deckhead beams, repeater dials down one bulkhead, a chart board on the other,
and a **plot table off to port throwing its light up into the room** — a
second, lower light source so the unit is not lit only from overhead. Graded
entirely to command brass. Drawn behind and around the unit, never across its
silhouette, with one blurred stanchion in the foreground for depth.

## Renders

| working | idle | offline |
|---|---|---|
| ![working](renders/A-working.png) | ![idle](renders/A-idle.png) | ![offline](renders/A-offline.png) |
