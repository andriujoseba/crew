# common.sh — shared plumbing for the duty engine. Sourced, never executed.
#
# Everything here is fleet-invariant. The box's runtime comes from its agent
# profile (conf/agents/), the shape of its work from its role profile(s)
# (conf/roles/), the pairing from conf/instance.conf (written by install.sh),
# and fleet facts from conf/fleet.defaults.conf + conf/fleet.conf.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # path constants are consumed by the sourcing scripts

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
WORK_DIR="$DUTY_DIR/work"    # main clones, parked on the default branch, fetch-only
TREES_DIR="$DUTY_DIR/trees"  # one worktree per PR; review trees are detached throwaways
LOG_DIR="$DUTY_DIR/logs"     # one file per session — session stdout never
                             # interleaves with duty.log (it corrupted grok's
                             # and kimi's line-oriented metrics)
CONF_DIR="$DUTY_DIR/conf"
PROMPTS_DIR="$DUTY_DIR/prompts"
BIN_DIR="$DUTY_DIR/bin"
REPOS_FILE="$DUTY_DIR/repos.txt"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { log "WARN: $*"; }

# load_fleet_conf — shipped defaults first, operator values second. The board
# marks are a wire protocol and cannot be changed by an operator file.
# shellcheck disable=SC1091
load_fleet_conf() {
  source "$CONF_DIR/fleet.defaults.conf"
  local wire_reviewing="$MARK_REVIEWING" wire_pickup="$MARK_PICKUP"
  local wire_resume="$MARK_RESUME" wire_addressing="$MARK_ADDRESSING"
  [ ! -f "$CONF_DIR/fleet.conf" ] || source "$CONF_DIR/fleet.conf"
  MARK_REVIEWING="$wire_reviewing"
  MARK_PICKUP="$wire_pickup"
  MARK_RESUME="$wire_resume"
  MARK_ADDRESSING="$wire_addressing"
}

# load_conf — source the box's configuration: fleet facts, then the
# instance resolution install.sh wrote (BOT_AGENT + BOT_ROLES, derived from
# fleet.roster and the box name), then the agent profile (the
# runtime) and one role profile per role (the shape of the work).
# shellcheck disable=SC1091
load_conf() {
  load_fleet_conf
  source "$CONF_DIR/instance.conf"
  # shellcheck disable=SC1090
  source "$CONF_DIR/agents/$BOT_AGENT.conf"
  local role
  for role in $BOT_ROLES; do
    # shellcheck disable=SC1090
    source "$CONF_DIR/roles/$role.conf"
  done
  export PATH="${BOT_PATH_PREPEND:+$BOT_PATH_PREPEND:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

has_role() {
  case " $BOT_ROLES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# read_repo_list FILE — one owner/repo per line; strips comments, blanks and
# whitespace; tolerates a missing trailing newline. Every consumer goes
# through here: the raw-`cat` fallback in the old notify.sh would have fed
# comment prose to `gh pr list -R` (dan-claude-bot's crew report, BAD #10).
read_repo_list() {
  [ -f "$1" ] || return 0
  # Comments stripped BEFORE whitespace: "o/r  # note" must yield "o/r",
  # not "o/r#note".
  sed -e 's/#.*$//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"
}

# rotate_log FILE — keep one 5 MB generation. Logs previously grew unbounded
# on every box.
rotate_log() {
  local f="$1"
  [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 5242880 ] && mv "$f" "$f.1"
  return 0
}

# render_prompt FILE NAME=VALUE... — fill {{NAME}} slots in a prompt template.
# Pure bash: boxes differ in installed tools (no node on kimi's, no shellcheck
# either), so the engine depends only on bash+gh+jq+git+flock+timeout.
render_prompt() {
  local file="$1" out pair name value
  shift
  out="$(cat "$PROMPTS_DIR/$file")"
  for pair in \
    "DOCTRINE_ENTRYPOINT=${DOCTRINE_ENTRYPOINT:-AGENTS.md}" \
    "DOCTRINE_TRIAGE=${DOCTRINE_TRIAGE:-TRIAGE.md}" \
    "DOCTRINE_BUILDER=${DOCTRINE_BUILDER:-BUILDER.md}" \
    "DOCTRINE_REVIEWER=${DOCTRINE_REVIEWER:-REVIEWER.md}" \
    "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    out="${out//"{{$name}}"/"$value"}"
  done
  printf '%s' "$out"
}

# ensure_checkout REPO DIR — clone if missing, fetch if present, and
# fast-forward a CLEAN parked default branch so sessions read current
# doctrine (a frozen clone serves last month's AGENTS.md forever). Never
# force-updates: a dirty or diverged tree gets a warning, not a reset — a
# session owns its own git state.
ensure_checkout() {
  local repo="$1" dir="$2"
  if [ ! -d "$dir/.git" ]; then
    gh repo clone "$repo" "$dir" -- --quiet || { warn "clone of $repo failed"; return 1; }
  else
    git -C "$dir" fetch --quiet --all --prune || warn "fetch failed in $dir"
    local br
    br="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
    if [ -n "$br" ] && [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      git -C "$dir" merge --ff-only --quiet "origin/$br" 2>/dev/null \
        || warn "cannot fast-forward $dir (diverged?) — sessions may read stale doctrine"
    fi
  fi
}

# ensure_main_clone REPO DIR — parked main clone with a `fork` remote at the
# bot's fork. Builds happen in worktrees, never here (a crashed build
# corrupted claude-bot's build clone on 2026-07-22).
ensure_main_clone() {
  local repo="$1" dir="$2"
  local name="${repo##*/}"
  ensure_checkout "$repo" "$dir" || return 1
  git -C "$dir" remote get-url fork >/dev/null 2>&1 \
    || git -C "$dir" remote add fork "https://github.com/$ME/$name.git"
}

# run_session KIND KEY DIR TIMEOUT PROMPT — the only way a duty launches the
# box CLI. Adds what every hand-rolled variant lacked somewhere: a timeout (a
# hung session used to hold the flock forever, invisibly), captured exit
# status on every path, a per-session log file, and one structured outcome
# line in duty.log (the biggest logging gap in three of five metrics files).
run_session() {
  local kind="$1" key="$2" dir="$3" tmo="$4" prompt="$5"
  local slog rc=0 start
  mkdir -p "$LOG_DIR"
  slog="$LOG_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$kind-${key//[\/#]/_}.log"
  log "SESSION START kind=$kind key=$key timeout=${tmo}s log=$slog"
  start=$SECONDS
  # </dev/null: the CLI reads piped stdin to EOF as context, and stdin here
  # is the caller's while-read work list — without this, the first session
  # of a sweep swallowed every remaining repo (one-iteration loops).
  # env -u: sessions must not inherit the lock/snapshot guards, or a
  # duty.sh/notify.sh invocation from inside a session bypasses the flock.
  # timeout -k: a CLI that ignores TERM still dies 60s later.
  ( cd "$dir" && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
      timeout -k 60 "$tmo" "${BOT_CLI_CMD[@]}" "$prompt" ) </dev/null >"$slog" 2>&1 || rc=$?
  local dur=$((SECONDS - start)) verdict=ok
  [ "$rc" -eq 124 ] && verdict=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && verdict=FAILED
  log "SESSION END kind=$kind key=$key rc=$rc dur=${dur}s outcome=$verdict"
  # Outcome exposed for callers that gate follow-up state on success (the seen-
  # ledger commits in duty-triage.sh) WITHOUT reintroducing the set -e abort a
  # failed session must never cause — return stays 0.
  RUN_SESSION_RC="$rc"
  return 0
}

# --- Seen-ledgers: turn "signal is present" into "signal CHANGED since I last
# looked". A wake whose only clearing action is one the session may correctly
# DECLINE — mark a mention read, comment on a held discussion — re-fired every
# tick forever, spawning a full model session each time (the triage box's
# overnight Fable burn, 2026-07-25: 147 mention + 61 triage sessions in 3 days,
# board unchanged). Each ledger records, per thread/discussion id, the activity
# timestamp last handled; a session launches only for entries new or advanced,
# and the ledger is committed ONLY after run_session reports rc 0 — a crashed
# session leaves its ids uncommitted, preserving crash-only retry. ISO-8601
# timestamps, so a lexical compare is a chronological one.
ledger_filter() { # $1=ledger; stdin "id ts" lines; stdout new-or-advanced ones
  local ledger="$1"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (!($1 in seen) || seen[$1] < $2) print }
  '
}
ledger_suppressed() { # $1=ledger; stdin "id ts" lines; stdout the ones it HIDES
  # The exact inverse of ledger_filter, so the two can never disagree about
  # what was withheld. Set arithmetic on the two outputs cannot do this safely:
  # an empty "fresh" list makes `grep -vxF -f` match every line and report
  # nothing suppressed, which is the reading that matters most.
  local ledger="$1"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (($1 in seen) && !(seen[$1] < $2)) print }
  '
}

# report_suppressed STATEFILE LABEL — stdin: the "id ts" lines a ledger hid.
#
# A ledger trades a burn for SILENCE, and silence is how the fleet starves. An
# issue still carrying no label is a live violation of the board invariant; the
# engine must stop PAYING for it, not stop SAYING it. Without this, #59's fix
# would convert a loud expensive bug into a quiet cheap one and the invariant
# would rot unobserved — the same shape as #52 (an interlock that reads like
# coverage) and #50 (skip lines nobody reads).
#
# Warns when the suppressed SET CHANGES, not every tick: at one tick per five
# minutes a standing violation would otherwise write 288 identical lines a day
# and bury the log it is trying to inform. Removing the state file when the set
# empties means the next occurrence speaks up again.
# $3 overrides the reason phrase. The default describes a LEDGER suppression —
# a session saw the item and declined to clear it. Not every withheld set has
# that history: the attention wake reports demands in repos this box does not
# carry, which no session ever saw and which were never actionable here. Both
# lines land in the same duty.log, and with one phrasing they read as the same
# event (grok, #67).
report_suppressed() {
  local state="$1" label="$2"
  local why="${3:-unactioned since a previous session and now suppressed}"
  local items n
  items="$(sort)"
  if [ -z "$items" ]; then rm -f "$state"; return 0; fi
  if [ "$items" = "$(cat "$state" 2>/dev/null)" ]; then return 0; fi
  n="$(printf '%s\n' "$items" | awk 'NF{c++} END{print c+0}')"
  warn "$label: $n item(s) $why — $(printf '%s\n' "$items" | awk 'NF>=2{printf "%s(%s) ", $1, $2}')"
  printf '%s\n' "$items" >"$state"
}

report_suppressed_if_complete() { # $1=0|1 $2=state $3=label; stdin items
  local complete="$1" state="$2" label="$3" items
  items="$(cat)"
  if [ "$complete" -eq 1 ]; then
    printf '%s\n' "$items" | report_suppressed "$state" "$label"
  else
    log "$label: suppression report state unchanged after partial sweep"
  fi
}

ledger_commit() { # $1=ledger; stdin "id ts" lines; merge keeping max ts, atomically
  local ledger="$1" tmp
  tmp="$(mktemp "${ledger}.XXXXXX")"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (!($1 in seen) || seen[$1] < $2) seen[$1]=$2 }
    END { for (k in seen) print k, seen[k] }
  ' > "$tmp"
  mv -f "$tmp" "$ledger"
}

# alert MESSAGE — best-effort operator ping over Telegram. Non-fatal by
# contract: a dead notification path must never take a duty loop down.
# dan-claude-bot kept an unused tg_send "for the boot gate" — this wires it.
alert() {
  local token chat
  token="$(cat "$HOME/.tg_bot_token" 2>/dev/null)" || return 0
  chat="$(cat "$HOME/.tg_chat_id" 2>/dev/null)" || return 0
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  curl -sS -m 10 "https://api.telegram.org/bot$token/sendMessage" \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$1" \
    >/dev/null 2>&1 || log "alert send failed (non-fatal)"
  return 0
}

# panel_for_repo REPO DIR — the review panel of REPO as a JSON array of
# logins, author NOT yet subtracted. Doctrine (BUILDER.md): the `panel=` line
# in the repo's own .github/labels.conf governs over any prose or hardcoded
# list — rig#120 shipped a kimi-less panel from a stale hardcoded roster.
# Resolution order: local clone (any default branch name), then the contents
# API (covers repos not yet cloned — the first tick must not run on the
# fallback bench when a panel= line exists), then FLEET_BENCH.
panel_for_repo() {
  local repo="$1" dir="$2" line=""
  if [ -d "$dir/.git" ]; then
    line="$(git -C "$dir" show 'origin/HEAD:.github/labels.conf' 2>/dev/null \
      | grep -m1 '^panel=' || true)"
    [ -n "$line" ] || line="$(git -C "$dir" show 'origin/main:.github/labels.conf' 2>/dev/null \
      | grep -m1 '^panel=' || true)"
  fi
  if [ -z "$line" ]; then
    line="$(gh api "repos/$repo/contents/.github/labels.conf" --jq .content 2>/dev/null \
      | base64 -d 2>/dev/null | grep -m1 '^panel=' || true)"
  fi
  if [ -n "$line" ]; then
    printf '%s' "${line#panel=}" | tr ', ' '\n' | sed '/^$/d' | jq -R . | jq -cs .
  else
    # shellcheck disable=SC2086  # word splitting of the bench list is the point
    printf '%s\n' $FLEET_BENCH | jq -R . | jq -cs .
  fi
}

# validate_sha SHA — full 40-hex object id. Short SHAs broke submit gates
# (grok's crew report: an unvalidated short SHA burns the retry and never
# matches commit_id).
validate_sha() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    *) [ "${#1}" -eq 40 ] ;;
  esac
}

# --------------------------------------------------------------------------
# Credential state, REPORTED BY THE FLOW rather than polled.
#
# The floor used to answer "is this box authenticated?" by running `gh auth
# status` and the agent's bot_cli_probe inside every box on every 60s poll.
# Both touch the network — `gh auth status` is a real api.github.com
# round-trip — so the fleet spent ~7,000 requests a day re-deriving a fact
# that changes when a token expires, i.e. about monthly, and the probe's
# latency became a function of GitHub's.
#
# Nothing needs to ask. The engine already talks to GitHub every tick and is
# therefore the first thing to find out, for free, when a credential stops
# working. These helpers record what it learns; probe.sh only reads the files.
#
# One file PER SERVICE, never one shared file matched by substring: a gh
# failure whose message happens to contain the word "vendor" would otherwise
# condemn the vendor CLI too, and the operator would go re-login the wrong
# thing.
#   .auth-fail.<svc>       "<iso8601> <reason>"  — present only while broken
#
# One file, one boolean: present means broken, absent means working. No expiry
# date is recorded — see gh_identity for why a countdown was dropped.
# --------------------------------------------------------------------------

# note_auth_failure SVC REASON — record that SVC rejected us, once. Rewriting
# the file every tick would reset its mtime and make a credential that broke
# three days ago look like it broke just now, which is the one thing an
# operator reads a marker file for. First failure wins until it is cleared.
note_auth_failure() {
  # Two `local`s, not one: in `local a=$1 b=${a}` the b assignment runs before
  # a is in scope, so every service would have shared one `.auth-fail.` file.
  local svc="$1" reason="$2"
  local f="$DUTY_DIR/.auth-fail.$svc"
  [ -s "$f" ] && return 0
  # Newlines would turn one record into several and break the ::key contract
  # probe.sh emits it under; gh's errors are routinely multi-line. Flattened
  # ONCE and reused, so the log line and the Telegram alert cannot disagree
  # with the file about what went wrong.
  local flat
  flat="$(printf '%s' "$reason" | tr '\n\r' '  ' | cut -c1-200)"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$flat" >"$f"
  warn "auth: $svc rejected us — $flat"
  # An operator who is not watching the floor still needs to know: a box with
  # a dead credential does no work at all, and says so nowhere else until
  # someone looks. alert() is best-effort and never fails a tick.
  alert "🔑 $(hostname): $svc auth failed — $flat"
  return 0
}

# clear_auth_failure SVC — the credential works again. Logged, because a
# marker vanishing silently is indistinguishable from one never written.
clear_auth_failure() {
  local svc="$1"
  local f="$DUTY_DIR/.auth-fail.$svc"
  [ -f "$f" ] || return 0
  rm -f "$f"
  log "auth: $svc is working again"
  alert "✅ $(hostname): $svc auth restored"
  return 0
}

# gh_identity — the box's own login, and whether gh still works. Echoes the
# login, or nothing if the credential was rejected.
#
# This REPLACES a bare `gh api user`: same single call the tick was already
# making to resolve $ME, but its failure is now recorded rather than swallowed
# by `|| true`. That is the whole credential signal — a rejection at the
# moment a real request is rejected, which is a stronger claim than
# `gh auth status`, since that only proves the token authenticates against
# `GET /` and a token with the wrong scopes passes it happily.
#
# No expiry DATE is tracked, here or anywhere. Every provider expresses it
# differently — epoch millis, a JWT claim, an ISO string, or not at all — and
# two of the four agent CLIs cannot answer locally, so a countdown was the
# flaky part of an otherwise stable idea. Whether the credential works right
# now is the boolean that matters, and it is the one every provider agrees on.
gh_identity() {
  local login rc=0 err
  err="$(mktemp)"
  login="$(gh api user --jq .login 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$login" ]; then
    note_auth_failure gh "$(grep -iE 'message|401|403|error' "$err" | head -1 || printf 'gh api user exited %s' "$rc")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  clear_auth_failure gh
  printf '%s' "$login"
}

# check_vendor_credential — the agent CLI's login state, WITHOUT a network
# call, once per tick.
#
# The agent profile's bot_cli_present reads its own vendor's credential store
# and answers one boolean: usable, or not. Where a vendor records the expiry
# of the credential a HUMAN must renew (claude, kimi) the profile compares it
# against now; where the refresh token is opaque (codex, grok) presence is the
# best local answer and the profile says so by returning 2.
#
# bot_cli_probe (which may hit the network) is deliberately NOT called here.
# It stays for `crew hire` and the boot gate, where paying for certainty once
# is right; a per-tick check must be free.
check_vendor_credential() {
  if ! command -v bot_cli_present >/dev/null 2>&1; then
    return 0        # an older agent profile: report nothing, claim nothing
  fi
  # Three outcomes, not two. `|| rc=$?` rather than an if: the whole point is
  # the exact code, and under `set -e` a bare call returning 1 would kill the
  # tick. 2 means the profile cannot tell from local state — it must change
  # nothing, so a box whose vendor layout is unknown neither alerts falsely
  # nor has a stale failure silently cleared out from under it.
  local rc=0
  bot_cli_present || rc=$?
  case "$rc" in
    0) clear_auth_failure vendor ;;
    1) note_auth_failure vendor "${AGENT_LOGIN_HINT:-the agent CLI is not logged in}" ;;
    *) : ;;
  esac
  return 0
}
