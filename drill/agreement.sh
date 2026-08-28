#!/usr/bin/env bash
# Classify one floor-vs-CLI pair for rehearsal-app.sh and its fixture test.
agreement_case() {
  local floor_view="$1" cli_line="$2" note="$3" disarmed="$4"
  case "$cli_line" in
    *stopped*|*"NOT CREATED"*) printf 'down\n' ;;
    "") printf 'missing\n' ;;
    *)
      if [ "$floor_view" != "offline" ]; then
        printf 'up\n'
      elif [ "$disarmed" = "True" ]; then
        case "$cli_line" in
          *disarmed*|*"paused by operator"*) printf 'disarmed\n' ;;
          *) printf 'disarmed-mismatch\n' ;;
        esac
      else
        case "$note" in
          *SILENT*)
            case "$cli_line" in
              *offline*'SILENT'*) printf 'silent\n' ;;
              *) printf 'silent-mismatch\n' ;;
            esac ;;
          *"not hired"*)
            case "$cli_line" in
              *"not hired"*) printf 'not-hired\n' ;;
              *) printf 'not-hired-mismatch\n' ;;
            esac ;;
          *) printf 'up-mismatch\n' ;;
        esac
      fi ;;
  esac
}

# Decide whether one reader agreement proves the narrower #494 criterion.
# The floor state alone is insufficient: a newly hired, armed box is `idle`
# before its first tick, and a synchronized box is just as `up` as a skewed
# one. The collector publishes the other three measured facts beside state so
# the live leg and the fixtures make this decision in one place.
agreement_armed_skewed() {
  local agreement="$1" disarmed="$2" tick_fresh="$3" clock_delta="$4"
  local magnitude

  magnitude="${clock_delta#-}"
  case "$clock_delta:$magnitude" in
    -[0-9]*:[0-9]*|[0-9]*:[0-9]*) ;;
    *) printf 'does-not-qualify\n'; return ;;
  esac
  case "$magnitude" in
    ""|*[!0-9]*) printf 'does-not-qualify\n'; return ;;
  esac

  # Timestamps have one-second precision and the host/box samples are not
  # simultaneous. A synchronized pair can therefore measure 0 or 1 second;
  # two seconds is the smallest delta distinguishable from that uncertainty.
  if [ "$agreement" = "up" ] && [ "$disarmed" = "False" ] \
      && [ "$tick_fresh" = "True" ] && [ "$magnitude" -ge 2 ]; then
    printf 'qualifies\n'
  else
    printf 'does-not-qualify\n'
  fi
}

# A disarmed comparison is still a real reader comparison, but it cannot
# evidence the armed, ticking, skewed state this drill exists to reach (#494).
# Keep that distinction out of the caller's prose so fixtures and the live leg
# grade the same fact.
agreement_round_result() {
  local armed_comparisons="$1"
  if [ "$armed_comparisons" -gt 0 ]; then
    printf 'compared\n'
  else
    printf 'could-not-compare\n'
  fi
}
