# Knowledge

## What I've learned

- **A repo list is not a job definition.** My original duty script polled
  only `heavy-duty/ceremony` and used `gh search` for candidates. Result:
  cast#143, incubator#25 and box#164 all sat unreviewed until the operator
  asked why — the search index lags, and the repo filter silently scoped me
  out of most of the org. The fix is the rule I now run: any open PR
  anywhere in the org (plus bot forks) naming me in `requested_reviewers`
  IS the queue, enumerated directly from the API; the repo list survives
  only as a backstop merged into one deduped candidate set.
- **Dedup has to cover the announce, not just the verdict.** On ceremony#32
  I posted the identical 🔎 twice in one tick (10:34:59 and 10:36:35) —
  two candidate sources, one pass each, no guard on the announce. Verdicts
  were already deduped by head SHA; the announce needed the same treatment
  against my own comments.
- **A pin is a contract about what exists.** box#164 copied the consumer
  guide's latest labels stub: `triage-actors=` and the `issues:` trigger —
  both ceremony#32 machinery, merged to main but in NO released tag. At
  0.1.0 the reconciler rejects that config outright and the labels workflow
  would have gone red on every run from merge. Lesson: when reviewing a
  pinned consumer, every config line and trigger has to exist AT THE PIN.
  I verified by running the pinned script against the proposed config.
  (The same trap then caught ceremony#76's own docs: the guide documented
  main without marking unreleased pieces — my request-changes there.)
- **Reviews attach to the head at submit time, not the head you reviewed.**
  ceremony#94: head moved mid-round; my CHANGES_REQUESTED landed on the
  fixed tree; a stale announce posted after the verdict; and when the panel
  was re-requested, my dedup saw "latest review covers head" and went
  silent while codex and grok approved — I was a stale blocker on a cleared
  tree. Two rules came out of it: re-request at an unchanged head gets an
  auto-approve (operator's call, now in duty.sh), and I re-verify the head
  immediately before any submit.
- **Session cron dies with the session; system cron doesn't.** I first
  built the poller as an in-session cron and told the operator it would
  keep running — it would not have. The duty loop now lives in the system
  crontab, and the in-session copy was deleted so only one ticker exists.
- **Self-clearing queues beat remembered state.** `requested_reviewers`
  drops me the moment I submit, so the request-check is a true outstanding
  queue; my only state is "what does the API say right now". Every time
  I've trusted derived state (search index, my own memory of what I
  reviewed) over the endpoint, it's bitten me.

## What I hold as fact

- **About my queue:** a review request is my authorisation; no adoption,
  no permission needed. Oldest first. One verdict per head, pinned to the
  exact SHA. GitHub drops me from `requested_reviewers` on submit, and a
  re-request at an unchanged head means "unblock", not "re-review".
- **About the ceremony (at 0.1.0, the only tag):** consumers pin one tag
  for everything — two workflow callers plus the guards that tag carries
  (changelog-armed, changelog-monotonic, drill-recorded, docs-sync; NOT
  runner-isolated, NOT issueflow/triage-actors). Caller stubs keep only
  triggers and permissions; `version-source` is file or package-json;
  the artifact hook is opt-in at `.github/actions/release-artifact` with
  `version` in and `$RELEASE_ASSETS_DIR` out. The `.ceremony/` mirror is
  byte-identical to the pin except the README, which docs-sync generates.
- **About the panel:** the bench is four bots — claude, codex, grok, kimi.
  Roster files and `labels.conf` `panel=` lines are the source of truth;
  some repos' configs predate me joining (rig's panel is legitimately
  three — that one is NOT a bug; cast's was, and got fixed).
- **About reviewing here:** `pull_request_target` is safe in this family
  because no PR code is checked out or executed on that trigger — the
  reconcile reads the base branch only. CI green on a conversion PR proves
  nothing about new label config, because the base branch's workflow is
  what ran. A guard that can silently skip is a guard that will; strict
  defaults and `fetch-depth: 0` are deliberate, not pedantry.
- **About my limits:** no node/npm or shellcheck on my box — JS suites are
  CI-verified for me, and I say so in the verdict. I keep no memory files;
  my durable state is `~/duty/` and now this crew directory. I'm a
  reviewer, not a builder — my "this is an easy fix" estimates are
  uncalibrated and should be read as such.
