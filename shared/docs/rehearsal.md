# Duty-engine rehearsal — runbook for a fresh box and a fresh session

> Automated form: `drill/rehearsal.sh` (run on the box HOST from a crew
> checkout) executes everything below mechanically — phase 1 always,
> phase 2 automatically once the operator has logged the drill box in —
> printing ok/FAIL per check. This document remains the explainer for what
> each check means, and the manual path when no host is at hand.
> It accepts `--agent <name>` and defaults to `claude`; available agents are
> the profiles under `shared/conf/agents/`.

You are validating the shared duty engine (crew PR #16) on a box that has
never run it. You have no context beyond this repo: read `shared/README.md`
first (architecture + provenance), then run the phases below IN ORDER.
Everything before "Phase 2" needs NO credentials — that is the point: the
engine must behave correctly, loudly, and harmlessly on a creds-free box.

The engine has passed static verification (shellcheck, 27 fixture tests,
three adversarial reviews) but before this rehearsal it has NEVER executed
a real tick. Assume bugs. Anything you find goes to the PR (Phase 3), with
logs, as a finding — never silently worked around.

## Phase 0 — orientation and static checks

```sh
git clone https://github.com/heavy-duty/crew ~/crew && cd ~/crew
git checkout crew/shared-duty        # skip if the PR has merged
shared/test/run.sh                   # must end: failed 0
command -v shellcheck && shellcheck -x shared/bin/*.sh shared/lib/*.sh \
  shared/install.sh cli/crew shared/conf/fleet.conf \
  shared/conf/agents/*.conf shared/conf/roles/*.conf
```

## Phase 1 — pre-auth engine validation (no logins anywhere)

Install as the default claude reviewer. The agent CLI may be absent in this
phase: its profile's auth probe then returns non-zero, which is the expected
unauthenticated result, and no session can launch:

```sh
shared/install.sh --agent claude --role reviewer --arm-cron
```

To rehearse another supported runtime, pass the same agent consistently:
`drill/rehearsal.sh --agent grok` derives the `grok-box` template, installer
agent, assertions, auth probe, and login hint from the grok profile.

Verify, and record the output of each check:

1. `cat ~/duty/VERSION` — `crew@<sha>` matching `git rev-parse --short HEAD`.
2. `cat ~/duty/conf/instance.conf` — `BOT_AGENT=claude`,
   `BOT_ROLES="reviewer"` (or the agent selected with `--agent`).
3. `crontab -l` — exactly one line: `*/5 * * * * $HOME/duty/bin/tick.sh`
   (no notify line: this is not the triage role).
4. Within ~5 minutes, `~/duty/duty.log` gains per-tick evidence:
   `duty run start` → a WARN that the login cannot be resolved →
   `duty run end`. EVERY 5-minute boundary must produce lines; silence at
   a boundary is a finding (that is the tick evidence contract).
5. `~/duty/boot-check.log` — one boot block; `cli probe: FAILED` is
   CORRECT here; `~/duty/.boot-id` must NOT exist (marker only on
   verified auth).
6. Lock behavior: run `~/duty/bin/duty.sh` by hand twice —
   idle: it runs; concurrently with itself or a tick: the second prints
   "a tick already holds …" and exits 199.
7. Idempotence: rerun `shared/install.sh --arm-cron` (no flags) — it must
   keep the instance config and not duplicate the cron line.
   `shared/install.sh --agent claude --role nosuchrole` must refuse.

Let it tick for at least 30 minutes. Expected steady state: three evidence
lines per tick, no growth in error variety, no session logs in
`~/duty/logs/`, no board writes anywhere.

## Phase 2 — authenticated ticks (operator required)

STOP until the operator has decided the identity (one box per identity is
a fleet invariant). For the default claude runtime this includes the singleton
triage identity as well as builder/reviewer identities: never borrow any live
identity until its other box's cron is DISARMED. The same rule applies to every
agent. A throwaway test identity instead needs a `FLEET_MANIFEST` line in
`shared/conf/fleet.conf` (or reuse Phase 1's explicit instance.conf, which
survives re-installs). The operator performs `gh auth login` and the selected
agent profile's `AGENT_LOGIN_HINT`; you never handle credentials.

Authentication creates two independent hazards. First, another live box must
not run the same identity. Second, a normal engine registry points at production
repositories, so a drill tick can make legitimate-looking production writes.
The automated rehearsal therefore saves `repos.txt`, points it at nothing
before the first authenticated tick, replaces it with the sandbox alone before
phase 2, verifies that narrowing fail-closed, and restores the original on exit
or interruption.

The rehearsal deliberately does **not** arm cron. Every drill tick is explicit;
the old scheduled-boundary check was not worth creating an autonomous agent
that could outlive the invoking shell. On every exit the cleanup path removes
any duty tick left by an older run and restores the registry. If the shell or
box is in doubt, `box down <box>` is the reliable stop: `pkill` routed through
`box exec` is unprivileged and may be unable to signal an already-running
session.

1. First authenticated tick: boot gate passes, `~/duty/.boot-id` appears,
   the login-resolution WARN disappears, review sweep logs
   `review: no outstanding review requests anywhere` (if true).
2. Attention drill: have the operator assign a test issue to the identity
   and add the `attention` label. Next tick: pickup session launches
   (`SESSION START kind=attention`), posts `📌 picked up`, REMOVES the
   label, then acts. Verify the session log in `~/duty/logs/`, and that
   the next tick logs `attention: none`.
3. Review drill: a scratch PR in a sandbox repo with a review request to
   the identity. Expect in order: candidate in the sweep log; the
   `🔎 reviewing head <full-sha>` comment posted exactly once (via
   post-once.sh); a verdict submitted via submit-verdict.sh pinned to that
   head; next tick: `my latest review already covers head …; skipping`.
4. Re-request drill: re-request review at the UNCHANGED head. Next tick
   must auto-approve through the gate (`--supersede-own`), log it, and the
   tick after must be quiet again.
5. Gate abuse: run `~/duty/bin/submit-verdict.sh` by hand with the same
   args as the landed verdict — must exit 0 "already present" WITHOUT a
   second review appearing on the PR. A short SHA must be refused.
6. Timeout: nothing to force here, but confirm every SESSION END line
   carries rc= and dur=.
7. Teardown: `repos.txt` is restored to its pre-drill contents and
   `crontab -l` contains no duty tick.

## Phase 3 — report

Comment on crew PR #16: which phases ran, every deviation from the
expectations above (with the duty.log/session-log excerpts), and what you
changed. Fixes go on the PR branch with the finding as provenance — the
same standard as everything already in it. If all of Phase 1 and 2 pass,
say so explicitly: that is the evidence the staged rollout
(`shared/docs/single-role.md`, migration order) is cleared to start.
