#!/usr/bin/env bash
# shared/test/common/tick-health.sh — mirrored suite for tick-health.sh.
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

NOW="$(date -u -d '2026-08-29T02:00:00Z' +%s)"
LOG="$TMP/duty.log"
NOTIFY_LOG="$TMP/notify.log"
cat >"$LOG" <<'EOF'
2026-08-27T01:00:00Z duty run start
2026-08-27T01:01:00Z SESSION SKIP kind=old key=o/r#1 reason=budget over=sessions
2026-08-29T01:00:00Z duty run start
2026-08-29T01:01:00Z duty tick FAILED: duty.sh exited 1
2026-08-29T01:05:00Z SESSION SKIP kind=build key=o/r#2 reason=terminal-breaker count=3
2026-08-29T01:06:00Z SESSION SKIP kind=build key=o/r#malformed
2026-08-29T01:10:00Z SESSION END kind=build key=o/r#2 rc=0 dur=5s outcome=ok acted=no reply_tail=
2026-08-29T01:15:00Z SESSION END kind=build key=o/r#3 rc=- dur=- outcome=died-with-box acted=unknown reply_tail= tier=unknown started=x
2026-08-29T01:20:00Z SESSION END kind=build key=o/r#4 rc=- dur=- outcome=died-with-box acted=unknown reply_tail= tier=unknown started=x
2026-08-29T01:25:00Z duty tick skipped: previous run still holds the lock (running 500s)
2026-08-29T01:30:00Z panel request holds while checks settle
2026-08-29T01:35:00Z SESSION SKIP kind=review key=o/r#5 reason=budget over=minutes
EOF
cat >"$NOTIFY_LOG" <<'EOF'
2026-08-29T01:26:00Z notify tick skipped: previous run still holds the lock (running 20s)
EOF

REPORT="$(tick_health_report "$LOG" "$NOW" 86400)"
t tick-health-bounded-old-record-ignored 0 "$(grep -c 'kind=old' <<<"$REPORT" || true)"
t tick-health-last-tick-and-busy 'last_tick_age_s=2040 ticks=3 busy=2' \
  "$(sed -n 's/^TICK_HEALTH window_s=86400 //p' <<<"$REPORT")"
t tick-health-failed-boundary-counted-once 3 \
  "$(sed -n 's/^TICK_HEALTH .* ticks=\([0-9]*\) busy=.*/\1/p' <<<"$REPORT")"
t tick-health-notify-busy-is-box-scoped 2 \
  "$(sed -n 's/^TICK_HEALTH .* busy=\([0-9]*\)$/\1/p' <<<"$REPORT")"
t tick-health-session-skip-only 'skips=1 holds=terminal-breaker:1' \
  "$(sed -n 's/.*kind=build \(skips=[^ ]* holds=[^ ]*\).*/\1/p' <<<"$REPORT")"
t tick-health-reconstructed-streak 'outcome=died-with-box streak=2' \
  "$(sed -n 's/.*kind=build .*\(outcome=[^ ]* streak=[^ ]*\).*/\1/p' <<<"$REPORT")"
t tick-health-hold-prose-ignored 0 "$(grep -o 'holds=[^ ]*hold[^ ]*' <<<"$REPORT" | wc -l)"
t tick-health-busy-has-no-kind 0 "$(grep 'TICK_HEALTH_KIND' <<<"$REPORT" | grep -c busy || true)"
t tick-health-reason-partition 'skips=1 holds=budget:1' \
  "$(sed -n 's/.*kind=review \(skips=[^ ]* holds=[^ ]*\).*/\1/p' <<<"$REPORT")"

: >"$LOG"
: >"$NOTIFY_LOG"
t tick-health-empty-history-is-empty '' "$(tick_health_report "$LOG" "$NOW" 86400)"

ROWS="$(tick_health_rows "$REPORT")"
t tick-health-rows-state-window 6 "$(grep -c '(1d window)' <<<"$ROWS")"
t tick-health-rows-busy-rate '2/3 (66.7%)' "$(sed -n 's/^Busy ticks.*\t//p' <<<"$ROWS")"
t tick-health-rows-streak 'died-with-box ×2' "$(sed -n 's/^build outcome streak.*\t//p' <<<"$ROWS")"

suite_finish
