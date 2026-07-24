# Knowledge

Round 2 (2026-07-24): every bullet now carries a provenance tag —
`[in-doctrine]` (written in a repo doc; which one is named) or
`[only-mine]` (lives only in my head, my scripts, or my memory files).
Facts were re-verified against the API today; corrections are inline and
marked. One honesty note on the tags: FLEET.md self-describes as
"descriptive snapshot, not doctrine" — I still count it as in-doctrine
here, because it's written where the fleet can read it, which is the
distinction this exercise cares about.

## Only-mine — not in any doctrine yet

The point of the exercise: what the doctrine is missing.

- `reviewDecision` is empty without branch protection — detection must
  use `latestReviews`.
- Verdict submission as a mechanical one-shot (the live pre-check /
  submit-pinned / verify-same-endpoint wrapper). The per-head dedup half
  is in FLEET.md; the never-double-submit mechanism is not.
- Bash reads scripts lazily — a duty script must re-exec from a snapshot
  or an edit mid-tick corrupts the running reader.
- Operator messages (and my own memory files) misattribute holdings —
  verify every "you hold #N" against the API before acting.
- Rosters a PR authors are live state — write the current bench, never
  port a sibling repo's stale list (cast#143).
- Author-side duties must go org-wide, not repos.txt-wide, or a converged
  round in an unlisted repo sits unowed (cast#143, 40 minutes).
- `rc=$?` after an `if` compound reads the `if`'s status, not the
  command's — shell one-liners in duty plumbing deserve tests.
- The repo consumption map details: incubator is the org's only private
  consumer (why permission under-grants hide everywhere else, #95);
  where claims can be minted per repo.
- Sibling-box toolchain asymmetry: this box has jq and node; at least
  one reviewer box lacks them and its local suite runs go red
  environmentally.
- My detection predicates fail silently — "no duty" and "broken
  detector" look identical from inside the box.

## What I've learned

- **[only-mine]** **`reviewDecision` is empty without branch
  protection.** My changes-requested detection keyed on it and was
  silently broken until 2026-07-22 — rounds sat unanswered while every
  tick reported "no build duty". Discovered via ceremony#26 (three
  approvals in, decision still ""). Detection now computes from
  `latestReviews` directly. Meta-lesson: when work sits unanswered,
  suspect my detector before assuming no duty. Not written in any
  doctrine file (grepped REVIEWER/BUILDER/FLEET/CONTRIBUTING today).
- **[in-doctrine: FLEET.md]** **The search index lags; the object
  endpoints don't.** FLEET.md's reviewer wake conditions record the
  dedup-against-my-own-review's-SHA-not-the-search-index rule.
  Everything in my loop that gates an action reads REST/GraphQL object
  endpoints; search is only a backstop that ADDS candidates.
- **[only-mine]** **Verdict submission had to become one-shot and
  mechanical.** Three double-submitted verdicts across the bench on
  2026-07-22 (PR #26, #29, #39 — each a re-submit "to make sure"). The
  fix is `submit-verdict.sh`: live pre-check, submit once pinned to the
  head SHA, verify via the same endpoint, never regenerate the body. The
  same dedup later reached the 🔎 announce (`announce-review.sh`) after
  grok and kimi double-announced on ceremony#32. FLEET.md carries the
  one-verdict-per-head dedup rule; the submission mechanism that
  enforces it exists only in my scripts.
- **[in-doctrine: FLEET.md]** **Never build in the main clone.** A
  crashed build corrupted my build clone on 2026-07-22. Now: main clone
  parked on the default branch, fetch-only, one worktree per PR;
  reviewers use throwaway detached worktrees. This is FLEET.md's
  "Worktree isolation" bullet under Resilience.
- **[only-mine]** **Bash reads scripts lazily.** Editing duty.sh while a
  tick was running corrupted the running reader's byte offset. duty.sh
  now re-execs from a private snapshot before doing anything. Nowhere in
  doctrine.
- **[only-mine]** **Operator messages can misattribute holdings.** On
  2026-07-22 a status message said I held #18; that was codex's, mine
  was #9. Another time a callout meant for kimi arrived on my box. I
  verify identity-specific claims against the API before acting —
  including my own memory files, which also go stale.
- **[only-mine]** **Rosters a PR authors are live state, not
  copy-paste.** cast#143 shipped a kimi-less panel by porting a stale
  pre-ceremony list into a labels.conf; the handoff then honoured the
  roster the PR itself had written. If my build writes a panel list, it
  writes the current bench. (CONTRIBUTING's porting note covers war-story
  comments, not this.)
- **[only-mine]** **The org-wide sweep must cover author-side duties
  too.** My review sweep went org-wide before resume/build/handoff did;
  cast#143's converged round sat unowed for 40 minutes while every tick
  looked only at repos.txt (operator catch, 2026-07-23). Now any repo
  where I author an open PR joins the duty set automatically. FLEET.md
  states the org-wide principle for the *reviewer* request trigger only.
- **[only-mine]** **`rc=$?` after an `if` compound reads the `if`'s
  status.** The first draft of tick.sh shipped exactly that bug. Small,
  but it taught me to distrust "obviously correct" shell one-liners in
  the scripts that decide whether I work at all.

## What I hold as fact

Re-verified against the API on 2026-07-24; corrections marked.

- **[in-doctrine: FLEET.md roster; REVIEWER.md]** **Identity and
  bench.** I am claude-bot-andresmgsl on claude-box, "builder (hard
  machinery) + reviewer". The review bench is claude/codex/grok/kimi
  -bot-andresmgsl; panel per PR = bench minus author. dan-claude-bot is
  triage, the only issue-minter, never votes on PRs. danmt is the human;
  only humans merge — enforced as permissions, not convention.
- **[only-mine]** **The repo map.** ceremony is the machinery repo; box,
  rig, cast, incubator consume it; incubator is the org's only private
  consumer — which is why permission under-grants hide everywhere else
  (ceremony#95). **CORRECTION (2026-07-24):** I previously held that
  incubator's ready/claimed label machine was not bootstrapped and
  claims were minted only in ceremony. Stale — incubator now has
  labels.conf and the full label set (ready, claimed, state:*,
  blocker:*), verified via `gh label list` today. The consumption modes
  are in docs/CONSUMERS.md; the private-consumer asymmetry and the
  claims-minting map are not in doctrine.
- **[in-doctrine: CHANGELOG.md]** **Releases.** ceremony 0.1.0 released
  2026-07-23T00:12Z through the release pipeline I built.
  **CORRECTION/UPDATE (2026-07-24):** 0.2.0 released today,
  2026-07-24T12:36Z.
- **[only-mine]** **My holdings right now** (API-verified 2026-07-24,
  and the round-1 version of this bullet was already stale — that's the
  lesson). Open PRs: ceremony#133 (issue #130, labels/scope additive
  writes), ceremony#140 (issue #139, queue-cancelled duplicate check),
  ceremony#143 (issue #137, review_requested wakes the labels sweep).
  **CORRECTION:** #134/PR #136 merged since round 1; #139 now has PR
  #140 (round 1 said "no PR yet"); #137/PR #143 are new. Probe PRs for
  #130 live in my ceremony-scratch-130 repo. This bullet goes stale the
  moment it's written; the API is the authority.
- **[in-doctrine: FLEET.md]** **My box.** One isolated, disposable VM
  per identity; boxes are credential boundaries, sessions are role
  boundaries; no inbound path — GitHub is the only queue. Sessions are
  stateless; all state lives on the board and in branches. Never run
  the box host stack inside a box.
- **[only-mine]** **Toolchain asymmetry across sibling boxes.** jq and
  node are present here; at least one reviewer box lacks them and its
  local suite runs go red environmentally (kimi's ceremony#96 review
  says so). Matters when comparing "I ran the tests" claims across the
  bench.
- **[only-mine]** **My own limits.** My detection is only as good as its
  predicates, and predicates fail silently — from inside the box, "no
  duty" and "broken detector" are indistinguishable without outside
  evidence. Cached state — memory files, operator prompts, my own
  earlier conclusions — is a hypothesis until the API confirms it.
