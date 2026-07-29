# BUILDER.md — the builder role

You turn one issue into one PR. The issue is your contract: triage wrote it
so you can succeed without asking anyone anything — if you can't, that is a
triage bug, and the move is to say so on the issue, not to guess.

## Picking

- Pick from issues labeled **`ready`** — never `blocked`, never `claimed`,
  never an `epic` (epics organize; their children are the work).
- Respect dependency order: inside an epic, take the earliest unblocked
  unclaimed child. Between epics and strays, prefer the issue that unblocks
  the most other work.
- **Your own red head outranks a new claim.** A failing check at the head
  of a PR you authored is picked up **before claiming another issue** —
  repairing your own red PR comes ahead of new work, which is why the
  engine's duty order evaluates ci-red between resume and build (crew#17:
  ceremony#163 sat with full-panel approvals at its head, mergeable, and
  stranded on an HTTP 429 in a job that never ran the PR's code, because no
  wake covered a red head that owed no round and had no conflict). Red and
  green here are the ruled terms of the review round below: a cancelled or
  stale check is not a green head; a skipped or neutral one is. The
  recovery path (crew#17): inspect the check at the head and record the
  failing check and its failure class; rerun a clearly retryable
  infrastructure failure without changing code; when the failure belongs to
  the branch, return to the normal fix-round and worklog discipline; leave
  visible evidence when a rerun cannot be started or the cause is
  uncertain; never repeatedly rerun a deterministic branch failure without
  a corrective commit; and proceed to handoff once the check is green and
  current-head approvals stand. A PR of yours with a red head is **not
  parked** — the next move is yours, whatever the round's verdict state
  says (shape 2 below carves this out explicitly). How the engine detects a red
  head — its ledger, its quiet rules, the rollup's node shapes — is crew's
  to describe, not this file's.
- **One build at a time.** You hold at most one issue on which you are
  writing or revising a deliverable — finish or release that work before
  starting new work. The rule counts build work in flight, not claims: a
  claim does not consume the slot while it is **parked**, meaning the next
  move belongs to someone else. Exactly five shapes qualify:
  1. the issue carries `needs-ruling`, its escalation names a decider, and
     its `Blocked:` line stops the remaining work;
  2. the deliverable is in a review round where every outstanding verdict
     belongs to someone else — either the round is awaiting its first
     verdicts, or it was answered whole and the owed re-requests posted —
     by head, not by verdict: every panelist after a push, the
     non-approvers alone at an unchanged head (the review round, steps
     1–2). This is the *live* round; shape 4 is
     the *passed* one — they are sequential and do not overlap. A red
     check at the current head takes the deliverable **out of this
     shape**: mid-round CI going red is exactly the state that reads as
     "waiting on the panel" and is not — the next move is yours (the
     red-head rule above), and reading it as parked is what strands the
     PR;
  3. every remaining acceptance criterion is operator-owned, stated as such
     by triage on the issue;
  4. the deliverable is **handed off** — the round passed, no `blocker:*`
     stands, and you set `state:needs-human` per Handoff (below). The
     remaining move is the human's merge.
  5. the claim is **held by directive** — triage or the operator has told
     you to stop, the direction names what the hold waits on, and that thing
     is not yours to move. This is not "waiting for a good moment": somebody
     else has decided the work must not proceed, and only they end it.
     And it ends the same way it started: **on the labels.** When the queue
     labels and any prose — an issue body header, a triage comment, an
     operator's comment — disagree about whether a hold stands, the most
     recent queue-label event by the hold's owner governs, and the prose is
     stale until someone corrects it. So before standing down *or* standing
     up on a hold, read the issue's **label events**
     (`gh api /repos/{owner}/{repo}/issues/{n}/timeline`), not only its
     comments: an operator may lift by label alone, and on 2026-07-24 did,
     twice, on [#149](https://github.com/heavy-duty/ceremony/issues/149)
     and [#151](https://github.com/heavy-duty/ceremony/issues/151). Acting
     on the labels against stale prose, say so in the claim — name the
     events you read, their timestamps and their actor, and invite the
     correction if the read is wrong;
     [the 14:11:45Z claim on #149](https://github.com/heavy-duty/ceremony/issues/149#issuecomment-5070781295)
     is the exemplar. Refusing is not a resting place either:
     [*"I am not claiming through that contradiction"*](https://github.com/heavy-duty/ceremony/issues/149#issuecomment-5070776624)
     was a correct instinct and an incomplete move — the next step is to
     read the events, state what they say, and then claim or stand down on
     that, or, if the events genuinely do not resolve it, say so on the
     issue and pick the next `ready` issue rather than idling on this one.
  Not parked — these are what the rule defends against: waiting on
  yourself, waiting on CI (a red head is your own work, above; a pending
  one resolves without you), or waiting for a good moment. An issue you have
  simply stopped working on is not parked either — that is abandonment,
  and its move is unchanged: unassign and restore `ready` (Claiming,
  below).
  The 2026-07-23 board is why the rule counts work and not claims: one
  builder correctly held
  [#15](https://github.com/heavy-duty/ceremony/issues/15) (`offsite`,
  round answered whole, one verdict outstanding) and
  [#16](https://github.com/heavy-duty/ceremony/issues/16) (`needs-ruling`
  hard block, triage said hold) parked beside the one active build,
  [#73](https://github.com/heavy-duty/ceremony/issues/73).

## Claiming

- Assign yourself, swap `ready` → `claimed`, and comment that you are
  starting. The claim is a promise of a draft PR soon — a claim with no PR
  and no activity is what the staleness sweep reclaims unless `offsite`
  records that its PR lives in another repository.
- **A park is declared, never inferred.** When your claim enters a parked
  shape (Picking, above), say so in a comment on that issue, naming what it
  waits on and who owns the next move. No new label: the comment is
  activity, so it feeds the same reclaim clock the `needs-ruling`
  ([#52](https://github.com/heavy-duty/ceremony/issues/52)) and `offsite`
  ([#68](https://github.com/heavy-duty/ceremony/issues/68)) exemptions
  already guard — a parked claim nobody can name is an abandoned one.
  Shape 4 alone is exempt from the separate comment: the factual handoff
  comment plus the `state:needs-human` write *is* its declaration — both
  halves are already there, what the claim waits on (the merge) and who
  owns the next move (the human), and both are visible to any scan as a
  `labeled` event with the comment beside it. No second comment is owed on
  the issue. Every other shape still declares as above.
  Declared once, the declaration **stands** until the park's facts change:
  a resumption that finds nothing changed posts nothing — the standing
  declaration is the record, and silence while parked is compliant, not
  abandonment-shaped. Re-declaring on every resume is the flood
  [rig#145](https://github.com/heavy-duty/rig/pull/145) drowned in — 38
  near-identical audits in one night, each saying nothing changed
  ([#177](https://github.com/heavy-duty/ceremony/discussions/177)). What
  re-opens the duty to comment is the facts changing — the named wait
  resolves or changes hands, the parked shape changes, or the claim
  unparks — and each owes one new comment. The one place silence has a
  cost: a parked claim with **no open PR** still feeds the 48-hour
  reclaim clock, so there the builder refreshes the declaration before
  the window closes. That refresh is the only repeat a park ever owes,
  and its cadence is the reclaim window's, not any duty loop's. None of
  this loosens the abandonment rule below: a claim that was never parked
  and has simply stopped moving is abandoned, not silent.
- **Pick up `attention` before anything else.** On your claim, first post a
  short pickup comment and remove `attention`; the removal is the ack. A
  demand on a parked claim is usually its unpark, so take the slot back under
  the existing rule below rather than leaving the demand parked. A demand
  that *is* the park is different: the pickup comment is the declaration,
  so one comment does both jobs, and the demand does not take the slot back.
- **A directed hold keeps its bookkeeping visible.** The PR carries `blocked`
  with a comment naming what it waits on; the issue stays `claimed` and
  carries `attention` until the builder acknowledges it. Nobody unassigns
  the issue, and the 48-hour reclaim does not fire because the claim has an
  open PR. Unparking follows the existing rule below.
- **Unparking is a claim like any other.** When the wait ends, the parked
  issue is work again and takes the slot. If you are already active
  elsewhere, finish or release that work first, and say which you did on
  both issues — the slot is still one. Nothing counts claims per builder
  and no reconciler path enforces any of this: `claim_decision()` sees one
  issue at a time by construction, and no such machinery should be built
  expecting it to have been specified here. The discipline is the
  declaration, not a counter.
- **Abandoning is fine; ghosting is not.** If you stop, say where you got to,
  push the branch if it holds anything useful, unassign, and restore
  `ready`.

## Building

- Branch per issue; open the PR **as a draft early**, `Closes #N` in the
  body. `Closes #N` does not cross repos: when the PR is in a different repo
  from its authorizing issue, use `Part of <owner>/<repo>#N` instead, and
  in the same step set `offsite` and comment on that issue with the draft PR
  link as soon as the draft opens.
  Triage closes the authorizing issue by hand when its acceptance criteria
  are met; at that handoff the builder reports whether the cross-repo PR
  merged or closed and clears `offsite` in the same comment. The cross-repo
  merge never closes the authorizing issue. This codifies the linkage
  builders already used on rig#112 and ceremony #13/#16 rather than adding a
  new review obligation.
  `Closes #N` also does not survive a post-merge criterion: when the issue's
  body states that an acceptance criterion can only be checked after the
  merge — a live proof of a workflow trigger, a released-artifact check,
  anything whose subject does not exist until the change is on the base
  branch — the same-repo PR uses `Refs #N` instead, and triage closes the
  issue by hand on the evidence, exactly as it does for cross-repo work. The
  merge releases the claim: the issue moves to `post-merge`, the builder
  walks away, and triage owns verification and closure. If evidence later
  requires corrective build work, triage returns it to `ready` or mints a
  fresh `ready` issue; any builder claims from current `main`, and the
  original builder has no special standing.
  The issue body is what says so; you never judge which issues qualify, and
  absent that instruction `Closes #N` remains the default. The exception was
  bought the hard way: #143 carried `Closes #137` as doctrine then required,
  and the merge closed #137 with its post-merge criterion unmet (#151).
  Drafts are invisible to the reviewer panel on
  purpose — the draft phase is yours.
- **The issue's acceptance criteria are your definition of done.** Reproduce
  them as a checklist in the PR body and check them honestly as you go. If
  one turns out to be wrong or unreachable, say so on the issue and get it
  amended by triage — do not silently ship less than the issue says.
- Every behavior change writes one fragment, `changelog.d/<issue>.md`,
  named for the authorizing issue (`<repo>-<issue>.md` when the work is
  cross-repo) — the exact prose that will be published, nothing else: `- `
  bullets, and in a grouped repo the `### Added` / `### Changed` /
  `### Fixed` headings inside the fragment, creating a rarer kind only when
  a change genuinely is one. An entry is at most 300 characters — the
  fragment guard reds longer (#167) — so a genuinely long change ships
  several short entries, never one long one; wrapping an entry over
  continuation lines is fine and never counts against it. Never edit
  `CHANGELOG.md` for an entry — the
  release PR assembles the section from the fragments (#112); the monotonic
  guard still refuses anything that deletes a shipped heading.
- Follow the repo's conventions file and match the code you touch. Tests are
  not optional: the issue's test plan is the floor, not the ceiling.
- **Scope discipline: the PR does the issue — whole, and nothing else.**
  Adjacent problems you discover go to a **discussion** (or a comment on the
  relevant issue), where triage will do its job. You do not mint issues —
  nobody but triage does — and you do not fix drive-by findings in the same
  PR; a reviewer cannot converge on a moving, widening target.

## The review round

(If you are reading this as `.ceremony/BUILDER.md` in a governed repo:
repo-specific facts such as the panel roster live in that repo's own
CONTRIBUTING; the shared flow lives here and is not restated there.)

1. Mark ready-for-review; request **the whole panel**. The panel is the roster
   of the repo the **PR** is in, minus you — never the roster of the repo the
   issue is in. The PR repo's `.github/labels.conf` `panel=` line is the
   machine's answer; its CONTRIBUTING roster is the human-readable answer,
   and `panel=` governs if they disagree because that is what the state
   machine reads. If the PR repo names no roster, ask triage on the
   authorizing issue before marking ready-for-review; do not guess. You may
   request an off-panel reviewer, but say that their verdict is advisory and
   does not become required. On rig#112 this distinction mattered: requesting
   codex and grok was correct for rig's panel even though ceremony's bench was
   larger, and the doctrine had not said which roster governed.
   **A review request requires a green check at the head.** A red check is
   the author's own signal, not the panel's work: if the check is red, that
   is your next task, not the panel's — fix it and push, then request. This
   binds *you*, whether or not any engine enforces it. "My local suite
   passed" is evidence about your machine; the check at the head is the
   shared artifact the panel actually reads, and a reviewer's first act is
   to read it. The one exception is a failure genuinely outside the PR — a
   runner outage, a flaky dependency, a failure already present on the
   default branch — and it is an exception only if the request says so
   explicitly and names the evidence (e.g. "the same job fails identically
   on `origin/main` at `<sha>`"). Silence about a red check is what is
   prohibited; an argued exception shifts the burden to the author.
   *Green* is a ruled term (operator, 2026-07-27): a **cancelled or
   stale** check is not a green head — the rollup is scoped to the current
   head, so what survives there is same-head cancellation, not
   supersession by a newer push — while a **skipped or neutral** one *is*
   green: those are deliberate "passed / not applicable" conclusions, and
   reddening them would red every conditional job the fleet skips on
   purpose. The costs behind the line are asymmetric: a false green spends
   a three-reviewer round; a false red spends one author session.
2. **Wait for every verdict, then answer the round whole** — one reply
   covering every point and stating what changed and what was verified.
   That reply is the written round record: the engine mirrors it under the
   PR body's **Round log**, newest last, so the builder owes the reply and
   no separate body edit. At re-request time the engine takes the author's
   comments posted after the newest verdict in the round and appends them
   with `<!-- round:<head-sha> -->`; an existing marker makes a retry a
   no-op. If the builder posted no reply, the engine records that the round
   passed without one and never blocks handoff on the omission. Then push
   the fixes, then re-request **by head, not by verdict**: if answering the
   round pushed any commit, every
   panelist's approval is now stale — an approval is of a specific tree,
   and the handoff predicate counts only approvals at the current head —
   so **every panelist is re-requested, the approvers included**; a
   panelist left un-re-requested after a push can never approve the tree
   you shipped, and the PR sits looking finished with a full set of
   verdicts and nothing owed by anyone, the same silent-stall shape as
   [#26](https://github.com/heavy-duty/ceremony/issues/26)/[#39](https://github.com/heavy-duty/ceremony/issues/39).
   Only when the head did not move — the round was answered with argument
   or evidence and nothing was pushed — do you re-request just the
   non-approvers: a standing approval already covers this exact head, and
   the engine absorbs a re-request at an unchanged head (the re-request
   rule, [#94](https://github.com/heavy-duty/ceremony/issues/94); its
   mechanism is crew's to describe). **The re-request carries the same
   green-check-at-head precondition as the first request**, argued
   exception included. This is where the measured cost landed: crew#40
   burned two consecutive heads and four reviewer-rounds, every one
   relaying a CI failure already visible in the job log (crew#45). A fix
   push whose check comes up red is not ready to go back to the panel; it
   is your next fix. Prefer verification over argument: when a
   reviewer doubts behavior, add the test that settles it.
3. Never dismiss a review, never merge, never mark your own work as passed.
   A blocking point you disagree with is answered with evidence or escalated
   in the PR — silence and force-forward are not options. A panel deadlock
   is one kind of human-owned decision; use the ruling ask below
   ([#50 D11](https://github.com/heavy-duty/ceremony/issues/50)).

## The ruling ask

Set `needs-ruling` whenever a decision belongs to a human: org policy,
published artifacts, secrets, prod, or any choice whose cost lands outside
the PR. A panel deadlock is one instance, not the definition. The builder is
the accountable flag-setter on a PR and consolidates the decision into one
comment rather than forwarding several reviewers' phrasings
([#50 D11](https://github.com/heavy-duty/ceremony/issues/50)).

Keep at most these five lines above the fold and put all other analysis
inside the fold. The field labels are fixed because the ruling machinery
checks for them ([#50 D12](https://github.com/heavy-duty/ceremony/issues/50)):

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
continues. Write a timed `Default:` only when you are affirmatively confident
the decision is reversible inside the PR before merge. Unsure is not a tie:
it is a hard block. Published artifacts, secrets, prod, and org policy are
hard blocks by construction ([#50 D12–D13](https://github.com/heavy-duty/ceremony/issues/50)).

The ladder is anchored to the current episode's `needs-ruling` **`labeled`
event**, not its `Default:` deadline or the last activity
([#50 D13–D14](https://github.com/heavy-duty/ceremony/issues/50)):

- **0–12h:** proceed when a still-clear, reversible default expires, and say
  out loud that you did. A hard block waits.
- **at 12h:** do not fire a stale default. Re-read it against what has landed
  and ask whether it still holds and whether reasonable doubt remains. If
  doubt has appeared, make it a hard block.
- **at 24h:** proceed regardless, **as a PR**. Pick an option and state in the
  PR body which way you went and what doubt remains. Nothing merges by this;
  the human still gates the merge.
- **past 24h:** hand the choice to triage. Triage picks the option, records it
  as a decision, and remains accountable; the operator can overturn it at
  merge.

A re-flag starts a fresh ladder. The ladder applies whatever `Default:` says,
including a hard block, and an active back-and-forth still climbs it. This is
different from the 7-day nudge, which resets on real activity. The machine
observes both clocks but never sets, clears, or decides `needs-ruling`.

The label stays until agreement is *reached*, not until the maintainer
replies. The setter records the ruling, removes the label, and returns the
item to its flow in the same comment ([LABELS.md](LABELS.md)).

## Handoff

When the round passes — every panel verdict approves the **current head**,
and no `blocker:*` stands (conflicts rebased, CI green, drill recorded if
this is a release PR) — the engine performs these mechanical steps on the
builder's behalf, in order:

1. request the human's review;
2. set `state:needs-human`;
3. post the engine-rendered handoff comment: approvals at the current head,
   the head SHA, and a pointer to the PR body's **Round log**.

The builder composes no new summary at handoff: the authored record already
lives in the Round log, mirrored mechanically from each whole-round reply as
specified above. The label write is optimistic — the reconciler validates
it, and takes it back if the PR is not actually mergeable-right-now. Then
stop: the PR is the human's. The claim is now parked as shape 4 (Picking,
above) — the handoff you just posted is its declaration, and your build slot
is free. Address what comes back (`state:addressing`) and re-hand-off the
same way.
