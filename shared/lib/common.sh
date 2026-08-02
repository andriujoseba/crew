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
  local wire_answered="$MARK_ANSWERED" wire_handoff="$MARK_HANDOFF"
  [ ! -f "$CONF_DIR/fleet.conf" ] || source "$CONF_DIR/fleet.conf"
  MARK_REVIEWING="$wire_reviewing"
  MARK_PICKUP="$wire_pickup"
  MARK_RESUME="$wire_resume"
  MARK_ADDRESSING="$wire_addressing"
  MARK_ANSWERED="$wire_answered"
  MARK_HANDOFF="$wire_handoff"
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
  local dur=$((SECONDS - start)) verdict=ok acted reply_tail
  [ "$rc" -eq 124 ] && verdict=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && verdict=FAILED
  acted="$(session_acted "$slog")"
  reply_tail="$(session_reply_tail "$slog")"
  log "SESSION END kind=$kind key=$key rc=$rc dur=${dur}s outcome=$verdict acted=$acted reply_tail=$reply_tail"
  # Outcome exposed for callers that gate follow-up state on success (the seen-
  # ledger commits in duty-triage.sh) WITHOUT reintroducing the set -e abort a
  # failed session must never cause — return stays 0.
  RUN_SESSION_RC="$rc"
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

# panel_for_repo REPO DIR [AUTHOR] — the review panel of REPO as a JSON array
# of logins, author NOT yet subtracted. An optional `panel[AUTHOR]=` line wins
# over `panel=`; callers still subtract AUTHOR as a safety net.
# in the repo's own .github/labels.conf governs over any prose or hardcoded
# list — rig#120 shipped a kimi-less panel from a stale hardcoded roster.
# Resolution order: local clone (any default branch name), then the contents
# API (covers repos not yet cloned — the first tick must not run on the
# fallback bench when a panel= line exists), then FLEET_BENCH.
panel_for_repo() {
  local repo="$1" dir="$2" author="${3:-}" conf="" line=""
  if [ -d "$dir/.git" ]; then
    conf="$(git -C "$dir" show 'origin/HEAD:.github/labels.conf' 2>/dev/null || true)"
    [ -n "$conf" ] || conf="$(git -C "$dir" show 'origin/main:.github/labels.conf' 2>/dev/null || true)"
  fi
  if [ -n "$author" ]; then
    line="$(printf '%s\n' "$conf" | awk -v key="panel[$author]=" 'index($0,key)==1 { print; exit }')"
  fi
  [ -n "$line" ] || line="$(printf '%s\n' "$conf" | grep -m1 '^panel=' || true)"
  if [ -z "$line" ]; then
    conf="$(gh api "repos/$repo/contents/.github/labels.conf" --jq .content 2>/dev/null \
      | base64 -d 2>/dev/null || true)"
    if [ -n "$author" ]; then
      line="$(printf '%s\n' "$conf" | awk -v key="panel[$author]=" 'index($0,key)==1 { print; exit }')"
    fi
    [ -n "$line" ] || line="$(printf '%s\n' "$conf" | grep -m1 '^panel=' || true)"
  fi
  if [ -n "$line" ]; then
    printf '%s' "${line#*=}" | tr ', ' '\n' | sed '/^$/d' | jq -R . | jq -cs .
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

# --------------------------------------------------------------------------
# Git identity — the SECOND carrier of the box's login (#294).
#
# The builder-identity split rotated the gh credential on each box and touched
# nothing else that carries identity. git kept the pre-split account, so every
# commit a split box pushed was authored by another droid and GitHub bylined
# that droid on the builder's own PR. On 2026-08-02 that read as a two-box race
# on PR #292 when one box had done everything; the record's own operator could
# not tell the difference, and the investigation nearly filed the wrong bug.
#
# So identity has ONE source of truth — the gh credential — and every other
# carrier is DERIVED from it, never set beside it. That is the same rule #285
# found on the panel copy; this is the git copy.
#
# The address written is GitHub's ID-prefixed noreply form,
# `<id>+<login>@users.noreply.github.com`, because that is the form GitHub
# guarantees links a commit to an account for every account minted since
# 2017-07-18 — which is every account this fleet has. The bare
# `<login>@users.noreply.github.com` form is ACCEPTED and never WRITTEN: it
# bylines correctly for older accounts, and accepting it is what stops this
# code from rewriting a hand-swept box on every upgrade forever.
# --------------------------------------------------------------------------

# git_identity_login EMAIL — the GitHub login a noreply author address names,
# or nothing if the address is not one. Case-folded, because logins are
# case-insensitive and `git config` stores whatever was typed.
#
# Anything that is NOT a github noreply address names nobody here, on purpose.
# A box could in principle commit under a verified account email and byline
# correctly, but the fleet provisions noreply addresses only, so an address
# outside that shape is one nothing in this engine wrote — which is exactly
# the state #294 is about, and guessing at it would re-open the hole.
git_identity_login() {
  local email id
  email="${1:-}"
  # Trim the EDGES, never the middle. A value's leading/trailing space is a
  # shape a hand-edited config can still present, so trimming it reads the
  # address that was meant; whitespace INSIDE the address is a different
  # animal, and deleting it INVENTS an identity — `cnd grr@users.noreply.
  # github.com`, which GitHub attributes to nobody, would collapse into a
  # valid-looking `cndgrr` and green a box that bylines no account at all.
  # That is this file's own bug class one layer down, so an interior space
  # names nobody rather than being helpfully removed.
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  case "$email" in
    *[[:space:]]*) return 0 ;;
  esac
  email="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')"
  case "$email" in
    ?*@users.noreply.github.com) : ;;
    *) return 0 ;;
  esac
  email="${email%@users.noreply.github.com}"
  # Split at the FIRST '+': a GitHub login cannot contain one, so what precedes
  # it is the numeric account id and must look like one. A local part with a
  # non-numeric prefix is not an address GitHub issued, so it names nobody
  # rather than half-parsing into a login it does not carry.
  case "$email" in
    *+*)
      id="${email%%+*}"
      case "$id" in
        ''|*[!0-9]*) return 0 ;;
      esac
      email="${email#*+}"
      ;;
  esac
  [ -n "$email" ] || return 0
  printf '%s' "$email"
}

# git_identity_ok LOGIN — does git's configured author address resolve to
# LOGIN? The EMAIL decides and `user.name` does not: the address is what
# GitHub matches a commit to an account by, and the name is a display string
# that can attribute nothing. The name is still written on convergence, so the
# two halves of the byline agree for a human reading `git log`.
#
# `--global` is read DELIBERATELY, not by oversight. git resolves an author
# address from `GIT_AUTHOR_EMAIL`, then a repo-local `user.email`, then the
# global one — so this checks the last of three carriers. It is the only one
# the fleet has: nothing in shared/, cli/ or drill/ writes either of the other
# two (#294's audit, surface 3), and the global file is what convergence
# writes. Reading the EFFECTIVE identity instead would mean resolving it
# inside some repository, and converge_git_identity runs where there may not
# be one — trading a stated assumption for an unstated failure. If anything
# here ever starts exporting GIT_AUTHOR_EMAIL or writing a repo-local
# user.email, this check stops being the whole answer and must widen with it.
git_identity_ok() {
  local want have
  want="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ -n "$want" ] || return 1
  have="$(git_identity_login "$(git config --global user.email 2>/dev/null || true)")"
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# converge_git_identity [LOGIN] — make git's author identity name this box's
# own account. Returns 0 when git will byline this box, 1 when it would byline
# somebody else and that could not be repaired.
#
# CONVERGENCE, not a bare refusal, and the difference is load-bearing. #294
# proposed an assert that refuses on mismatch; a refusal alone is the
# stronger-sounding half of the fix and the weaker one in practice, because
# the gh credential arrives BY HAND after `crew hire` (`box shell <box>` →
# `gh auth login`). At provisioning time there is frequently no truth yet to
# copy, so a box that only refused would refuse every tick forever with
# nobody left to fix it — a fleet-wide brick shipped as a safety feature.
# Writing the copy at the first moment the source exists is what makes the
# invariant hold with no hand at all. The refusal is still here: it is what a
# non-zero return means, and duty.sh spends no session on one.
#
# The fast path is one local `git config` read and NO network — which is what
# every tick after the first pays. `gh api user` is called only when the copy
# is actually wrong, so the steady state costs nothing and the repair costs
# one request, once.
converge_git_identity() {
  local want="${1:-}" expect="${1:-}" pair id email had_email had_name
  if [ -n "$want" ] && git_identity_ok "$want"; then
    return 0
  fi
  # One call for both halves: the login names the account and the id builds the
  # address GitHub attributes by. Asking twice could straddle a credential
  # rotation and write a login with another account's id.
  pair="$(gh api user --jq '[.login, .id] | @tsv' 2>/dev/null | head -1 || true)"
  # Split in the shell rather than with `cut`. install.sh's fixture runs this
  # under a curated PATH that is the box's whole world, and every external
  # this reaches for is one more way a real install degrades into a diagnostic
  # nobody reads. A pair with no tab leaves id == want, which is not numeric
  # and is refused below — the malformed case needs no separate branch.
  want="${pair%%$'\t'*}"
  id="${pair#*$'\t'}"
  case "$id" in
    ''|*[!0-9]*) id="" ;;
  esac
  if [ -z "$want" ] || [ -z "$id" ]; then
    warn "git identity: cannot resolve this box's own account (gh credential dead?) — git config left untouched"
    return 1
  fi
  # The caller named a login; gh must still name the SAME one. duty.sh resolved
  # $ME from its own `gh api user` moments ago, and if the credential rotated
  # between that call and this one, converging on the login gh reports NOW
  # would write the new account, return 0, and hand the tick to a session
  # still running as the old $ME — sessions acting as one identity while
  # commits byline another, which is #294 restated one call later. So a
  # rotation refuses: write nothing, spend no session, and let the next tick
  # resolve both halves from a single consistent reading.
  if [ -n "$expect" ] &&
     [ "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" != \
       "$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "git identity: the gh credential now names '$want', but this tick is running as '$expect' — the credential rotated mid-tick; git config left untouched"
    return 1
  fi
  # Re-checked against the login gh just reported rather than the caller's:
  # this is the no-argument call (install.sh, which has no $ME) and the case
  # where a hand sweep already wrote the bare-login form. Both are already
  # converged and owe no write and no announcement.
  if git_identity_ok "$want"; then
    return 0
  fi
  email="$id+$want@users.noreply.github.com"
  had_email="$(git config --global user.email 2>/dev/null || true)"
  had_name="$(git config --global user.name 2>/dev/null || true)"
  if ! git config --global user.email "$email" || ! git config --global user.name "$want"; then
    warn "git identity: could not write git config — this box would commit as '${had_email:-nobody}'"
    return 1
  fi
  # Read back rather than trust the write. A `git config` that exits 0 against
  # a file some other setting shadows leaves the byline wrong while reporting
  # success, and a silent false green here is the whole bug a second time.
  if ! git_identity_ok "$want"; then
    warn "git identity: wrote $email, but git still reads '$(git config --global user.email 2>/dev/null || true)'"
    return 1
  fi
  log "git identity: converged to $want <$email> (was ${had_name:-unset} <${had_email:-unset}>)"
  # Once, by construction: the fast path above takes every later tick. An
  # operator learns that a box was committing under the wrong name at the
  # moment it stops, which is the only moment the fact is actionable.
  alert "🪪 $(hostname): git identity was <${had_email:-unset}> — now <$email> ($want)"
  return 0
}
