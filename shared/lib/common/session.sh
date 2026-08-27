# common/session.sh — run_session, session_acted, session_reply_tail,
# session_peak_rss — the dispatch that launches the box CLI, and what it
# reports about the session afterwards.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # RUN_SESSION_RC/RUN_SESSION_LOG are run_session's
# out-of-band result, read by the caller (duty-triage.sh's ledger commits)

# _session_cli_cmd KIND — resolve THIS dispatch's CLI invocation and the tier
# name to record for it, into _SESSION_CLI_CMD and _SESSION_TIER (#469).
#
# Every duty in this fleet used to be bought at the same price: BOT_CLI_CMD is
# a property of the agent profile, so a 1.57-minute mention that reads a
# notification subject cost what an issue mint costs. Everything ELSE about a
# session's shape is already per-duty — the timeouts are, and they carry their
# calibration in the conf comments — and model tier was the one dimension with
# nowhere to live. It lives beside the timeout now (D2), because they are two
# statements about the same duty and splitting them across files is how they
# drift apart.
#
# The mechanism is deliberately the array run_session already expands (D1).
# There is NO new dispatch path: the override replaces `"${BOT_CLI_CMD[@]}"`
# and nothing else, so the timeout, the logging, the SESSION END line, the
# terminal breaker and #464's budget gate are untouched by construction rather
# than by a promise a later edit could quietly break.
#
# Resolved AFTER both gates in run_session, which is load-bearing in the small:
# a lane that is over budget or tripped terminal must produce its SESSION SKIP
# and nothing else. Resolving here would make a refused dispatch warn about a
# tier it was never going to buy.
#
# The variable is MODEL_<KIND>, the kind's non-alphanumerics folded to `_` and
# upper-cased — the same fold BUDGET_*_<KIND> uses, so `ci-red` reads
# MODEL_CI_RED in both places and an operator learns the rule once.
#
# It is read generically, so a kind whose MODEL_ variable no conf DECLARES is
# still tierable: an operator who sets it gets it honoured. The shipped
# declarations sit in conf/roles/, which is where #469 D7 fences them; a kind
# with no declaration there is not a kind the lever skips.
_session_cli_cmd() {
  local kind="$1" suffix var tier
  suffix="${kind//[^[:alnum:]]/_}"
  suffix="${suffix^^}"
  var="MODEL_${suffix}"
  tier="${!var:-}"
  # The default, and it is the whole of D4: with nothing configured anywhere
  # this function copies the profile's array and names the tier `default`, so
  # an engine that is upgraded and not configured INVOKES exactly what it
  # invoked before — the invocation and the session's behaviour are unchanged.
  # The log is not: _SESSION_TIER is set unconditionally, so SESSION END gains
  # `tier=default` on every line, including unconfigured ones. That is D5's
  # deliberate choice, not a leak — an aggregate cannot tell a duty that got
  # cheaper from one that got rarer off a field that vanishes whenever the
  # answer is boring. See the SESSION END comment below for why it is appended
  # past reply_tail rather than inserted.
  _SESSION_CLI_CMD=("${BOT_CLI_CMD[@]}")
  _SESSION_TIER=default
  [ -n "$tier" ] || return 0
  # D3, and the failure mode it exists to stop: silently ignoring a configured
  # override is what makes an operator think they saved something. Both ways a
  # profile can fail to honour a tier — no translation at all, and a
  # translation that refuses this particular tier — leave the duty on the
  # default and SAY SO, naming the profile and the kind. Never silently.
  if ! declare -F bot_cli_model_cmd >/dev/null 2>&1; then
    warn "session model: kind=$kind asked for tier=$tier but agent profile ${BOT_AGENT:-unknown} expresses no model translation — staying on the default invocation"
    return 0
  fi
  # The hook answers in an array, because a tier is not always one token: the
  # profile owns the whole translation from "this duty wants a cheaper tier"
  # to its own flags, exactly as it already owns bot_cli_probe and
  # bot_session_acted. Cleared first so a hook that returns 0 without writing
  # cannot hand us the PREVIOUS kind's invocation.
  BOT_CLI_MODEL_CMD=()
  if ! bot_cli_model_cmd "$tier" || [ "${#BOT_CLI_MODEL_CMD[@]}" -eq 0 ]; then
    warn "session model: kind=$kind asked for tier=$tier but agent profile ${BOT_AGENT:-unknown} cannot express it — staying on the default invocation"
    return 0
  fi
  _SESSION_CLI_CMD=("${BOT_CLI_MODEL_CMD[@]}")
  _SESSION_TIER="$tier"
}

# run_session KIND KEY DIR TIMEOUT PROMPT — the only way a duty launches the
# box CLI. Adds what every hand-rolled variant lacked somewhere: a timeout (a
# hung session used to hold the flock forever, invisibly), captured exit
# status on every path, a per-session log file, and one structured outcome
# line in duty.log (the biggest logging gap in three of five metrics files).
run_session() {
  local kind="$1" key="$2" dir="$3" tmo="$4" prompt="$5"
  local slog rc=0 start terminal=no
  # Budget BEFORE the terminal gate, and the order is load-bearing (#464): the
  # terminal gate's recovery path makes a live vendor probe, and a lane that
  # has spent its window must not be able to buy one.
  _session_budget_gate "$kind" "$key" || return 0
  _session_terminal_gate "$kind" "$key" || return 0
  # Both gates passed, so this dispatch is really happening: now, and not
  # before, resolve what it is bought with (#469).
  _session_cli_cmd "$kind"
  mkdir -p "$LOG_DIR"
  slog="$LOG_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$kind-${key//[\/#]/_}.log"
  # holder=: who to ask, at a later tick, whether this session is still
  # running. Nothing below this line runs if the box dies under the CLI, so
  # the start has to carry the liveness question with it — and it has to be a
  # question about a PROCESS, because a build may legitimately run for two
  # hours and no clock can tell that from a death (#478, common/ledger.sh).
  log "SESSION START kind=$kind key=$key timeout=${tmo}s log=$slog holder=$(_session_holder)"
  start=$SECONDS
  # Started before the dispatch and stopped after it, so the window measured
  # is exactly the session's (#473). `.peak` and not `.log`: nothing that
  # walks LOG_DIR for session logs may pick this scratch file up.
  _session_peak_rss_start "$slog.peak"
  # </dev/null: the CLI reads piped stdin to EOF as context, and stdin here
  # is the caller's while-read work list — without this, the first session
  # of a sweep swallowed every remaining repo (one-iteration loops).
  # env -u: sessions must not inherit the lock/snapshot guards, or a
  # duty.sh/notify.sh invocation from inside a session bypasses the flock.
  # timeout -k: a CLI that ignores TERM still dies 60s later.
  ( cd "$dir" && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
      timeout -k 60 "$tmo" "${_SESSION_CLI_CMD[@]}" "$prompt" ) </dev/null >"$slog" 2>&1 || rc=$?
  _session_peak_rss_stop
  local dur=$((SECONDS - start)) verdict=ok acted reply_tail peak_rss
  [ "$rc" -eq 124 ] && verdict=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && verdict=FAILED
  if [ "$verdict" = FAILED ] && session_terminal "$slog"; then
    verdict=TERMINAL
    terminal=yes
  fi
  acted="$(session_acted "$slog")"
  reply_tail="$(session_reply_tail "$slog")"
  peak_rss="$(session_peak_rss "$slog.peak")"
  rm -f "$slog.peak" 2>/dev/null || true
  # tier= is APPENDED, after reply_tail, and the position is the whole of D5's
  # compatibility (#469). This chain is justified by an aggregate read off
  # these lines, so a field that breaks the measurement would be a poor way to
  # end it. Two readers constrain where it can go:
  #
  #   - the operator's own awk splits every token on `=` into a map, so it
  #     takes a new field anywhere and gains a column for free;
  #   - the floor's RE_END (fleet-floor/server/floor/units.py) matches
  #     `… outcome=(\S+)(?: acted=… reply_tail=(\S*))?` and is unanchored at
  #     the end. INSERTING before `acted=` would break that optional group and
  #     silently drop acted and reply_tail on every line; appending after it
  #     leaves the match untouched and the trailing token simply unread.
  #
  # So the floor keeps working with no edit, which matters because D7 fences
  # fleet-floor out of this issue. The orphan reconciler already appends
  # `started=` past reply_tail the same way (common/ledger.sh), so this is the
  # established position rather than a new one.
  #
  # peak_rss= is appended past tier= for the same reason and OMITTED ENTIRELY
  # when the kernel gave no figure (#473 D2): a `peak_rss=0` or an
  # `unknown` would be a measurement claimed by a session nobody measured,
  # and an aggregate cannot tell those apart from a cheap session. The
  # reconstructed terminal in common/ledger.sh carries the field as `-`, the
  # convention that file states for a numeric it cannot recover — #553's
  # parity guard is what makes that a rule rather than a habit.
  log "SESSION END kind=$kind key=$key rc=$rc dur=${dur}s outcome=$verdict acted=$acted reply_tail=$reply_tail tier=$_SESSION_TIER${peak_rss:+ peak_rss=$peak_rss}"
  _session_terminal_record "$kind" "$terminal" "$acted" "$slog"
  # The rolling counter is written alongside the line that carries the same
  # duration, so the budget and the log can never disagree about what a
  # session cost. Every outcome counts: a TIMEOUT and a TERMINAL spent the
  # vendor's clock exactly as an ok did.
  _session_budget_record "$kind" "$dur"
  # Outcome exposed for callers that gate follow-up state on success (the seen-
  # ledger commits in duty-triage.sh) WITHOUT reintroducing the set -e abort a
  # failed session must never cause — return stays 0.
  RUN_SESSION_RC="$rc"
  RUN_SESSION_LOG="$slog"
  return 0
}

session_acted() {
  local rc
  declare -F bot_session_acted >/dev/null 2>&1 || { printf unknown; return; }
  bot_session_acted "$1" && rc=0 || rc=$?
  case "$rc" in
    0) printf yes ;;
    1) printf no ;;
    *) printf unknown ;;
  esac
}

session_reply_tail() {
  # SESSION END is space-delimited, so encode arbitrary reply prose as one
  # token; the fleet floor decodes it for display.
  awk 'NF { line=$0 } END { printf "%s", substr(line, 1, 200) }' "$1" 2>/dev/null \
    | base64 | tr -d '\n'
}

# --- peak RSS (#473) --------------------------------------------------------
#
# What SESSION END could not say: a triage session reached 3.42 GB on a ~4 GB
# zero-swap guest, the OOM killer took a process out of the tree and the box
# thrashed unreachable for twelve minutes — and the engine's record of that
# session carries `rc`, `dur` and `outcome`, not one number that grows.
#
# WHAT IS READ, and why it is not a sample of current usage. `VmHWM` in
# `/proc/<pid>/status` is the kernel's own high-water mark for a process: it
# only rises, and it survives the free that follows a spike. Measured on this
# kernel — a process that allocates 300 MiB and releases it reports
# `VmHWM: 315684 kB` beside `VmRSS: 11460 kB`. So every read here returns a
# peak the kernel recorded, never a footprint sampled at the moment of asking,
# and the only thing an interval between reads can lose is growth in a process
# that then dies before the next one.
#
# WHY IT IS READ WHILE THE TREE IS ALIVE, against D1's letter. There is no
# teardown read to make. A task's mm is torn down before it becomes a zombie:
# `/proc/<pid>/status` for an exited-but-unreaped child carries `State: Z` and
# no `Vm*` line at all, and after the wait the directory is gone (both
# measured). `VmHWM` is also per-process and never aggregates — a parent shell
# sat at 3300 kB while its own child peaked at 315928 kB — and bash execs the
# last command of the dispatch subshell, so that pid is `timeout`, whose child
# is the CLI. A figure taken at teardown would be missing or the wrong
# process's. The finding is on #473 and the reader is one function, so a
# ruling that prefers another mechanism replaces this and nothing else.
#
# WHAT THE FIGURE IS: the largest `VmHWM` in the session's process tree, not a
# sum. Summing RSS over a forked tree double-counts the pages a fork shares,
# and the per-process peak is what the OOM killer scores — the incident above
# is one process reaching 3.42 GB, not a tree averaging it.
#
# The interval, and the seam the tests drive. Two forks every SESSION_PEAK_
# POLL_S while a session runs; the walk itself is builtin reads, because a
# fork per process per interval is a real cost on a two-core box.
SESSION_PEAK_POLL_S="${SESSION_PEAK_POLL_S:-5}"

# _session_proc_hwm PID — one live process's VmHWM in KiB, or nothing. The
# read is wrapped because a process that exits mid-walk makes the redirection
# itself fail, and under `set -e` a bare failed redirection ends the tick.
_session_proc_hwm() {
  local field value
  {
    while read -r field value _; do
      if [ "$field" = "VmHWM:" ]; then
        printf '%s' "$value"
        break
      fi
    done <"/proc/$1/status"
  } 2>/dev/null || return 0
  return 0
}

# _session_proc_children PID — the kernel's own child list for PID, from
# `/proc/<pid>/task/<tid>/children`. A kernel built without CONFIG_PROC_
# CHILDREN has no such file, and the walk then sees a one-process tree rather
# than failing (D4).
_session_proc_children() {
  local f kids out=""
  for f in /proc/"$1"/task/*/children; do
    [ -r "$f" ] || continue
    kids=""
    # `read` reports failure on the file's missing trailing newline while
    # still having read the line, so its status is deliberately discarded.
    { read -r kids <"$f"; } 2>/dev/null || :
    [ -z "$kids" ] || out="$out $kids"
  done
  printf '%s' "$out"
}

# _session_tree_hwm PIDS SKIP — the largest VmHWM in the trees rooted at PIDS
# (a whitespace-separated list), in KiB, skipping SKIP and never descending
# into it: SKIP is the watcher itself, whose own `sleep` would otherwise be
# measured as part of the session.
_session_tree_hwm() {
  local skip="$2" pid kids hwm=0 v depth=0
  # shellcheck disable=SC2206  # a pid list, split on whitespace by design
  local -a pids=($1) next
  while [ "${#pids[@]}" -gt 0 ] && [ "$depth" -lt 32 ]; do
    next=()
    for pid in "${pids[@]}"; do
      [ "$pid" != "$skip" ] || continue
      v="$(_session_proc_hwm "$pid")"
      [ -n "$v" ] && [ "$v" -gt "$hwm" ] && hwm="$v"
      kids="$(_session_proc_children "$pid")"
      # shellcheck disable=SC2206  # a pid list, split on whitespace by design
      [ -z "$kids" ] || next+=($kids)
    done
    pids=("${next[@]}")
    depth=$((depth + 1))
  done
  [ "$hwm" -gt 0 ] || return 0
  printf '%s' "$hwm"
}

# _session_peak_rss_watch ROOT FILE — hold FILE at the largest VmHWM seen
# BELOW ROOT for as long as ROOT lives. FILE is written only when the figure
# rises, so a box that dies under the CLI leaves the last peak on disk rather
# than nothing.
#
# It sleeps BEFORE its first read, and that is what makes the field's absence
# mean one thing. Reading first would race the dispatch's own fork: the same
# session would carry a figure or not depending on which of two processes the
# scheduler ran first, and a field that appears at random is worse than one
# that is always missing. Sleeping first states the rule instead — a session
# that does not outlive one interval is not measured — and the tests assert
# both sides of it.
#
# ROOT itself is walked but never MEASURED (it is passed as the skip on the
# first turn only through its own exclusion below): ROOT is the engine shell,
# whose own footprint is not the session's. What is measured is everything the
# dispatch put underneath it.
_session_peak_rss_watch() {
  local root="$1" out="$2" self hwm=0 v kids
  self="$BASHPID"
  while kill -0 "$root" 2>/dev/null; do
    sleep "$SESSION_PEAK_POLL_S"
    kids="$(_session_proc_children "$root")"
    [ -n "$kids" ] || continue
    v="$(_session_tree_hwm "$kids" "$self")"
    if [ -n "$v" ] && [ "$v" -gt "$hwm" ]; then
      hwm="$v"
      printf '%s\n' "$hwm" >"$out" 2>/dev/null || return 0
    fi
  done
}

# _session_peak_rss_start FILE — begin measuring, into _SESSION_PEAK_PID.
#
# The watcher is a SIBLING of the dispatch and roots its walk at the engine
# shell, which is the whole of D4 in the structural sense: the dispatch line
# below is byte-identical to the one that ran before this field existed, so
# there is no path by which measuring a session can refuse, delay or end it.
# During a dispatch the engine's only descendants are that subshell's tree and
# this watcher, which the walk skips.
_session_peak_rss_start() {
  _SESSION_PEAK_PID=""
  rm -f "$1" 2>/dev/null || true
  # No procfs, no measurement, and no complaint: SESSION END simply carries no
  # peak_rss= on that platform (D2, D4).
  [ -r "/proc/$$/status" ] || return 0
  _session_peak_rss_watch "$$" "$1" &
  _SESSION_PEAK_PID=$!
  return 0
}

# _session_peak_rss_stop — end the watcher, reaping it quietly.
_session_peak_rss_stop() {
  [ -n "${_SESSION_PEAK_PID:-}" ] || return 0
  { kill "$_SESSION_PEAK_PID" 2>/dev/null; wait "$_SESSION_PEAK_PID"; } >/dev/null 2>&1 || true
  _SESSION_PEAK_PID=""
  return 0
}

# session_peak_rss FILE — the recorded figure, in KiB, or nothing. Anything
# that is not a bare integer is nothing: an absent field says the engine did
# not measure this session, and a fabricated one would say it measured zero.
session_peak_rss() {
  local v=""
  { read -r v <"$1"; } 2>/dev/null || :
  case "$v" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$v"
}
