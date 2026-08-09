#!/usr/bin/env bash
# Sourceable, leg-neutral verdict helpers for drill/rehearsal.sh.

# rehearsal_verdict_record STATUS_FILE <ok|skip|fail> [reason]
# Append instead of overwriting: a later pass must never erase an earlier
# failure from the same leg.
rehearsal_verdict_record() {
  local status_file="$1" verdict="$2" reason="${3:-}"
  [ -n "$status_file" ] || return 0
  printf '%s %s %s\n' "${ROLE:-unknown}" "$verdict" "$reason" \
    >>"$status_file" 2>/dev/null || true
  return 0
}

# rehearsal_worst_verdict VERDICT_TEXT
# Print "<verdict> <reason>" for the worst recorded line. No input returns 1;
# an unknown token is evidence of a broken report and therefore grades fail.
rehearsal_worst_verdict() {
  local role verdict reason rank best="" best_reason="" best_rank=0
  while read -r role verdict reason; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      ok)   rank=1 ;;
      skip) rank=2 ;;
      *)    rank=3; verdict=fail ;;
    esac
    if [ "$rank" -gt "$best_rank" ]; then
      best_rank="$rank"; best="$verdict"; best_reason="$reason"
    fi
  done <<<"$1"
  [ -n "$best" ] || return 1
  printf '%s %s\n' "$best" "$best_reason"
}
