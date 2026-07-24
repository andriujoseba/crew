# duty-review.sh — the reviewer wake: outstanding review requests, one
# merged candidate set, verdict dedup by head SHA, re-request auto-approve.
#
# Doctrine (REVIEWER.md / FLEET.md):
#  - A review request IS authorization, anywhere in the org or a fleet fork.
#    No repo list scopes it; repos.txt is only a backstop.
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
  local candidates="" org_repos page SR
  org_repos="$(gh api "/orgs/$FLEET_ORG/repos" --paginate --jq '.[].full_name' 2>/dev/null || echo err)"
  if [ "$org_repos" = "err" ]; then
    warn "review: org repo enumeration failed this tick; the repos.txt backstop still collects"
    org_repos=""
  fi
  # shellcheck disable=SC2086
  for SR in $org_repos $FLEET_SWEEP_EXTRA_REPOS; do
    page="$(gh api "repos/$SR/pulls?state=open&per_page=100" --paginate 2>/dev/null | jq -cs 'add // []')" \
      || { warn "review: pulls fetch failed for $SR; skipping repo this tick"; continue; }
    candidates="$candidates
$(printf '%s' "$page" | jq -r --arg me "$ME" --arg sr "$SR" \
      '.[] | select(.draft | not) | select([.requested_reviewers[].login] | index($me)) | "\(.created_at) \($sr) \(.number)"')"
    if printf '%s' "$page" | jq -e --arg me "$ME" '[.[] | select(.user.login == $me)] | length > 0' >/dev/null; then
      REVIEW_MY_PR_REPOS="$REVIEW_MY_PR_REPOS $SR"
    fi
  done

  # Backstop: repos.txt via the search index. Only ADDS candidates (e.g.
  # after an org-enumeration failure); never evidence of no duty.
  local BR
  while IFS= read -r BR; do
    candidates="$candidates
$(gh pr list -R "$BR" --state open --search "review-requested:$ME" \
      --json number,createdAt,isDraft \
      --jq '.[] | select(.isDraft | not) | "\(.createdAt) '"$BR"' \(.number)"' 2>/dev/null || true)"
  done < <(read_repo_list "$REPOS_FILE")

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
    if [ "$req_at" != "-" ] && [ "$mine_at" != "-" ] && [[ "$req_at" > "$mine_at" ]]; then
      head_now="$(gh api "repos/$SR/pulls/$N" --jq .head.sha 2>/dev/null || echo err)"
      if [ "$head_now" = "$head" ]; then
        body="$(mktemp)"
        printf 'Re-requested at unchanged head %s — my latest review already covers this tree; approving per the re-request rule.\n' "$head" >"$body"
        if "$BIN_DIR/submit-verdict.sh" "$SR" "$N" "$head" approve "$body"; then
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
