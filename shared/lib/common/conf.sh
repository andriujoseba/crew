# common/conf.sh — load_fleet_conf, load_conf, has_role, read_repo_list, render_prompt,
# panel_for_repo — the box's own configuration, and the files it reads to
# learn about a repository.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash

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
