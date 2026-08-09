# Drill records

Per-release evidence for crew's duty-engine rehearsal. **One file per
version**, named for the version exactly as `VERSION` carries it:

    drills/<version>.md

So `0.1.0` is recorded in `drills/0.1.0.md`, and `0.1.0-rc1` in
`drills/0.1.0-rc1.md`. They are different files, which is the whole point: the
filesystem does the whole-version comparison, so a record for a candidate can
never be mistaken for evidence for the final.

The directory is `drills/`, not `.drills/` — a dot-directory is invisible to
any glob without `dotglob`, which is how the fleet's siblings shipped releases
with records a sweep could not see.

**This directory is the record, not the instrument.** The instrument is
[`drill/rehearsal.sh`](../drill/rehearsal.sh) and its companions
(`rehearsal-all.sh`, `rehearsal-app.sh`, `rehearsal-config.sh`,
`rehearsal-safety.sh`): they install the engine in a drill box on a real host
and exercise the duty lifecycle end to end. crew does not reach into another
repo's harness to decide whether crew may ship — a cross-repo lookup that fails
silently degrades to "pass". The gate reads a file in this repo, and nothing
else.

## What the gate requires

The `drill-recorded` guard (heavy-duty/ceremony's action, pinned through
`.github/workflows/release.yml`) runs on every PR. On a `-dev` tree it asserts
nothing — a development tree has no release to evidence. On a bare `VERSION` — a
release ceremony tree — it requires `drills/<version>.md` to exist and to hold
at least one non-whitespace character. An empty file, or one of only spaces and
tabs, is not a record.

The guard requires a **record**, not a passing result. A maintainer waiver is a
legitimate outcome of a release — but it is written in that version's file, so
that skipping the drill is a deliberate, reviewable commit rather than a
silence. **A failed drill is still a valid record**: the gate wants evidence,
not success.

## Adapting the drill to the window

**A release window's drill is adapted to what that window shipped, and the
release issue carries the audit that says so.** At release-init, triage adds one
row for every surface shipped by the fragments in `changelog.d/` on `main` when
the release issue is minted, naming the issue and surface and assigning exactly
one disposition.
Every fragment contributes at least one row; a fragment that ships more than
one surface contributes a row for each:

- **`drilled`** — an existing leg reads the surface; name the assertion.
- **`new leg`** — the window needs another leg; name the issue minted for it.
- **`not a drill surface`** — no real-host assertion belongs in this drill;
  state why. An empty reason leaves the audit incomplete.

Those three dispositions are exhaustive. `Partly drilled` is not a fourth: it
means a fragment shipped separate surfaces that need separate rows.

The audit is a table in the release issue, not another repository file. Triage
owns it because release-init already reads the window membership, and completes
it then so every required leg can land before the operator runs the round. A
leg that lands after the drill round changes the candidate the record describes
and forces a re-drill.

### Worked example: `0.1.2`

This is a worked example at snapshot
`07bb0f3473d1a35a39fdf8d9ab93ac7d99ec3d74`, not `0.1.2`'s audit of record.
Its fragment names are exactly the 42 fragments returned by
`git ls-tree -r --name-only 07bb0f3473d1a35a39fdf8d9ab93ac7d99ec3d74 -- changelog.d/`,
excluding `changelog.d/README.md`. Triage re-derives the audit of record at
release-init against the actual cut. The owed `425.md` and `427.md` fragments
are absent at this snapshot and therefore have no rows below. A disposition
records the decision at audit time, so a `new leg` row keeps the issue it caused
even when that issue has since landed.

| Fragment | Surface | Disposition and evidence |
| --- | --- | --- |
| `139.md` | Fix rounds return to draft | **`new leg`** — #418 |
| `168.md` | Dirty-worktree preservation | **`new leg`** — #422 |
| `190.md` | Floor integrity verdict | **`new leg`** — #420 |
| `190.md` | Browser walk checks `gh ✓` only for armed, ticking boxes and reports when none qualify | **`drilled`** — `render: the fixture offers an armed, ticking box...`, `render: healthy boxes show gh ✓...`, and the no-candidate report in `fleet-floor/test/browser.js` read it. |
| `204.md` | Consoles only for deployed boxes | **`new leg`** — #420 |
| `210.md` | Tagged installer assets and checksums | **`not a drill surface`** — assets exist only after the tag; #210 owns their post-merge verification. The installed tree is covered by #421. |
| `217.md` | Round teardown, retention and reuse | **`drilled`** — the `teardown` summary rows and `drill/teardown.sh` refusal, inspection and cleanup assertions read it. |
| `218.md` | `crew up --dry-run` | **`new leg`** — #420 |
| `240.md` | Boot-check probe verdict | **`new leg`** — #427 |
| `301.md` | Attention pickup comment and acknowledgement | **`drilled`** — the pickup-comment and `attention`-removal assertions in `rehearsal.sh` read it. |
| `301.md` | Attention dispatch and timed-out pickup reporting | **`new leg`** — #440 |
| `303.md` | Hygiene reporting of malformed `attention` | **`new leg`** — #441 |
| `308.md` | Unknown `crew status` probe | **`new leg`** — #420 |
| `312.md` | Disarmed versus silent floor states | **`new leg`** — #420 |
| `316.md` | Union of work and notification repositories | **`new leg`** — #423 |
| `319.md` | Malformed-signal detection and fresh comment reads | **`new leg`** — #419 |
| `323.md` | Release-tree floor CLI test | **`not a drill surface`** — this fixes the repository's `ci-floor` suite; no installed real-host behavior changed. |
| `341.md` | Post-removal tick wait and diagnostics | **`drilled`** — `step 9: positive engine/cron/tick survival observation` reads it. |
| `345.md` | `no build duty` cause | **`new leg`** — #420 |
| `347.md` | Serving crew version in the floor | **`new leg`** — #420 |
| `350.md` | Ceremony pin, guards and board reconciliation | **`not a drill surface`** — GitHub Actions runs these repository guards and board workflows; a drill box does not. |
| `358.md` | `post-merge` in the queue-label set | **`new leg`** — #417 |
| `359.md` | Quiet post-session triage state | **`new leg`** — #417 |
| `363.md` | Doctrine-quotation and docs-sync CI guards | **`not a drill surface`** — these compare repository files in CI, not behavior on an installed host. |
| `365.md` | Installed payload roots and size | **`new leg`** — #421 |
| `384.md` | Check-conclusion resume wake | **`new leg`** — #419 |
| `388.md` | Terminal-lane trip, alert and recovery | **`new leg`** — #424 |
| `398.md` | Ceremony pin and vendored doctrine | **`not a drill surface`** — a dependency pin and mirrored prose have no installed real-host surface. |
| `402.md` | Pending-check round signal and request gate | **`new leg`** — #418 |
| `403.md` | Zero-action resume stop | **`new leg`** — #419 |
| `405.md` | Development dependency and manifest hygiene | **`not a drill surface`** — repository development furniture is not shipped into the installed tree. |
| `406.md` | Attributed-doctrine quotation guard | **`not a drill surface`** — this is a repository fixture guard, not installed behavior. |
| `407.md` | Phase-0 tracked-tree staging | **`drilled`** — `fixture tests green` runs from the staged tree before the live legs. |
| `408.md` | Reused-box post-removal tick | **`drilled`** — `step 9: positive engine/cron/tick survival observation` reads it. |
| `411.md` | Membership predicates under load | **`drilled`** — teardown's roster/sandbox refusals and the install leg's `crew hire` / `crew up` assertions read them. |
| `417.md` | `post-merge` triage invariant | **`drilled`** — `triage: post-merge drew no comment`, `kept its single label`, and `launched no session` read it. |
| `418.md` | Live builder fix round | **`drilled`** — the builder assertions read draft return, the pending-check signal and withheld request, then the request after settle. |
| `419.md` | Resume wake, malformed marker and zero-action stop | **`drilled`** — the `resume:` assertions name all three outcomes. |
| `420.md` | Operator-view release surfaces | **`drilled`** — the `floor:`, `integrity:`, `crew status`, `crew up --dry-run`, and `no build duty` assertions read them. |
| `421.md` | Installed-tree exclusions and budget | **`drilled`** — the three `payload:` measurements read exclusions and size from the first install, upgrade and offline artifact. |
| `422.md` | Dirty-worktree preservation and refusal | **`drilled`** — the `hygiene:` assertions read the remote `wip/` tree, durable record, push-before-removal order and refusal retention. |
| `423.md` | Notification-union leg and cleanup | **`drilled`** — the notifier assertions read both halves of the watch set, and its safety/teardown assertions read restoration and cleanup. |
| `424.md` | Terminal-session breaker | **`drilled`** — the `breaker:` assertions read the threshold trip, suppressed ticks, one alert and recovered dispatch. |
| `435.md` | Resume leg's independent summary verdict | **`drilled`** — the resume verdict file and `rehearsal_worst_verdict` feed the `resume` summary row independently of the builder exit. |

## The drill

crew asserts the **duty lifecycle** — that the engine, installed on a real box,
runs its roles correctly. box asserts the isolation contract, rig asserts
convergence, cast asserts promotion; crew asserts that a fleet of agents does
triage, build and review the way the doctrine says. The legs
(`drill/rehearsal.sh`, run per role by `rehearsal-all.sh`):

- **Phase 1, creds-free.** Install the engine into a drill box as the selected
  agent in each role, and verify every behavior that needs no credentials —
  a box comes up disarmed and reports so.
- **Phase 2, authenticated** (runs when the box's `gh` and agent CLIs are
  logged in — the operator logs the box in between runs; the harness never
  touches credentials). It mints its own GitHub fixtures under the host
  identity and verifies the attention wake, the review round through both
  one-shot gates, head dedup, the re-request auto-approve, and gate abuse.
- **One box per role**, not one box carrying all three: `fleet.roster` deploys
  single-role members and `duty.sh` gates every module on `has_role`, so a
  composite box would exercise a path nobody runs.
- **The console** (`fleet-floor`) is part of the rehearsal, not a separate
  errand: it is what an operator looks at to decide the fleet is healthy.
- **Operator-config convergence** — the registry contract exercised against a
  real installed box.

Within a run, fixtures and the drill box are left in place for inspection; the
box is always left disarmed and its pre-drill repo registry restored. What
happens to them *between* runs is the lifecycle below. Companion prose:
[`shared/docs/rehearsal.md`](../shared/docs/rehearsal.md).

## The round's lifecycle — create, reuse, teardown

A round is real infrastructure, and it is the operator's machine and the
operator's GitHub account that carry it.

**A round creates**, per role in `--roles` (all three by default):

- a **box** on the host, `crew-drill-<role>`, at 2 CPU / 4 GiB / 20 GiB;
- a **public sandbox repository**, `<host-gh-identity>/crew-drill-<role>`,
  which the round then fills with issues, PRs and review traffic.

**A green round tears itself down.** `rehearsal-all.sh` runs
[`drill/teardown.sh`](../drill/teardown.sh) when every leg passed, removing
both. Nothing else on the host is touched, ever:

    drill/teardown.sh [--roles "triage builder reviewer"] [--role <role>]
                      [--box <name>] [--sandbox <owner/repo>]
                      [--dry-run] [--yes]

It names every box and repository with its creation date and asks once
(`CREW_YES=1` or `--yes` for an unattended run), and it is idempotent — a
second run over a clean host reports nothing to do and exits zero. A name is
deletable only when it is **exactly** one of the drill's own names *and* is
named by no roster on this host: a roster member is refused even when its name
matches the drill pattern, and a name that merely starts with `crew-drill` is
not a drill box. A sandbox repository has the same two gates — the `<repo>`
half must be a drill name *and* the owner must be this host's `gh` identity,
since a round's sandboxes are always `<host-gh-identity>/crew-drill-<role>`.
Every target is validated before any is deleted, so a command carrying one bad
name removes nothing at all, and naming the same target twice deletes it once.

**"I found nothing" and "I could not look" are different answers**, and the
exit status is where teardown keeps them apart:

| exit | meaning |
| --- | --- |
| `0` | every class it was asked to clear was **inspected**, and whatever existed is gone. Only this means a clean host. |
| `1` | **refused** — a name outside the deletable set — or a deletion failed. |
| `2` | **INCOMPLETE** — a class could not be inspected at all, so what it holds is unknown and may still be standing. |

A run is INCOMPLETE when there is no `gh` identity to address the sandbox
repositories with, when there is no `box` CLI, when `box list --json` cannot
be read or parsed (no `jq` counts), or when a **single repository lookup**
does not answer. That last one is the same distinction at the other grain: an
identity that resolves says the API can be *asked*, not that it *answered*, so
a lookup that fails for anything other than a measured `HTTP 404` names its own
repository as uninspected rather than being counted absent. It says which class
or repository and why, it still deletes everything it *could* see — that half
of the host really is clean — and it does not report the round as done.
`rehearsal-all.sh` gives it its own `INCOMPLETE teardown` summary row rather
than `ok`, so a green round can never end with a cleanup line claiming more
than was measured.

One caveat worth knowing rather than discovering: GitHub answers `404` for a
private repository the token cannot see, so a measured absence is really
"absent *to this identity*". That is the API's shape, and it is the safe
direction — a repository this identity cannot see is not one it can delete.

A custom `--box` name is the operator's own and teardown will refuse it; the
rehearsal's reuse refusal says so rather than printing a teardown command that
cannot work.

**A round that did not pass keeps its boxes**, and so does `--keep`. A failed
leg is the case where you need the box standing to find out why, so the run
says the boxes are still there and prints the teardown command. `INCOMPLETE`
— phase 2 never ran — counts as not passing here for the same reason.

**Reuse is opt-in, and it weakens phase 1.** A rehearsal whose target box
already exists **refuses**, naming the box, its creation date, and the two ways
forward: tear it down, or pass `--reuse`. Reuse is legitimate when the operator
means it, but a box that is already `gh`-authenticated cannot prove the
creds-free half of phase 1 — the login WARN, the absent `.boot-id` marker and
the un-spawned sessions all SKIP. That is what happened to the `0.1.0` round
(#116), which is why the refusal is the default and why `--reuse` writes itself
into the run's output, at the point of reuse and again in the summary. **A
record of a reused round says so**, by carrying that line.

Deleting a box does not revoke the GitHub identity it logged into. Identity
lifecycle is a separate concern from drill fixtures, and teardown does not
touch it.

## What a record should contain

What ran, on what host, the pinned candidate ref, the numbers, and what failed.
Below is the *shape*, in a file named `drills/9.9.9.md` — a version that can
never collide with a real release. **No drill has been recorded here yet**;
this log starts empty rather than reconstructing runs from memory, since an
invented number is worse than no number.

```markdown
# Release drill — 9.9.9 — 2026-01-01

Run ID: drill-2026-01-01-a. Host: bare Debian 13 cloud image, box + rig
installed, 4 vCPU / 8 GB. Candidate ref: crew@1a2b3c4.

| Leg | Result |
| --- | --- |
| phase 1 — creds-free install, reviewer role, box disarmed | PASS |
| phase 2 — attention wake | PASS |
| phase 2 — review round through both one-shot gates | PASS |
| head dedup / re-request auto-approve | PASS |
| gate abuse refused | PASS |
| fleet-floor console (read-only) | PASS |
| operator-config convergence | clean, no changes |

Failed: nothing this run.
```

State what failed. A record with no failures listed reads as "nothing broke",
so if a leg was not run, say that instead of omitting it.
