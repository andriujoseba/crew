# common/session.sh — run_session, session_acted, session_reply_tail,
# session_peak_rss, session_mem_hit — the dispatch that launches the box CLI,
# what it reports about the session afterwards, and the memory ceiling it is
# run under.
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
  # </dev/null: the CLI reads piped stdin to EOF as context, and stdin here
  # is the caller's while-read work list — without this, the first session
  # of a sweep swallowed every remaining repo (one-iteration loops).
  # env -u: sessions must not inherit the lock/snapshot guards, or a
  # duty.sh/notify.sh invocation from inside a session bypasses the flock.
  # timeout -k: a CLI that ignores TERM still dies 60s later.
  # `&` and a `wait`, and that is the whole of the change the measurement asks
  # of this line (#473): the dispatch needs a NAME before it can be measured,
  # and `$!` is the session's own subshell — the root of the process tree the
  # peak is taken over. Backgrounding costs nothing else here: stdin was
  # already </dev/null, and `wait` reports the same status the foreground
  # list did, timeout's 124 included.
  # The process group is UNCHANGED by the `&`, and is not this shell's —
  # measured, not reasoned: GNU `timeout` calls setpgid(0,0) absent
  # --foreground, so it puts ITSELF in a new group and runs the CLI there.
  # The session has never sat in the engine's group, in this shape or the
  # foreground one it replaced; job control is off in a script, so `&`
  # creates no group of its own. Do not read this line as putting the
  # session under a signal delivered to the engine's group — it never was.
  # The sameness is asserted as a differential against the old foreground
  # list: the D5 block in `test/common/session.sh` runs both shapes and
  # requires them to agree on where the session's group sits.
  # `_session_oom_arm` runs INSIDE the subshell and before the `env`, which is
  # the whole of D1 of #474: `oom_score_adj` is a per-process attribute that
  # survives both fork and exec, so raising it here — in the process that is
  # about to become `timeout`, which forks the CLI — is what puts the session's
  # whole tree above the engine, `cron` and `sshd` in the kernel's victim
  # scoring at the moment the CLI is `exec`'d. It cannot fail the dispatch: it
  # returns 0 on every path, so the `&&` chain is unbroken on a guest with no
  # writable procfs.
  ( cd "$dir" && _session_oom_arm && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
      timeout -k 60 "$tmo" "${_SESSION_CLI_CMD[@]}" "$prompt" ) </dev/null >"$slog" 2>&1 &
  _SESSION_DISPATCH_PID=$!
  # Started AFTER the dispatch, which is D4 by construction: the session is
  # already running by the time anything about measuring it can go wrong.
  # `.peak` and not `.log`, and LOG_DIR's readers select on that suffix — the
  # floor probe's `ls` does since #473, and `common.sh`'s "one file per
  # session" holds for everything that reads the directory as session logs.
  # The claim is about the SELECTION and not about the suffix: an
  # extension-blind walk here would see two files per running session, so a
  # reader added later has to say `*.log` to keep this true. #474's `.mem`
  # marker is the SECOND such file and rides that same rule: the probe's glob
  # covers it with no edit, which is what "the glob is also the general
  # answer" in `fleet-floor/server/probe.sh` was written for.
  _session_peak_rss_start "$slog.peak" "$_SESSION_DISPATCH_PID"
  # Started after the measurement it reads, and it is a THIRD process rather
  # than a branch inside the watcher (#474 D2): #473's D4 is that no order of
  # events lets measuring a session end it, and the guarantee lives in the
  # shape of `_session_peak_rss_watch`. Teaching that function to kill would
  # repeal D4 inside the function that exists to hold it, so the ceiling is a
  # separate actor reading the same figure off the same file.
  _session_mem_watch_start "$slog.peak" "$slog.mem" "$_SESSION_DISPATCH_PID" "$kind"
  wait "$_SESSION_DISPATCH_PID" || rc=$?
  _session_peak_rss_stop
  _session_mem_watch_stop "$slog.mem"
  local dur=$((SECONDS - start)) verdict=ok acted reply_tail peak_rss mem_hit
  mem_hit="$(session_mem_hit "$slog.mem")"
  [ "$rc" -eq 124 ] && verdict=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && verdict=FAILED
  # The ceiling OUTRANKS the timeout and the terminal classifier, and it has to
  # be a branch rather than an extra condition on the one below (D4 of #474).
  # A session the engine killed reports whatever `timeout` reported for being
  # signalled — 143, or 124 if the deadline landed in the same instant — and
  # both of those read as the CLI's own verdict on the line. Worse, the log of
  # a killed session is a TRUNCATED log, and `session_terminal` classifies
  # truncated output for a living: routing this through it would let a memory
  # kill count toward the vendor breaker and stop a lane for a reason the
  # vendor had nothing to do with.
  if [ -n "$mem_hit" ]; then
    verdict="$SESSION_MEM_OUTCOME"
  elif [ "$verdict" = FAILED ] && session_terminal "$slog"; then
    verdict=TERMINAL
    terminal=yes
  fi
  acted="$(session_acted "$slog")"
  reply_tail="$(session_reply_tail "$slog")"
  peak_rss="$(session_peak_rss "$slog.peak")"
  rm -f "$slog.peak" "$slog.mem" 2>/dev/null || true
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
# The interval, and the seam the tests drive. The reads themselves are
# builtins — no `cat`, no `grep`, no `ps` — but `_session_proc_hwm` and
# `_session_proc_children` are called in command substitutions, so the honest
# budget is TWO FORKS PER PROCESS IN THE TREE per SESSION_PEAK_POLL_S, plus
# the `sleep` and the outer substitution. For an agent CLI tree that is tens
# of forks an interval, not two. None of them exec, which is what keeps it
# cheap on a two-core box, and the interval is what keeps it bounded — but
# the number to budget against when editing this is the per-process one.
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

# _session_tree_hwm PIDS — the largest VmHWM in the trees rooted at PIDS (a
# whitespace-separated list), in KiB. Nothing is printed where no process in
# the tree reported a figure, which is also what a tree that has just exited
# looks like.
#
# The depth bound is a runaway guard and not a policy: 32 generations below
# the dispatch subshell is far past anything an agent CLI builds, and a walk
# that cannot terminate is exactly what must not run every few seconds inside
# the engine.
_session_tree_hwm() {
  local pid kids hwm=0 v depth=0
  # shellcheck disable=SC2206  # a pid list, split on whitespace by design
  local -a pids=($1) next
  while [ "${#pids[@]}" -gt 0 ] && [ "$depth" -lt 32 ]; do
    next=()
    for pid in "${pids[@]}"; do
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

# _session_peak_rss_watch ROOT FILE — hold FILE at the largest VmHWM seen in
# the process tree rooted at ROOT, for as long as ROOT lives. ROOT is the
# dispatch's own subshell, so what is measured is the session and nothing the
# engine is doing beside it. FILE is written only when the figure rises, so a
# box that dies under the CLI leaves the last peak on disk rather than
# nothing.
#
# It sleeps BEFORE its first read, and that is what makes the field's absence
# mean one thing. Reading first would race the tree's own startup: the same
# session would carry a figure or not depending on which process the scheduler
# ran first, and a field that appears at random is worse than one that is
# reliably absent. Sleeping first states the rule instead — a session that
# does not outlive one interval is not measured — and the tests assert both
# sides of it.
_session_peak_rss_watch() {
  local root="$1" out="$2" hwm=0 v
  while kill -0 "$root" 2>/dev/null; do
    # `|| return 0` and not a bare `sleep`: an interval this cannot sleep on
    # ends the watcher instead of spinning the loop hot on /proc for as long
    # as the session runs. Under the engine's `set -e` a failed sleep would
    # end it anyway — the explicit exit is what makes that true everywhere,
    # rather than a property of the caller's shell options.
    sleep "$SESSION_PEAK_POLL_S" || return 0
    v="$(_session_tree_hwm "$root")"
    if [ -n "$v" ] && [ "$v" -gt "$hwm" ]; then
      hwm="$v"
      printf '%s\n' "$hwm" >"$out" 2>/dev/null || return 0
    fi
  done
}

# _session_peak_rss_start FILE ROOT — begin measuring, into _SESSION_PEAK_PID.
#
# The watcher is a SIBLING of the dispatch, never its parent, and it starts
# only once the dispatch is already running. That is D4 structurally rather
# than by promise: there is no order of events in which measuring a session
# refuses, delays or ends it, because by the time this runs the session is
# under way and nothing here is in its path.
_session_peak_rss_start() {
  _SESSION_PEAK_PID=""
  rm -f "$1" 2>/dev/null || true
  # No procfs, no measurement, and no complaint: SESSION END simply carries no
  # peak_rss= on that platform (D2, D4).
  [ -r "/proc/$2/status" ] || return 0
  # Silenced, deliberately: the watcher shares the engine's stdout and stderr,
  # and a duty log is evidence. Anything it could have to say — an interval an
  # operator mistyped, a /proc that vanished mid-walk — is a reason to record
  # no figure, never a line in the middle of a session's own record.
  _session_peak_rss_watch "$2" "$1" >/dev/null 2>&1 &
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

# --- the memory ceiling (#474) ----------------------------------------------
#
# #473 made the growth VISIBLE; this bounds it. On 2026-08-14 one session
# reached 3.42 GB on a ~4 GB zero-swap guest and the engine bounded nothing but
# its clock: the kernel's global victim selection took a process out of the
# session's tree while its siblings kept allocating, so the box stayed down and
# the session did not stop. That is the worst of both outcomes, and the two
# halves below are the two halves of it.
#
# D1 — WHO THE KERNEL PICKS. `oom_score_adj` on the dispatch subshell, so that
# when the kernel does have to choose, it chooses the session over `cron`,
# `sshd` and the engine. Unconditional and unconfigured in the fleet conf: it
# has no number an operator needs to pick, and a fleet where it is off is a
# fleet where the 2026-08-14 outcome is still reachable.
#
# D2 — WHETHER THE KERNEL IS ASKED AT ALL. The (c) watchdog, ruled by triage at
# the past-24h rung on 2026-08-25 over `ulimit -v` (a) and a `systemd` transient
# scope (b): portable, degrading to a warning, and the only one of the three
# that can log WHY before it acts.
#
# WHAT IT READS, and the constraint that shapes everything below. The figure is
# `_session_tree_hwm`'s, produced by `_session_peak_rss_watch` and left on the
# `$slog.peak` scratch file — not a second reader of a different number. And
# the watchdog is a THIRD process rather than a branch inside that watcher,
# because #473's D4 is structural: *there is no order of events in which
# measuring a session refuses, delays or ends it*, and that guarantee is the
# SHAPE of `_session_peak_rss_watch`, not a promise beside it. This issue's
# actor must do the one thing that one must never do, so it cannot be that one.
#
# Reading the file rather than `/proc` a second time is also what keeps the
# cost at zero: the honest budget of the walk is two forks per process in the
# tree per interval (see above), and a second walk would double it on a
# two-core box. The watchdog's own budget is one `read` of a one-line file.
#
# WHY IT CANNOT FIRE EARLY OFF A TORN READ. `_session_peak_rss_watch` writes
# with `>`, which truncates before it writes, so a reader landing mid-write
# sees a PREFIX of the new figure and never a splice of two. A prefix of a
# decimal integer is smaller than the integer, so a torn read can only fail to
# fire this interval and fire on the next — the safe direction, and the reason
# `session_peak_rss`'s "anything but digits is nothing" is enough validation
# for a killing decision.

# The outcome token for a session the ceiling ended (D4). It lives in one place
# for the reason `SESSION_ORPHAN_OUTCOME` does in common/ledger.sh: it is the
# only thing distinguishing this shape from an ordinary FAILED, so the writer
# and every reader have to be looking at the same string. A bare non-zero `rc`
# is exactly what D4 forbids — `timeout` reports 143 for being signalled, which
# reads as the CLI's own verdict.
SESSION_MEM_OUTCOME=MEMORY

# The increment added to the engine's own `oom_score_adj`, and the grace
# between TERM and KILL. Both are in-module defaults, env-overridable, and
# deliberately NOT `fleet.defaults.conf` keys — that file's key is D3's
# ceiling and is this issue's alone, the same fence #473 put around
# SESSION_PEAK_POLL_S.
#
# 500 rather than 1000: the kernel's badness is `oom_score_adj` plus a
# thousandth-of-total-memory share, so +500 picks the session over any process
# not using fifty percentage points more of the box than it — decisive for the
# runaway this exists to catch — while leaving an operator room above it.
SESSION_OOM_SCORE_ADJ="${SESSION_OOM_SCORE_ADJ:-500}"
SESSION_MEM_KILL_GRACE_S="${SESSION_MEM_KILL_GRACE_S:-5}"

# _session_oom_arm — raise THIS process's oom_score_adj. Called inside the
# dispatch subshell, before the CLI is `exec`'d: the attribute survives both
# fork and exec, so arming the subshell arms `timeout`, the CLI, and every
# descendant, with no per-process bookkeeping.
#
# It returns 0 on every path, and that is a contract rather than tidiness: it
# sits in the dispatch's own `&&` chain, so a non-zero return here would refuse
# a session on a guest whose procfs is read-only.
_session_oom_arm() {
  local cur=0 inc base want
  inc="${SESSION_OOM_SCORE_ADJ:-500}"
  case "$inc" in '' | *[!0-9]*) inc=500 ;; esac
  { read -r cur </proc/self/oom_score_adj; } 2>/dev/null || cur=0
  # Anything the kernel would not have written is read as the default, which is
  # also what a guest with no procfs produces: no reading, no adjustment, and
  # no complaint.
  { [ -n "$cur" ] && [ "$cur" -eq "$cur" ]; } 2>/dev/null || cur=0
  # The floor is the KERNEL default and not the engine's own value. An engine
  # deliberately protected at a negative adjustment must not drag the session
  # down with it: the property owed is that the session outranks `cron` and
  # `sshd` as well, and those run at 0.
  base="$cur"
  [ "$base" -gt 0 ] || base=0
  want=$((base + inc))
  [ "$want" -le 1000 ] || want=1000
  # Raising is unprivileged; LOWERING needs CAP_SYS_RESOURCE. So a want at or
  # below the current value is never attempted — it could only fail, and a
  # failure here has nothing useful to say.
  [ "$want" -gt "$cur" ] || return 0
  printf '%s\n' "$want" >/proc/self/oom_score_adj 2>/dev/null || :
  return 0
}

# _session_mem_total_kib — this box's MemTotal in KiB, or nothing. KiB because
# that is `VmHWM`'s unit, so the ceiling and the figure it bounds are never
# converted and can never disagree about a factor of 1024.
_session_mem_total_kib() {
  local field value
  {
    while read -r field value _; do
      if [ "$field" = "MemTotal:" ]; then
        case "$value" in '' | *[!0-9]*) break ;; esac
        printf '%s' "$value"
        break
      fi
    done </proc/meminfo
  } 2>/dev/null || return 0
  return 0
}

# _session_mem_pct — the configured ceiling as a percentage of MemTotal, or
# nothing when no ceiling is armed (D3).
#
# A percentage and not a number of KiB, per the ruling's own reason: a fleet of
# boxes with different memory sizes needs a RELATIVE bound, and the same conf
# ships to a 4 GiB triage box and a 16 GiB builder.
#
# THE PER-ROLE OVERRIDE WINS OVER THE FLEET VALUE, and where a box carries more
# than one role — `BOT_ROLES` is a list — the MOST RESTRICTIVE armed override
# wins. The box is one box and its memory is one resource, so the tighter bound
# is the one that protects it. 0 and unset both mean "this role names no
# ceiling" rather than "this role forbids one", which is the same reading `0 is
# OFF` already has for every BUDGET_* value: a role opting out cannot disarm
# the bound a sibling role asked for.
_session_mem_pct() {
  local role suffix var value best=""
  # shellcheck disable=SC2086  # BOT_ROLES is a space-separated list by design
  for role in ${BOT_ROLES:-}; do
    suffix="${role//[^[:alnum:]]/_}"
    suffix="${suffix^^}"
    var="SESSION_MEM_MAX_PCT_${suffix}"
    value="${!var:-}"
    case "$value" in '' | *[!0-9]*) continue ;; esac
    [ "$value" -gt 0 ] || continue
    if [ -z "$best" ] || [ "$value" -lt "$best" ]; then best="$value"; fi
  done
  if [ -z "$best" ]; then
    best="${SESSION_MEM_MAX_PCT:-0}"
    case "$best" in '' | *[!0-9]*) best=0 ;; esac
  fi
  [ "$best" -gt 0 ] || return 0
  printf '%s' "$best"
}

# _session_mem_ceiling_kib — the armed ceiling in KiB, or nothing. Nothing is
# the shipped state and the whole of "with no ceiling configured, behaviour is
# exactly today's": the caller then starts no watchdog, writes no file and logs
# no line.
_session_mem_ceiling_kib() {
  local pct total ceil
  pct="$(_session_mem_pct)"
  [ -n "$pct" ] || return 0
  total="$(_session_mem_total_kib)"
  [ -n "$total" ] || return 0
  ceil=$((total * pct / 100))
  [ "$ceil" -gt 0 ] || return 0
  printf '%s' "$ceil"
}

# _session_tree_pids ROOT — every LIVE pid in the tree rooted at ROOT, the same
# bounded walk `_session_tree_hwm` makes and for the same reason: 32
# generations is far past anything an agent CLI builds, and a walk that cannot
# terminate must not run inside the engine.
#
# The two guards are the test plan's *"must fail: a ceiling that terminates the
# engine's own process rather than the session tree"*, written into the code
# rather than left to the walk's shape. The walk descends from ROOT and the
# engine is ROOT's PARENT, so it is already unreachable — but `$$` is the
# engine's pid even inside a subshell, so saying it costs one comparison and
# makes the mutation that would break it visible.
_session_tree_pids() {
  local pid kids depth=0 out=""
  # shellcheck disable=SC2206  # a pid list, split on whitespace by design
  local -a pids=($1) next
  while [ "${#pids[@]}" -gt 0 ] && [ "$depth" -lt 32 ]; do
    next=()
    for pid in "${pids[@]}"; do
      case "$pid" in '' | *[!0-9]*) continue ;; esac
      [ "$pid" -gt 1 ] || continue
      [ "$pid" != "$$" ] || continue
      # `kill -0` and not a `/proc` test: it is a builtin, so the liveness
      # check costs no fork, and it answers the question the caller is about
      # to ask anyway. A dead root must come back EMPTY rather than as a pid
      # the terminator would then signal into the void — a pid number is
      # reused, and a list that keeps dead entries is a list that could name
      # somebody else's process by the time it is used.
      kill -0 "$pid" 2>/dev/null || continue
      out="$out $pid"
      kids="$(_session_proc_children "$pid")"
      # shellcheck disable=SC2206  # a pid list, split on whitespace by design
      [ -z "$kids" ] || next+=($kids)
    done
    pids=("${next[@]}")
    depth=$((depth + 1))
  done
  printf '%s' "$out"
}

# _session_mem_terminate ROOT — end the session's tree, TERM then KILL.
#
# TERM first because a CLI that is given the chance flushes its own transcript,
# and the session log is the evidence this outcome will be read against. The
# tree is re-walked after the grace rather than reusing the first list alone:
# a process that forked during the grace is new, and one that exited is a kill
# that silently no-ops, so the union is both cheap and complete for anything
# still reachable from ROOT.
_session_mem_terminate() {
  local root="$1" pid
  local -a first=() second=()
  # A here-string and `read -a` rather than an unquoted substitution: the same
  # split, without the SC2207 the per-file shellcheck loop reds on.
  read -r -a first <<<"$(_session_tree_pids "$root")"
  [ "${#first[@]}" -gt 0 ] || return 0
  for pid in "${first[@]}"; do kill -TERM "$pid" 2>/dev/null || :; done
  sleep "$SESSION_MEM_KILL_GRACE_S" 2>/dev/null || :
  read -r -a second <<<"$(_session_tree_pids "$root")"
  for pid in "${first[@]}" ${second[@]+"${second[@]}"}; do
    kill -KILL "$pid" 2>/dev/null || :
  done
  return 0
}

# _session_mem_watch PEAK MARK ROOT KIND CEILING — the watchdog loop. Polls the
# figure #473's watcher is already producing and, past CEILING, records why and
# ends the tree.
#
# The MARK is written BEFORE the kill, and the order is what makes the outcome
# survive: `run_session` classifies this session by that file, and a box that
# dies between the two would otherwise report a session the engine killed as an
# ordinary CLI failure.
#
# The interval is SESSION_PEAK_POLL_S and not a second knob. The watchdog
# cannot see a figure sooner than the watcher publishes it, so an independent
# interval would be a setting with no effect below that one and no meaning
# above it.
_session_mem_watch() {
  local peak="$1" mark="$2" root="$3" kind="$4" ceil="$5" v
  while kill -0 "$root" 2>/dev/null; do
    sleep "$SESSION_PEAK_POLL_S" || return 0
    v="$(session_peak_rss "$peak")"
    [ -n "$v" ] || continue
    [ "$v" -gt "$ceil" ] || continue
    printf '%s\n' "$v" >"$mark" 2>/dev/null || return 0
    # Logged BEFORE it acts, which is the property (c) was chosen for: an
    # operator reading duty.log afterwards sees the figure, the ceiling and the
    # decision, not just a session that stopped. This watcher's stdout is the
    # duty log on purpose — unlike the peak watcher's, which is silenced
    # because it has nothing to say that is not a reason to record no figure.
    warn "session memory: kind=$kind reached $v KiB against a ceiling of $ceil KiB — terminating the session tree"
    _session_mem_terminate "$root"
    # After the kill, deliberately: `alert` is a curl with a ten-second
    # deadline, and a runaway that is already past the ceiling must not be
    # given ten more seconds of the box to allocate in.
    alert "🚨 $(hostname): $kind session terminated at $v KiB, past its ${ceil} KiB memory ceiling"
    return 0
  done
}

# _session_mem_watch_start PEAK MARK ROOT KIND — arm the ceiling, into
# _SESSION_MEM_PID. A no-op when nothing is configured, and that is the whole
# of "this must not become a mandatory setting": no watchdog, no file, no line.
_session_mem_watch_start() {
  local ceil
  _SESSION_MEM_PID=""
  rm -f "$2" 2>/dev/null || true
  ceil="$(_session_mem_ceiling_kib)"
  [ -n "$ceil" ] || return 0
  # Armed but unmeasurable — a guest with no procfs, or a session whose
  # measurement could not start. This is (c)'s documented degradation: the
  # ceiling reads the figure the watcher produces, so where there is no figure
  # there is no bound, and the operator is told rather than left with a setting
  # that silently does nothing.
  if [ -z "${_SESSION_PEAK_PID:-}" ]; then
    warn "session memory: kind=$4 ceiling of $ceil KiB is configured but this session is not measurable — no memory bound applied"
    return 0
  fi
  _session_mem_watch "$1" "$2" "$3" "$4" "$ceil" &
  _SESSION_MEM_PID=$!
  return 0
}

# _session_mem_watch_stop MARK — end the watchdog.
#
# A watchdog that has FIRED is waited for instead of signalled, and the
# distinction is load-bearing. Its second half — the KILL after the grace — is
# what reaps a process deeper in the tree than the root `wait` can see, so
# killing it there would leave that survivor running for the life of the box:
# the precise failure 2026-08-14 was, one level down. MARK is how the parent
# can tell: the watchdog writes it before it signals anything, so a root that
# has already exited with the file present has been killed by this ceiling.
_session_mem_watch_stop() {
  local pid="${_SESSION_MEM_PID:-}"
  _SESSION_MEM_PID=""
  [ -n "$pid" ] || return 0
  if [ -e "$1" ]; then
    wait "$pid" >/dev/null 2>&1 || true
  else
    { kill "$pid" 2>/dev/null; wait "$pid"; } >/dev/null 2>&1 || true
  fi
  return 0
}

# session_mem_hit FILE — the figure that crossed the ceiling, or nothing.
# Validated like session_peak_rss and for the same reason: this file decides an
# outcome, and anything the watchdog did not write is not one.
session_mem_hit() {
  local v=""
  { read -r v <"$1"; } 2>/dev/null || :
  case "$v" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$v"
}
