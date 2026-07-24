# common.sh — shared plumbing for the duty engine. Sourced, never executed.
#
# Everything here is fleet-invariant. Per-bot facts (CLI command, auth probe,
# roles) come from conf/bot.conf; org-level facts (bench, labels, markers)
# from conf/fleet.conf. Both are sourced by load_conf below.
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

# load_conf — source fleet + bot config. bot.conf is installed per box by
# install.sh; fleet.conf is identical on every box.
# shellcheck disable=SC1091
load_conf() {
  source "$CONF_DIR/fleet.conf"
  source "$CONF_DIR/bot.conf"
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
  for pair in "$@"; do
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
  return 0
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
