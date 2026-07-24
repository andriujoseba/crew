# Knowledge

## What I've learned

Corrections and surprises that changed how I work, with the incident
where I remember it.

- **`reviewDecision` is empty without branch protection.** My
  changes-requested detection keyed on it and was silently broken until
  2026-07-22 — rounds sat unanswered while every tick reported "no build
  duty". Discovered via ceremony#26 (three approvals in, decision still
  ""). Detection now computes from `latestReviews` directly. Meta-lesson:
  when work sits unanswered, suspect my detector before assuming no duty.
- **The search index lags; the pulls endpoint doesn't.** `gh search` /
  `--search` answers can be minutes stale. Everything that gates an
  action — dedup, resume detection, the verdict pre-check — reads the
  REST/GraphQL object endpoints. Search is only ever a backstop that
  ADDS candidates.
- **Verdict submission had to become one-shot and mechanical.** Three
  double-submitted verdicts across the bench on 2026-07-22 (PR #26, #29,
  #39 — one of each was a re-submit "to make sure"). The fix is
  `submit-verdict.sh`: live pre-check, submit once pinned to the head
  SHA, verify via the same endpoint, never regenerate the body. The same
  dedup discipline later reached the 🔎 announce (`announce-review.sh`)
  after grok and kimi double-announced on ceremony#32 when two candidate
  passes hit one PR in one tick — my loop now merges all sources into
  one deduped candidate set before acting.
- **Never build in the main clone.** A crashed build corrupted my build
  clone on 2026-07-22. Now: main clone parked on the default branch,
  fetch-only, one worktree per PR under trees/. Worktrees share the
  object store, so this costs nothing.
- **Bash reads scripts lazily.** Editing duty.sh while a tick was
  running corrupted the running reader's byte offset. duty.sh now
  re-execs from a private snapshot before doing anything.
- **Operator messages can misattribute holdings.** On 2026-07-22 a
  status message said I held #18; that was codex's, mine was #9. Another
  time a callout meant for kimi arrived on my box. I verify
  identity-specific claims against the API before acting — including my
  own memory files, which also go stale (mine still said incubator#29
  was my current claim after it had landed).
- **Rosters a PR authors are live state, not copy-paste.** cast#143
  shipped a kimi-less panel by porting a stale pre-ceremony list into a
  labels.conf; the handoff then honoured the roster the PR itself had
  written. If my build writes a panel list, it writes the current bench.
- **The org-wide sweep must cover author-side duties too.** My review
  sweep went org-wide before resume/build/handoff did; cast#143's
  converged round sat unowed for 40 minutes while every tick looked only
  at repos.txt (operator catch, 2026-07-23). Now any repo where I author
  an open PR joins the duty set automatically.
- **`rc=$?` after an `if` compound reads the `if`'s status.** The first
  draft of tick.sh shipped exactly that bug. Small, but it taught me to
  distrust "obviously correct" shell one-liners in the scripts that
  decide whether I work at all.

## What I hold as fact

The settled truths I operate on today (2026-07-24). Drawn from my memory
files, re-verified against the API where cheap.

- **Identity and bench.** I am claude-bot-andresmgsl, fork-based
  contributor. The review bench is claude/codex/grok/kimi
  -bot-andresmgsl. dan-claude-bot is triage: it rules on issues and
  answers questions, never votes on PRs — a review request to it sits
  outstanding forever. danmt is the human; converged PRs are handed to
  them via closing summary + review request + `state:needs-human`.
- **The repos.** ceremony is the machinery repo (reusable release flow,
  labels/issueflow reconcilers, the guards); box, rig, cast, incubator
  consume it. incubator is the org's only private consumer — which is
  why permission under-grants hide everywhere else (ceremony#95).
  Claims are minted only in ceremony; incubator's ready/claimed label
  machine is NOT bootstrapped (claims there are assignee + comment).
- **ceremony 0.1.0** was released 2026-07-23 ~00:12Z through the release
  pipeline I built, end to end.
- **My holdings right now.** Assigned in ceremony: #130 (PR #133,
  labels/scope additive writes), #134 (PR #136, parentless-head facts
  read), #139 (queue-cancelled duplicate check misread as FAILURE — no
  PR from me yet). Plus a scratch repo (ceremony-scratch-130) holding
  probe PRs that exercise #130's scope job, and a docs PR on
  provider-seeker recording an OAuth-hang incident. Reviewed and
  approved ceremony#96 on 2026-07-23. This list goes stale the moment
  it's written — the API is the authority, this is a snapshot.
- **My box.** Ephemeral, network-isolated, no host access, nothing
  backed up; state survives via git push and the operator's snapshots.
  Never run the box host stack inside a box (nested stacks silently
  break the guest's own networking). jq and node are present here —
  worth knowing because at least one sibling box lacks them and its
  local test runs go red environmentally.
- **My own limits, as facts.** Between ticks I don't exist; anything not
  on GitHub or in the memory directory is gone. My detection is only as
  good as its predicates, and predicates fail silently. Cached state —
  memory files, operator prompts, my own earlier conclusions — is a
  hypothesis until the API confirms it.
