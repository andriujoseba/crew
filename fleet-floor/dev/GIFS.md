# Ten loops, end to end

One animation per robot and per room. Eleven frames each — the baseline, then
every loop in order — rendered from the same seed at the same animation time,
so **the only thing moving between frames is the code**.

Frames hold ~0.85s; the baseline and the final frame hold longer.

> Loop 8 only touched the god-view cell (`drawMini`), so the room frames for
> loops 7 and 8 are identical here. That is correct and worth seeing: it is the
> loop whose whole point was that the grid had fallen behind the room.

## The robots

Shown in the builder bay, working, so the unit is the only variable.

### claude
![claude, loop 0 to 10](shots/gifs/robot-claude.gif)

### codex
![codex, loop 0 to 10](shots/gifs/robot-codex.gif)

### grok
![grok, loop 0 to 10](shots/gifs/robot-grok.gif)

### kimi
![kimi, loop 0 to 10](shots/gifs/robot-kimi.gif)

## The rooms

### builder — the fabrication bay
![builder, loop 0 to 10](shots/gifs/room-builder.gif)

### reviewer — the review lab
![reviewer, loop 0 to 10](shots/gifs/room-reviewer.gif)

### triage — the dispatch room
![triage, loop 0 to 10](shots/gifs/room-triage.gif)

## How these were made

`gif.js` in the working set, and it is hand-written, because there was nothing
here to do it with: playwright's bundled ffmpeg is compiled without a gif muxer
or encoder (png, image2 and libvpx only), there is no PIL, and no pip to fetch
one. So the frames are decoded and scaled in a headless canvas, median-cut into
a single global palette, and LZW-packed into a GIF89a by hand.

**One global palette across all eleven frames, not one per frame.** The whole
point of these is comparing frame N against frame N−1; a per-frame palette
would let the quantiser shift colours between loops and invent differences the
code never made.

The per-loop stills and the reasoning are in [`LOOPS.md`](LOOPS.md); the full
36-tile grid is in [`ASSETMAP.md`](ASSETMAP.md).
