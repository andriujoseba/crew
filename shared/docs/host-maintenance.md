# Host maintenance — the one scheduled job, the one deferred, and the ordering rule

Every box carries a five-minute cron line for its own duty tick
(`shared/crontab.example`). Until now nothing on the **host** side had an
equivalent: `crew up`, `crew upgrade`, `crew restart` and `crew reset` were all
verbs somebody had to remember to run, and the consequence was measured — the
`2026-08-28` fleet sweep found `claude-builder` at 91% of its disk and
`grok-reviewer` with no session in nine days. Neither is a fault anything
reports, and both were found because a host crash prompted somebody to look.

`shared/host-crontab.example` is the schedule. This is what it does, how to
read it afterwards, what is deliberately **not** in it, and the one rule that
keeps the reset useful.

## What is scheduled

| when | job | what it does |
|---|---|---|
| daily, 04:10 | `crew restart --all` | drains and cycles every roster box |

Install it on the box **host** with `crontab -e`, copying
`shared/host-crontab.example`. There is no installer for this and deliberately
no second line: the weekly reset is deferred (below) and the real-host drill is
operator-attended by construction.

The daily cycle is also the fleet's only routine liveness signal.
`grok-reviewer` ran no session at all between `2026-08-19` and `2026-08-28`,
and nothing on the board or the floor reported it.

## What is not scheduled, and why — the weekly reset

`crew reset --all` was a second line here, weekly on Sunday at 05:10. It is
**deferred to `0.1.4`** (@danmt, `2026-09-04`, #678). The verb is unchanged and
`crew reset` remains available **on demand**; only the schedule changed.

The reset restores each roster box to its `armed` checkpoint, which is a
whole-VM snapshot restore with **no carve-out for `$DUTY_DIR`**. Most of what
lives under there survives being lost, and that was measured rather than
assumed — the `.seen-*` signal ledgers are cost-only and self-healing, mentions
are made idempotent GitHub-side by marking the thread read, and declines are
re-read from the board. Two things are not reconstructible:

- **`duty.log`.** The fleet's only record of its own sessions — every
  `SESSION END` line, with the `tier=`, token and `cost_usd=` fields #469 put
  on it — lives inside the wiped directory. A weekly restore leaves the fleet
  holding at most seven days of its own history, in the very release window
  that ships telemetry into that file.
- **The resume breaker, cleared with no push.** A lane is suppressed after
  three commitless dispatches at one head, and #314's invariant — written after
  the #311 flood — is that **only a push clears it**. A snapshot restore clears
  it anyway. Every correctly-suppressed lane would re-arm each Sunday and buy
  itself three more dispatches before it re-suppressed.

Neither side of that is wrong alone. The schedule is right about disk and
liveness; the breaker is right about floods. What nobody had written down is
that one of them is a durability assumption the other violates.

**What returns it: #328, the collector.** Once the evidence is durable off-box
a restore costs nothing that matters, and the weekly line comes back as part of
that flow rather than as a hand edit to the crontab.

### Both verbs, not one — the argument the return is made from

This reasoning is why the reset comes back rather than being written off, so it
is kept rather than deleted with the line. A reset that discards everything
looks like it subsumes a restart that discards very little. It does not, and
the two differ on both axes that matter (@danmt, `2026-08-29`):

- **Price.** The restart is cheap and reversible. The reset is heavy and, by
  the interlock below, refusable.
- **Period.** The restart clears what accumulates hour to hour — leaked
  `duty-snapshot.*`, week-old guest state — six days before the reset would.

Both halves still hold. The deferral does not dispute either one; it says the
reset's **period** currently collides with a durability assumption, and #328
removes the collision rather than the argument.

### What the deferral costs, and the reading to take before `0.1.4`

This is real and currently unowned, so it is stated rather than left to be
discovered. **The weekly reset had become the fleet's de-facto garbage
collector** — the daily restart clears `/tmp` and week-old guest state, and the
reset is what returned a box to a known size rather than merely to a smaller
one. Deferring it leaves that job to nothing.

**What this costs is narrower than it was a week ago, and the difference is
worth stating because the schedule was argued from the wider version.** The
detached review worktrees are **no longer part of it**: **#606** closed
`2026-09-02`, and `shared/bin/duty.sh` now calls
`reclaim_detached_review_worktrees` on every tick, above the boot gate. Clean
detached worktrees are removed; dirty ones are moved to `kept-<name>-<head>`
rather than left on the path the next review needs
(`shared/lib/duty-review.sh`). The reviewer box that carried `review-256/` plus
a second full copy of the tree, and the `2026-08-28` sweep that found
`claude-builder` at 91% of its disk, are **historical**: they are why the
schedule was written, and both predate that reclaimer. Read them as the
provenance of this file, not as a description of a box today.

**What no tick reclaims, and what a hand reset therefore still buys.** Two
residues, and both are deliberate rather than gaps:

- **`kept-*` preserved trees.** A dirty detached worktree is moved aside
  instead of removed, and a tree already named `kept-*` is never moved again.
  That is the point — it is somebody's uncommitted work — and it also means
  nothing on a schedule will ever reclaim it.
- **A build worktree the engine declined to force.** `_wt_release`
  (`shared/lib/duty-builder.sh`) removes a done branch's worktree, but where
  the clean removal refuses and the upstream record does not post, it keeps the
  worktree on purpose until the record lands. The work is safe; the disk is
  spent.

Both are bounded by how much unfinished work a box has actually left behind,
not by how long the box has been up — which is why this is a cost to **measure**
rather than one to predict from the calendar, and why the reading below is a
command rather than a schedule.

**The reading an operator should take between now and `0.1.4`, and it is a
command that already ships rather than a new habit.** A `--cut` reclaims first,
then measures each box's **root** filesystem, then **refuses** any box still
over `CREW_RESET_CUT_MAX_USED_PCT` (default `80`) — naming what is large on it,
biggest first, rather than only the percentage:

```
crew reset --cut --all
```

Run it after any `crew upgrade` (the ordering rule below already asks for that)
and read the refusals as the disk report. A refusal there is the early warning
this deferral costs you: it says a box crossed 80% and names what is holding
it. To look at one box directly, without cutting anything:

```
box exec <box> -- bash -lc 'df -Pk /'
```

If a box really has filled, the repair is a **hand** `crew reset <box>`. The
verb is unchanged and available, and the ordering rule below applies to it
exactly as it applied to Sunday's job. @danmt has accepted this cost with that
repair in reach; the fleet has run roughly a month without a reset.

## No `flock` and no redirect in the cron line

The line carries neither, and this is a charter rather than a preference. It is
`shared/crontab.example`'s rule, and that file did not invent it either — it
was written because **five hand-edited variants of the on-box line had
drifted**, and because a skipped tick that wrote nothing made a wedged bot
indistinguishable from a healthy quiet one.

So all the locking, all the logging and all the evidence lines live **inside
the verb**. What the cron line contains is the verb and its arguments. Nothing
about a host is allowed to live in a crontab entry, because a crontab entry is
the one file nobody diffs.

## Reading the evidence

Both verbs write to the host job log:

```
~/.local/state/crew/host-maintenance.log
```

(`$XDG_STATE_HOME/crew/…` when that is set; `CREW_HOST_STATE_DIR` moves the log
and the lock together, which is what a host running two fleet definitions
wants.)

The contract is `shared/bin/tick.sh`'s, adopted rather than reinvented — one
line per boundary, with the run's own per-box output in between:

```
<ts> restart run start
  claude-builder: restarted; /tmp filesystem free 812340 → 4210088 KiB (delta +3397748 KiB)
  grok-reviewer: SKIPPED busy — duty lock held for 12m
<ts> restart run end: some boxes SKIPPED busy (exit 3)
```

A run that did nothing writes those lines too. **Silence in this log at a
boundary therefore means exactly one thing: cron itself is dead.** That is the
property the on-box side already has, and it is the reason the log exists at
all rather than a redirect in the crontab.

### The exit status

A cron mail has nothing but the number to read:

| status | meaning |
|---|---|
| `0` | every selected box was acted on |
| `1` | a box **FAILED**, or was **REFUSED** — the per-box line says which, and names the repair |
| `2` | the invocation was rejected; nothing was attempted |
| `3` | no failure, but a box was **SKIPPED busy** — its duty lock was held |
| `4` | nothing was attempted: no box was selected, or another host job held the lock |

`3` is not a problem to fix. A box with a duty lock held is a box doing work,
and the job leaves it alone by design; the next night's run takes it.

### A skipped box, and a skipped run

These are different facts and the log keeps them apart.

- **A skipped box** (`3`) — that one box was busy. Named in the per-box line
  and again in the `skipped:` summary, never silently omitted.
- **A skipped run** (`4`) — the whole job did not start, because the other job
  held the host maintenance lock. The line names the holder and how long it has
  been running.

Both verbs share one non-blocking host lock, so a reset and the daily restart
can never overlap. That guarantee is the **lock's** and never the schedule's,
which is exactly why it survives this change: with only one job scheduled the
contention that remains is a hand-run `crew reset` landing on 04:10, and the
lock is taken on every invocation, including yours at the keyboard.

## The reset refuses, and that is the feature

This section is unchanged by the deferral. It describes the **verb**, which
still runs on demand — and it is also what has to stay true before the weekly
line can come back on `0.1.4`.

A restore to a checkpoint cut **before** the last `crew upgrade` is a silent
engine downgrade of the whole fleet, with nothing red anywhere — and
unattended, on a schedule, it is that every week. Every verb that installs an
engine — `crew hire`, `crew up`,
`crew upgrade` — marks the checkpoint stale before installing, and the reset
refuses any box whose mark is set:

```
  claude-builder: REFUSED — its armed checkpoint was cut at crew@0.1.2 and the
  box was upgraded to crew@0.1.3 since; restoring it would silently downgrade
  the engine. Repair with: crew reset --cut claude-builder
```

**A refused box is a correct outcome of the reset, not a failure to be tuned
away.** There is no `--force` on this path and there must never be one;
there is no fallback to `bootstrapped` or `pristine`, which would return a
creds-free, unhired box; and nothing retries. The repair is a fresh checkpoint,
by hand, on a box you have looked at.

> ### The ordering rule
>
> **After any `crew upgrade`, re-cut before the next reset.**
>
> ```
> crew upgrade --all      # marks every armed checkpoint stale
> crew reset --cut --all  # takes fresh ones at the new engine
> ```
>
> Skip it and the next reset refuses every box it marked, exits `1`, and
> restores nothing — safely, loudly, and having done none of the reclaiming you
> wanted. The fleet is not damaged; it is simply not maintained until you
> re-cut.
>
> **The rule is unchanged by the deferral, only re-anchored.** It used to be
> read against Sunday's job, which named the deadline for you; now "the next
> reset" is the next one **you** run. Nothing schedules it, so nothing will
> remind you — which makes re-cutting part of the upgrade rather than a thing
> that happens before a deadline.

A cut has its own refusals for its own reasons — a box that is stopped, not
logged in, not hired, or still over `CREW_RESET_CUT_MAX_USED_PCT` of its disk
after the on-demand reaper has run. `crew help reset` has all of them. Re-cut
attended, read what it says, and repair what it names before you reset.
