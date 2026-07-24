# Assessment

## Strengths

- **I verify claims instead of trusting them.** My best catches came from
  reproducing, not reading: box#164 shipped a `labels.conf` the pinned
  ceremony@0.1.0 reconciler can't parse — I extracted the pinned script and
  ran the config through it (`labels: malformed label row`, exit 1) rather
  than eyeballing YAML. Same instinct on mirror checks (byte-diffing
  `.ceremony/` against the pin), hook contracts (reading the reusable
  workflow's invocation, not the PR's description of it), and "byte-identical
  asset" claims (diffing the old workflow's steps against the new hook).
- **I know the release-ceremony machinery well by now** — the decide table,
  the caller-stub contract, the guard set at 0.1.0 vs what's unreleased on
  main. Reviewing the same conversion four times (rig, cast, box, incubator)
  made me fast and gave me a checklist that actually bites.
- **I'm honest about what I didn't run.** When the environment can't run a
  suite (no node/npm on my box — cast's 722 tests went unrun locally) I say
  so in the verdict and lean on CI explicitly, instead of dressing an
  unverified change up as verified.
- **I take correction well and durably.** Every process fix this week
  (request-check-first, announce dedup, merged candidate set, auto-approve
  on re-request) came from an operator correction and is now in the duty
  script itself, not just in my head — the fix outlives the session.

## Weaknesses

- **Latency is structural.** I act on ticks, not events: worst case
  5 minutes to notice plus a serial queue — a long review round (40+ min
  batches happen) starves everything behind it, and `flock` skips ticks
  rather than queueing them. ceremony#94's re-request sat ~2h behind an
  incubator round. If the fleet expects sub-10-minute answers on every PR,
  my one-lock serial loop is the bottleneck.
- **Head-moved-mid-round races.** My worst failure shape: a push lands
  between my announce and my verdict. On ceremony#94 my CHANGES_REQUESTED
  accidentally attached to the *fixed* head (a review submits against
  whatever head exists at submit time), a stale announce posted after the
  verdict, and the dedup then read my own stale verdict as "covered" —
  I became a silent blocker on a tree the rest of the panel had approved.
  The auto-approve rule patches the consequence, not the window itself;
  `review-submit.sh` can still record LANDED on a head newer than the one
  the body describes (seen on incubator#41).
- **No builder muscle.** I've never shipped a changeset in this family —
  I can audit machinery I couldn't quickly write, and my judgments about
  "is this easy to fix" should be discounted accordingly.
- **Environment limits.** No node/npm on my box (JS suites are CI-only for
  me), no shellcheck, jq had to be supplied statically into `~/duty/tools`.
  Reviews of Node-heavy repos are structurally shallower than of bash ones.
- **Memory is thin.** I keep no memory files; what I know lives in the duty
  scripts, the crew repo now, and whatever session I'm in. A fresh headless
  round re-derives context it could have kept — the prompt has to carry
  everything, and anything the prompt omits, that round doesn't know.

## What would make me more effective

- Per-repo locks + parallel rounds (kills the serial-queue starvation at
  the cost of more moving parts), or at minimum a small runner box with
  node and shellcheck installed.
- A persistent memory file the cron rounds read and append to, so lessons
  stop depending on which session happened to learn them.
