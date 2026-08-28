# common/operating-limits.sh — the engine's declared operating limits and the
# warning/error boundary shared by every caller.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # named reads are consumed by sibling modules

# One inspectable table. Values here are the engine's shipped limits; operator
# configuration chooses how close a measurement may get before it warns, never
# a second copy of the limits themselves (#482).
declare -Ag OPERATING_LIMITS=(
  [github_connection_nodes]=100
  [github_panel_nodes]=50
  [github_rest_page]=100
  [floor_event_spool_entries]=100
  [session_kill_grace_seconds]=60
  [session_terminal_failures]=3
)

# Named reads keep call sites legible while the associative table remains the
# only place a numeric limit is declared.
OPERATING_LIMIT_GITHUB_CONNECTION_NODES="${OPERATING_LIMITS[github_connection_nodes]}"
OPERATING_LIMIT_GITHUB_PANEL_NODES="${OPERATING_LIMITS[github_panel_nodes]}"
OPERATING_LIMIT_GITHUB_REST_PAGE="${OPERATING_LIMITS[github_rest_page]}"
OPERATING_LIMIT_FLOOR_EVENT_SPOOL_ENTRIES="${OPERATING_LIMITS[floor_event_spool_entries]}"
OPERATING_LIMIT_SESSION_KILL_GRACE_SECONDS="${OPERATING_LIMITS[session_kill_grace_seconds]}"
OPERATING_LIMIT_SESSION_TERMINAL_FAILURES="${OPERATING_LIMITS[session_terminal_failures]}"

# operating_limit NAME — print one declared limit, refusing unknown names.
operating_limit() {
  local name="$1"
  if [ -z "${OPERATING_LIMITS[$name]+x}" ]; then
    log "ERROR: operating limit: unknown limit '$name'"
    return 2
  fi
  printf '%s' "${OPERATING_LIMITS[$name]}"
}

# _operating_limit_spool LEVEL MESSAGE — durably hand one limit event to the
# host-owned floor process.  The box never sends it: probe.sh carries this
# bounded spool on the next host poll and the floor alert channel owns egress.
# Identical events collapse at the writer so a standing near-limit condition
# cannot turn a five-minute duty cadence into alert spam.
_operating_limit_spool() {
  local level="$1" message="$2" spool="$DUTY_DIR/.floor-events"
  local event_id line tmp count
  message="${message//$'\t'/ }"
  message="${message//$'\n'/ }"
  event_id="$(printf '%s\t%s' "$level" "$message" | sha256sum | awk '{print $1}')" \
    || return 0
  line="$event_id"$'\t'"$level: $message"
  grep -Fqx "$line" "$spool" 2>/dev/null && return 0

  mkdir -p "$DUTY_DIR" 2>/dev/null || return 0
  if [ -f "$spool" ]; then
    count="$(wc -l <"$spool")"
  else
    count=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ge "$OPERATING_LIMIT_FLOOR_EVENT_SPOOL_ENTRIES" ]; then
    tmp="$(mktemp "$DUTY_DIR/.floor-events.XXXXXX")" || return 0
    tail -n "$((OPERATING_LIMIT_FLOOR_EVENT_SPOOL_ENTRIES - 1))" "$spool" \
      >"$tmp" 2>/dev/null || :
    printf '%s\n' "$line" >>"$tmp"
    mv -f "$tmp" "$spool"
  else
    printf '%s\n' "$line" >>"$spool" 2>/dev/null || return 0
  fi
  return 0
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
    local message="operating limit: $repo#$pr $name measured=$measured limit=$limit crossed; cause=$cause"
    log "ERROR: $message"
    _operating_limit_spool ERROR "$message"
    return 2
  fi
  if [ $((measured * 100)) -ge $((limit * pct)) ]; then
    local message="operating limit: $repo#$pr $name measured=$measured limit=$limit; cause=$cause"
    warn "$message"
    _operating_limit_spool WARN "$message"
  fi
  return 0
}
