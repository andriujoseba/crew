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
     it, and it **does not run while the PR is a draft** — your WIP saves are
     free. Marking the PR ready for review runs it at that head, with no
     further push needed, so the round's green-check precondition is met by the
     act of marking ready (#136).
   - `release-guards.yml` — the ceremony guards (`changelog-armed`,
     `changelog-monotonic`, `changelog-assembled`, `drill-recorded`,
     `runner-isolated`, `docs-sync`), run as ceremony's pinned actions on
     **every** PR with no paths filter, so a furniture PR still carries a real
     green check.
4. **Feature PRs land their changelog entry as part of the PR**: write
   `changelog.d/<issue>.md` — the release PR assembles those fragments into
   the release notes verbatim.

## Changelog entries

Every PR that changes behaviour writes one `changelog.d/<issue>.md` fragment,
holding one or more entries under the relevant `### Added` / `### Changed` /
`### Fixed` heading.

**Length is a per-entry rule and nothing else.** One entry is one line, and the
cap it must not exceed is the vendored builder doctrine's — read the number in
[`.ceremony/BUILDER.md`](.ceremony/BUILDER.md), which this file deliberately
does not copy: a number that moves only with a pin bump drifts the moment it is
written down twice. Wrapping an entry across source lines is not length and
never counts against it. What to do about an entry that is over the cap is the
doctrine's answer too, and this file leaves it there: whatever that remedy is,
it fixes one entry's length and never answers how many entries a fragment
carries. That question is settled below, and length is no part of it.

**Bullet count follows the distinct user-visible changes, never the author's
judgment about length.** One entry per change a reader meets on its own: four
separate outcomes ship four entries, and one outcome that took three lines to
state is still one entry. The test, applied to a specific fragment:

> A reader who cares about only one of the two outcomes — does the other
> sentence still tell them something they can act on? Yes → two bullets.
> No → one.

- **Say what changed, and stop.** Why it was wrong, how it was found, what it
  cost — that belongs in the PR body and the commit message. This file answers
  one question: what is different in this version. This is also the rule that
  decides a bullet explaining, justifying or naming the mechanism of another
  one: it is not a second change, so it is **deleted**, not merged back into
  the first.
- **Any word that can be removed, is removed.**
- **Lead with the surface, not the mechanism.**
- **Cite the issue or PR** — `(#84)` — and let the reader follow it for the rest.
- **Mark a breaking change** with a leading `BREAKING:`.
- Group under `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- No bold run-in headings, no sub-paragraphs, no code blocks, no prose essays.

Not all of that is worth a `CHANGES_REQUESTED`. A fragment's accuracy is
load-bearing and a reviewer blocks on it; its phrasing is editorial and rides
an approval as a nit (`.ceremony/REVIEWER.md`). **Bullet count is editorial** —
one sentence that two reviewers read into opposite verdicts (#263) is what this
split exists to stop:

| blocking | editorial — a nit, rides an approval |
|---|---|
| an entry that is inaccurate about the behaviour that shipped | how many bullets the fragment carries |
| a missing `###` group heading | which of two accurate phrasings is tighter |
| a missing issue cite | word-level trimming inside an accurate entry |
| mechanism, justification or how-it-was-found prose | ordering of bullets within a fragment |
| an entry over the per-entry cap | |
| editing `CHANGELOG.md` directly instead of writing a fragment | |

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
