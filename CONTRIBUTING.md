# Contributing

This repo is governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). **Agents:
read [`.ceremony/AGENTS.md`](.ceremony/AGENTS.md) first** — it routes you to
your role file (builder, reviewer, triage), vendored beside it,
byte-identical to ceremony at the pin named in
[`.github/workflows/release.yml`](.github/workflows/release.yml) and
guarded by the `docs-sync` step in CI. The review-round doctrine — drafts,
whole-round replies, verdicts, the handoff — lives there and in
[`.ceremony/LABELS.md`](.ceremony/LABELS.md); this file keeps only what is
genuinely crew's.

## The PR loop, crew specifics

1. **Fork and branch.** Contributors work from forks; upstream branches are
   for maintainers. crew's branch convention is `<type>/<issue>-<slug>`.
   Title the PR conventionally (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`).
2. **The review panel** (`.github/labels.conf`'s `panel=` line):
   `claude-bot-andresmgsl`, `codex-bot-andresmgsl`, `grok-bot-andresmgsl`,
   `kimi-bot-andresmgsl` — the required verdicts for a PR are the panel minus
   its author. The maintainer (`danmt`) takes the last word and merges.
3. **Checks must be green.** crew runs two CI workflows:
   - `shared-ci.yml` — crew's engine suite (`shellcheck`, `shared/test/run.sh`,
     the fleet-floor collector + page tests, the built-page freshness check).
     It carries a paths filter, so a PR touching only release furniture skips
     it.
   - `release-guards.yml` — the ceremony guards (`changelog-armed`,
     `changelog-monotonic`, `changelog-assembled`, `drill-recorded`,
     `runner-isolated`, `docs-sync`), run as ceremony's pinned actions on
     **every** PR with no paths filter, so a furniture PR still carries a real
     green check.
4. **Feature PRs land their changelog entry as part of the PR**: write
   `changelog.d/<issue>.md` — the release PR assembles those fragments into
   the release notes verbatim.

## Changelog entries

Every PR that changes behaviour writes one `changelog.d/<issue>.md` fragment.
The fragment keeps the relevant `### Added` / `### Changed` / `### Fixed`
heading above its entry. One line is the whole rule — if it wraps more than
twice in your editor, cut it down.

- **Say what changed, and stop.** Why it was wrong, how it was found, what it
  cost — that belongs in the PR body and the commit message. This file answers
  one question: what is different in this version.
- **Any word that can be removed, is removed.**
- **Lead with the surface, not the mechanism.**
- **Cite the issue or PR** — `(#84)` — and let the reader follow it for the rest.
- **Mark a breaking change** with a leading `BREAKING:`.
- Group under `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- No bold run-in headings, no sub-paragraphs, no code blocks, no prose essays.

## Releasing

A release is a PR, and merging it is the release. The ceremony — the two
doors, the decide table, the stamps, the post-release re-arm — is
heavy-duty/ceremony's machinery, consumed by reference:
[its README](https://github.com/heavy-duty/ceremony/blob/main/README.md) is
the doctrine, `.github/workflows/release.yml` here is the caller pinning it,
and the guards run in `release-guards.yml` from the same pin. Bare `X.Y.Z`
tags, no `v`; the tag's source tarball is the package. `VERSION` bootstraps at
`X.Y.Z-dev` and the ceremony stamps it bare to ship, then re-arms to the next
`-dev`.

What stays crew's is the **drill** — the real-host gate before a release PR's
handoff, run by [`drill/rehearsal.sh`](drill/rehearsal.sh) (per role via
`drill/rehearsal-all.sh`): install the engine in a drill box on a box host and
exercise the duty lifecycle end to end — the creds-free install, then (once the
box is logged in) the attention wake, the review round through both one-shot
gates, head dedup, the re-request auto-approve, and gate abuse. crew's drill
asserts the **duty lifecycle** (a fleet of agents does triage, build and review
the way the doctrine says), where box asserts isolation, rig asserts
convergence, and cast asserts promotion. The full meaning — the per-version
record files, the waiver rule — is [`drills/README.md`](drills/README.md); the
`drill-recorded` guard enforces the record on every release tree.

## Labels — who sets what

The taxonomy and state machine are
[`.ceremony/LABELS.md`](.ceremony/LABELS.md); crew's `scope:*` rows live in
`.github/labels.conf` (reconciled by the labels caller) and their path map in
`.github/labeler.yml`. What matters day to day is who sets each kind — most of
it is machinery, and hand-moving a machine-owned label just gets corrected on
the next pass:

| Labels | Set by |
|---|---|
| `state:*` | the labels workflow ([.github/workflows/labels.yml](.github/workflows/labels.yml)) — recomputed from GitHub's own facts on PR events and every 15 minutes. Machine-owned, with one exception: the author sets `state:needs-human` at handoff and the workflow reconciles it. Exactly one per PR: *whose ball is it.* |
| `blocker:*` | the same workflow, from the same facts — *what is in the way.* Any number per PR, or none. Never by hand: fix the thing and the next sweep drops the label. |
| `stale` | the same workflow — 48h without commits, comments, or reviews. `blocked` PRs are exempt. |
| `scope:*` on PRs | actions/labeler, from the changed paths ([.github/labeler.yml](.github/labeler.yml)). Additive — you may add more, the machine won't remove them. |
| `scope:*` on issues | you, when opening or triaging — issues have no paths to derive from. |
| `blocked`, `release` | you — automation never guesses intent. |
| `merge-next` | you or the agent owning the queue. The workflow never sets it — it only **clears** it once the PR stops being something a human could merge. |
| `bug` / `enhancement` / `documentation` | you, on issues only — a PR's type already lives in its title. |

## Issues

Only triage mints issues — everyone else starts a
[Discussion](https://github.com/heavy-duty/crew/discussions), and triage
converges it to an outcome (`.ceremony/TRIAGE.md`). Give issues the same care
as PR titles: say the surface in the title, apply a `scope:` label and a type
label when you open one, and `blocked` when it waits on something — that is
what keeps the board navigable as the issue count grows.
