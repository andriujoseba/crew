#!/usr/bin/env bash
# install-survival.sh — step 9's engine/cron/tick survival predicate for
# drill/install-drill.sh. The caller supplies bx(); keeping the predicate here
# makes both of its paths fixture-testable without a box, the way
# rehearsal-safety.sh does for the isolation interlocks.
#
# Step 9 proves the engine outlives its console. Engine and cron are diffed
# across the removal in every case. The TICK leg cannot be: a box hired
# seconds earlier has no ~/duty/duty.log at all — the first line is written at
# the first cron boundary — so a history diff there asserts history the box
# cannot have and reds on a box whose survival is not in doubt. Observed live
# on crew-drill-011, 2026-08-03: the drill read an empty tail and redded, and
# the box's first tick fired 14 seconds later, after the console was gone
# (#341).
#
# So the leg splits by what the box has, and the fresh side is the stronger
# assertion of the two: not "the last line I saw is still there" but "the
# engine wrote a new one, with its console removed".

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
# disturb, and choose the tick leg's form from what the box actually has.
# shellcheck disable=SC2034  # PATH_LABEL is read by the caller's pass line
install_survival_before() {
  INSTALL_SURVIVAL_ENGINE_PRE="$(install_survival_read_engine)"
  INSTALL_SURVIVAL_CRON_PRE="$(install_survival_read_cron)"
  INSTALL_SURVIVAL_TICK_PRE="$(install_survival_read_tick)"
  if [ -n "$INSTALL_SURVIVAL_TICK_PRE" ]; then
    INSTALL_SURVIVAL_PATH=history
    INSTALL_SURVIVAL_PATH_LABEL="history diff — the box arrived with tick history"
  else
    INSTALL_SURVIVAL_PATH=fresh
    INSTALL_SURVIVAL_PATH_LABEL="post-removal tick wait — the box had no duty.log before the removal"
  fi
}

# install_survival_wait_for_tick BUDGET — poll duty.log until a line appears or
# the budget runs out. The wait IS the assertion here: a diff says a line
# written before the removal is still there, this says the engine wrote one
# after it.
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    [ -z "$INSTALL_SURVIVAL_TICK" ] || return 0
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}

# install_survival_check — read the three surfaces again and rule on survival.
# On failure INSTALL_SURVIVAL_DETAIL names every surface that missed and what
# was read for it; the removal's own transcript says nothing about any of them
# and is never the evidence here (#341).
install_survival_check() {
  local budget=0
  local -a missed=()
  INSTALL_SURVIVAL_ENGINE="$(install_survival_read_engine)"
  INSTALL_SURVIVAL_CRON="$(install_survival_read_cron)"
  INSTALL_SURVIVAL_TICK=""
  INSTALL_SURVIVAL_DETAIL=""

  if [ -z "$INSTALL_SURVIVAL_ENGINE" ]; then
    missed+=("engine: read nothing at ~/duty/VERSION, where the box carried '$INSTALL_SURVIVAL_ENGINE_PRE' before the removal")
  elif [ "$INSTALL_SURVIVAL_ENGINE" != "$INSTALL_SURVIVAL_ENGINE_PRE" ]; then
    missed+=("engine: read '$INSTALL_SURVIVAL_ENGINE' at ~/duty/VERSION, where the box carried '$INSTALL_SURVIVAL_ENGINE_PRE' before the removal")
  fi

  if [ -z "$INSTALL_SURVIVAL_CRON" ]; then
    missed+=("cron: no tick.sh line left in the box's crontab, where it carried '$INSTALL_SURVIVAL_CRON_PRE' before the removal")
  elif [ "$INSTALL_SURVIVAL_CRON" != "$INSTALL_SURVIVAL_CRON_PRE" ]; then
    missed+=("cron: read '$INSTALL_SURVIVAL_CRON' in the box's crontab, where it carried '$INSTALL_SURVIVAL_CRON_PRE' before the removal")
  fi

  if [ "$INSTALL_SURVIVAL_PATH" = history ]; then
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    if [ -z "$INSTALL_SURVIVAL_TICK" ]; then
      missed+=("tick: read nothing at ~/duty/duty.log, where the box's last line was '$INSTALL_SURVIVAL_TICK_PRE' before the removal")
    elif [ "$INSTALL_SURVIVAL_TICK" != "$INSTALL_SURVIVAL_TICK_PRE" ]; then
      missed+=("tick: read '$INSTALL_SURVIVAL_TICK' at ~/duty/duty.log, where the box's last line was '$INSTALL_SURVIVAL_TICK_PRE' before the removal")
    fi
  else
    budget="$(install_survival_budget "$INSTALL_SURVIVAL_CRON_PRE")"
    if [ -z "$INSTALL_SURVIVAL_CRON" ]; then
      # Not waited for, and said so: with the line gone no boundary can strike,
      # so a ${budget}s wait would only relabel the cron failure as a tick one.
      missed+=("tick: not waited for, the box's schedule being gone, so no boundary can strike — and it had no duty.log to diff")
    elif ! install_survival_wait_for_tick "$budget"; then
      missed+=("tick: read nothing at ~/duty/duty.log through the ${budget}s after the removal — one schedule period plus grace, the box having arrived with no duty.log to diff")
    fi
  fi

  if [ "${#missed[@]}" -gt 0 ]; then
    INSTALL_SURVIVAL_DETAIL="$(printf '%s; ' "${missed[@]}")"
    INSTALL_SURVIVAL_DETAIL="${INSTALL_SURVIVAL_DETAIL%; }"
    return 1
  fi
  return 0
}
