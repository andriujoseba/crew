#!/usr/bin/env bash
# shared/test/common/session.sh — standalone suite for shared/lib/common/session.sh.
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

# --- session action telemetry is best-effort and additive (#256) ----------
SA_LOG="$TMP/session-action.log"
printf 'OpenAI Codex\nfinal answer: Please connect a plugin.\n' >"$SA_LOG"
t session-hookless-is-unknown unknown "$(session_acted "$SA_LOG")"
t session-reply-tail-captured 'final answer: Please connect a plugin.' \
  "$(session_reply_tail "$SA_LOG" | base64 -d)"

codex_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/codex.conf"
  bot_session_acted "$SA_LOG" && printf yes || printf no
}
t session-codex-no-tool-is-no no "$(codex_acted)"
printf 'OpenAI Codex\nexec\n/bin/bash -lc git status\nfinal answer: done\n' >"$SA_LOG"
t session-codex-exec-is-yes yes "$(codex_acted)"

claude_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  session_acted "$SA_LOG"
}
printf 'Claude Code\nfinal answer: I need more information.\n' >"$SA_LOG"
t session-claude-print-log-is-unknown unknown "$(claude_acted)"

# Exercise run_session itself so a helper-only implementation cannot pass.
SA_WORK="$TMP/session-work"; mkdir -p "$SA_WORK"
BOT_CLI_CMD=(bash -c 'printf "exec\ncommand output\nfinal reply\n"')
# shellcheck disable=SC2317  # invoked indirectly by session_acted
bot_session_acted() { grep -qx exec "$1"; }
sa_end="$(run_session build fixture/test "$SA_WORK" 5 prompt | tail -1)"
case "$sa_end" in
  *'outcome=ok acted=yes reply_tail='*) r1=present ;;
  *) r1=MISSING ;;
esac
t session-end-fields-written present "$r1"
t session-end-outcome-token-unchanged ok \
  "$(printf '%s\n' "$sa_end" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p')"
unset -f bot_session_acted

# --- budgets off is byte-identical to today (#464) ------------------------
#
# This is what makes the change safe to land while the fleet is stopped, so it
# is asserted as a DIFF of the log output over a fixture run rather than by
# reading the code: with no budget configured, run_session's behaviour, its
# log lines and its state files must be exactly what they were.
#
# Two arms, because "not configured" has two shapes in the field — a conf that
# predates the budget and names no BUDGET_* at all, and the conf this change
# actually ships, which names them and sets them to 0.

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_off_run() ( # budget_off_run absent|explicit
  local bdir="$TMP/budget-off-$1" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  if [ "$1" = explicit ]; then
    BUDGET_SESSIONS_BUILD=0; BUDGET_MINUTES_BUILD=0; BUDGET_WINDOW_BUILD=0
  fi
  BOT_CLI_CMD=(bash -c 'printf "exec\nfinal reply\n"')
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  # Normalised on exactly three tokens, all of which move between any two runs
  # of anything: the leading UTC stamp, the session log's timestamped path, and
  # the measured duration. Everything else is compared verbatim, which is where
  # a stray budget line would show up.
  for i in 1 2 3; do run_session build "fixture/test$i" "$bdir/work" 5 prompt; done \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //' \
          -e 's#log=[^ ]*/[0-9TZ]*-build#log=<slog>-build#' \
          -e 's/ dur=[0-9]*s / dur=<n>s /'
  printf 'state-files=%s alerts=%s\n' \
    "$(find "$bdir" -name '.session-budget.*' | wc -l)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)"
)
t budget-off-log-output-is-byte-identical \
  "$(budget_off_run absent)" "$(budget_off_run explicit)"
t budget-off-writes-no-state-and-raises-nothing 'state-files=0 alerts=0' \
  "$(budget_off_run absent | sed -n '$p')"
# The gate is silent, not merely harmless: an "off" implementation that logged
# `reason=budget over=no` every tick would pass the diff above and still change
# every duty log in the fleet.
t budget-off-says-nothing-about-budgets 0 \
  "$(budget_off_run absent | grep -c budget || true)"


suite_finish
