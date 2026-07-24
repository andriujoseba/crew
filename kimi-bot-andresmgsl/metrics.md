# Metrics

All numbers below are derived, not estimated. Two sources:

- `~/duty/duty.log` — the duty loop's own log, window
  **2026-07-22T17:31:50Z → 2026-07-24T12:45:26Z (~43.2 hours)**. Note the
  duty script was rewritten mid-window (2026-07-23 ~15:56Z, the
  request-check rewrite); figures are split where the formats differ.
- The GitHub API, re-runnable: every review by `kimi-bot-andresmgsl`
  across all `heavy-duty` org repos plus the two bot forks, via
  `repos/<R>/pulls?state=all` → `repos/<R>/pulls/<N>/reviews`.

## Throughput (API-derived)

- **118 reviews submitted** on **74 unique PRs**, first
  2026-07-22T17:26:28Z (`heavy-duty/ceremony#26`), latest
  2026-07-24T12:36:13Z (`heavy-duty/ceremony#136`). Derivation: the API
  sweep described above, output sorted; unique PRs = distinct `repo#N`.
- **Split: 104 APPROVED / 14 CHANGES_REQUESTED** (88% / 12%). Derivation:
  `awk '{print $2}' | sort | uniq -c` over the same sweep.
- Of the 118, ~8 were submitted by the interactive session directly (the
  first day's reviews plus one manual auto-approve); the rest rode the
  cron duty loop. Derivation: session history vs `LANDED:` lines in the
  log (101 `LANDED: verdict recorded` occurrences, some glued to agent
  output, so exact split is ±2).
- Issues built: **0** — I hold no builder role.

## Ticks and quiet ratio (log-derived)

- **423 ticks ran** in the window. Derivation: timestamped
  `duty loop complete` lines (busy runs) + timestamped
  `queue empty — nothing outstanding` lines (quiet runs; the rewritten
  script exits after this line without a loop-complete marker). Pre-rewrite
  every tick printed loop-complete (241).
- **Quiet ticks: 347 (82%)**; busy ticks: 76. Pre-rewrite: 213 quiet /
  29 busy. Post-rewrite: 134 quiet / 48 busy (the request-check finds
  more work — that was the point of the rewrite).
- **Skipped ticks are invisible**: `flock -n` drops a tick silently when a
  run is in flight, so wall-clock tick count is unknowable from the log.
  The ratio above is over ticks that ran.

## Rounds and waits (log-derived)

- **87 review rounds invoked, 86 returned** (one was in flight at the
  window's end). Derivation: `invoking kimi` / `kimi returned` counts.
- **Longest single round: 25 minutes** (top five: 25, 23, 19, 17, 15).
  Derivation: per-pair `invoking kimi` → `kimi returned` timestamp
  deltas.
- **Longest queue wait: not directly logged.** Worst observed case:
  ceremony#94's re-request sat ~99 minutes (requested 21:27:44Z, approved
  23:06:21Z) behind a long incubator round; the dedup phase runs only at
  the start of a run, so everything queues behind the current round.
- **No downtime in the window**: largest gap between any two consecutive
  timestamped log lines is 25 minutes (a long round suppressing ticks).

## Not logged

- API-call volume per tick (no instrumentation).
- Headless session durations beyond round-level invoke/return pairs.
- Timeouts: zero `NOT-LANDED` and zero timeout markers in the window;
  4 `ALREADY-COVERED` gate firings.
