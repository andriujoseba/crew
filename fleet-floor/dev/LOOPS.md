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
