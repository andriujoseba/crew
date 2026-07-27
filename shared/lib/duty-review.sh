# duty-review.sh — the reviewer wake: outstanding review requests, one
# merged candidate set, verdict dedup by head SHA, re-request auto-approve.
#
# Doctrine (REVIEWER.md / FLEET.md), as amended by danmt 2026-07-25:
#  - repos.txt IS the scope. A review request authorizes a review only in a
#    repo this box carries. The previous rule ("a request anywhere in the org
#    or a fleet fork is authorization; no repo list scopes it") made every
#    box's write surface the entire org, which no registry could bound: the
#    #26 interlock narrows repos.txt and so confined triage and hygiene, but
#    NOT this module. Scope is now the registry.
#    Corrected 2026-07-27 (#52): this note used to claim the interlock also
#    confined ATTENTION. It does not, and never did — duty-attention.sh reads
#    the authenticated-user issues endpoint on purpose, cross-repo, and
#    reaches repos not in repos.txt. That inaccuracy mattered: it is the kind
#    of claim that reads like coverage, which is the whole complaint #52 was
#    filed about. drill/rehearsal-safety.sh now checks attention separately
#    rather than assuming repos.txt bounds it.
#  - Awareness is still org-wide, but it never acts. One search query per
#    tick reports requests outside the registry, so the failure mode the old
#    rule existed to prevent (cast#143: a converged round sat unowed for 40
#    minutes) surfaces as a logged line instead of silence. If one of those
#    matters, the repo belongs in repos.txt — that is an operator decision,
#    not something a sweep should make by writing to a repo nobody listed.
#  - Truth comes from object endpoints (pulls API, pulls/N/reviews). The
#    SEARCH index lags — it caused missed wakes (cast#143, box#164, rig#112,
#    nine hours) and double reviews (#26, #29). Search only ADDS candidates.
#  - ONE candidate set, merged and deduped by (repo, PR) BEFORE acting —
#    sequential source passes double-announced on ceremony#32 (grok + kimi).
#  - requested_reviewers self-clears on submit, so the queue needs no
#    remembered state.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

# Repos where I author an open PR — read off the sweep's own pulls pages at
# zero extra API cost (claude-bot's cast#143 fix). Consumed by duty-builder.
REVIEW_MY_PR_REPOS=""

duty_review() {
  local candidates="" page SR
  # The registry is the scope. Object endpoints only — one authoritative
  # pulls page per carried repo, never the lagging search index.
  while IFS= read -r SR; do
    [ -n "$SR" ] || continue
    page="$(gh api "repos/$SR/pulls?state=open&per_page=100" --paginate 2>/dev/null | jq -cs 'add // []')" \
      || { warn "review: pulls fetch failed for $SR; skipping repo this tick"; continue; }
    candidates="$candidates
$(printf '%s' "$page" | jq -r --arg me "$ME" --arg sr "$SR" \
      '.[] | select(.draft | not) | select([.requested_reviewers[].login] | index($me)) | "\(.created_at) \($sr) \(.number)"')"
    if printf '%s' "$page" | jq -e --arg me "$ME" '[.[] | select(.user.login == $me)] | length > 0' >/dev/null; then
      REVIEW_MY_PR_REPOS="$REVIEW_MY_PR_REPOS $SR"
    fi
  done < <(read_repo_list "$REPOS_FILE")

  # Awareness pass — reports, never acts. A request outside the registry is
  # an operator signal ("should this box carry that repo?"), not a licence to
  # write to it. Cheap by construction: one search call, and the index's lag
  # is acceptable for a hint in a way it never was for the queue itself.
  local outside cand unscoped=""
  outside="$(gh search prs --review-requested="$ME" --state open --limit 50 \
    --json repository,number --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null || true)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if ! read_repo_list "$REPOS_FILE" | grep -qxF "${cand%%#*}"; then
      unscoped="$unscoped $cand"
    fi
  done <<<"$outside"
  if [ -n "$unscoped" ]; then
    warn "review: request(s) outside repos.txt, NOT acted on:$unscoped — add the repo to repos.txt if this box should carry it"
  fi

  # One candidate per (repo, PR) — first mention wins (the authoritative
  # sweep precedes the backstop), then oldest-first for the acting order.
  candidates="$(printf '%s\n' "$candidates" | awk 'NF==3 && !seen[$2"#"$3]++' | sort)"
  if [ -z "$candidates" ]; then
    log "review: no outstanding review requests anywhere"
    return 0
  fi

  local -A repo_prs=()
  local repo_order=() _created N owner name fields head mine_oid mine_at req_at head_now body
  while read -r _created SR N; do
    [ -z "${N:-}" ] && continue
    owner="${SR%%/*}"; name="${SR##*/}"
    # Per-PR dedup guard: my own latest VERDICT's commit oid vs the live
    # head — one GraphQL call fetches both plus what the re-request rule
    # needs. states filter excludes COMMENTED: a comment is a non-verdict.
    fields="$(RV_ME="$ME" gh api graphql \
      -f query='query($owner:String!,$name:String!,$num:Int!,$me:String!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid
          reviews(author:$me,last:1,states:[APPROVED,CHANGES_REQUESTED]){nodes{commit{oid} submittedAt}}
          timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT],last:20){
            nodes{... on ReviewRequestedEvent{createdAt requestedReviewer{... on User{login}}}}}
        } } }' \
      -f owner="$owner" -f name="$name" -F num="$N" -f me="$ME" \
      --jq '.data.repository.pullRequest as $pr
        | ($pr.reviews.nodes[0] // {}) as $mine
        | ([$pr.timelineItems.nodes[] | select((.requestedReviewer.login // "") == env.RV_ME) | .createdAt] | max // "-") as $req
        | "\($pr.headRefOid) \($mine.commit.oid // "-") \($mine.submittedAt // "-") \($req)"' \
      2>/dev/null || echo err)"
    if [ "$fields" = "err" ]; then
      warn "review: $SR#$N state fetch failed; skipping this tick"
      continue
    fi
    read -r head mine_oid mine_at req_at <<<"$fields"

    if [ "$mine_oid" != "$head" ]; then
      if [ -z "${repo_prs[$SR]:-}" ]; then repo_order+=("$SR"); fi
      repo_prs[$SR]="${repo_prs[$SR]:-}$N "
      continue
    fi

    # My latest verdict already covers the head. The re-request rule
    # (operator ruling 2026-07-23, ceremony#94): a review-requested event
    # NEWER than my review at this unchanged head is answered with an
    # auto-approve, not silence — a re-request at the same tree means the
    # stale verdict must not sit as a blocker. Head re-verified immediately
    # before submitting; the submit goes through the one-shot gate like any
    # verdict.
    if [ "${AUTO_APPROVE_REREQUEST:-1}" = "1" ] && [ "$req_at" != "-" ] && [ "$mine_at" != "-" ] && [[ "$req_at" > "$mine_at" ]]; then
      head_now="$(gh api "repos/$SR/pulls/$N" --jq .head.sha 2>/dev/null || echo err)"
      if [ "$head_now" = "$head" ]; then
        body="$(mktemp)"
        printf 'Re-requested at unchanged head %s — my latest review already covers this tree; approving per the re-request rule.\n' "$head" >"$body"
        # --supersede-own: the approval must REPLACE my stale verdict at this
        # same head; the gate's normal already-present check would refuse it
        # and the wake would refire forever. Idempotent across ticks because
        # the new approval makes mine_at newer than req_at.
        if "$BIN_DIR/submit-verdict.sh" "$SR" "$N" "$head" approve "$body" --supersede-own; then
          log "review: $SR#$N auto-approved re-request at unchanged head ${head:0:12}"
        else
          warn "review: $SR#$N auto-approve did not land (will retry next tick)"
        fi
        rm -f "$body"
      elif [ "$head_now" = "err" ]; then
        warn "review: $SR#$N head re-verify failed; deferring"
      else
        log "review: $SR#$N head moved during dedup — queued for a real review"
        if [ -z "${repo_prs[$SR]:-}" ]; then repo_order+=("$SR"); fi
        repo_prs[$SR]="${repo_prs[$SR]:-}$N "
      fi
    else
      log "review: $SR#$N my latest review already covers head ${head:0:12}; skipping (request mid-clear or stale search)"
    fi
  done <<<"$candidates"

  # One session per repo covering all its pending PRs, oldest first —
  # amortizes checkout and session cost (grok/kimi pattern).
  local dir slug prompt prs
  for SR in "${repo_order[@]}"; do
    prs="${repo_prs[$SR]% }"
    slug="${SR//\//__}"
    log "review: $SR needs verdicts on: $prs — launching review session"
    dir="$WORK_DIR/$slug-review"
    ensure_checkout "$SR" "$dir" || continue
    prompt="$(render_prompt review.txt ME="$ME" REPO="$SR" PRS="$prs" \
      BIN="$BIN_DIR" WT_DIR="$TREES_DIR/$slug" \
      MARK_REVIEWING="$MARK_REVIEWING" \
      ONESHOT_RULES="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")")"
    run_session review "$SR" "$dir" "$TIMEOUT_REVIEW" "$prompt"
  done
}
