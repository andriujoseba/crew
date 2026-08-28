#!/usr/bin/env bash
# shared/test/common/operating-limits.sh — standalone suite for the engine's
# declared operating-limit table and boundary classifier.
set -uo pipefail

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

t operating-limit-table-session-grace 60 \
  "$(operating_limit session_kill_grace_seconds)"
t operating-limit-table-terminal-failures 3 \
  "$(operating_limit session_terminal_failures)"
t operating-limit-table-graphql-window 100 \
  "$(operating_limit github_connection_nodes)"

limit_case() {
  local measured="$1" out rc=0
  out="$(OPERATING_LIMIT_WARN_PCT=90 operating_limit_assess \
    github_connection_nodes "$measured" heavy-duty/crew 482 fixture-payload)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

case_09="$(limit_case 90)"
case_10="$(limit_case 100)"
case_11="$(limit_case 110)"
t limit-0.9-warns 1 "$(grep -c 'WARN: operating limit: heavy-duty/crew#482 github_connection_nodes measured=90 limit=100' <<<"$case_09" || true)"
t limit-1.0-warns 1 "$(grep -c 'WARN: operating limit: heavy-duty/crew#482 github_connection_nodes measured=100 limit=100' <<<"$case_10" || true)"
t limit-1.1-errors 1 "$(grep -c '2|.*ERROR: operating limit: heavy-duty/crew#482 github_connection_nodes measured=110 limit=100 crossed; cause=fixture-payload' <<<"$case_11" || true)"
t limit-error-never-says-no-duty 0 "$(grep -c 'no .* duty' <<<"$case_11" || true)"

bad_pct="$(OPERATING_LIMIT_WARN_PCT=wide operating_limit_assess \
  github_connection_nodes 89 heavy-duty/crew 482 fixture-payload)"
t invalid-margin-is-loud 1 "$(grep -c 'WARN: operating limit: OPERATING_LIMIT_WARN_PCT is invalid (wide); using 90' <<<"$bad_pct" || true)"
t invalid-margin-uses-default 0 "$(grep -c 'github_connection_nodes measured=89' <<<"$bad_pct" || true)"

unknown_rc=0
unknown="$(operating_limit missing-limit)" || unknown_rc=$?
t unknown-limit-refuses 2 "$unknown_rc"
t unknown-limit-names-cause 1 "$(grep -c "ERROR: operating limit: unknown limit 'missing-limit'" <<<"$unknown" || true)"

# Every decision-path `|| name=""` must explain its safe failure direction on
# the code line itself. Comments that quote the old bug are not candidates.
unjustified="$(
  while IFS= read -r source; do
    awk '/\|\|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=""/ \
         && $0 !~ /^[[:space:]]*#/ \
         && $0 !~ /Decision-path empty fallback:/ \
         { print FILENAME ":" FNR ":" $0 }' "$source"
  done < <(engine_lib_sources; find "$SHARED/bin" -type f -name '*.sh' -print | sort)
)"
t decision-path-empty-fallbacks-are-justified '' "$unjustified"

suite_finish
