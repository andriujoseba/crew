# Labels

The taxonomy shared across the heavy-duty repos. Only the `scope:` set
differs per repo (each repo's `.github/labels.conf` names its actual
surfaces); everything else below is core and identical everywhere, created by
the labels workflow's bootstrap dispatch (issue #10).

Two state machines share the taxonomy: the **PR machine** (proven in
box/rig/cast, reconciled by machinery) and the **issue flow** (the
triage → build queue, reconciled by the work-queue sweep). One rule joins
everything: **states are machine-owned, intent
labels are hand-set** — a hand-moved state label is a lie waiting to happen,
and the reconciler recomputes it from GitHub's own facts.

## PR state — who is the ball with? (exactly one per open PR)

| Label | Color | Waiting on |
|---|---|---|
| `state:building` | `#FBCA04` | the builder — PR is a draft |
| `state:bots-reviewing` | `#1D76DB` | the reviewer panel to finish the round (a request is live) |
| `state:addressing` | `#D93F0B` | the builder — round complete without full approval, or nobody was asked, or a blocker is up, or a ruling is pending |
| `state:needs-human` | `#8250DF` | the human — **this PR could be merged right now**: zero blockers, whole panel approved the current head |

`bots-reviewing` vs `addressing` is deliberate: staleness in the first means
*poke the reviewers*, in the second *the builder dropped the ball*. And
`state:needs-human` means exactly one thing — a human could merge this now —
so it requires zero blockers and head-current approvals; anything less and
the reconciler takes it back. The author sets it at handoff (the one
hand-set state); the `labeled` event fires the sweep that validates the
write within seconds.

## PR blockers — what is in the way? (facts, as many as apply)

| Label | Color | Means |
|---|---|---|
| `blocker:conflict` | `#B60205` | does not merge — the builder owes a **rebase** |
| `blocker:ci-red` | `#B60205` | a check failed — the builder owes a **fix**, which a rebase will not provide |
| `blocker:unrequested` | `#E99695` | this head has no verdict from somebody, and nobody was asked |
| `blocker:drill-pending` | `#B60205` | a `release` PR whose version has no `drills/X.Y.Z.md` record — correct but unevidenced (maintainer-created label; the bot bootstrap 403s on it) |

States answer *whose ball*; blockers answer *what's in the way*. They are
separate axes because the single-label version kept lying — independent facts
projected onto one totally-ordered label meant one always won and the losers
vanished off the board (box's `state:needs-rebase`, retired: the reconciler
strips it on sight).

## Issue flow — the work queue (exactly one per open, triaged, non-epic issue)

| Label | Color | Means | Set by |
|---|---|---|---|
| `needs-triage` | `#FBCA04` | an issue that did not come through triage — it owes normalization or conversion back to a discussion | anyone who spots one; cleared by triage |
| `ready` | `#0E8A16` | triaged, spec complete, unblocked — a builder can start now and succeed | triage |
| `claimed` | `#1D76DB` | a builder owns it: assignee set, a draft PR expected shortly | the claiming builder |
| `blocked` | `#6A737D` | waiting on another issue or PR (`Blocked by #N` in the body names it) | triage; anyone may correct it |
| `epic` | `#5319E7` | organizes other issues via a dependency-ordered task list; **builders never pick an epic** | triage |

The work-queue sweep enforces the invariant a board scan relies on: every open issue is either
`needs-triage`, `epic`, or carries exactly one of `ready` / `claimed` /
`blocked`. It flags conflicts rather than guessing intent. A `claimed` issue
with no open PR and no activity for 48 hours is reclaimed by the sweep: it
comments, unassigns the stale owner, and restores `ready`.

## Cross-cutting (PRs and issues)

| Label | Color | Meaning |
|---|---|---|
| `stale` | `#B60205` | no activity for 48h — sweep-managed, never hand-applied |
| `blocked` | `#6A737D` | (see above — same label serves PRs waiting on another PR/issue; legitimately quiet, the staleness sweep skips it) |
| `offsite` | `#CFD3D7` | issue deliverable is a PR in another repository; set by the builder with the draft link and cleared by the builder at handoff |
| `needs-ruling` | `#D4C5F9` | a human-owned decision is required; use BUILDER.md's ruling template and ladder. Set by triage or the builder; a state, not a signal — it clears on agreement, not on a reply |
| `attention` | `#D93F0B` | issue-only demand parked for the assignee; hand-set, and never written by the machine |
| `release` | `#0E8A16` | release flow, versioning, packaging work — and the ceremony PR itself |
| `merge-next` | `#0E8A16` | head of the merge queue — merge this one next. Queue order is *intent*: never set by the reconciler, only cleared by it |

`needs-ruling` marks where the human's turn is when the pending thing is a
*decision*, not a merge ([#50 D1–D14](https://github.com/heavy-duty/ceremony/issues/50)).
It applies to any human-owned decision — org policy, published artifacts,
secrets, prod, or any choice whose cost lands outside the work. A panel
deadlock is one instance, not the definition (D11). It is not
`state:needs-human`: that label means exactly "this PR could be merged right
now", and the retired `state:needs-rebase` is the family's proof that a
label meaning two things lies about both. It is not a `blocker:*` either:
every blocker names work the *builder* owes, a ruling is owed by the human —
and the flag must live on issues too, where blockers do not exist. On issues
it coexists with the queue labels (the one-of-three invariant above ignores
it); its color is the light shade of `state:needs-human`'s, so the human
axis reads as one family. It is a state, not a signal: set only with the
[canonical escalation contract](BUILDER.md#the-ruling-ask) (D12). A bare
flag is noise. The comment carries exhaustive, mutually exclusive options
(at most three), a mandatory recommendation, what stops and what continues,
and either a default affirmatively known to be reversible inside the PR or
`none — hard block`. Unsure is a block; published artifacts, secrets, prod,
and org policy are hard blocks by construction (D13).

The ruling ladder runs from the current episode's `needs-ruling` **`labeled`
event** (D13–D14):

- **0–12h:** a clear, reversible decision may proceed when its stated default
  expires, saying out loud that it did; anything with reasonable doubt waits
  as a hard block.
- **at 12h:** the setter re-reads the default against what has landed and asks
  whether it still holds and whether doubt remains. A stale default does not
  fire; new doubt makes it a hard block.
- **at 24h:** the builder proceeds regardless, **as a PR**, stating the option
  chosen and the doubt that remains. Nothing merges by this; the human still
  gates the merge.
- **past 24h:** triage picks the option, records it as a decision, and remains
  accountable. The operator may overturn it at merge.

A re-flag starts a new ladder. The rungs apply whatever `Default:` says,
including a hard block. Active discussion still climbs the ladder; by
contrast, the separate 7-day nudge resets on real activity. The machine
observes the rungs but never sets, clears, or decides `needs-ruling`.

The flag stays up until agreement is *reached* — a human reply alone does not
clear it — and its setter closes it out: records the ruling as a decision in
one comment, removes the label, and returns the item to its flow in that same
comment, never as a side effect. If the human disagrees that agreement was
reached, the label goes back on. The reconciler refuses `state:needs-human`
while it stands (the PR falls to `state:addressing` — the ball on the PR is
the builder's, who carries the ruling in), and the staleness sweep skips it,
because waiting on a human is legitimately quiet. Quiet, but not unwatched
(#52, both surfaces): a flag set with no escalation comment from its setter
is called out by the sweep — comment-only, scoped to the labeled event, the
label never removed — and a ruling with no real activity for 7 days draws a
comment-only nudge addressed to the decider, linking the escalation. The
nudge carries no marker on purpose: the comment is itself activity, so it
resets its own window and never repeats within a quiet week. Label churn is
not activity — the clock reads comments, reviews and commits, or the sweep
would reset itself.

`offsite` is issue-only and records that a claimed issue's deliverable lives
in another repository, where a closing reference cannot make a local open PR
visible to the sweep (#68). The builder sets it in the same step that posts
the cross-repo draft link, then clears it at handoff in the same comment that
reports whether that PR merged or closed. The machine reads the flag and
never writes it. It stops only the claim-reclaim clock: missing assignees are
still flagged, queue-label conflicts and missing queue state are still
repaired, and epic-completion and PR-side stale behavior are unchanged. The
sweep tells the assignee once when every visible cross-referenced PR has
closed; it only tells, and never clears the flag or changes the claim.

`attention` is issue-only and says a demand is parked on an issue for its
assignee. Anyone who needs that assignee's hands — triage, the operator, or a
sibling agent — sets it. The assignee alone clears it, as the first act of
pickup together with a short comment; that removal is the acknowledgement
and re-arms the flag for the next demand. If the session dies before the ack,
the still-visible flag launches the next pickup instead. An unanswered flag
is auditable evidence on the board.

The flag is additive: it composes with `ready`, `claimed`, or `blocked` and
with `needs-ruling`, and never substitutes for queue state. It pauses no
clock. Unlike `offsite` and `needs-ruling`, which make silence legitimate,
unanswered `attention` is exactly the silence the 48-hour reclaim should
take. It is hand-set doctrine only: nothing in `actions/` sets, clears,
reads, or validates it, and no reconciler enforces the assignee requirement.
An `attention` issue without an assignee is therefore a board bug, not a
demand; anyone may assign it or remove the flag.

The three signals are mutually distinct: `attention` means an assignee owes
a move; `needs-ruling` means a human owes a decision under
[the escalation contract and ladder](BUILDER.md#the-ruling-ask); and a bare
`@`-mention is an FYI that demands nothing and remains perfectly fine. A
demand that is itself a human decision carries `needs-ruling`, never both.
This distinction records the
[#16 missed-ruling incident](https://github.com/heavy-duty/ceremony/issues/16#issuecomment-5061051198)
and why the rejected mention poll is not returning: ordinary thread traffic
re-arms mentions, but only the writer can declare that a move is owed (#83).

## Scope — which surface? (PRs and issues, any number)

All scopes share one calm color, `#C5DEF5` — scopes locate, states alert. The
set is per-repo: PRs get theirs from changed paths via the labels workflow's
scope job — an additive write only, so a label applied by hand or by an agent
while the machine runs always survives it (#130) — and issues get theirs from
triage. This file never enumerates a set — it is mirrored
byte-identically into every governed repo, and any list it carried would be
true in one repo and false in the rest (#104). The set for the repo you are
standing in lives in the two places that are true wherever you read them: its
`.github/labels.conf` (the definitions, one `name|color|description` row per
scope) and its own `CONTRIBUTING.md`, beside the other repo-specific facts.

## Issue types

`bug`, `enhancement`, `documentation` — issues only, set by triage. PRs carry
their type in the conventional title (`feat:`, `fix:`, `docs:`); a type label
on a PR would say the same thing twice and drift.

## Maintenance

The labels workflow (issue #10) recomputes PR state statelessly on PR events
plus a 15-minute advisory cron, and bootstraps this taxonomy idempotently on
manual dispatch. The sweep warns when the core taxonomy declares a label the
repository lacks. The same workflow reconciles issue-flow labels on issue
events and during the scheduled sweep. Default GitHub labels (`duplicate`,
`invalid`, `question`, `wontfix`, `help wanted`, `good first issue`) are
deleted at bootstrap — a `question` is a discussion, not an issue.
