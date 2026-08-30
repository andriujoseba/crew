# common/detached-run.sh — bounded work that deliberately outlives one model
# session, plus the review-park record that hands its result to a later tick.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # result globals are the module's caller interface

# Twelve five-minute duty ticks give a detached review one hour. This is an
# engine safety bound, not an operator tuning surface: expiry deliberately
# spends one fresh review rather than leaving a PR parked forever (#533 D5).
REVIEW_PARK_TICK_LIMIT=12
# The process owns the same one-hour ceiling even if its launching session dies
# before it can emit PARKED. The supervisor and command use separate sessions:
# that lets the supervisor terminate the command's whole process group and then
# record completion, while detached_run_abandon signals the supervisor and lets
# its trap perform the same bounded teardown.
DETACHED_RUN_TIMEOUT_SECONDS=3600
DETACHED_RUN_KILL_AFTER_SECONDS=60
DETACHED_RUN_HANDSHAKE_SECONDS=5
# Test seam for the otherwise millisecond launch-stamp race. Production keeps
# this at zero; the mirrored suite delays publication and kills the launcher.
DETACHED_RUN_STAMP_DELAY_SECONDS=0

_detached_slug() {
  printf '%s' "$1" | tr '/:' '__'
}

_detached_run_dir() {
  printf '%s/.detached-runs/%s/%s/%s' \
    "$DUTY_DIR" "$(_detached_slug "$1")" "$2" "$3"
}

_detached_run_stamp() {
  printf '%s/%s.stamp' "$(_detached_run_dir "$1" "$2" "$3")" "$4"
}

_detached_field() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { value=substr($0, length(key)+2) } END { print value }' \
    "$file" 2>/dev/null
}

_detached_valid_subject() {
  local repo="$1" pr="$2" head="$3"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    && [[ "$pr" =~ ^[1-9][0-9]*$ ]] \
    && [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]]
}

_detached_valid_digest() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

_detached_boot_id() {
  tr -d '\n' </proc/sys/kernel/random/boot_id 2>/dev/null
}

_detached_pid_start() {
  awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null
}

# run_detached REPO PR HEAD -- COMMAND [ARG...]
#
# Launch COMMAND in a fresh session/process group, write its immutable launch
# facts before allowing it to run, and atomically append completion facts. The
# digest is printed for the caller to put in its PARKED declaration. Repeating
# the same invocation at the same subject returns the existing digest and does
# not launch a second process.
run_detached() {
  local repo="${1:-}" pr="${2:-}" head="${3:-}"
  shift 3 2>/dev/null || return 2
  [ "${1:-}" = -- ] || return 2
  shift
  [ "$#" -gt 0 ] || return 2
  _detached_valid_subject "$repo" "$pr" "$head" || return 2

  local command_text digest dir stamp log tmp pid pid_start boot_id started command_b64 state
  printf -v command_text '%q ' "$@"
  command_text="${command_text% }"
  digest="$(printf '%s\0' "$command_text" | sha256sum | awk '{print $1}')"
  dir="$(_detached_run_dir "$repo" "$pr" "$head")"
  stamp="$dir/$digest.stamp"
  log="$dir/$digest.log"
  mkdir -p "$dir" || return 2

  if [ -f "$stamp" ]; then
    detached_run_read "$repo" "$pr" "$head" "$digest" >/dev/null
    state="$DETACHED_RUN_STATE"
    if [ "$state" = complete ] || [ "$state" = running ]; then
      printf '%s\n' "$digest"
      return 0
    fi
  fi

  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 2
  command_b64="$(printf '%s' "$command_text" | base64 | tr -d '\n')"

  # The detached wrapper waits for the launch stamp before executing. Without
  # that handshake a very short command can finish before the parent records
  # its pid, and the later launch write erases the completion it raced.
  # shellcheck disable=SC2016  # this program is expanded by the child bash
  setsid bash -c '
    stamp=$1; log=$2; bound=$3; grace=$4; handshake=$5; shift 5
    deadline=$((SECONDS + handshake))
    while [ ! -f "$stamp" ]; do
      [ "$SECONDS" -lt "$deadline" ] || exit 125
      sleep 0.01
    done

    target_pid=
    stop_target() {
      [ -n "$target_pid" ] || return 0
      kill -TERM -- "-$target_pid" 2>/dev/null || return 0
      stop_deadline=$((SECONDS + grace))
      while kill -0 -- "-$target_pid" 2>/dev/null \
        && [ "$SECONDS" -lt "$stop_deadline" ]; do
        sleep 0.05
      done
      kill -KILL -- "-$target_pid" 2>/dev/null || true
    }
    interrupted() {
      trap - TERM HUP INT
      stop_target
      exit 143
    }
    trap interrupted TERM HUP INT

    setsid "$@" >"$log" 2>&1 &
    target_pid=$!
    timed_out="$stamp.timeout.$BASHPID"
    (
      sleep "$bound"
      : >"$timed_out"
      kill -TERM -- "-$target_pid" 2>/dev/null || true
      sleep "$grace"
      kill -KILL -- "-$target_pid" 2>/dev/null || true
    ) &
    watchdog=$!

    rc=0
    wait "$target_pid" || rc=$?
    if [ -f "$timed_out" ]; then
      wait "$watchdog" 2>/dev/null || true
      rc=124
    else
      kill "$watchdog" 2>/dev/null || true
      wait "$watchdog" 2>/dev/null || true
      # A command can exit after orphaning descendants in its process group.
      # Completion is not published until that remainder is gone too.
      stop_target
    fi
    rm -f "$timed_out"
    trap - TERM HUP INT
    finish=$(date -u "+%Y-%m-%dT%H:%M:%SZ") || finish=unknown
    tmp="$stamp.done.$BASHPID"
    awk -F= '\''$1 != "state" && $1 != "exit_status" && $1 != "finish_time"'\'' \
      "$stamp" >"$tmp" 2>/dev/null || : >"$tmp"
    printf "state=complete\nexit_status=%s\nfinish_time=%s\n" "$rc" "$finish" >>"$tmp"
    mv -f "$tmp" "$stamp"
  ' _ "$stamp" "$log" "$DETACHED_RUN_TIMEOUT_SECONDS" \
    "$DETACHED_RUN_KILL_AFTER_SECONDS" "$DETACHED_RUN_HANDSHAKE_SECONDS" \
    "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  pid_start="$(_detached_pid_start "$pid")"
  boot_id="$(_detached_boot_id)"
  if [[ ! "$pid_start" =~ ^[0-9]+$ ]] || [ -z "$boot_id" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    return 2
  fi

  if [[ "$DETACHED_RUN_STAMP_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    sleep "$DETACHED_RUN_STAMP_DELAY_SECONDS"
  fi

  tmp="$(mktemp "$dir/.launch.XXXXXX")" || {
    kill -TERM -- "-$pid" 2>/dev/null || true
    return 2
  }
  printf '%s\n' \
    'version=1' "repo=$repo" "pr=$pr" "head=$head" "digest=$digest" \
    "command_b64=$command_b64" "start_time=$started" "pid=$pid" \
    "pid_start=$pid_start" "boot_id=$boot_id" \
    "timeout_seconds=$DETACHED_RUN_TIMEOUT_SECONDS" "log_path=$log" \
    'state=running' >"$tmp"
  mv -f "$tmp" "$stamp" || {
    rm -f "$tmp"
    kill -TERM -- "-$pid" 2>/dev/null || true
    return 2
  }
  printf '%s\n' "$digest"
  return 0
}

# detached_run_read REPO PR HEAD DIGEST — classify one stamp. Result fields
# are exposed through DETACHED_RUN_* only on `running` or `complete`.
detached_run_read() {
  local repo="$1" pr="$2" head="$3" digest="$4"
  local stamp state pid pid_start boot_id status finish log command_b64
  DETACHED_RUN_STATE=unreadable
  DETACHED_RUN_PID="" DETACHED_RUN_STATUS="" DETACHED_RUN_FINISH=""
  DETACHED_RUN_LOG="" DETACHED_RUN_COMMAND=""
  _detached_valid_subject "$repo" "$pr" "$head" || { printf unreadable; return 0; }
  _detached_valid_digest "$digest" || { printf unreadable; return 0; }
  stamp="$(_detached_run_stamp "$repo" "$pr" "$head" "$digest")"
  [ -f "$stamp" ] || { DETACHED_RUN_STATE=missing; printf missing; return 0; }
  if ! { [ "$(_detached_field "$stamp" version)" = 1 ] \
    && [ "$(_detached_field "$stamp" repo)" = "$repo" ] \
    && [ "$(_detached_field "$stamp" pr)" = "$pr" ] \
    && [ "$(_detached_field "$stamp" head)" = "$head" ] \
    && [ "$(_detached_field "$stamp" digest)" = "$digest" ]; }; then
    printf unreadable
    return 0
  fi
  state="$(_detached_field "$stamp" state)"
  pid="$(_detached_field "$stamp" pid)"
  pid_start="$(_detached_field "$stamp" pid_start)"
  boot_id="$(_detached_field "$stamp" boot_id)"
  log="$(_detached_field "$stamp" log_path)"
  command_b64="$(_detached_field "$stamp" command_b64)"
  if ! { [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ "$pid_start" =~ ^[0-9]+$ ]] \
    && [ -n "$boot_id" ] && [ -n "$log" ] && [ -n "$command_b64" ] \
    ; }; then
    printf unreadable
    return 0
  fi
  DETACHED_RUN_PID="$pid"
  DETACHED_RUN_LOG="$log"
  DETACHED_RUN_COMMAND="$(printf '%s' "$command_b64" | base64 -d 2>/dev/null)" \
    || { printf unreadable; return 0; }
  case "$state" in
    running)
      if [ "$boot_id" = "$(_detached_boot_id)" ] \
        && [ "$pid_start" = "$(_detached_pid_start "$pid")" ] \
        && kill -0 "$pid" 2>/dev/null; then
        DETACHED_RUN_STATE=running
        printf running
      else
        printf unreadable
      fi
      ;;
    complete)
      status="$(_detached_field "$stamp" exit_status)"
      finish="$(_detached_field "$stamp" finish_time)"
      if ! { [[ "$status" =~ ^[0-9]+$ ]] && [ -n "$finish" ] && [ -f "$log" ]; }; then
        printf unreadable
        return 0
      fi
      DETACHED_RUN_STATUS="$status"
      DETACHED_RUN_FINISH="$finish"
      DETACHED_RUN_STATE=complete
      printf complete
      ;;
    *) printf unreadable ;;
  esac
  return 0
}

detached_run_abandon() {
  local repo="$1" pr="$2" head="$3" digest="$4" stamp log pid pid_start boot_id state
  _detached_valid_subject "$repo" "$pr" "$head" || return 0
  _detached_valid_digest "$digest" || return 0
  stamp="$(_detached_run_stamp "$repo" "$pr" "$head" "$digest")"
  log="$(_detached_run_dir "$repo" "$pr" "$head")/$digest.log"
  pid="$(_detached_field "$stamp" pid)"
  pid_start="$(_detached_field "$stamp" pid_start)"
  boot_id="$(_detached_field "$stamp" boot_id)"
  state="$(_detached_field "$stamp" state)"
  if [ "$state" = running ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]] \
    && [ "$boot_id" = "$(_detached_boot_id)" ] \
    && [ "$pid_start" = "$(_detached_pid_start "$pid")" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  fi
  rm -f "$stamp" "$log" 2>/dev/null || true
  return 0
}

_review_park_path() {
  printf '%s/.review-parks/%s/%s/%s.park' \
    "$DUTY_DIR" "$(_detached_slug "$1")" "$2" "$3"
}

review_park_write() {
  local repo="$1" pr="$2" head="$3" digests="$4" reason_b64="$5"
  local path dir tmp
  _detached_valid_subject "$repo" "$pr" "$head" || return 2
  path="$(_review_park_path "$repo" "$pr" "$head")"; dir="${path%/*}"
  mkdir -p "$dir" || return 2
  tmp="$(mktemp "$dir/.park.XXXXXX")" || return 2
  printf '%s\n' 'version=1' "repo=$repo" "pr=$pr" "head=$head" \
    "digests=$digests" "reason_b64=$reason_b64" 'ticks=0' >"$tmp"
  mv -f "$tmp" "$path"
}

review_park_clear() {
  rm -f "$(_review_park_path "$1" "$2" "$3")" 2>/dev/null || true
}

_review_park_valid_digests() {
  local digests="$1" digest
  [ -n "$digests" ] || return 1
  IFS=, read -ra _REVIEW_PARK_DIGESTS <<<"$digests"
  for digest in "${_REVIEW_PARK_DIGESTS[@]}"; do
    _detached_valid_digest "$digest" || return 1
  done
}

# review_park_capture LOG EXPECTED_REPO "PR=HEAD ..." — consume standalone
# declarations from one completed reviewer session:
#
#   PARKED owner/repo#7@<40-hex-head> runs=<digest[,digest]> reason=<base64>
#
# The explicit subject prevents prose from one PR in a batched session from
# parking another. An attempted but malformed declaration makes the caller
# withhold its seen-ledger commit, so a typo retries instead of going silent.
review_park_capture() {
  local log="$1" expected_repo="$2" expected_heads="$3"
  local line marker subject runs reason extra repo tail pr head digests reason_b64 pair allowed
  REVIEW_PARK_CAPTURED=""
  REVIEW_PARK_CAPTURE_INVALID=0
  [ -f "$log" ] || return 0
  while IFS= read -r line; do
    [[ "$line" == PARKED\ * ]] || continue
    read -r marker subject runs reason extra <<<"$line"
    if [ "$marker" != PARKED ] || [ -n "${extra:-}" ] \
      || [[ "$subject" != *#*@* ]] \
      || [[ "$runs" != runs=* ]] || [[ "$reason" != reason=* ]]; then
      REVIEW_PARK_CAPTURE_INVALID=1
      continue
    fi
    repo="${subject%%#*}"
    tail="${subject#*#}"; pr="${tail%%@*}"; head="${tail#*@}"
    digests="${runs#runs=}"; reason_b64="${reason#reason=}"
    allowed=0
    for pair in $expected_heads; do
      if [ "$pair" = "$pr=$head" ]; then allowed=1; break; fi
    done
    if [ "$repo" != "$expected_repo" ] || [ "$allowed" -ne 1 ] \
      || ! _detached_valid_subject "$repo" "$pr" "$head" \
      || ! _review_park_valid_digests "$digests" \
      || ! printf '%s' "$reason_b64" | base64 -d >/dev/null 2>&1; then
      REVIEW_PARK_CAPTURE_INVALID=1
      continue
    fi
    review_park_write "$repo" "$pr" "$head" "$digests" "$reason_b64" || {
      REVIEW_PARK_CAPTURE_INVALID=1
      continue
    }
    REVIEW_PARK_CAPTURED="$REVIEW_PARK_CAPTURED $pr"
  done <"$log"
  REVIEW_PARK_CAPTURED="${REVIEW_PARK_CAPTURED# }"
  return 0
}

_review_park_rewrite_ticks() {
  local path="$1" ticks="$2" dir tmp
  dir="${path%/*}"
  tmp="$(mktemp "$dir/.ticks.XXXXXX")" || return 2
  awk -F= '$1 != "ticks"' "$path" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 2; }
  printf 'ticks=%s\n' "$ticks" >>"$tmp"
  mv -f "$tmp" "$path"
}

_review_park_abandon_all() {
  local repo="$1" pr="$2" head="$3" digests="$4" digest
  IFS=, read -ra _REVIEW_PARK_DIGESTS <<<"$digests"
  for digest in "${_REVIEW_PARK_DIGESTS[@]}"; do
    detached_run_abandon "$repo" "$pr" "$head" "$digest"
  done
  review_park_clear "$repo" "$pr" "$head"
}

_review_park_cleanup_runs() {
  local repo="$1" pr="$2" head="$3" digests="$4" digest
  _detached_valid_subject "$repo" "$pr" "$head" || return 0
  _review_park_valid_digests "$digests" || return 0
  for digest in "${_REVIEW_PARK_DIGESTS[@]}"; do
    detached_run_abandon "$repo" "$pr" "$head" "$digest"
  done
}

_review_park_abandon_file() {
  local path="$1" repo pr head digests digest stamp
  repo="$(_detached_field "$path" repo)"
  pr="$(_detached_field "$path" pr)"
  head="$(_detached_field "$path" head)"
  digests="$(_detached_field "$path" digests)"
  if _detached_valid_subject "$repo" "$pr" "$head" \
    && _review_park_valid_digests "$digests"; then
    _review_park_abandon_all "$repo" "$pr" "$head" "$digests"
    return 0
  fi

  # A damaged park may have lost its digest list while its run stamps remain
  # readable. Derive only validated digests from the subject directory; never
  # let malformed record text become a path or a kill target.
  if _detached_valid_subject "$repo" "$pr" "$head"; then
    for stamp in "$(_detached_run_dir "$repo" "$pr" "$head")"/*.stamp; do
      [ -f "$stamp" ] || continue
      digest="${stamp##*/}"; digest="${digest%.stamp}"
      _detached_valid_digest "$digest" || continue
      detached_run_abandon "$repo" "$pr" "$head" "$digest"
    done
  fi
  rm -f "$path" 2>/dev/null || true
}

_review_park_prune_other_heads() {
  local repo="$1" pr="$2" current_head="$3" current_path path
  current_path="$(_review_park_path "$repo" "$pr" "$current_head")"
  for path in "${current_path%/*}"/*.park; do
    [ -f "$path" ] || continue
    [ "$path" = "$current_path" ] && continue
    warn "review: $repo#$pr head moved past parked verification — abandoning the old detached run"
    _review_park_abandon_file "$path"
  done
}

# review_park_prune_inactive "REPO#PR ..." — after a complete pulls sweep,
# abandon parks whose review request disappeared. An incomplete sweep never
# calls this: absence under an API failure is not evidence that a request ended.
review_park_prune_inactive() {
  local active=" $1 " path repo pr
  for path in "$DUTY_DIR"/.review-parks/*/*/*.park; do
    [ -f "$path" ] || continue
    repo="$(_detached_field "$path" repo)"
    pr="$(_detached_field "$path" pr)"
    if [[ "$active" != *" $repo#$pr "* ]]; then
      warn "review: $repo#$pr no longer has a live review request — abandoning its detached run"
      _review_park_abandon_file "$path"
    fi
  done
  return 0
}

# review_park_inspect REPO PR HEAD — set REVIEW_PARK_STATE to none, parked,
# ready, or expired. A ready result remains recorded until the resumed session
# completes, so a crash retries with the same evidence instead of re-running.
review_park_inspect() {
  local repo="$1" pr="$2" head="$3" path version stored_repo stored_pr stored_head
  local digests reason_b64 ticks next_ticks digest any_running=0 result="" command_b64
  REVIEW_PARK_STATE=none
  REVIEW_PARK_RESULTS=""
  REVIEW_PARK_REASON=""
  REVIEW_PARK_DIGESTS=""
  _review_park_prune_other_heads "$repo" "$pr" "$head"
  path="$(_review_park_path "$repo" "$pr" "$head")"
  [ -f "$path" ] || return 0
  version="$(_detached_field "$path" version)"
  stored_repo="$(_detached_field "$path" repo)"
  stored_pr="$(_detached_field "$path" pr)"
  stored_head="$(_detached_field "$path" head)"
  digests="$(_detached_field "$path" digests)"
  reason_b64="$(_detached_field "$path" reason_b64)"
  ticks="$(_detached_field "$path" ticks)"
  if [ "$version" != 1 ] || [ "$stored_repo" != "$repo" ] \
    || [ "$stored_pr" != "$pr" ] || [ "$stored_head" != "$head" ] \
    || ! _review_park_valid_digests "$digests" \
    || [[ ! "$ticks" =~ ^[0-9]+$ ]] \
    || ! REVIEW_PARK_REASON="$(printf '%s' "$reason_b64" | base64 -d 2>/dev/null)"; then
    warn "review: $repo#$pr park at ${head:0:12} is unreadable — expiring and re-dispatching"
    _review_park_abandon_file "$path"
    REVIEW_PARK_STATE=expired
    return 0
  fi

  REVIEW_PARK_DIGESTS="$digests"

  IFS=, read -ra _REVIEW_PARK_DIGESTS <<<"$digests"
  for digest in "${_REVIEW_PARK_DIGESTS[@]}"; do
    detached_run_read "$repo" "$pr" "$head" "$digest" >/dev/null
    case "$DETACHED_RUN_STATE" in
      running) any_running=1 ;;
      complete)
        command_b64="$(printf '%s' "$DETACHED_RUN_COMMAND" | base64 | tr -d '\n')"
        result="${result}${result:+$'\n'}- command_b64=$command_b64 exit=$DETACHED_RUN_STATUS finished=$DETACHED_RUN_FINISH log=$DETACHED_RUN_LOG"
        ;;
      *)
        warn "review: $repo#$pr park at ${head:0:12} lost detached run $digest — expiring and re-dispatching"
        _review_park_abandon_all "$repo" "$pr" "$head" "$digests"
        REVIEW_PARK_STATE=expired
        return 0
        ;;
    esac
  done

  if [ "$any_running" -eq 1 ]; then
    next_ticks=$((ticks + 1))
    if [ "$next_ticks" -gt "$REVIEW_PARK_TICK_LIMIT" ]; then
      warn "review: $repo#$pr park at ${head:0:12} exceeded $REVIEW_PARK_TICK_LIMIT ticks — abandoning and re-dispatching"
      _review_park_abandon_all "$repo" "$pr" "$head" "$digests"
      REVIEW_PARK_STATE=expired
    elif _review_park_rewrite_ticks "$path" "$next_ticks"; then
      REVIEW_PARK_STATE=parked
    else
      warn "review: $repo#$pr could not advance its park tick — expiring and re-dispatching"
      _review_park_abandon_all "$repo" "$pr" "$head" "$digests"
      REVIEW_PARK_STATE=expired
    fi
    return 0
  fi

  REVIEW_PARK_RESULTS="$result"
  REVIEW_PARK_STATE=ready
  return 0
}
