#!/usr/bin/env bash
# reap-now.sh — run the reaper sweep NOW, out of tick, under the duty lock
# (#589 D7 step 1).
#
# The daily slot in duty.sh is self-scheduling on `.reaper-last`, which is
# exactly right for a janitor and exactly wrong for `crew reset --cut`: the cut
# has to reclaim before it measures, and a sweep that answers "not yet, I ran
# four hours ago" would leave the cut measuring a box the reaper was about to
# fix. So this entry point runs the sweep REGARDLESS of `.reaper-last`.
#
# IT DOES NOT WRITE `.reaper-last` EITHER. The stamp is the box's own daily
# cadence and belongs to the tick; an operator running a cut at 09:00 must not
# silently move the box's janitor slot to 09:00 forever. The cost of leaving it
# alone is that the next tick may repeat a walk that just ran, which is two
# `find` passes over caches this module keeps to milliseconds — against a
# scheduling side effect nothing in the fleet would ever attribute to a reset.
#
# THE LOCK IS THE POINT, not an incidental. #457 D1's own hazard note is "a
# reaper deleting files under a running session", and this is the one reaper
# call that is not already inside a tick holding the lock. It is taken exactly
# as duty.sh takes it — `flock -n` on $DUTY_DIR/.duty.lock — so a box mid-tick
# or mid-session refuses instead of sweeping underneath it. `-n` and never a
# wait: `crew reset --cut` has already drain-probed this box and decided it was
# free (D6), so a lock held HERE is news — something took it in between — and
# the answer is to say so and let the cut skip the box, not to block a fleet-
# wide command on one guest.
#
# Exit 0 swept · 199 the lock was held (nothing run) · 1 could not set up.
# 199 is duty.sh's own contended-tick status, kept identical so a reader of
# either script learns one number.
set -uo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

# Re-exec under the lock, the shape duty.sh uses. `|| rc=$?` rather than a bare
# call for the reason duty.sh spells out at its own gate: under a non-zero
# flock the sentinel message below would never run and a contended invocation
# would be silent, which is the one outcome an operator cannot act on.
if [ -z "${REAP_NOW_LOCKED:-}" ]; then
  rc=0
  env REAP_NOW_LOCKED=1 DUTY_DIR="$DUTY_DIR" \
    flock -n -E 199 "$DUTY_DIR/.duty.lock" "$0" "$@" || rc=$?
  if [ "$rc" -eq 199 ]; then
    echo "reap-now.sh: a duty tick holds $DUTY_DIR/.duty.lock — nothing run" >&2
  fi
  exit "$rc"
fi

# shellcheck source=../lib/common.sh disable=SC1091
source "$DUTY_DIR/lib/common.sh"
load_conf
# shellcheck source=../lib/duty-reaper.sh disable=SC1091
source "$DUTY_DIR/lib/duty-reaper.sh"

log "reaper: on-demand sweep requested (#589 D7)"
duty_reaper
