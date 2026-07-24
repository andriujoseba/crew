# duty-triage.sh — the triage wake signals, per repo in repos.txt:
#   (a) needs-triage issues        (b) queue-unlabeled strays
#   (c) discussions without my voice  (d) unread mentions (own session)
#   (e) blocked issues whose named blockers all landed (a LEAD, not a verdict)
#
# Architectural spine (dan-claude-bot): this module only ever WAKES a
# session — it never edits a label itself. A parser bug becomes a false lead
# the session rejects, not a wrong board write. Every signal is fail-safe:
# (e)'s unknown blocker counts as still-open, and the hourly hygiene sweep
# is the unconditional backstop for anything detection misses.
#
# Every gh read is isolated per signal per repo: one transient API failure
# degrades to a logged skip, never an aborted tick (the old duty.sh died
# mid-queue on the first failure, silently skipping every later repo).
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

duty_triage() {
  local R
  while IFS= read -r R; do
    [ -z "$R" ] && continue
    _triage_repo "$R"
  done < <(read_repo_list "$REPOS_FILE")
}

_triage_repo() {
  local R="$1"
  local owner="${R%%/*}" name="${R##*/}"
  local signals="" nt stray undisc unblockable="" dir prompt

  # (a) needs-triage
  nt="$(gh issue list -R "$R" --state open --label "$LABEL_NEEDS_TRIAGE" \
    --json number --jq 'length' 2>/dev/null || echo err)"
  case "$nt" in
    err) warn "$R: needs-triage probe failed" ;;
    0) : ;;
    *) signals="$signals ${nt}x needs-triage;" ;;
  esac

  # (b) queue-unlabeled strays: the board invariant says every open issue
  # carries needs-triage, epic, or exactly one of ready/claimed/blocked.
  stray="$(gh issue list -R "$R" --state open --limit 200 --json number,labels \
    | jq --arg r "$LABEL_READY" --arg c "$LABEL_CLAIMED" --arg b "$LABEL_BLOCKED" \
         --arg e "$LABEL_EPIC" --arg n "$LABEL_NEEDS_TRIAGE" \
      '[ .[] | select( ([.labels[].name]
          | map(. == $r or . == $c or . == $b or . == $e or . == $n) | any) | not ) ]
        | length' 2>/dev/null || echo err)"
  case "$stray" in
    err) warn "$R: stray probe failed" ;;
    0) : ;;
    *) signals="$signals ${stray}x queue-unlabeled;" ;;
  esac

  # (c) open discussions with no comment or reply by me. Limits (50/50/20)
  # silently truncate very busy threads — the safe direction (re-wake), and
  # hygiene is the backstop.
  undisc="$(TR_ME="$ME" gh api graphql -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        discussions(first:50,states:OPEN){
          nodes{ number
            comments(first:50){ nodes{ author{ login }
              replies(first:20){ nodes{ author{ login } } } } } }
        }
      }
    }' --jq '[.data.repository.discussions.nodes[]
              | select( [ .comments.nodes[] | .author.login,
                          .replies.nodes[].author.login ]
                        | index(env.TR_ME) | not ) ] | length' 2>/dev/null || echo err)"
  case "$undisc" in
    err) warn "$R: discussion probe failed (discussions disabled?)" ;;
    0) : ;;
    *) signals="$signals ${undisc}x uncommented discussions;" ;;
  esac

  # (e) blocked issues whose named blockers all landed. The parser is
  # deliberately narrow (see lib/jq/blockers.jq — corpus-tested); issue and
  # PR numbering is shared, so the state map needs both lists. Fail-safe by
  # construction: an unknown number counts as still-open.
  local blocked_json numstates
  blocked_json="$(gh issue list -R "$R" --state open --label "$LABEL_BLOCKED" \
    --limit 200 --json number,body 2>/dev/null || echo '[]')"
  if [ "$(jq 'length' <<<"$blocked_json" 2>/dev/null || echo 0)" -gt 0 ]; then
    numstates="$( { gh issue list -R "$R" --state all --limit 500 --json number,state
                    gh pr    list -R "$R" --state all --limit 500 --json number,state; } 2>/dev/null \
      | jq -s 'add | map({key:(.number|tostring), value:.state}) | from_entries' || echo '{}')"
    unblockable="$(jq -r --argjson S "$numstates" -f "$DUTY_DIR/lib/jq/blockers.jq" \
      <<<"$blocked_json" 2>/dev/null || echo "")"
  fi
  [ -n "$unblockable" ] && signals="$signals unblockable:${unblockable};"

  # (d) unread mentions — a separate wake with its own session, so a builder
  # blocked on a question is answered even when the board is clean. Only the
  # thread ids and API subject URLs travel in the prompt (never titles —
  # anyone on GitHub writes those, and this is a permissionless session).
  # Idempotency is mark-read-AFTER-handling: anything unhandled is retried.
  local mentions mcount
  mentions="$(gh api notifications --paginate 2>/dev/null | jq -c -s --arg repo "$R" 'add
    | [ .[] | select(.repository.full_name == $repo
                and (.reason == "mention" or .reason == "team_mention"))
      | {thread: .id, subject: .subject.url} ]' 2>/dev/null || echo '[]')"
  mcount="$(jq 'length' <<<"$mentions" 2>/dev/null || echo 0)"
  if [ "$mcount" -gt 0 ]; then
    log "$R: ${mcount} unread mention(s) — launching mention session"
    dir="$WORK_DIR/${R//\//__}"
    if ensure_checkout "$R" "$dir"; then
      run_session mention "$R" "$dir" "$TIMEOUT_MENTION" \
        "$(render_prompt mention.txt ME="$ME" REPO="$R" MENTIONS="$mentions")"
    fi
  fi

  if [ -z "$signals" ]; then
    if [ "$mcount" -eq 0 ]; then
      log "$R: quiet — no mentions, no triage signals, no session launched"
    else
      log "$R: no triage signals — mention session was the only wake"
    fi
    return 0
  fi

  log "$R: signals:$signals launching triage session"
  dir="$WORK_DIR/${R//\//__}"
  ensure_checkout "$R" "$dir" || return 0
  local unblock_note=""
  if [ -n "$unblockable" ]; then
    unblock_note="$(render_prompt fragment-unblockable.txt NUMS="$unblockable")"
  fi
  prompt="$(render_prompt triage.txt ME="$ME" REPO="$R" UNBLOCKABLE_NOTE="$unblock_note")"
  run_session triage "$R" "$dir" "$TIMEOUT_TRIAGE" "$prompt"
}
