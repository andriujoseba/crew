#!/usr/bin/env bash
# notify.sh — the operator's merge queue, in one Telegram thread. A fleet
# SINGLETON service: it runs on the triage box only (see crontab.example),
# but lives in the shared tree so there is exactly one source of it.
#
# Watches every repo the fleet can touch for open PRs carrying the builder's
# state:needs-human handoff label, and keeps ONE message per PR alive for
# its whole life: sent when the PR needs the operator, edited in place when
# it is merged, closed, or the label is withdrawn. The chat therefore reads
# as a live list — 🟣 is your queue, ✅/✖/↩ is history — instead of an
# append-only feed the operator has to reconcile by hand.
#
# NOT a triage actor: it launches no session, writes nothing to any board,
# and takes no GitHub action. It reads PRs and sends Telegram. Keep it that
# way — the whole reason it can run unattended is that its blast radius is
# one chat.
#
# Deliberately NOT inferring readiness from approval counts: the panel size
# varies per repo, so counting fires at 2-of-3 while a verdict is still
# inbound, and a ping that cries "mergeable" before the round closes trains
# the operator to ignore it. The handoff label is the trigger and the only
# trigger. A missed handoff is a builder bug — fix it in the builder.
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

# Manual runs take the same lock the cron tick uses (tick.sh notify). Own
# guard variable: a leaked DUTY_LOCKED from a duty session must not bypass
# the notify lock.
if [ -z "${NOTIFY_LOCKED:-}" ]; then
  # `|| rc=$?` is load-bearing under `set -e`: a bare non-zero flock exits the
  # shell HERE, so the sentinel message below never ran and a contended run
  # printed nothing at all. Identical to the duty.sh defect (#30); this file
  # was missed by that fix and found by its own audit task.
  rc=0
  env NOTIFY_LOCKED=1 DUTY_DIR="$DUTY_DIR" flock -n -E 199 "$DUTY_DIR/.notify.lock" "$0" "$@" || rc=$?
  # An `if` block, not `[ … ] && echo …`: that form returns 1 on a non-199
  # exit and, as the last command before `exit`, would take `set -e` with it
  # — the same shape as the install.sh bug behind #25.
  if [ "$rc" -eq 199 ]; then
    echo "notify.sh: a tick already holds $DUTY_DIR/.notify.lock — nothing run" >&2
  fi
  exit "$rc"
fi
trap 'rm -f "$DUTY_DIR/.notify.lock.since"' EXIT
date +%s >"$DUTY_DIR/.notify.lock.since"

# shellcheck source=../lib/common.sh disable=SC1091
source "$DUTY_DIR/lib/common.sh"
load_conf

STATE="$DUTY_DIR/.notify-state"          # repo \t pr \t head \t message_id \t status
NOTIFY_REPOS="$DUTY_DIR/notify-repos.txt"

log "notify run start"
[ -f "$STATE" ] || : >"$STATE"

if [ ! -r "$HOME/.tg_bot_token" ] || [ ! -r "$HOME/.tg_chat_id" ]; then
  log "tg: credentials missing — nothing to do"
  log "notify run end"
  exit 0
fi
TOK="$(cat "$HOME/.tg_bot_token")"
CHAT="$(cat "$HOME/.tg_chat_id")"

# --- telegram -------------------------------------------------------------
# Both helpers are non-fatal by contract: a dead notification path must
# never take the loop down with it, or a Telegram outage becomes a silent
# blackout with no record of what was missed.

tg_send() {  # $1 text -> prints message_id, empty on failure
  local resp
  resp="$(curl -sS -m 15 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true" 2>/dev/null)" || { log "tg: send failed"; return 0; }
  jq -r 'if .ok then (.result.message_id|tostring) else empty end' <<<"$resp" 2>/dev/null || true
}

tg_edit() {  # $1 message_id, $2 text -> 0 always
  local resp ok
  # No message to edit (legacy adopted row, or a send that failed): nothing
  # to do, and NOT an error. Guarded in the callee so call sites stay clean.
  if [ "$1" = "-" ] || [ -z "$1" ]; then return 0; fi
  resp="$(curl -sS -m 15 -X POST "https://api.telegram.org/bot${TOK}/editMessageText" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "message_id=$1" \
    --data-urlencode "text=$2" \
    --data-urlencode "disable_web_page_preview=true" 2>/dev/null)" || { log "tg: edit failed (net)"; return 0; }
  ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null || echo false)"
  # "message is not modified" is a success for our purposes.
  [ "$ok" = "true" ] || log "tg: edit rejected — $(jq -r '.description // "?"' <<<"$resp" 2>/dev/null)"
  return 0
}

# --- repo set -------------------------------------------------------------
# The work registry always participates: working a repo implies notification
# coverage. notify-repos.txt is additive for cross-repo handoff targets, NOT
# an alternative registry and NOT org discovery (see that file for costs).
# read_repo_list tolerates the missing file, making the fallback the union's
# degenerate case while retaining its operator-visible log line.
if [ ! -r "$NOTIFY_REPOS" ]; then
  log "notify-repos.txt missing — falling back to repos.txt"
fi
repos="$({
  read_repo_list "$REPOS_FILE"
  [ ! -r "$NOTIFY_REPOS" ] || read_repo_list "$NOTIFY_REPOS"
} | sort -u)"

state_put() {  # $1 repo $2 pr $3 head $4 msgid $5 status
  # Same-directory temp file: mktemp's default /tmp can be a different
  # filesystem, where mv is copy+unlink and a crash mid-copy truncates the
  # state. Same-dir rename is atomic.
  local tmp; tmp="$(mktemp "$STATE.tmp.XXXXXX")"
  grep -vP "^\Q$1\E\t\Q$2\E\t" "$STATE" >"$tmp" 2>/dev/null || true
  # "-" not "": with IFS=$'\t' bash collapses runs of tabs, so an empty
  # field silently shifts every later field left.
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" "$5" >>"$tmp"
  mv "$tmp" "$STATE"
}

body_pending() {  # repo pr title head
  printf '🟣 NEEDS YOU — %s#%s\n%s\npanel approved %s · zero blockers\nhttps://github.com/%s/pull/%s' \
    "$1" "$2" "$3" "${4:0:7}" "$1" "$2"
}

# --- 1. sweep for new handoffs -------------------------------------------
found=0
FLAGGED=""   # every "repo<TAB>PR" line the label sweep saw, for the invariant
for R in $repos; do
  # shellcheck disable=SC2016  # $L is a jq binding, not a shell expansion
  prs="$(NF_LABEL="$LABEL_NEEDS_HUMAN" NF_BLOCKER="$BLOCKER_PREFIX" \
    gh pr list -R "$R" --state open --limit 100 \
        --json number,title,isDraft,headRefOid,labels \
        --jq '[ .[]
      | select(.isDraft | not)
      | ([ .labels[].name ]) as $L
      | select($L | index(env.NF_LABEL))
      | select([ $L[] | startswith(env.NF_BLOCKER) ] | any | not)
      | {number, title, head: .headRefOid} ]' 2>/dev/null)" || continue
  [ -z "$prs" ] && continue

  while IFS=$'\t' read -r pr_num pr_head pr_title; do
    [ -z "$pr_num" ] && continue
    found=$((found+1))
    FLAGGED="${FLAGGED}${R}	${pr_num}
"
    line="$(grep -P "^\Q$R\E\t\Q$pr_num\E\t" "$STATE" 2>/dev/null || true)"
    s_status=""; s_head=""; s_msg="-"
    [ -n "$line" ] && IFS=$'\t' read -r _ _ s_head s_msg s_status <<<"$line"
    # Only a `pending` row is a live message to update. merged/closed/
    # cleared are NOT terminal: a handoff withdrawn by a new push comes back
    # every time the builder re-earns approval, and a closed PR can reopen.
    # Falling through to the fresh send below is what makes a relapse notify
    # again — treating those as final is how cast#143 sat flagged and silent
    # for hours.
    if [ "$s_status" = "pending" ]; then
      if [ "$s_head" != "$pr_head" ] && [ "$s_msg" != "-" ]; then
        # A new push means the approvals it was handed off on are stale.
        tg_edit "$s_msg" "$(body_pending "$R" "$pr_num" "$pr_title" "$pr_head")"
        state_put "$R" "$pr_num" "$pr_head" "$s_msg" pending
        log "$R#$pr_num: head moved -> ${pr_head:0:7}, message updated"
      elif [ "$s_msg" = "-" ]; then
        # Legacy row with no trackable message: adopt with a fresh send.
        mid="$(tg_send "$(body_pending "$R" "$pr_num" "$pr_title" "$pr_head")")"
        state_put "$R" "$pr_num" "$pr_head" "${mid:--}" pending
        log "$R#$pr_num: adopted legacy entry (msg ${mid:-none})"
      fi
      continue
    fi
    mid="$(tg_send "$(body_pending "$R" "$pr_num" "$pr_title" "$pr_head")")"
    state_put "$R" "$pr_num" "$pr_head" "${mid:--}" pending
    log "$R#$pr_num: notified needs-human at ${pr_head:0:7} (msg ${mid:-none})"
  done < <(jq -r '.[] | [ (.number|tostring), .head, .title ] | @tsv' <<<"$prs")
done

# --- 2. resolve everything still pending ---------------------------------
# Runs over the state file, NOT the label sweep: the whole point is to catch
# PRs that have LEFT the needs-human set — a merged PR no longer carries the
# label, so a label-driven pass can never close its message.
resolved_now=""
while IFS=$'\t' read -r R pr_num s_head s_msg s_status; do
  [ "${s_status:-}" = "pending" ] || continue
  [ -z "${R:-}" ] && continue
  info="$(gh pr view "$pr_num" -R "$R" --json state,title,mergedAt,labels 2>/dev/null)" || continue
  st="$(jq -r '.state' <<<"$info")"
  title="$(jq -r '.title' <<<"$info")"
  has_label="$(jq -r --arg l "$LABEL_NEEDS_HUMAN" '[.labels[].name] | index($l) != null' <<<"$info")"
  url="https://github.com/$R/pull/$pr_num"

  case "$st" in
    MERGED)
      when="$(jq -r '.mergedAt // ""' <<<"$info")"
      tg_edit "$s_msg" "$(printf '✅ MERGED — %s#%s\n%s\nmerged %s\n%s' \
        "$R" "$pr_num" "$title" "$when" "$url")"
      state_put "$R" "$pr_num" "$s_head" "$s_msg" merged
      resolved_now="$resolved_now$R#$pr_num "
      log "$R#$pr_num: merged — message closed"
      ;;
    CLOSED)
      tg_edit "$s_msg" "$(printf '✖ CLOSED unmerged — %s#%s\n%s\n%s' \
        "$R" "$pr_num" "$title" "$url")"
      state_put "$R" "$pr_num" "$s_head" "$s_msg" closed
      resolved_now="$resolved_now$R#$pr_num "
      log "$R#$pr_num: closed unmerged — message closed"
      ;;
    OPEN)
      if [ "$has_label" != "true" ]; then
        tg_edit "$s_msg" "$(printf '↩ WITHDRAWN — %s#%s\n%s\nhandoff label removed; back with the builder\n%s' \
          "$R" "$pr_num" "$title" "$url")"
        state_put "$R" "$pr_num" "$s_head" "$s_msg" cleared
        resolved_now="$resolved_now$R#$pr_num "
        log "$R#$pr_num: label withdrawn — message closed"
      fi
      ;;
  esac
done <"$STATE"

pending="$(awk -F'\t' '$5=="pending"' "$STATE" 2>/dev/null | wc -l | tr -d ' ')"
log "sweep done — $(printf '%s\n' "$repos" | grep -c .) repos, $found flagged, $pending pending"

# --- 3. invariant: everything flagged must be tracked ---------------------
# flagged > pending means the sweep SAW a PR and did not track it — the PR
# is labelled for the operator and the operator will never hear about it.
# That is this script's worst failure because it is silent (cast#143 and
# ceremony#78 sat exactly there for an hour). This says it out loud, once
# per PR. A PR resolved between phase 1 and here (merged in the window) is
# NOT a desync — that race made the alarm cry wolf in the old version.
DESYNC="$DUTY_DIR/.notify-desync"
[ -f "$DESYNC" ] || : >"$DESYNC"
untracked=""
while IFS=$'\t' read -r R pr_num; do
  [ -z "${pr_num:-}" ] && continue
  case " $resolved_now" in *" $R#$pr_num "*) continue ;; esac
  if ! grep -qP "^\Q$R\E\t\Q$pr_num\E\t[^\t]*\t[^\t]*\tpending$" "$STATE" 2>/dev/null; then
    untracked="${untracked}${R}#${pr_num} "
    if ! grep -qxF "${R}#${pr_num}" "$DESYNC"; then
      tg_send "⚠️ notifier desync — ${R}#${pr_num}
carries $LABEL_NEEDS_HUMAN but is not being tracked, so it would never be announced.
This message is the bug report, not the handoff.
https://github.com/${R}/pull/${pr_num}" >/dev/null
      printf '%s\n' "${R}#${pr_num}" >>"$DESYNC"
    fi
  fi
done < <(printf '%s' "$FLAGGED")

if [ -n "$untracked" ]; then
  log "INVARIANT VIOLATED — flagged but untracked: ${untracked}(operator NOT notified of these by the normal path)"
else
  # Resolved: forget the warnings so a future recurrence pings again.
  : >"$DESYNC"
fi
log "notify run end"
