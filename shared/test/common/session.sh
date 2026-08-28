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

# --- structured usage and credential-pool identity (#475) ----------------
#
# The stub is the CLI, not the parser: it receives Claude's profile-built
# argv and emits the vendor JSON shape. That makes the invocation, prose
# reconstruction and SESSION END record one behavioral path.
USAGE_CLI="$TMP/usage-cli.sh"
cat >"$USAGE_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$USAGE_ARGV"
case "${USAGE_SHAPE:-valid}" in
  valid)
    printf '%s\n' '{"type":"result","subtype":"success","result":"I pushed the fix.","session_id":"session/one","total_cost_usd":0.0125,"usage":{"input_tokens":120,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":77}}'
    ;;
  malformed)
    printf '%s\n' '{"type":"result","subtype":"success","result":"I pushed the fix.","session_id":"session/two","total_cost_usd":0.5,"usage":{"input_tokens":"many","output_tokens":4}}'
    ;;
esac
STUB
chmod +x "$USAGE_CLI"

# shellcheck disable=SC2030,SC2031,SC2317
usage_run() ( # usage_run POOL SHAPE — one independent box-shaped dispatch
  local pool="$1" shape="$2" udir
  udir="$TMP/usage-$pool-$shape-$RANDOM"
  mkdir -p "$udir/logs" "$udir/work"
  DUTY_DIR="$udir"; LOG_DIR="$udir/logs"; DUTY_TICK_ID="tick-usage"
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  BOT_CLI_CMD=(bash "$USAGE_CLI" -p)
  SESSION_CREDENTIAL_POOL="$pool"
  export USAGE_SHAPE="$shape" USAGE_ARGV="$udir/argv"
  run_session build fixture/usage "$udir/work" 5 theprompt \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  printf '%s\n' -- '--prose--'
  cat "$udir"/logs/*.log
  printf '%s\n' -- '--argv--'
  cat "$udir/argv"
)

usage_valid="$(usage_run shared-a valid)"
usage_end="$(grep 'SESSION END' <<<"$usage_valid")"
t usage-claude-profile-selects-json-output 1 \
  "$(sed -n '/^--argv--$/,$p' <<<"$usage_valid" | grep -c '^json$' || true)"
t usage-claude-session-records-input 120 \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-output 34 \
  "$(sed -n 's/.* output_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-cache-create 5 \
  "$(sed -n 's/.* cache_creation_input_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-cache-read 77 \
  "$(sed -n 's/.* cache_read_input_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-cost 0.0125 \
  "$(sed -n 's/.* cost_usd=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-session-id session%2Fone \
  "$(sed -n 's/.* session_id=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-structured-run-restores-the-prose-log 'I pushed the fix.' \
  "$(sed -n '/^--prose--$/{n;p;}' <<<"$usage_valid")"
t usage-structured-scratch-does-not-survive 0 \
  "$(find "$TMP" -name '*.structured' | wc -l)"

# Two independent directories stand in for two boxes: pool identity is the
# operator's declaration, not a session-local or box-local derivative.
usage_same="$(usage_run shared-a valid)"
usage_other="$(usage_run shared-b valid)"
t usage-same-pool-is-stable-across-boxes shared-a \
  "$(grep 'SESSION END' <<<"$usage_same" | sed -n 's/.* pool=\([^ ]*\).*/\1/p')"
t usage-different-pool-is-distinguishable shared-b \
  "$(grep 'SESSION END' <<<"$usage_other" | sed -n 's/.* pool=\([^ ]*\).*/\1/p')"

# Malformed accounting is absent, while the work's result, rc, outcome and
# prose survive. This is the failure direction the instrument must never own.
usage_bad="$(usage_run shared-a malformed)"
usage_bad_end="$(grep 'SESSION END' <<<"$usage_bad")"
t usage-malformed-block-does-not-fail-session '0|ok' \
  "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).*/\1|\2/p' <<<"$usage_bad_end")"
t usage-malformed-block-claims-no-input-token 0 \
  "$(grep -c ' input_tokens=' <<<"$usage_bad_end" || true)"
t usage-malformed-block-keeps-prose 'I pushed the fix.' \
  "$(sed -n '/^--prose--$/{n;p;}' <<<"$usage_bad")"

# A hookless profile is the exact old command/log/line shape: the existing
# budget golden below pins the whole line byte-for-byte; this focused case
# additionally proves no usage/pool field can appear merely because the
# engine learned the optional protocol.
usage_legacy="$(
  unset -f bot_cli_structured_cmd bot_cli_structured_prose bot_cli_usage 2>/dev/null || true
  SESSION_CREDENTIAL_POOL=""
  BOT_CLI_CMD=(bash -c 'printf "exec\nfinal reply\n"')
  # shellcheck disable=SC2317  # invoked indirectly through session_acted
  bot_session_acted() { grep -qx exec "$1"; }
  run_session build fixture/legacy "$SA_WORK" 5 prompt | tail -1
)"
t usage-hookless-profile-claims-no-accounting 0 \
  "$(grep -Ec ' (input_tokens|cost_usd|session_id|pool)=' <<<"$usage_legacy" || true)"

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

# The SECOND fixture is the first one's opposite, and it exists to pin what
# the walk cannot see. Its allocating descendant does not sleep: it exits the
# moment it has given the memory back, so its `mm` — and the `VmHWM` the
# kernel recorded in it — is torn down long before any read lands. The root
# then outlives several intervals, so the session IS measured; the figure is
# just the root's and the spike is not in it.
#
# This is the shape codex-bot-andresmgsl drove in round 1, and pinning it is
# the answer to that finding rather than a mechanism change: the limit was
# stated in `common/session.sh`'s prose and in the PR body, and prose is the
# weaker thing this suite keeps converting into an assertion. A ruling that
# moves the reader to `getrusage(RUSAGE_CHILDREN)` or to a per-session cgroup
# `memory.peak` — both of which retain an exited descendant — flips this case
# rather than passing quietly beside it, which is exactly what a limit ought
# to do when it stops being one.
PEAK_TRANSIENT_CLI="$TMP/peak-transient-cli.sh"
cat >"$PEAK_TRANSIENT_CLI" <<'STUB'
#!/usr/bin/env bash
python3 -c 'x = bytearray(256 * 1024 * 1024); del x'
sleep 7
printf 'exec\nfinal reply\n'
STUB
chmod +x "$PEAK_TRANSIENT_CLI"

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

  # THE LIMIT, asserted rather than promised. A five-second interval against a
  # descendant that lives well under one second is not a race the scheduler
  # can decide: the allocator is gone before the first read by two orders of
  # magnitude, so this reports the same thing on a loaded box as on an idle
  # one. Three claims, and the last two are why this is a limit and not a
  # defect — the session is still measured and its line is still sound.
  peak_gone="$(peak_run - 5 bash "$PEAK_TRANSIENT_CLI" 2>&1)"
  t peak-transient-descendant-is-missed TOO-SMALL \
    "$(peak_atleast 204800 "$(peak_of "$peak_gone")" | sed 's/(.*//')"
  t peak-transient-descendant-still-measures-the-root at-least \
    "$(peak_atleast 1 "$(peak_of "$peak_gone")")"
  t peak-transient-descendant-line-otherwise-unchanged '0|ok|yes' \
    "$(peak_rest "$peak_gone")"

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

  # Must fail (test plan, triage 2026-08-27): the field INSERTED ahead of
  # `acted=` instead of appended. This is the sharpest of the must-fails
  # because it does not look like a failure: `RE_END` ends in an OPTIONAL
  # `acted=… reply_tail=…` group, so the line still matches — the group simply
  # stops participating, and `acted` and `reply_tail` go silently missing from
  # every line the floor reads, on every box, for as long as nobody notices.
  # The mutation removes the appended field at the same time, so what is
  # measured is the POSITION and not the presence of a second token.
  # shellcheck disable=SC2016  # the sed matches the module's literal variables
  peak_mutant inserted-field \
    's/ acted=$acted/ peak_rss=999999 acted=$acted/; s/${peak_rss:+ peak_rss=$peak_rss}//'
  peak_mut_ins="$(peak_run "$TMP/session-mutant-inserted-field.sh" 30 \
    bash -c 'printf "exec\nfinal reply\n"' 2>&1)"
  t peak-mutation-inserted-field-drops-acted-and-reply-tail 'build|None|None' \
    "$(PEAK_END="$(grep 'SESSION END' <<<"$peak_mut_ins")" \
       python3 - "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-08-26T00:00:00Z " + os.environ["PEAK_END"])
# group(2) is the kind, which still matches; 7 and 8 are acted and reply_tail
# (units.py reads reply_tail as group(8)), and `None` is the whole finding —
# the line PARSED and lost two fields, which is why nothing would have caught
# this at the seam. A non-match would have been the safe failure.
print("|".join(str(g) for g in (m.group(2), m.group(7), m.group(8))) if m else "NO-MATCH")
PY
)"
fi

# --- D5: naming the session changed no dispatch guarantee (#473) ------------
#
# The walk needs a NAME for the session's tree before it can measure one, and
# `$!` is that name — so the dispatch is `( … ) &` plus a `wait` where it used
# to be a foreground list. D5 fences that: obtaining the name is in scope,
# changing what the line guarantees is not. Each case below is one of D5's
# properties, driven WITH the measurement live, because the claim is about the
# dispatch under the walk and not about the dispatch in isolation.
#
# `set -e` inside the runner is the point of three of them: the engine's ticks
# run under it, and the failure mode being excluded is a session ending a tick
# rather than reporting.
# shellcheck disable=SC2030,SC2031,SC2317
d5_run() ( # d5_run TMO CMD… — one dispatch, under the caller's `set -e`
  local tmo="$1"; shift
  local ddir="$TMP/d5-$RANDOM$RANDOM"
  mkdir -p "$ddir/logs" "$ddir/work"
  DUTY_DIR="$ddir"; LOG_DIR="$ddir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=("$@")
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  SESSION_PEAK_POLL_S=1
  set -e
  run_session build fixture/d5 "$ddir/work" "$tmo" theprompt
  # Reached only if a failing session did not abort its caller — which is the
  # whole of "RUN_SESSION_RC carries the status and run_session returns 0".
  printf 'reached=yes rc=%s\n' "$RUN_SESSION_RC"
)
d5_verdict() { sed -n 's/.*SESSION END .* rc=\([^ ]*\) dur=[^ ]* outcome=\([^ ]*\).*/\1|\2/p' <<<"$1"; }
d5_atmost() { # d5_atmost SECONDS OUTPUT — the dur= on the line, bounded
  local d; d="$(sed -n 's/.*SESSION END .* dur=\([0-9]*\)s .*/\1/p' <<<"$2")"
  case "$d" in
    '' | *[!0-9]*) printf 'NO-DURATION(%s)' "$d" ;;
    *) [ "$d" -le "$1" ] && printf 'at-most' || printf 'TOO-LATE(%s)' "$d" ;;
  esac
}

# A fired timeout, beside the walk. Both halves matter: the deadline still
# fires, and its 124 still reaches the line as TIMEOUT rather than as a
# FAILED with a strange rc.
d5_slow="$(d5_run 1 bash -c 'sleep 30' 2>&1)"
t d5-a-fired-timeout-still-reports-124-and-TIMEOUT '124|TIMEOUT' "$(d5_verdict "$d5_slow")"
# `timeout -k 60` is a SECOND deadline, and a dispatch that waited it out
# would report the same rc sixty seconds late. The session's own deadline is
# the one the engine budgets against, so the bound is on the clock, not the
# status.
t d5-the-timeout-is-not-delayed-past-its-own-deadline at-most "$(d5_atmost 10 "$d5_slow")"

# A failing session: its own rc, and no abort. `set -e` is live in d5_run, so
# `reached=yes` is not decoration — it is the assertion.
d5_fail="$(d5_run 30 bash -c 'printf "exec\nfinal reply\n"; exit 3' 2>&1)"
t d5-a-failing-sessions-rc-reaches-the-line '3|FAILED' "$(d5_verdict "$d5_fail")"
t d5-a-failing-session-cannot-abort-the-caller 'reached=yes rc=3' \
  "$(grep '^reached=' <<<"$d5_fail" || true)"

# The `</dev/null` defect, driven rather than trusted: the CLI reads piped
# stdin to EOF as context, and the caller's stdin here is a while-read work
# list. Without the redirection the FIRST session swallows the rest of the
# sweep and the loop runs once — the one-iteration-loop the module's comment
# records. The stub reads stdin exactly as a CLI would.
#
# What this asserts is D5's PROPERTY and deliberately not the line, and the
# distinction is load-bearing here rather than pedantic. Measured while
# writing this: bash redirects an ASYNC command's stdin from /dev/null of its
# own accord when job control is off, which is every script — so under
# `( … ) &` the work list is held by two mechanisms, and deleting the explicit
# `</dev/null` is not observable from here. Removing it anyway would be wrong
# (it is what the shape guarantees, not what today's bash happens to do for
# it), but a case claiming to catch that would be claiming something this
# suite cannot see, so this one claims what it can: the sweep survives the
# session, which is the guarantee D5 actually fences.
d5_items="$(printf 'a\nb\nc\n' | while read -r d5_item; do
  d5_run 10 bash -c 'cat >/dev/null; printf "exec\nfinal reply\n"' >/dev/null 2>&1
  printf '%s' "$d5_item"
done)"
t d5-the-session-does-not-swallow-the-callers-work-list abc "$d5_items"

# The process group, asserted as a DIFFERENTIAL — and the differential is the
# point, because the flat reading of D5 is false and was false before this
# issue existed. Measured: GNU `timeout` puts itself in a new process group
# (`setpgid(0,0)`, absent `--foreground`) and runs the CLI there, so the
# session has never sat in the engine's own group. Job control is off in a
# script, so `&` does not create a group and did not change this; `timeout`
# did, in both shapes.
#
# So what D5 fences — "a signal delivered to the engine reaches it exactly as
# it does today" — is a claim about SAMENESS, and the honest test runs both
# dispatch shapes against one stub and compares. The old shape is spelled out
# here rather than referenced, because the thing being compared against is the
# line as it stood before this change.
#
# `/proc` and not `ps`: after `) ` the fields are state, ppid, pgrp, so f3 is
# the group. The split is on `) ` because comm can contain spaces and
# parentheses. The GROUP LEADER is identified by name rather than by pid,
# because the leader's pid is the dispatch's own and the stub has no way to
# be told it — and `comm=timeout` is the fact the verdict actually rests on.
# (Not the stub's ppid: the reads run in a pipeline, so a CLI's ppid is its
# own shell, which says nothing about the group.)
D5_PG_STUB="$TMP/d5-pg-stub.sh"
cat >"$D5_PG_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 — where to write "<pgrp> <comm of that group's leader>"
pg="$(sed 's/.*) //' /proc/self/stat | cut -d' ' -f3)"
printf '%s %s\n' "$pg" "$(cat "/proc/$pg/comm" 2>/dev/null)" >"$1"
printf 'exec\nfinal reply\n'
STUB
chmod +x "$D5_PG_STUB"
d5_engine_pg="$(sed 's/.*) //' /proc/self/stat | cut -d' ' -f3)"
d5_pg_verdict() { # d5_pg_verdict "<pgrp> <leader comm>"
  local pg="${1%% *}" comm="${1##* }"
  [ -n "$1" ] || { printf 'NO-READING'; return; }
  [ "$pg" = "$d5_engine_pg" ] && { printf 'engines'; return; }
  [ "$comm" = timeout ] && printf 'its-own-timeouts' || printf 'SOME-OTHER-GROUP(%s)' "$comm"
}

d5_pg_new="$TMP/d5-pg-new"; rm -f "$d5_pg_new"
d5_run 10 bash "$D5_PG_STUB" "$d5_pg_new" >/dev/null 2>&1

# The dispatch exactly as it read before the measurement named it: a
# FOREGROUND list, same redirections, same `timeout -k`. Spelled out rather
# than referenced, because the thing under comparison is that old line.
d5_pg_old="$TMP/d5-pg-old"; rm -f "$d5_pg_old"
d5_oldwork="$TMP/d5-oldwork"; mkdir -p "$d5_oldwork"
( cd "$d5_oldwork" && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
    timeout -k 60 10 bash "$D5_PG_STUB" "$d5_pg_old" ) </dev/null >/dev/null 2>&1

t d5-the-dispatchs-process-group-is-what-it-was-before-the-name \
  "$(d5_pg_verdict "$(cat "$d5_pg_old" 2>/dev/null)")" \
  "$(d5_pg_verdict "$(cat "$d5_pg_new" 2>/dev/null)")"
# …and the shared value is named, so a run where BOTH shapes broke the same
# way cannot pass as agreement.
t d5-the-session-runs-in-its-own-timeouts-group its-own-timeouts \
  "$(d5_pg_verdict "$(cat "$d5_pg_new" 2>/dev/null)")"

# --- the memory ceiling (#474) ----------------------------------------------
#
# Two halves, and they fail differently. D1 (`oom_score_adj`) is asserted from
# INSIDE the CLI, because the claim is about the process the kernel will score
# and nothing the engine can observe from outside says which process that is.
# D2 (the ceiling) is asserted against a fixture that really allocates, because
# the failure being excluded is a session that keeps running.
#
# MemTotal is STUBBED in every driven case below, and that is the design rather
# than a shortcut. The ceiling is a percentage of the box, so a case that used
# the real MemTotal would have to allocate a percentage of whatever box the
# suite is on — gigabytes on a large runner, and a different figure on each.
# Stubbing the one function that reads `/proc/meminfo` fixes the ceiling at 64
# MiB everywhere; the read itself is asserted separately, against `/proc`.

# mem_run MUTANT|- POLL CONF CMD… — one dispatch under a memory ceiling. CONF
# is shell text eval'd in the runner: the conf keys, and the MemTotal stub.
# shellcheck disable=SC2030,SC2031,SC2317
mem_run() (
  local mutant="$1" poll="$2" conf="$3"; shift 3
  local mdir="$TMP/mem-$RANDOM$RANDOM"
  mkdir -p "$mdir/logs" "$mdir/work"
  DUTY_DIR="$mdir"; LOG_DIR="$mdir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=("$@")
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  # shellcheck disable=SC1090
  [ "$mutant" = - ] || source "$mutant"
  SESSION_PEAK_POLL_S="$poll"
  SESSION_MEM_KILL_GRACE_S=1
  eval "$conf"
  run_session build fixture/mem "$mdir/work" 60 theprompt
  # `reached=` is the assertion and not decoration: the must-fail this suite
  # owes is a ceiling that ends the ENGINE rather than the session, and the
  # engine here is this subshell. A line printed after run_session returned is
  # the only evidence that survives it.
  #
  # `terminal=` is the second: a session the ceiling killed is not a vendor
  # failure, so it must leave no per-lane terminal-breaker state behind.
  printf 'reached=yes rc=%s scratch=%s terminal=%s engine-adj=%s\n' \
    "$RUN_SESSION_RC" \
    "$(find "$mdir/logs" \( -name '*.peak' -o -name '*.mem' \) | wc -l | tr -d ' ')" \
    "$(find "$mdir" -name '.session-terminal.*' | wc -l | tr -d ' ')" \
    "$( { read -r a </proc/self/oom_score_adj; printf '%s' "$a"; } 2>/dev/null )"
)
mem_field() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2" | tail -1; }
mem_outcome() { sed -n 's/.*SESSION END .* outcome=\([^ ]*\).*/\1/p' <<<"$1"; }
mem_dur() { sed -n 's/.*SESSION END .* dur=\([0-9]*\)s .*/\1/p' <<<"$1"; }
mem_mutant() { # mem_mutant NAME SED-EXPR — mutate the module under test
  local out="$TMP/session-mem-mutant-$1.sh"
  sed "$2" "$SHARED/lib/common/session.sh" >"$out"
  if cmp -s "$out" "$SHARED/lib/common/session.sh"
  then t "mem-mutation-$1-applies" applied INERT
  else t "mem-mutation-$1-applies" applied applied; fi
}
# The stub every driven case shares: a 256 MiB box, so 25% is a 64 MiB ceiling
# and the allocating fixture below is four times over it.
MEM_STUB_CONF='_session_mem_total_kib() { printf 262144; }'

# --- D3: what the conf resolves to, before anything is dispatched -----------
#
# `_session_mem_pct` is the whole of the per-role rule, so it is asserted
# directly rather than inferred from a session's fate. Each case runs in its
# own subshell: these are conf variables, and one leaking into the next would
# make the suite's own order load-bearing.
mem_pct() ( eval "$1"; _session_mem_pct )
t mem-pct-unset-is-no-ceiling '' "$(mem_pct 'BOT_ROLES=builder')"
t mem-pct-zero-is-no-ceiling '' "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=0')"
t mem-pct-fleet-value-is-read 60 "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60')"
# The acceptance criterion, in the direction that actually distinguishes an
# override from a minimum: the role value wins even when it is LARGER.
t mem-pct-role-override-wins-downward 20 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60; SESSION_MEM_MAX_PCT_BUILDER=20')"
t mem-pct-role-override-wins-upward 70 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=20; SESSION_MEM_MAX_PCT_BUILDER=70')"
# A role this box does not carry says nothing about it.
t mem-pct-other-roles-override-is-not-read 60 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60; SESSION_MEM_MAX_PCT_TRIAGE=20')"
# BOT_ROLES is a list, and the box is one box: the tighter bound governs.
t mem-pct-multi-role-takes-the-tightest 30 \
  "$(mem_pct 'BOT_ROLES="builder reviewer"; SESSION_MEM_MAX_PCT_BUILDER=70; SESSION_MEM_MAX_PCT_REVIEWER=30')"
# …and 0 means "this role names no ceiling", never "this role forbids one".
t mem-pct-a-role-at-zero-does-not-disarm-a-sibling 30 \
  "$(mem_pct 'BOT_ROLES="builder reviewer"; SESSION_MEM_MAX_PCT_BUILDER=0; SESSION_MEM_MAX_PCT_REVIEWER=30')"
t mem-pct-a-non-numeric-override-is-ignored 60 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60; SESSION_MEM_MAX_PCT_BUILDER=half')"
t mem-pct-a-non-numeric-fleet-value-is-no-ceiling '' \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=most')"

# The conf file ships the mechanism OFF, which is the last acceptance
# criterion read at its source rather than through a dispatch.
t mem-conf-ships-every-value-off 0 \
  "$(grep -c '^SESSION_MEM_MAX_PCT\(_[A-Z]*\)\?=[^0]' "$SHARED/conf/fleet.defaults.conf" || true)"
t mem-conf-declares-a-row-per-shipped-role 3 \
  "$(grep -c '^SESSION_MEM_MAX_PCT_' "$SHARED/conf/fleet.defaults.conf" || true)"

# The MemTotal read, against `/proc` and not against a stub — the one case the
# stub above would otherwise hide.
t mem-total-matches-proc-meminfo \
  "$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)" "$(_session_mem_total_kib)"
mem_ceiling() ( eval "$1"; eval "$MEM_STUB_CONF"; _session_mem_ceiling_kib )
t mem-ceiling-is-a-percentage-of-memtotal 65536 \
  "$(mem_ceiling 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=25')"
t mem-ceiling-unconfigured-is-nothing '' "$(mem_ceiling 'BOT_ROLES=builder')"
# A percentage so small it rounds to nothing is nothing, never a ceiling of 0
# that every session is instantly over.
t mem-ceiling-rounding-to-zero-is-no-ceiling '' \
  "$(mem_ceiling 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=0')"

# --- the walk, and the process it must never return ------------------------
t mem-no-pids-from-a-dead-tree '' "$(_session_tree_pids 2147483647)"
t mem-no-pids-from-pid-one '' "$(_session_tree_pids 1)"
t mem-reader-refuses-a-missing-mark '' "$(session_mem_hit "$TMP/absent.mem")"
printf 'not-a-number\n' >"$TMP/bad.mem"
t mem-reader-refuses-a-non-integer '' "$(session_mem_hit "$TMP/bad.mem")"
printf '70000\n' >"$TMP/good.mem"
t mem-reader-reads-an-integer 70000 "$(session_mem_hit "$TMP/good.mem")"

# MUST FAIL (test plan): a ceiling that terminates the engine's own process
# rather than the session tree. Asserted at the guard that decides it and NOT
# by driving a mutant kill — a mutation that really signalled `$$` from inside
# a dispatch would take this suite's own shell down with it, so the case that
# proves the guard has to be the one that does not need it.
mem_self() { grep -c "\\b$$\\b" <<<" $(_session_tree_pids "$$") " || true; }
t mem-the-walk-never-returns-the-engines-own-pid 0 "$(mem_self)"
# shellcheck disable=SC2016  # the sed matches the module's literal guard
mem_mutant no-self-guard 's/^      \[ "\$pid" != "\$\$" \] || continue$//'
# shellcheck disable=SC1090,SC1091,SC2317
mem_self_mutant() ( source "$TMP/session-mem-mutant-no-self-guard.sh"; mem_self )
t mem-mutation-no-self-guard-returns-the-engine 1 "$(mem_self_mutant)"

# --- the containment identity: what the walk alone cannot hold (round 1) ----
#
# A pid walk is not a bound. A descendant that handles TERM by forking a
# replacement and exiting leaves that replacement reparented to PID 1, so it is
# in neither the pre-TERM snapshot (it did not exist) nor the post-grace re-walk
# (nothing rooted at the session reaches it) — the session's record says it was
# bounded while something holding its allocation runs on with no clock and no
# ceiling over it. That is the 2026-08-14 shape one level down, and it is what
# the session's own process group closes: `timeout` calls `setpgid(0,0)` absent
# `--foreground`, and a reparented child that never called `setsid()` never
# leaves the group it was forked into.

# The group read, first. The parse is past the LAST `)` because `comm` is
# parenthesised and may itself contain spaces and parentheses — the case below
# is a real process with a real name that a field-5-from-the-start parse gets
# wrong, not a synthetic string.
mem_pgid_naive() { awk '{ print $5 }' "/proc/$1/stat" 2>/dev/null; }
t mem-pgid-of-a-dead-pid-is-nothing '' "$(_session_proc_pgid 2147483647)"
sleep 30 & mem_plain_pid=$!
MEM_PAREN_BIN="$TMP/a (b) c"
cp "$(command -v sleep)" "$MEM_PAREN_BIN"
"$MEM_PAREN_BIN" 30 & mem_paren_pid=$!
# Both are background children of THIS shell, and job control is off in a
# script, so `&` creates no group: they are both in the suite's own group. That
# is the oracle — no external `ps` and no second copy of the parse.
t mem-pgid-agrees-with-a-naive-parse-on-a-plain-comm \
  "$(mem_pgid_naive "$mem_plain_pid")" "$(_session_proc_pgid "$mem_plain_pid")"
t mem-pgid-survives-parentheses-in-comm \
  "$(_session_proc_pgid "$mem_plain_pid")" "$(_session_proc_pgid "$mem_paren_pid")"
# …and the hazard is real rather than theoretical: the naive parse returns the
# STATE letter for this process, which is what shifting on the first `)` does.
mem_paren_naive_verdict() {
  [ "$(mem_pgid_naive "$mem_paren_pid")" = "$(_session_proc_pgid "$mem_paren_pid")" ] \
    && printf 'NAIVE-PARSE-WOULD-HAVE-DONE' || printf differs
}
t mem-pgid-a-naive-parse-is-what-this-avoids differs "$(mem_paren_naive_verdict)"
t mem-pgid-of-a-comm-with-parens-is-still-the-suites-group \
  "$(mem_pgid_naive "$mem_plain_pid")" "$(_session_proc_pgid "$mem_paren_pid")"
kill -KILL "$mem_plain_pid" "$mem_paren_pid" 2>/dev/null || :
wait "$mem_plain_pid" "$mem_paren_pid" 2>/dev/null || :

# The refusal, which is `_session_tree_pids`'s `$$` guard one level up and the
# more important of the two: a group kill aimed at the engine's group takes the
# engine, this watchdog and every sibling session with it.
mem_groups_of() { # mem_groups_of PIDS… — the group list, whitespace-normalised
  local -a g=()
  read -r -a g <<<"$(_session_mem_groups "$@")"
  printf '%s' "${g[*]-}"
}
t mem-the-groups-never-name-the-engines-own-group '' "$(mem_groups_of "$$")"
# A group that is NOT the engine's is named — otherwise the case above would
# pass on a function that always returns nothing. `timeout` puts itself in a
# group of its own with `setpgid(0,0)`, so the group id is its own pid: an
# expectation that does not go through the function under test.
timeout 30 sleep 30 & mem_tmo_pid=$!
sleep 0.5
t mem-a-group-outside-the-engines-is-named "$mem_tmo_pid" "$(mem_groups_of "$mem_tmo_pid")"
t mem-a-group-is-named-once-however-many-pids-sit-in-it "$mem_tmo_pid" \
  "$(mem_groups_of "$mem_tmo_pid" "$mem_tmo_pid" "$mem_tmo_pid")"
kill -KILL "$mem_tmo_pid" 2>/dev/null || :
wait "$mem_tmo_pid" 2>/dev/null || :
# MUST FAIL: the refusal removed. The mutation is the guard deleted, and under
# it the engine's own group is returned — the list a group kill is taken from.
# shellcheck disable=SC2016  # the sed matches the module's literal guard
mem_mutant no-group-self-guard 's/^    \[ "\$grp" != "\$self" \] || continue$//'
# shellcheck disable=SC1090,SC1091,SC2317
mem_group_self_mutant() (
  source "$TMP/session-mem-mutant-no-group-self-guard.sh"
  [ -n "$(_session_mem_groups "$$")" ] && printf RETURNS-THE-ENGINES-GROUP || printf refused
)
t mem-mutation-no-group-self-guard-returns-the-engines-group \
  RETURNS-THE-ENGINES-GROUP "$(mem_group_self_mutant)"

# The escape itself, driven end to end against `_session_mem_terminate`.
#
# Driven HERE rather than only through a dispatch, and the reason is coverage
# on every runner: the ceiling's own cases need a fixture that really allocates
# and so sit behind `python3`, while the defect this closes is about signals
# and not about memory at all. This case needs neither python3 nor a ceiling.
MEM_ESCAPE_STUB="$TMP/mem-escape-stub.sh"
cat >"$MEM_ESCAPE_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 — where to record the replacement's pid; $2 — the readiness file.
# The escape, exactly as both reviewers drove it: handle TERM by forking a
# replacement and exiting. The replacement is reparented to PID 1 the moment
# this shell goes, and it never calls setsid(), so the session's GROUP is the
# only identity that still holds it.
trap 'sleep 30 & printf "%s\n" "$!" >"$1"; exit 0' TERM
printf ready >"$2"
# `wait` and not a bare `sleep`: bash runs a trap when a foreground `wait` is
# interrupted, which is what makes the handler above reachable at all.
sleep 30 &
wait $!
STUB
# mem_escape MUTANT|- — start a session-shaped tree, terminate it, and say
# whether the replacement outlived the terminator. Prints the verdict.
# shellcheck disable=SC2030,SC2031,SC2317
mem_escape() (
  local pidfile="$TMP/escape-$RANDOM$RANDOM.pid" ready="$TMP/escape-$RANDOM$RANDOM.ready"
  local root rep i
  rm -f "$pidfile" "$ready"
  SESSION_MEM_KILL_GRACE_S=1
  # shellcheck disable=SC1090
  [ "$1" = - ] || source "$1"
  # The dispatch's own shape: `timeout` is the root, so the tree's group is the
  # one `timeout` made for itself — the same identity a real session has.
  timeout -k 60 30 bash "$MEM_ESCAPE_STUB" "$pidfile" "$ready" >/dev/null 2>&1 &
  root=$!
  for i in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.1; done
  [ -s "$ready" ] || { printf 'FIXTURE-NEVER-READY'; kill -KILL "$root" 2>/dev/null; return 0; }
  _session_mem_terminate "$root"
  wait "$root" 2>/dev/null || :
  rep="$(cat "$pidfile" 2>/dev/null)"
  case "$rep" in '' | *[!0-9]*) printf 'NO-REPLACEMENT-FORKED(%s)' "$rep"; return 0 ;; esac
  if kill -0 "$rep" 2>/dev/null; then
    kill -KILL "$rep" 2>/dev/null || :
    printf 'SURVIVED'
  else
    printf reaped
  fi
)
t mem-a-term-handler-that-forks-does-not-outlive-the-terminator reaped "$(mem_escape -)"
# MUST FAIL (round 1): the group pass removed. One line — the collector made to
# return nothing — which is "forgetting the group" in its smallest form, and
# under it the very same replacement survives the terminator. This is the case
# that reds against the head this round was opened on.
# shellcheck disable=SC2016  # the sed matches the module's literal assignment
mem_mutant no-group-pass 's/^  self="\$(_session_proc_pgid "\$\$")"$/  return 0/'
t mem-mutation-no-group-pass-lets-the-replacement-survive SURVIVED \
  "$(mem_escape "$TMP/session-mem-mutant-no-group-pass.sh")"

# The grace between TERM and KILL is validated like every other numeric in the
# module. An unvalidated one makes `sleep` fail instantly and collapses the
# grace to zero, landing TERM and KILL back to back — which defeats the one
# reason TERM goes first, letting the CLI flush the transcript this outcome is
# going to be read against.
mem_grace() ( eval "$1"; _session_mem_kill_grace_s )
t mem-grace-unset-is-the-default 5 "$(mem_grace 'unset SESSION_MEM_KILL_GRACE_S')"
t mem-grace-a-configured-value-is-read 2 "$(mem_grace 'SESSION_MEM_KILL_GRACE_S=2')"
t mem-grace-a-non-numeric-value-is-the-default 5 \
  "$(mem_grace 'SESSION_MEM_KILL_GRACE_S=soon')"
t mem-grace-an-empty-value-is-the-default 5 "$(mem_grace 'SESSION_MEM_KILL_GRACE_S=')"

# Armed but no bound applied: the operator is TOLD. The three shapes are
# separated from the unconfigured SILENCE, which is an acceptance criterion —
# reading only the resolved ceiling made "armed but unresolvable" and "not
# armed" the same answer, so the procfs-less guest the comment named was
# exactly the case that got no warning.
# shellcheck disable=SC2317
mem_start_warn() ( # mem_start_warn CONF — the warn line, if any
  # Measurable by default, so a case that is not about measurability does not
  # have to say so; CONF is eval'd after, and may take it away.
  _SESSION_PEAK_PID=1
  eval "$1"
  _session_mem_watch_start "$TMP/absent.peak" "$TMP/warn-$RANDOM.mem" 2147483647 build 2>&1 \
    | sed -n 's/.*\(session memory: .*\)/\1/p'
)
t mem-armed-but-no-memtotal-is-warned \
  'session memory: kind=build a ceiling of 25% is configured but this box'"'"'s MemTotal is unreadable — no memory bound applied' \
  "$(mem_start_warn 'SESSION_MEM_MAX_PCT=25; _session_mem_total_kib() { :; }')"
t mem-armed-but-unmeasurable-is-warned 1 \
  "$(mem_start_warn "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF; _SESSION_PEAK_PID=''" \
     | grep -c 'this session is not measurable' || true)"
t mem-armed-but-rounding-to-nothing-is-warned 1 \
  "$(mem_start_warn 'SESSION_MEM_MAX_PCT=1; _session_mem_total_kib() { printf 10; }' \
     | grep -c 'rounds to nothing' || true)"
# …and the silence, which is the acceptance criterion the warn must not eat.
t mem-unconfigured-warns-about-nothing '' \
  "$(mem_start_warn 'SESSION_MEM_MAX_PCT=0; _session_mem_total_kib() { :; }')"

# --- D1: oom_score_adj, read from inside the CLI ---------------------------
#
# The AC is about the process the kernel will score at the moment the CLI is
# `exec`'d, and only that process can say what its own adjustment is. The stub
# reads its own `/proc/self/oom_score_adj` — after the exec, in the process
# that will be doing the allocating.
OOM_STUB="$TMP/oom-stub.sh"
cat >"$OOM_STUB" <<'STUB'
#!/usr/bin/env bash
{ read -r adj </proc/self/oom_score_adj; } 2>/dev/null || adj=UNREADABLE
printf '%s\n' "$adj" >"$1"
printf 'exec\nfinal reply\n'
STUB
chmod +x "$OOM_STUB"
mem_oom_out="$TMP/oom-adj"; rm -f "$mem_oom_out"
mem_oom_run="$(mem_run - 30 '' bash "$OOM_STUB" "$mem_oom_out" 2>&1)"
mem_cli_adj="$(cat "$mem_oom_out" 2>/dev/null)"
mem_engine_adj="$(mem_field engine-adj "$mem_oom_run")"
mem_adj_verdict() { # mem_adj_verdict CLI ENGINE
  case "$1" in '' | *[!0-9-]*) printf 'NO-READING(%s)' "$1"; return ;; esac
  case "$2" in '' | *[!0-9-]*) printf 'NO-ENGINE-READING(%s)' "$2"; return ;; esac
  [ "$1" -gt "$2" ] || { printf 'NOT-ABOVE-ENGINE(%s<=%s)' "$1" "$2"; return; }
  # `cron` and `sshd` run at the kernel default, so clearing 0 is what the AC's
  # other two names come to. Read as a value rather than by probing their pids:
  # neither is guaranteed to be running on a box, and a case that silently
  # skips itself proves nothing.
  [ "$1" -gt 0 ] && printf 'above-engine-and-default' \
    || printf 'NOT-ABOVE-DEFAULT(%s)' "$1"
}
t mem-oom-adj-is-raised-on-the-process-that-execs-the-cli above-engine-and-default \
  "$(mem_adj_verdict "$mem_cli_adj" "$mem_engine_adj")"
t mem-oom-arming-does-not-disturb-the-session '0|ok|yes' "$(peak_rest "$mem_oom_run")"

# MUST FAIL (test plan): `oom_score_adj` set on the engine instead of on the
# child. The mutation hoists the arm out of the dispatch subshell, which is the
# single most plausible way to write this wrong — it still runs before the CLI,
# it still raises an adjustment the CLI inherits, and the only thing that moves
# is WHOSE. So the verdict cannot be "is the CLI raised": it is whether the CLI
# sits ABOVE the engine or merely level with it, which is the difference
# between the kernel preferring the session and the kernel preferring both.
# shellcheck disable=SC2016  # the sed matches the module's literal dispatch
mem_mutant oom-on-the-engine \
  's/^  ( cd "\$dir" \&\& _session_oom_arm \&\& env /  _session_oom_arm; ( cd "$dir" \&\& env /'
rm -f "$mem_oom_out"
mem_oom_mut="$(mem_run "$TMP/session-mem-mutant-oom-on-the-engine.sh" 30 '' \
  bash "$OOM_STUB" "$mem_oom_out" 2>&1)"
t mem-mutation-oom-on-the-engine-leaves-the-cli-level-with-it \
  NOT-ABOVE-ENGINE \
  "$(mem_adj_verdict "$(cat "$mem_oom_out" 2>/dev/null)" \
       "$(mem_field engine-adj "$mem_oom_mut")" | sed 's/(.*//')"

# --- D2/D4: the ceiling fires, and what it leaves behind -------------------
#
# The fixture HOLDS its allocation rather than releasing it: the case is a
# runaway that is still growing, which is the only shape a ceiling can act on.
# Its sleep is long enough that a session reaching the end of it has not been
# terminated at all — the duration bound below is what turns that into a
# verdict rather than a slow pass.
MEM_CLI="$TMP/mem-cli.sh"
cat >"$MEM_CLI" <<'STUB'
#!/usr/bin/env bash
python3 -c '
import time
x = bytearray(256 * 1024 * 1024)
time.sleep(30)
'
printf 'exec\nfinal reply\n'
STUB
chmod +x "$MEM_CLI"

# A session UNDER the ceiling, with the ceiling armed: the acceptance criterion
# that the bound is not felt by the sessions it does not bind.
mem_under="$(mem_run - 1 "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF" \
  bash -c 'sleep 3; printf "exec\nfinal reply\n"' 2>&1)"
t mem-a-session-under-the-ceiling-is-untouched '0|ok|yes' "$(peak_rest "$mem_under")"
t mem-a-session-under-the-ceiling-says-nothing 0 \
  "$(grep -c 'session memory:' <<<"$mem_under" || true)"

if command -v python3 >/dev/null 2>&1; then
  mem_hit="$(mem_run - 1 "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  t mem-crossing-the-ceiling-carries-its-own-outcome MEMORY "$(mem_outcome "$mem_hit")"
  # The kill, and not merely the label: the fixture sleeps 30s, so a session
  # that ran to its own end would report a duration near it.
  mem_killed() {
    local d; d="$(mem_dur "$1")"
    case "$d" in
      '' | *[!0-9]*) printf 'NO-DURATION(%s)' "$d" ;;
      *) [ "$d" -le 20 ] && printf terminated || printf 'RAN-TO-COMPLETION(%ss)' "$d" ;;
    esac
  }
  t mem-crossing-the-ceiling-terminates-the-session terminated "$(mem_killed "$mem_hit")"
  # The engine survives it, which is the other half of the incident: on
  # 2026-08-14 the kernel took a process out of the session's tree and the box
  # stayed down. `reached=yes` is printed after run_session returned.
  t mem-the-engine-survives-the-kill 'reached=yes' \
    "$(grep -o 'reached=yes' <<<"$mem_hit" || true)"
  # (c) logs WHY before it acts — the property it was ruled over (a) and (b)
  # for. The figure and the ceiling are both on the line.
  t mem-the-kill-is-logged-with-both-figures 1 \
    "$(grep -c 'session memory: kind=build reached [0-9]* KiB against a ceiling of 65536 KiB' <<<"$mem_hit" || true)"
  # The scratch files are the session's, not the log directory's — the `.mem`
  # marker joins `.peak` under that rule.
  t mem-scratch-files-do-not-outlive-the-session 0 "$(mem_field scratch "$mem_hit")"
  # The peak that crossed is still reported: this session is measured like any
  # other, and the figure on the line is the evidence for the outcome beside it.
  t mem-the-crossing-figure-is-still-on-the-line at-least \
    "$(peak_atleast 65536 "$(peak_of "$mem_hit")")"

  # D4's other half: a memory kill is not a VENDOR failure. With a terminal
  # hook that says yes to everything, the old ordering would have classified
  # this TERMINAL and fed the per-lane breaker — stopping a lane for a reason
  # the vendor had nothing to do with.
  mem_term="$(mem_run - 1 \
    "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF; bot_session_terminal() { return 0; }" \
    bash "$MEM_CLI" 2>&1)"
  t mem-a-kill-is-not-a-vendor-terminal MEMORY "$(mem_outcome "$mem_term")"
  t mem-a-kill-feeds-no-terminal-breaker-state 0 "$(mem_field terminal "$mem_term")"

  # MUST FAIL (test plan): an unconfigured ceiling changing any behaviour. The
  # mutation is the one-character version of forgetting the guard — an unarmed
  # ceiling defaulting to a number instead of to nothing — and under it the
  # very same unconfigured run is killed. It targets the PERCENTAGE guard since
  # round 1 split the armed-but-unresolvable warn out of it: that guard is now
  # the one place "nothing is configured" is decided, so it is the one place
  # forgetting it can be written.
  # shellcheck disable=SC2016  # the sed matches the module's literal guard
  mem_mutant unconfigured-arms 's/^  \[ -n "\$pct" \] || return 0$/  pct="${pct:-1}"/'
  mem_unconf_ctl="$(mem_run - 1 "$MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  mem_unconf_mut="$(mem_run "$TMP/session-mem-mutant-unconfigured-arms.sh" 1 \
    "$MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  t mem-unconfigured-is-exactly-todays-behaviour ok "$(mem_outcome "$mem_unconf_ctl")"
  t mem-unconfigured-starts-no-watchdog 0 \
    "$(grep -c 'session memory:' <<<"$mem_unconf_ctl" || true)"
  t mem-mutation-unconfigured-arms-kills-an-unbounded-session MEMORY \
    "$(mem_outcome "$mem_unconf_mut")"

  # MUST FAIL (test plan, triage 2026-08-27): a change that lets
  # `_session_peak_rss_watch` end a session. This is #473's D4 as landed, and
  # the reason this issue's watchdog is a third process rather than a branch
  # inside that one. Driven with NO ceiling configured, so what the mutation
  # demonstrates is the measurement killing on its own account.
  # shellcheck disable=SC2016  # the sed matches the module's literal assignment
  mem_mutant measurement-kills 's/^      hwm="\$v"$/      hwm="$v"; kill -TERM "$root"/'
  mem_meas_mut="$(mem_run "$TMP/session-mem-mutant-measurement-kills.sh" 1 \
    "$MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  mem_meas_verdict() {
    case "$(mem_outcome "$1")" in
      ok) printf untouched ;;
      *) printf 'ENDED-BY-THE-MEASUREMENT(%s)' "$(mem_outcome "$1")" ;;
    esac
  }
  t mem-the-measurement-does-not-end-a-session untouched "$(mem_meas_verdict "$mem_unconf_ctl")"
  t mem-mutation-measurement-kills-ends-the-session ENDED-BY-THE-MEASUREMENT \
    "$(mem_meas_verdict "$mem_meas_mut" | sed 's/(.*//')"
fi

# …and the same must-fail read structurally, which holds on a box with no
# python3 and states the constraint rather than one of its consequences: every
# `kill` inside the measurement is a liveness probe. `kill -0` is the loop's
# own condition; anything else in there would be the measurement acting.
mem_watch_signals() {
  local body; body="$(declare -f _session_peak_rss_watch)"
  printf '%s' "$(( $(grep -c 'kill' <<<"$body" || true) \
                  - $(grep -c 'kill -0' <<<"$body" || true) ))"
}
t mem-the-measurement-only-ever-probes-liveness 0 "$(mem_watch_signals)"
t mem-the-measurement-does-not-reach-the-terminator 0 \
  "$(declare -f _session_peak_rss_watch | grep -c '_session_mem_terminate' || true)"

suite_finish
