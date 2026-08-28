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
# shellcheck source=shared/conf/fleet.defaults.conf
source "$SHARED/conf/fleet.defaults.conf"

t operating-limit-table-session-grace 60 \
  "$(operating_limit session_kill_grace_seconds)"
t operating-limit-table-terminal-failures 3 \
  "$(operating_limit session_terminal_failures)"
t operating-limit-table-graphql-window 100 \
  "$(operating_limit github_connection_nodes)"
t limit-spool-default-max 200 "$DUTY_LIMIT_SPOOL_MAX"
t limit-spool-default-ttl 86400 "$DUTY_LIMIT_SPOOL_TTL_S"

conf_value() { sed -n "s/^$1=\([0-9]*\)\$/\1/p" "$SHARED/conf/fleet.defaults.conf"; }
t limit-spool-module-default-matches-conf-max \
  "$DUTY_LIMIT_SPOOL_MAX_DEFAULT" "$(conf_value DUTY_LIMIT_SPOOL_MAX)"
t limit-spool-module-default-matches-conf-ttl \
  "$DUTY_LIMIT_SPOOL_TTL_S_DEFAULT" "$(conf_value DUTY_LIMIT_SPOOL_TTL_S)"
t terminal-threshold-conf-defers-to-table '' "$SESSION_TERMINAL_THRESHOLD"

OPERATING_LIMITS[session_terminal_failures]=7
t terminal-threshold-default-follows-table 7 "$(_session_terminal_threshold)"
t terminal-threshold-preserves-operator-override 9 \
  "$(SESSION_TERMINAL_THRESHOLD=9 _session_terminal_threshold)"
OPERATING_LIMITS[session_terminal_failures]=3

table_breaker_dir="$TMP/table-breaker"
table_breaker_state="$(
  (
    mkdir -p "$table_breaker_dir"
    unset SESSION_TERMINAL_THRESHOLD
    OPERATING_LIMITS[session_terminal_failures]=2
    warn() { :; }
    alert() { :; }
    DUTY_DIR="$table_breaker_dir" \
      _session_terminal_record table-default yes yes fixture.log
    DUTY_DIR="$table_breaker_dir" \
      _session_terminal_record table-default yes yes fixture.log
    cut -f1,2 "$table_breaker_dir/.session-terminal.table-default"
  )
)"
t terminal-breaker-trips-at-table-derived-default $'2\ttripped' "$table_breaker_state"

# A new engine can run briefly with a conf that predates the spool keys during
# install. Under `set -u` that skew must still report and spool the assessment.
skew_dir="$TMP/skew"
skew_rc=0
(
  unset DUTY_LIMIT_SPOOL_MAX DUTY_LIMIT_SPOOL_TTL_S
  DUTY_DIR="$skew_dir" operating_limit_assess \
    github_connection_nodes 110 heavy-duty/crew 482 upgrade-skew >/dev/null
) || skew_rc=$?
t limit-spool-unset-conf-keys-preserve-assessment-rc 2 "$skew_rc"
t limit-spool-unset-conf-keys-still-write 1 "$(wc -l <"$skew_dir/.limit-events")"

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
t limit-events-spooled 3 "$(wc -l <"$DUTY_DIR/.limit-events")"
t limit-spool-has-eight-tab-fields 3 \
  "$(awk -F '\t' 'NF == 8 {n++} END {print n+0}' "$DUTY_DIR/.limit-events")"
t limit-spool-box-assigns-event-id 3 \
  "$(awk -F '\t' '$1 ~ /^[0-9]+-[0-9]+-[0-9]+$/ {n++} END {print n+0}' \
      "$DUTY_DIR/.limit-events")"
t limit-warning-spool-names-measurement 1 \
  "$(awk -F '\t' '$3=="warn" && $4=="github_connection_nodes" && $5==90 && $6==100 && $7=="heavy-duty/crew#482" {n++} END {print n+0}' \
      "$DUTY_DIR/.limit-events")"
t limit-error-spool-names-cause 1 \
  "$(awk -F '\t' '$3=="error" && $5==110 && $8=="fixture-payload" {n++} END {print n+0}' \
      "$DUTY_DIR/.limit-events")"

# Repeated content is two real events, not one content hash. Keep both.
rm -f "$DUTY_DIR/.limit-events" "$DUTY_DIR/.limit-events.dropped"
DUTY_LIMIT_SPOOL_MAX=10
operating_limit_assess github_connection_nodes 90 heavy-duty/crew 482 repeated >/dev/null
operating_limit_assess github_connection_nodes 90 heavy-duty/crew 482 repeated >/dev/null
t repeated-limit-events-keep-distinct-ids 2 \
  "$(cut -f1 "$DUTY_DIR/.limit-events" | sort -u | wc -l)"

# Both bounds discard loudly through one cumulative counter.
DUTY_LIMIT_SPOOL_MAX=2
operating_limit_assess github_connection_nodes 91 heavy-duty/crew 482 max-bound >/dev/null
t max-bound-keeps-newest-events 2 "$(wc -l <"$DUTY_DIR/.limit-events")"
t max-bound-counts-dropped-event 1 "$(cat "$DUTY_DIR/.limit-events.dropped")"
old_epoch=$(( $(date -u +%s) - 100 ))
printf '%s-1-1\t2020-01-01T00:00:00Z\twarn\tgithub_connection_nodes\t90\t100\theavy-duty/crew#482\tttl-bound\n' \
  "$old_epoch" >"$DUTY_DIR/.limit-events"
DUTY_LIMIT_SPOOL_MAX=10 DUTY_LIMIT_SPOOL_TTL_S=10 \
  operating_limit_assess github_connection_nodes 92 heavy-duty/crew 482 ttl-bound >/dev/null
t ttl-bound-removes-expired-event 1 "$(wc -l <"$DUTY_DIR/.limit-events")"
t ttl-bound-increments-cumulative-drop-counter 2 \
  "$(cat "$DUTY_DIR/.limit-events.dropped")"

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

t limit-guard-is-wired-to-round-history 2 \
  "$(grep -c 'operating_limit_assess github_connection_nodes' \
      "$SHARED/lib/duty-builder.sh")"
t limit-guard-reads-server-total-counts 5 \
  "$(grep -c '){totalCount nodes{' "$SHARED/lib/duty-builder.sh")"

suite_finish
