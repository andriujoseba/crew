# common/operating-limits.sh — the engine's declared operating limits and the
# warning/error boundary shared by every caller.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash

# One inspectable table. Values here are the engine's shipped limits; operator
# configuration chooses how close a measurement may get before it warns, never
# a second copy of the limits themselves (#482).
declare -Ag OPERATING_LIMITS=(
  [github_connection_nodes]=100
  [github_panel_nodes]=50
  [github_rest_page]=100
  [session_kill_grace_seconds]=60
  [session_terminal_failures]=3
)

# operating_limit NAME — print one declared limit, refusing unknown names.
operating_limit() {
  local name="$1"
  if [ -z "${OPERATING_LIMITS[$name]+x}" ]; then
    log "ERROR: operating limit: unknown limit '$name'"
    return 2
  fi
  printf '%s' "${OPERATING_LIMITS[$name]}"
}

# operating_limit_assess NAME MEASURED REPO PR CAUSE — classify a measurement.
# At the configured margin the structured warning carries the subject and both
# numbers. Past the limit is a hard error: callers must stop the affected
# decision path rather than render its failed read as a clean board.
operating_limit_assess() {
  local name="$1" measured="$2" repo="$3" pr="$4" cause="$5"
  local limit pct
  limit="$(operating_limit "$name")" || return $?
  pct="${OPERATING_LIMIT_WARN_PCT:-90}"
  case "$measured" in ''|*[!0-9]*)
    log "ERROR: operating limit: $repo#$pr $name measurement is not a whole number ($measured); cause=$cause"
    return 2
    ;;
  esac
  case "$pct" in ''|*[!0-9]*|0|1[0-9][0-9]|[2-9][0-9][0-9]*)
    warn "operating limit: OPERATING_LIMIT_WARN_PCT is invalid ($pct); using 90"
    pct=90
    ;;
  esac
  if [ "$measured" -gt "$limit" ]; then
    log "ERROR: operating limit: $repo#$pr $name measured=$measured limit=$limit crossed; cause=$cause"
    return 2
  fi
  if [ $((measured * 100)) -ge $((limit * pct)) ]; then
    warn "operating limit: $repo#$pr $name measured=$measured limit=$limit; cause=$cause"
  fi
  return 0
}
