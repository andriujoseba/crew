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

Fixtures and the drill box are left in place for inspection; the box is always
left disarmed and its pre-drill repo registry restored. Companion prose:
[`shared/docs/rehearsal.md`](../shared/docs/rehearsal.md).

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
