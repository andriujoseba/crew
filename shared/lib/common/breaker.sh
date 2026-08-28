# common/breaker.sh — the per-lane dispatch breakers and what feeds them.
#
# TWO reasons stop a lane, and they answer different questions:
#   - TERMINAL (_session_terminal_*, session_terminal) — the vendor is dead.
#     Consecutive terminal failures, cleared by a probe.
#   - BUDGET (_session_budget_*) — the lane has spent enough. Volume in a
#     rolling window, cleared by the window rolling (#464).
# They share the skip, the log-line shape, the per-kind state file convention
# and the alert channel, which is D3 of #464: the budget invents no second
# mechanism, it supplies a second reason to pull the one that exists.
#
# Both live here rather than in common/session.sh because deciding that a lane
# is closed is not dispatching — the same split that put the terminal
# classifier here. Neither is a new module, so #507's one-suite-per-module
# mirror is unchanged: shared/test/common/breaker.sh covers both.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # RUN_SESSION_RC/RUN_SESSION_LOG are run_session's
# out-of-band result, read by the caller (duty-triage.sh's ledger commits)

# _session_terminal_state KIND — one state file per dispatch lane. Keeping the
# kind in the filename is what lets a dead review credential stop review work
# without silencing an unrelated attention, build, or triage lane.
_session_terminal_state() {
  local kind="${1//[^[:alnum:]_-]/_}"
  printf '%s/.session-terminal.%s' "$DUTY_DIR" "$kind"
}

# _session_terminal_gate KIND KEY — refuse an open lane before the CLI starts.
# A later duty tick gets one cheap vendor probe: success clears the breaker and
# dispatch resumes immediately; failure keeps every remaining item in that tick
# suppressed. DUTY_TICK_ID is set by duty.sh, with $$ as a test/direct-call
# fallback so repeated run_session calls in one process still form one tick.
_session_terminal_gate() {
  local kind="$1" key="$2" state count status last_tick tick tmp
  state="$(_session_terminal_state "$kind")"
  [ -s "$state" ] || return 0
  IFS=$'\t' read -r count status last_tick <"$state" || return 0
  [ "$status" = tripped ] || return 0
  tick="${DUTY_TICK_ID:-$$}"
  if [ "$last_tick" != "$tick" ]; then
    if bot_cli_probe; then
      rm -f "$state"
      log "session breaker: kind=$kind recovered; dispatch resumed"
      alert "✅ $(hostname): $kind session dispatch resumed after the vendor probe succeeded"
      return 0
    fi
    tmp="$state.tmp.$$"
    printf '%s\ttripped\t%s\n' "$count" "$tick" >"$tmp"
    mv -f "$tmp" "$state"
  fi
  log "SESSION SKIP kind=$kind key=$key reason=terminal-breaker count=$count"
  RUN_SESSION_RC=75
  RUN_SESSION_LOG=""
  return 1
}

# _session_terminal_threshold — resolve the optional operator override, with
# the declared table as the only shipped default.
_session_terminal_threshold() {
  local threshold="${SESSION_TERMINAL_THRESHOLD:-}"
  case "$threshold" in
    ''|*[!0-9]*|0) threshold="$(operating_limit session_terminal_failures)" ;;
  esac
  printf '%s' "$threshold"
}

# _session_terminal_record KIND TERMINAL ACTED LOG — count consecutive terminal
# dispatches and alert exactly once, on the transition to the open breaker.
# Any success, timeout, transient failure, or unclassified failure resets the
# count: absent/uncertain hooks are deliberately fail-safe and keep working.
_session_terminal_record() {
  local kind="$1" terminal="$2" acted="$3" slog="$4"
  local state count=0 status=closed last_tick="" tick tmp threshold
  state="$(_session_terminal_state "$kind")"
  if [ "$terminal" != yes ]; then
    rm -f "$state"
    return 0
  fi
  if [ -s "$state" ]; then
    IFS=$'\t' read -r count status last_tick <"$state" || count=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  threshold="$(_session_terminal_threshold)"
  tick="${DUTY_TICK_ID:-$$}"
  status=closed
  [ "$count" -lt "$threshold" ] || status=tripped
  tmp="$state.tmp.$$"
  printf '%s\t%s\t%s\n' "$count" "$status" "$tick" >"$tmp"
  mv -f "$tmp" "$state"
  if [ "$status" = tripped ]; then
    warn "session breaker: kind=$kind tripped after $count consecutive terminal failures; log=$slog"
    alert "🚨 $(hostname): $kind session dispatch stopped after $count terminal failures (acted=$acted) — $slog"
  fi
}

session_terminal() {
  local rc
  declare -F bot_session_terminal >/dev/null 2>&1 || return 1
  bot_session_terminal "$1" && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
}

# --- the session budget (#464) --------------------------------------------
#
# The engine had no idea what it spent and nothing stopped it: 4150 sessions
# and 224 hours of model time from one box, ended by the operator watching a
# quota meter on a Monday. This is the bound, and it is a property of the
# ENGINE rather than of any duty — the gate lives in run_session and nowhere
# else (D2), so no lib/duty-*.sh learns the word "budget".
#
# Counted in BOTH sessions and session-minutes, per kind, per rolling window
# (D1): 2399 mentions at 1.57 minutes and a handful of hour-long builds are
# different failure shapes, and a single metric hides one of them. Rolling
# rather than calendar so a Monday reset cannot be gamed by a Sunday night.
#
# Default OFF (D5). crew ships the mechanism; the operator sets the numbers,
# because a bound nobody chose is a bound that stops a fleet at 3am for a
# reason nobody wrote down.

# The window default. It is here and not only in the conf for the reason the
# reaper's three values are mirrored in duty-reaper.sh: a conf that predates
# this must degrade, never abort the tick under `set -u`. A day is the unit
# the incident was measured in and the unit a quota renews in.
SESSION_BUDGET_WINDOW_DEFAULT=86400
# D6's "tell me before the ceiling, not only at it", as a percentage.
SESSION_BUDGET_ALERT_PCT_DEFAULT=80
# The dispatch lanes crew ships, for the REPORT alone. The GATE never reads
# this list: it resolves BUDGET_*_<KIND> from the kind it was handed, so a lane
# an operator names in their own conf is enforced whether or not it appears
# here, and appears in the report as soon as it has a counter.
#
# It exists because a conf variable name cannot be folded back into a kind:
# `ci-red` folds to CI_RED, and CI_RED un-folds to `ci_red`, which is a lane
# this engine never dispatches. shared/test/common/breaker.sh pins the list
# against both places it could drift from — the BUDGET_SESSIONS_* in
# shared/conf/ and the run_session call sites in shared/lib/duty-*.sh — so a
# lane added without its name here is a red test rather than a silent hole in
# `crew status`.
SESSION_BUDGET_KINDS="attention build ci-red hygiene mention rebase resume review triage"

# _session_budget_state KIND — one state file per dispatch lane, beside the
# terminal breaker's and sanitized the same way, for the same reason: an
# exhausted hygiene budget must not silence review.
_session_budget_state() {
  local kind="${1//[^[:alnum:]_-]/_}"
  printf '%s/.session-budget.%s' "$DUTY_DIR" "$kind"
}

# _session_budget_limits KIND — resolve this lane's ceilings from the role
# conf into _BUDGET_*, and say whether the budget is on at all.
#
# Returns 1 when OFF, and the caller then does NOTHING: no state read, no
# state write, no log line. That is what makes "budgets off is byte-identical
# to today" an assertable property rather than a claim.
_session_budget_limits() {
  local kind="$1" suffix var
  suffix="${kind//[^[:alnum:]]/_}"
  suffix="${suffix^^}"
  for var in SESSIONS MINUTES WINDOW; do
    local name="BUDGET_${var}_${suffix}" value
    value="${!name:-}"
    case "$value" in ''|*[!0-9]*) value=0 ;; esac
    printf -v "_BUDGET_$var" '%s' "$value"
  done
  # A window of 0 means "unset", not "no window": fall back to the fleet
  # default so a ceiling set without one is still a ceiling.
  if [ "$_BUDGET_WINDOW" -le 0 ]; then
    _BUDGET_WINDOW="${BUDGET_WINDOW:-$SESSION_BUDGET_WINDOW_DEFAULT}"
    case "$_BUDGET_WINDOW" in ''|*[!0-9]*|0) _BUDGET_WINDOW=$SESSION_BUDGET_WINDOW_DEFAULT ;; esac
  fi
  # The two ceilings are independent (D1): either one alone arms the lane.
  [ "$_BUDGET_SESSIONS" -gt 0 ] || [ "$_BUDGET_MINUTES" -gt 0 ]
}

# _session_budget_ceiling VALUE — a ceiling as a human should read it: the
# number when it is armed, `-` when it is not.
#
# A lane may run on ONE metric alone (D1), and `0/0 min` in an alert reads as
# an exhausted minute ceiling to an operator who never set one. Every place
# that prints a pair — the two alerts, the SESSION SKIP line and the report —
# goes through here, so the four cannot drift apart.
_session_budget_ceiling() {
  if [ "${1:-0}" -gt 0 ]; then printf '%s' "$1"; else printf -- '-'; fi
}

# _session_budget_load KIND — read the lane's counter, drop everything older
# than the window, and leave the survivors in _BUDGET_KEPT with their totals.
#
# Returns 1 on unreadable OR malformed, which is the D4 fail-closed trigger.
# Every other gate in this engine fails OPEN and says so; this one is the
# opposite ON PURPOSE. An unreadable counter means the engine does not know
# what it has spent, and dispatching on an unknown balance is precisely the
# incident #464 exists to prevent. Do not "fix" this into consistency with
# its neighbours.
_session_budget_load() {
  local kind="$1" state now cutoff parsed summary
  state="$(_session_budget_state "$kind")"
  now="$(date -u +%s)"
  cutoff=$((now - _BUDGET_WINDOW))
  _BUDGET_COUNT=0 _BUDGET_SECONDS=0 _BUDGET_WARNED=0 _BUDGET_TRIPPED=0
  _BUDGET_OLDEST=0 _BUDGET_KEPT="" _BUDGET_NOW="$now"
  # No file yet is a fresh lane, not a fault: nothing spent, nothing to read.
  [ -e "$state" ] || return 0
  [ -r "$state" ] || return 1
  # An EXISTING but empty file is not a fresh lane. The write is atomic —
  # tmp+mv — so this engine cannot have produced one, which makes an empty
  # counter something else's truncation and a balance nobody can read. It
  # fails closed with the rest of D4 rather than repairing itself silently
  # through the next dispatch.
  [ -s "$state" ] || return 1
  # One awk, no pipe: an `awk … | head` here would be the SIGPIPE-under-
  # pipefail shape the suite guards against (#449).
  parsed="$(awk -F'\t' -v cutoff="$cutoff" '
    NR == 1 {
      if ($1 != "budget" || NF != 6) { bad = 1; exit }
      # The window and the two ceilings are validated even though the CONF is
      # what this engine enforces: a header carrying anything but digits was
      # not written by _session_budget_save, and a counter this engine did not
      # write is a balance it cannot vouch for.
      if ($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) { bad = 1; exit }
      if ($5 !~ /^[01]$/ || $6 !~ /^[01]$/) { bad = 1; exit }
      warned = $5; tripped = $6
      next
    }
    NF == 0 { next }
    {
      if (NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/) { bad = 1; exit }
      if ($1 + 0 < cutoff) next
      n++; s += $2
      if (oldest == 0 || $1 + 0 < oldest) oldest = $1 + 0
      kept = kept $1 "\t" $2 "\n"
    }
    END {
      if (bad) exit 1
      printf "%d\t%d\t%d\t%d\t%d\n", n, s, warned, tripped, oldest
      printf "%s", kept
    }' "$state")" || return 1
  summary="${parsed%%$'\n'*}"
  case "$parsed" in
    *$'\n'*) _BUDGET_KEPT="${parsed#*$'\n'}"$'\n' ;;
    *) _BUDGET_KEPT="" ;;
  esac
  IFS=$'\t' read -r _BUDGET_COUNT _BUDGET_SECONDS _BUDGET_WARNED _BUDGET_TRIPPED _BUDGET_OLDEST \
    <<<"$summary" || return 1
}

# _session_budget_save KIND — atomic rewrite, same tmp+mv as the terminal
# breaker's. Returns 1 if the state cannot be written, which is the OTHER
# half of D4: an unwritable duty directory means the next tick would read a
# stale balance and dispatch on it.
#
# The header carries the resolved window and ceilings, not only the latches,
# so the file is SELF-DESCRIBING: `crew status` (D7) reads a balance without
# resolving a role conf on the operator's host.
_session_budget_save() {
  local kind="$1" state tmp
  state="$(_session_budget_state "$kind")"
  tmp="$state.tmp.$$"
  {
    printf 'budget\t%s\t%s\t%s\t%s\t%s\n' \
      "$_BUDGET_WINDOW" "$_BUDGET_SESSIONS" "$_BUDGET_MINUTES" \
      "$_BUDGET_WARNED" "$_BUDGET_TRIPPED"
    printf '%s' "$_BUDGET_KEPT"
  # 2>/dev/null FIRST: redirections apply left to right, so a $tmp that
  # cannot be opened (an unwritable or non-directory DUTY_DIR, which is D4's
  # own case) must find stderr already silenced, or the shell reports it on
  # the duty log's stderr and the fail-closed path grows a stray line.
  } 2>/dev/null >"$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$state" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# _session_budget_refuse KIND KEY REASON DETAIL — the D4 branch's own skip.
# Same line shape and same RUN_SESSION_RC as the terminal breaker's refusal,
# so a reader of duty.log needs no new vocabulary.
_session_budget_refuse() {
  local kind="$1" key="$2" reason="$3" detail="$4"
  warn "session budget: kind=$kind $detail — dispatch refused (fail-closed)"
  alert "🚨 $(hostname): $kind session dispatch refused — $detail, so the engine cannot know what it has spent"
  log "SESSION SKIP kind=$kind key=$key reason=$reason"
  RUN_SESSION_RC=75
  RUN_SESSION_LOG=""
}

# _session_budget_gate KIND KEY — refuse a lane that has spent its window.
#
# Called AHEAD of _session_terminal_gate in run_session, deliberately: the
# terminal gate's recovery probe costs a vendor call, and an exhausted budget
# must not be able to spend one.
_session_budget_gate() {
  local kind="$1" key="$2" over=no over_alert=no spent_min ceiling_min ceiling_sessions
  _session_budget_limits "$kind" || return 0
  if ! _session_budget_load "$kind"; then
    _session_budget_refuse "$kind" "$key" budget-unreadable \
      "the rolling counter is unreadable or malformed"
    return 1
  fi
  if [ "$_BUDGET_SESSIONS" -gt 0 ] && [ "$_BUDGET_COUNT" -ge "$_BUDGET_SESSIONS" ]; then
    over=sessions
  elif [ "$_BUDGET_MINUTES" -gt 0 ] && [ "$_BUDGET_SECONDS" -ge $((_BUDGET_MINUTES * 60)) ]; then
    over=minutes
  fi
  # The latch is what makes the trip alert once per crossing rather than once
  # per skipped dispatch. A rolling window has no reset instant to hang "once
  # per window" on, so the crossing is the event: set on the way over, and
  # cleared here the moment the oldest entries age out far enough to bring the
  # lane back under. That is the same "alert exactly once, on the transition"
  # rule the terminal breaker uses.
  if [ "$over" != no ]; then
    if [ "$_BUDGET_TRIPPED" = 1 ]; then over_alert=no; else over_alert=yes; fi
    _BUDGET_TRIPPED=1
  else
    over_alert=no
    _BUDGET_TRIPPED=0
  fi
  # Saved BEFORE the over-check and on every armed dispatch: this one write is
  # the prune, the latch commit AND the writability probe, so an unwritable
  # duty directory fails closed whether or not the lane is over budget.
  if ! _session_budget_save "$kind"; then
    _session_budget_refuse "$kind" "$key" budget-unwritable \
      "the rolling counter cannot be written"
    return 1
  fi
  [ "$over" != no ] || return 0
  spent_min=$((_BUDGET_SECONDS / 60))
  # `-`, not the raw 0, for a ceiling nobody armed: this lane may be running on
  # one metric alone, and a fabricated second number reads as a bound.
  ceiling_min="$(_session_budget_ceiling "$_BUDGET_MINUTES")"
  ceiling_sessions="$(_session_budget_ceiling "$_BUDGET_SESSIONS")"
  if [ "$over_alert" = yes ]; then
    warn "session budget: kind=$kind reached its $over ceiling; dispatch stopped until the window rolls"
    alert "🚨 $(hostname): $kind session dispatch stopped — $over budget reached (${_BUDGET_COUNT}/${ceiling_sessions} sessions, ${spent_min}/${ceiling_min} min in ${_BUDGET_WINDOW}s)"
  fi
  log "SESSION SKIP kind=$kind key=$key reason=budget over=$over sessions=$_BUDGET_COUNT/$ceiling_sessions minutes=$spent_min/$ceiling_min window=${_BUDGET_WINDOW}s"
  RUN_SESSION_RC=75
  RUN_SESSION_LOG=""
  return 1
}

# _session_budget_near COUNT SECONDS PCT — which armed ceiling this balance is
# past PCT of, or `no`. One function because D6's alert asks the question
# TWICE of the same lane: once of the pruned balance the roll left behind, to
# decide whether the latch still stands, and once of the balance this session
# creates, to decide whether it has just been crossed.
_session_budget_near() {
  local count="$1" seconds="$2" pct="$3"
  if [ "$_BUDGET_SESSIONS" -gt 0 ] && [ $((count * 100)) -ge $((_BUDGET_SESSIONS * pct)) ]; then
    printf sessions
  elif [ "$_BUDGET_MINUTES" -gt 0 ] && [ $((seconds * 100)) -ge $((_BUDGET_MINUTES * 60 * pct)) ]; then
    printf minutes
  else
    printf no
  fi
}

# _session_budget_record KIND DURATION — one entry per completed session,
# written alongside the SESSION END line that carries the same duration.
#
# This one does NOT fail closed. The session already ran and already spent;
# refusing after the fact protects nothing, and the next _session_budget_gate
# is where an unreadable counter stops the lane.
_session_budget_record() {
  local kind="$1" dur="$2" pct near=no spent_min
  case "$dur" in ''|*[!0-9]*) dur=0 ;; esac
  _session_budget_limits "$kind" || return 0
  if ! _session_budget_load "$kind"; then
    warn "session budget: kind=$kind counter unreadable at record time; the next dispatch fails closed"
    return 0
  fi
  pct="${SESSION_BUDGET_ALERT_PCT:-$SESSION_BUDGET_ALERT_PCT_DEFAULT}"
  case "$pct" in ''|*[!0-9]*|0) pct=$SESSION_BUDGET_ALERT_PCT_DEFAULT ;; esac
  # THE LATCH RE-ARMS FROM THE PRUNED, PRE-SESSION BALANCE, and it has to be
  # this balance rather than the one below. A rolling window carries a lane
  # back under the threshold with no dispatch at all — the oldest entries age
  # out — and the next session then crosses the line again, which is a NEW
  # crossing owed its own alert. Clearing the latch on a POST-session balance
  # under the line, as this did, asks a question a latched lane crossing back
  # over never answers `no` to: the lane would fall under 80%, climb over it,
  # and never say so again.
  if [ "$(_session_budget_near "$_BUDGET_COUNT" "$_BUDGET_SECONDS" "$pct")" = no ]; then
    _BUDGET_WARNED=0
  fi
  _BUDGET_KEPT="${_BUDGET_KEPT}${_BUDGET_NOW}"$'\t'"${dur}"$'\n'
  _BUDGET_COUNT=$((_BUDGET_COUNT + 1))
  _BUDGET_SECONDS=$((_BUDGET_SECONDS + dur))
  # This session's own balance decides the crossing. It can only be at or above
  # the pre-session one, so the re-arm above is the only place the latch is
  # ever cleared.
  near="$(_session_budget_near "$_BUDGET_COUNT" "$_BUDGET_SECONDS" "$pct")"
  spent_min=$((_BUDGET_SECONDS / 60))
  if [ "$near" != no ] && [ "$_BUDGET_WARNED" != 1 ]; then
    _BUDGET_WARNED=1
    warn "session budget: kind=$kind past ${pct}% of its $near ceiling"
    alert "⚠️ $(hostname): $kind session budget past ${pct}% — ${_BUDGET_COUNT}/$(_session_budget_ceiling "$_BUDGET_SESSIONS") sessions, ${spent_min}/$(_session_budget_ceiling "$_BUDGET_MINUTES") min in ${_BUDGET_WINDOW}s"
  fi
  _session_budget_save "$kind" \
    || warn "session budget: kind=$kind could not record this session; the next dispatch fails closed"
}

# _session_budget_human SECONDS — a duration an operator reads at a glance.
# `now` for a window that has already passed, so the "ages out" clause reads as
# a moment rather than as a zero.
_session_budget_human() {
  local s="${1:-0}" d h m
  if [ "$s" -le 0 ]; then printf now; return 0; fi
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%sd%sh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%sh%sm' "$h" "$m"
  else printf '%sm' "$m"; fi
}

# _session_budget_lanes — every kind that could own a row, one per line, sorted
# and de-duplicated: the lanes crew ships, UNIONED with every lane a state file
# names. The union is what carries a kind an operator configured without crew
# knowing about it; the sort is so the report's order is a property of the
# report rather than an accident of a glob.
#
# Naming a lane here is not what arms it. Every candidate is put to
# _session_budget_limits, and the conf decides.
_session_budget_lanes() {
  local state kind
  {
    for state in "$DUTY_DIR"/.session-budget.*; do
      [ -f "$state" ] || continue
      case "$state" in *.tmp.*) continue ;; esac
      kind="${state##*/.session-budget.}"
      printf '%s\n' "$kind"
    done
    # shellcheck disable=SC2086  # the lane list is a word list by design
    printf '%s\n' $SESSION_BUDGET_KINDS
  } | sort -u
}

# session_budget_report — one row per CONFIGURED lane (D7), whether or not it
# has ever dispatched.
#
# CONFIGURED means the conf says so, and nothing else. An earlier cut of this
# read the ceilings out of the state file, which the gate writes, and so
# answered "which lanes have dispatched since being armed" instead: a lane
# armed an hour ago printed nothing until its first dispatch, a raised ceiling
# printed the superseded number, and — worst — a lane whose ceilings had been
# REMOVED kept printing a bound nobody was enforcing. The conf is where the
# gate reads its ceilings, so it is where the report reads them, and the two
# cannot now disagree about what is armed or what the bound is.
#
# The state file keeps exactly the half it owns: the spend. It is read through
# _session_budget_load, the gate's own reader, so "unreadable" means here
# precisely what it means there — including the window it prunes by, which
# comes from the conf too.
#
# The ROW is rendered on the BOX and `crew status` prints it verbatim, the same
# thing it already does with the duty.log tail. The conf that decides all of
# this lives on the box; a renderer on the operator's host would have to
# resolve a role conf it does not have, and no offline suite could reach it,
# while shared/test/common/breaker.sh drives this one beside the gate whose
# balance it prints.
#
# Prints NOTHING when no lane is configured, which is what lets `crew status`
# omit the section entirely rather than print an empty heading — and a lane
# that is off prints nothing even when a stale counter for it survives, because
# a row for an unenforced ceiling is the one statement this view must not make.
#
# Deliberately not telemetry (#327), which owns per-session accounting,
# outcomes and vendor spend: this is the balance the gate is already keeping,
# displayed, and nothing else.
session_budget_report() {
  local kind rolls ages
  while read -r kind; do
    [ -n "$kind" ] || continue
    # The conf, not the filesystem, decides whether this lane has a row.
    _session_budget_limits "$kind" || continue
    if ! _session_budget_load "$kind"; then
      # The one state that must not read as a balance: the gate is refusing
      # every dispatch on this lane right now, and saying so here is what
      # connects a silent box to its cause.
      printf '  %-10s unreadable — dispatch is refused until it is repaired or removed\n' "$kind"
      continue
    fi
    # "ages out" is when the OLDEST surviving entry drops out — the moment this
    # lane next gains headroom. A lane with nothing in the window has no such
    # moment, and says so rather than reporting one that has already passed.
    if [ "$_BUDGET_OLDEST" -gt 0 ]; then
      rolls=$((_BUDGET_OLDEST + _BUDGET_WINDOW - _BUDGET_NOW))
      [ "$rolls" -ge 0 ] || rolls=0
      ages="oldest ages out $(_session_budget_human "$rolls")"
    else
      ages="nothing spent yet"
    fi
    printf '  %-10s %s/%s sessions, %s/%s min spent in %s (%s)\n' \
      "$kind" "$_BUDGET_COUNT" "$(_session_budget_ceiling "$_BUDGET_SESSIONS")" \
      "$((_BUDGET_SECONDS / 60))" "$(_session_budget_ceiling "$_BUDGET_MINUTES")" \
      "$(_session_budget_human "$_BUDGET_WINDOW")" "$ages"
  # A here-string and not a pipe: the loop must run in THIS shell (it calls the
  # _BUDGET_* readers), and `_session_budget_lanes | while` under pipefail is
  # the shape #449 exists about.
  done <<<"$(_session_budget_lanes)"
}
