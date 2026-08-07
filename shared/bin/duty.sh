#!/usr/bin/env bash
# duty.sh — the duty engine. One tick: boot gate, then every duty the box's
# roles enable, in fleet-standard priority order:
#
#   attention (all roles) → triage signals → review queue → resume → ci-red →
#   build → handoff → rebase → worktree hygiene → backlog hygiene (hourly)
#
# ci-red sits between resume and build because a builder repairs its own red
# PR before claiming another issue (ceremony BUILDER.md, "Your own red head
# outranks a new claim"). This header is what FLEET.md's duty order is
# reconciled against, so it is not decoration: a header that lags the module
# order is how the #149 drift went unnoticed.
#
# All DETECTION happens here in plain bash against GitHub's object APIs; the
# model is spawned only when a duty exists, with a role prompt rendered from
# prompts/. The scripts never write to the board themselves — with one
# operator-ruled exception (the re-request auto-approve, which goes through
# the submit gate like any verdict). Detection here, judgment in sessions.
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

# Manual invocations take the same lock the cron tick uses. The old scripts
# locked only in the crontab line, so a debugging run raced the tick.
if [ -z "${DUTY_LOCKED:-}" ]; then
  # `|| rc=$?` is load-bearing under `set -e`: a bare non-zero flock exits
  # the shell HERE, so the sentinel message below never ran and a contended
  # manual run printed nothing at all — exit 199 with total silence, which
  # is the failure this message exists to prevent. tick.sh avoids the same
  # trap by not using `set -e` at all.
  rc=0
  env DUTY_LOCKED=1 DUTY_DIR="$DUTY_DIR" flock -n -E 199 "$DUTY_DIR/.duty.lock" "$0" "$@" || rc=$?
  # An `if` block, not `[ … ] && echo …`: that form returns 1 on a non-199
  # exit and, as the last command before `exit`, would take `set -e` with it
  # — the same shape as the install.sh bug behind #25.
  if [ "$rc" -eq 199 ]; then
    echo "duty.sh: a tick already holds $DUTY_DIR/.duty.lock — nothing run" >&2
  fi
  exit "$rc"
fi

# Re-exec from a private snapshot: bash reads scripts lazily, and an
# in-place edit under a running tick corrupts the reader's byte offset
# (claude-bot, 2026-07-22). The snapshot dies with the run.
if [ -z "${DUTY_SNAPSHOT:-}" ]; then
  snap="$(mktemp "${TMPDIR:-/tmp}/duty-snapshot.XXXXXX.sh")"
  cp "$0" "$snap"
  DUTY_SNAPSHOT="$snap" exec bash "$snap"
fi
trap 'rm -f "$DUTY_SNAPSHOT" "$DUTY_DIR/.duty.lock.since"' EXIT
date +%s >"$DUTY_DIR/.duty.lock.since"

# shellcheck source=../lib/common.sh disable=SC1091
source "$DUTY_DIR/lib/common.sh"
load_conf
mkdir -p "$WORK_DIR" "$TREES_DIR" "$LOG_DIR"

log "duty run start"
# A stable identity for every run_session call in this process. Terminal
# breakers use it to probe at most once per kind per tick after opening.
# shellcheck disable=SC2034  # consumed dynamically by common.sh
DUTY_TICK_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"

# --- Once-per-boot sanity gate. The kernel boot id changes on every reboot;
# the first tick after a restart probes auth and disk and prunes worktrees
# left by the crash. The marker is written ONLY when gh and the box CLI both
# authenticate — a box with dead credentials re-checks (loudly) every tick
# instead of silently playing with them. On failure the operator is alerted
# once per boot: the boot gate that only ever wrote to a quieter log was the
# fleet's silent-starvation mode (the triage box is the minting SPOF). ---
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
if [ "$(cat "$DUTY_DIR/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
  {
    echo "== boot check $(date -Is) =="
    gh auth status || true
    df -h / | tail -1
    bot_cli_probe && echo "cli probe: ok" || echo "cli probe: FAILED"
    for d in "$WORK_DIR"/*/; do
      { [ -d "$d/.git" ] && git -C "$d" worktree prune -v; } || true
    done
  } >>"$DUTY_DIR/boot-check.log" 2>&1
  if gh auth status >/dev/null 2>&1 && bot_cli_probe; then
    echo "$boot_id" >"$DUTY_DIR/.boot-id"
  else
    warn "boot gate: auth probe failed — duty continues degraded, re-checking every tick"
    if [ "$(cat "$DUTY_DIR/.boot-alerted" 2>/dev/null)" != "$boot_id" ]; then
      alert "⚠️ $(hostname): boot gate failed (gh or CLI auth dead) — box is degraded"
      echo "$boot_id" >"$DUTY_DIR/.boot-alerted"
    fi
  fi
fi

# Identity comes from the token, not a hardcoded string: two of five boxes
# had both, used inconsistently. Resolved AFTER the boot gate so dead
# credentials hit the diagnostics above, not an opaque set -e death here.
# gh_identity, not a bare `gh api user`: the SAME single call also carries the
# token's expiry header and tells us whether the credential was rejected, so
# the floor learns both from the request the tick was making anyway. Nothing
# polls `gh auth status` any more — see common.sh.
ME="$(gh_identity)"
# Free, local, and every tick: reads the vendor's credential file rather than
# asking the vendor. The boot gate above still pays for one real bot_cli_probe
# per boot, which is where certainty is worth a round-trip.
check_vendor_credential
if [ -z "$ME" ]; then
  warn "cannot resolve own login (gh auth dead?) — nothing to do this tick"
  log "duty run end"
  exit 0
fi

# Identity's second carrier (#294). $ME is the gh half; git holds a COPY, and
# until now nothing kept it converged — the builder-identity split rotated the
# gh credential alone, so a split box authored every commit as the account it
# carried BEFORE the split and GitHub bylined that droid on this box's own PRs.
#
# Converged HERE: after $ME resolves, because that is the source of truth, and
# before the first duty dispatch below, because after it a session could
# already have committed. Nothing between these two points writes a commit.
#
# A box that cannot be made to byline itself spends no session at all. That is
# the refusal #294 asks for, and it is deliberately narrow: convergence has
# already tried, so reaching here means git would demonstrably commit under
# another droid's name. Running anyway is how the record got corrupted.
if ! converge_git_identity "$ME"; then
  warn "git identity does not name $ME and could not be repaired — no session this tick"
  # Once per boot, on the channel the auth watchdog already uses: this is a
  # by-hand repair (git config --global user.email), so re-alerting every five
  # minutes would train the operator to ignore the one channel that matters.
  if [ "$(cat "$DUTY_DIR/.identity-alerted" 2>/dev/null)" != "$boot_id" ]; then
    alert "🪪 $(hostname): git identity does not name $ME — refusing to run sessions that would commit as somebody else"
    echo "$boot_id" >"$DUTY_DIR/.identity-alerted"
  fi
  log "duty run end"
  exit 0
fi

# shellcheck source=../lib/duty-attention.sh disable=SC1091
source "$DUTY_DIR/lib/duty-attention.sh"
# shellcheck source=../lib/duty-review.sh disable=SC1091
source "$DUTY_DIR/lib/duty-review.sh"
# shellcheck source=../lib/duty-builder.sh disable=SC1091
source "$DUTY_DIR/lib/duty-builder.sh"
# shellcheck source=../lib/duty-triage.sh disable=SC1091
source "$DUTY_DIR/lib/duty-triage.sh"

# ATTENTION is role-independent and runs FIRST, per FLEET.md: a parked
# demand outranks every queue.
duty_attention

if has_role triage; then
  duty_triage
fi

if has_role reviewer; then
  duty_review
fi

if has_role builder; then
  duty_builder
fi

# Backlog hygiene: triage-only, self-scheduling (runs when HYGIENE_INTERVAL
# has elapsed, whatever tick that lands on — a skipped top-of-hour tick
# delays it instead of losing the hour). Shares this tick's lock, so it can
# never race the triage sweep over the same checkouts (the old separate
# hygiene cron could, and did share ~/duty/work with duty.sh unlocked).
if has_role triage; then
  now="$(date +%s)"
  last="$(cat "$DUTY_DIR/.hygiene-last" 2>/dev/null || echo 0)"
  if [ $((now - last)) -ge "$HYGIENE_INTERVAL" ]; then
    # shellcheck source=../lib/duty-hygiene.sh disable=SC1091
    source "$DUTY_DIR/lib/duty-hygiene.sh"
    duty_attention_audit
    duty_hygiene && echo "$now" >"$DUTY_DIR/.hygiene-last"
  fi
fi

log "duty run end"
