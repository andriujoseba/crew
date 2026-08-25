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


suite_finish
