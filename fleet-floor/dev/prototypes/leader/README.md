# leader — "CAPTAIN" (LD-01) · prototype A

Standing-look prototype for the **leader (foreman) agent** of crew#225. The
first **role droid**: its identity is the chair, not a vendor — so it wears
no vendor colour anywhere. Command brass and a crimson sash are the role's
own palette.

Open `proto-a-captain.html` in a browser (working / idle / offline buttons
under the canvas; `?state=X&t=N` renders a deterministic still).

## The concept

A captain at **parade rest**: legs planted shoulder-width, arms clasped
behind the back, chin up. The leader never writes code, so it carries no
tools — the silhouette is chest, boards and cap.

- **The cap is armour, not a hat** — the crown, the brass-corded band, the
  laurel-and-star crest and the glossy visor bill are all helmet plates.
  It is the one shape that reads LEADER at grid-cell size.
- **Greatcoat torso** — double row of brass closure studs, service ribbons
  over the left breast, a crimson command sash shoulder-to-hip, brass
  buckle with the command star.
- **Stepped shoulder boards** with four rank bars riding squared pauldrons.
- **War-veteran grammar** (the fleet's standing art rule): squared jaw
  guard with vent grille, cheek plates with a scar, gouged coat hem,
  chipped cap crown, crimson officer stripes down the trouser seams.
- **Offline it stays at attention** — a captain does not slump. The crest
  dies, the optics go dark, the service beacon rakes the cap.

Written in the fleet-floor grammar — canvas 2D, `plate()`/rim/emissive
buffers, no assets, no deps — so it ports into a `buildLeader()` in
`fleet-floor/src/app.js` the way JUGGERNAUT ported into `buildKimi()`.

## Renders

| working | idle | offline |
|---|---|---|
| ![working](renders/A-working.png) | ![idle](renders/A-idle.png) | ![offline](renders/A-offline.png) |
