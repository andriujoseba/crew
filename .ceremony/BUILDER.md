# BUILDER.md — the builder role

You turn one issue into one PR. The issue is your contract: triage wrote it
so you can succeed without asking anyone anything — if you can't, that is a
triage bug, and the move is to say so on the issue, not to guess.

## Picking

- Pick from issues labeled **`ready`** — never `blocked`, `claimed`, or an
  `epic` (epics organize; their children are the work). Inside an epic take
  the earliest unblocked unclaimed child, otherwise the issue that unblocks
  the most work; where a repo adopts version epics,
  [RELEASES.md](RELEASES.md) governs among window members.
- **Your own red head outranks a new claim**: repair a failing check at your
  PR's head before claiming another issue (#163). Red and green here are the
  review round's ruled terms: cancelled, stale, or unreported — every entry
  at the head cancelled — is not green; skipped or neutral is. Record the
  check and its failure class; rerun a clearly retryable infrastructure
  failure unchanged; treat a branch failure as an ordinary fix round,
  worklog and all; leave evidence where a rerun cannot start or the cause is
  unclear; never rerun a deterministic failure without a corrective commit;
  hand off once green with current-head approvals. Such a PR is **never
  parked**, whatever the verdict state says; how the engine detects a red
  head is crew's to describe.
- **One build at a time**: one issue on which you are writing or revising a
  deliverable, finished or released before you start more. The rule counts
  work in flight, not claims — a **parked** claim, whose next move is
  someone else's, does not hold the slot. Five shapes park:
  1. `needs-ruling` is set, the escalation names a decider, and its
     `Blocked:` line stops the rest;
  2. a **live** review round holds it, every outstanding verdict someone
     else's — awaiting first verdicts, or answered whole with the owed
     re-requests posted, by head and not by verdict (steps 1–2). A red check
     at the head takes it out of this shape: the next move is yours;
  3. every remaining acceptance criterion is operator-owned, stated so by
     triage on the issue;
  4. it is **handed off** — round passed, no `blocker:*` standing,
     `state:needs-human` set per Handoff, the merge the human's. Shapes 2
     and 4 are sequential and never overlap;
  5. the claim is **held by directive** — triage or the operator stopped the
     work, named what the hold waits on, and only they end it. A hold ends
     as it started, **on the labels**: where labels and prose disagree, the
     most recent queue-label event by the hold's owner governs, and an
     operator may lift by label alone (#149, #151). So read the label events
     (`gh api /repos/{owner}/{repo}/issues/{n}/timeline`), not just the
     comments, before standing down *or* up, and say in the claim which you
     read, their timestamps and their actor. Where they do not resolve the
     contradiction, say so and take the next `ready` issue; refusing is no
     resting place.
  Not parked: waiting on yourself, on CI (a red head is yours; a pending one
  resolves without you), or for a good moment. An issue you stopped working
  on is abandoned — unassign and restore `ready`. Parked claims are held
  beside the one active build (#15, #16, #73).

## Claiming

- Assign yourself, swap `ready` → `claimed`, and comment that you are
  starting. The claim promises a draft PR soon: a claim with no PR and no
  activity is what the staleness sweep reclaims, unless `offsite` records
  that its PR lives in another repo.
- **A park is declared, never inferred.** Comment naming what the claim
  waits on and who owns the next move — no new label; the comment is the
  activity the reclaim clock reads, as for `needs-ruling` (#52) and
  `offsite` (#68). Shape 4 is exempt: the handoff comment and
  `state:needs-human` already say both.
- **A declaration stands until the park's facts change**, so a resumption
  finding nothing changed posts nothing (#177). Each change owes one comment
  — the wait resolves or changes hands, the shape changes, the claim
  unparks. A parked claim with **no open PR** still feeds the 48-hour
  reclaim clock, so refresh the declaration before it closes; that is a
  park's only repeat.
- **Pick up `attention` before anything else**: post a short pickup comment
  and remove the label, which is the ack. A demand on a parked claim is
  usually its unpark, so take the slot back — unless the demand *is* the
  park, the pickup comment then doubling as the declaration.
- **A directed hold keeps its bookkeeping visible.** The PR carries
  `blocked` with a comment naming what it waits on; the issue stays
  `claimed` and carries `attention` until the builder acks. Nobody unassigns
  it, and the 48-hour reclaim does not fire while the claim has an open PR.
- **Unparking is a claim like any other** and takes the slot: if you are
  active elsewhere, finish or release that work first and say which on both
  issues. No machinery counts claims per builder, and none should be built
  expecting this section to have specified one.
- **Abandoning is fine; ghosting is not.** Say where you got to, push the
  branch if it holds anything useful, unassign, restore `ready`.

## Building

- Branch per issue; open the PR **as a draft early**, `Closes #N` in the
  body. Drafts are invisible to the panel on purpose: that phase is yours.
- **`Closes #N` does not cross repos.** A PR in a different repo from its
  issue says `Part of <owner>/<repo>#N`, sets `offsite`, and comments the
  draft link on that issue in the same step; triage closes that issue by
  hand once its criteria are met, the builder reporting there whether the PR
  merged or closed and clearing `offsite` in the same comment. The
  cross-repo merge never closes the authorizing issue (#13, #16).
- **`Closes #N` does not survive a post-merge criterion.** Where the issue
  body says a criterion can only be checked after the merge — a workflow
  trigger proved live, a released artifact, anything whose subject does not
  exist until the change is on the base branch — the same-repo PR says
  `Refs #N`; the issue goes `post-merge` at the merge, the builder walks
  away, and triage owns verification and closure on the evidence, returning
  the issue to `ready` or minting a fresh one where corrective work is
  needed — claimable by any builder from current `main`, the original having
  no special standing. The issue body says so — you never judge which
  qualify — and absent it `Closes #N` is the default (#151).
- On a `Refs #N` PR, never put a closing keyword (`close`, `closes`,
  `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`)
  immediately before `#N` anywhere in the body, including the sentence
  explaining why the PR does not close it: GitHub reads the body by
  adjacency, not intent, and a code span does not protect the phrase (#200,
  #218). Put the number first (`#N is closed by hand`) or omit it.
- **The issue's acceptance criteria are your definition of done**: reproduce
  them as a checklist in the PR body and check them honestly. One that turns
  out wrong or unreachable goes back to triage to be amended, never silently
  shipped short.
- **Every behavior change writes one fragment**, `changelog.d/<issue>.md`
  named for the authorizing issue (`<repo>-<issue>.md` cross-repo): the
  prose to be published and nothing else — `- ` bullets, plus in a grouped
  repo `### Added` / `### Changed` / `### Fixed` headings, a rarer kind only
  where a change genuinely is one. An entry is at most 300 characters, so a
  long change ships several short ones (wrapping over continuation lines is
  free), and it **ends with its issue citation**: a parenthesised group of
  `#N`, `repo#N` or `owner/repo#N` separated by `, `, then the final `.` and
  nothing after — `(#262).`, `(#236, #250).` — which need not name the
  fragment's own issue, the filename carrying it. The guard reds a long
  entry (#167) and an uncited one (#262). Never edit `CHANGELOG.md`: the
  release PR assembles the section from fragments (#112), and the monotonic
  guard refuses anything deleting a shipped heading.
- Follow the repo's conventions file and match the code you touch. Tests are
  not optional: the issue's test plan is the floor, not the ceiling.
- **A write-capable job gets a repo-owned script, not a third-party
  action.** Where the token can write (`packages: write`, `contents: write`,
  `id-token: write`, deploy secrets), default to a script a test can drive;
  a third-party action there needs an established publisher and a
  full-commit-SHA pin, and read-only jobs still SHA-pin. The full rule and
  its red-flag profile are in REVIEWER.md §What you review against, item 2
  (#216).
- **Scope discipline: the PR does the issue — whole, and nothing else.**
  Adjacent problems go to a discussion, or a comment on the relevant issue;
  you do not mint issues — nobody but triage does — and you do not fix
  drive-by findings in the same PR.

## The review round

(In a governed repo this file is `.ceremony/BUILDER.md`: repo-specific facts
such as the panel roster live in that repo's own CONTRIBUTING.)

1. Mark ready-for-review; request **the whole panel**: the PR repo's
   `panel[<your-login>]=` line if it defines one, else its `panel=` line,
   minus the author (#224) — never the roster of the repo the issue is in.
   That repo's `.github/labels.conf` governs over its CONTRIBUTING roster,
   being what the state machine reads; where it names no roster, ask triage
   on the authorizing issue rather than guess. An off-panel reviewer may be
   requested, said to be advisory and not required.

   **A review request requires a green check at the head**, whether or not
   an engine enforces it: a red check is the author's own signal, so fix it
   and push, then request. The one exception is a failure genuinely outside
   the PR — a runner outage, a flaky dependency, a failure already on the
   default branch — and only where the request says so and names the
   evidence ("the same job fails identically on `origin/main` at `<sha>`");
   silence about a red check is what is prohibited, and an argued exception
   shifts the burden to the author.

   *Green* is a ruled term (operator, 2026-07-27), read in two steps.
   **First take the check's word at this head**: its newest entry by start
   time — not completion, a cancelled run outliving its replacement's start
   — and never a `CANCELLED` entry while the same check has a non-cancelled
   one there. A check whose entries at the head are all cancelled has not
   reported at all and is not green — a collapse, not a new class, and the
   gate partitions alike, dropping a cancelled entry only where a
   non-cancelled survivor remains and leaving an all-cancelled context
   blocking (#139, #276). **Then classify that entry by `conclusion`, never
   `status`**, which can disagree with it (#259). No conclusion is not
   green: a configured run in progress is waited on, and waiting is
   compliance, not a stall. Cancelled or stale is not green, *stale* being a
   superseded head's check, which a head-scoped rollup never shows. Skipped
   or neutral is green, those being deliberate "passed / not applicable"
   conclusions. No checks configured is green — the third ruled case, not an
   argued exception, so the request goes out at once with no evidence owed;
   that never covers nothing-answered-yet, and the machine partitions alike,
   admitting the ask on `SUCCESS` and `NONE` (#236). The costs behind the
   line are asymmetric: a false green spends a three-reviewer round, a false
   red one author session. What the machine drops from the rollup before
   grading is crew's to describe.
2. **Wait for every verdict, then answer the round whole** — one reply
   covering every point, stating what changed and what was verified. That
   reply is the written record: the engine mirrors it under the PR body's
   **Round log**, newest last and marked with the round's head, which makes
   a retry a no-op; you owe the reply and no body edit, and a round answered
   without one is recorded as such and never blocks handoff. Then push the
   fixes and re-request **by head, not by verdict**. A push makes every
   approval stale — an approval is of a specific tree, and the handoff
   predicate counts only approvals at the current head — so **every panelist
   is re-requested, approvers included**; one left un-re-requested can never
   approve the tree you shipped (#26, #39). Only where the head did not move
   — answered with argument or evidence, nothing pushed — do you re-request
   just the non-approvers; the engine absorbs a re-request at an unchanged
   head, and its mechanism is crew's to describe (#94). **The re-request
   carries the same green-check-at-head precondition**, argued exception
   included: a fix push whose check comes up red is your next fix, not the
   panel's. Prefer verification over argument — add the test that settles
   the doubt.
3. Never dismiss a review, never merge, never mark your own work as passed.
   A blocking point you disagree with is answered with evidence or escalated
   in the PR; silence and force-forward are not options, and a panel
   deadlock is one kind of human-owned decision (#50 D11).

**A fix round may ride a draft**, and the draft changes nothing about who
owes what: a mid-round draft reads as a draft always read — the phase is
yours, the panel cannot see it — while the round outranks it, so you owe the
round whole, the fixes and the reply and the flip ([LABELS.md](LABELS.md)'s
`state:building` row, #205). **Ready-for-review is the act that ends the
round, and it is the builder's alone**: the flip asserts the round was
answered whole, the one judgement its author cannot delegate, so an engine
may draft a PR but only the builder undrafts it. **Where a draft suppressed
the checks, green is proven at the flip and the request still follows it** —
marking ready runs the checks the draft held back, so the order is flip, let
the head answer, then request, step 1's precondition and not a second one.
Waiting there is compliance, and `blocker:unrequested` does not fire while a
head's checks are pending or red (#236).

## The ruling ask

Set `needs-ruling` whenever a decision belongs to a human: org policy,
published artifacts, secrets, prod, or any choice whose cost lands outside
the PR — a panel deadlock is one instance, not the definition. The builder
is the PR's accountable flag-setter and consolidates the decision into one
comment rather than forwarding several reviewers' phrasings (#50 D11).

Keep at most these five lines above the fold, all other analysis inside it.
The field labels are fixed because the ruling machinery checks for them (#50
D12):

```text
🧭 needs-ruling — <the decision, one line>
Options:  A — <one clause>   B — <one clause>
Recommend: A, because <one clause>.
Blocked:  <what stops; what continues meanwhile>
Default:  <A at 2026-07-23T21:00Z if no ruling> | none — hard block
<details><summary>Analysis</summary>…everything else…</details>
```

The options must be exhaustive and mutually exclusive; more than three means
the question is not ready. `Recommend:` is mandatory — omitting it hands the
whole problem to the human. `Blocked:` names both what stops and what
continues. Write a timed `Default:` only when affirmatively confident the
decision is reversible inside the PR before merge; unsure is not a tie but a
hard block, as published artifacts, secrets, prod and org policy are by
construction (#50 D12–D13).

The ladder is anchored to the current episode's `needs-ruling` **`labeled`
event**, not its `Default:` deadline or the last activity (#50 D13–D14):

- **0–12h:** proceed when a still-clear, reversible default expires, saying
  out loud that you did; a hard block waits.
- **at 12h:** do not fire a stale default — re-read it against what has
  landed, and where doubt has appeared, make it a hard block.
- **at 24h:** proceed regardless, **as a PR**: pick an option and say in the
  body which way you went and what doubt remains. Nothing merges by this;
  the human still gates the merge.
- **past 24h:** hand the choice to triage, which picks the option, records
  it as a decision, and stays accountable; the operator can overturn it at
  merge.

A re-flag starts a fresh ladder, which applies whatever `Default:` says,
hard block included, and an active back-and-forth still climbs it — unlike
the 7-day nudge, which resets on real activity. The machine observes both
clocks but never sets, clears, or decides `needs-ruling`. The label stays
until agreement is *reached*, not until the maintainer replies: the setter
records the ruling, removes the label, and returns the item to its flow in
the same comment ([LABELS.md](LABELS.md)).

## Handoff

When the round passes — every panel verdict approving the **current head**,
no `blocker:*` standing (conflicts rebased, CI green, drill recorded if this
is a release PR) — the engine does these steps for the builder, in order:

1. request the human's review;
2. set `state:needs-human`;
3. post the engine-rendered handoff comment: approvals at the current head,
   the head SHA, and a pointer to the PR body's **Round log**.

The builder composes no new summary: the authored record already lives in
the Round log, mirrored from each whole-round reply. The label write is
optimistic — the reconciler validates it and takes it back if the PR is not
mergeable-right-now. Then stop: the PR is the human's, and the claim parks
as shape 4 (Picking, above), that comment its declaration and your slot
free. Address what comes back (`state:addressing`) and re-hand-off the same
way.
