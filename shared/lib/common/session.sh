# common/session.sh — run_session, session_acted, session_reply_tail — the dispatch that
# launches the box CLI, and what it reports about the session afterwards.
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
  ( cd "$dir" && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
      timeout -k 60 "$tmo" "${_SESSION_CLI_CMD[@]}" "$prompt" ) </dev/null >"$slog" 2>&1 || rc=$?
  local dur=$((SECONDS - start)) verdict=ok acted reply_tail
  [ "$rc" -eq 124 ] && verdict=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && verdict=FAILED
  if [ "$verdict" = FAILED ] && session_terminal "$slog"; then
    verdict=TERMINAL
    terminal=yes
  fi
  acted="$(session_acted "$slog")"
  reply_tail="$(session_reply_tail "$slog")"
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
  log "SESSION END kind=$kind key=$key rc=$rc dur=${dur}s outcome=$verdict acted=$acted reply_tail=$reply_tail tier=$_SESSION_TIER"
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
