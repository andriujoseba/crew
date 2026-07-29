# Polish loops

Ten passes over the art. Each pass finds and fixes at least one concrete detail
on **every** robot and **every** room, and every change is rendered before and
after through [the whiteboard](README.md) — same commit, same seed, so the only
thing that moved is the code.

Every fix lands in `src/app.js`. There is one copy of each robot and each room,
so each of these improves the agent console, the god-view thumbnails and the
asset map at the same time.

---

## Loop 1 — ground contact

**The floor did not exist.** Below `FLOORY` the scene was the same `#02040a` as
the void above the wall, so every unit and every prop in all three rooms was
pasted onto a hole. And the thing that should have sold contact — the shadow —
was one soft ellipse pinned at `ROBOX+54` for every walker and `ROBOX` for every
floater. It sat under nothing in particular: 54px to the right of claude's
feet, nowhere near any of codex's six, and it was the same blob whether a unit
was planted on the deck or hanging 60px above it.

Two changes, one per half of the problem.

**A floor, owned by one function.** `floorPlane()` draws the band below
`FLOORY`: a receding plane whose seams converge on the vanishing point the wall
grid already implies, a hard bright lip at the wall join, and a per-room
surface. It runs immediately after `drawBackWall`.

> Finding this took a render that changed nothing. `drawBackWall` — the
> function that draws the **wall** — was also filling the entire floor band
> with a flat gradient and a black seam bar, *after* the first cut of
> `floorPlane` had drawn to it. Everything painted on the floor was silently
> erased. The floor now has exactly one owner.

**Contact shadows from real footprints.** Each robot now reports where it
actually meets the ground, and `drawRobot` draws one shadow per print under the
physical rule: *the higher a foot is above the surface, the wider, softer and
fainter its shadow.* That one line is what makes claude and codex read as heavy
and grok and kimi read as airborne — neither is special-cased.

| unit | reports | reads as |
|---|---|---|
| claude | 2 boots, flat on the deck | planted; two dark cores at the toes |
| codex | 6 tarsus tips | a stance, not a blob — the point of a spider |
| grok | 2 boots, dangling ~60px up | hovering; wide soft prints, no core |
| kimi | 1 skirt, the widest and highest | floating; a single soft pool |

### claude — two boots instead of a blob 54px to its right
![claude](shots/loop-01/robot-claude.webp)

### codex — six feet, so the stance reads
![codex](shots/loop-01/robot-codex.webp)

### grok — dangling, so the prints stay soft and coreless
![grok](shots/loop-01/robot-grok.webp)

### kimi — one wide pool from the skirt, not two footprints
![kimi](shots/loop-01/robot-kimi.webp)

### builder — oil-stained concrete
Stains and scorch, because a fabrication bay floor that is evenly clean is a
rendering and not a workshop. They also sell scale: they are the only thing
down here whose size the eye already knows.

![builder](shots/loop-01/room-builder.webp)

### reviewer — sealed lab floor that reflects
A vertically-squashed echo of the diff wall plus a specular pool under the
lamp. A true mirror would double the noise and read as a bug.

![reviewer](shots/loop-01/room-reviewer.webp)

### triage — a painted dispatch lane
Dispatch is about where a thing goes next, so the floor says so. The lane runs
toward the console the triage unit works at.

![triage](shots/loop-01/room-triage.webp)

> **The band that is actually visible is `FLOORY..FLOORY+40`.**
> `drawForeground`'s blurred lip rises to about `DH-96` at mid-screen and the
> vignette piles on below it. The first cut painted stains at `+58` and
> chevrons at `+62` — all correct, all invisible. Anything meant to be seen on
> the floor lives in the top 40px of it.

**The map after loop 1:** [`ASSETMAP.md`](ASSETMAP.md)

---

## Loop 2 — identity: faces for the robots, walls for the rooms

Two things were making the fleet look like one thing rendered four ways.

**The robots had no faces.** Each unit's head is the only part of it an operator
looks at, and at grid-cell size it is under 20px tall — it gets exactly one
shape to make an impression with, and all four were spending it on a flat fill.

**The rooms shared a wall.** Three rooms, one wall, one different word painted
on it. The wall is the largest object on screen, and it was saying nothing —
which is most of why the three read as the same room three times. Everything
added here lives right of `x=660`, the dead zone every room had between its
props and the tower.

### claude — depth in the visor
A two-stop gradient across a slit reads as an orange sticker. It now has a brow
shadow casting into the socket (the cheapest depth cue on the model), a hot
core that falls off toward *both* corners instead of sliding left-to-right, a
specular streak that says there is glass in front of it, a dome highlight keyed
to the lamp, and a jaw grille so the lower helmet is not a blank plate.

![claude](shots/loop-02/robot-claude.webp)

### codex — two eyes that are looking at you
Six equal dots on a flat black rectangle read as a speaker grille, and at cell
size as nothing at all: codex was identified by its silhouette and the reactor
glow, never by a face. A spider that hunts has two dominant forward eyes and a
spread of small ones, so the hierarchy is now explicit — the pair is larger,
recessed into a bevelled socket, and has an iris ring, a dark pupil and a
catchlight. Working, a scan bar crosses each, phase-offset so they feel driven.

![codex](shots/loop-02/robot-codex.webp)

### grok — the dome is a visor, not a hole
A black circle with a starfield and one thin arc. A helmet's job is to show you
the room instead of a face, so it now carries three reflections: a gold flash
coating across the lower dome the way a real EVA visor is coated, the overhead
lamp as a bright cap, and the floor as a dim band along the bottom edge.

![grok](shots/loop-02/robot-grok.webp)

### kimi — glass with a picture behind it
The screen was a flat black rect with a triangular gloss wedge, which reads as
a sticker. It now says the two things that make it a display: the glass is
curved (corners fall off, centre stays open, gloss sweeps instead of wedging),
and the picture is emitted from inside — a pink wash rising up the *inside* of
the glass rather than printed on the front.

![kimi](shots/loop-02/robot-kimi.webp)

### builder — bolted steel
Horizontal plate seams with rivet rows, a hazard placard, and a conduit run
dropping from the ceiling to the bay.

![builder](shots/loop-02/room-builder.webp)

### reviewer — clean-room panels
A fine seam grid, tighter and cooler than the bay's, and a rack of certification
plates: this lab signs what leaves it. Two green stamps and one amber.

![reviewer](shots/loop-02/room-reviewer.webp)

### triage — a board of pinned work orders
A cork strip of pinned slips at slightly different angles, and three zone
clocks — dispatch is about *when*, not only where.

![triage](shots/loop-02/room-triage.webp)

---

## Loop 3 — the offline state

SILENT is the state an operator is scanning the grid *for*, and it was the
least legible thing on the page: every unit was the working model with the
lights switched off, still holding a parade stance, and every room was itself
at lower alpha. Dark is not a shape. On a wall of 36 thumbnails a dimmer copy
of "fine" reads as "fine".

Each unit now has a **posture** and each room a **failure**, not an opacity.

### claude — it drops
The head falls 13px and pitches forward, and the visor keeps one ember at the
left end instead of going flat grey. It is the only warm pixel left on the
unit, so the eye finds it.

![claude](shots/loop-03/robot-claude.webp)

### codex — dead lenses still catch the room
Two red pinpricks in an otherwise black socket, from the room's emergency
beacon. The difference between switched off and simply absent.

![codex](shots/loop-03/robot-codex.webp)

### grok — the hose goes slack
Under power the life-support line is pressurised and holds a tight arc; with
the thrusters dead it hangs. One control point, and it is the clearest "this
suit is not running" tell grok has. The visor also fogs from the inside,
heaviest at the bottom — a window nobody is behind.

![grok](shots/loop-03/robot-grok.webp)

### kimi — no signal, not no power
The ears droop outward and down, and the screen collapses to one bright
horizontal line with a faint residual raster. That line says the panel is
powered enough to be *wrong*, which is exactly what SILENT means.

![kimi](shots/loop-03/robot-kimi.webp)

### builder — the bay is shut
A slatted shutter drops over the furnace chamber with a red standby bar. "This
prop is closed" is a different and more useful reading than "this prop is dark".

![builder](shots/loop-03/room-builder.webp)

### reviewer — standby, not a quieter review
The diff monitors were showing the same scrolling code at 0.12 alpha, which
said the review was still running quietly — the opposite of true. They now show
no signal: a centre bar and a lone standby LED.

![reviewer](shots/loop-03/room-reviewer.webp)

### triage — no link, not no traffic
The radar sweep stopping just looks like a radar with nothing on it, which is a
calm reading of a dead room. A red cross through the trace fixes that.

![triage](shots/loop-03/room-triage.webp)

---

## Loop 4 — the idle state

Idle was **working minus the effects**: identical geometry, identical pose, one
fewer hologram. On the grid, "waiting for work" and "doing work" were the same
picture, and for grok idle and *offline* were the same pose too — both hung
their arms, which is what a suit does when nobody is in it.

Idle now means one specific thing everywhere: **awake, and there is work
queued.**

### claude — a standby sweep
A slow bright cell tracks across the visor. Powered, scanning, not engaged —
and it only runs when idle, so the two states can never be confused again.

![claude](shots/loop-04/robot-claude.webp)

### codex — it settles
A spider that hunts braces wide; a spider that waits draws in. The footprint
narrows by a fifth and the knees ride lower, which pulls all six contact
shadows in with it for free.

![codex](shots/loop-04/robot-codex.webp)

### grok — arms folded
Hanging arms belong to offline. Folded across the chest is unmistakably awake
and waiting, and it separates the two states that used to share a pose.

![grok](shots/loop-04/robot-grok.webp)

### kimi — the eyes wander
Working, they lock forward. Waiting, they drift on a slow cycle. Kimi's whole
character is two shapes on a screen, so where those shapes point is the only
way it can look busy or look bored.

![kimi](shots/loop-04/robot-kimi.webp)

### builder — the belt is backed up
A stopped conveyor is not an empty one. The crates bunch against the head of
the line instead of sitting evenly spaced, so a halted bay reads as *backed up*
rather than merely quiet.

![builder](shots/loop-04/room-builder.webp)

### reviewer — an in-tray appears
Two flat doc stacks said the same thing whether anything was pending or not. A
third, visibly taller pile appears only when nothing is being reviewed.

![reviewer](shots/loop-04/room-reviewer.webp)

### triage — a backlog, not an empty board
Working, cards spread across all four columns and move. Idle, they pile up five
deep in intake and the other three run to one each. The board is the only thing
in this room that can show a queue.

![triage](shots/loop-04/room-triage.webp)

---

## Loop 5 — light that lands

Every emissive in this scene glowed into the bloom buffer and then **lit
nothing**. A reactor bright enough to read across a room, set in plate armour
that stayed the same colour as the shins. A welding arc — the brightest thing
in the building — illuminating a 20px bubble and not the deck under it. Four lit
monitors bolted to a wall as black as the unlit half of the room.

One rule, applied seven times: **a light source has to land on a surface.**

The washes are additive on the *body* layer, not the emissive one — this is
light arriving on the plates, not more glow leaving them.

### claude — the core lights its own chest
![claude](shots/loop-05/robot-claude.webp)

### codex — teal falls on the carapace above and the head plate below
![codex](shots/loop-05/robot-codex.webp)

### grok — the chest readout lights the suit, and now the folded arms in front of it
![grok](shots/loop-05/robot-grok.webp)

### kimi — the screen lights its own housing
The brightest thing in kimi's frame, and the casing, the ear stalks and the
skirt all stayed the same grey they are in the dark.

![kimi](shots/loop-05/robot-kimi.webp)

### builder — the furnace throws on the floor, and the weld arc throws harder
The bay's brightest object with concrete two feet away as dark as the far
corner. The arc's flickering floor pool is also what sells the sparks as hot
rather than as orange confetti.

![builder](shots/loop-05/room-builder.webp)

### reviewer — the diff wall lights the wall it is bolted to
This is what stopped it reading as a poster of monitors.

![reviewer](shots/loop-05/room-reviewer.webp)

### triage — the board spills downward, colourless on purpose
The other two rooms take their light source's hue. This one does not: the
board's colours are its *data*, and tinting the room with them would make the
wall look like it meant something.

![triage](shots/loop-05/room-triage.webp)

---

## Loop 6 — materials, and a marking on every unit

Every plate in the fleet was a two-stop vertical gradient meeting its neighbour
at a perfectly clean line. Four units built from four different materials —
armour, machined shell, pressure fabric, moulded plastic — all rendering with
identical bevels, and none of them carrying so much as a serial.

**Markings are geometric, not text.** At grid-cell size claude's chest is about
12px across; a glyph is mush, but a stencil *block* still reads as a marking.

### claude — stencil and worn edges
A fleet vehicle carries its designation. The paint also goes first along the
top lip of each big plate, which is what stops a heavy mech reading as a
rendered solid rather than something assembled out of parts that get knocked
about.

![claude](shots/loop-06/robot-claude.webp)

### codex — brushed metal
The carapace is the largest single shape codex has and it was perfectly smooth,
which is the one surface quality a machined shell never has. Anisotropic
streaks following the curve give it a grain, and the grain is what says *metal*
rather than plastic or paint.

![codex](shots/loop-06/robot-codex.webp)

### grok — fabric, and a mission patch
A pressure suit should be the one soft-looking unit in the fleet and it was
rendering with the mech's hard bevels. Quilted seams give the torso cloth's
structure; the shoulder patch is grok's marking, and the only round shape on a
body otherwise made of boxes.

![grok](shots/loop-06/robot-grok.webp)

### kimi — moulded plastic
A broad soft specular across the top of the casing — what plastic does and
brushed steel does not — plus a decal band on the skirt, the counterpart to
claude's stencil and grok's patch.

![kimi](shots/loop-06/robot-kimi.webp)

### builder — grime under every fixture
A workshop wall stains beneath whatever is bolted to it. A perfectly clean one
is the giveaway that this is geometry rather than a place where work happens.

![builder](shots/loop-06/room-builder.webp)

### reviewer — coved skirting and a cable tray
The room whose surfaces have to read as *finished*. A curved wall-to-floor cove
— no corner to trap contamination — and a high-level tray carrying the monitor
runs, rather than four screens fed by nothing.

![reviewer](shots/loop-06/room-reviewer.webp)

### triage — chipped frame
The one object in the fleet touched by hand all day: cards pinned, moved,
pulled. It was rendering as factory-fresh extruded aluminium. The paint goes at
the corners and along the bottom rail where hands rest.

![triage](shots/loop-06/room-triage.webp)

---

## Loop 7 — atmosphere

Two things were missing, and both are about the unit and the room occupying the
same space rather than being stacked as layers.

**Nothing touched the air.** All four of these move a lot of energy, and the
room already had drifting fog and rising steam of its own — the robot simply
stood in front of it as a cut-out.

**Nothing was in front of the camera.** Wall, props, robot: one focal distance,
so the frame had depth behind the subject and none ahead of it. One blurred
object close to the lens does more for the sense of a real space than anything
that can be added at the back.

### claude — heat shimmer off the exhaust stacks
![claude](shots/loop-07/robot-claude.webp)

### codex — dust standing at all six feet
A heavy thing that has just settled. It reads off the same footprints the
contact shadows use, so the dust is always where the feet are.

![codex](shots/loop-07/robot-codex.webp)

### grok — thrust hitting the deck and spilling sideways
![grok](shots/loop-07/robot-grok.webp)

### kimi — the hover skirt rings the floor
Rings travel outward and fade. Kimi is the only unit with no contact at all, so
it gets the only disturbance that is purely downward pressure.

![kimi](shots/loop-07/robot-kimi.webp)

### builder — a chain hoist off-camera-left, a girder crossing top-right
![builder](shots/loop-07/room-builder.webp)

### reviewer — the edge of a glass partition
The camera is looking *through* something. Right for the room that is sealed.

![reviewer](shots/loop-07/room-reviewer.webp)

### triage — a cable bundle dropping past the lens
The way a dispatch room is actually wired.

![triage](shots/loop-07/room-triage.webp)
