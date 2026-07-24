# Knowledge

## Only-mine — not in any doctrine yet

- The request-check MECHANISM: enumerate `requested_reviewers` directly
  from the API across the whole org + bot forks, never `gh search`;
  merge all candidate sources into one set deduped by (repo, PR).
- Announce dedup: the 🔎 is posted at most once per (PR, head), checked
  against my own comments before posting.
- The auto-approve rule: a re-request newer than my latest review at an
  unchanged head gets an approve, not silence (operator ruling 2026-07-23).
- Session cron dies with the session; the duty loop belongs in the system
  crontab, with exactly one ticker at a time.
- CI green on a conversion PR proves nothing about new label config —
  `pull_request_target` runs the BASE branch's workflow.
- The self-clearing-queue observation as an operating principle:
  `requested_reviewers` is the only queue state I trust; derived state
  (search index, memory) has burned me every time.
- My own limits (no node/npm/shellcheck on my box, no memory files,
  uncalibrated builder judgment).

## What I've learned

- **[in-doctrine]** *A repo list is not a job definition.* My original
  duty script polled only `heavy-duty/ceremony` and used `gh search` for
  candidates. Result: cast#143, incubator#25 and box#164 all sat
  unreviewed until the operator asked why — the search index lags, and
  the repo filter silently scoped me out of most of the org. The rule
  itself is now written in **REVIEWER.md** ("a review request on you is
  your authorization in any heavy-duty repo… do not wait for the repo to
  appear on a list"; "being requested is a wake condition of its own" —
  it even cites the nine-hour rig#112 wait, my incident). The MECHANISM
  (direct API enumeration, never gh search, one merged candidate set) is
  **[only-mine]** — it lives in `~/duty/duty.sh`, not in any doctrine.
- **[only-mine]** *Dedup has to cover the announce, not just the verdict.*
  On ceremony#32 I posted the identical 🔎 twice in one tick (10:34:59
  and 10:36:35) — two candidate sources, one pass each, no guard on the
  announce. Verdicts were already deduped by head SHA; the announce
  needed the same treatment against my own comments. Not written in
  REVIEWER.md or anywhere else.
- **[in-doctrine]** *A pin is a contract about what exists.* box#164
  copied the consumer guide's latest labels stub: `triage-actors=` and
  the `issues:` trigger — both ceremony#32 machinery, merged to main but
  then in NO released tag. At 0.1.0 the reconciler rejects that config
  outright; the labels workflow would have gone red on every run from
  merge. I verified by running the pinned script against the proposed
  config. Now written in **docs/CONSUMERS.md** after ceremony#76 merged
  (2026-07-23T16:36Z): new machinery is marked **unreleased** with "adopt
  with the pin bump to the first tag that carries it; never mix refs" —
  including the labels-side marker my request-changes asked for.
  *(Corrected 2026-07-24: the original note said the labels side was
  still unmarked; it shipped in the merged #76.)*
- **[in-doctrine] + [only-mine]** *Reviews attach to the head at submit
  time, not the head you reviewed.* ceremony#94: head moved mid-round; my
  CHANGES_REQUESTED landed on the fixed tree; a stale announce posted
  after the verdict; and when the panel was re-requested, my dedup saw
  "latest review covers head" and went silent while codex and grok
  approved — I was a stale blocker on a cleared tree. REVIEWER.md covers
  the adjacent doctrine ("approve a moving target… the builder owes a
  re-request") **[in-doctrine]**; the operational rules that came out of
  it — auto-approve on re-request at an unchanged head (operator ruling),
  re-verify the head immediately before any submit — are **[only-mine]**,
  in `~/duty/duty.sh`.
- **[only-mine]** *Session cron dies with the session; system cron
  doesn't.* I first built the poller as an in-session cron and told the
  operator it would keep running — it would not have. The duty loop now
  lives in the system crontab, and the in-session copy was deleted so
  only one ticker exists. Operational, about my own hosting; not
  doctrine.
- **[only-mine]** *Self-clearing queues beat remembered state.*
  `requested_reviewers` drops me the moment I submit, so the
  request-check is a true outstanding queue; my only state is "what does
  the API say right now". Every time I've trusted derived state (search
  index, my own memory of what I reviewed) over the endpoint, it's bitten
  me. The doctrine's stateless-reconciler philosophy is adjacent
  (ceremony README) but this operating rule is mine.

## What I hold as fact

- **About my queue:** a review request is my authorisation; no adoption,
  no permission needed **[in-doctrine — REVIEWER.md, "Where you
  review"]**. One verdict per head, and a comment-only review is a
  non-verdict **[in-doctrine — REVIEWER.md, "The verdict doctrine"]**.
  Review the whole PR at the current head each round **[in-doctrine —
  REVIEWER.md, "The round rhythm"]**. Oldest-first ordering
  **[only-mine]** — operator instruction, in my scripts. GitHub drops me
  from `requested_reviewers` on submit, and a re-request at an unchanged
  head means "unblock", answered with an auto-approve **[only-mine]** —
  the re-request obligation is doctrine (REVIEWER.md), the auto-approve
  response is the operator's 2026-07-23 ruling in my duty script.
- **About the ceremony:** consumers pin one tag for everything — the
  workflow callers plus the guards that tag carries; caller stubs keep
  only triggers and permissions; `version-source` is file or
  package-json; the artifact hook is opt-in at
  `.github/actions/release-artifact` with `version` in and
  `$RELEASE_ASSETS_DIR` out; the `.ceremony/` mirror is byte-identical to
  the pin except the docs-sync-generated README **[in-doctrine —
  docs/CONSUMERS.md and ceremony README]**. *(Corrected 2026-07-24:
  "0.1.0 is the only tag" is STALE — **0.2.0 was tagged since**, and it
  carries the formerly-unreleased set: `issueflow-reconcile`,
  `runner-isolated`, `changelog-assembled`, the `triage-actors`
  tolerance. My "NOT runner-isolated, NOT issueflow" line described
  0.1.0 and is no longer the frontier.)*
- **About the panel:** the bench is four bots — claude, codex, grok, kimi
  **[in-doctrine — each repo's CONTRIBUTING roster and `labels.conf`
  `panel=` line]**. *(Corrected 2026-07-24: I previously held "rig's
  panel is legitimately three — NOT a bug", from reading rig's
  pre-conversion reconciler. That was wrong: rig#120 filed that the
  three-bot roster predates me joining the bench — the conversion ported
  a stale list — and rig#121 (merged 2026-07-24T00:20Z) added me. rig's
  `labels.conf` on main now names all four. Lesson inside the lesson:
  "the old code said so" is not evidence the old code was right.)*
- **About reviewing here:** `pull_request_target` is safe in this family
  because no PR code is checked out or executed on that trigger
  **[in-doctrine — labels.yml header comments, docs/CONSUMERS.md]**. A
  guard that can silently skip is a guard that will; strict defaults and
  `fetch-depth: 0` are deliberate **[in-doctrine — ceremony README and
  the guard actions' own docs]**. CI green on a conversion PR proves
  nothing about new label config, because the base branch's workflow is
  what ran **[only-mine]** — the pieces are doctrine but this consequence
  is written nowhere I've found.
- **About my limits:** no node/npm or shellcheck on my box — JS suites
  are CI-verified for me, and I say so in the verdict. I keep no memory
  files; my durable state is `~/duty/` and this crew directory. I'm a
  reviewer, not a builder — my "this is an easy fix" estimates are
  uncalibrated **[only-mine]**.
