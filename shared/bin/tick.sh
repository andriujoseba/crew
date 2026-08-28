#!/usr/bin/env bash
# tick.sh — the only cron target. Wraps a job (duty by default, notify for
# the operator notifier) in a non-blocking flock and guarantees exactly one
# evidence line per 5-minute boundary, in one of three shapes:
#
#   <ts> duty run start            — normal tick (logged by the job itself)
#   <ts> duty tick skipped: ...    — previous run still holds the lock
#   <ts> duty tick FAILED: ...     — the job exited non-zero
#
# Silence at a boundary therefore means exactly one thing: cron itself is
# dead. This evidence contract is claude-bot's tick.sh, generalized; the
# other four boxes put flock in the cron line, where a skipped tick wrote
# nothing and a wedged bot was indistinguishable from a healthy quiet one
# (grok's and kimi's metrics files both flag it).
#
# Deliberately `set -u` only, never -e: this script must always reach the rc
# dispatch below.
set -u

JOB="${1:-duty}"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
LOG="$DUTY_DIR/$JOB.log"
LOCK="$DUTY_DIR/.$JOB.lock"
TARGET="$DUTY_DIR/bin/$JOB.sh"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Rotation happens HERE, before the append redirect below opens the file —
# rotating inside the job would move the inode the shared fd points at, and
# that tick's evidence lines (including "run start") would land in the old
# generation, which reads exactly like "cron is dead".
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 5242880 ]; then
  mv "$LOG" "$LOG.1"
fi

# --- vitals (#483 D2) --------------------------------------------------------
# One box vitals record per tick, alongside the lines this file already
# writes and on no new schedule. Emitted HERE, before the dispatch and
# outside the lock, so it lands on a SKIPPED tick too: a box wedged behind a
# stuck run is exactly the box whose memory and disk a reader wants, and a
# probe inside the lock would go quiet at that moment.
#
# It does not touch the evidence contract at the top of this file. That
# contract is about the three `$JOB tick ...` shapes, and a VITALS line
# matches none of them — the `duty run start` / `skipped` / `FAILED` greps
# that read this log are unaffected by a fourth, distinctly-prefixed line.
#
# Wrapped in a subshell that cannot fail the tick: the probe is telemetry, and
# telemetry that can break the thing it observes is worse than no telemetry.
# Its own D6 degradation handles a missing field; this handles a missing or
# broken probe.
(
  VITALS_SH="${VITALS_SH:-$DUTY_DIR/bin/vitals.sh}"
  [ -r "$VITALS_SH" ] || exit 0
  # The role profile supplies BOX_CPU/BOX_MEMORY/BOX_DISK for the D3
  # comparison. Sourced best-effort and per-role: a box with no instance.conf
  # yet still emits a record, just without the profile findings.
  CONF_DIR="${CONF_DIR:-$DUTY_DIR/conf}"
  # shellcheck disable=SC1091
  [ -r "$CONF_DIR/instance.conf" ] && . "$CONF_DIR/instance.conf"
  for _role in ${BOT_ROLES:-}; do
    # shellcheck disable=SC1090
    [ -r "$CONF_DIR/roles/$_role.conf" ] && . "$CONF_DIR/roles/$_role.conf"
  done
  # shellcheck disable=SC1090
  . "$VITALS_SH" && emit_vitals
) >>"$LOG" 2>&1 || true

# Sentinel 199 distinguishes lock-busy from a real failure (99 was too
# plausible as a genuine tool exit under duty.sh's set -e). Each job gets
# its own guard variable so a leaked guard can never bypass the OTHER
# job's lock.
LOCKVAR="$(printf '%s' "$JOB" | tr '[:lower:]' '[:upper:]')_LOCKED"
env "$LOCKVAR=1" DUTY_DIR="$DUTY_DIR" flock -n -E 199 "$LOCK" "$TARGET" >>"$LOG" 2>&1
# rc read on its own line, never inside an `if` compound — the first draft of
# this file shipped with rc reading the if's status (claude-bot knowledge.md).
rc=$?

if [ "$rc" -eq 199 ]; then
  since="unknown"
  if [ -f "$LOCK.since" ]; then
    since="$(( $(date +%s) - $(cat "$LOCK.since" 2>/dev/null || echo 0) ))s"
  fi
  echo "$(ts) $JOB tick skipped: previous run still holds the lock (running $since)" >>"$LOG"
elif [ "$rc" -ne 0 ]; then
  echo "$(ts) $JOB tick FAILED: $JOB.sh exited $rc" >>"$LOG"
fi
