# Host maintenance — the two scheduled jobs, and the one ordering rule

Every box carries a five-minute cron line for its own duty tick
(`shared/crontab.example`). Until now nothing on the **host** side had an
equivalent: `crew up`, `crew upgrade`, `crew restart` and `crew reset` were all
verbs somebody had to remember to run, and the consequence was measured — the
`2026-08-28` fleet sweep found `claude-builder` at 91% of its disk and
`grok-reviewer` with no session in nine days. Neither is a fault anything
reports, and both were found because a host crash prompted somebody to look.

`shared/host-crontab.example` is the schedule. This is what it does, how to
read it afterwards, and the one rule that keeps the weekly job useful.

## The two lines

| when | job | what it does |
|---|---|---|
| daily, 04:10 | `crew restart --all` | drains and cycles every roster box |
| weekly, Sunday 05:10 | `crew reset --all` | restores every roster box to its `armed` checkpoint |

Install them on the box **host** with `crontab -e`, copying
`shared/host-crontab.example`. There is no installer for this and deliberately
no third line: the real-host drill is operator-attended by construction.

**Both lines, not one.** A reset that discards everything looks like it
subsumes a restart that discards very little. It does not, and the two differ
on both axes that matter (@danmt, `2026-08-29`):

- **Price.** The restart is cheap and reversible. The reset is heavy and, by
  the interlock below, refusable.
- **Period.** The restart clears what accumulates hour to hour — leaked
  `duty-snapshot.*`, week-old guest state — six days before the reset would.

And the daily cycle is the fleet's only routine liveness signal.
`grok-reviewer` ran no session at all between `2026-08-19` and `2026-08-28`,
and nothing on the board or the floor reported it.

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

The two jobs share one non-blocking host lock so a weekly reset and a daily
restart can never overlap. The schedule already staggers them by an hour; the
lock is what makes the guarantee independent of the schedule, and it is taken
on every invocation, including yours at the keyboard.

## The weekly reset refuses, and that is the feature

An unattended restore to a checkpoint cut **before** the last `crew upgrade` is
a silent engine downgrade of the whole fleet, weekly, with nothing red
anywhere. Every verb that installs an engine — `crew hire`, `crew up`,
`crew upgrade` — marks the checkpoint stale before installing, and the reset
refuses any box whose mark is set:

```
  claude-builder: REFUSED — its armed checkpoint was cut at crew@0.1.2 and the
  box was upgraded to crew@0.1.3 since; restoring it would silently downgrade
  the engine. Repair with: crew reset --cut claude-builder
```

**A refused box is a correct outcome of the weekly line, not a failure to be
tuned away.** There is no `--force` on this path and there must never be one;
there is no fallback to `bootstrapped` or `pristine`, which would return a
creds-free, unhired box; and nothing retries. The repair is a fresh checkpoint,
by hand, on a box you have looked at.

> ### The ordering rule
>
> **After any `crew upgrade`, re-cut before the next weekly reset.**
>
> ```
> crew upgrade --all      # marks every armed checkpoint stale
> crew reset --cut --all  # takes fresh ones at the new engine
> ```
>
> Skip it and Sunday's job refuses every box it marked, exits `1`, and restores
> nothing — safely, loudly, and having done none of the reclaiming you wanted.
> The fleet is not damaged; it is simply not maintained until you re-cut.

A cut has its own refusals for its own reasons — a box that is stopped, not
logged in, not hired, or still over `CREW_RESET_CUT_MAX_USED_PCT` of its disk
after the on-demand reaper has run. `crew help reset` has all of them. Re-cut
attended, read what it says, and repair what it names before Sunday.
