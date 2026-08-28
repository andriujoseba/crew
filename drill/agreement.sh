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
  local agreement="$1" disarmed="$2" tick_fresh="$3" clock_delta="$4" uncertainty="$5"
  local magnitude uncertainty_magnitude

  magnitude="${clock_delta#-}"
  uncertainty_magnitude="${uncertainty#-}"
  case "$clock_delta:$magnitude:$uncertainty:$uncertainty_magnitude" in
    -[0-9]*:[0-9]*:[0-9]*:[0-9]*|[0-9]*:[0-9]*:[0-9]*:[0-9]*) ;;
    *) printf 'does-not-qualify\n'; return ;;
  esac
  case "$magnitude" in
    ""|*[!0-9]*) printf 'does-not-qualify\n'; return ;;
  esac
  case "$uncertainty_magnitude" in
    ""|*[!0-9]*) printf 'does-not-qualify\n'; return ;;
  esac

  # The box clock is sampled inside a measured host interval. Qualification is
  # deliberately strict: a delta inside that interval's half-width plus the
  # box timestamp's one-second precision is indistinguishable from latency.
  if [ "$agreement" = "up" ] && [ "$disarmed" = "False" ] \
      && [ "$tick_fresh" = "True" ] \
      && [ "$magnitude" -gt "$uncertainty_magnitude" ]; then
    printf 'qualifies\n'
  else
    printf 'does-not-qualify\n'
  fi
}

# Apply that verdict to the live round's count. Keeping the state transition
# beside the predicate lets fixtures execute the same behavior as the roster
# loop, rather than merely pinning the caller's source text.
agreement_armed_count() {
  local current="$1"
  shift
  if [ "$(agreement_armed_skewed "$@")" = "qualifies" ]; then
    printf '%s\n' "$((current + 1))"
  else
    printf '%s\n' "$current"
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
