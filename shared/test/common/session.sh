#!/usr/bin/env bash
# shared/test/common/session.sh — standalone suite for shared/lib/common/session.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"

# --- session action telemetry is best-effort and additive (#256) ----------
SA_LOG="$TMP/session-action.log"
printf 'OpenAI Codex\nfinal answer: Please connect a plugin.\n' >"$SA_LOG"
t session-hookless-is-unknown unknown "$(session_acted "$SA_LOG")"
t session-reply-tail-captured 'final answer: Please connect a plugin.' \
  "$(session_reply_tail "$SA_LOG" | base64 -d)"

codex_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/codex.conf"
  bot_session_acted "$SA_LOG" && printf yes || printf no
}
t session-codex-no-tool-is-no no "$(codex_acted)"
printf 'OpenAI Codex\nexec\n/bin/bash -lc git status\nfinal answer: done\n' >"$SA_LOG"
t session-codex-exec-is-yes yes "$(codex_acted)"

claude_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  session_acted "$SA_LOG"
}
printf 'Claude Code\nfinal answer: I need more information.\n' >"$SA_LOG"
t session-claude-print-log-is-unknown unknown "$(claude_acted)"

# Exercise run_session itself so a helper-only implementation cannot pass.
SA_WORK="$TMP/session-work"; mkdir -p "$SA_WORK"
BOT_CLI_CMD=(bash -c 'printf "exec\ncommand output\nfinal reply\n"')
# shellcheck disable=SC2317  # invoked indirectly by session_acted
bot_session_acted() { grep -qx exec "$1"; }
sa_end="$(run_session build fixture/test "$SA_WORK" 5 prompt | tail -1)"
case "$sa_end" in
  *'outcome=ok acted=yes reply_tail='*) r1=present ;;
  *) r1=MISSING ;;
esac
t session-end-fields-written present "$r1"
t session-end-outcome-token-unchanged ok \
  "$(printf '%s\n' "$sa_end" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p')"
unset -f bot_session_acted

# --- budgets off is byte-identical to today (#464) ------------------------
#
# This is what makes the change safe to land while the fleet is stopped, so it
# is asserted as a DIFF of the log output over a fixture run rather than by
# reading the code: with no budget configured, run_session's behaviour, its
# log lines and its state files must be exactly what they were.
#
# Two arms, because "not configured" has two shapes in the field — a conf that
# predates the budget and names no BUDGET_* at all, and the conf this change
# actually ships, which names them and sets them to 0.

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_off_run() ( # budget_off_run absent|explicit
  local bdir="$TMP/budget-off-$1" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  if [ "$1" = explicit ]; then
    BUDGET_SESSIONS_BUILD=0; BUDGET_MINUTES_BUILD=0; BUDGET_WINDOW_BUILD=0
  fi
  BOT_CLI_CMD=(bash -c 'printf "exec\nfinal reply\n"')
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  # Normalised on exactly four tokens, all of which move between any two runs
  # of anything: the leading UTC stamp, the session log's timestamped path, the
  # measured duration, and the dispatching process's identity (#478).
  # Everything else is compared verbatim, which is where a stray budget line
  # would show up.
  for i in 1 2 3; do run_session build "fixture/test$i" "$bdir/work" 5 prompt; done \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //' \
          -e 's#log=[^ ]*/[0-9TZ]*-build#log=<slog>-build#' \
          -e 's/ dur=[0-9]*s / dur=<n>s /' \
          -e 's/ holder=[^ ]*$/ holder=<holder>/'
  printf 'state-files=%s alerts=%s\n' \
    "$(find "$bdir" -name '.session-budget.*' | wc -l)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)"
)
t budget-off-log-output-is-byte-identical \
  "$(budget_off_run absent)" "$(budget_off_run explicit)"
t budget-off-writes-no-state-and-raises-nothing 'state-files=0 alerts=0' \
  "$(budget_off_run absent | sed -n '$p')"
# The gate is silent, not merely harmless: an "off" implementation that logged
# `reason=budget over=no` every tick would pass the diff above and still change
# every duty log in the fleet. Case-INSENSITIVE, because `BUDGET` and `Budget`
# are the same new line in a duty log and only one of the three spellings would
# have been caught.
t budget-off-says-nothing-about-budgets 0 \
  "$(budget_off_run absent | grep -ci budget || true)"

# THE BASELINE, which the diff above is not: two off-shapes of the same build
# agree with each other even when both are wrong, because a line emitted on the
# off path appears in BOTH arms and the diff stays clean. This is the log three
# sessions produce when no budget exists at all, written down — so a line the
# off path grows, in any spelling the grep above might miss, moves this instead.
#
# Nothing in it is budget-specific on purpose. It is what run_session said
# before #464 and must go on saying after it.
#
# It moved once, for #478: SESSION START gained `holder=`, the identity of the
# process the orphan reconciler asks about later. That is a deliberate change
# to what run_session says and so belongs in the golden — which is exactly the
# tripwire working, and the reason the field is normalised above rather than
# quietly excluded from the comparison.
#
# It has now moved twice. #469 appended `tier=` to SESSION END, and it is
# present on EVERY line rather than only on overridden ones, because D5's field
# is "the resolved invocation's tier, or `default`" — an aggregate cannot
# separate "hygiene got cheaper" from "hygiene got rarer" off a field that is
# missing whenever the answer is boring. So `tier=default` is what an
# unconfigured fleet writes, deliberately, and it is written down here for the
# same reason `holder=` was.
budget_off_golden() {
  cat <<'GOLDEN'
SESSION START kind=build key=fixture/test1 timeout=5s log=<slog>-build-fixture_test1.log holder=<holder>
SESSION END kind=build key=fixture/test1 rc=0 dur=<n>s outcome=ok acted=yes reply_tail=ZmluYWwgcmVwbHk= tier=default
SESSION START kind=build key=fixture/test2 timeout=5s log=<slog>-build-fixture_test2.log holder=<holder>
SESSION END kind=build key=fixture/test2 rc=0 dur=<n>s outcome=ok acted=yes reply_tail=ZmluYWwgcmVwbHk= tier=default
SESSION START kind=build key=fixture/test3 timeout=5s log=<slog>-build-fixture_test3.log holder=<holder>
SESSION END kind=build key=fixture/test3 rc=0 dur=<n>s outcome=ok acted=yes reply_tail=ZmluYWwgcmVwbHk= tier=default
GOLDEN
}
# The last line is the state-file/alert tally the case above reads; everything
# before it is the log itself.
t budget-off-log-output-matches-its-golden "$(budget_off_golden)" \
  "$(budget_off_run absent | sed '$d')"

# --- the per-duty model tier (#469) ---------------------------------------
#
# The CLI stub is a real script that records its own argv, because the whole
# claim of D1 is about WHAT WAS INVOKED. A stub that only prints a reply would
# let an implementation resolve the override, log a tier for it and still
# dispatch the profile's default array — which is the one bug this issue
# exists to make impossible.
MODEL_CLI="$TMP/model-cli.sh"
cat >"$MODEL_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$MODEL_CAPTURE"
printf 'exec\nfinal reply\n'
STUB
chmod +x "$MODEL_CLI"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
model_run() ( # model_run KIND [MODEL_VAR=VALUE ...] — one dispatch, argv captured
  local kind="$1"; shift
  local mdir="$TMP/model-$kind-$RANDOM" setting
  mkdir -p "$mdir/logs" "$mdir/work"
  DUTY_DIR="$mdir"; LOG_DIR="$mdir/logs"; DUTY_TICK_ID="tick-1"
  export MODEL_CAPTURE="$mdir/argv"; : >"$MODEL_CAPTURE"
  BOT_AGENT=fixtureagent
  BOT_CLI_CMD=(bash "$MODEL_CLI" --base-flag -p)
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  for setting in "$@"; do
    [ -n "$setting" ] || continue
    export "${setting?}"
  done
  run_session "$kind" "fixture/$kind" "$mdir/work" 5 theprompt \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  printf -- '--argv--\n'
  cat "$MODEL_CAPTURE"
)

# The profile's translation, for the arms that have one. Mirrors what
# claude.conf ships: built FROM BOT_CLI_CMD, spliced ahead of a trailing -p.
#
# SC2031: BOT_CLI_CMD is set by model_run inside its own subshell, and this
# hook is CALLED from there — reading it is the point, not a lost write. That
# is the same reason the runners above carry the disable.
# shellcheck disable=SC2317,SC2031
model_hook() {
  bot_cli_model_cmd() {
    local tier="${1:-}"
    case "$tier" in ''|-*|*[[:space:]]*) return 1 ;; esac
    case "$tier" in unsayable) return 1 ;; esac
    local -a base=("${BOT_CLI_CMD[@]}")
    local last=$(( ${#base[@]} - 1 ))
    if [ "$last" -ge 0 ] && [ "${base[last]}" = "-p" ]; then
      BOT_CLI_MODEL_CMD=("${base[@]:0:last}" --model "$tier" -p)
    else
      BOT_CLI_MODEL_CMD=("${base[@]}" --model "$tier")
    fi
  }
}

# D1/D4 — unset resolves to the profile's own array, and the argv proves it.
model_default="$( model_hook; model_run build )"
t model-unset-invokes-the-profile-array "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_default" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-unset-logs-tier-default default \
  "$(printf '%s\n' "$model_default" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# D1 — a configured kind IS invoked with the override, and the flag lands
# ahead of the trailing -p so the prompt stays the prompt.
model_over="$( model_hook; model_run mention MODEL_MENTION=cheapo )"
t model-configured-kind-invokes-the-override \
  "$(printf -- '--base-flag\n--model\ncheapo\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_over" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-configured-kind-logs-its-tier cheapo \
  "$(printf '%s\n' "$model_over" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# ...and EVERY OTHER KIND IS NOT. The override is per kind, so a configured
# mention must not re-price the build lane running beside it in the same tick.
model_other="$( model_hook; model_run build MODEL_MENTION=cheapo )"
t model-override-does-not-leak-to-another-kind \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_other" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-other-kind-still-logs-tier-default default \
  "$(printf '%s\n' "$model_other" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# The kind→variable fold, which is BUDGET_*'s and not the timeout's:
# `ci-red` reads MODEL_CI_RED. Worth its own case because TIMEOUT_CIRED sits
# in the same conf with the other spelling.
model_cired="$( model_hook; model_run ci-red MODEL_CI_RED=cheapo )"
t model-kind-suffix-folds-non-alnum cheapo \
  "$(printf '%s\n' "$model_cired" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# D3 — a profile with NO translation at all leaves the duty on the default and
# WARNS, naming the profile and the kind. Silently ignoring a configured
# override is the failure that makes an operator think they saved something.
model_hookless="$( model_run hygiene MODEL_HYGIENE=cheapo )"
t model-hookless-profile-stays-on-default \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_hookless" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-hookless-profile-logs-tier-default default \
  "$(printf '%s\n' "$model_hookless" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"
t model-hookless-profile-warns 1 \
  "$(printf '%s\n' "$model_hookless" | grep -c '^WARN: session model:' || true)"
# The warn is only useful if it says WHICH profile and WHICH duty — an operator
# reading it has four profiles and nine lanes to choose between.
model_warn="$(printf '%s\n' "$model_hookless" | sed -n 's/^WARN: session model: //p')"
case "$model_warn" in
  *kind=hygiene*fixtureagent*|*fixtureagent*kind=hygiene*) r1=named ;;
  *) r1="UNNAMED($model_warn)" ;;
esac
t model-hookless-warn-names-profile-and-kind named "$r1"
case "$model_warn" in *cheapo*) r1=named ;; *) r1=MISSING ;; esac
t model-hookless-warn-names-the-refused-tier named "$r1"

# D3, the other half — a profile that HAS a translation but cannot express
# THIS tier. Same outcome, same warn: never silently.
model_refused="$( model_hook; model_run hygiene MODEL_HYGIENE=unsayable )"
t model-refused-tier-stays-on-default \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_refused" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-refused-tier-logs-tier-default default \
  "$(printf '%s\n' "$model_refused" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"
t model-refused-tier-warns 1 \
  "$(printf '%s\n' "$model_refused" | grep -c '^WARN: session model:' || true)"

# A hook that returns 0 without writing the array is a broken profile, not a
# licence to dispatch whatever the previous kind left in the global. It must
# fall back and warn like any other profile that could not answer.
# shellcheck disable=SC2317
model_silent_hook() { bot_cli_model_cmd() { return 0; }; }
model_silent="$( model_silent_hook; model_run hygiene MODEL_HYGIENE=cheapo )"
t model-hook-that-writes-nothing-stays-on-default \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_silent" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-hook-that-writes-nothing-warns 1 \
  "$(printf '%s\n' "$model_silent" | grep -c '^WARN: session model:' || true)"

# An override must not buy its way past #464's budget gate: the gate runs
# FIRST, so an over-budget lane produces its SESSION SKIP, dispatches nothing,
# and says nothing about models — there is no invocation to have a tier.
#
# A ceiling of 1 admits the first session, so the refusal has to be asserted on
# a SECOND dispatch against the same rolling counter. Hence a pair in one
# directory rather than two calls to model_run, which deliberately gets a fresh
# DUTY_DIR each time.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
model_budget_pair() ( # model_budget_pair hook|nohook
  local mdir="$TMP/model-budget-$1" i
  mkdir -p "$mdir/logs" "$mdir/work"
  DUTY_DIR="$mdir"; LOG_DIR="$mdir/logs"; DUTY_TICK_ID="tick-1"
  export MODEL_CAPTURE="$mdir/argv"; : >"$MODEL_CAPTURE"
  BOT_AGENT=fixtureagent
  BOT_CLI_CMD=(bash "$MODEL_CLI" --base-flag -p)
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  MODEL_HYGIENE=cheapo BUDGET_SESSIONS_HYGIENE=1 BUDGET_MINUTES_HYGIENE=0
  export MODEL_HYGIENE BUDGET_SESSIONS_HYGIENE BUDGET_MINUTES_HYGIENE
  [ "$1" = nohook ] || model_hook
  for i in 1 2; do
    run_session hygiene "fixture/h$i" "$mdir/work" 5 theprompt \
      | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  done
  printf -- '--argv--\n'
  cat "$MODEL_CAPTURE"
)
model_budget="$(model_budget_pair hook)"
# The first is bought at the override; the second is refused by the budget.
t model-budget-gate-still-fires-first 1 \
  "$(printf '%s\n' "$model_budget" | grep -c 'SESSION SKIP kind=hygiene .* reason=budget' || true)"
t model-budget-refused-dispatch-invokes-nothing 1 \
  "$(printf '%s\n' "$model_budget" | sed -n '/^--argv--$/,$p' | grep -c '^theprompt$' || true)"
t model-budget-refused-dispatch-says-nothing-about-models 0 \
  "$(printf '%s\n' "$model_budget" | sed -n '/^--argv--$/q;p' \
     | grep -c '^WARN: session model:' || true)"
# THE ORDER ITSELF, and it needs a HOOKLESS profile to be observable at all.
#
# The case above passes whether the invocation is resolved before or after the
# gate, because a profile that CAN express the tier resolves it silently either
# way — a mutation moving _session_cli_cmd ahead of _session_budget_gate reds
# nothing in it. Measured, not assumed: that mutation was run and it was the
# one that killed no assertion.
#
# With no translation on the profile, resolving is no longer silent — it warns
# — so the count separates the two orders. Two dispatches, a ceiling of 1: the
# first runs and warns, the second is refused by the budget and must warn about
# NOTHING, because a dispatch that never happens has no invocation to resolve
# and no tier to fail to buy. One warn, not two.
model_budget_nohook="$(model_budget_pair nohook)"
t model-tier-resolved-only-for-a-dispatch-that-happens 1 \
  "$(printf '%s\n' "$model_budget_nohook" | sed -n '/^--argv--$/q;p' \
     | grep -c '^WARN: session model:' || true)"
# The one session that DID run was bought at the override, so the gate and the
# override are independent rather than one silencing the other.
t model-budget-armed-lane-still-honours-the-override cheapo \
  "$(printf '%s\n' "$model_budget" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p' | head -1)"

# D5's compatibility, asserted against the two readers that exist rather than
# by eye.
#
# 1. The operator's own aggregate — the awk from #467, which splits every
#    token on `=` into a map. It must still find kind and acted, and it now
#    gains a tier column for free.
model_end_line="$(printf '%s\n' "$model_over" | grep 'SESSION END')"
t model-operator-aggregate-still-parses 'mention acted=yes tier=cheapo' \
  "$(printf '%s\n' "$model_end_line" | awk '/SESSION END/ {
      for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
      printf "%s acted=%s tier=%s", f["kind"], f["acted"], f["tier"]
    }')"
# 2. The FLOOR's RE_END (fleet-floor/server/floor/units.py), which D7 fences
#    this issue out of editing — so the field's position has to keep it working
#    with no change there. The regex is read out of the floor's own source
#    rather than retyped, so this red-lines if either side moves.
if command -v python3 >/dev/null 2>&1; then
  t model-floor-re-end-still-matches 'mention|yes|cheapo-unread' \
    "$(MODEL_END="$model_end_line" python3 - "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
# Execute just the two assignments the pattern is built from.
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_]+ =|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-08-26T00:00:00Z " + os.environ["MODEL_END"])
print("|".join([m.group(2), m.group(7), "cheapo-unread"]) if m else "NO-MATCH")
PY
)"
fi

# The mechanism is the engine's and no duty module learns the word (D7), the
# same rule #464 set for budgets. Asserted over the tree, not promised.
t model-no-duty-module-knows-about-models 0 \
  "$(grep -rlE 'MODEL_[A-Z_]+|bot_cli_model_cmd' "$SHARED/lib/duty-"*.sh 2>/dev/null | wc -l)"

# --- the session's peak RSS (#473) -----------------------------------------
#
# The fixture allocates in a GRANDCHILD of the dispatch subshell and RELEASES
# it before exiting, and that shape is what both must-fail cases need: at exit
# its resident size is small and the kernel's high-water mark is not, and a
# walk that never descends the tree sees neither. `sleep` after the release,
# because a process that has already exited has no `/proc` entry to read — the
# fixture is the runaway that is still alive, which is the case that matters.
PEAK_CLI="$TMP/peak-cli.sh"
cat >"$PEAK_CLI" <<'STUB'
#!/usr/bin/env bash
python3 -c '
import time
x = bytearray(256 * 1024 * 1024)
del x
time.sleep(3)
'
printf 'exec\nfinal reply\n'
STUB
chmod +x "$PEAK_CLI"

# peak_run MUTANT|- POLL CMD… — one dispatch under a poll interval, its own
# log, and a tally of the scratch files it left behind.
# shellcheck disable=SC2030,SC2031,SC2317
peak_run() (
  local mutant="$1" poll="$2"; shift 2
  local pdir="$TMP/peak-$RANDOM$RANDOM"
  mkdir -p "$pdir/logs" "$pdir/work"
  DUTY_DIR="$pdir"; LOG_DIR="$pdir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=("$@")
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  # shellcheck disable=SC1090
  [ "$mutant" = - ] || source "$mutant"
  SESSION_PEAK_POLL_S="$poll"
  run_session build fixture/peak "$pdir/work" 30 theprompt
  # The scratch file is the session's, not the log directory's: it must not
  # outlive the line it fed.
  printf 'scratch=%s\n' "$(find "$pdir/logs" -name '*.peak' | wc -l | tr -d ' ')"
)
peak_of() { sed -n 's/.* peak_rss=\([^ ]*\).*/\1/p' <<<"$1"; }
# rc, outcome and acted as one token, for the cases whose claim is that the
# REST of the line did not move.
peak_rest() {
  sed -n 's/.*SESSION END .* rc=\([^ ]*\) dur=[^ ]* outcome=\([^ ]*\) acted=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$1"
}
peak_atleast() { # peak_atleast KiB VALUE
  case "$2" in
    '' | *[!0-9]*) printf 'NOT-A-FIGURE(%s)' "$2" ;;
    *) [ "$2" -ge "$1" ] && printf 'at-least' || printf 'TOO-SMALL(%s)' "$2" ;;
  esac
}
peak_mutant() { # peak_mutant NAME SED-EXPR — mutate the module under test
  local out="$TMP/session-mutant-$1.sh"
  sed "$2" "$SHARED/lib/common/session.sh" >"$out"
  if cmp -s "$out" "$SHARED/lib/common/session.sh"
  then t "peak-mutation-$1-applies" applied INERT
  else t "peak-mutation-$1-applies" applied applied; fi
}

# The unit reads first, because every case below rests on them: no live
# process, no figure — which is exactly what a platform with no `VmHWM`
# produces, and it must never come back as a zero.
t peak-no-reading-from-a-dead-pid '' "$(_session_proc_hwm 2147483647)"
t peak-no-reading-from-a-dead-tree '' "$(_session_tree_hwm 2147483647)"
t peak-reader-refuses-a-missing-file '' "$(session_peak_rss "$TMP/absent.peak")"
printf 'not-a-number\n' >"$TMP/bad.peak"
t peak-reader-refuses-a-non-integer '' "$(session_peak_rss "$TMP/bad.peak")"
printf '4096\n' >"$TMP/good.peak"
t peak-reader-reads-an-integer 4096 "$(session_peak_rss "$TMP/good.peak")"

# The watcher is the session's and dies with it. A leaked one would poll a pid
# that no longer exists for as long as the box lives, once per session.
SESSION_PEAK_POLL_S=30
( sleep 0.3 ) & peak_root=$!
_session_peak_rss_start "$TMP/live.peak" "$peak_root"
peak_watcher="$_SESSION_PEAK_PID"
wait "$peak_root"
_session_peak_rss_stop
if kill -0 "$peak_watcher" 2>/dev/null; then r1=STILL-RUNNING; else r1=reaped; fi
t peak-watcher-is-reaped-with-the-session reaped "$r1"
t peak-watcher-pid-is-cleared '' "$_SESSION_PEAK_PID"
SESSION_PEAK_POLL_S=5

# D2's absence, and the rule that makes it mean one thing: a session that does
# not outlive one interval is not measured. The rest of the line is untouched
# — an unmeasured session is not a failed one.
peak_short="$(peak_run - 30 bash -c 'printf "exec\nfinal reply\n"' 2>&1)"
t peak-short-session-carries-no-field '' "$(peak_of "$peak_short")"
t peak-short-session-line-otherwise-unchanged '0|ok|yes' "$(peak_rest "$peak_short")"
t peak-scratch-file-does-not-outlive-the-session scratch=0 \
  "$(sed -n 's/^scratch=/scratch=/p' <<<"$peak_short")"

# D4, and the only shape in which measuring could ever have ended a session:
# an interval an operator mistyped, which kills the watcher on its first
# sleep. The session still runs, still reports, and the failure says NOTHING —
# a duty log is evidence, and the watcher shares its stdout.
peak_broken="$(peak_run - notanumber bash -c 'sleep 1; printf "exec\nfinal reply\n"' 2>&1)"
t peak-broken-watcher-still-completes-the-session '0|ok|yes' "$(peak_rest "$peak_broken")"
t peak-broken-watcher-carries-no-field '' "$(peak_of "$peak_broken")"
t peak-broken-watcher-says-nothing-on-the-log 0 \
  "$(grep -c 'invalid time interval' <<<"$peak_broken" || true)"

# The measured cases need a process that can allocate on demand and give it
# back. Guarded rather than assumed, as the floor's RE_END case above is.
if command -v python3 >/dev/null 2>&1; then
  peak_ctl="$(peak_run - 1 bash "$PEAK_CLI" 2>&1)"
  peak_val="$(peak_of "$peak_ctl")"
  t peak-rss-recorded-on-session-end at-least "$(peak_atleast 204800 "$peak_val")"
  t peak-measured-session-line-otherwise-unchanged '0|ok|yes' "$(peak_rest "$peak_ctl")"
  # The token is LAST, past tier=, which is what keeps every reader that
  # matched the line before this field still matching it.
  case "$peak_ctl" in
    *"tier=default peak_rss=$peak_val"*) r1=appended ;;
    *) r1=NOT-APPENDED ;;
  esac
  t peak-field-is-appended-past-tier appended "$r1"

  # Must fail: RSS read at exit instead of the kernel's high-water mark. The
  # fixture has already given the memory back by the time the first read
  # lands, so this mutation reports the small figure that hid the incident
  # this issue is built on.
  peak_mutant exit-rss 's/VmHWM:/VmRSS:/'
  peak_mut_rss="$(peak_run "$TMP/session-mutant-exit-rss.sh" 1 bash "$PEAK_CLI" 2>&1)"
  t peak-mutation-exit-rss-reports-the-freed-figure TOO-SMALL \
    "$(peak_atleast 204800 "$(peak_of "$peak_mut_rss")" | sed 's/(.*//')"

  # Must fail: a walk that does not descend. The allocation is two generations
  # below the dispatch subshell, so a reader that measures only the pid it was
  # given sees `timeout` and nothing else.
  # shellcheck disable=SC2016  # the sed matches the module's literal variable
  peak_mutant no-descend 's/kids="\$(_session_proc_children "\$pid")"/kids=""/'
  peak_mut_flat="$(peak_run "$TMP/session-mutant-no-descend.sh" 1 bash "$PEAK_CLI" 2>&1)"
  t peak-mutation-no-descend-never-sees-the-allocation TOO-SMALL \
    "$(peak_atleast 204800 "$(peak_of "$peak_mut_flat")" | sed 's/(.*//')"

  # Compatibility, against the two readers that exist rather than by eye —
  # the same pair #469 asserted for tier=, now with the field behind it.
  peak_end_line="$(grep 'SESSION END' <<<"$peak_ctl")"
  t peak-operator-aggregate-still-parses "build acted=yes tier=default" \
    "$(awk '/SESSION END/ {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
        printf "%s acted=%s tier=%s", f["kind"], f["acted"], f["tier"]
      }' <<<"$peak_end_line")"
  t peak-operator-aggregate-gains-the-column "$peak_val" \
    "$(awk '/SESSION END/ {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
        printf "%s", f["peak_rss"]
      }' <<<"$peak_end_line")"
  t peak-floor-re-end-still-matches 'build|yes' \
    "$(PEAK_END="$peak_end_line" python3 - "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-08-26T00:00:00Z " + os.environ["PEAK_END"])
print("|".join([m.group(2), m.group(7)]) if m else "NO-MATCH")
PY
)"
fi

suite_finish
