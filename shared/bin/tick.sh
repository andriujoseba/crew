#!/usr/bin/env bash
# tick.sh — the only cron target. Wraps a job (duty by default, notify for
# the operator notifier) in a non-blocking flock and guarantees exactly one
# evidence line per 5-minute boundary, in one of three shapes:
#
#   <ts> duty run start            — normal tick (logged by the job itself)
#   <ts> duty tick skipped: ...    — the lock refused this boundary
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

# Who holds a lock, asked of the kernel (#726). Used by the 199 branch below,
# where the argument for reading it rather than inferring it lives.
#
# `/proc/locks` carries one row per held lock: the pid that took it, and the
# device and inode of the file it was taken on. The file's own `stat` supplies
# that key — `%d` is the device as one number, which splits into the major and
# minor halves the kernel prints in hex.
#
# Prints nothing at all rather than guessing: no readable table, no row for
# this file, or a pid the kernel declines to name (it prints `0` for a holder
# this namespace cannot see, `-1` for an owner with no pid) are all "I cannot
# say", and the caller must treat them as such. A blocked WAITER is printed
# with a leading `->` that shifts every column, so rows are matched on the
# exact unblocked shape — a process queued for the lock is not its holder.
lock_owner_pid() { # LOCKFILE -> the pid that holds it, or nothing
  local dev ino key
  [ -r /proc/locks ] || return 0
  dev="$(stat -c %d "$1" 2>/dev/null)" || return 0
  ino="$(stat -c %i "$1" 2>/dev/null)" || return 0
  case "$dev" in '' | *[!0-9]*) return 0 ;; esac
  case "$ino" in '' | *[!0-9]*) return 0 ;; esac
  key="$(printf '%02x:%02x:%u' \
    "$(((dev >> 8) & 0xfff))" "$(((dev & 0xff) | ((dev >> 12) & 0xfff00)))" "$ino")"
  awk -v k="$key" \
    '$2 == "FLOCK" && $6 == k { if ($5 ~ /^[1-9][0-9]*$/) print $5; exit }' \
    /proc/locks 2>/dev/null
}

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
  # Headroom overrides are fleet policy. Defaults stay in the operating-limit
  # table; these files can supply only an operator's explicit override.
  # shellcheck disable=SC1091
  [ -r "$CONF_DIR/fleet.defaults.conf" ] && . "$CONF_DIR/fleet.defaults.conf"
  # shellcheck disable=SC1091
  [ -r "$CONF_DIR/fleet.conf" ] && . "$CONF_DIR/fleet.conf"
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
  # Two claims, and the KERNEL decides which one this boundary gets (#726).
  #
  # The question is whether the run that owns this lock is still alive, and the
  # sidecar cannot answer it. `$LOCK.since` is written by the job a few
  # milliseconds AFTER `flock` acquires — the lock is taken in flock's own
  # process, before the target's interpreter has started — so an absent sidecar
  # is equally a run that has exited and a run that is still starting up. A
  # categorical claim built on it blames an inherited descriptor while a
  # genuinely concurrent run holds the lock, which is the first thing this
  # branch must never do (codex-bot, #740: staged and observed, not argued).
  #
  # `/proc/locks` answers it, and answers it from the instant the lock is
  # taken, because the kernel records the holder as part of taking it: there is
  # no window to narrow. `lock_owner_pid` above keys the row on the lock file's
  # own device and inode and reads back the pid; `/proc/<pid>` says whether
  # that pid is still there.
  #
  # What makes that pid the RUN's liveness rather than an accident is the
  # acquisition shape above — flock's COMMAND form, where flock(1) takes the
  # lock and waits for the target, so the recorded pid lives exactly as long as
  # the run does. An implementation that exec'd the target instead of forking
  # would record the target's own pid, which lives exactly as long too: the
  # reading holds either way. What it would NOT survive is moving acquisition
  # to the fd form, `flock -n 9`, where the recorded pid belongs to a helper
  # that exits immediately and EVERY holder would read as gone. #726's last
  # acceptance criterion holds that shape still, and shared/test/common.sh
  # pins it to this reading.
  #
  # So a pid that resolves and is GONE is the second claim, and the only path
  # to it. `flock` hands the lock on a descriptor every child inherits, and the
  # lock stands while ANY holder of that descriptor does — so a run that has
  # exited can leave the lock held by something it spawned. Until #726 this
  # branch said `previous run still holds the lock (running unknown)`, which
  # sends an operator hunting for a duty process that is gone. What to look for
  # instead is on the preceding SESSION END record: `left=` counts the
  # processes that outlived that session, and one of them is holding this.
  #
  # Everything else keeps the first claim: a live pid, and equally a pid the
  # kernel will not name (no `/proc/locks` to read, a holder this namespace
  # cannot see). Absence of evidence is not evidence of death — the categorical
  # claim is the one that has to earn its way in, and defaulting the other way
  # costs only the pre-#726 reading, which is wrong in exactly the case that
  # reading cannot detect.
  owner="$(lock_owner_pid "$LOCK")"
  if [ -n "$owner" ] && [ ! -d "/proc/$owner" ]; then
    echo "$(ts) $JOB tick skipped: lock held with no live holder — the previous run exited; its descriptor was inherited by a process it left behind" >>"$LOG"
  else
    # The sidecar keeps the one job it was ever sound for: how long. Absent or
    # truncated mid-write, the holder is a holder still and only its start time
    # is lost, so `running unknown` now means exactly that and never "no
    # holder". Before #726 a non-numeric stamp reached `$(( now - <word> ))`
    # under `set -u`, which aborted this script at that line and wrote NO line
    # for the boundary — silence, which the evidence contract at the top of
    # this file reserves for a dead cron.
    since="unknown"
    if [ -f "$LOCK.since" ]; then
      stamp="$(cat "$LOCK.since" 2>/dev/null || echo)"
      case "$stamp" in
        '' | *[!0-9]*) ;;                              # truncated mid-write
        *) since="$(( $(date +%s) - stamp ))s" ;;
      esac
    fi
    echo "$(ts) $JOB tick skipped: previous run still holds the lock (running $since)" >>"$LOG"
  fi
elif [ "$rc" -ne 0 ]; then
  echo "$(ts) $JOB tick FAILED: $JOB.sh exited $rc" >>"$LOG"
fi
