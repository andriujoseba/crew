#!/usr/bin/env bash
# shared/test/common/breaker.sh — standalone suite for shared/lib/common/breaker.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"

# --- terminal session classification and per-kind breaker (#388) ----------
TERM_LOG="$TMP/session-terminal.log"
printf '%s\n' "Server: Error code: 403 - {'error': {'message': \"You've reached your usage limit for this billing cycle.\", 'type': 'access_terminated_error'}}" >"$TERM_LOG"

kimi_session_classification() (
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  printf "provider error: {'type': 'access_terminated_error'}\n" >"$TERM_LOG"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  printf 'provider error: access_terminated_error; reached your usage limit\n' >"$TERM_LOG"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  if bot_session_terminal "$SHARED/conf/agents/kimi.conf"; then printf terminal; else printf transient; fi
  printf '|'
  printf 'Used Shell (gh api repos/o/r/pulls/1/reviews)\n' >"$TERM_LOG.acted"
  if bot_session_acted "$TERM_LOG.acted"; then printf yes; else printf no; fi
  printf '|'
  printf 'Final answer only\n' >"$TERM_LOG.acted"
  if bot_session_acted "$TERM_LOG.acted"; then printf yes; else printf no; fi
)
t kimi-session-hooks 'terminal|terminal|transient|transient|yes|no' \
  "$(kimi_session_classification)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
kimi_quoted_terminal_then_transient() (
  local bdir="$TMP/terminal-breaker-kimi-quoted" i state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  BOT_CLI_CMD=(bash -c '
    printf x >>"$BREAKER_CALLS"
    printf "%s\n" "Used Shell (gh issue view 388)"
    printf "%s\n" "Server: Error code: 403 - {'\''error'\'': {'\''message'\'': \"You'\''ve reached your usage limit for this billing cycle.\", '\''type'\'': '\''access_terminated_error'\''}}"
    printf "%s\n" "transient network failure: dial tcp i/o timeout"
    exit 1
  ')
  bot_cli_probe() { printf probe >>"$bdir/probes"; return 0; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 16); do
    run_session review fixture/repo "$bdir/work" 5 prompt
  done >"$bdir/output"
  state="$(_session_terminal_state review)"
  printf '%s|%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'outcome=FAILED' "$bdir/output" || true)" \
    "$([ -e "$state" ] && echo tripped || echo clear)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)" \
    "$([ -e "$bdir/probes" ] && wc -c <"$bdir/probes" || echo 0)"
)
t kimi-quoted-terminal-payload-ending-transient-never-trips '16|16|clear|0|0' \
  "$(kimi_quoted_terminal_then_transient)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_case() ( # terminal_breaker_case terminal|transient|hookless
  local shape="$1" bdir="$TMP/terminal-breaker-$1" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"
  LOG_DIR="$bdir/logs"
  DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"
  : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf "%s\n" "$BREAK_TEXT"; exit 1')
  export BREAK_TEXT=transient-network-failure
  if [ "$shape" = terminal ]; then
    BREAK_TEXT=access_terminated_error
    export BREAK_TEXT
    bot_session_terminal() { grep -q access_terminated_error "$1"; }
  elif [ "$shape" = transient ]; then
    bot_session_terminal() { grep -q access_terminated_error "$1"; }
  else
    unset -f bot_session_terminal
  fi
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 16); do
    run_session review fixture/repo "$bdir/work" 5 prompt
  done >"$bdir/output"
  local alert_count=0
  [ ! -f "$bdir/alerts" ] || alert_count="$(wc -l <"$bdir/alerts")"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$alert_count" \
    "$(grep -c 'outcome=TERMINAL' "$bdir/output" || true)" \
    "$(grep -c 'SESSION SKIP.*terminal-breaker' "$bdir/output" || true)"
)
t terminal-breaker-replays-sixteen-as-three-dispatches '3|1|3|13' \
  "$(terminal_breaker_case terminal)"
t transient-failures-never-trip '16|0|0|0' \
  "$(terminal_breaker_case transient)"
t hookless-failures-remain-transient '16|0|0|0' \
  "$(terminal_breaker_case hookless)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_resets_sequence() (
  local bdir="$TMP/terminal-breaker-reset" state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  BOT_CLI_CMD=(bash -c 'printf "%s\n" "$BREAK_TEXT"; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  alert() { :; }
  export BREAK_TEXT=access_terminated_error
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  BREAK_TEXT=transient-network-failure
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  BREAK_TEXT=access_terminated_error
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  state="$(_session_terminal_state review)"
  if [ -s "$state" ]; then
    IFS=$'\t' read -r count status _ <"$state"
    printf '%s|%s' "$count" "$status"
  else
    printf missing
  fi
)
t terminal-breaker-transient-resets-consecutive-count '2|closed' \
  "$(terminal_breaker_resets_sequence)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_timeout_case() (
  local bdir="$TMP/terminal-breaker-timeout" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  BOT_CLI_CMD=(bash -c 'exit 124')
  bot_session_terminal() { return 0; }
  bot_session_acted() { return 1; }
  alert() { printf alert >>"$bdir/alerts"; }
  for i in $(seq 1 16); do run_session review fixture/repo "$bdir/work" 5 prompt; done >"$bdir/output"
  printf '%s|%s' "$(grep -c 'outcome=TIMEOUT' "$bdir/output")" \
    "$([ -e "$(_session_terminal_state review)" ] && echo tripped || echo clear)"
)
t timeout-failures-never-trip '16|clear' "$(terminal_timeout_case)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_kind_isolation() (
  local bdir="$TMP/terminal-breaker-kind" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  run_session build fixture/repo "$bdir/work" 5 prompt >/dev/null
  printf '%s|%s' "$(wc -c <"$BREAKER_CALLS")" \
    "$([ -e "$(_session_terminal_state review)" ] && echo review-stopped || echo review-open)"
)
t terminal-breaker-is-keyed-by-kind '4|review-stopped' "$(terminal_kind_isolation)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_recovery() (
  local bdir="$TMP/terminal-breaker-recovery" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  DUTY_TICK_ID="tick-2"
  bot_cli_probe() { return 0; }
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  state="$(_session_terminal_state review)"
  printf '%s|%s' "$(wc -c <"$BREAKER_CALLS")" "$([ -e "$state" ] && echo present || echo cleared)"
)
t terminal-breaker-recovers-on-next-tick '4|cleared' "$(terminal_breaker_recovery)"

# --- the session budget (#464) --------------------------------------------
#
# Every case drives the REAL run_session in its own subshell with its own
# DUTY_DIR, because the defect being fixed is that 500 dispatches complete:
# a helper-only test would assert a predicate and never the dispatch it is
# supposed to stop. `wc -c <"$BREAKER_CALLS"` is one byte per CLI launch, the
# same counter the terminal-breaker cases above use.

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_session_ceiling() (
  local bdir="$TMP/budget-sessions" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  # SESSIONS armed alone — the minute ceiling is 0, and the lane must still
  # stop. Half of "the two ceilings are independent".
  BUDGET_SESSIONS_REVIEW=3; BUDGET_MINUTES_REVIEW=0
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf ok; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  # A distinct key per iteration, because run_session names the session log
  # from the timestamp and the key: ten dispatches inside one second under one
  # key would write one file and the log count below would prove nothing.
  for i in $(seq 1 10); do run_session review "fixture/repo$i" "$bdir/work" 5 prompt; done >"$bdir/output"
  # The session-log count is the criterion's "and the absence of a session log
  # file": a return code alone cannot tell a refused dispatch from a silent one.
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'SESSION SKIP.*reason=budget ' "$bdir/output" || true)" \
    "$(find "$bdir/logs" -name '*-review-*.log' | wc -l)" \
    "$(grep -c 'SESSION START' "$bdir/output" || true)"
)
t budget-session-ceiling-stops-dispatch '3|7|3|3' "$(budget_session_ceiling)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_minute_ceiling() (
  local bdir="$TMP/budget-minutes" now
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  # MINUTES armed alone, and the fleet configured no session ceiling at all —
  # the other half of the independence criterion.
  BUDGET_SESSIONS_REVIEW=0; BUDGET_MINUTES_REVIEW=5
  now="$(date -u +%s)"
  # Seeded to exactly five minutes across three in-window sessions. Seeded and
  # not accumulated because accumulating five real minutes costs five real
  # minutes; that the RECORD writes the measured duration is asserted
  # separately, by the case directly below, so the two together cover what one
  # slow test would.
  { printf 'budget\t86400\t0\t5\t0\t0\n'
    printf '%s\t120\n' "$((now - 300))"
    printf '%s\t120\n' "$((now - 200))"
    printf '%s\t60\n'  "$((now - 100))"
  } >"$bdir/.session-budget.review"
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'reason=budget over=minutes' "$bdir/output" || true)" \
    "$(find "$bdir/logs" -name '*-review-*.log' | wc -l)" \
    "$(grep -c 'minutes=5/5' "$bdir/output" || true)"
)
t budget-minute-ceiling-stops-dispatch-alone '0|1|0|1' "$(budget_minute_ceiling)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_duration_agrees_with_log() (
  local bdir="$TMP/budget-duration" end_dur state_dur
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=99; BUDGET_MINUTES_REVIEW=0
  BOT_CLI_CMD=(bash -c 'sleep 1; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  end_dur="$(sed -n 's/.*SESSION END .* dur=\([0-9]*\)s .*/\1/p' "$bdir/output")"
  state_dur="$(awk -F'\t' 'NR > 1 && NF == 2 { print $2 }' "$bdir/.session-budget.review")"
  # The VALUE is not asserted — a one-second sleep lands on 1 or 2 depending on
  # where the second boundary falls, and a suite that pinned it would be the
  # flake. What is asserted is that the counter and the log can never disagree
  # about what a session cost, which is the property the fix claims.
  if [ -n "$end_dur" ] && [ "$end_dur" = "$state_dur" ]; then printf agree; else printf 'DISAGREE(%s/%s)' "$end_dur" "$state_dur"; fi
)
t budget-counter-duration-agrees-with-session-end agree "$(budget_duration_agrees_with_log)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_kind_isolation() (
  local bdir="$TMP/budget-kind" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  # hygiene bounded, triage not configured at all: an implementation that
  # halts every kind when one lane is over budget fails here, which is the
  # test plan's "must fail: a global stop".
  BUDGET_SESSIONS_HYGIENE=1; BUDGET_MINUTES_HYGIENE=0
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2; do run_session hygiene fixture/repo "$bdir/work" 5 prompt; done >"$bdir/output"
  run_session triage fixture/repo "$bdir/work" 5 prompt >>"$bdir/output"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'SESSION SKIP kind=hygiene.*reason=budget ' "$bdir/output" || true)" \
    "$(grep -c 'SESSION SKIP kind=triage' "$bdir/output" || true)" \
    "$([ -e "$bdir/.session-budget.triage" ] && echo triage-counted || echo triage-untouched)"
)
t budget-is-keyed-by-kind '2|1|0|triage-untouched' "$(budget_kind_isolation)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_window_rolls() (
  local bdir="$TMP/budget-roll" now state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=2; BUDGET_MINUTES_REVIEW=0; BUDGET_WINDOW_REVIEW=3600
  now="$(date -u +%s)"
  state="$bdir/.session-budget.review"
  # A lane that WAS over its ceiling of 2 and is latched tripped, with one of
  # its two entries now older than the window. No hand reset and no deletion:
  # the entry ages out and the lane dispatches again.
  { printf 'budget\t3600\t2\t0\t0\t1\n'
    printf '%s\t60\n' "$((now - 7200))"
    printf '%s\t60\n' "$((now - 60))"
  } >"$state"
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  printf '%s|%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'reason=budget' "$bdir/output" || true)" \
    "$([ -f "$state" ] && echo present || echo DELETED)" \
    "$(awk -F'\t' 'NR > 1 && NF == 2' "$state" | wc -l)" \
    "$(awk -F'\t' 'NR == 1 { print $6 }' "$state")"
)
# 1 dispatch, 0 skips, the file kept, the aged entry pruned and the survivor
# joined by this session's own, and the trip latch cleared by the roll.
t budget-window-rolls-without-a-reset '1|0|present|2|0' "$(budget_window_rolls)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_corrupt_fails_closed() ( # budget_corrupt_fails_closed header|entry|latch|numbers|empty
  local bdir="$TMP/budget-corrupt-$1" state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=5; BUDGET_MINUTES_REVIEW=0
  state="$bdir/.session-budget.review"
  case "$1" in
    header) printf 'this is not a budget header\n' >"$state" ;;
    entry)  { printf 'budget\t86400\t5\t0\t0\t0\n'; printf 'not-an-epoch\tnot-a-duration\n'; } >"$state" ;;
    latch)  { printf 'budget\t86400\t5\t0\tyes\t0\n'; } >"$state" ;;
    # A header of the right SHAPE whose numbers are not numbers. It parses as
    # six tab-separated fields and its latches are valid, so only the numeric
    # check stands between it and a dispatch on an unknown balance.
    numbers) printf 'budget\tnot-a-window\tnot-a-ceiling\tnot-a-ceiling\t0\t0\n' >"$state" ;;
    # An existing but EMPTY counter. The save is atomic, so this engine cannot
    # have written one; it is a truncation by something else, and a truncated
    # counter that reads as a fresh lane would silently repair itself through
    # the very dispatch it should be refusing.
    empty)  : >"$state" ;;
  esac
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { printf probe >>"$bdir/probes"; return 0; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'reason=budget-unreadable' "$bdir/output" || true)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)" \
    "$(find "$bdir/logs" -name '*-review-*.log' | wc -l)"
)
# D4's inversion, asserted directly because it is the one a reviewer will
# question: every other gate in this engine fails OPEN. An unreadable counter
# means the engine does not know what it has spent, and dispatching on an
# unknown balance is the incident #464 exists to prevent.
t budget-corrupt-header-fails-closed  '0|1|1|0' "$(budget_corrupt_fails_closed header)"
t budget-corrupt-entry-fails-closed   '0|1|1|0' "$(budget_corrupt_fails_closed entry)"
t budget-corrupt-latch-fails-closed   '0|1|1|0' "$(budget_corrupt_fails_closed latch)"
t budget-corrupt-numbers-fails-closed '0|1|1|0' "$(budget_corrupt_fails_closed numbers)"
t budget-empty-counter-fails-closed   '0|1|1|0' "$(budget_corrupt_fails_closed empty)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_unwritable_fails_closed() (
  local bdir="$TMP/budget-unwritable"
  mkdir -p "$bdir/logs" "$bdir/work"
  # A regular FILE standing where DUTY_DIR should be, so the counter's write
  # fails with ENOTDIR. Deliberately not `chmod 000` on a directory: CI runs
  # unprivileged but a box session can be root, and a permission bit root
  # ignores would make this case pass for the wrong reason.
  : >"$bdir/notadir"
  DUTY_DIR="$bdir/notadir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=5; BUDGET_MINUTES_REVIEW=0
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'reason=budget-unwritable' "$bdir/output" || true)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)" \
    "$(find "$bdir/logs" -name '*-review-*.log' | wc -l)"
)
t budget-unwritable-counter-fails-closed '0|1|1|0' "$(budget_unwritable_fails_closed)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_threshold_alerts_once() (
  local bdir="$TMP/budget-threshold" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=10; BUDGET_MINUTES_REVIEW=0
  SESSION_BUDGET_ALERT_PCT=80
  BOT_CLI_CMD=(bash -c 'exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 14); do run_session review fixture/repo "$bdir/work" 5 prompt; done >"$bdir/output"
  # D6 is "once per window per kind, NOT per session": sessions 8, 9 and 10 are
  # all at or past 80%, and four dispatches are refused after that. One of
  # each alert is the whole assertion — a per-session implementation scores 7.
  printf '%s|%s|%s|%s' \
    "$(grep -c 'session budget: kind=review past 80%' "$bdir/output" || true)" \
    "$(grep -c 'past 80%' "$bdir/alerts" || true)" \
    "$(grep -c 'dispatch stopped' "$bdir/alerts" || true)" \
    "$(grep -c 'reason=budget ' "$bdir/output" || true)"
)
t budget-threshold-alert-fires-once-per-crossing '1|1|1|4' "$(budget_threshold_alerts_once)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_alert_names_the_numbers() (
  local bdir="$TMP/budget-alert-text" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=5; BUDGET_MINUTES_REVIEW=0
  SESSION_BUDGET_ALERT_PCT=80
  BOT_CLI_CMD=(bash -c 'exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in 1 2 3 4; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  # "names the kind, the spend and the ceiling" — the criterion's own words.
  printf '%s|%s|%s' \
    "$(grep -c 'review session budget' "$bdir/alerts" || true)" \
    "$(grep -c '4/5 sessions' "$bdir/alerts" || true)" \
    "$(wc -l <"$bdir/alerts")"
)
t budget-threshold-alert-names-kind-spend-and-ceiling '1|1|1' "$(budget_alert_names_the_numbers)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_threshold_alert_rearms() (
  local bdir="$TMP/budget-threshold-rearm" now state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BUDGET_SESSIONS_REVIEW=10; BUDGET_MINUTES_REVIEW=0
  SESSION_BUDGET_ALERT_PCT=80
  now="$(date -u +%s)"
  state="$bdir/.session-budget.review"
  # A lane that WAS past 80% and is latched warned, whose roll has since taken
  # it back under: three of its ten entries are older than the window, so the
  # pruned balance is 7/10 = 70%. The session below carries it to 8/10, which
  # is a NEW crossing and owed its one alert.
  #
  # This is the case a latch cleared from the POST-session balance can never
  # answer: 8/10 is over the line, so the old code left `warned=1` standing and
  # said nothing, here and for every crossing after it.
  { printf 'budget\t86400\t10\t0\t1\t0\n'
    for i in 1 2 3; do printf '%s\t60\n' "$((now - 90000 - i))"; done
    for i in $(seq 1 7); do printf '%s\t60\n' "$((now - 100 - i))"; done
  } >"$state"
  BOT_CLI_CMD=(bash -c 'exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  printf '%s|%s|%s|%s' \
    "$(grep -c 'past 80%' "$bdir/alerts" 2>/dev/null || true)" \
    "$(grep -c '8/10 sessions' "$bdir/alerts" 2>/dev/null || true)" \
    "$(awk -F'\t' 'NR == 1 { print $5 }' "$state")" \
    "$(awk -F'\t' 'NR > 1 && NF == 2' "$state" | wc -l)"
)
# One alert, naming the balance that crossed, the latch left standing for it,
# and the three aged entries gone.
t budget-threshold-alert-re-arms-after-the-window-rolls '1|1|1|8' \
  "$(budget_threshold_alert_rearms)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_unarmed_ceiling_is_a_dash() (
  local bdir="$TMP/budget-dash" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  # Sessions armed alone: this lane has no minute ceiling at all, and neither
  # the skip line nor the alert may invent one. `0/0 min` reads as an exhausted
  # minute budget to an operator who never set one.
  BUDGET_SESSIONS_REVIEW=1; BUDGET_MINUTES_REVIEW=0
  SESSION_BUDGET_ALERT_PCT=80
  BOT_CLI_CMD=(bash -c 'exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in 1 2; do run_session review "fixture/repo$i" "$bdir/work" 5 prompt; done >"$bdir/output"
  printf '%s|%s|%s|%s' \
    "$(grep -c 'minutes=0/- ' "$bdir/output" || true)" \
    "$(grep -c 'sessions=1/1 ' "$bdir/output" || true)" \
    "$(grep -c '0/- min' "$bdir/alerts" || true)" \
    "$(grep -c '0/0 min' "$bdir/alerts" || true)"
)
# The skip line and BOTH alerts — the 80% warning and the trip — say `-`, and
# nothing anywhere says 0/0.
t budget-an-unarmed-ceiling-is-a-dash-not-a-zero '1|1|2|0' \
  "$(budget_unarmed_ceiling_is_a_dash)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_gate_precedes_vendor_probe() (
  local bdir="$TMP/budget-before-probe" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  SESSION_TERMINAL_THRESHOLD=3
  BUDGET_SESSIONS_REVIEW=3; BUDGET_MINUTES_REVIEW=0
  BOT_CLI_CMD=(bash -c 'printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { printf probe >>"$bdir/probes"; return 0; }
  alert() { :; }
  # Three terminal failures leave BOTH breakers closed on this lane: the
  # terminal one tripped at its threshold, the budget one at its ceiling.
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  # A NEW tick is what earns the terminal gate its recovery probe — a live
  # vendor call. The budget gate runs first and must refuse before it is bought.
  DUTY_TICK_ID="tick-2"
  run_session review fixture/repo "$bdir/work" 5 prompt >"$bdir/output"
  printf '%s|%s|%s' \
    "$([ -e "$bdir/probes" ] && echo PROBED || echo no-probe)" \
    "$(grep -c 'reason=budget ' "$bdir/output" || true)" \
    "$(grep -c 'reason=terminal-breaker' "$bdir/output" || true)"
)
t budget-gate-refuses-before-the-vendor-probe 'no-probe|1|0' "$(budget_gate_precedes_vendor_probe)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_report_shape() (
  local bdir="$TMP/budget-report" empty rows
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=(bash -c 'exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  # D7's "omits the section entirely when none is configured": no armed lane
  # writes no state file, so the report is empty and cli/crew prints no heading.
  empty="$(session_budget_report)"
  BUDGET_SESSIONS_REVIEW=4; BUDGET_MINUTES_REVIEW=0
  BUDGET_SESSIONS_HYGIENE=0; BUDGET_MINUTES_HYGIENE=30
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session hygiene fixture/repo "$bdir/work" 5 prompt >/dev/null
  rows="$(session_budget_report)"
  # An unarmed ceiling renders `-`, never a fabricated number: hygiene runs on
  # minutes alone and review on sessions alone.
  printf '%s|%s|%s|%s|%s' \
    "${empty:-none}" \
    "$(printf '%s\n' "$rows" | n)" \
    "$(printf '%s\n' "$rows" | grep -c 'review .*1/4 sessions, 0/- min' || true)" \
    "$(printf '%s\n' "$rows" | grep -c 'hygiene .*1/- sessions, 0/30 min' || true)" \
    "$(printf '%s\n' "$rows" | grep -c 'spent in 1d0h' || true)"
)
t budget-report-omits-unarmed-lanes-and-names-both-ceilings 'none|2|1|1|2' "$(budget_report_shape)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_report_says_unreadable() ( # budget_report_says_unreadable armed|disarmed
  local bdir="$TMP/budget-report-bad-$1"
  mkdir -p "$bdir/logs"
  DUTY_DIR="$bdir"
  BUDGET_SESSIONS_REVIEW=0; BUDGET_MINUTES_REVIEW=0
  [ "$1" = disarmed ] || BUDGET_SESSIONS_REVIEW=5
  printf 'this is not a budget header\n' >"$bdir/.session-budget.review"
  # ARMED: the one state that must not render as a balance — the gate is
  # refusing every dispatch on this lane, and the report is what connects a
  # silent box to its cause.
  #
  # DISARMED: the same broken file with no ceiling on the lane. The gate
  # returns at _session_budget_limits and never opens it, so nothing is being
  # refused and "dispatch is refused" would be a false sentence about the
  # fleet. Silence is the true answer.
  printf '%s' "$(session_budget_report)"
)
t budget-report-renders-an-unreadable-counter \
  '  review     unreadable — dispatch is refused until it is repaired or removed' \
  "$(budget_report_says_unreadable armed)"
t budget-report-is-silent-about-an-unreadable-counter-on-a-disarmed-lane \
  '' "$(budget_report_says_unreadable disarmed)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_report_follows_the_conf() (
  local bdir="$TMP/budget-report-conf" unarmed armed raised disarmed
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=(bash -c 'exit 0')
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  BUDGET_SESSIONS_REVIEW=0; BUDGET_MINUTES_REVIEW=0
  unarmed="$(session_budget_report)"
  # THE CRITERION, read literally: the operator sets a ceiling and opens
  # `crew status` to confirm it took. Nothing has dispatched, so no state file
  # exists — and the lane must still have a row, at zero. A report that
  # enumerates state files scores `none` here and leaves the operator unable to
  # tell a configured lane from an unconfigured one.
  BUDGET_SESSIONS_REVIEW=4; BUDGET_MINUTES_REVIEW=600
  armed="$(session_budget_report)"
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  # A ceiling raised with no dispatch since. The state file still carries the
  # old one in its header, so a report reading the header prints 1/4.
  BUDGET_SESSIONS_REVIEW=40
  raised="$(session_budget_report)"
  # And a lane disarmed with its counter left behind: the gate no longer reads
  # that file and no longer enforces anything, so a row quoting its bound would
  # tell the operator this lane is bounded when nothing is bounding it.
  BUDGET_SESSIONS_REVIEW=0; BUDGET_MINUTES_REVIEW=0
  disarmed="$(session_budget_report)"
  printf '%s|%s|%s|%s|%s' \
    "${unarmed:-none}" \
    "$(printf '%s\n' "$armed" | grep -c 'review .*0/4 sessions, 0/600 min spent in 1d0h (nothing spent yet)' || true)" \
    "$(printf '%s\n' "$raised" | grep -c 'review .*1/40 sessions' || true)" \
    "${disarmed:-none}" \
    "$([ -f "$bdir/.session-budget.review" ] && echo counter-kept || echo COUNTER-DELETED)"
)
t budget-report-follows-the-conf-not-the-counter 'none|1|1|none|counter-kept' \
  "$(budget_report_follows_the_conf)"

# The lane list the report enumerates is the one thing in the budget that can
# drift silently: a lane added to a role conf or to a duty without a row here
# is enforced by the gate and invisible in `crew status` until it dispatches.
# So it is pinned from BOTH sides it could drift from.

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_kinds_match_the_confs() (
  local conf suffix kind missing="" extra=""
  # Every BUDGET_SESSIONS_<SUFFIX> crew ships must fold from a kind in the
  # list. The fold is one-way — `ci-red` gives CI_RED and CI_RED gives back
  # `ci_red`, which is why the list exists at all — so the comparison is made
  # in the direction that works.
  for suffix in $(grep -rhno '^BUDGET_SESSIONS_[A-Z0-9_]*' "$SHARED/conf/" \
    | sed 's/.*BUDGET_SESSIONS_//' | sort -u); do
    for kind in $SESSION_BUDGET_KINDS; do
      kind="${kind//[^[:alnum:]]/_}"
      [ "${kind^^}" != "$suffix" ] || { suffix=""; break; }
    done
    [ -z "$suffix" ] || missing="$missing $suffix"
  done
  # And every kind in the list must be configurable: its own pair in a shipped
  # conf, or it is a row `crew status` can never print.
  for kind in $SESSION_BUDGET_KINDS; do
    suffix="${kind//[^[:alnum:]]/_}"
    grep -rq "^BUDGET_SESSIONS_${suffix^^}=" "$SHARED/conf/" || extra="$extra $kind"
  done
  printf 'unlisted:%s|unconfigurable:%s' "$missing" "$extra"
)
t budget-kinds-list-matches-the-shipped-confs 'unlisted:|unconfigurable:' \
  "$(budget_kinds_match_the_confs)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_kinds_match_the_call_sites() (
  local kind dispatched missing="" extra=""
  # The kinds the engine actually dispatches, read off the run_session call
  # sites themselves: a lane the duties launch and the list does not name is a
  # lane no operator can see the balance of before its first session.
  dispatched="$(grep -rho '^[[:space:]]*run_session [a-z-]*' "$SHARED/lib/" \
    | awk '{ print $2 }' | sort -u)"
  for kind in $dispatched; do
    case " $SESSION_BUDGET_KINDS " in *" $kind "*) ;; *) missing="$missing $kind" ;; esac
  done
  for kind in $SESSION_BUDGET_KINDS; do
    grep -q "^$kind\$" <<<"$dispatched" || extra="$extra $kind"
  done
  printf 'undispatchable:%s|unlisted:%s' "$extra" "$missing"
)
t budget-kinds-list-matches-the-run-session-call-sites 'undispatchable:|unlisted:' \
  "$(budget_kinds_match_the_call_sites)"


suite_finish
