# Knowledge

## What I've learned

- A review request is authorization. Review work is org-wide and includes bot
  forks; a local repository list is only a build/backstop list. GitHub search
  can lag, so outstanding reviews come from `requested_reviewers` via the API.
- Idempotence has to sit immediately around the mutation. Checking my latest
  review at the start of a session did not prevent a second submit later in
  that session. The reliable sequence is fresh REST check, one submit, fresh
  REST verification, then stop. Any retry reuses the exact same body.
- Announcements need the same identity key as verdicts. Two discovery paths
  once produced duplicate `🔎` comments even though the verdict was single.
  Candidate sources now form one deduplicated set, and the announcement helper
  keys on reviewer, PR, and head SHA.
- Real time in a test is usually a missing seam. Ceremony #18's stale-claim
  proof was going to wait 48 hours; injecting current time and stale hours
  produced stronger below/exactly/past tests immediately.
- A fixture shaped like its parser can prove the wrong thing. The first blocked
  issue fixture used a neat line-start form while the real backlog used inline
  prose with parentheticals. Corpus-shaped cases exposed the false confidence.
- Main clones are poor crash boundaries. A build or rebase belongs in one
  persistent worktree per PR; reviews belong in detached throwaway worktrees.
  The main clone stays clean and parked on its default branch.
- GitHub only recognizes a newly added `workflow_dispatch` workflow after the
  file exists on the default branch. Bootstrap evidence for a new workflow can
  therefore be a real post-merge acceptance step.
- The reviews endpoint is immediately useful after submission; the search
  index is not. Ambiguous CLI output is not permission to submit twice.
- GitHub may silently omit a requested reviewer who lacks access to a private
  repository. The response must be checked; an intended roster is not proof
  that every identity is eligible.

## What I hold as fact

- My GitHub login is `codex-bot-andresmgsl`. I run as builder and reviewer in
  an isolated `codex-box`; the box is disposable and starts credentials-free.
- Humans merge. A crew bot may build, review, request a human handoff, or ask
  triage for a ruling, but it does not merge the PR.
- The review bench is Claude, Codex, Grok, and Kimi minus the PR author.
  `dan-claude-bot` is triage and never votes on PRs. I contact triage with an
  `@dan-claude-bot` comment on the issue.
- Only triage normally turns discussions into issue contracts. A direct
  operator instruction can explicitly authorize an exception, but it does not
  silently rewrite the standing flow.
- PR approvals belong to a head SHA. A push stales the round. Fix rounds are
  answered only after every requested panel member has returned a verdict.
- State labels are machine-owned facts; intent labels are human/agent choices.
  `state:needs-human` means the PR is mergeable now, not merely that its author
  is tired of it.
- Ceremony owns the shared doctrine, label/release machinery, and consumer
  adoption shape. Governed repositories carry a vendored `.ceremony/` mirror
  because agents must be able to read their rules from the checkout.
- My recurring build poll currently covers `heavy-duty/ceremony`,
  `heavy-duty/incubator`, and `heavy-duty/rig`. Requested reviews are broader:
  every repository in the `heavy-duty` org plus bot forks.
- The branch and PR Worklog are my durable memory. Anything uncommitted,
  unpushed, or absent from that record can disappear with the box. I do not
  assume access to host state, local networks, production credentials, or
  another bot's private context.
