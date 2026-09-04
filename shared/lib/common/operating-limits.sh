# common/operating-limits.sh — the engine's declared operating limits and the
# warning/error boundary shared by every caller.
#
# A module of shared/lib/common.sh, which is the engine entry point. The
# standalone vitals probe also sources this table directly: it runs before the
# duty engine and still needs the same single source for box headroom limits.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # named reads are consumed by sibling modules

# One inspectable table. Values here are the engine's shipped limits; operator
# configuration chooses how close a measurement may get before it warns, never
# a second copy of the limits themselves (#482).
declare -Ag OPERATING_LIMITS=(
  [github_connection_nodes]=100
  [github_panel_nodes]=50
  [github_pr_page]=50
  [github_rest_page]=100
  [session_kill_grace_seconds]=60
  [session_terminal_failures]=3
  [session_terminal_hold_max_ticks]=12
  [vitals_disk_used_pct]=90
  [vitals_memory_available_pct]=10
)

# Config and engine files are installed by separate atomic renames, so a tick
# can briefly run this module with a conf that predates the spool settings.
# Keep module fallbacks here; the mirrored suite pins them to the shipped conf.
DUTY_LIMIT_SPOOL_MAX_DEFAULT=200
DUTY_LIMIT_SPOOL_TTL_S_DEFAULT=86400

# Named reads keep call sites legible while the associative table remains the
# only place a numeric limit is declared.
OPERATING_LIMIT_GITHUB_CONNECTION_NODES="${OPERATING_LIMITS[github_connection_nodes]}"
OPERATING_LIMIT_GITHUB_PANEL_NODES="${OPERATING_LIMITS[github_panel_nodes]}"
OPERATING_LIMIT_GITHUB_PR_PAGE="${OPERATING_LIMITS[github_pr_page]}"
OPERATING_LIMIT_GITHUB_REST_PAGE="${OPERATING_LIMITS[github_rest_page]}"
OPERATING_LIMIT_SESSION_KILL_GRACE_SECONDS="${OPERATING_LIMITS[session_kill_grace_seconds]}"

# operating_limit NAME — print one declared limit, refusing unknown names.
operating_limit() {
  local name="$1"
  if [ -z "${OPERATING_LIMITS[$name]+x}" ]; then
    log "ERROR: operating limit: unknown limit '$name'"
    return 2
  fi
  printf '%s' "${OPERATING_LIMITS[$name]}"
}

# Process-local sequence in D6.2's box-assigned event id. Repeated content is
# deliberately not deduplicated: two assessments are two events and both are
# owed to the floor.
_OPERATING_LIMIT_EVENT_SEQ=0

# _operating_limit_spool SEVERITY NAME MEASURED LIMIT REPO PR CAUSE — durably
# hand one assessment to the host floor. The writer owns both retention bounds
# and counts every discarded line; probe.sh remains a read-only carrier.
_operating_limit_spool() {
  local severity="$1" name="$2" measured="$3" limit="$4"
  local repo="$5" pr="$6" cause="$7"
  local spool="$DUTY_DIR/.limit-events" counter="$DUTY_DIR/.limit-events.dropped"
  local now iso subject event_id line tmp counter_tmp cutoff old id event_epoch dropped=0 prior=0
  local max="${DUTY_LIMIT_SPOOL_MAX:-$DUTY_LIMIT_SPOOL_MAX_DEFAULT}"
  local ttl="${DUTY_LIMIT_SPOOL_TTL_S:-$DUTY_LIMIT_SPOOL_TTL_S_DEFAULT}"
  local -a kept=()

  now="$(date -u +%s)" || return 0
  iso="$(date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ')" || return 0
  _OPERATING_LIMIT_EVENT_SEQ=$((_OPERATING_LIMIT_EVENT_SEQ + 1))
  event_id="$now-$BASHPID-$_OPERATING_LIMIT_EVENT_SEQ"
  if [ -n "$repo" ] && [ -n "$pr" ]; then subject="$repo#$pr"; else subject=-; fi
  cause="${cause//$'\t'/ }"
  cause="${cause//$'\n'/ }"
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$event_id" "$iso" "$severity" "$name" "$measured" "$limit" "$subject" "$cause")"

  # Invalid operator values degrade to the same safe bounds as install skew.
  # The assessment itself is already logged; never lose its durable handoff
  # merely because retention configuration is malformed.
  case "$max" in ''|*[!0-9]*|0) max="$DUTY_LIMIT_SPOOL_MAX_DEFAULT" ;; esac
  case "$ttl" in ''|*[!0-9]*|0) ttl="$DUTY_LIMIT_SPOOL_TTL_S_DEFAULT" ;; esac
  mkdir -p "$DUTY_DIR" 2>/dev/null || return 0
  cutoff=$((now - ttl))
  if [ -f "$spool" ]; then
    while IFS= read -r old; do
      id="${old%%$'\t'*}"
      event_epoch="${id%%-*}"
      case "$event_epoch" in
        ''|*[!0-9]*) dropped=$((dropped + 1)); continue ;;
      esac
      if [ "$event_epoch" -lt "$cutoff" ]; then
        dropped=$((dropped + 1))
      else
        kept+=("$old")
      fi
    done <"$spool"
  fi
  kept+=("$line")
  if [ "${#kept[@]}" -gt "$max" ]; then
    dropped=$((dropped + ${#kept[@]} - max))
    kept=("${kept[@]:${#kept[@]}-max}")
  fi

  tmp="$(mktemp "$DUTY_DIR/.limit-events.XXXXXX")" || return 0
  printf '%s\n' "${kept[@]}" >"$tmp"
  if [ "$dropped" -gt 0 ]; then
    [ ! -f "$counter" ] || prior="$(cat "$counter" 2>/dev/null)"
    case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
    counter_tmp="$(mktemp "$DUTY_DIR/.limit-events.dropped.XXXXXX")" \
      || { rm -f "$tmp"; return 0; }
    printf '%s\n' "$((prior + dropped))" >"$counter_tmp"
    # Counter first is the safe crash direction: an interruption may report a
    # loss that did not complete, never discard evidence without accounting.
    mv -f "$counter_tmp" "$counter" || { rm -f "$tmp"; return 0; }
  fi
  mv -f "$tmp" "$spool" || return 0
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
    _operating_limit_spool error "$name" "$measured" "$limit" "$repo" "$pr" "$cause"
    return 2
  fi
  if [ $((measured * 100)) -ge $((limit * pct)) ]; then
    local message="operating limit: $repo#$pr $name measured=$measured limit=$limit; cause=$cause"
    warn "$message"
    _operating_limit_spool warn "$name" "$measured" "$limit" "$repo" "$pr" "$cause"
  fi
  return 0
}
