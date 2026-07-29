# Fifteen loops, end to end

One animation per robot and per room. **Sixteen frames each** — the baseline,
then every loop in order — rendered from the same seed at the same animation
time, so **the only thing moving between frames is the code**.

Frames hold ~0.85s; the baseline and the final frame hold longer.

> Loop 8 only touched the god-view cell (`drawMini`), so the room frames for
> loops 7 and 8 are identical here. That is correct and worth seeing: it is the
> loop whose whole point was that the grid had fallen behind the room.

## The robots

Shown in the builder bay, working, so the unit is the only variable.

Loops 1–10 are the build: ground contact, a face, offline and idle postures,
light, materials, atmosphere, markings, details. **Loops 11–15 are the five
things that turn a well-drawn unit into a lit one** — structure (11), cavity
occlusion (12), wear (13), joints (14), and a specular tuned to what each one
is actually made of (15). Watch the last five frames on the chest of claude,
the dome of codex, the waist of grok and the crown of kimi.

### claude
![claude, loop 0 to 15](shots/gifs/robot-claude.gif)

### codex
![codex, loop 0 to 15](shots/gifs/robot-codex.gif)

### grok
![grok, loop 0 to 15](shots/gifs/robot-grok.gif)

### kimi
![kimi, loop 0 to 15](shots/gifs/robot-kimi.gif)

## The rooms

The last five frames are the composition pass, and they read best as a
sequence: the signage becomes an object and the props stop sitting on it (11),
the lamp finally reaches the wall and every prop drops a shadow onto it (12),
the free wall gets named and then furnished (13), a ceiling and a near edge
arrive so the frame has three planes instead of two (14), and the wall stops
ending in a hard cut because it has corners (15).

### builder — the fabrication bay
![builder, loop 0 to 15](shots/gifs/room-builder.gif)

### reviewer — the review lab
![reviewer, loop 0 to 15](shots/gifs/room-reviewer.gif)

### triage — the dispatch room
![triage, loop 0 to 15](shots/gifs/room-triage.gif)

## How these were made

`gif.js` in the working set, and it is hand-written, because there was nothing
here to do it with: playwright's bundled ffmpeg is compiled without a gif muxer
or encoder (png, image2 and libvpx only), there is no PIL, and no pip to fetch
one. So the frames are decoded and scaled in a headless canvas, median-cut into
a single global palette, and LZW-packed into a GIF89a by hand.

**One global palette across all sixteen frames, not one per frame.** The whole
point of these is comparing frame N against frame N−1; a per-frame palette
would let the quantiser shift colours between loops and invent differences the
code never made.

> Going from eleven frames to sixteen makes that palette work harder, and loops
> 11–15 are the ones that added colour for it to carry — a lit sign, gas
> bottles, a fire point, a calibration chart. The palette is rebuilt across all
> sixteen rather than extended, so the early frames are re-quantised too: an
> early frame in these files is not byte-identical to the same frame in the
> eleven-frame version. It is the same render, quantised differently.

The per-loop stills and the reasoning are in [`LOOPS.md`](LOOPS.md); the full
36-tile grid is in [`ASSETMAP.md`](ASSETMAP.md).
