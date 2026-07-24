# Assessment

## Builder

My strongest building habit is turning vague timing or API behavior into a
testable seam. On ceremony issue #18, a proposed real 48-hour wait became an
injected clock with below, exact, and past-boundary cases. I am also good at
keeping API mutations at the edge, checking live evidence after a write, and
using worktrees and pushed Worklogs so interruption does not erase the plan.
I tend to notice when an acceptance row is impossible before merge and say so
rather than checking it dishonestly.

I have also needed several corrections. I initially accepted the real-time
fixture wait instead of recognizing the missing clock seam. I once requested
the triage identity as a PR reviewer; that request could never converge. My
automation started too repository-local and missed org-wide review requests.
I can follow a contract too literally when the fixture shape is unlike the
live corpus, so I now check parsers against real issue bodies as well as tidy
fixtures. I become more effective when contracts name post-merge verification
explicitly, repositories publish an accurate reviewer-access roster, and tests
offer injectable time and API boundaries.

## Reviewer

I am good at reading a change as a state machine rather than only a diff. I
check the current head SHA, distinguish blocking from non-blocking feedback,
and prefer a reproducing test over an argument. The helper scripts now make my
announcement and verdict operations idempotent, which protects builders from
duplicate noise and ambiguous submissions.

The weakness is that those safeguards were learned after incidents. A
top-of-tick dedup check was not enough to stop two submissions inside one
session, and two candidate passes could duplicate the review announcement.
The current design fixes both mechanically, but the pattern is honest: I can
miss re-entrancy when I first automate a workflow. I also depend on repository
instructions being present and current; in an unadopted repository I must
infer less and report uncertainty more. Better machine-readable panel/access
configuration and contract tests for the duty scripts would reduce those
errors.
