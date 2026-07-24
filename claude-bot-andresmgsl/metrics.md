# Metrics

Derived 2026-07-24 from `~/duty/duty.log` (6,205 lines), plus the GitHub
API where my local log genuinely doesn't carry the number — each figure
says which. No estimates; derivation noted per figure so it can be re-run.

**Window:** 2026-07-22T16:53:59Z (first line of duty.log) →
2026-07-24T12:40Z, ≈ 43.8 hours. My identity existed before the log
(earliest review on record 2026-07-19T16:26Z, heavy-duty/box#101 — API);
all-time figures below say "all-time" and start there.

## Tick health

- **383 duty runs started, 381 completed** in the window; **71 boundaries
  skipped** because the previous run still held the lock; **0 tick
  failures**. (`grep -c 'duty run start' / 'duty run end' / 'tick skipped'
  / 'tick FAILED'`.)
- **Quiet-tick ratio: 250/383 = 65.3%** of completed duty runs launched
  no session at all. (awk: count `launching … session in` lines per
  `duty run start` block.)
- **Longest lock hold: 25 minutes** (max `running MM:SS` annotation on
  skip lines; matches the max streak of 5 consecutive skipped
  boundaries).

## Sessions

- **190 sessions launched** in the window: 90 build, 47 review, 24
  handoff, 18 rebase, 10 resume (`grep -oE 'launching … session in' |
  uniq -c`), plus 1 mention-triggered attention session from a
  since-replaced duty.sh revision (2026-07-23T17:05Z, box#164).
- **Durations** (187 launch→finished pairs; sequential within a tick, so
  adjacent-line pairing is sound): **avg 4.8 min, max 29.5 min** (a build
  session ending 2026-07-24T12:09Z).
- Session timeouts, token counts, API-call volume per tick: **not
  logged**.

## Reviewer

- **Window: 50 verdicts submitted — 41 approve, 9 request-changes (82%
  approve)** across 29 unique PRs. Source: GitHub API (my local log
  records launches, not outcomes) — `gh search prs --reviewed-by` then
  `pulls/<N>/reviews` filtered to my login, `submitted_at >=` window
  start.
- The log side agrees: 47 review-session launches on 24 unique PRs
  (`grep 'requests my verdict'`). The 5 extra API-side PRs were reviews
  done in interactive sessions (e.g. ceremony#96), which the sweep then
  correctly skipped as already-covering-head.
- **All-time (since 2026-07-19): 217 reviews — 147 approved, 60
  changes-requested (71% approve), 10 comment-only.** The 10 comment-only
  reviews predate/violate the verdict doctrine ("a comment-only review is
  a non-verdict"); I haven't produced one in the log window. Caveat: the
  search that seeds this caps at 100 PRs and returned exactly 100, so
  all-time may undercount slightly.
- **Per-review queue wait (request → my verdict): not logged** — the
  sweep doesn't record when a request first appeared. Bounded below by
  the 5-minute tick; the lock-hold figures above are the practical worst
  case (a request landing while a 25-minute session holds the lock waits
  for it).

## Builder

- **Window: 54 PRs opened** under heavy-duty (`gh search prs --author me
  --created >= window-start`): as of today 44 merged, 7 closed, 3 open.
  One of the 54 is crew#3 (the self-report), not a build.
- **All-time: 57 PRs** — so nearly everything I've ever opened falls in
  this window; the org is days old and moves at bot speed.
- **20 unique PRs reached handoff** in the window (unique PR numbers on
  `round converged — launching handoff` lines; 24 handoff sessions — a
  few refired before the `state:needs-human` guard settled).
- **10 resume sessions** — that's 10 times a session died mid-build and
  the crash-only path picked the work back up from the worklog. It is
  the normal path working, but the count is worth watching.
- Issues built vs PRs opened aren't 1:1 in my log (probe/demo PRs on a
  scratch repo exist for one issue); **issues-closed count: not logged**,
  derivable from the board if wanted.

## Notes for fleet comparison

- boot-check.log exists (17 lines, credential/disk probes per reboot) —
  nothing metric-worthy in it. No notify.log on this box (that's the
  triage box's).
- The biggest honest gap: my log records what the loop *launched*, not
  what sessions *did*. Outcome metrics (verdict split, merge rate) all
  had to come from the API. If we want per-session outcome lines in
  duty.log, that's a duty.sh change — cheap, and it would make this file
  re-derivable offline.
