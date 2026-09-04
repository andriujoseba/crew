#!/usr/bin/env bash
# shared/test/conf.sh — standalone conf subject suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
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
# Shared installer fixture used by the configuration and profile cases below.
ISHIM="$TMP/install-bin"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM"
for cmd in awk bash basename cat chmod cp date dirname env find grep head mkdir mktemp mv readlink rm sed sha256sum sort tail tr wc xargs; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
# shellcheck disable=SC2016  # expanded when the fixture shim runs
printf '#!/usr/bin/env bash\n[ "${FIXTURE_GITLESS:-0}" != 1 ] || exit 1\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
chmod +x "$ISHIM/gh" "$ISHIM/git"

# --- agent profiles and rehearsal selection -----------------------------
for profile in "$SHARED"/conf/agents/*.conf; do
  agent="$(basename "$profile" .conf)"
  if bash -c '. "$1"; type bot_cli_probe >/dev/null; test -n "$AGENT_LOGIN_HINT"' _ "$profile"; then
    r1=sourceable
  else
    r1=broken
  fi
  t "agent-conf-$agent-standalone" sourceable "$r1"
  profile_login_hints="$(sed -n '/^AGENT_LOGIN_HINT=.*${/p' "$profile")"
  if grep -q . <<<"$profile_login_hints"; then
    r1=deferred
  else
    r1=literal
  fi
  t "agent-conf-$agent-login-hint-literal" literal "$r1"
done

# Structured session output is profile-owned (#475): profiles with an observed
# vendor shape declare all three hooks; the remaining profiles stay on
# BOT_CLI_CMD byte-for-byte.
for agent in claude codex; do
  if bash -c '. "$1"; declare -F bot_cli_structured_cmd >/dev/null; declare -F bot_cli_structured_prose >/dev/null; declare -F bot_cli_usage >/dev/null' \
      _ "$SHARED/conf/agents/$agent.conf"; then r1=declared; else r1=MISSING; fi
  t "$agent-profile-declares-structured-session-output" declared "$r1"
done
for agent in grok kimi; do
  if bash -c '. "$1"; declare -F bot_cli_structured_cmd >/dev/null' \
      _ "$SHARED/conf/agents/$agent.conf"; then r1=UNEXPECTED; else r1=absent; fi
  t "$agent-profile-does-not-guess-structured-output" absent "$r1"
done

# Codex 0.146.0 emits JSONL and writes its final answer separately. The stub
# reproduces the observed command/message/usage event shapes and plants an
# earlier usage-shaped object that must not be selected or accumulated. Its
# guarded file_change event is a defensive vendor-schema fixture, not part of
# the read-only credentialed observation recorded for #570 D2-D4.
CODEX_USAGE_CLI="$TMP/codex-usage-cli.sh"
cat >"$CODEX_USAGE_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CODEX_USAGE_ARGV"
prose=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message)
      prose="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done
[ -n "$prose" ] || exit 2
if [ "${CODEX_USAGE_FAIL_BEFORE_PROSE:-0}" = 1 ]; then
  printf '%s\n' \
    '{"type":"item.started","item":{"type":"command_execution","command":"/bin/bash -lc false","status":"in_progress"}}' \
    '{"type":"item.completed","item":{"type":"command_execution","command":"/bin/bash -lc false","aggregated_output":"permission denied\n","exit_code":1,"status":"failed"}}' \
    '{"type":"error","message":"stream error: unexpected status 401 Unauthorized"}'
  exit 1
fi
printf 'observation complete.\n' >"$prose"
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thread/one"}' \
  '{"type":"turn.started"}' \
  '{"type":"item.completed","item":{"type":"agent_message","text":"checking"},"usage":{"input_tokens":999,"output_tokens":999}}' \
  '{"type":"item.started","item":{"type":"command_execution","command":"/bin/bash -lc pwd","status":"in_progress"}}' \
  '{"type":"item.completed","item":{"type":"command_execution","command":"/bin/bash -lc pwd","aggregated_output":"/work\n","exit_code":0,"status":"completed"}}' \
  '{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"shared/example.txt","kind":"update"}],"status":"completed"}}' \
  '{"type":"item.completed","item":{"type":"agent_message","text":"observation complete."}}' \
  '{"type":"turn.completed","usage":{"input_tokens":30302,"cached_input_tokens":25088,"cache_write_input_tokens":0,"output_tokens":91,"reasoning_output_tokens":7}}'
STUB
chmod +x "$CODEX_USAGE_CLI"

codex_usage_run() (
  local fail_before_prose="${1:-0}"
  local udir="$TMP/codex-usage-$RANDOM"
  mkdir -p "$udir/logs" "$udir/work" "$udir/tmp"
  DUTY_DIR="$udir"; LOG_DIR="$udir/logs"; DUTY_TICK_ID=codex-usage
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/codex.conf"
  BOT_CLI_CMD=(bash "$CODEX_USAGE_CLI")
  SESSION_CREDENTIAL_POOL=codex-pool
  TMPDIR="$udir/tmp"
  CODEX_USAGE_ARGV="$udir/argv"
  CODEX_USAGE_FAIL_BEFORE_PROSE="$fail_before_prose"
  export CODEX_USAGE_ARGV CODEX_USAGE_FAIL_BEFORE_PROSE TMPDIR
  run_session build fixture/codex "$udir/work" 5 'the prompt' \
    2>&1 | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  printf '%s\n' -- '--prose--'
  cat "$udir"/logs/*.log
  printf '%s\n' -- '--argv--'
  sed -E 's#^.*/crew-codex-prose\.[^/ ]+$#<prose-path>#' "$udir/argv"
  printf '%s\n' -- '--profile-scratch--'
  find "$udir/tmp" -maxdepth 1 -type f -name 'crew-codex-prose.*' | wc -l
)

codex_usage="$(codex_usage_run)"
codex_usage_end="$(grep 'SESSION END' <<<"$codex_usage")"
t codex-structured-command-selects-json 1 \
  "$(sed -n '/^--argv--$/,/^--profile-scratch--$/p' <<<"$codex_usage" | grep -c '^--json$' || true)"
t codex-structured-command-selects-separate-prose '<prose-path>' \
  "$(sed -n '/^--argv--$/,/^--profile-scratch--$/p' <<<"$codex_usage" | sed -n '/^--output-last-message$/{n;p;}')"
t codex-structured-command-keeps-prompt-last 'the prompt' \
  "$(sed -n '/^--output-last-message$/{n;n;p;}' <<<"$codex_usage")"
t codex-multi-event-stream-selects-completed-turn '5214|91|25088|0' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* output_tokens=\([^ ]*\).* cache_creation_input_tokens=\([^ ]*\).* cache_read_input_tokens=\([^ ]*\).*/\1|\2|\4|\3/p' <<<"$codex_usage_end")"
t codex-session-records-thread-identity thread%2Fone \
  "$(sed -n 's/.* session_id=\([^ ]*\).*/\1/p' <<<"$codex_usage_end")"
t codex-unnamed-model-is-honest unknown \
  "$(sed -n 's/.* model=\([^ ]*\).*/\1/p' <<<"$codex_usage_end")"
t codex-costless-session-keeps-cost-absent 0 \
  "$(grep -c ' cost_usd=' <<<"$codex_usage_end" || true)"
t codex-structured-run-restores-prose-unchanged 'observation complete.' \
  "$(sed -n '/^--prose--$/,/^--argv--$/p' <<<"$codex_usage" \
    | grep -vE '^--(prose|argv)--$|^--$' | tail -n 1)"
t codex-structured-run-preserves-human-transcript \
  'checking|exec /bin/bash -lc pwd|/work|command status=completed exit_code=0|apply_patch shared/example.txt|file_change update shared/example.txt' \
  "$(sed -n '/^--prose--$/,/^--argv--$/p' <<<"$codex_usage" \
    | grep -E '^(checking|exec |/work$|command status=|apply_patch |file_change )' \
    | paste -sd '|')"
t codex-structured-run-reports-acted yes \
  "$(sed -n 's/.* acted=\([^ ]*\).*/\1/p' <<<"$codex_usage_end")"
t codex-structured-run-hides-json-envelope 0 \
  "$(sed -n '/^--prose--$/,/^--argv--$/p' <<<"$codex_usage" | grep -c '^{' || true)"
t codex-profile-prose-scratch-is-removed 0 \
  "$(sed -n '/^--profile-scratch--$/{n;p;}' <<<"$codex_usage")"

codex_failed_usage="$(codex_usage_run 1)"
t codex-empty-prose-preserves-activity-marker 'yes|exec /bin/bash -lc false' \
  "$(printf '%s|' "$(grep 'SESSION END' <<<"$codex_failed_usage" | sed -n 's/.* acted=\([^ ]*\).*/\1/p')"; \
     sed -n '/^--prose--$/{n;p;}' <<<"$codex_failed_usage")"
t codex-empty-prose-preserves-command-result 'permission denied|command status=failed exit_code=1' \
  "$(sed -n '/^--prose--$/,/^--argv--$/p' <<<"$codex_failed_usage" \
    | grep -E '^(permission denied|command status=)' | paste -sd '|')"
t codex-empty-prose-preserves-structured-diagnostic 1 \
  "$(sed -n '/^--prose--$/,/^--argv--$/p' <<<"$codex_failed_usage" | grep -c '^{"type":"error"' || true)"
t codex-empty-prose-reports-failed FAILED \
  "$(grep 'SESSION END' <<<"$codex_failed_usage" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p')"
t codex-empty-prose-scratch-is-removed 0 \
  "$(sed -n '/^--profile-scratch--$/{n;p;}' <<<"$codex_failed_usage")"

CODEX_OBSERVED="$TMP/codex-observed.jsonl"
cat >"$CODEX_OBSERVED" <<'JSONL'
{"type":"thread.started","thread_id":"thread/one"}
{"type":"turn.started"}
{"type":"item.completed","usage":{"input_tokens":999,"output_tokens":999}}
{"type":"turn.completed","usage":{"input_tokens":30302,"cached_input_tokens":25088,"cache_write_input_tokens":0,"output_tokens":91,"reasoning_output_tokens":7}}
JSONL
# shellcheck disable=SC1091
codex_normalized="$({ source "$SHARED/conf/agents/codex.conf"; bot_cli_usage "$CODEX_OBSERVED"; })"
t codex-profile-carries-reasoning-separately '91|7' \
  "$(jq -r '[.output_tokens, .reasoning_output_tokens] | join("|")' <<<"$codex_normalized")"
t codex-profile-normalized-object-never-invents-cost false \
  "$(jq -r 'has("cost_usd")' <<<"$codex_normalized")"

CODEX_NO_CACHE="$TMP/codex-no-cache.jsonl"
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thread/uncached"}' \
  '{"type":"turn.completed","usage":{"input_tokens":500,"output_tokens":91}}' \
  >"$CODEX_NO_CACHE"
# shellcheck disable=SC1091
codex_no_cache="$({ source "$SHARED/conf/agents/codex.conf"; bot_cli_usage "$CODEX_NO_CACHE"; })"
t codex-profile-treats-absent-cache-as-zero '500|0' \
  "$(jq -r '[.input_tokens, .cache_read_input_tokens] | join("|")' <<<"$codex_no_cache")"

CODEX_BAD_CACHE="$TMP/codex-bad-cache.jsonl"
printf '%s\n' \
  '{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":"0","output_tokens":91}}' \
  >"$CODEX_BAD_CACHE"
# shellcheck disable=SC1091
t codex-profile-refuses-malformed-cache 0 \
  "$({ source "$SHARED/conf/agents/codex.conf"; bot_cli_usage "$CODEX_BAD_CACHE"; } | wc -l)"

CODEX_TWO_TURNS="$TMP/codex-two-turns.jsonl"
cat "$CODEX_OBSERVED" "$CODEX_OBSERVED" >"$CODEX_TWO_TURNS"
# shellcheck disable=SC1091
t codex-profile-refuses-more-than-one-completed-turn 0 \
  "$({ source "$SHARED/conf/agents/codex.conf"; bot_cli_usage "$CODEX_TWO_TURNS"; } | wc -l)"
# --- kimi: usage read from the session artifact (#571) --------------------
#
# kimi-cli 1.50.0 reports no usage on stdout — `--output-format stream-json`
# must be combined with `--print`, which the fleet's invocation does not pass,
# and its JsonPrinter has no usage branch on any path. The figures are in the
# session's own `wire.jsonl`, under `<share>/sessions/<work-dir hash>/<session
# id>/`. The stub below reproduces the observed launch: it takes the pinned id
# off its own argv and writes the artifact where the CLI writes it.
#
# THE RECORDS ARE VENDOR-SERIALIZED, not transcribed. Every StatusUpdate line
# was produced by kimi's own models at 1.50.0 —
# `WireMessageRecord.from_wire_message(StatusUpdate(token_usage=TokenUsage(…)))`
# — and pasted verbatim, so the field spellings and the null-filled siblings
# are the vendor's by construction rather than by my typing. The metadata
# header and the TurnBegin/TurnEnd pair are from the credential-less session
# observed on this box and recorded on the PR.
KIMI_USAGE_CLI="$TMP/kimi-usage-cli.sh"
cat >"$KIMI_USAGE_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$KIMI_USAGE_ARGV"
sid='' prev=''
for a in "$@"; do
  [ "$prev" = --session ] && { sid="$a"; break; }
  prev="$a"
done
# No pin, no artifact: the CLI would mint its own id and write somewhere this
# fleet cannot name, which is the case the profile must report as absent.
if [ -n "$sid" ] && [ "${KIMI_USAGE_SHAPE:-full}" != nofile ]; then
  dir="$KIMI_SHARE_DIR/sessions/${KIMI_USAGE_HASH:-8331003854c45d801e9c7516a9cf2092}/$sid"
  mkdir -p "$dir"
  {
    printf '%s\n' '{"type": "metadata", "protocol_version": "1.10"}'
    printf '%s\n' '{"timestamp":1788415586.16,"message":{"type":"TurnBegin","payload":{"user_input":"the prompt"}}}'
    case "${KIMI_USAGE_SHAPE:-full}" in
      full)
        printf '%s\n' '{"timestamp":1788415586.2,"message":{"type":"StatusUpdate","payload":{"context_usage":null,"context_tokens":null,"max_context_tokens":null,"token_usage":{"input_other":1200,"output":340,"input_cache_read":25088,"input_cache_creation":64},"message_id":null,"plan_mode":null,"mcp_status":null}}}'
        printf '%s\n' '{"timestamp":1788415587.0,"message":{"type":"StatusUpdate","payload":{"context_usage":0.31,"context_tokens":null,"max_context_tokens":null,"token_usage":null,"message_id":null,"plan_mode":null,"mcp_status":null}}}'
        printf '%s\n' '{"timestamp":1788415588.4,"message":{"type":"StatusUpdate","payload":{"context_usage":null,"context_tokens":null,"max_context_tokens":null,"token_usage":{"input_other":37,"output":512,"input_cache_read":26240,"input_cache_creation":0},"message_id":null,"plan_mode":null,"mcp_status":null}}}'
        printf '%s\n' '{"timestamp":1788415591.1,"message":{"type":"StatusUpdate","payload":{"context_usage":null,"context_tokens":null,"max_context_tokens":null,"token_usage":{"input_other":9,"output":88,"input_cache_read":0,"input_cache_creation":0},"message_id":null,"plan_mode":null,"mcp_status":null}}}'
        ;;
      nocache)
        # Defensive vendor-schema fixture: the two cache counters carry model
        # defaults of 0, so a record that omits them is a real zero.
        printf '%s\n' '{"timestamp":1788415586.2,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":500,"output":91}}}}'
        ;;
      badfield)
        printf '%s\n' '{"timestamp":1788415586.2,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":"many","output":91,"input_cache_read":0,"input_cache_creation":0}}}}'
        ;;
      garbage)
        printf '%s\n' 'not json at all'
        ;;
      nostatus) : ;;   # the observed credential-less session: no usage record
    esac
    printf '%s\n' '{"timestamp":1788415592.0,"message":{"type":"TurnEnd","payload":{}}}'
  } >"$dir/wire.jsonl"
  [ "${KIMI_USAGE_UNREADABLE:-0}" != 1 ] || chmod 000 "$dir/wire.jsonl"
fi
printf 'Used Shell (ls)\nthe answer.\n'
STUB
chmod +x "$KIMI_USAGE_CLI"

kimi_usage_run() ( # kimi_usage_run SHAPE [decoy]
  local shape="${1:-full}" mode="${2:-}"
  local udir="$TMP/kimi-usage-$shape-$RANDOM"
  mkdir -p "$udir/logs" "$udir/work" "$udir/share"
  DUTY_DIR="$udir"; LOG_DIR="$udir/logs"; DUTY_TICK_ID=kimi-usage
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  # Ends in `--afk -p`, mirroring the real invocation, because the splice site
  # is defined by that trailing `-p` — a stub command that did not carry one
  # would take the pin on the end and make the adjacency assertion below
  # vacuous, which is exactly how it was first written.
  BOT_CLI_CMD=(bash "$KIMI_USAGE_CLI" --afk -p)
  SESSION_CREDENTIAL_POOL=kimi-pool
  KIMI_USAGE_ARGV="$udir/argv"
  KIMI_USAGE_SHAPE="$shape"
  KIMI_USAGE_UNREADABLE="${KIMI_USAGE_UNREADABLE:-0}"
  export KIMI_USAGE_ARGV KIMI_USAGE_SHAPE KIMI_USAGE_UNREADABLE
  # Subshell-local on purpose: each dispatch gets its own artifact root, so
  # one case's decoys cannot reach another's read.
  # shellcheck disable=SC2030
  export KIMI_SHARE_DIR="$udir/share"
  # A decoy: another session's artifact, carrying different figures, and made
  # the NEWEST wire.jsonl on disk so that selecting by mtime really would take
  # it (#571 D4). The mtime is what a wrong reader would sort on, and it is
  # forced here rather than inherited: these files are written BEFORE
  # run_session, so without the touch this session's own artifact is the
  # newest and the mtime mutation would be tested against nothing. The
  # `timestamp` INSIDE the record is a different thing entirely and no reader
  # here consults it.
  # Planted twice: once under a DIFFERENT work dir, and once as a sibling in
  # THIS session's own work-dir directory — the concurrent-lane shape, where
  # "the newest under my work dir" is the plausible wrong answer.
  if [ "$mode" = decoy ]; then
    local other
    for other in \
        "$KIMI_SHARE_DIR/sessions/decoyhash/00000000-0000-4000-8000-000000000000" \
        "$KIMI_SHARE_DIR/sessions/8331003854c45d801e9c7516a9cf2092/00000000-0000-4000-8000-000000000001"; do
      mkdir -p "$other"
      printf '%s\n' \
        '{"type": "metadata", "protocol_version": "1.10"}' \
        '{"timestamp":1788499999.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":777777,"output":777777,"input_cache_read":0,"input_cache_creation":0}}}}' \
        >"$other/wire.jsonl"
      touch -t 203001010000 "$other/wire.jsonl"
    done
  fi
  run_session build fixture/kimi "$udir/work" 5 'the prompt' \
    2>&1 | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  # The fixture's own premise, reported so it can be ASSERTED rather than
  # assumed: the newest wire.jsonl under this run's share root. If a later
  # edit drops the touch above, this names this session's own artifact and the
  # assertion below reds — which is the state the fixture was actually in.
  if [ "$mode" = decoy ]; then
    local w newest=""
    for w in "$KIMI_SHARE_DIR"/sessions/*/*/wire.jsonl; do
      [ -f "$w" ] || continue
      if [ -z "$newest" ] || [ "$w" -nt "$newest" ]; then newest="$w"; fi
    done
    printf '%s\n%s\n' '--newest--' "$newest"
  fi
  printf '%s\n' '--argv--'
  cat "$udir/argv"
  printf '%s\n' '--prose--'
  cat "$udir"/logs/*.log
)

kimi_usage="$(kimi_usage_run full)"
kimi_usage_end="$(grep 'SESSION END' <<<"$kimi_usage")"
kimi_sid="$(sed -n 's/.* sid=\([^ ]*\).*/\1/p' <<<"$kimi_usage_end")"
# The sum across the series, and the whole of D3. 1246 = 1200+37+9,
# 940 = 340+512+88, 51328 = 25088+26240+0, 64 = 64+0+0 — four figures no
# single record carries, over a fixture whose middle StatusUpdate has a null
# token_usage and must contribute nothing.
t kimi-multi-step-usage-is-the-sum-of-the-series '1246|940|64|51328' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* output_tokens=\([^ ]*\).* cache_creation_input_tokens=\([^ ]*\).* cache_read_input_tokens=\([^ ]*\).*/\1|\2|\3|\4/p' <<<"$kimi_usage_end")"
# The failure direction, stated as its own assertion rather than left implied
# by the one above: an implementation that read the FIRST record, or the last,
# would satisfy a suite that only checked "some number arrived".
t kimi-usage-is-not-any-single-record 0 \
  "$(grep -c ' input_tokens=1200 \| input_tokens=9 \| input_tokens=37 ' <<<"$kimi_usage_end" || true)"
t kimi-uncached-input-is-input-other-not-a-subtraction 1246 \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).*/\1/p' <<<"$kimi_usage_end")"
# The figures and the transcript named beside them describe ONE session.
t kimi-usage-session-id-is-the-pinned-id 1 \
  "$([ "$(sed -n 's/.* session_id=\([^ ]*\).*/\1/p' <<<"$kimi_usage_end")" = "$kimi_sid" ] \
    && printf 1 || printf 0)"
t kimi-usage-session-id-is-a-real-id-not-unknown 0 \
  "$(grep -cx unknown <<<"$kimi_sid" || true)"
t kimi-session-never-reports-a-cost 0 \
  "$(grep -c ' cost_usd=' <<<"$kimi_usage_end" || true)"
t kimi-unnamed-model-is-honest unknown \
  "$(sed -n 's/.* model=\([^ ]*\).*/\1/p' <<<"$kimi_usage_end")"
t kimi-pool-identity-rides-the-figures kimi-pool \
  "$(sed -n 's/.* pool=\([^ ]*\).*/\1/p' <<<"$kimi_usage_end")"
# The pin reaches the CLI, and the prompt is still the final argument — the
# reason `_session_splice_cli_args` splices ahead of a trailing `-p` (#538).
t kimi-invocation-pins-the-session-id 1 \
  "$(sed -n '/^--session$/{n;p;}' <<<"$(sed -n '/^--argv--$/,/^--prose--$/p' <<<"$kimi_usage")" \
    | grep -cx "$kimi_sid" || true)"
# The prompt must remain `-p`'s OPERAND, not merely the last word on the line.
# Written as "last argument" first, this assertion was vacuous: run_session
# appends the prompt after the splice either way, so a pin appended PAST the
# trailing `-p` leaves the prompt last and the flag pointing at `--session`.
# What `_session_splice_cli_args` actually promises is this adjacency (#538).
t kimi-invocation-keeps-the-prompt-as-the-p-operand 'the prompt' \
  "$(sed -n '/^--argv--$/,/^--prose--$/p' <<<"$kimi_usage" | sed -n '/^-p$/{n;p;}')"
t kimi-session-prose-log-is-unchanged 'the answer.' \
  "$(sed -n '/^--prose--$/,$p' <<<"$kimi_usage" | sed -n '$p')"
t kimi-usage-run-does-not-fail-the-session '0|ok' \
  "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).*/\1|\2/p' <<<"$kimi_usage_end")"

# Absence, five ways, and every one of them the same answer (#571 D5): no
# usage block, no pool beside it, and a session whose outcome, prose and exit
# status are untouched. `nostatus` is not a hypothetical — it is the exact
# shape of the credential-less session observed on this box, which writes
# TurnBegin and TurnEnd and no StatusUpdate at all.
for shape in nofile nostatus garbage badfield; do
  kimi_absent="$(kimi_usage_run "$shape")"
  kimi_absent_end="$(grep 'SESSION END' <<<"$kimi_absent")"
  t "kimi-$shape-artifact-records-usage-absent" 0 \
    "$(grep -c ' input_tokens=' <<<"$kimi_absent_end" || true)"
  t "kimi-$shape-artifact-claims-no-pool" 0 \
    "$(grep -c ' pool=' <<<"$kimi_absent_end" || true)"
  t "kimi-$shape-artifact-leaves-the-session-alone" '0|ok|the answer.' \
    "$(printf '%s|%s' \
        "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).*/\1|\2/p' <<<"$kimi_absent_end")" \
        "$(sed -n '/^--prose--$/,$p' <<<"$kimi_absent" | sed -n '$p')")"
done

# An unreadable artifact is distinct from a missing one: the file is there and
# named correctly, and the read fails. Absent, not zero, and not an error the
# session wears.
kimi_unreadable="$( KIMI_USAGE_UNREADABLE=1 kimi_usage_run full )"
t kimi-unreadable-artifact-records-usage-absent 0 \
  "$(grep -c ' input_tokens=' <<<"$(grep 'SESSION END' <<<"$kimi_unreadable")" || true)"
t kimi-unreadable-artifact-leaves-the-session-alone '0|ok' \
  "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).*/\1|\2/p' \
      <<<"$(grep 'SESSION END' <<<"$kimi_unreadable")")"

# D4, the assertion the whole design is for. A NEWER artifact carrying wildly
# different figures sits beside this session's under the same share root — one
# under a different work-dir hash, one as a sibling under this session's own.
# A reader that took the newest file, or the first file its glob happened to
# match, would report 777777.
kimi_decoy="$(kimi_usage_run full decoy)"
kimi_decoy_sid="$(sed -n 's/.* sid=\([^ ]*\).*/\1/p' \
  <<<"$(grep 'SESSION END' <<<"$kimi_decoy")")"
# The fixture's premise, asserted rather than described. The pair below is
# named for the mtime mutation, and it can only kill it if a decoy really is
# the newest file on disk — which it was NOT as first written, because both
# decoys are planted before run_session and so were the OLDER files. This
# assertion is what fails if that regresses.
kimi_decoy_newest="$(sed -n '/^--newest--$/{n;p;}' <<<"$kimi_decoy")"
kimi_decoy_newest_sid="${kimi_decoy_newest%/wire.jsonl}"
kimi_decoy_newest_sid="${kimi_decoy_newest_sid##*/}"
t kimi-decoy-really-is-the-newest-on-disk 1 \
  "$([ -n "$kimi_decoy_newest_sid" ] \
    && [ "$kimi_decoy_newest_sid" != "$kimi_decoy_sid" ] \
    && printf 1 || printf 0)"
t kimi-newest-artifact-is-not-the-key '1246|940' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* output_tokens=\([^ ]*\).*/\1|\2/p' \
      <<<"$(grep 'SESSION END' <<<"$kimi_decoy")")"
t kimi-decoy-figures-never-appear 0 \
  "$(grep -c 777777 <<<"$kimi_decoy" || true)"

# The two cache counters default to 0 in the vendor's own model, so a record
# that omits them is a real zero rather than a missing measurement.
kimi_nocache="$(kimi_usage_run nocache)"
t kimi-absent-cache-counters-are-zero '500|91|0|0' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* output_tokens=\([^ ]*\).* cache_creation_input_tokens=\([^ ]*\).* cache_read_input_tokens=\([^ ]*\).*/\1|\2|\3|\4/p' \
      <<<"$(grep 'SESSION END' <<<"$kimi_nocache")")"

# The profile's own reader, driven directly — the kills the end-to-end cases
# above cannot make, because they can only observe what reached the line.
KIMI_SHARE_FIXTURE="$TMP/kimi-share"
mkdir -p "$KIMI_SHARE_FIXTURE/sessions/hash-one/aaaaaaaa-0000-4000-8000-000000000001"
printf '%s\n' \
  '{"type": "metadata", "protocol_version": "1.10"}' \
  '{"timestamp":1788415586.2,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":11,"output":22,"input_cache_read":33,"input_cache_creation":44}}}}' \
  >"$KIMI_SHARE_FIXTURE/sessions/hash-one/aaaaaaaa-0000-4000-8000-000000000001/wire.jsonl"
kimi_direct() ( # kimi_direct SID
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  # shellcheck disable=SC2031  # the run harness above is a sibling subshell
  export KIMI_SHARE_DIR="$KIMI_SHARE_FIXTURE"
  bot_cli_usage '' '' '' "$1"
)
t kimi-profile-reads-the-artifact-by-id '11|22|33|44' \
  "$(kimi_direct aaaaaaaa-0000-4000-8000-000000000001 \
    | jq -r '[.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens] | join("|")')"
t kimi-profile-never-invents-cost false \
  "$(kimi_direct aaaaaaaa-0000-4000-8000-000000000001 | jq -r 'has("cost_usd")')"
# `unknown` is a value, not a directory. A profile that treated it as a path
# component would go looking for a session literally named `unknown`, and one
# planted here proves the refusal is by name rather than by absence.
mkdir -p "$KIMI_SHARE_FIXTURE/sessions/hash-one/unknown"
cp "$KIMI_SHARE_FIXTURE/sessions/hash-one/aaaaaaaa-0000-4000-8000-000000000001/wire.jsonl" \
  "$KIMI_SHARE_FIXTURE/sessions/hash-one/unknown/wire.jsonl"
t kimi-profile-refuses-unknown-as-a-path-component 0 \
  "$(kimi_direct unknown | wc -l)"
t kimi-profile-refuses-an-empty-id 0 "$(kimi_direct '' | wc -l)"
# A traversal dressed as an id. The lookup composes a path from this string,
# so a value carrying a separator is refused before it is composed.
t kimi-profile-refuses-a-path-shaped-id 0 \
  "$(kimi_direct '../hash-one/aaaaaaaa-0000-4000-8000-000000000001' | wc -l)"
# `.` and `..` carry no separator, so the character class admits them, and
# neither is a path component: `..` composes `sessions/*/../wire.jsonl` and
# `.` composes `sessions/*/./wire.jsonl`. Both landing sites are PLANTED here
# with figures nothing else in this suite carries, so the refusal is proved by
# name rather than by the file's absence — drop either arm from the profile
# and the composed read succeeds and reports 424242.
printf '%s\n' \
  '{"timestamp":1.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":424242,"output":424242}}}}' \
  >"$KIMI_SHARE_FIXTURE/sessions/wire.jsonl"
printf '%s\n' \
  '{"timestamp":1.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":424242,"output":424242}}}}' \
  >"$KIMI_SHARE_FIXTURE/sessions/hash-one/wire.jsonl"
t kimi-profile-refuses-dotdot-as-an-id 0 "$(kimi_direct '..' | wc -l)"
t kimi-profile-refuses-dot-as-an-id 0 "$(kimi_direct '.' | wc -l)"
t kimi-profile-refuses-an-id-that-matches-nothing 0 \
  "$(kimi_direct bbbbbbbb-0000-4000-8000-000000000002 | wc -l)"
# Two concurrent sessions under ONE work dir, which is the acceptance
# criterion D4 is written for: same hash directory, two ids, two answers.
# Neither figure appears in the other's record.
mkdir -p "$KIMI_SHARE_FIXTURE/sessions/hash-one/aaaaaaaa-0000-4000-8000-000000000009"
printf '%s\n' \
  '{"type": "metadata", "protocol_version": "1.10"}' \
  '{"timestamp":1788416000.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":91,"output":92,"input_cache_read":93,"input_cache_creation":94}}}}' \
  >"$KIMI_SHARE_FIXTURE/sessions/hash-one/aaaaaaaa-0000-4000-8000-000000000009/wire.jsonl"
t kimi-concurrent-sessions-one-work-dir-each-carry-their-own '11|22::91|92' \
  "$(printf '%s::%s' \
      "$(kimi_direct aaaaaaaa-0000-4000-8000-000000000001 | jq -r '[.input_tokens, .output_tokens] | join("|")')" \
      "$(kimi_direct aaaaaaaa-0000-4000-8000-000000000009 | jq -r '[.input_tokens, .output_tokens] | join("|")')")"
# One id under two work-dir hashes: a shape the CLI cannot produce, and if it
# ever does, either answer would be a measurement attributed to a session
# nobody identified.
mkdir -p "$KIMI_SHARE_FIXTURE/sessions/hash-two/aaaaaaaa-0000-4000-8000-000000000001"
cp "$KIMI_SHARE_FIXTURE/sessions/hash-one/aaaaaaaa-0000-4000-8000-000000000001/wire.jsonl" \
  "$KIMI_SHARE_FIXTURE/sessions/hash-two/aaaaaaaa-0000-4000-8000-000000000001/wire.jsonl"
t kimi-profile-refuses-one-id-under-two-work-dirs 0 \
  "$(kimi_direct aaaaaaaa-0000-4000-8000-000000000001 | wc -l)"
# The artifact root is $KIMI_SHARE_DIR when set and ~/.kimi otherwise, and it
# is NOT the credential home: a box whose credential lives in ~/.kimi-code
# still writes its sessions under ~/.kimi.
kimi_home_default() (
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  unset KIMI_SHARE_DIR
  HOME="$TMP/kimi-homedefault"
  export HOME KIMI_CODE_HOME="$HOME/.kimi-code"
  mkdir -p "$HOME/.kimi-code/sessions/hash-cred/cccccccc-0000-4000-8000-000000000003" \
    "$HOME/.kimi/sessions/hash-home/cccccccc-0000-4000-8000-000000000003"
  # The DECOY is in the credential home, carrying different figures.
  printf '%s\n' \
    '{"timestamp":1.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":999,"output":999}}}}' \
    >"$HOME/.kimi-code/sessions/hash-cred/cccccccc-0000-4000-8000-000000000003/wire.jsonl"
  printf '%s\n' \
    '{"timestamp":1.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":5,"output":6}}}}' \
    >"$HOME/.kimi/sessions/hash-home/cccccccc-0000-4000-8000-000000000003/wire.jsonl"
  bot_cli_usage '' '' '' cccccccc-0000-4000-8000-000000000003
)
t kimi-share-root-defaults-to-home-kimi-not-the-credential-home '5|6' \
  "$(kimi_home_default | jq -r '[.input_tokens, .output_tokens] | join("|")')"

# The profile declares the artifact shape and NOT the stdout one. This is
# #475 D8's second declaration shape, and the pair is the statement: usage
# without a structured command is exactly what "my figures are in a file"
# means. `bot_cli_structured_cmd`'s absence is already asserted above.
if bash -c '. "$1"; declare -F bot_cli_usage >/dev/null' \
    _ "$SHARED/conf/agents/kimi.conf"; then r1=declared; else r1=MISSING; fi
t kimi-profile-declares-artifact-backed-usage declared "$r1"
if bash -c '. "$1"; declare -F bot_cli_session_id_args >/dev/null' \
    _ "$SHARED/conf/agents/kimi.conf"; then r1=declared; else r1=MISSING; fi
t kimi-profile-pins-the-session-id declared "$r1"
# The invocation gains the pin and NOTHING ELSE. `--print` is what would
# change the capture shape, and #571 D6 is settled the other way: the artifact
# is written without it, so it is not passed and neither is a stream format.
t kimi-invocation-adds-no-print-mode 0 \
  "$(bash -c '. "$1"; printf "%s\n" "${BOT_CLI_CMD[@]}"' _ "$SHARED/conf/agents/kimi.conf" \
    | grep -cx -- '--print\|--output-format\|--quiet' || true)"

t credential-pool-ships-unset '' \
  "$(bash -c '. "$1"; printf %s "$SESSION_CREDENTIAL_POOL"' \
      _ "$SHARED/conf/fleet.defaults.conf")"

# --- optional classifier hooks are loud once per profile per boot (#501) ---
for agent in claude kimi; do
  if bash -c '. "$1"; declare -F bot_session_terminal >/dev/null' \
      _ "$SHARED/conf/agents/$agent.conf"; then r1=declared; else r1=MISSING; fi
  t "$agent-profile-declares-terminal-classifier" declared "$r1"
done
for agent in codex grok; do
  if bash -c '. "$1"; declare -F bot_session_terminal >/dev/null' \
      _ "$SHARED/conf/agents/$agent.conf"; then r1=UNEXPECTED; else r1=absent; fi
  t "$agent-profile-declares-terminal-gap" absent "$r1"
done
for profile in "$SHARED"/conf/agents/*.conf; do
  agent="$(basename "$profile" .conf)"
  if bash -c '. "$1"; declare -F bot_session_terminal >/dev/null' _ "$profile"; then
    if bash -c '. "$1"; declare -F bot_session_terminal_fixture >/dev/null' \
        _ "$profile"; then r1=declared; else r1=MISSING; fi
    t "$agent-terminal-classifier-carries-drill-fixture" declared "$r1"
    if grep -q '^# Observed sessions: ' "$profile"; then r1=cited; else r1=MISSING; fi
    t "$agent-terminal-classifier-cites-observed-sessions" cited "$r1"
  else
    if bash -c '. "$1"; declare -F bot_session_terminal_fixture >/dev/null' \
        _ "$profile"; then r1=UNEXPECTED; else r1=absent; fi
    t "$agent-terminal-gap-carries-no-drill-fixture" absent "$r1"
  fi
done

classifier_report_case() ( # profile boot acted|missing terminal|missing
  local profile="$1" boot="$2" acted="$3" terminal="$4"
  BOT_AGENT="$profile"
  unset -f bot_session_acted bot_session_terminal
  # shellcheck disable=SC2317  # invoked indirectly by the reporter's declare -F probe
  [ "$acted" = missing ] || bot_session_acted() { return 1; }
  # shellcheck disable=SC2317  # invoked indirectly by the reporter's declare -F probe
  [ "$terminal" = missing ] || bot_session_terminal() { return 1; }
  report_profile_classifier_gaps "$boot"
)
classifier_report="$({
  classifier_report_case codex boot-a declared missing
  classifier_report_case codex boot-a declared missing
  classifier_report_case operator boot-a missing missing
  classifier_report_case codex boot-b declared missing
  classifier_report_case claude boot-b declared declared
} 2>&1)"
t classifier-gap-once-for-profile-per-boot 2 \
  "$(grep -c 'agent profile codex missing classifier hook(s): bot_session_terminal' <<<"$classifier_report" || true)"
t classifier-gap-lists-every-missing-hook 1 \
  "$(grep -c 'agent profile operator missing classifier hook(s): bot_session_acted, bot_session_terminal' <<<"$classifier_report" || true)"
t classifier-complete-profile-is-not-named 0 \
  "$(grep -c 'agent profile claude missing classifier' <<<"$classifier_report" || true)"
boot_id_line="$(grep -n '^boot_id=' "$SHARED/bin/duty.sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # match the literal boot-id argument in duty.sh
classifier_report_line="$(grep -n 'report_profile_classifier_gaps "\$boot_id"' \
  "$SHARED/bin/duty.sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # match the literal boot marker read in duty.sh
boot_gate_line="$(grep -n 'if \[ "\$(cat "\$DUTY_DIR/.boot-id"' \
  "$SHARED/bin/duty.sh" | head -1 | cut -d: -f1)"
if [ -n "$boot_id_line" ] && [ -n "$classifier_report_line" ] \
    && [ -n "$boot_gate_line" ] \
    && [ "$boot_id_line" -lt "$classifier_report_line" ] \
    && [ "$classifier_report_line" -lt "$boot_gate_line" ]; then
  r1=wired
else
  r1=MISSING
fi
t classifier-gap-report-is-wired-on-the-boot-path wired "$r1"

# --- each agent profile reads its OWN credential store, locally -------------
# Driven against the real conf files with a fabricated HOME, because the whole
# claim of bot_cli_present is that it needs nothing but local disk.

CREDH="$TMP/credhome"; mkdir -p "$CREDH"
cred_rc() {  # cred_rc <agent> <home> [KIMI_CODE_HOME] -> rc of bot_cli_present
  local rc=0
  # Every vendor env override is cleared, not just the one under test: these
  # are read by the sourced profile, and inheriting the RUNNER's credentials
  # would make the result depend on whose machine ran the suite. KIMI_CODE_HOME
  # is the one a caller may set back, in $3, because kimi's home resolver gives
  # it precedence over both probed homes and that precedence is under test.
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$2" KIMI_CODE_HOME="${3:-}" CODEX_HOME="" GROK_HOME="" \
    ANTHROPIC_API_KEY="" XAI_API_KEY=""
    # shellcheck disable=SC1090
    source "$SHARED/conf/agents/$1.conf"; bot_cli_present ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
# base64url with the padding stripped, the way a JWT actually arrives.
b64url() { base64 -w0 | tr '/+' '_-' | tr -d '='; }

# -- claude: refreshTokenExpiresAt, in MILLISECONDS
CH="$CREDH/claude"; mkdir -p "$CH/.claude"
CLAUDE_EXP_MS=$(( ($(date +%s) + 20 * 86400) * 1000 ))
jq -n --argjson r "$CLAUDE_EXP_MS" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-present 0 "$(cred_rc claude "$CH")"

# THE trap, and the reason this profile reads refreshTokenExpiresAt: an access
# token that lapsed hours ago while the refresh token is still good is the
# ordinary steady state, refreshed silently on next use. A profile testing
# `expiresAt` would call a perfectly healthy box logged out three times a day.
jq -n --argjson r "$CLAUDE_EXP_MS" --argjson a "$(( ($(date +%s) - 3600) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:$a,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-stale-access-token-is-fine 0 "$(cred_rc claude "$CH")"

# An expired REFRESH token is the real logout: nothing can renew it but a human.
jq -n --argjson r "$(( ($(date +%s) - 86400) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-expired-refresh 1 "$(cred_rc claude "$CH")"
t cred-claude-no-file 1 "$(cred_rc claude "$CREDH/nothing")"

# -- kimi: the refresh token is a JWT; its exp claim is the relogin deadline
KH="$CREDH/kimi"; mkdir -p "$KH/.kimi-code/credentials"
KIMI_EXP=$(( $(date +%s) + 30 * 86400 ))
# A payload sized so base64url PADDING is required — the case a naive decoder
# silently fails on.
KJWT="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code","sub":"u"}' "$KIMI_EXP" | b64url).sig"
jq -n --arg rt "$KJWT" \
  '{access_token:"a",refresh_token:$rt,expires_at:1,token_type:"Bearer"}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-present 0 "$(cred_rc kimi "$KH")"
t cred-kimi-no-file 1 "$(cred_rc kimi "$CREDH/nothing")"
# An expired refresh JWT is a logout, not merely "cannot tell".
KJWT_OLD="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code"}' "$(( $(date +%s) - 86400 ))" | b64url).sig"
jq -n --arg rt "$KJWT_OLD" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-expired-refresh 1 "$(cred_rc kimi "$KH")"
# Garbage in the JWT slot must be "cannot tell" (2), never a confident logout.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-unparseable-is-unknown 2 "$(cred_rc kimi "$KH")"

# -- kimi, the second home. The shipped CLI keeps the same credential at
# ~/.kimi, not ~/.kimi-code, so the profile resolves the home instead of
# assuming it (#240): the fleet's kimi box reported a dead vendor credential
# on every tick while being perfectly logged in. cred_rc clears
# KIMI_CODE_HOME by design, so these four are the unset case.
KH2="$CREDH/kimialt"; mkdir -p "$KH2/.kimi/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-present 0 "$(cred_rc kimi "$KH2")"
# A wider search must reach the SAME parser, not a second, dumber one.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-unparseable-is-unknown 2 "$(cred_rc kimi "$KH2")"
# Neither home holds anything: still a CONFIDENT logout. A resolver that fell
# back to a path it never checked would answer 2 here and silence a real one.
KH0="$CREDH/kiminone"; mkdir -p "$KH0/.kimi/credentials" "$KH0/.kimi-code/credentials"
t cred-kimi-neither-home 1 "$(cred_rc kimi "$KH0")"

# KIMI_CODE_HOME is explicit operator intent and outranks both probes. Proven
# by pointing it at a home with NO credential while BOTH known homes hold a
# good one: a resolver that probed first would answer 0. cred_rc's third
# argument is the only vendor override it does not clear, for exactly this.
KHO="$CREDH/kimiover"; mkdir -p "$KHO/.kimi/credentials" "$KHO/.kimi-code/credentials" "$KHO/elsewhere/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/.kimi/credentials/kimi-code.json"
cp "$KHO/.kimi/credentials/kimi-code.json" "$KHO/.kimi-code/credentials/kimi-code.json"
t cred-kimi-override-outranks-probe 1 "$(cred_rc kimi "$KHO" "$KHO/elsewhere")"
# ...and it reaches a credential neither probe would ever find.
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/elsewhere/credentials/kimi-code.json"
t cred-kimi-override-reaches-elsewhere 0 "$(cred_rc kimi "$KH0" "$KHO/elsewhere")"

# -- the SAME resolution drives PATH, and until now nothing asserted that half
# of #240's D2: BOT_PATH_PREPEND is an assignment evaluated when the profile is
# sourced, so reading it back also proves the resolver is defined ABOVE it.
# The resolved home's bin comes first, then every other known home's — a
# non-existent PATH entry costs nothing, which is why the fallbacks are cheaper
# than guessing right. Only PRESENCE of the credential picks the home here, not
# whether its JWT parses, so the fixtures above are reused exactly as they lie.
path_prepend() {  # path_prepend <home> [KIMI_CODE_HOME] -> BOT_PATH_PREPEND
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$1" KIMI_CODE_HOME="${2:-}"
    # shellcheck disable=SC1091
    source "$SHARED/conf/agents/kimi.conf"; printf '%s' "$BOT_PATH_PREPEND" ) 2>/dev/null
}
t path-kimi-alt-home-first "$KH2/.kimi/bin:$KH2/.kimi-code/bin" "$(path_prepend "$KH2")"
t path-kimi-old-home-first "$KH/.kimi-code/bin:$KH/.kimi/bin" "$(path_prepend "$KH")"
# No credential anywhere: the ~/.kimi-code fallback leads, and the other home
# is still on PATH — the CLI may be installed where the credential is not.
t path-kimi-neither-home-falls-back "$KH0/.kimi-code/bin:$KH0/.kimi/bin" "$(path_prepend "$KH0")"
# Explicit operator intent leads here too, even though both probes would hit.
t path-kimi-override-first "$KHO/elsewhere/bin:$KHO/.kimi/bin:$KHO/.kimi-code/bin" \
  "$(path_prepend "$KHO" "$KHO/elsewhere")"

# -- codex: file-backed vs keyring-backed, and NO expiry at all
DH="$CREDH/codex"; mkdir -p "$DH/.codex"
jq -n '{auth_mode:"chatgpt",tokens:{access_token:"a.b.c",refresh_token:"opaque"}}' > "$DH/.codex/auth.json"
t cred-codex-present 0 "$(cred_rc codex "$DH")"
t cred-codex-no-file-is-logout 1 "$(cred_rc codex "$CREDH/nothing")"
# ...unless the box keeps its credential in the desktop keyring, where a
# missing auth.json is normal and must not be reported as a logout.
KB="$CREDH/codexkeyring"; mkdir -p "$KB/.codex"
echo 'cli_auth_credentials_store = "keyring"' > "$KB/.codex/config.toml"
t cred-codex-keyring-is-unknown 2 "$(cred_rc codex "$KB")"

# -- grok: its probe was already a local file test, so it is authoritative
# -- grok: a MAP of "<issuer>::<client_id>" slots, refresh token opaque
GH_="$CREDH/grok"; mkdir -p "$GH_/.grok"
jq -n '{"https://auth.x.ai::abc":{key:"j.w.t",refresh_token:"opaque",expires_at:"2026-07-27T19:54:18Z"}}' \
  > "$GH_/.grok/auth.json"
t cred-grok-present 0 "$(cred_rc grok "$GH_")"
t cred-grok-no-file 1 "$(cred_rc grok "$CREDH/nothing")"
# An empty map is a non-empty FILE. The old `[ -s ]` test called this logged
# in; it is a failed login, and the honest answer is "cannot tell".
echo '{}' > "$GH_/.grok/auth.json"
t cred-grok-empty-map-is-unknown 2 "$(cred_rc grok "$GH_")"

# No profile may define bot_cli_expiry: the floor tracks no expiry dates, and
# a profile still exporting one would be dead code drifting out of sync.
for agent in claude codex grok kimi; do
  r1=absent
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$agent.conf"; command -v bot_cli_expiry >/dev/null ) 2>/dev/null && r1=DEFINED
  t "cred-$agent-defines-no-expiry" absent "$r1"
done

# --- install.sh: the operator agent-profile transport contract (#75) --------
# The ordering is the whole difficulty (codex Blocking 4 on #73): install.sh
# refuses an unknown agent BEFORE it creates conf/agents, so a profile that
# arrived only with the conf copy would fail its own validation — a vendor
# that lists in `crew profiles` and dies at `crew hire`. The host stages
# operator profiles into ~/duty/.crew-seed-agents ahead of the run; these
# fixtures assert every clause: a seeded profile passes validation, the
# operator copy is what conf/agents carries (same-name wins where load_conf
# reads), the seed is consumed on success AND failure, and an unseeded
# unknown agent still dies.
PHOME="$TMP/profile-home"
PDUTY="$PHOME/duty"
mkdir -p "$PDUTY/.crew-seed-agents"
printf 'old-boot\n' >"$PDUTY/.boot-id"
printf 'old classifier report\n' >"$PDUTY/.profile-classifier-hooks"
cat >"$PDUTY/.crew-seed-agents/vendorx.conf" <<'EOF'
# vendorx — operator-supplied fixture vendor (never shipped)
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="vendorx"
AGENT_LOGIN_HINT="vendorx auth login"
bot_cli_probe() { return 0; }
bot_cli_present() { command -v vendorx >/dev/null 2>&1; }
EOF
profile_install() {
  env HOME="$PHOME" DUTY_DIR="$PDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
if profile_install --agent vendorx --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-validates-before-conf-exists 0 "$r1"
[ -f "$PDUTY/conf/agents/vendorx.conf" ] && r1=installed || r1=missing
t operator-profile-lands-in-conf-agents installed "$r1"
if grep -q 'operator-supplied fixture vendor' "$PDUTY/conf/agents/vendorx.conf" 2>/dev/null; then
  r1=operator
else
  r1=other
fi
t operator-profile-is-the-operator-copy operator "$r1"
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed consumed "$r1"
t install-clears-boot-gate-cache absent \
  "$([ -e "$PDUTY/.boot-id" ] && printf present || printf absent)"
t install-clears-classifier-report-cache absent \
  "$([ -e "$PDUTY/.profile-classifier-hooks" ] && printf present || printf absent)"
# The shipped set still installs whole beside the operator's addition.
[ -f "$PDUTY/conf/agents/claude.conf" ] && r1=present || r1=missing
t operator-profile-shipped-set-intact present "$r1"

# Same-name precedence: an operator claude.conf beats the shipped one — and
# the win must hold at RUNTIME, where load_conf sources whatever
# conf/agents carries (common.sh:34); settled in the copy, not by a reader.
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/claude.conf" <<'EOF'
# claude — operator override fixture
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="claude"
AGENT_LOGIN_HINT="operator override wins"
bot_cli_probe() { return 0; }
bot_cli_present() { return 0; }
EOF
profile_install --agent claude --role reviewer >/dev/null 2>&1
if grep -q 'operator override fixture' "$PDUTY/conf/agents/claude.conf" 2>/dev/null; then
  r1=operator
else
  r1=shipped
fi
t operator-profile-same-name-wins operator "$r1"
# shellcheck disable=SC2016  # $DUTY_DIR and $AGENT_LOGIN_HINT expand in the child shell
runtime_hint="$(env DUTY_DIR="$PDUTY" HOME="$PHOME" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_conf; printf %s "$AGENT_LOGIN_HINT"')"
t operator-profile-wins-at-load_conf "operator override wins" "$runtime_hint"

# The gap the contract closes, inverted: an agent nobody transported and
# nobody ships must still die at validation, not at first duty tick.
if profile_install --agent vendory --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-unknown-still-refused 1 "$r1"

# A one-install transport on FAILURE too: a failing install (here: a role
# that does not exist, checked after the agent) must not leave seeds behind
# for a later bare run to resurrect.
mkdir -p "$PDUTY/.crew-seed-agents"
printf '# vendorz — fixture\n' >"$PDUTY/.crew-seed-agents/vendorz.conf"
profile_install --agent vendorz --role nosuchrole >/dev/null 2>&1 || true
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed-on-failure consumed "$r1"


# --- bot_session_acted: the idle detector on the two -p profiles (#467) -----
#
# THE FIXTURES BELOW ARE VERBATIM CAPTURED SESSION LOGS, byte for byte, from
# the 1064 `claude -p` transcripts this engine wrote on a real builder box.
# Nothing here was composed to be detected. That is the point of #467's
# acceptance criteria: a detector tested only against strings someone imagined
# is a detector that fails on the first real session, and the two corrections
# this suite pins hardest — the sub-action claim and the quota banner — were
# both invisible until the whole corpus was run through it.
#
# Each fixture names the log it came from, so the claim is checkable.

ALOG="$TMP/acted"; mkdir -p "$ALOG"

acted_rc() {  # acted_rc <agent> <log> -> raw rc of the profile hook
  local rc=0
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; bot_session_acted "$2" ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
acted_prose() {  # acted_prose <agent> <log> -> what the detector actually reads
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; "_${1}_reply_prose" "$2" ) 2>/dev/null
}
acted_word() {  # acted_word <agent> <log> -> the field as duty.log spells it
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; session_acted "$2" )
}
acted_verdict_line() {  # acted_verdict_line <agent> <line> -> yes|no
  # Asks the verdict pattern directly, about ONE line. Used only where the
  # whole transcript that line came from is not available to paste, so an rc
  # case on a one-line file would answer `yes` from D3's default no matter
  # what the pattern said — a case no mutation could kill. This asks the
  # question the rendering actually poses.
  # A here-string, not `printf | grep -q`: this file sets pipefail, and #449's
  # guard puts that shape in the class where grep's early exit reds the suite
  # by SIGPIPE. There is no producer to reap here anyway.
  # shellcheck disable=SC1090
  if ( source "$SHARED/conf/agents/$1.conf"
       av_re="${1^^}_ACTED_VERDICT_RE"
       grep -Eiq "${!av_re}" <<<"$2" ); then echo yes; else echo no; fi
}

# an `attention` session that posted two comments and removed a label
# captured: ~/duty/logs/20260802T130504Z-attention-heavy-duty_crew_286.log
cat >"$ALOG/push.log" <<'ACTED_EOF'
Done. The demand on #286 was a single recovery act, and it's complete.

**What the thread demanded:** my 12:48:59Z signal named `d664faf3`, then I pushed `4a8a86e3` (triage's amended must-fail item) *after* it. The head therefore carried no signal, `_request_panel` was correctly holding, and the PR would have held forever — #241's shape, with the recovery duty not deployed to the boxes.

**What I did:**
- Posted `📌 picked up` on #286 and removed the `attention` label ([comment](https://github.com/heavy-duty/crew/issues/286#issuecomment-5158076189)).
- Verified head `4a8a86e378fe990092097fdc283a02f0b70ee712` is green — rollup `SUCCESS`, all four checks (`check`, `guards`, `labels / scope`, `labels / trigger`) completed successful, nothing queued, cancelled, or stale. Worktree clean at that exact SHA, nothing unpushed.
- Confirmed the round is answered whole: every worklog checkbox and acceptance criterion in the PR body is checked, and no reviews are outstanding at any head.
- Posted the signal on [#292](https://github.com/heavy-duty/crew/pull/292#issuecomment-5158080889): `📣 round answered at head 4a8a86e378fe990092097fdc283a02f0b70ee712`, with the green table, the two judgement calls flagged for the panel (task 3 scoped to `CHANGES_REQUESTED`; `answered-head.jq` serving both callers with stranded detection reading no time), and an explicit acknowledgement that the post-signal push was mine to re-signal regardless of why the head moved.

No exception was argued — the head is genuinely green. The engine now requests the panel; that is not mine to do.
ACTED_EOF

# a `resume` session that read the whole PR thread and wrote nothing
# captured: ~/duty/logs/20260806T053009Z-resume-heavy-duty_crew.log
cat >"$ALOG/read.log" <<'ACTED_EOF'
**PR #376 needs no action — it is already fully converged. I posted nothing.**

The resume wake named it, but the REST thread shows the work is complete:

| check | state |
|---|---|
| head | `019db9b4c85485910ee1c4b6adc429650dcd924e` |
| round-answered signal at that head | posted 01:01:31Z |
| panel verdicts at that head | kimi ✅ 01:10, codex ✅ 01:13, claude ✅ 01:19 — all three, full bench minus me |
| handoff | `🤝 handed off at head 019db9b…` posted 01:21:50Z |
| label | `state:needs-human` |
| checks at head | ci-shell SUCCESS, guards SUCCESS, labels/scope SUCCESS (+ SKIPPED reruns), labels/trigger SUCCESS — green |
| worktree `build-168-wip-refs` | clean, HEAD == `fork` branch tip, nothing stranded |

This is the known false positive: the 12-tick counter runs from the *push* (23:59Z), and round 3's reply→signal gap ran to 01:01Z, so the counter tripped on a PR that had in fact answered its round, been approved by the whole panel, and been handed to the human. Per BUILDER.md — "a resumption that finds nothing changed posts nothing" — re-posting a signal or a ⟲ marker here would be pure flood on a PR that is already at `state:needs-human` and waiting only on a human merge.

No draft PRs and no orphaned claimed issues were outstanding, so the duty is discharged with no writes to GitHub.
ACTED_EOF

# a `resume` session that opens with TWO no-op claims and then writes a memory file
# captured: ~/duty/logs/20260806T010509Z-resume-heavy-duty_crew.log
cat >"$ALOG/trap.log" <<'ACTED_EOF'
Nothing to do on PR 376, and I posted nothing to it. The standing record is correct: signalled at the current head, green, panel requested, one reviewer mid-round. Per BUILDER.md's Claiming rule — *"a resumption that finds nothing changed posts nothing"* — silence here is the compliant act, and a duplicate marker would have been the `#145`/`#311` flood.

I updated my memory of the resume wake: the cause it recorded (`#360`'s comment-blindness) merged yesterday, but the wake tripped anyway for a different reason worth carrying forward — the twelve-tick counter runs from the push, not from the whole-round reply, so a long gap between posting the reply and posting the `📣` signal burns the budget on its own. The fix is on my side: close that gap.
ACTED_EOF

# a session that is only waiting on a verdict
# captured: ~/duty/logs/20260824T220003Z-attention-heavy-duty_ceremony_499.log
cat >"$ALOG/wait.log" <<'ACTED_EOF'
Round 2's third verdict hasn't landed yet. I'll pick this back up the moment it does — the poll wakes me either on the verdict or in ~13 minutes, whichever comes first, so a long wait produces a worklog update on the PR rather than silence.
ACTED_EOF

# a session cut off mid-flight, one clause short of saying whether it posted
# captured: ~/duty/logs/20260809T022011Z-build-heavy-duty_crew.log
cat >"$ALOG/ambi.log" <<'ACTED_EOF'
No tests drive the log helpers directly, so claude's NB#3 is cheap to take. Posting the plan of record now, before touching code.
API Error: Server error mid-response. The response above may be incomplete.
ACTED_EOF


# THE REVIEW DUTY, on two transcripts a reviewer session actually emitted.
#
# There is no captured `review` transcript in this box's 1066 logs — 578
# resume, 312 build, 131 attention, 36 ci-red, 3 rebase, 6 operator-floor, and
# not one review — and that absence is the defect these fixtures exist for.
# The first cut of this detector was tuned on that corpus, so it could not see
# the review duty's acts at all and booked 25 reviewer sessions that had
# written a verdict to GitHub as idle. The second cut fixed 20 of the 25 and
# was still fitted to ONE string, a minimal reproduction someone wrote down —
# which is exactly what #467 criterion 1 forbids, and the remaining five real
# reports render the marker four other ways.
#
# So both fixtures below are whole captured transcripts, byte for byte, from
# the reviewer box that holds 1261 of them. They were pasted verbatim by
# claude-bot into its round-2 review of PR #522 at head `57eea8e1` precisely
# so that nothing here has to be taken on trust, and each session's act is
# confirmed against GitHub — `pulls/N/reviews` and `issues/N/comments` — and
# not against the reply's own text.
#
# captured: 20260807T104505Z-review-heavy-duty_crew.log (2704 bytes)
# GitHub:   heavy-duty/crew#394 APPROVED at `c489f4f`, 10:51:56Z
#
# Rendering: `PR 394 (heavy-duty/crew) — approved` — the reference carries no
# `#` at all and the repository sits in parentheses between it and the dash,
# so a pattern wanting `#N` beside the verdict could not see it.
#
# Its no-op claim is load-bearing and is NOT a report about itself: the idle
# net hits `still running` in prose about a suite and `is still on disk` about
# someone else's stale worktree. That is what drags a session which plainly
# acted onto the residue path, where the verdict pattern has to answer for it.
cat >"$ALOG/verdict.log" <<'ACTED_EOF'
**PR 394 (heavy-duty/crew) — approved at `c489f4f`.**

Why it was in scope: my last verdict covered `5bcb8d0`, the head moved to `c489f4f`, and a re-request for me (10:44:08Z) postdates it. Announced once via `post-once.sh`, reviewed in a detached throwaway worktree, removed after.

What the round turned on: codex blocked on the per-repository grain of "could not inspect ≠ absent" — a live `gh` identity plus a dead network still surveyed sandboxes as absent and printed a clean host. This head replaces `gh repo view` (GraphQL, one exit code for both facts) with `gh api repos/...` (REST, 404 distinguishable), and routes anything that isn't a measured 404 into the `UNINSPECTED` list.

I verified rather than read:

- Rebuilt codex's repro in my own harness (my `box`/`gh` doubles, my roster) — exit 2, the specific repo named, no delete, no clean-host sentence. Also drove the precedence edges: failed deletion still beats INCOMPLETE (rc 1), `--dry-run` carries the 2, and a 404 is still a measured absence so idempotence survives.
- Asked the **real** `gh` binary, since the fix rests entirely on its stderr shape: 404 → `gh: Not Found (HTTP 404)`; invalid token → `Bad credentials (HTTP 401)`; bad host → `error connecting to…`. All land on the right arm. End-to-end with real `gh` and only `box` doubled: own-owner 404 → rc 0, wrong-owner slug → refused, invalid token → rc 2.
- My two other nits from last round also landed: the sandbox owner gate (repo half now has two gates like the box half) and the dedupe (a target named twice is deleted once).
- Suites: `drill-teardown.sh` 44/0, `shared/test/run.sh` 1536/1, per-file `shellcheck -x` and CI's exact `bash -n` list clean. The single failure is `floor-named-crew-verb-roster-is-complete`, which lives on `main` in `fleet-floor/server/floor.py:654` — a directory this PR does not touch.

Stated in the verdict as unverified: the five POST-MERGE real-host criteria (no nested box possible from in here — heavy-duty/box#80), all `box` CLI interactions still going through doubles, and the aggregate `shellcheck` invocation that OOM-killed in this box.

Three non-blocking nits carried, the substantive one being that `roster_files` tests `-f` but never `-r` — I reproduced a `chmod 000` roster silently dropping the roster gate and letting a drill-named fleet member be removed. Remote (needs an unreadable roster *and* a collision-named member) and consistent with `cli/crew`'s existing idiom, so a nit rather than a block, with the one-line fix named.

One unrelated observation: a stale worktree from an earlier session, `trees/heavy-duty__crew/review-385`, is still on disk. Not this PR's, so I left it alone.
ACTED_EOF

# The subjectless half, also whole and also captured — and a better fixture on
# every axis than the invented one it replaces, because here the trap and the
# act are both real and both in the same file.
#
# captured: 20260818T013513Z-review-heavy-duty_incubator.log (2482 bytes)
# GitHub:   heavy-duty/incubator#293 APPROVED at `7e6d617`, 01:52:26Z
#
# Two renderings at once. The marker is `#293 — <title> → approved`: the
# reference is right, but a backticked title span sits between it and the
# verdict and the separator is an arrow rather than a dash. And the opening
# summary is form B MID-SENTENCE — `Both PRs reviewed at their current heads,
# verdicts submitted, worktrees removed` — where the pattern had required the
# verdict noun to open its sentence.
#
# Its last line is the trap the invented fixture was built for, in the wild,
# which is why that one is not missed: the `🔎` announce for #293 was already
# present, `so I posted nothing there` — a GENUINE first-person no-op claim
# about a suppressed duplicate, in a session that had already landed two
# verdicts on GitHub.
cat >"$ALOG/passive.log" <<'ACTED_EOF'
Both PRs reviewed at their current heads, verdicts submitted, worktrees removed, clone clean.

**#293 — `feat: localize application emails by deployer language` → approved** (head `7e6d617`)

My round-1 blocker was that the named must-fail case ("any applicant-facing English string reachable from a `["es"]` deployment") didn't fail. The new structural leaf-equivalence guard does: I planted all three of my original mutations at once and the suite failed naming all three, then passed 29/29 restored. I re-proved byte-identity at this head rather than carrying the old proof forward — 11 messages rendered through worktrees at merge base `af3af6c` and at head, 40,720 bytes, `diff` clean — and re-ran the fail-closed type mutations against the changed type alias (`Record<Locale, ApplicationEmailCopy>`, the full union, so it no longer leans on the generator's widening). Full Core suite 124 files / 1111 tests green, Biome clean over 537 files, same-head CI green. One non-blocking note carried forward: `sender-roles.test.ts` pins the no-reply invariant against the English constant, which will break the day an ES template becomes the build template — not this PR's work.

**#295 — La Familia's accountability set → changes requested** (head `9efc63c`)

The set is strong and every criterion is met on its face; the code claims check out individually (cohort map, consent-is-withholding, cadence ordering constraint, `quit`/#198, the portability gap and the notice that promises it, nothing served by the content collection, all 44 open-decision counts). The blocker is that `RETENTION_ENABLED` gates more than the sweep: with it off — the default, and the state `21` §6 tells the deployer to hold — the erasure route answers `404 retention_disabled` and the alumni consent write is refused, so four of the nine rights in `22` are described as served by a route that isn't there. That's the issue's own must-fail case, one flag away from the portability case the document handles correctly. The sharper half: `21` §6's precondition ("the consent is actually being asked and recorded" before enabling) can't be met, because recording the consent requires the flag it gates. Both fixes are documentary — a caveat at the named sites and an executable ordering in `21` §6.

One thing to mention rather than act on: the `🔎` announce for #293 was already present when I ran `post-once.sh`, from an earlier pass at this same head, so I posted nothing there.
ACTED_EOF

# THE OTHER HALF OF THAT TRAP, and the reason the verdict pattern anchors to
# position rather than to a head SHA. This is a `resume` session that did
# nothing and says so — while quoting a whole panel's approvals, its own
# signal marker from a PREVIOUS session, and a handoff. An earlier draft of
# the review-duty widening accepted `approved at <sha>` and flipped 45 corpus
# sessions of exactly this shape to `yes`; every one was false.
# captured: ~/duty/logs/20260806T055009Z-resume-heavy-duty_crew.log
cat >"$ALOG/quoted.log" <<'ACTED_EOF'
No action taken, and nothing posted — correctly so.

**PR #376 is finished, not stranded.** The resume wake named it, but the thread shows the round is complete and handed off:

- Head `019db9b` (last commit 2026-08-05T23:57:23Z, unchanged since)
- My `📣 round answered at head 019db9b4c85485910ee1c4b6adc429650dcd924e` posted at 01:01:31Z
- All three panelists — claude-bot, codex-bot, kimi-bot — APPROVED **at that exact head** (01:10Z / 01:13Z / 01:19Z)
- `🤝 handed off at head 019db9b…` posted 01:21:50Z, `state:needs-human` set, `requested_reviewers` now just `danmt`
- Rollup green at head: `guards` success, `ci-shell` success, `labels / scope` success, `labels / trigger` success

Re-signalling here would re-request an already-unanimous panel on a PR the human now owns — the exact marker flood #145/#311 forbid.

No other work was outstanding: no draft PRs, no orphaned claimed issues. Session exits silent.
ACTED_EOF

# The two false `no`s claude-bot recorded OUTSIDE the review duty are on its
# box, not this one — but the same verb gap has a third victim here, and this
# one is captured locally and confirmed against the API.
#
# captured: ~/duty/logs/20260821T171004Z-attention-heavy-duty_incubator_368.log
# GitHub:   heavy-duty/incubator comments 5373060777 (17:21:30Z) and
#           5373073792 (17:22:46Z), commits 5e05c607 and 44d11ae2
#
# It posted an ack, removed a label, pushed two commits, posted three comments
# including its own round-answered signal — and read as `no`, because the idle
# net hits `test` STILL RUNNING and none of its act reports is in a shape the
# act pattern could see. `**The ack.** Posted ...` is not sentence-initial: the
# anchor wants a full stop followed by a SPACE, and here the stop is inside the
# bold run. What rescues it is `which I declared explicitly`, one of the two
# verbs claude-bot offered as cheap and non-blocking. It is the only verdict in
# 1066 that either verb moves, and it is true.
cat >"$ALOG/declared.log" <<'ACTED_EOF'
Done — here's where #368 and PR #378 stand.

**The ack.** Posted `📌 picked up` on #368 and removed the `attention` label (it re-arms the wake).

**What the demand was.** Triage's 17:05:09Z correction left exactly one item on my side — *"the mutation proof of conditions (a) and (b) against the must-fail bullet"* — plus the instruction not to invert the two `indexOf` ordering assertions. While reading the thread I found a **completed panel round** at head `5931c44f`: kimi approve, codex approve, claude-bot **changes requested**. So the tick carried both.

**1. The mutation proof** ([comment](https://github.com/heavy-duty/incubator/pull/378#issuecomment-5373073792)) — 28 mutants plus a baseline control, each applied and reverted, head unmoved and tree clean throughout:

- **(a)** all **21** inverted `(assertion, subject)` pairs reached and red, each from its own Spanish sentence injected into the English copy string that renders in its place. That includes the two that were silently deleted at `3c4312c`. Nine pairs are shadowed by an earlier assertion in the same test (html legs behind their body sibling; `emails.test.ts` ll. 289/292 behind the byte-exact `toBe`; l. 59's `questions` iteration behind `confirmation`) — those runs scaffold the shadowing assertion out, which I declared explicitly rather than glossing.
- **(b)** three single-character mutants each red exactly their own body; two end-of-body append mutants red **only** the three `toBe` tests while all 30 substring assertions stay green — which is the discriminator the must-fail bullet is actually about.
- Collateral worth having: the injected multi-locale ordering tests and the hash-based byte-identity test red on the copy mutants, so the relocated coverage is live.

**2. The round** — agreed with every point, disputed none ([pickup + analysis](https://github.com/heavy-duty/incubator/pull/378#issuecomment-5373060777)):

- 🔴 **Criterion 5 was genuinely violated.** My `legalCopy.test.ts` comment stated the jurisdiction outright, at the exact site the deleted sentence occupied, while three other sites in the same diff carry the discipline. Re-cut to *"the operator's own record contradicts the denial"* (`5e05c607`). I also swept the whole diff's added lines for a fourth site — exactly one existed, and `template-dist.test.ts`'s registered-address comment correctly stays.
- 🟡 The `templates/_fixture` comment claimed `legalCopy.test.ts` drives the fixture; verified it doesn't and re-cut it (`44d11ae2`), with PR body position 2 corrected.
- 🟡 Criterion 6's stale `[⚠️]` needed no change — it has been `[x]` since the 17:08 re-signal.

Both commits are comment-only: no assertion, source file or shipped copy string moved. `npm run check` (554 files), `intake-web` (254), `ui-core` (`tsc` + 55) and the two admitted `apps/core` files (33) all green locally; PR body carries the round-2 worklog and round-log entry; `📣 round answered at head 44d11ae262d511032f69ce26406268f9f1cd2cf6` posted. I did not request the panel — the engine does that from the signal.

**Open.** CI at the new head: `check`, `guards`, `refs-not-closing`, both `labels` jobs green; `test` still running (started 17:24Z) — a watcher will bring me back when it settles, and if it reds on comment-only commits I'll treat it as mine to diagnose first.

**One thing for you, outside this PR:** `docs/brain/STATE.md`'s #368 row still reads *"Blocked, operator-owned — a second-episode `needs-ruling` hard block stands"*. That has been false since the 14:32:47Z ruling; the row now describes a build in flight. I left it alone rather than opening a second PR mid-round, but it will mislead the next orientation until the merge record runs.
ACTED_EOF

# D4's THIRD state — "a transcript the profile does not recognise" — on the
# only log in 1065 that is one. Fifty-eight bytes of a session cut off after a
# probe result: it names nothing this engine does, so whether it acted is not
# ambiguous, it is absent. D3 governs ambiguity; this is not that.
# captured: ~/duty/logs/20260815T080517Z-build-heavy-duty_ceremony.log
cat >"$ALOG/frag.log" <<'ACTED_EOF'
Probe 4 passed (tags 1→1, releases 1→1). Four remain.
ACTED_EOF

# And a transcript from a different runtime altogether, which is the same
# state arriving the other way: prose, first-person, and about nothing this
# profile reads. It is the fixture `shared/test/common/session.sh` used to
# assert `unknown` with, kept here now that the stub it relied on is gone.
printf 'Claude Code\nfinal answer: I need more information.\n' >"$ALOG/foreign.log"

# `Execution error` is what the CLI prints when it dies before the model
# speaks: fifteen bytes and NO trailing newline. All 26 in the corpus.
printf 'Execution error' >"$ALOG/fault.log"
# The vendor's refusal banners. A session that hit the weekly cap or a dead
# login never reached the model at all — 40 of the 1064 are one of these.
printf "You've hit your session limit \xc2\xb7 resets 1:20am (UTC)\n" >"$ALOG/quota.log"
printf "You've hit your weekly limit \xc2\xb7 resets 9am (UTC)\n" >"$ALOG/weekly.log"
printf "Not logged in \xc2\xb7 Please run /login\n" >"$ALOG/nologin.log"
: >"$ALOG/empty.log"

terminal_rc() {  # terminal_rc <agent> <log> -> raw rc of the profile hook
  local rc=0
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; bot_session_terminal "$2" ) \
    >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
t terminal-claude-observed-session-limit 0 "$(terminal_rc claude "$ALOG/quota.log")"
t terminal-claude-observed-weekly-limit 0 "$(terminal_rc claude "$ALOG/weekly.log")"
printf '%s\n' "You've hit your weekly limit · resets 9am (UTC)" \
  'transient network failure: dial tcp i/o timeout' >"$ALOG/quota-then-transient.log"
t terminal-claude-quoted-quota-ending-transient 1 \
  "$(terminal_rc claude "$ALOG/quota-then-transient.log")"
t terminal-claude-login-failure-is-not-guessed 1 "$(terminal_rc claude "$ALOG/nologin.log")"

profile_breaker_reach() ( # profile terminal-text -> terminal|failed
  local profile="$1" terminal_text="$2" bdir="$TMP/profile-breaker-$1" output
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=fixture
  SESSION_TERMINAL_THRESHOLD=1
  export PROFILE_BREAK_TEXT="$terminal_text"
  # shellcheck disable=SC1090
  source "$SHARED/conf/agents/$profile.conf"
  # shellcheck disable=SC2016  # expanded by the fixture CLI, not this suite
  BOT_CLI_CMD=(bash -c 'printf "%s\n" "$PROFILE_BREAK_TEXT"; exit 1')
  alert() { :; }
  output="$(run_session review fixture/repo "$bdir/work" 5 prompt)"
  if grep -q 'outcome=TERMINAL' <<<"$output"; then
    printf terminal
  else
    printf failed
  fi
)
t terminal-breaker-reaches-claude terminal \
  "$(profile_breaker_reach claude "You've hit your weekly limit · resets 9am (UTC)")"
t terminal-breaker-reaches-kimi terminal \
  "$(profile_breaker_reach kimi "provider error: {'type': 'access_terminated_error'}")"
t terminal-breaker-does-not-guess-codex failed \
  "$(profile_breaker_reach codex "You've hit your weekly limit · resets 9am (UTC)")"
t terminal-breaker-does-not-guess-grok failed \
  "$(profile_breaker_reach grok "You've hit your weekly limit · resets 9am (UTC)")"

# The contract, on BOTH profiles, case for case. grok.conf carries the same
# detector as a second copy because a profile is transported one file at a
# time; this loop is what stops the copies drifting, and it is the only reason
# the duplication is safe.
for agent in claude grok; do
  # A session that wrote something: two comments posted and a label removed.
  t "acted-$agent-wrote-is-yes"        0 "$(acted_rc "$agent" "$ALOG/push.log")"
  # A session that only read: it says so, and nothing else in it says otherwise.
  t "acted-$agent-read-only-is-no"     1 "$(acted_rc "$agent" "$ALOG/read.log")"
  # D4, both halves, and neither folded into `no`.
  t "acted-$agent-empty-is-unknown"    2 "$(acted_rc "$agent" "$ALOG/empty.log")"
  t "acted-$agent-fault-is-unknown"    2 "$(acted_rc "$agent" "$ALOG/fault.log")"
  # A cap or a dead login is a session that never spoke, NOT one that did
  # nothing. Reading it as idle would have booked 40 of this box's sessions as
  # waste that no duty ever incurred.
  t "acted-$agent-quota-is-unknown"    2 "$(acted_rc "$agent" "$ALOG/quota.log")"
  t "acted-$agent-nologin-is-unknown"  2 "$(acted_rc "$agent" "$ALOG/nologin.log")"
  # D3, pinned by a real borderline transcript rather than by a paragraph: the
  # session was cut off one clause short of saying whether it posted. That is
  # the ambiguity the bias exists for, and it answers ACTED.
  t "acted-$agent-ambiguous-is-yes"    0 "$(acted_rc "$agent" "$ALOG/ambi.log")"
  # THE TRAP. This reply opens "Nothing to do on PR 376, and I posted nothing
  # to it" — and then updates a memory file. A no-op claim is about one
  # sub-action until the rest of the reply is read, so the claim is deleted
  # from the text BEFORE the evidence is looked for. A detector that stopped
  # at the first phrase books this session as idle; it was not.
  t "acted-$agent-subaction-claim-is-yes" 0 "$(acted_rc "$agent" "$ALOG/trap.log")"
  # Waiting on someone else's verdict is doing nothing, and says so.
  t "acted-$agent-waiting-only-is-no"  1 "$(acted_rc "$agent" "$ALOG/wait.log")"
  # The verb tail, outside the review duty: a session that acked, pushed twice
  # and commented three times, held on `no` by `still running` until `declared`
  # entered the list. Non-blocking in review; it is a case because a widening
  # nobody can red is a widening nobody can remove safely.
  t "acted-$agent-declared-is-yes"     0 "$(acted_rc "$agent" "$ALOG/declared.log")"
  # THE REVIEW DUTY, on whole captured transcripts. Both carry a real no-op
  # claim and both sessions submitted a verdict that is confirmed on GitHub:
  # one renders the marker as `PR N (repo) — approved`, the other as
  # `#N — <title> → approved` with a mid-sentence `verdicts submitted`. A
  # detector tuned on builder transcripts answered `no` to both, which is what
  # it did to 25 real reviewer sessions, and a detector fitted to one written
  # -down example still answered `no` to both, which is what it did to 5.
  t "acted-$agent-review-verdict-is-yes"   0 "$(acted_rc "$agent" "$ALOG/verdict.log")"
  t "acted-$agent-subjectless-verdict-is-yes" 0 "$(acted_rc "$agent" "$ALOG/passive.log")"
  # The three renderings whose whole transcript is not on this box. Each line
  # is verbatim from claude-bot's round-2 table on PR #522, where it was read
  # out of the named log and its act confirmed against the GitHub API; the
  # session ids are recorded so a later round can swap in the whole file. They
  # are asserted against the pattern rather than against an rc, because a
  # one-line fixture would answer `yes` from D3's default whatever the pattern
  # did — the vacuous shape a mutation caught in round 1.
  #
  # 20260818T195008Z-review-heavy-duty_lafamilia-site — APPROVED @ `901a672`.
  # No `#`, and a backticked title between the dash and the verdict. The title
  # holds a version number, so a span matched as "anything up to a full stop"
  # ends early on `0.7.4` and misses — the defect claude-bot named in its own
  # probe of this fix, which is why the span is matched as a delimited one.
  # shellcheck disable=SC2016  # backticks are the captured marker's own
  t "acted-$agent-rendering-title-span-is-verdict" yes "$(acted_verdict_line "$agent" \
    '**PR 30 — `chore: bump ceremony to 0.7.4` — approved** at head `901a672`')"
  # 20260806T144555Z-operator-floor-2fb41ac8 — CHANGES_REQUESTED @ `b05c2a9`.
  # No reference and no verdict noun as subject: the verb leads, and its
  # object is the verdict.
  # shellcheck disable=SC2016  # backticks are the captured marker's own
  t "acted-$agent-rendering-submitted-verdict-is-verdict" yes "$(acted_verdict_line "$agent" \
    'submitted `request-changes` via `submit-verdict.sh`')"
  # 20260818T122010Z-review-heavy-duty_incubator — announce comment posted.
  # Form B with the noun singular and unlisted.
  t "acted-$agent-rendering-announce-posted-is-verdict" yes "$(acted_verdict_line "$agent" \
    'Announce posted and verified.')"
  # The fourth rendering, and the ONE arm the rc cases cannot speak for: the
  # `passive.log` session leads with `verdicts submitted` mid-sentence, but it
  # also carries the `#293 — <title> → approved` marker, so its rc is already
  # `yes` from the marker arm and a mutation removing the clause anchor left
  # every case green. That is the vacuous shape again, one arm lower down.
  # Asked of the line, it is the clause anchor or nothing.
  t "acted-$agent-rendering-midsentence-verdicts-is-verdict" yes "$(acted_verdict_line "$agent" \
    'Both PRs reviewed at their current heads, verdicts submitted, worktrees removed, clone clean.')"
  # And the same helper on the quoting forms, which must stay refused: this is
  # where the widening above would have cost the idle column if the anchor had
  # slipped from "clause boundary" to "anywhere".
  t "acted-$agent-rendering-quoted-panel-is-not-verdict" no "$(acted_verdict_line "$agent" \
    '- All three panelists — claude-bot, codex-bot, kimi-bot — APPROVED **at that exact head**')"
  t "acted-$agent-rendering-zero-verdicts-is-not-verdict" no "$(acted_verdict_line "$agent" \
    'The round is not answered: zero verdicts submitted at that head, and no verdict submitted since.')"
  # ...and the guard that stops that widening eating the idle column: a
  # resumption QUOTING a panel's approvals, its own earlier signal and a
  # handoff, having done nothing. Position, not proximity to a SHA.
  t "acted-$agent-quoted-verdict-is-no"    1 "$(acted_rc "$agent" "$ALOG/quoted.log")"
  # D4's third clause, both doors: a fragment that names nothing this engine
  # does, and a transcript from another runtime. Neither is `no` — the
  # session's acts are not undecided here, they are unstated — and neither is
  # `yes`, which is where an un-gated D3 default put them.
  t "acted-$agent-fragment-is-unknown"     2 "$(acted_rc "$agent" "$ALOG/frag.log")"
  t "acted-$agent-foreign-log-is-unknown"  2 "$(acted_rc "$agent" "$ALOG/foreign.log")"
  # The banner filter is asserted on the PROSE, not on the verdict, because
  # the verdict no longer distinguishes it: the recognition gate answers
  # `unknown` for a banner-only log with the filter removed, and does so
  # identically on all 1065 captured logs. Its remaining guarantee is the
  # narrower one — that a vendor banner never enters the text the patterns
  # read, however loose those patterns grow — so that is where it is pinned.
  # A case on the rc here would be a case no mutation can kill.
  t "acted-$agent-banner-leaves-no-prose" "" "$(acted_prose "$agent" "$ALOG/quota.log")"
done

# The three states survive session_acted's mapping and reach duty.log as the
# words the operator's aggregate greps for. `unknown` is the one that must
# still be reachable: before this change it was the ONLY reachable value.
t acted-word-yes     yes     "$(acted_word claude "$ALOG/push.log")"
t acted-word-no      no      "$(acted_word claude "$ALOG/read.log")"
t acted-word-unknown unknown "$(acted_word claude "$ALOG/empty.log")"

# codex and kimi are out of scope (#467 D6) and stay byte-identical. Pinned by
# content rather than by `git diff`, which would assert nothing the moment this
# branch merges: these two lines ARE the two detectors, and a suite that reds
# when they move is the durable form of "unchanged".
t acted-codex-detector-untouched \
  "grep -Eq '(^|[[:space:]])(exec|apply_patch)([[:space:]]|\$)|^tool (call|result)' \"\$1\"" \
  "$(sed -n '/^bot_session_acted()/,/^}/p' "$SHARED/conf/agents/codex.conf" | sed -n '2p' | sed 's/^  //')"
t acted-kimi-detector-untouched \
  "grep -Eq '(^|[^[:alpha:]])(Using|Used) Shell[[:space:]]*\\(' \"\$1\"" \
  "$(sed -n '/^bot_session_acted()/,/^}/p' "$SHARED/conf/agents/kimi.conf" | sed -n '2p' | sed 's/^  //')"

# D5: this issue makes an existing field truthful and gates nothing on it. The
# tempting one-liner is a dispatch gate keyed on the PREVIOUS session's
# `acted`, and it is a separate decision — so the absence is asserted, not
# promised. run_session must reach the CLI whatever the last session reported.
printf '%s SESSION END kind=mention key=r/x rc=0 dur=9s outcome=ok acted=no reply_tail=\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$TMP/duty-prior.log"
AWORK="$TMP/acted-work"; mkdir -p "$AWORK"
BOT_CLI_CMD=(bash -c 'printf "I posted nothing.\n"')
DUTY_LOG="$TMP/duty-prior.log" run_session mention r/x "$AWORK" 5 p >"$TMP/acted-gate.out" 2>&1
grep -q 'SESSION START' "$TMP/acted-gate.out" && r1=dispatched || r1=GATED
t acted-no-dispatch-gate-on-prior-acted dispatched "$r1"
unset BOT_CLI_CMD

# --- the operator's own aggregate, end to end (#467) ------------------------
#
# The criterion is stated as the command @danmt ran, not as a call into the
# library: real transcripts -> run_session -> duty.log -> awk. Every SESSION
# END line below is written by the engine, from a fixture the CLI actually
# emitted, so nothing between the detector and the `idle` column is stubbed.
AGG="$TMP/acted-duty.log"; : >"$AGG"
# The profile is sourced for real here, in a subshell so the suite's own scope
# stays as the cases above found it. Sourcing it is not a detail: session_acted
# resolves the hook through `declare -F`, so a box whose profile defines none
# answers `unknown` for every session it ever runs — which is grok's half of
# this bug, and running the aggregate without the source would reproduce
# `idle=0` here for exactly that reason.
(
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  for f in push read trap wait ambi verdict quoted empty fault quota; do
    # The stub IS the CLI: it replays one captured transcript verbatim. $0 is
    # the fixture because run_session appends the prompt as the final argument.
    # shellcheck disable=SC2016  # $0 is the shim's own argument, not this shell's
    BOT_CLI_CMD=(bash -c 'cat -- "$0"' "$ALOG/$f.log")
    run_session mention "r/$f" "$AWORK" 10 p >>"$AGG" 2>/dev/null
  done
)

# The aggregate, as it was run: sessions, minutes, and idle by duty.
agg_idle() { awk '/SESSION END/ {
    for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
    if (f["acted"] == "no") idle[f["kind"]]++
    n[f["kind"]]++
  } END { for (k in n) printf "%s sessions=%d idle=%d\n", k, n[k], idle[k] + 0 }' "$1"
}
agg="$(agg_idle "$AGG")"
t acted-aggregate-counts-every-session "sessions=10" \
  "$(printf '%s\n' "$agg" | sed -n 's/.*\(sessions=[0-9]*\).*/\1/p')"
# The whole point. `idle=0` across 4150 sessions was a disabled detector; an
# `idle` equal to the session count would be a detector stuck the other way.
idle_n="$(printf '%s\n' "$agg" | sed -n 's/.*idle=\([0-9]*\).*/\1/p')"
[ "${idle_n:-0}" -gt 0 ] && [ "${idle_n:-10}" -lt 10 ] && r1=non-degenerate || r1="degenerate(idle=$idle_n)"
t acted-aggregate-idle-is-non-degenerate non-degenerate "$r1"

# --- role box sizing: the reviewer is the builder's size (#607) -------------
# The reviewer was sized "lean" at half the builder's box on a premise that is
# false in both halves — its worktrees are not throwaway (#606) and session
# LENGTH does not set peak RSS, the heaviest single command does. That command
# is the builder's own suite, re-run to verify it, plus a mutation probe over a
# corrupted copy, plus lint sweeps the builder never runs. It killed a
# ShellCheck sweep twice with exit 137 on the box these numbers replace.
#
# READ FROM BOTH FILES, never two hardcoded copies (#607 acceptance criterion
# 1): a test that pins 4/8GiB/60GiB in its own source goes green on a day
# someone trims reviewer.conf back and updates the literal beside it, which is
# the whole failure this asserts against. What is asserted is the RELATION.
box_sizing_of() {  # box_sizing_of <role>
  bash -c '. "$1"; printf "%s/%s/%s\n" "${BOX_CPU:-}" "${BOX_MEMORY:-}" "${BOX_DISK:-}"' \
    _ "$SHARED/conf/roles/$1.conf" 2>/dev/null
}
t role-sizing-reviewer-matches-builder "$(box_sizing_of builder)" "$(box_sizing_of reviewer)"
# ...and the relation is only worth asserting over figures that are actually
# there: two roles that both failed to declare any would compare equal as
# "//" and pass a suite that had proved nothing.
case "$(box_sizing_of reviewer)" in
  */*/*) [ -n "$(box_sizing_of reviewer | tr -d '/')" ] && r1=declared || r1=empty ;;
  *) r1=malformed ;;
esac
t role-sizing-reviewer-is-declared declared "$r1"

# D2: the comment above those numbers is the deliverable as much as they are —
# it is the reasoning that produced the wrong figure, and left in place it is
# what restores them in six months. The two dead words must be gone, and the
# real reason must be named.
reviewer_comment="$(sed -n '/^# Box resources/,/^BOX_CPU=/p' "$SHARED/conf/roles/reviewer.conf")"
t role-sizing-reviewer-comment-drops-lean 0 \
  "$(grep -ci 'lean' <<<"$reviewer_comment" || true)"
t role-sizing-reviewer-comment-drops-throwaway 0 \
  "$(grep -ci 'throwaway detached worktrees' <<<"$reviewer_comment" || true)"
for needle in 'mutation probe' "builder's whole suite"; do
  t "role-sizing-reviewer-comment-names-${needle// /-}" 1 \
    "$(grep -cF "$needle" <<<"$reviewer_comment" || true)"
done

# D3: triage is LEFT ALONE. "Reads boards and launches short sessions" is
# accurate — no docker, no suites, no toolchains — and resizing it on the
# reviewer's reasoning would be the same mistake in the other direction. The
# figures are pinned literally here on purpose: this one is a "did not move"
# assertion, so deriving it from the file it guards would assert nothing.
t role-sizing-triage-unchanged "2/4GiB/30GiB" "$(box_sizing_of triage)"

suite_finish
