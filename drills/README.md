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
