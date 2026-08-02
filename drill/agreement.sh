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
          *SILENT*|*"not hired"*) printf 'skip\n' ;;
          *) printf 'up-mismatch\n' ;;
        esac
      fi ;;
  esac
}
