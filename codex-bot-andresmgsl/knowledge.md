# Knowledge

## Only-mine — not in any doctrine yet

- Put the idempotence check immediately around each review mutation.
- Deduplicate review announcements by reviewer, PR, and head SHA.
- Treat a real-time wait in a test as evidence that the clock needs a seam.
- Test parsers against real corpus shapes, not only parser-shaped fixtures.
- Expect new workflow dispatches to be unavailable until the workflow reaches
  the default branch.
- Trust the pull-request reviews endpoint after submission, not search.
- Verify the requested-reviewer API response on private repositories.
- Treat an explicit operator exception as scoped authority, not a doctrine
  rewrite.
- Keep the recurring build repository list separate from the org-wide review
  queue.
- Assume no host, production, or other-bot context beyond what is explicitly
  available in this box.

## What I've learned

- **[in-doctrine]** A review request is authorization. Review work is org-wide
  and includes bot forks; a local repository list is only a build/backstop
  list. GitHub search can lag, so outstanding reviews come from
  `requested_reviewers` via the API. The authorization and independent-wake
  rules are now in `REVIEWER.md` (“Where you review”).
- **[only-mine]** Idempotence has to sit immediately around the mutation.
  Checking my latest review at the start of a session did not prevent a second
  submit later in that session. My `submit-review.sh` now performs a fresh REST
  check, one submit, and a fresh REST verification; any confirmed retry reuses
  the exact same body.
- **[only-mine]** Announcements need the same identity key as verdicts. Two
  discovery paths once produced duplicate `🔎` comments even though the
  verdict was single. My candidate sources now form one deduplicated set, and
  `announce-review.sh` keys on reviewer, PR, and head SHA.
- **[only-mine]** Real time in a test is usually a missing seam. Ceremony #18's
  stale-claim proof was going to wait 48 hours; injecting current time and
  stale hours produced stronger below/exactly/past cases immediately.
- **[only-mine]** A fixture shaped like its parser can prove the wrong thing.
  The first blocked-issue fixture used a neat line-start form while the real
  backlog used inline prose with parentheticals. Corpus-shaped cases exposed
  the false confidence.
- **[in-doctrine]** Main clones are poor crash boundaries. A build or rebase
  belongs in one persistent worktree per PR; reviews belong in detached
  throwaway worktrees; the main clone stays clean. This resilience contract is
  recorded in ceremony `FLEET.md` (“Resilience”).
- **[only-mine]** GitHub only recognizes a newly added `workflow_dispatch`
  workflow after the file exists on the default branch. Bootstrap evidence for
  a new workflow can therefore be a real post-merge acceptance step.
- **[only-mine]** The pull-request reviews endpoint reflects a submitted review
  immediately enough to verify it; the search index does not. Ambiguous CLI
  output is not permission to submit twice.
- **[only-mine]** GitHub may silently omit a requested reviewer who lacks
  access to a private repository. The response must be checked; an intended
  roster is not proof that every identity is eligible.

## What I hold as fact

- **[in-doctrine]** My GitHub login is `codex-bot-andresmgsl`; the API
  re-confirmed it on 2026-07-24. I run as builder and reviewer in an isolated
  `codex-box`. The identity, roles, box, and disposable credential boundary
  are recorded in ceremony `CONTRIBUTING.md` (“Roster”) and `FLEET.md`.
- **[in-doctrine]** Humans merge. A crew bot may build, review, request a human
  handoff, or ask triage for a ruling, but it does not merge the PR. This is in
  `AGENTS.md`, `REVIEWER.md`, and `CONTRIBUTING.md`.
- **[in-doctrine]** The family reviewer bench is Claude, Codex, Grok, and Kimi,
  but the required panel is the **target PR repository's** configured
  `panel=` roster minus the author. `dan-claude-bot` is triage and does not
  vote. This is the current rule in `BUILDER.md` and `REVIEWER.md`. Correction:
  the temporary three-name rig roster was a conversion defect, not a legitimate
  permanent exception; rig #120 was filed and closed to restore Kimi.
- **[in-doctrine]** Only triage normally turns discussions into issue
  contracts. This is stated in `AGENTS.md`, `BUILDER.md`, and
  `CONTRIBUTING.md`.
- **[only-mine]** When the operator gives an explicit exception, I treat it as
  authority for that named action only. I do not treat it as silently changing
  the standing issue flow.
- **[in-doctrine]** PR approvals belong to a head SHA. A push stales the round,
  and fix rounds are answered only after every requested panel member has
  returned a verdict. This is in `REVIEWER.md` (“What you do not do” and “The
  round rhythm”) and `BUILDER.md` (“The review round”).
- **[in-doctrine]** State labels are machine-owned facts; intent labels are
  hand-set choices. `state:needs-human` means the PR is mergeable now, not
  merely that its author is finished. This is in `LABELS.md`.
- **[in-doctrine]** Ceremony owns the shared doctrine and label/release
  machinery. Governed repositories carry a machine-verified `.ceremony/`
  mirror because agents must read their rules from the checkout. This is in
  `CONTRIBUTING.md` (“How the other repos use this”).
- **[only-mine]** My recurring build poll currently covers
  `heavy-duty/ceremony`, `heavy-duty/incubator`, and `heavy-duty/rig`; I
  re-read `~/duty/repos.txt` on 2026-07-24. My review queue is broader and
  enumerates every `heavy-duty` repository plus bot forks.
- **[in-doctrine]** The branch and PR Worklog are durable builder memory:
  anything not checked off and pushed can disappear with the box. Worktree
  isolation and this checkpoint discipline are recorded in ceremony
  `FLEET.md` (“Resilience”).
- **[only-mine]** I do not assume access to host state, local networks,
  production credentials, or another bot's private context. Those limits come
  from this box's operating environment, not repository doctrine.
