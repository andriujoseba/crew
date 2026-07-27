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

  # (a) and (b) are BOARD-STATE signals, and both are enumerated rather than
  # counted so they can be compared against what a previous session already
  # looked at. A count cannot be: it says how many, never which, so an issue a
  # session correctly DECLINED to label re-fired a full model session every
  # tick, forever (#59 — observed as 11 triage sessions in 50 minutes on an
  # unchanged board). That is the same defect (c) and (d) were fixed for on
  # 2026-07-25, and (a)/(b) were left with the assumption that they clear
  # themselves. They only clear if the session labels EVERY issue it sees.
  #
  # One ledger for both: they are open issues in a single numbering space, and
  # the sets are disjoint by construction — a stray carries none of the five
  # labels, so it can never also be needs-triage. Keys are REPO-qualified for
  # the reason (c) records: one ledger spans every repo in repos.txt, and a
  # bare number let rig#1 shadow ceremony#1.
  #
  # Fetch and parse are SEPARATE steps, matching the builder's shape below
  # (kimi-bot, #60 review). Piped together, a jq that fails after gh succeeded
  # appends `err` to whatever it had already emitted, so the `= err` test misses
  # and a PARTIAL list is processed as a complete one — with the probe-failed
  # warn swallowed. The list being short is harmless (absent items re-appear
  # next tick, the safe direction); losing the warn is not, because a probe that
  # cannot tell must say so. That is this whole issue's argument.
  local nt_items="" stray_items="" nt_json stray_json
  nt_json="$(gh issue list -R "$R" --state open --label "$LABEL_NEEDS_TRIAGE" \
    --json number,updatedAt 2>/dev/null || echo err)"
  if [ "$nt_json" = err ]; then
    warn "$R: needs-triage probe failed"
  elif ! nt_items="$(printf '%s' "$nt_json" \
      | jq -r --arg r "$R" '.[] | "\($r)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
    warn "$R: needs-triage parse failed"
    nt_items=""
  else
    nt="$(printf '%s\n' "$nt_items" \
      | ledger_filter "$DUTY_DIR/.seen-triage-board" | awk 'NF{c++} END{print c+0}')"
    [ "$nt" -gt 0 ] && signals="$signals ${nt}x needs-triage;"
  fi

  # (b) queue-unlabeled strays: the board invariant says every open issue
  # carries needs-triage, epic, or exactly one of ready/claimed/blocked.
  stray_json="$(gh issue list -R "$R" --state open --limit 200 \
    --json number,labels,updatedAt 2>/dev/null || echo err)"
  if [ "$stray_json" = err ]; then
    warn "$R: stray probe failed"
  elif ! stray_items="$(printf '%s' "$stray_json" \
      | jq -r --arg repo "$R" --arg r "$LABEL_READY" --arg c "$LABEL_CLAIMED" --arg b "$LABEL_BLOCKED" \
           --arg e "$LABEL_EPIC" --arg n "$LABEL_NEEDS_TRIAGE" \
        '.[] | select( ([.labels[].name]
            | map(. == $r or . == $c or . == $b or . == $e or . == $n) | any) | not )
          | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
    warn "$R: stray parse failed"
    stray_items=""
  else
    stray="$(printf '%s\n' "$stray_items" \
      | ledger_filter "$DUTY_DIR/.seen-triage-board" | awk 'NF{c++} END{print c+0}')"
    [ "$stray" -gt 0 ] && signals="$signals ${stray}x queue-unlabeled;"
  fi

  # Everything the ledger just hid is still a live board-invariant violation.
  # Stop paying for it; do NOT stop saying it.
  # State file PER REPO. _triage_repo runs once per repos.txt entry, so a single
  # shared file has repo B overwrite repo A's saved set — and a repo with
  # nothing suppressed rm -f's it outright. Next tick A's unchanged set looks
  # new and warns again, which is precisely the every-tick spam the change
  # detection exists to prevent, on precisely the multi-repo box #59 is about
  # (codex-bot and grok-bot both caught this; grok-bot reproduced the flip-flop).
  printf '%s\n%s\n' "$nt_items" "$stray_items" \
    | ledger_suppressed "$DUTY_DIR/.seen-triage-board" \
    | report_suppressed "$DUTY_DIR/.suppressed-triage-board.${R//\//_}" "$R: board"

  # (c) open discussions with no comment or reply by me — but wake only for
  # ones whose activity ADVANCED since I last handled this repo. A discussion
  # held for a human ruling (needs-ruling) carries no comment of mine by
  # design; keying on that alone re-fired a full triage session every tick
  # forever (the overnight burn). updatedAt now travels too; `uncommented_disc`
  # holds every currently-uncommented one as "REPO#number updatedAt" lines and
  # is committed after the triage session, so a held one is marked seen at its
  # current state. The key is REPO-qualified: discussion numbers are
  # per-repository but this ledger is one file across every repo in repos.txt,
  # so a bare number let rig#1 shadow ceremony#1 (codex, #16 review). Limits
  # (50/50/20) truncate very busy threads — safe direction (re-wake), hygiene
  # is the backstop.
  local uncommented_disc
  uncommented_disc="$(TR_ME="$ME" TR_R="$R" gh api graphql -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        discussions(first:50,states:OPEN){
          nodes{ number updatedAt
            comments(first:50){ nodes{ author{ login }
              replies(first:20){ nodes{ author{ login } } } } } }
        }
      }
    }' --jq '[.data.repository.discussions.nodes[]
              | select( [ .comments.nodes[] | .author.login,
                          .replies.nodes[].author.login ]
                        | index(env.TR_ME) | not )
              | "\(env.TR_R)#\(.number) \(.updatedAt)"] | .[]' 2>/dev/null || echo err)"
  if [ "$uncommented_disc" = err ]; then
    warn "$R: discussion probe failed (discussions disabled?)"
    uncommented_disc=""
  else
    undisc="$(printf '%s\n' "$uncommented_disc" \
      | ledger_filter "$DUTY_DIR/.seen-discussions" | awk 'NF{c++} END{print c+0}')"
    [ "$undisc" -gt 0 ] && signals="$signals ${undisc}x uncommented discussions;"
  fi

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
  # Idempotency is the seen-ledger, NOT mark-read alone: a mention the session
  # reads but correctly does not act on (an FYI, an already-answered thread, a
  # PR I don't own) used to stay unread and re-fire a full session every tick.
  # A thread now re-wakes only when its notification updated_at advances.
  local all_mentions keep_threads keep_json mentions mcount
  all_mentions="$(gh api notifications --paginate 2>/dev/null | jq -c -s --arg repo "$R" 'add
    | [ .[] | select(.repository.full_name == $repo
                and (.reason == "mention" or .reason == "team_mention"))
      | {thread: .id, subject: .subject.url, updated: .updated_at} ]' 2>/dev/null || echo '[]')"
  keep_threads="$(printf '%s\n' "$all_mentions" \
    | jq -r '.[] | "\(.thread) \(.updated)"' 2>/dev/null \
    | ledger_filter "$DUTY_DIR/.seen-mentions" | awk '{print $1}')"
  if [ -n "$keep_threads" ]; then
    keep_json="$(printf '%s\n' "$keep_threads" | jq -R . | jq -cs .)"
    mentions="$(jq -c --argjson keep "$keep_json" \
      '[ .[] | select(.thread as $t | $keep | index($t)) ]' <<<"$all_mentions")"
  else
    mentions='[]'
  fi
  mcount="$(jq 'length' <<<"$mentions" 2>/dev/null || echo 0)"
  if [ "$mcount" -gt 0 ]; then
    log "$R: ${mcount} unread mention(s) — launching mention session"
    dir="$WORK_DIR/${R//\//__}"
    if ensure_checkout "$R" "$dir"; then
      RUN_SESSION_RC=1
      run_session mention "$R" "$dir" "$TIMEOUT_MENTION" \
        "$(render_prompt mention.txt ME="$ME" REPO="$R" MENTIONS="$mentions")"
      # Commit only on success: a crashed/timed-out session leaves these
      # uncommitted and retries next tick (crash-only), as before.
      if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
        printf '%s\n' "$all_mentions" | jq -r '.[] | "\(.thread) \(.updated)"' \
          | ledger_commit "$DUTY_DIR/.seen-mentions"
      fi
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
  RUN_SESSION_RC=1
  run_session triage "$R" "$dir" "$TIMEOUT_TRIAGE" "$prompt"
  # Mark every currently-uncommented discussion seen at its present state, so a
  # held/needs-ruling one does not re-wake until it actually changes. Same for
  # the board signals: an issue this session saw and left alone is recorded at
  # the state it was seen in, and re-wakes only when it actually changes.
  #
  # Committed ONLY on rc 0, exactly as (c) is: a crashed or timed-out session
  # must leave its ids uncommitted so the next tick retries. That distinction —
  # declined vs never got there — is the whole reason this is safe.
  if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
    printf '%s\n' "$uncommented_disc" | ledger_commit "$DUTY_DIR/.seen-discussions"
    printf '%s\n%s\n' "$nt_items" "$stray_items" | ledger_commit "$DUTY_DIR/.seen-triage-board"
  fi
}
