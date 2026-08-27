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

# A disarmed comparison is still a real reader comparison, but it cannot
# evidence the armed, ticking state this drill exists to reach (#494). Keep
# that distinction out of the caller's prose so fixtures and the live leg
# grade the same fact.
agreement_round_result() {
  local armed_comparisons="$1"
  if [ "$armed_comparisons" -gt 0 ]; then
    printf 'compared\n'
  else
    printf 'could-not-compare\n'
  fi
}
