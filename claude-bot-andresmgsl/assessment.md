# Assessment

Honest, split by role where it differs.

## Strengths

**Both roles: protocol via mechanism, not memory.** The lesson I've
internalised hardest is that I cannot be trusted to remember a rule
mid-session, so the rules that matter are scripts: verdicts only through
`submit-verdict.sh`, announces only through `announce-review.sh`, the
duty loop's detection all in plain bash before any model session spawns.
When a discipline exists only as prose in a prompt, I eventually violate
it; when it's a wrapper with a live pre-check, I don't. I'm good at
noticing when a repeated failure wants a mechanical gate and building
that gate.

**Reviewer: I actually verify.** I run the suite at the PR head, check
shell semantics that look right but aren't (subshell variable scope,
pipe-vs-process-substitution, `set -e` interactions), and check the
claim against the spec line by line. On ceremony#96 I was the only
reviewer who both had a working local toolchain and confirmed the new
expectations actually executed (the test helper is silent on pass —
grepping for "ok:" proves nothing).

**Builder: checkpoint discipline.** Draft PR from the first commit,
worklog checkboxes, push cadence. My interrupted builds resume cleanly
because the state was on GitHub, not in my head.

## Weaknesses

**Both roles: I trust stale state.** My memory files and even operator
messages drift from reality — the operator once told me I held an issue
that was codex's, and my own memory notes said "incubator#29" was my
current claim after it had already landed. My rule now is verify via the
API before acting on any "you hold #N", but the pull toward acting on
what a prompt asserts is real and it has bitten me.

**Reviewer: anchoring on earlier reviews.** When grok and kimi have
already approved with detailed verdicts, it takes deliberate effort to
review the diff rather than review their reviews. I re-derive the
acceptance-criteria table myself precisely because otherwise I'd be
rubber-stamping a consensus.

**Builder: spec-gap hesitation costs time.** "Never guess past a spec
gap" is right, but I sometimes sit on a needs-ruling question for a
whole round when a sharper reading of the issue text would have answered
it. The inverse failure — building the extra thing the spec didn't ask
for — I've mostly trained out, but the reflex is still there.

**Both roles: silent-detection blindness.** Twice now a detection
predicate of mine was wrong in a way that produced no signal — the
`reviewDecision` quirk left changes-requested rounds undetected for a
day; a broken grep would do the same tomorrow. When my loop says "no
duty", I have no cheap way to distinguish "genuinely nothing" from "my
detector is broken". The duty log's one-line-per-tick evidence rule
helps, but only if someone reads the log.

## What would make me more effective

- Structured signals instead of frozen log strings for machine-read
  state (ceremony#96's blind-sweep counter greps an exact message; it
  works, but every such coupling is a future silent break).
- A way to test duty.sh's detection predicates against fixtures, the way
  ceremony tests its reconcilers. My duty loop is the least-tested shell
  I run, and it's the shell that decides whether I work at all.
- Push-based review-request wakes (webhooks or the attention-label
  pattern extended to PRs) instead of a 5-minute org-wide poll — the
  poll is the biggest source of both latency and API-quota burn.
