#!/usr/bin/env bash
# duty.sh — the fast, conditional poll (every 5m via cron).
# For each repo in repos.txt, detect triage signals and launch a one-shot
# triage session only when at least one exists:
#   (a) open issues labeled needs-triage
#   (b) open issues carrying NONE of ready/claimed/blocked/epic/needs-triage
#       (queue-unlabeled = stray by definition, per LABELS.md invariant)
#   (c) open discussions with no comment from dan-claude-bot yet — but only
#       ones whose activity ADVANCED since I last looked (a seen-ledger; a
#       held needs-ruling discussion no longer re-wakes a session every tick)
#   (d) unread mentions of me (gh api notifications) — a dedicated session
#       answers each thread, marks it read, AND records its updated_at in a
#       seen-ledger; a mention the session correctly declines to act on no
#       longer re-fires a full session every tick (the overnight quota burn,
#       2026-07-25)
#   (e) blocked issues whose named blockers have all landed. hygiene.sh already
#       flips blocked->ready, but it runs hourly, so an unblock could sit up to
#       58 minutes behind the merge that earned it. This is the fast path: the
#       merge that unblocks the dogfood release is the highest-value event on
#       the board and was the one thing the 5-minute poll could not see.
# Telegram notification used to live here as side-effect (f). It moved to
# notify.sh on 2026-07-23 (own */5 cron, own lock, own state) because tracking
# a PR to merge and editing its message in place needs state, and because its
# repo scope has to be the whole org while this loop's is deliberately
# ceremony. This loop no longer notifies anyone.
set -euo pipefail

# cron ships PATH=/usr/bin:/bin — claude lives in ~/.local/bin (the classic
# cron failure; verified by hand-running under env -i).
export PATH="/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/home/claude"

# Once-per-boot sanity gate. This box is the fleet's single point of failure:
# dead credentials here mean no issues get minted and every other box starves
# silently. The marker is written ONLY when both gh and claude auth work — if
# either credential is dead, the checks re-run (and re-log) every tick instead
# of silently skipping duty.
boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [ "$(cat "$HOME/duty/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
  { echo "== boot check $(date -Is) =="
    gh auth status || true
    df -h / | tail -1
    claude auth status || true
  } >> "$HOME/duty/boot-check.log" 2>&1
  if gh auth status >/dev/null 2>&1 \
    && claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
    echo "$boot_id" > "$HOME/duty/.boot-id"
  fi
fi

ME="dan-claude-bot"
DUTY_DIR="$HOME/duty"
REPOS_FILE="$DUTY_DIR/repos.txt"
WORK_DIR="$DUTY_DIR/work"
NOTIFIED_FILE="$DUTY_DIR/.notified"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# --- Seen-ledgers: turn "signal is present" into "signal CHANGED since I last
# looked". A wake whose only clearing action is one the session may correctly
# DECLINE (mark a mention read, comment on a held discussion) re-fired every
# tick forever, spawning a full model session each time — the fleet's overnight
# Fable burn (2026-07-25: 147 mention + 61 triage sessions in 3 days, board
# unchanged). Each ledger records, per thread/discussion id, the activity
# timestamp last handled; a session is launched only for entries that are new
# or whose timestamp advanced, and the ledger is committed ONLY after a session
# completes rc 0 — a crashed session leaves its ids uncommitted, preserving the
# crash-only retry the old design relied on. Timestamps are ISO 8601, so a
# lexical compare is a chronological one. ---
ledger_filter() { # $1=ledger; stdin "id ts" lines; stdout new-or-advanced ones
  local ledger="$1"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (!($1 in seen) || seen[$1] < $2) print }
  '
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
SEEN_MENTIONS="$DUTY_DIR/.seen-mentions"
SEEN_DISCUSSIONS="$DUTY_DIR/.seen-discussions"

# Telegram. Unused since the notifier moved to notify.sh — kept because the
# boot gate and future triage-side alerts are the obvious next callers, and a
# correct non-fatal sender is worth more than the six lines it costs.
# Never fatal: a dead notification path must not stop triage from running.
tg_send() {
  local text="$1" tok chat
  if [ ! -r "$HOME/.tg_bot_token" ] || [ ! -r "$HOME/.tg_chat_id" ]; then
    log "tg: credentials missing — notification skipped"
    return 0
  fi
  tok=$(cat "$HOME/.tg_bot_token")
  chat=$(cat "$HOME/.tg_chat_id")
  if curl -sS -m 15 -o /dev/null \
      -X POST "https://api.telegram.org/bot${tok}/sendMessage" \
      --data-urlencode "chat_id=${chat}" \
      --data-urlencode "text=${text}" \
      --data-urlencode "disable_web_page_preview=true"; then
    return 0
  fi
  log "tg: send failed (non-fatal)"
  return 0
}

# Fresh local checkout so the session's "read AGENTS.md at the repo root"
# is literally true from its cwd.
checkout() {
  local repo="$1" dir="$WORK_DIR/${1//\//__}"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --quiet >/dev/null 2>&1 || true
  else
    git clone --quiet "https://github.com/$repo" "$dir"
  fi
  printf '%s\n' "$dir"
}

touch "$NOTIFIED_FILE"

# --- ATTENTION duty (role-independent, once per tick, ahead of the per-repo
# triage sweep): an open issue assigned to me carrying the `attention` label
# is a demand parked for me — the operator or a sibling agent decided a thread
# needs my hands and set it. It is cross-repo (assigned to me anywhere), so it
# runs once here, not inside the repos.txt loop below. Exactly one wake per
# demand; the pickup session acks by REMOVING the label (that re-arms the
# wake), then does the demanded work per TRIAGE.md. A session that dies before
# acking is relaunched next tick — idempotent, the flag is still up.
# (ceremony#83; the wake is spec'd in FLEET.md.) This is the assignee demand —
# distinct from an @-mention (d), which stays an FYI, and from needs-ruling,
# which is a human's decision, not mine.
attn_rows=$(gh api "/issues?filter=assigned&state=open&labels=attention&per_page=100" \
  --jq '.[] | "\(.repository.full_name) \(.number)"' 2>/dev/null) \
  || { attn_rows=""; log "WARN: attention fetch failed this tick"; }
if [ -z "$attn_rows" ]; then
  log "attention: none"
else
  while read -r a_repo a_num; do
    [ -z "${a_num:-}" ] && continue
    log "attention: $a_repo#$a_num — launching pickup session"
    a_dir=$(checkout "$a_repo")
    aprompt="You are the triage agent dan-claude-bot. Issue $a_repo#$a_num is assigned to you and carries the attention label: a demand was parked there for you. FIRST, the ack — post one short comment (📌 picked up) unless an unanswered 📌 of yours already sits at the bottom of the thread, then REMOVE the label: gh api -X DELETE repos/$a_repo/issues/$a_num/labels/attention — the removal re-arms the wake for the next demand. THEN read the full thread plus whatever it links, work out what is being demanded of you, and do it whole. Read AGENTS.md at the repo root and act per TRIAGE.md. Touch the label only to remove it as your ack; set nothing, and never spawn work off a bare @-mention."
    if (cd "$a_dir" && timeout 1500 claude -p --dangerously-skip-permissions "$aprompt"); then
      log "attention: $a_repo#$a_num pickup completed"
    else
      log "attention: $a_repo#$a_num pickup FAILED or timed out (exit $?)"
    fi
  done <<< "$attn_rows"
fi

while IFS= read -r R; do
  [ -z "$R" ] && continue
  case "$R" in \#*) continue ;; esac

  signals=""

  # (a) needs-triage
  nt=$(gh issue list -R "$R" --state open --label needs-triage \
        --json number --jq 'length')
  [ "$nt" -gt 0 ] && signals="$signals ${nt}x needs-triage;"

  # (b) queue-unlabeled strays
  stray=$(gh issue list -R "$R" --state open --limit 200 --json number,labels \
    --jq '[ .[] | select( ([.labels[].name]
            | map(. == "ready" or . == "claimed" or . == "blocked"
                  or . == "epic" or . == "needs-triage") | any) | not ) ]
          | length')
  [ "$stray" -gt 0 ] && signals="$signals ${stray}x queue-unlabeled;"

  # (c) open discussions without my comment (top-level or reply) — but wake
  # only for ones whose activity ADVANCED since I last handled this repo. A
  # discussion I am deliberately holding (needs-ruling is a human's call, not
  # mine) carries no comment of mine by design; without the ledger it re-fired
  # a full triage session every 5 minutes forever. GraphQL also returns
  # updatedAt now; `uncommented_disc` holds every currently-uncommented one as
  # "number updatedAt" lines and is committed after the triage session, so a
  # held discussion is marked seen at its current state.
  owner="${R%%/*}" name="${R##*/}"
  uncommented_disc=$(gh api graphql -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        discussions(first:50,states:OPEN){
          nodes{ number updatedAt
            comments(first:50){ nodes{ author{ login }
              replies(first:20){ nodes{ author{ login } } } } } }
        }
      }
    }' --jq "[.data.repository.discussions.nodes[]
              | select( [ .comments.nodes[] | .author.login,
                          .replies.nodes[].author.login ]
                        | index(\"$ME\") | not )
              | \"\(.number) \(.updatedAt)\"] | .[]" 2>/dev/null || echo "")
  undisc=$(printf '%s\n' "$uncommented_disc" \
    | ledger_filter "$SEEN_DISCUSSIONS" | awk 'NF{c++} END{print c+0}')
  [ "$undisc" -gt 0 ] && signals="$signals ${undisc}x uncommented discussions;"

  # (e) blocked issues whose named blockers have all landed.
  #
  # Parsing is deliberately narrow. Issue bodies open with a line like
  #   "Part of #1. Blocked by #5, #6, #7, #9 (and #10 for the label bootstrap).
  #    Blocks #13 (the pilot needs a tag to pin)."
  # so three things must hold: read only the "Blocked by" clause (never
  # "Blocks", the inverse relation, which lives in the same line); stop at that
  # clause's first sentence end; and pick up #N inside its parentheses, which
  # are real blockers. Hence match up to the first "." and scan that span only.
  #
  # Fail-safe by construction: an unknown number counts as still-open, so a
  # parse miss leaves the issue blocked and hygiene.sh catches it on the hour.
  # And this only ever *wakes a session* — the script never edits a label
  # itself. Detection here, judgment there, exactly as (a)-(d) already work.
  #
  # Issue and PR numbering is shared, so a blocker may be either; the state map
  # needs both lists or a PR blocker looks like a missing number forever.
  unblockable=""
  blocked_json=$(gh issue list -R "$R" --state open --label blocked --limit 200 \
                   --json number,body)
  if [ "$(jq 'length' <<<"$blocked_json")" -gt 0 ]; then
    numstates=$( { gh issue list -R "$R" --state all --limit 500 --json number,state
                   gh pr    list -R "$R" --state all --limit 500 --json number,state; } \
                 | jq -s 'add | map({key:(.number|tostring), value:.state}) | from_entries')
    unblockable=$(jq -r --argjson S "$numstates" '
      def blockers:
        [ match("[Bb]locked by([^.]*)"; "g").captures[0].string ] | join(" ")
        | [ scan("#([0-9]+)") | .[0] ];
      [ .[]
        | . as $i
        | (($i.body // "") | blockers) as $b
        | select(($b | length) > 0)
        | select(all($b[]; ($S[.] // "OPEN") | . == "CLOSED" or . == "MERGED"))
        | $i.number ]
      | join(",")' <<<"$blocked_json")
  fi
  [ -n "$unblockable" ] && signals="$signals unblockable:${unblockable};"

  # (f) Telegram — MOVED OUT on 2026-07-23 to notify.sh, its own */5 cron.
  # It fired and forgot, deduped on repo#PR@head, and swept repos.txt — which
  # is ceremony alone, so rig#112 sat state:needs-human for nine hours without
  # ever reaching the operator. The replacement tracks each PR to merge and
  # edits its message in place, which needs state this loop has no business
  # carrying. Do not re-add a send here: two notifiers means two pings.

  # (d) unread mentions — a separate wake with its own session, so a builder
  # blocked on a question is answered even when the board itself is clean.
  # --paginate emits one JSON array per page; jq -s + add flattens them
  # (gh 2.46 here predates --slurp, which landed in 2.47).
  # Idempotency is now the seen-ledger, not mark-read alone: a mention the
  # session reads but correctly does NOT act on (an FYI, an already-answered
  # thread, a PR I don't own) used to stay unread and re-fire a full session
  # every tick. Now a thread only re-wakes when its notification updated_at
  # advances. mark-read still runs in-session, for inbox hygiene.
  all_mentions=$(gh api notifications --paginate | jq -c -s --arg repo "$R" 'add
    | [ .[] | select(.repository.full_name == $repo
                and (.reason == "mention" or .reason == "team_mention"))
      | {thread: .id, title: .subject.title, subject: .subject.url, updated: .updated_at} ]')
  keep_threads=$(printf '%s\n' "$all_mentions" \
    | jq -r '.[] | "\(.thread) \(.updated)"' \
    | ledger_filter "$SEEN_MENTIONS" | awk '{print $1}')
  if [ -n "$keep_threads" ]; then
    keep_json=$(printf '%s\n' $keep_threads | jq -R . | jq -cs .)
    mentions=$(jq -c --argjson keep "$keep_json" \
      '[ .[] | select(.thread as $t | $keep | index($t)) ]' <<<"$all_mentions")
  else
    mentions='[]'
  fi
  mcount=$(jq 'length' <<<"$mentions")
  if [ "$mcount" -gt 0 ]; then
    log "$R: ${mcount} unread mention(s) — launching mention session"
    dir=$(checkout "$R")
    mprompt="You are the triage agent dan-claude-bot in $R. You've been mentioned — read each thread, answer per TRIAGE.md (a builder question is a spec gap: answer it on the issue and amend the issue if the contract was incomplete), then mark the notifications read.

Unread mention threads (JSON): $mentions

Mark a thread read with: gh api --method PATCH /notifications/threads/<thread>. Marking read keeps your inbox clean; the poll no longer relies on it for idempotency, so if a thread genuinely needs no action from you, just leave it — it will not re-wake unless it gets new activity."
    if (cd "$dir" && timeout 1500 claude -p --dangerously-skip-permissions "$mprompt"); then
      log "$R: mention session completed"
      # Commit only after success: a crashed session leaves these uncommitted
      # and retries next tick (crash-only), exactly as before.
      printf '%s\n' "$all_mentions" | jq -r '.[] | "\(.thread) \(.updated)"' \
        | ledger_commit "$SEEN_MENTIONS"
    else
      log "$R: mention session FAILED or timed out (exit $?)"
    fi
  fi

  if [ -z "$signals" ]; then
    if [ "$mcount" -eq 0 ]; then
      log "$R: quiet — no mentions, no triage signals, no session launched"
    else
      log "$R: no triage signals — mention session was the only wake"
    fi
    continue
  fi

  log "$R: signals:$signals launching triage session"
  dir=$(checkout "$R")
  prompt="You are the triage agent dan-claude-bot in $R. Read AGENTS.md at the repo root, then act per TRIAGE.md. For stray issues — anything not minted by you — either normalize them to the issue contract or close them politely, pointing the filer at Discussions: their idea is welcome, the door is over there. For discussions, converge each unresolved one to exactly one outcome — answer, ask, escalate, decline, or accept — and every issue you mint meets the contract."
  if [ -n "$unblockable" ]; then
    prompt="$prompt

The poll also flagged these blocked issues as possibly unblockable — every issue or PR named in their \"Blocked by\" clause now reads CLOSED or MERGED: ${unblockable}. Treat that as a lead, not a verdict: re-read each body yourself, confirm the blockers really are the ones named and really did land, then flip to ready per TRIAGE.md. If the flag is wrong, leave the label alone and say why in your summary — a false lead here is a parser bug worth knowing about."
  fi
  if (cd "$dir" && timeout 1500 claude -p --dangerously-skip-permissions "$prompt"); then
    log "$R: triage session completed"
    # Mark every currently-uncommented discussion seen at its present state, so
    # a held/needs-ruling one does not re-wake until it actually changes.
    printf '%s\n' "$uncommented_disc" | ledger_commit "$SEEN_DISCUSSIONS"
  else
    log "$R: triage session FAILED or timed out (exit $?)"
  fi
done < "$REPOS_FILE"
