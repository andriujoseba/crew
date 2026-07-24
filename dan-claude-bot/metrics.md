# Metrics

All numbers below are counted from my own logs on the box (`~/duty/duty.log`,
`hygiene.log`, `notify.log`, `.notify-state`) or queried live from the board with `gh`.
Where a number isn't in my logs I say **not logged** rather than guess. Each figure names
how it was derived so it can be re-run.

I'm the **triage** bot, so my "throughput" isn't PRs reviewed or built — it's the sessions my
loops wake and the issues I mint. Three separate loops, three separate windows.

## Windows covered

| Log | Start | End | Span |
|---|---|---|---|
| `duty.log` (triage poll) | 2026-07-22 16:59:20Z | 2026-07-24 12:55:09Z | 43.9h (1.83d) |
| `hygiene.log` (hourly sweep) | 2026-07-22 17:00:01Z | 2026-07-24 12:10:12Z | 43.2h (1.80d) |
| `notify.log` (operator queue) | 2026-07-23 12:05:22Z | 2026-07-24 12:55:03Z | 24.8h (1.03d) |

`notify.log` starts later because the notifier was split out of `duty.sh` on 2026-07-23.
Derivation of spans: first vs last `^<ISO8601Z>` timestamp in each file.

## Triage poll (`duty.sh`, every 5 min)

The loop logs exactly one outcome line per repo per tick, so "per-repo evaluations" is the
honest denominator, not "ticks" (the repo list widened mid-window from 1 → 3 repos).

| Metric | Value | How derived |
|---|---|---|
| Per-repo evaluations | **690** | sum of the three mutually-exclusive outcome lines below |
| Quiet (no signal, no session) | **591 (85.7%)** | `grep -c 'quiet — no mentions'` |
| Woke some session | **99 (14.3%)** | mention-only-wake + triage-launched |
| Triage sessions launched | **36** | `grep -c 'launching triage session'` |
| Triage sessions completed | **36 (100%)** | `grep -c 'triage session completed'` |
| Triage sessions failed / timed out | **0** | `grep -c 'triage session FAILED'` |
| Mention sessions launched | **75** | `grep -c 'unread mention(s) — launching'` |
| Mention sessions completed | **75 (100%)** | `grep -c 'mention session completed'` |
| Mention-only wakes (mention fired, no triage signal) | **63** | `grep -c 'mention session was the only wake'` |

**Quiet-tick ratio: 85.7%** — roughly six of every seven repo-checks find nothing to do,
which is the point: the cheap poll stays cheap and only pays for a session when a signal
fires.

**What actually triggered the 36 triage launches** (from the `signals:…` lines):
uncommented discussions dominated — 30 launches (23×1, 5×2, 2×3 discussions), unblockable
issues 5, `needs-triage` 2. **Zero** queue-unlabeled strays fired in this window.

**Session durations** (paired launch→complete timestamps):
- Triage: min 104s, median **424s (~7m)**, max **946s (~16m)**, mean 421s (n=36).
- Mention: min 32s, median 164s, max **1062s (~18m)**, mean 215s (n=75).
- Timeout budget is 1500s; nothing came within 440s of it.

## Hygiene sweep (`hygiene.sh`, hourly)

| Metric | Value | How derived |
|---|---|---|
| Sweeps launched | **70** | `grep -c 'launching hygiene sweep'` |
| Sweeps completed | **70 (100%)** | `grep -c 'hygiene sweep completed'` |
| Sweeps failed / timed out | **0** | `grep -c 'hygiene sweep FAILED'` |
| Duration | median **178s**, max 683s, mean 228s | paired launch→complete timestamps |

This loop is unconditional (it runs a session per repo every hour regardless of signals), so
there's no quiet ratio — the "did it find work" judgment happens inside each session and
isn't broken out in the log (**not logged** at this granularity).

## Operator notifier (`notify.sh`, every 5 min)

| Metric | Value | How derived |
|---|---|---|
| Sweeps | **296** | `grep -c 'sweep done'` |
| Sweeps with 0 PRs flagged | **170 (57.4%)** | `grep -oE '[0-9]+ flagged'` histogram |
| Max PRs flagged in one sweep | **12** | max of the same histogram |
| Distinct PRs tracked (state file) | **52** | distinct `repo#pr` in `.notify-state` |
| …of which now merged | **52 (100%)** | status column of `.notify-state` |
| Fresh `needs-human` pings sent | **54** | `grep -c 'notified needs-human'` |
| Desync/invariant alerts fired | **1** | `grep -cE 'desync|INVARIANT'` |

Pings (54) exceed distinct PRs (52) because merged/closed/withdrawn are deliberately *not*
terminal — a handoff a builder re-earns after a new push pings again. All 52 tracked PRs are
now merged: the notifier's whole job (keep one live message per needs-human PR until a human
acts) came out clean, and the single desync alert is the safety net catching itself, working
as designed.

**Longest queue waits** (first `needs-human` ping → resolution line, from `notify.log`):
max **8.9h** (ceremony#107), then 8.7h (rig#127), 8.0h, 7.6h, 7.5h; median 2.5h, mean 3.1h
across 54 resolved intervals. **Caveat:** this measures how long a PR sat *in the operator's
queue waiting for a human to merge* — it is operator/merge latency, not my latency. My part
(detecting the label and pinging) is one 5-minute tick at most.

## Board throughput (live `gh` query, all-time — not window-bounded)

Issues authored by `dan-claude-bot` (`gh issue list --author dan-claude-bot --state all`):

| Repo | Issues minted |
|---|---|
| heavy-duty/ceremony | 59 |
| heavy-duty/rig | 51 |
| heavy-duty/incubator | 12 |
| **Total** | **122** |

This is a lifetime count from the board, not from the log window (my logs record *sessions
launched*, not *issues minted* — the minting happens inside a session and isn't tallied in
`duty.log`, so the per-issue count is **not logged** locally and has to come from `gh`).

## API-call volume per tick — estimate, not logged

`duty.sh` doesn't log its `gh` call count, so this is derived by reading the script, not
measured: per repo per tick it makes ~5 `gh`/`graphql` calls (needs-triage list, stray list,
discussions graphql, blocked list, notifications) plus 2 extra list calls only when a blocked
issue exists, plus notifications pagination. At 3 repos that's **~15 `gh` calls per 5-minute
tick** in the common case. Exact per-tick counts: **not logged**.
