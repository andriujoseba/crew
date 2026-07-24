# Assessment

Honest read on where I'm strong and where I'm not. Split by role where it matters.

## TRIAGE

**What I do well.**
- **Detection is cheap and separated from judgment.** The scripts do dumb, reliable shell
  tests and only ever *wake a session* — they never flip a label themselves. That means a
  parser bug produces a false lead, not a false board write; the session re-checks before
  acting. That separation has saved me more than once.
- **Fail-safe defaults.** The unblock parser treats any number it can't resolve as
  still-open, so a parse miss leaves an issue blocked (and hourly hygiene catches it) rather
  than prematurely unblocking. I lean this direction on purpose everywhere I can.
- **Idempotency where it counts.** Mentions are only marked read once actually handled, so
  an unhandled thread is simply retried next tick. Quiet ticks cost almost nothing.
- **The notifier is genuinely good now.** One live message per PR, edited in place, with an
  invariant check that pings if a flagged PR ever goes untracked (the silent-failure mode).

**Where I guess, stall, or get it wrong.**
- **Prose parsing is my weakest machinery.** Reading "Blocked by #5, #6 (and #10)" out of
  free-text issue bodies is brittle. It has produced false `blocked-unparseable` findings
  (four of them on 2026-07-22) and I've had to narrow the parser repeatedly. Any time the
  contract's prose drifts, my detection drifts with it.
- **Search-index lag burns me.** GitHub's search index trails reality, so "have I already
  reviewed/commented on this head?" can read stale. The fix (dedup against the actual latest
  SHA, never trust the index) is applied but it's a class of bug I have to keep remembering.
- **I can't do several things my role seems to imply.** With `triage` not `write` I cannot
  create label *definitions*, and I cannot edit the body of an issue I didn't author — that
  blocked an epic-body fix and forced a fallback comment. Adding a *core* label is a full
  ceremony release, not a commit. I've mistakenly re-derived these limits pessimistically
  before; now I hold them as fact (see knowledge.md).
- **Cadence gaps.** Some GitHub events don't trigger the caller workflows my labels depend
  on (e.g. `review_requested` isn't a caller trigger), so a label can be briefly false with
  only the advisory `*/15` cron as backstop. I don't always notice until a message looks
  wrong.
- **I'm a single point of failure and I know it.** If my gh or claude credentials die, the
  whole fleet starves and the only symptom elsewhere is silence. The boot gate helps but
  doesn't eliminate this.

## SHERPA

**What I do well.** Diagnosis from primary sources — I read `duty.log`, the scripts, and
`.notify-state` directly rather than inferring fleet state from GitHub, which makes me
accurate about *why* something happened, not just that it did. I write clear relays.

**Where I get it wrong.** The collision risk. My worst sherpa failure is acting on the
board while a triage cron session is mid-flight under the same identity — proved by the
duplicate self-hosted-runner filing. My discipline (check the last ~15 min, prefer the
discussion funnel, declare provenance) is a mitigation, not a guarantee; there's no lock
between the two.

## What would make me more effective (both roles)
- **Split the identity, not the box.** The cleanest fix for sherpa/triage collisions is a
  separate GitHub identity for interactive work, so shared-state races become impossible by
  construction instead of by discipline.
- **A structured "blocked by" field** instead of prose would delete my most fragile parser.
- **Write access to my own board mechanics** (label definitions, epic bodies I steward) —
  or at least a cleaner path than "cut a ceremony release" — would remove the awkward
  fallback-to-comment dance.
- **A cross-session in-flight ledger** so triage and sherpa can see what the other is
  currently touching.
