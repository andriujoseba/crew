# duty-triage.sh — the triage wake signals, per repo in repos.txt, in the
# order they run:
#   (d) unread mentions (one tick-wide session, and it goes FIRST)
#   (a) needs-triage issues        (b) queue-unlabeled strays
#   (c) discussions without my voice
#   (e) blocked issues whose named blockers all landed (a LEAD, not a verdict)
#
# The board poll follows the mention session because that session can run for
# TIMEOUT_MENTION (25 minutes) and can itself change the board: polled first,
# the launch decision is made on a snapshot up to 25 minutes stale, which
# spends a triage session on leads that died mid-session and defers a signal
# born during it by a full tick (#253).
#
# Architectural spine (dan-claude-bot): this module only ever WAKES a
# session — it never edits a label itself. A parser bug becomes a false lead
# the session rejects, not a wrong board write. Every signal is fail-safe:
# (e)'s unknown blocker counts as still-open, and the hourly hygiene sweep
# is the unconditional backstop for anything detection misses.
#
# Every board read is isolated per signal per repo: one transient API failure
# degrades to a logged skip, never an aborted tick (the old duty.sh died
# mid-queue on the first failure, silently skipping every later repo). The
# notifications read is deliberately tick-wide: one snapshot feeds every repo.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

_triage_discussion_items() {  # _triage_discussion_items REPO OWNER NAME
  local repo="$1" owner="$2" name="$3"
  TR_ME="$ME" TR_R="$repo" gh api graphql -f owner="$owner" -f name="$name" -f query='
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
              | "\(env.TR_R)#\(.number) \(.updatedAt)"] | .[]'
}

_triage_unblockable_items() {  # _triage_unblockable_items REPO BLOCKED_JSON NUMSTATES
  local repo="$1" blocked_json="$2" numstates="$3" numbers
  numbers="$(jq -r --argjson S "$numstates" -f "$DUTY_DIR/lib/jq/blockers.jq" \
    <<<"$blocked_json" 2>/dev/null)" || return 1
  jq -r --arg repo "$repo" --arg numbers "$numbers" '
    ($numbers | split(",")) as $due
    | .[]
    | select((.number | tostring) as $number | $due | index($number))
    | "\($repo)#\(.number) \(.updatedAt)"
  ' <<<"$blocked_json" 2>/dev/null
}

_triage_signal_numbers() {  # stdin: REPO#NUMBER UPDATED_AT
  awk 'NF {
    number=$1; sub(/^.*#/, "#", number)
    numbers = numbers separator number; separator=", "
  } END { print numbers }'
}

duty_triage() {
  local R notification_pages all_mentions repo_json fresh_threads fresh_json fresh_mentions
  local keep_threads keep_json mentions mcount mention_rc
  local -a repos=()
  mapfile -t repos < <(read_repo_list "$REPOS_FILE")

  # (d) unread mentions — one notifications snapshot and one session for the
  # whole tick. The session remains first, so every per-repo board poll below
  # observes changes made while answering a mention (#253).
  all_mentions='[]'
  repo_json="$(printf '%s\n' "${repos[@]}" | awk 'NF' | jq -R . | jq -cs .)"
  if [ "${#repos[@]}" -eq 0 ]; then
    :
  elif notification_pages="$(gh api notifications --paginate 2>/dev/null)" &&
     all_mentions="$(printf '%s\n' "$notification_pages" | jq -c -s --argjson repos "$repo_json" '
       (add // [])
       | [ .[]
           | select((.reason == "mention" or .reason == "team_mention")
                    and (.repository.full_name as $repo | $repos | index($repo)))
           | {repo: .repository.full_name, thread: .id,
              subject: .subject.url, updated: .updated_at} ]
     ' 2>/dev/null)"; then
    :
  else
    warn "notifications probe failed; mention wake skipped this tick"
    all_mentions='[]'
  fi
  fresh_threads="$(printf '%s\n' "$all_mentions" \
    | jq -r '.[] | "\(.thread) \(.updated)"' 2>/dev/null \
    | ledger_filter "$DUTY_DIR/.seen-mentions")"
  if [ -n "$fresh_threads" ]; then
    fresh_json="$(printf '%s\n' "$fresh_threads" | awk 'NF { print $1 }' | jq -R . | jq -cs .)"
    fresh_mentions="$(jq -c --argjson fresh "$fresh_json" \
      '[ .[] | select(.thread as $thread | $fresh | index($thread)) ]' <<<"$all_mentions")"
  else
    fresh_mentions='[]'
  fi
  keep_threads="$(printf '%s\n' "$fresh_threads" \
    | awk -v ceiling="$MENTION_THREAD_CEILING" 'NF && selected < ceiling {
        print $1; selected++
      }')"
  if [ -n "$keep_threads" ]; then
    keep_json="$(printf '%s\n' "$keep_threads" | jq -R . | jq -cs .)"
    mentions="$(jq -c --argjson keep "$keep_json" \
      '[ .[] | select(.thread as $thread | $keep | index($thread)) ]' <<<"$all_mentions")"
  else
    mentions='[]'
  fi
  mcount="$(jq 'length' <<<"$mentions" 2>/dev/null || echo 0)"
  if [ "$mcount" -gt 0 ]; then
    log "fleet: ${mcount} unread mention(s) — launching one mention session"
    RUN_SESSION_RC=1
    run_session mention fleet "$DUTY_DIR" "$TIMEOUT_MENTION" \
      "$(render_prompt mention.txt ME="$ME" MENTIONS="$mentions")"
    mention_rc="${RUN_SESSION_RC:-1}"
    # One transaction for the batch: a crash or timeout commits none, so every
    # thread retries next tick. The ceiling's remainder was never selected and
    # therefore remains uncommitted too.
    if [ "$mention_rc" -eq 0 ]; then
      printf '%s\n' "$mentions" | jq -r '.[] | "\(.thread) \(.updated)"' \
        | ledger_commit "$DUTY_DIR/.seen-mentions"
    fi
  fi

  for R in "${repos[@]}"; do
    _triage_repo "$R" \
      "$(jq --arg repo "$R" '[.[] | select(.repo == $repo)] | length' \
        <<<"$fresh_mentions" 2>/dev/null || echo 0)" \
      "$(jq --arg repo "$R" '[.[] | select(.repo == $repo)] | length' \
        <<<"$mentions" 2>/dev/null || echo 0)"
  done
}

_triage_repo() {
  local R="$1"
  local mention_count="${2:-0}"
  local selected_mention_count="${3:-0}"
  local owner="${R%%/*}" name="${R##*/}"
  local signals="" nt stray undisc unblockable="" dir prompt
  local fresh_nt="" fresh_stray="" fresh_discussions=""

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
  # the sets are disjoint by construction — a stray carries none of the six
  # queue labels, so it can never also be needs-triage. Keys are REPO-qualified
  # for the reason (c) records: one ledger spans every repo in repos.txt, and a
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
    fresh_nt="$(printf '%s\n' "$nt_items" \
      | ledger_filter "$DUTY_DIR/.seen-triage-board")"
    nt="$(printf '%s\n' "$fresh_nt" | awk 'NF{c++} END{print c+0}')"
    [ "$nt" -gt 0 ] && signals="$signals ${nt}x needs-triage;"
  fi

  # (b) queue-unlabeled strays: the board invariant, quoted from LABELS.md, is
  # that every open issue "is either needs-triage, epic, or carries exactly one
  # of ready / claimed / blocked / post-merge" — SIX labels. This enumeration
  # said five until #358, dropping post-merge, and the paraphrase is what made
  # that survivable-looking: the moment triage did its job and moved a merged
  # issue post-merge, it converted that issue into a permanent violation of the
  # engine's own invariant, which no session could ever clear because
  # post-merge is the correct terminal state. The detector asks exactly one
  # question — does this issue carry a queue label — and the composition rules
  # (post-merge never composes with blocked or attention, an assigned
  # post-merge issue is flagged) are the sweep's, not this signal's.
  stray_json="$(gh issue list -R "$R" --state open --limit 200 \
    --json number,labels,updatedAt 2>/dev/null || echo err)"
  if [ "$stray_json" = err ]; then
    warn "$R: stray probe failed"
  elif ! stray_items="$(printf '%s' "$stray_json" \
      | jq -r --arg repo "$R" --arg r "$LABEL_READY" --arg c "$LABEL_CLAIMED" --arg b "$LABEL_BLOCKED" \
           --arg p "$LABEL_POST_MERGE" --arg e "$LABEL_EPIC" --arg n "$LABEL_NEEDS_TRIAGE" \
        '.[] | select( ([.labels[].name]
            | map(. == $r or . == $c or . == $b or . == $p or . == $e or . == $n) | any) | not )
          | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
    warn "$R: stray parse failed"
    stray_items=""
  else
    fresh_stray="$(printf '%s\n' "$stray_items" \
      | ledger_filter "$DUTY_DIR/.seen-triage-board")"
    stray="$(printf '%s\n' "$fresh_stray" | awk 'NF{c++} END{print c+0}')"
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
  # After #253 this reports the board as it stood when the launch decision was
  # made, which is what the message claims — so the WARN now lands after the
  # mention session's SESSION START/END lines rather than before them.
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
  if ! uncommented_disc="$(_triage_discussion_items "$R" "$owner" "$name" 2>/dev/null)"; then
    warn "$R: discussion probe failed (discussions disabled?)"
    uncommented_disc=""
  else
    fresh_discussions="$(printf '%s\n' "$uncommented_disc" \
      | ledger_filter "$DUTY_DIR/.seen-discussions")"
    undisc="$(printf '%s\n' "$fresh_discussions" | awk 'NF{c++} END{print c+0}')"
    [ "$undisc" -gt 0 ] && signals="$signals ${undisc}x uncommented discussions;"
  fi

  # (e) blocked issues whose named blockers all landed. The parser is
  # deliberately narrow (see lib/jq/blockers.jq — corpus-tested); issue and
  # PR numbering is shared, so the state map needs both lists. Fail-safe by
  # construction: an unknown number counts as still-open.
  local blocked_json numstates unblockable_items="" fresh_unblockable=""
  blocked_json="$(gh issue list -R "$R" --state open --label "$LABEL_BLOCKED" \
    --limit 200 --json number,body,updatedAt 2>/dev/null || echo '[]')"
  if [ "$(jq 'length' <<<"$blocked_json" 2>/dev/null || echo 0)" -gt 0 ]; then
    numstates="$( { gh issue list -R "$R" --state all --limit 500 --json number,state
                    gh pr    list -R "$R" --state all --limit 500 --json number,state; } 2>/dev/null \
      | jq -s 'add | map({key:(.number|tostring), value:.state}) | from_entries' || echo '{}')"
    if ! unblockable_items="$(_triage_unblockable_items "$R" "$blocked_json" "$numstates")"; then
      warn "$R: unblockable parse failed"
      unblockable_items=""
    fi
  fi
  fresh_unblockable="$(printf '%s\n' "$unblockable_items" \
    | ledger_filter "$DUTY_DIR/.seen-unblockable")"
  unblockable="$(printf '%s\n' "$fresh_unblockable" | awk 'NF {
    number=$1; sub(/^.*#/, "", number); due = due sep number; sep="," }
    END { print due }')"
  [ -n "$unblockable" ] && signals="$signals unblockable:${unblockable};"
  printf '%s\n' "$unblockable_items" \
    | ledger_suppressed "$DUTY_DIR/.seen-unblockable" \
    | report_suppressed "$DUTY_DIR/.suppressed-unblockable.${R//\//_}" "$R: unblockable"

  if [ -z "$signals" ]; then
    if [ "$mention_count" -eq 0 ]; then
      log "$R: quiet — no mentions, no triage signals, no session launched"
    elif [ "$selected_mention_count" -eq 0 ]; then
      log "$R: mentions deferred by fleet ceiling — no triage signals, no repo session launched"
    else
      log "$R: no triage signals — mention session was the only wake"
    fi
    return 0
  fi

  log "$R: signals:$signals launching triage session"
  dir="$WORK_DIR/${R//\//__}"
  ensure_checkout "$R" "$dir" || return 0
  local signal_items="" signal_block=""
  if [ -n "$fresh_nt" ]; then
    signal_items="- Needs-triage issues: $(printf '%s\n' "$fresh_nt" | _triage_signal_numbers)"
  fi
  if [ -n "$fresh_stray" ]; then
    signal_items="${signal_items:+$signal_items
}- Queue-unlabeled issues: $(printf '%s\n' "$fresh_stray" | _triage_signal_numbers)"
  fi
  if [ -n "$fresh_discussions" ]; then
    signal_items="${signal_items:+$signal_items
}- Unresolved discussions without your voice: $(printf '%s\n' "$fresh_discussions" | _triage_signal_numbers)"
  fi
  if [ -n "$unblockable" ]; then
    signal_items="${signal_items:+$signal_items
}- Possibly unblockable issues: #${unblockable//,/, #}. Treat these as leads, not verdicts: re-read each body yourself, confirm the blockers really are the ones named and really did land, then flip to ready per {{DOCTRINE_TRIAGE}}. If a flag is wrong, leave the label alone and say why in your summary — a false lead here is a parser bug worth knowing about."
  fi
  signal_block="$(render_prompt fragment-triage-signals.txt SIGNAL_ITEMS="$signal_items")"
  prompt="$(render_prompt triage.txt ME="$ME" REPO="$R" SIGNAL_BLOCK="$signal_block")"
  RUN_SESSION_RC=1
  run_session triage "$R" "$dir" "$TIMEOUT_TRIAGE" "$prompt"
  # Mark each signal at the state in which the session LEFT it, not the state
  # that launched the session. That prevents the session's own comments from
  # re-waking it next tick. A third-party write racing the re-read is swallowed
  # in the safe direction: hourly hygiene remains the unconditional backstop,
  # and every stable suppressed set is still reported. Never substitute now():
  # the board's own timestamps are the evidence the next tick compares.
  #
  # Committed ONLY on rc 0, exactly as (c) is: a crashed or timed-out session
  # must leave its ids uncommitted so the next tick retries. That distinction —
  # declined vs never got there — is the whole reason this is safe.
  if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
    local post_board_json post_nt="" post_stray="" post_discussions=""
    local post_blocked post_numstates post_unblockable=""
    post_board_json="$(gh issue list -R "$R" --state open --limit 200 \
      --json number,body,labels,updatedAt 2>/dev/null || echo err)"
    if [ "$post_board_json" = err ]; then
      warn "$R: post-session board probe failed; ledgers left unchanged"
    else
      if ! post_nt="$(printf '%s' "$post_board_json" | jq -r --arg repo "$R" \
          --arg n "$LABEL_NEEDS_TRIAGE" \
          '.[] | select([.labels[].name] | index($n))
            | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
        warn "$R: post-session needs-triage parse failed"
        post_nt=""
      fi
      if ! post_stray="$(printf '%s' "$post_board_json" \
          | jq -r --arg repo "$R" --arg r "$LABEL_READY" --arg c "$LABEL_CLAIMED" \
              --arg b "$LABEL_BLOCKED" --arg p "$LABEL_POST_MERGE" \
              --arg e "$LABEL_EPIC" --arg n "$LABEL_NEEDS_TRIAGE" \
            '.[] | select( ([.labels[].name]
                | map(. == $r or . == $c or . == $b or . == $p or . == $e or . == $n) | any) | not )
              | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
        warn "$R: post-session stray parse failed"
        post_stray=""
      fi
      printf '%s\n%s\n' "$post_nt" "$post_stray" \
        | ledger_commit "$DUTY_DIR/.seen-triage-board"

      post_blocked="$(printf '%s' "$post_board_json" | jq -c \
        --arg b "$LABEL_BLOCKED" '[.[] | select([.labels[].name] | index($b))]' 2>/dev/null || echo err)"
      if [ "$post_blocked" = err ]; then
        warn "$R: post-session blocked parse failed"
      elif [ "$(jq 'length' <<<"$post_blocked" 2>/dev/null || echo 0)" -gt 0 ]; then
        post_numstates="$( { gh issue list -R "$R" --state all --limit 500 --json number,state
                            gh pr    list -R "$R" --state all --limit 500 --json number,state; } 2>/dev/null \
          | jq -s 'add | map({key:(.number|tostring), value:.state}) | from_entries' || echo err)"
        if [ "$post_numstates" = err ] || \
           ! post_unblockable="$(_triage_unblockable_items "$R" "$post_blocked" "$post_numstates")"; then
          warn "$R: post-session unblockable probe failed; ledger left unchanged"
        else
          printf '%s\n' "$post_unblockable" | ledger_commit "$DUTY_DIR/.seen-unblockable"
        fi
      fi
    fi

    if post_discussions="$(_triage_discussion_items "$R" "$owner" "$name" 2>/dev/null)"; then
      printf '%s\n' "$post_discussions" | ledger_commit "$DUTY_DIR/.seen-discussions"
    else
      warn "$R: post-session discussion probe failed; ledger left unchanged"
    fi
  fi
}
