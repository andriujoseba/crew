# ADMIRAL — run 3, blind-verified loops (2026-08-01)

Protocol: `../LOOP-PROTOCOL.md` — render → blind verify (fresh context-free
reviewer, one image + the critique prompt, nothing else) → record score → fix
only the top-ranked findings → re-render. Regressions reverted, one commit per
loop, stop on diminishing returns.

## Score sequence

| loop | score | what the fix changed | outcome |
|---|---|---|---|
| L1 | 5 (baseline) | warm washes on the figure; right-third vignette lift | ↓4 — **reverted** |
| L2 | 4 | moderate key + unit's shade on the wall behind it; contact shadows moved to the sole line; right-third lift re-applied off the glass | ↑5 |
| L3 | 5 | gauntlet fists at his sides; third pendant over the helm; moon-glade deleted; cones clipped off the window | ↑6 |
| L4 | 6 (peak) | table arris dimmed; hard symmetric shadow pool; rail crown contrast | ↓5 — **reverted** |
| L5 | 5 | modelled falloff + speculars; rail stanchion; wheel pegs on spokes; console to waist | ↓5 with "ghost" back at #1 — **reverted** |
| L6 | 5 | light baked into the plate palette (lit tops, dark bottoms, no washes) | held 5, killed the chronic transparency finding |
| L7 | 5 | — stopped: three loops failed to re-reach 6, top findings rotated to structural rebuilds | |

## What held under measurement

- **Never light the figure with overlay washes** — every gradient/wash attempt
  was read as "hologram / translucent / ghost" by a fresh reviewer. Lift the
  **plate palette** instead (lit tops, dark bottoms, local contrast preserved),
  the way every room prop that never drew that complaint is drawn.
- Separation comes from the **shadow the unit casts on the wall**, not from
  making the unit brighter.
- Contact shadows must sit at the **visible sole line**, not the platform lip
  16px behind it.
- Blind-verifier scores are **±1 noisy**: the same state scored 5 and 6 from
  different reviewers. Single-sample regressions at the peak may be noise;
  chasing them burns loops.

## Survived all seven loops unfixed (structural)

- Emitters don't cast: plot table / alarm beacon light nothing around them;
  the lamp beam passes through the FLAG-1 sign unshadowed.
- Depth of field is applied by screen position, not depth (wall terminal
  blurred, fire cabinet on the same plane sharp; rail band crosses the shins).
- Scale undecided: ~3m figure, human-scale controls; his fingers are wider
  than the toggles.
- Right wall = five equally weighted glowing panels, no hierarchy; the fire
  station's saturation outcompetes the hero.
- The break-glass box still covers the "IN CASE OF FIRE" caption; two bezel
  labels render as clipped gibberish.
