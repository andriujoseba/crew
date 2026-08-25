# common/breaker.sh — _session_terminal_state, _session_terminal_gate, _session_terminal_record,
# session_terminal — the terminal-failure classifier and the per-lane breaker
# it feeds. Separate from session: classifying a failure is not dispatching.
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
  threshold="${SESSION_TERMINAL_THRESHOLD:-3}"
  case "$threshold" in ''|*[!0-9]*|0) threshold=3 ;; esac
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
