#!/usr/bin/env bash
# CREW NOTE: operator merge queue over Telegram. Fires every 5m via cron (flock-guarded). Reads PRs, sends/edits one message per needs-human PR. Takes no board action.
# notify.sh — the operator's merge queue, in one Telegram thread.
#
# Watches every repo the fleet can touch for open PRs carrying the builder's
# state:needs-human handoff label, and keeps ONE message per PR alive for its
# whole life: sent when the PR needs the operator, edited in place when it is
# merged, closed, or the label is withdrawn. The chat therefore reads as a
# live list — 🟣 is your queue, ✅/✖/↩ is history — instead of an append-only
# feed the operator has to reconcile by hand.
#
# Split out of duty.sh's side-effect (f) on 2026-07-23. That version fired and
# forgot, deduped on repo#PR@head, and read repos.txt — which lists ceremony
# alone, so rig#112 sat needs-human for hours without ever pinging. Scope here
# is every heavy-duty repo plus the bot forks, because a cross-repo PR is
# exactly the case the operator cannot discover on their own.
#
# NOT a triage actor: it launches no session, writes nothing to any board, and
# takes no GitHub action. It reads PRs and sends Telegram. Keep it that way —
# the whole reason it can run unattended is that its blast radius is one chat.
#
# Deliberately NOT inferring readiness from approval counts: the panel size
# varies per repo, so counting fires at 2-of-3 while a verdict is still
# inbound, and a ping that cries "mergeable" before the round closes trains
# the operator to ignore it. The handoff label is the trigger and the only
# trigger. A missed handoff is a builder bug — fix it in the builder.
set -euo pipefail

export PATH="/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/home/claude"

DUTY_DIR="$HOME/duty"
STATE="$DUTY_DIR/.notify-state"          # repo \t pr \t head \t message_id \t status
REPOS="$DUTY_DIR/notify-repos.txt"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

[ -f "$STATE" ] || : > "$STATE"

if [ ! -r "$HOME/.tg_bot_token" ] || [ ! -r "$HOME/.tg_chat_id" ]; then
  log "tg: credentials missing — nothing to do"
  exit 0
fi
TOK=$(cat "$HOME/.tg_bot_token")
CHAT=$(cat "$HOME/.tg_chat_id")

# --- telegram -------------------------------------------------------------
# Both helpers are non-fatal by contract: a dead notification path must never
# take the loop down with it, or a Telegram outage becomes a silent blackout
# with no record of what was missed.

tg_send() {  # $1 text -> prints message_id, empty on failure
  local resp
  resp=$(curl -sS -m 15 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true" 2>/dev/null) || { log "tg: send failed"; return 0; }
  jq -r 'if .ok then (.result.message_id|tostring) else empty end' <<<"$resp" 2>/dev/null || true
}

tg_edit() {  # $1 message_id, $2 text -> 0 always
  local resp ok
  # No message to edit (legacy entry adopted from .notified, or a send that
  # failed): nothing to do, and NOT an error. Guarding here rather than at the
  # call sites keeps `[ ... ] && tg_edit` out of the script, which under
  # `set -e` exits the whole run whenever the test is false.
  if [ "$1" = "-" ] || [ -z "$1" ]; then return 0; fi
  resp=$(curl -sS -m 15 -X POST "https://api.telegram.org/bot${TOK}/editMessageText" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "message_id=$1" \
    --data-urlencode "text=$2" \
    --data-urlencode "disable_web_page_preview=true" 2>/dev/null) || { log "tg: edit failed (net)"; return 0; }
  ok=$(jq -r '.ok' <<<"$resp" 2>/dev/null || echo false)
  # "message is not modified" is a success for our purposes: the chat already
  # says what we wanted it to say.
  [ "$ok" = "true" ] || log "tg: edit rejected — $(jq -r '.description // "?"' <<<"$resp" 2>/dev/null)"
  return 0
}

# --- repo set -------------------------------------------------------------
# Read from notify-repos.txt, NOT discovered org-wide. See that file for why.
# Falls back to the triage repo list so a missing config still watches
# ceremony — notifying about one repo beats notifying about nothing.
if [ -r "$REPOS" ]; then
  repos=$(grep -vE '^\s*(#|$)' "$REPOS" | sort -u)
else
  log "notify-repos.txt missing — falling back to repos.txt"
  repos=$(cat "$DUTY_DIR/repos.txt" 2>/dev/null || true)
fi

state_put() {  # $1 repo $2 pr $3 head $4 msgid $5 status
  local tmp; tmp=$(mktemp)
  grep -vP "^\Q$1\E\t\Q$2\E\t" "$STATE" > "$tmp" 2>/dev/null || true
  # "-" not "": with IFS=$'\t' bash collapses runs of tabs, so an empty field
  # silently shifts every later field left and status reads as garbage.
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" "$5" >> "$tmp"
  mv "$tmp" "$STATE"
}

body_pending() {  # repo pr title head
  printf '🟣 NEEDS YOU — %s#%s\n%s\npanel approved %s · zero blockers\nhttps://github.com/%s/pull/%s' \
    "$1" "$2" "$3" "${4:0:7}" "$1" "$2"
}

# --- 1. sweep for new handoffs -------------------------------------------
found=0
FLAGGED=""   # every repo\tPR the label sweep saw, for the invariant check below
for R in $repos; do
  prs=$(gh pr list -R "$R" --state open --limit 100 \
        --json number,title,isDraft,headRefOid,labels --jq '
    [ .[]
      | select(.isDraft | not)
      | ([ .labels[].name ]) as $L
      | select($L | index("state:needs-human"))
      | select([ $L[] | startswith("blocker:") ] | any | not)
      | {number, title, head: .headRefOid} ]' 2>/dev/null) || continue
  [ -z "$prs" ] && continue

  while IFS=$'\t' read -r pr_num pr_head pr_title; do
    [ -z "$pr_num" ] && continue
    found=$((found+1))
    FLAGGED="${FLAGGED}${R}	${pr_num}
"
    line=$(grep -P "^\Q$R\E\t\Q$pr_num\E\t" "$STATE" 2>/dev/null || true)
    s_status=""; s_head=""; s_msg="-"
    [ -n "$line" ] && IFS=$'\t' read -r _ _ s_head s_msg s_status <<<"$line"
    # Only a `pending` row is a live message to update. merged/closed/cleared
    # are NOT terminal: a handoff withdrawn by a new push comes back every time
    # the builder re-earns approval, and a closed PR can reopen. Falling through
    # to the send below is what makes a relapse notify again — treating those as
    # final is how cast#143 sat flagged and silent for hours ("1 flagged, 0
    # pending" in the log, every tick).
    if [ "$s_status" = "pending" ]; then
      # Already tracked and still open. Re-arm only if the head moved AND we
      # have a message to edit — a new push means the approvals it was handed
      # off on are stale.
      if [ "$s_head" != "$pr_head" ] && [ "$s_msg" != "-" ]; then
        tg_edit "$s_msg" "$(body_pending "$R" "$pr_num" "$pr_title" "$pr_head")"
        state_put "$R" "$pr_num" "$pr_head" "$s_msg" pending
        log "$R#$pr_num: head moved -> ${pr_head:0:7}, message updated"
      elif [ "$s_msg" = "-" ]; then
        # Seeded from the old .notified file: notified once by duty.sh, never
        # tracked. Adopt it with a fresh message so it becomes editable.
        mid=$(tg_send "$(body_pending "$R" "$pr_num" "$pr_title" "$pr_head")")
        state_put "$R" "$pr_num" "$pr_head" "${mid:--}" pending
        log "$R#$pr_num: adopted legacy entry (msg ${mid:-none})"
      fi
      continue
    fi
    mid=$(tg_send "$(body_pending "$R" "$pr_num" "$pr_title" "$pr_head")")
    state_put "$R" "$pr_num" "$pr_head" "${mid:--}" pending
    log "$R#$pr_num: notified needs-human at ${pr_head:0:7} (msg ${mid:-none})"
  done < <(jq -r '.[] | [ (.number|tostring), .head, .title ] | @tsv' <<<"$prs")
done

# --- 2. resolve everything still pending ---------------------------------
# Runs over the state file, NOT over the label sweep above: the whole point is
# to catch PRs that have LEFT the needs-human set. A merged PR no longer
# carries the label, so a label-driven pass can never close its message.
while IFS=$'\t' read -r R pr_num s_head s_msg s_status; do
  [ "${s_status:-}" = "pending" ] || continue
  [ -z "${R:-}" ] && continue
  info=$(gh pr view "$pr_num" -R "$R" --json state,title,mergedAt,labels 2>/dev/null) || continue
  st=$(jq -r '.state' <<<"$info")
  title=$(jq -r '.title' <<<"$info")
  has_label=$(jq -r '[.labels[].name] | index("state:needs-human") != null' <<<"$info")
  url="https://github.com/$R/pull/$pr_num"

  case "$st" in
    MERGED)
      when=$(jq -r '.mergedAt // ""' <<<"$info")
      tg_edit "$s_msg" "$(printf '✅ MERGED — %s#%s\n%s\nmerged %s\n%s' \
        "$R" "$pr_num" "$title" "$when" "$url")"
      state_put "$R" "$pr_num" "$s_head" "$s_msg" merged
      log "$R#$pr_num: merged — message closed"
      ;;
    CLOSED)
      tg_edit "$s_msg" "$(printf '✖ CLOSED unmerged — %s#%s\n%s\n%s' \
        "$R" "$pr_num" "$title" "$url")"
      state_put "$R" "$pr_num" "$s_head" "$s_msg" closed
      log "$R#$pr_num: closed unmerged — message closed"
      ;;
    OPEN)
      if [ "$has_label" != "true" ]; then
        tg_edit "$s_msg" "$(printf '↩ WITHDRAWN — %s#%s\n%s\nhandoff label removed; back with the builder\n%s' \
          "$R" "$pr_num" "$title" "$url")"
        state_put "$R" "$pr_num" "$s_head" "$s_msg" cleared
        log "$R#$pr_num: label withdrawn — message closed"
      fi
      ;;
  esac
done < "$STATE"

pending=$(awk -F'\t' '$5=="pending"' "$STATE" 2>/dev/null | wc -l | tr -d ' ')
log "sweep done — $(printf '%s\n' "$repos" | grep -c . ) repos, $found flagged, $pending pending"

# --- 3. invariant: everything flagged must be tracked --------------------
# flagged > pending means the sweep SAW a PR and did not track it — the PR is
# labelled for the operator and the operator will never hear about it. That is
# the worst failure this script has, because it is silent: the log looks calm
# and the chat stays empty. cast#143 and ceremony#78 sat in exactly this state
# for over an hour on 2026-07-23, and the only trace was two counters in the
# line above disagreeing. Counters a human has to compare are not a signal, so
# this says it out loud and pings once per PR.
DESYNC="$DUTY_DIR/.notify-desync"
[ -f "$DESYNC" ] || : > "$DESYNC"
untracked=""
while IFS=$'\t' read -r R pr_num; do
  [ -z "${pr_num:-}" ] && continue
  if ! grep -qP "^\Q$R\E\t\Q$pr_num\E\t[^\t]*\t[^\t]*\tpending$" "$STATE" 2>/dev/null; then
    untracked="${untracked}${R}#${pr_num} "
    if ! grep -qxF "${R}#${pr_num}" "$DESYNC"; then
      tg_send "⚠️ notifier desync — ${R}#${pr_num}
carries state:needs-human but is not being tracked, so it would never be announced.
This message is the bug report, not the handoff.
https://github.com/${R}/pull/${pr_num}" >/dev/null
      printf '%s\n' "${R}#${pr_num}" >> "$DESYNC"
    fi
  fi
done < <(printf '%b' "$FLAGGED")

if [ -n "$untracked" ]; then
  log "INVARIANT VIOLATED — flagged but untracked: ${untracked}(operator NOT notified of these by the normal path)"
else
  # Resolved: forget the warnings so a future recurrence pings again.
  : > "$DESYNC"
fi
