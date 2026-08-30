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

  local command_text digest dir stamp log tmp pid started command_b64 state
  printf -v command_text '%q ' "$@"
  command_text="${command_text% }"
  digest="$(printf '%s\0' "$command_text" | sha256sum | awk '{print $1}')"
  dir="$(_detached_run_dir "$repo" "$pr" "$head")"
  stamp="$dir/$digest.stamp"
  log="$dir/$digest.log"
  mkdir -p "$dir" || return 2

  if [ -f "$stamp" ]; then
    state="$(_detached_field "$stamp" state)"
    if [ "$state" = complete ] \
      || { [ "$state" = running ] && kill -0 "$(_detached_field "$stamp" pid)" 2>/dev/null; }; then
      printf '%s\n' "$digest"
      return 0
    fi
  fi

  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 2
  command_b64="$(printf '%s' "$command_text" | base64 | tr -d '\n')"

  # The detached wrapper waits for the launch stamp before executing. Without
  # that handshake a very short command can finish before the parent records
  # its pid, and the later launch write erases the completion it raced.
  setsid bash -c '
    stamp=$1; log=$2; shift 2
    while [ ! -f "$stamp" ]; do sleep 0.01; done
    rc=0
    "$@" >"$log" 2>&1 || rc=$?
    finish=$(date -u "+%Y-%m-%dT%H:%M:%SZ") || finish=unknown
    tmp="$stamp.done.$BASHPID"
    awk -F= '\''$1 != "state" && $1 != "exit_status" && $1 != "finish_time"'\'' \
      "$stamp" >"$tmp" 2>/dev/null || : >"$tmp"
    printf "state=complete\nexit_status=%s\nfinish_time=%s\n" "$rc" "$finish" >>"$tmp"
    mv -f "$tmp" "$stamp"
  ' _ "$stamp" "$log" "$@" </dev/null >/dev/null 2>&1 &
  pid=$!

  tmp="$(mktemp "$dir/.launch.XXXXXX")" || return 2
  printf '%s\n' \
    'version=1' "repo=$repo" "pr=$pr" "head=$head" "digest=$digest" \
    "command_b64=$command_b64" "start_time=$started" "pid=$pid" \
    "log_path=$log" 'state=running' >"$tmp"
  mv -f "$tmp" "$stamp" || return 2
  printf '%s\n' "$digest"
  return 0
}

# detached_run_read REPO PR HEAD DIGEST — classify one stamp. Result fields
# are exposed through DETACHED_RUN_* only on `running` or `complete`.
detached_run_read() {
  local repo="$1" pr="$2" head="$3" digest="$4"
  local stamp state pid status finish log command_b64
  DETACHED_RUN_STATE=unreadable
  DETACHED_RUN_PID="" DETACHED_RUN_STATUS="" DETACHED_RUN_FINISH=""
  DETACHED_RUN_LOG="" DETACHED_RUN_COMMAND=""
  _detached_valid_subject "$repo" "$pr" "$head" || { printf unreadable; return 0; }
  _detached_valid_digest "$digest" || { printf unreadable; return 0; }
  stamp="$(_detached_run_stamp "$repo" "$pr" "$head" "$digest")"
  [ -f "$stamp" ] || { DETACHED_RUN_STATE=missing; printf missing; return 0; }
  [ "$(_detached_field "$stamp" version)" = 1 ] \
    && [ "$(_detached_field "$stamp" repo)" = "$repo" ] \
    && [ "$(_detached_field "$stamp" pr)" = "$pr" ] \
    && [ "$(_detached_field "$stamp" head)" = "$head" ] \
    && [ "$(_detached_field "$stamp" digest)" = "$digest" ] \
    || { printf unreadable; return 0; }
  state="$(_detached_field "$stamp" state)"
  pid="$(_detached_field "$stamp" pid)"
  log="$(_detached_field "$stamp" log_path)"
  command_b64="$(_detached_field "$stamp" command_b64)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$log" ] && [ -n "$command_b64" ] \
    || { printf unreadable; return 0; }
  DETACHED_RUN_PID="$pid"
  DETACHED_RUN_LOG="$log"
  DETACHED_RUN_COMMAND="$(printf '%s' "$command_b64" | base64 -d 2>/dev/null)" \
    || { printf unreadable; return 0; }
  case "$state" in
    running)
      if kill -0 "$pid" 2>/dev/null; then
        DETACHED_RUN_STATE=running
        printf running
      else
        printf unreadable
      fi
      ;;
    complete)
      status="$(_detached_field "$stamp" exit_status)"
      finish="$(_detached_field "$stamp" finish_time)"
      [[ "$status" =~ ^[0-9]+$ ]] && [ -n "$finish" ] && [ -f "$log" ] \
        || { printf unreadable; return 0; }
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
  local repo="$1" pr="$2" head="$3" digest="$4" stamp pid
  stamp="$(_detached_run_stamp "$repo" "$pr" "$head" "$digest")"
  pid="$(_detached_field "$stamp" pid)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  fi
  rm -f "$stamp" 2>/dev/null || true
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
