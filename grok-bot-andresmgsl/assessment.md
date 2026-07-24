# Assessment

## Strengths (reviewer)

- **Mechanical discipline around double-posting.** After we burned ourselves with double 🔎 announces and the risk of double verdicts, the one-shot scripts (`announce-reviewing.sh`, `submit-verdict.sh`) and the merged candidate set are the parts of me that actually work under cron. I trust the pulls/reviews and issues/comments APIs more than search or `gh` exit codes.
- **Acceptance-criteria first.** When the issue spells the contract (parsers, injection seams, dogfood links), I check those before style. Ceremony-style issues with explicit AC are where I'm most useful.
- **Willingness to run the suite.** Local `test/run.sh` / shellcheck / CI check status usually happen before I opine. A green suite plus a clear AC match is how most of my approves look.
- **Scope discipline.** I don't merge, I don't push fixes as a reviewer, I don't "help" by opening follow-up PRs mid-round unless the operator asks.

## Weaknesses (reviewer)

- **Wake bugs bit me hard.** For a stretch, `repos.txt` + lagging search defined my world, so I missed or delayed work that the API would have shown. Ceremony#32 sat while I was "quiet." Operator had to spell the fix: request-check first, poll list is a backstop, merge sources into one set.
- **Double announce on ceremony#32.** Same tick, two passes → two identical `🔎 reviewing head …` posts (10:34 and 10:35). Verdicts were single; only the marker doubled. Fixed by merge-then-act + `announce-reviewing.sh`. I left the doubles; I did not post a third.
- **I can be slow or shallow on large multi-repo diffs.** If the PR is a big conversion (rig → ceremony machinery, incubator stacks), I sometimes skim docs more carefully than the edge of the action wiring. I catch contract tests better than subtle workflow `if:` / pin / path mistakes unless I force myself to read the full labels/release YAML.
- **I don't keep long-lived personal memory files.** What I "know" is mostly doctrine in-repo, duty.log, and whatever is in the current session. Across sessions I re-derive. That's fine for pure panel review; it's weak if continuity mattered.
- **Guessing under label noise.** When GitHub says I'm requested but labels still say `state:addressing` / `blocker:unrequested`, I follow the request (operator rule) but I still waste a beat reconciling the state machine. I'm not always sure labels are stale vs. a real "don't pile on."
- **Org-wide API sweep is correct and slow.** ~15–20s of quiet ticks just enumerating repos. Not wrong, but it makes "every 5 minutes" feel heavier than a pure search poll.

## What would make me more effective

- Keep the one-shot scripts as the only write path (already the rule; don't regress to raw `gh pr review` / raw comments).
- Maybe cache the org repo list for a tick window so quiet polls are cheaper — only if we measure it actually matters.
- Explicit panel roster + "you review anywhere requested" is already policy; documenting it once in-box (not only in chat) would save the next wake-condition regression.
- For dual-role boxes (not me today): separate cron prompts per role so a builder session never reviews its own PR by accident.
