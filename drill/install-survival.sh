#!/usr/bin/env bash
# install-survival.sh — step 9's engine/cron/tick survival predicate for
# drill/install-drill.sh. The caller supplies bx(); keeping the predicate here
# makes both of its paths fixture-testable without a box, the way
# rehearsal-safety.sh does for the isolation interlocks.
#
# Step 9 proves the engine outlives its console. Engine and cron are diffed
# across the removal, while both tick contexts wait for a line written after
# the removal returned. A box hired seconds earlier has no ~/duty/duty.log at
# all — the first line is written at the first cron boundary — which is why the
# record still distinguishes a box arriving with history from one arriving
# without it. Observed live on crew-drill-011, 2026-08-03: the drill read an
# empty tail and redded, and the box's first tick fired 14 seconds later, after
# the console was gone (#341).
#
# "After the removal" is meant literally. The tick assertion measures its wait
# against a baseline taken once the removal has RETURNED, not the read taken
# before it: a boundary striking
# while the uninstall runs writes a line that proves nothing about survival, and
# a wait that accepts the first non-empty line it sees would pass on it at zero
# elapsed time. Same reasoning for engine and cron, which are re-read after the
# wait as well as before it — a box that loses either one while the drill sits
# waiting did not outlive its console either.

# The wait budget's two adjustable halves. The period itself is read off the
# cron line the box is carrying; this is only the fallback for a line that
# names no `*/N`, plus the slack a boundary needs to actually write.
: "${INSTALL_SURVIVAL_PERIOD:=300}"
: "${INSTALL_SURVIVAL_GRACE:=90}"
: "${INSTALL_SURVIVAL_POLL:=10}"

# Clock and sleep are seams, not conveniences: a fixture drives the wait
# through them without spending it, so the suite can exercise the real budget.
install_survival_now() { date +%s; }
install_survival_sleep() { sleep "$1"; }

install_survival_read_engine() { bx "head -1 ~/duty/VERSION 2>/dev/null" | tr -d '\r\n' || true; }
install_survival_read_cron() { bx "crontab -l 2>/dev/null | grep -F '/duty/bin/tick.sh' || true" | tr -d '\r' || true; }
install_survival_read_tick() { bx "tail -n 1 ~/duty/duty.log 2>/dev/null" | tr -d '\r' || true; }

# install_survival_budget CRON_LINE — how long one boundary plus grace is, in
# seconds. A `*/N` schedule ticks every N minutes; anything else falls back to
# the shipped 5-minute period rather than guessing at the line's meaning.
install_survival_budget() {
  local cron="$1" minutes=''
  case "$cron" in
    '*/'[0-9]*' '*) minutes="${cron#*/}"; minutes="${minutes%% *}" ;;
  esac
  case "$minutes" in ''|*[!0-9]*) minutes='' ;; esac
  if [ -n "$minutes" ] && [ "$minutes" -gt 0 ]; then
    printf '%s\n' "$(( minutes * 60 + INSTALL_SURVIVAL_GRACE ))"
  else
    printf '%s\n' "$(( INSTALL_SURVIVAL_PERIOD + INSTALL_SURVIVAL_GRACE ))"
  fi
}

# install_survival_before — read the three surfaces the removal must not
# disturb, and record whether the box arrived with tick history.
# shellcheck disable=SC2034  # PATH_LABEL is read by the caller's pass line
install_survival_before() {
  INSTALL_SURVIVAL_ENGINE_PRE="$(install_survival_read_engine)"
  INSTALL_SURVIVAL_CRON_PRE="$(install_survival_read_cron)"
  INSTALL_SURVIVAL_TICK_PRE="$(install_survival_read_tick)"
  if [ -n "$INSTALL_SURVIVAL_TICK_PRE" ]; then
    INSTALL_SURVIVAL_PATH=history
    INSTALL_SURVIVAL_PATH_LABEL="the box arrived with tick history"
  else
    INSTALL_SURVIVAL_PATH=fresh
    INSTALL_SURVIVAL_PATH_LABEL="the box arrived with no duty.log"
  fi
}

# install_survival_wait_for_tick BUDGET BASELINE — poll duty.log until a line
# appears that the completed removal did not already leave there, or the budget
# runs out. The wait IS the assertion here: a diff says a line written before
# the removal is still there, this says the engine wrote one after it. Which is
# why BASELINE — the read taken once the removal returned — has to be excluded:
# accepting any non-empty line would let a boundary that struck DURING the
# uninstall pass the leg at zero elapsed time, asserting nothing.
install_survival_wait_for_tick() {
  local budget="$1" baseline="$2" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    if [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" != "$baseline" ]; then
      return 0
    fi
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}

# install_survival_diff_engine_cron WHEN — read the two surfaces that must be
# byte-identical across the removal and append a line per miss to
# INSTALL_SURVIVAL_MISSED, WHEN naming the read that saw it. Called before and
# after the tick wait; a surface is reported once, at the read
# where it first missed, so the second pass adds only what the first did not see.
install_survival_diff_engine_cron() {
  local when="$1"
  INSTALL_SURVIVAL_ENGINE="$(install_survival_read_engine)"
  INSTALL_SURVIVAL_CRON="$(install_survival_read_cron)"

  if [ "$INSTALL_SURVIVAL_ENGINE_SEEN" = ok ]; then
    if [ -z "$INSTALL_SURVIVAL_ENGINE" ]; then
      INSTALL_SURVIVAL_ENGINE_SEEN=missed
      INSTALL_SURVIVAL_MISSED+=("engine: read nothing at ~/duty/VERSION $when, where the box carried '$INSTALL_SURVIVAL_ENGINE_PRE' before the removal")
    elif [ "$INSTALL_SURVIVAL_ENGINE" != "$INSTALL_SURVIVAL_ENGINE_PRE" ]; then
      INSTALL_SURVIVAL_ENGINE_SEEN=missed
      INSTALL_SURVIVAL_MISSED+=("engine: read '$INSTALL_SURVIVAL_ENGINE' at ~/duty/VERSION $when, where the box carried '$INSTALL_SURVIVAL_ENGINE_PRE' before the removal")
    fi
  fi

  if [ "$INSTALL_SURVIVAL_CRON_SEEN" = ok ]; then
    if [ -z "$INSTALL_SURVIVAL_CRON" ]; then
      INSTALL_SURVIVAL_CRON_SEEN=missed
      INSTALL_SURVIVAL_MISSED+=("cron: no tick.sh line left in the box's crontab $when, where it carried '$INSTALL_SURVIVAL_CRON_PRE' before the removal")
    elif [ "$INSTALL_SURVIVAL_CRON" != "$INSTALL_SURVIVAL_CRON_PRE" ]; then
      INSTALL_SURVIVAL_CRON_SEEN=missed
      INSTALL_SURVIVAL_MISSED+=("cron: read '$INSTALL_SURVIVAL_CRON' in the box's crontab $when, where it carried '$INSTALL_SURVIVAL_CRON_PRE' before the removal")
    fi
  fi
}

# install_survival_check — read the three surfaces again and rule on survival.
# On failure INSTALL_SURVIVAL_DETAIL names every surface that missed and what
# was read for it; the removal's own transcript says nothing about any of them
# and is never the evidence here (#341).
install_survival_check() {
  local budget=0 waited=ok read_as
  INSTALL_SURVIVAL_MISSED=()
  INSTALL_SURVIVAL_ENGINE_SEEN=ok
  INSTALL_SURVIVAL_CRON_SEEN=ok
  INSTALL_SURVIVAL_TICK=""
  INSTALL_SURVIVAL_TICK_POST=""
  INSTALL_SURVIVAL_DETAIL=""

  # First read of all, before engine and cron: this is the baseline the wait
  # excludes, so the narrower the window between the removal
  # returning and this read, the less of the uninstall it can swallow.
  INSTALL_SURVIVAL_TICK_POST="$(install_survival_read_tick)"

  install_survival_diff_engine_cron "after the removal"

  budget="$(install_survival_budget "$INSTALL_SURVIVAL_CRON_PRE")"
  if [ -z "$INSTALL_SURVIVAL_CRON" ]; then
    # Not waited for, and said so: with the line gone no boundary can strike,
    # so a ${budget}s wait would only relabel the cron failure as a tick one.
    INSTALL_SURVIVAL_MISSED+=("tick: not waited for, the box's schedule being gone, so no boundary can strike")
  else
    install_survival_wait_for_tick "$budget" "$INSTALL_SURVIVAL_TICK_POST" || waited=no
    # Both outcomes re-read engine and cron: a surviving box that lost one of
    # them inside the wait window did not survive, and on a failed wait the
    # second read is often the reason the tick never came.
    install_survival_diff_engine_cron "after the ${budget}s tick wait"
    if [ "$waited" = no ]; then
      read_as="read '$INSTALL_SURVIVAL_TICK'"
      [ -n "$INSTALL_SURVIVAL_TICK" ] || read_as="read nothing"
      if [ -n "$INSTALL_SURVIVAL_TICK_PRE" ]; then
        INSTALL_SURVIVAL_MISSED+=("tick: $read_as at ~/duty/duty.log through the ${budget}s after the removal, where the box arrived with '$INSTALL_SURVIVAL_TICK_PRE' and the removal completed with '$INSTALL_SURVIVAL_TICK_POST' — one schedule period plus grace, and no boundary struck after the removal itself")
      elif [ -n "$INSTALL_SURVIVAL_TICK_POST" ]; then
        INSTALL_SURVIVAL_MISSED+=("tick: $read_as at ~/duty/duty.log through the ${budget}s after the removal, where the removal completed with '$INSTALL_SURVIVAL_TICK_POST' already there — one schedule period plus grace, and no boundary struck after the removal itself")
      else
        INSTALL_SURVIVAL_MISSED+=("tick: $read_as at ~/duty/duty.log through the ${budget}s after the removal — one schedule period plus grace, the box having arrived with no duty.log")
      fi
    fi
  fi

  if [ "${#INSTALL_SURVIVAL_MISSED[@]}" -gt 0 ]; then
    INSTALL_SURVIVAL_DETAIL="$(printf '%s; ' "${INSTALL_SURVIVAL_MISSED[@]}")"
    INSTALL_SURVIVAL_DETAIL="${INSTALL_SURVIVAL_DETAIL%; }"
    return 1
  fi
  return 0
}
