# duty-builder.sh — builder wakes, in doctrine priority order (FLEET.md):
# resume → ci-red → build (ready issues / completed rounds) → handoff →
# rebase, plus worktree hygiene. ci-red precedes build because your own red
# head outranks a new claim (ceremony BUILDER.md); the block order in this
# file IS the tick order, and this header is what FLEET.md is reconciled
# against. All predicates are computed from latestReviews /
# latestOpinionatedReviews, NEVER reviewDecision: reviewDecision exists only
# under branch protection and stays "" here — keying on it silently stalled
# rounds for a day (ceremony#26, #39).
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

# Author-side duty repos are repos.txt-scoped, like every other module
# (danmt 2026-07-25). This previously swept the org, on the rationale that
# cast#143's converged round sat unowed 40 minutes while every tick looked
# only at ceremony — but an org-wide author sweep also lets a builder box
# act on repos nobody put in its registry, which is the same unbounded write
# surface the reviewer sweep had. The miss cast#143 describes is now a
# logged line (below) rather than silence, and the repair is to add the repo.
_discover_my_pr_repos() {
  if [ -n "$REVIEW_MY_PR_REPOS" ] || has_role reviewer; then
    # shellcheck disable=SC2086  # splitting the space-joined list is the point
    printf '%s\n' $REVIEW_MY_PR_REPOS
    return 0
  fi
  local SR
  while IFS= read -r SR; do
    [ -n "$SR" ] || continue
    if gh api "repos/$SR/pulls?state=open&per_page=100" --paginate 2>/dev/null \
      | jq -se --arg me "$ME" '[add[] | select(.user.login == $me)] | length > 0' >/dev/null; then
      printf '%s\n' "$SR"
    fi
  done < <(read_repo_list "$REPOS_FILE")
}

# Awareness pass — reports, never acts. Mirrors the reviewer sweep: an open
# PR I authored in a repo outside the registry is an operator signal, not
# licence to work it.
_warn_unscoped_authored() {
  local mine cand unscoped=""
  mine="$(gh search prs --author="$ME" --state open --limit 50 \
    --json repository,number --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null || true)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if ! read_repo_list "$REPOS_FILE" | grep -qxF "${cand%%#*}"; then
      unscoped="$unscoped $cand"
    fi
  done <<<"$mine"
  if [ -n "$unscoped" ]; then
    warn "builder: authored PR(s) outside repos.txt, NOT acted on:$unscoped — add the repo to repos.txt if this box should carry it"
  fi
}

duty_builder() {
  local duty_repos R
  duty_repos="$({ read_repo_list "$REPOS_FILE"; _discover_my_pr_repos; } | awk 'NF && !seen[$0]++')"
  _warn_unscoped_authored

  while IFS= read -r R; do
    [ -z "$R" ] && continue
    _builder_repo "$R"
  done <<<"$duty_repos"
}

_builder_repo() {
  local R="$1"
  local slug="${R//\//__}" owner="${R%%/*}" name="${R##*/}"
  local dir="$WORK_DIR/$slug"
  local wt_rules round_rules oneshot_rules panel_json
  wt_rules="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name")"
  round_rules="$(render_prompt fragment-round-rules.txt TRIAGE="$FLEET_TRIAGE" BENCH="$FLEET_BENCH" MARK_ADDRESSING="$MARK_ADDRESSING")"
  oneshot_rules="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")"

  # --- RESUME: interrupted work of mine, checked FIRST. Two shapes: an open
  # draft PR (a session died mid-build), or a claimed issue whose build/*
  # branch exists on my fork with no open PR (died between first push and
  # `gh pr create`). I hold the duty lock, so nothing else of mine can be
  # mid-flight — that lock is what makes resume detection sound. ---
  local draft_nums orphan_nums="" claimed_nums open_heads merged_heads N branch
  draft_nums="$(gh pr list -R "$R" --state open --author "$ME" --draft \
    --json number --jq '.[].number' 2>/dev/null | tr '\n' ' ' || echo err)"
  claimed_nums="$(gh issue list -R "$R" --state open --label "$LABEL_CLAIMED" \
    --assignee "$ME" --json number --jq '.[].number' 2>/dev/null || echo err)"
  open_heads="$(gh pr list -R "$R" --state open --author "$ME" \
    --json headRefName --jq '.[].headRefName' 2>/dev/null || echo err)"
  # A merged build/* branch is NOT interrupted work: its PR landed, and the
  # claim lingers only until triage moves the issue to its post-merge state
  # (heavy-duty/ceremony#172 — the PR carried Refs #N, not Closes, because the
  # remaining ACs are post-merge and triage-owned). Treating it as an orphan
  # phantom-rebuilds merged code every tick and holds the build slot against
  # ready work (incubator#55/#64). Gather merged heads and exclude them below,
  # so every box gets this in the shared engine instead of re-deriving it by
  # hand per box (codex's per-box bridge, heavy-duty/crew#19).
  merged_heads="$(gh pr list -R "$R" --state merged --author "$ME" \
    --json headRefName --jq '.[].headRefName' 2>/dev/null || echo err)"
  if [ "$draft_nums" = "err" ] || [ "$claimed_nums" = "err" ] || [ "$open_heads" = "err" ] || [ "$merged_heads" = "err" ]; then
    warn "$R: resume detection failed (a listing errored); skipping resume this tick"
    draft_nums=""
  else
    for N in $claimed_nums; do
      branch="$(gh api "repos/$ME/$name/git/matching-refs/heads/build/$N-" \
        --jq '.[0].ref // "" | sub("^refs/heads/"; "")' 2>/dev/null || echo "")"
      [ -z "$branch" ] && continue
      # Post-merge wait, not an orphan: the branch already merged. Never resume
      # it — re-entry for any residue is a fresh branch off current main, by
      # a builder claiming the re-readied issue normally (#172), not this one.
      if printf '%s\n' "$merged_heads" | grep -qx "$branch"; then continue; fi
      if ! printf '%s\n' "$open_heads" | grep -qx "$branch"; then
        orphan_nums="$orphan_nums $N"
      fi
    done
  fi
  if [ -n "${draft_nums// /}" ] || [ -n "${orphan_nums// /}" ]; then
    log "$R: resume duty (drafts: ${draft_nums:-none}; orphaned claims:${orphan_nums:-" none"})"
    ensure_main_clone "$R" "$dir" || return 0
    run_session resume "$R" "$dir" "$TIMEOUT_RESUME" \
      "$(render_prompt resume.txt ME="$ME" REPO="$R" NAME="$name" \
        DRAFTS="${draft_nums:-none}" ORPHANS="${orphan_nums:-none}" \
        MARK_RESUME="$MARK_RESUME" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules")"
  else
    log "$R: no resume duty"
  fi

  panel_json="$(panel_for_repo "$R" "$dir" | jq -c --arg me "$ME" '. - [$me]')"

  # --- One listing of my open PRs, several facts. The state of the check at
  # the head was never read by this engine at all: `statusCheckRollup` appeared
  # nowhere in it. That single omission is both #45 (a fix round opened on a red
  # head spends a full panel round relaying a failure the author already had)
  # and #17 (a red head with no round owed and no conflict woke nothing, so an
  # approved, mergeable PR stranded on a transient CI failure). One datum, two
  # bugs — and the round-owed signal was already fetching this exact listing, so
  # headRefOid and statusCheckRollup ride along for no additional call.
  local mine_json mine_rows
  mine_json="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft,latestReviews,reviewRequests,updatedAt,headRefOid,statusCheckRollup \
    2>/dev/null || echo err)"
  if [ "$mine_json" = "err" ]; then
    mine_rows=err
  else
    mine_rows="$(printf '%s' "$mine_json" \
      | jq -r --argjson panel "$panel_json" --arg repo "$R" \
        -f "$DUTY_DIR/lib/jq/head-checks.jq" 2>/dev/null || echo err)"
  fi

  # --- CI-RED: a PR of mine whose check FAILED at the current head. Placed
  # before BUILD on purpose — a builder repairs its own red PR before claiming
  # another issue (ceremony#163: full-panel approvals at the head, mergeable,
  # and stranded on an HTTP 429 while a job downloaded actions/checkout. No PR
  # code ever ran. No wake condition covered it, because CI-red is actionable
  # authored work even when there is no requested change and no conflict).
  #
  # THE LEDGER ID CARRIES THE HEAD, AND ITS VALUE IS A FIXED SENTINEL. Both
  # halves are deliberate. ledger_filter re-fires when the value sorts GREATER,
  # and a SHA has no order — keyed the usual way, a corrective push whose oid
  # happened to sort below the previous one would be SUPPRESSED, killing
  # exactly the wake this block exists to deliver. So the head goes in the id,
  # where a new head is an id never seen and always fires; and the value cannot
  # advance within one head, which is "never blind-rerun a deterministic
  # failure" (#17's fifth bullet) expressed as data rather than as an
  # instruction a session may forget. updatedAt is wrong here for the same
  # reason from the other side: a comment on the PR would advance it and buy
  # another rerun of an unchanged tree.
  local red_items red_fresh red_key red_checks red_num
  if [ "$mine_rows" = "err" ]; then
    warn "$R: CI-red detection failed; skipping"
  else
    red_items="$(awk -F'\t' '$4 == "red" { print $1 "@" $3 "\thead\t" $6 }' <<<"$mine_rows")"
    red_fresh="$(printf '%s\n' "$red_items" | ledger_filter "$DUTY_DIR/.seen-ci-red")"
    # A red head we have already spent a session on is still red. Stop paying
    # for it; do not stop saying it (#59).
    printf '%s\n' "$red_items" \
      | ledger_suppressed "$DUTY_DIR/.seen-ci-red" \
      | report_suppressed "$DUTY_DIR/.suppressed-ci-red.$slug" "$R: ci-red"
    if [ -z "${red_fresh//[[:space:]]/}" ]; then
      log "$R: no ci-red duty"
    else
      while IFS=$'\t' read -r red_key _ red_checks; do
        [ -n "$red_key" ] || continue
        red_num="${red_key#*#}"; red_num="${red_num%@*}"
        log "$R#$red_num: check RED at head — launching ci-red session (${red_checks:-unknown})"
        ensure_main_clone "$R" "$dir" || continue
        RUN_SESSION_RC=1
        run_session ci-red "$R#$red_num" "$dir" "$TIMEOUT_CIRED" \
          "$(render_prompt ci-red.txt ME="$ME" REPO="$R" NUM="$red_num" \
            CHECKS="${red_checks:-unknown}" WT_RULES="$wt_rules")"
        if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
          printf '%s\thead\n' "$red_key" | ledger_commit "$DUTY_DIR/.seen-ci-red"
        fi
      done <<<"$red_fresh"
    fi
  fi

  # --- BUILD: ready unclaimed issues, or my PRs whose round is WHOLE.
  # Rounds are answered whole (BUILDER.md): a changes-request is actionable
  # only when no panel review request is still outstanding. Ready issues
  # with an assignee are mid-claim, not pickable — counting them launched
  # sessions with nothing to do (codex's 69% busy-tick rate). ---
  #
  # Enumerated, not counted, and filtered through a seen-ledger — the same fix
  # (c)/(d) got on 2026-07-25 and (a)/(b) got in #59. A `ready` issue clears
  # this signal only when the session CLAIMS it, which is an action the session
  # may correctly decline (out of scope, unbuildable, needs a ruling). Declined
  # once, a bare count re-fires a build session every tick forever — and build
  # carries TIMEOUT_BUILD=3600, four times triage's ceiling, over a repo set
  # WIDER than repos.txt (_discover_my_pr_repos above). This was the most
  # expensive instance of the defect and the last one anybody looked at.
  # ONE issue listing, two derived facts. Two calls could disagree about the
  # board between them, and the assigned-count is only meaningful relative to
  # the same snapshot the pickable set came from.
  local ready_json ready_count ready_assigned cr_count head_checks="-"
  local ready_items="" cr_items=""
  ready_json="$(gh issue list -R "$R" --state open --label "$LABEL_READY" \
    --json number,assignees,updatedAt 2>/dev/null || echo err)"
  if [ "$ready_json" = "err" ]; then
    ready_count=err
  else
    ready_items="$(printf '%s' "$ready_json" | jq -r --arg repo "$R" \
      '.[] | select((.assignees | length) == 0) | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null || true)"
    ready_assigned="$(printf '%s' "$ready_json" \
      | jq '[.[] | select((.assignees | length) > 0)] | length' 2>/dev/null || echo 0)"
    ready_count="$(printf '%s\n' "$ready_items" \
      | ledger_filter "$DUTY_DIR/.seen-build" | awk 'NF{c++} END{print c+0}')"
    # ready+assigned is a board anomaly (a claim swaps ready→claimed); it
    # doesn't wake a builder, but it must not be invisible either — only
    # the triage box's hygiene can fix it.
    [ "$ready_assigned" -gt 0 ] && log "NOTE: $R has $ready_assigned ready issue(s) WITH an assignee (board anomaly; hygiene's to fix)"
  fi
  # Same treatment for the owed-round signal: a round the session declines to
  # answer is a permanent wake otherwise. number+updatedAt travel so the ledger
  # re-wakes on a push or a new review, which is exactly when it should.
  #
  # A RED HEAD IS NOT A ROUND (#45). The rule is the author's: a review request
  # requires a green check at the head, because a red check is the author's own
  # signal and not the panel's work. Measured on crew#40 — two consecutive
  # heads, four reviewer-rounds, every one relaying a CI failure already visible
  # in the job log. The most expensive of the four opened with "CI is red at
  # this head … that gates my approval" and stopped looking, so the cost is not
  # the wasted round, it is the findings that round did not make.
  #
  # Enforced here rather than left to the prompt. The doctrine belongs in
  # fragment-round-rules.txt as well, and is there — but a rule only a model can
  # apply is a rule that gets dropped under a long context, and this one has to
  # hold for every round of every builder. Nothing is stranded by the exclusion:
  # a red head has already woken the ci-red block above, which is the work that
  # has to happen first regardless.
  #
  # RED IS THE GATE; PENDING AND NONE ARE ADMITTED, DELIBERATELY (codex, #64).
  #
  # The exclusion is `red`, not "everything but green", and that is a decision
  # rather than a fallthrough — the same shape as the CANCELLED bug codex found
  # in the classifier, so it is written down here instead of being inferred.
  #
  #   none    A repo with no CI configured is `none` FOREVER. Selecting only
  #           green retires its owed rounds permanently — a strict regression
  #           against the engine before this change, which read no checks at
  #           all and woke every owed round. The escape ("an explicitly
  #           evidenced manual path") runs inside a session, and the session
  #           is what the gate would be suppressing.
  #   pending Excluding it stalls an owed round behind runner queue time and
  #           closes nothing: this gate spawns the AUTHOR's fix session, while
  #           #45's cost is a PANEL round, and a head green at wake time can
  #           still be red by the time the session re-requests. #45 item (2)
  #           asks the engine to "refuse to re-request while it is FAILURE" —
  #           FAILURE, and the re-request is an act of the session, which is
  #           why the enforceable half landed here as a wake gate.
  #
  # What the gate owes instead is the DATUM: a non-green head admitted here
  # travels into the build prompt, so the session applying the doctrine has
  # the check state in hand rather than being assumed to go look for it.
  local blocked_rounds
  if [ "$mine_rows" = "err" ]; then
    cr_items=""
    cr_count=err
    head_checks="-"
  else
    cr_items="$(awk -F'\t' '$5 == "owed" && $4 != "red" { print $1, $2 }' <<<"$mine_rows")"
    blocked_rounds="$(awk -F'\t' '$5 == "owed" && $4 == "red" { print $1 }' <<<"$mine_rows")"
    for N in $blocked_rounds; do
      log "$N: round owed, but the check at its head is RED — CI first, no panel round (#45)"
    done
    # Admitted, but not silently: named in the log AND handed to the session.
    head_checks="$(awk -F'\t' '$5 == "owed" && $4 != "red" && $4 != "green" { s = s (s ? "; " : "") $1 " (" $4 ")" } END { print s }' <<<"$mine_rows")"
    [ -n "$head_checks" ] && log "$R: round(s) admitted on a non-green head — $head_checks (#45: red is the gate, but the re-request still needs green)"
    head_checks="${head_checks:--}"
    cr_count="$(printf '%s\n' "$cr_items" \
      | ledger_filter "$DUTY_DIR/.seen-build" | awk 'NF{c++} END{print c+0}')"
  fi
  # Whatever the ledger hid is still real work that nobody has done — the
  # engine stops paying for it, and says so once per change to the set.
  # Per repo, for the reason spelled out in duty-triage.sh: _builder_repo runs
  # once per repo, and one shared state file makes every repo clobber the last.
  printf '%s\n%s\n' "$ready_items" "$cr_items" \
    | ledger_suppressed "$DUTY_DIR/.seen-build" \
    | report_suppressed "$DUTY_DIR/.suppressed-build.$slug" "$R: build"
  if [ "$ready_count" = "err" ] && [ "$cr_count" != "err" ]; then
    # Issue listing fails where issues are disabled (forks); that must not
    # blind the PR-based round detection.
    warn "$R: ready-issue detection failed (issues disabled?); counting 0"
    ready_count=0
  fi
  if [ "$cr_count" = "err" ]; then
    warn "$R: build-duty detection failed; skipping build this tick"
  elif [ "$ready_count" -gt 0 ] || [ "$cr_count" -gt 0 ]; then
    log "$R: build duty (ready unclaimed=$ready_count, whole rounds owed=$cr_count)"
    ensure_main_clone "$R" "$dir" || return 0
    RUN_SESSION_RC=1
    run_session build "$R" "$dir" "$TIMEOUT_BUILD" \
      "$(render_prompt build.txt ME="$ME" REPO="$R" TRIAGE="$FLEET_TRIAGE" \
        HEAD_CHECKS="$head_checks" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules" ONESHOT_RULES="$oneshot_rules")"
    # Record what this session SAW, at the state it saw it in — but only if the
    # session actually ran to completion. A crash or timeout leaves the ids
    # uncommitted so the next tick retries: declined and never-got-there must
    # not look the same to the ledger.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
      printf '%s\n%s\n' "$ready_items" "$cr_items" | ledger_commit "$DUTY_DIR/.seen-build"
    fi
  else
    log "$R: no build duty"
  fi

  # --- HANDOFF: a converged round of mine that owes the human. Convergence
  # computed directly: every panelist's latest opinionated review APPROVES
  # the CURRENT head, no panel request outstanding, PR mergeable RIGHT NOW,
  # and state:needs-human not already set (the human is off-panel — without
  # the refire guard this wake fires forever after a successful handoff).
  #
  # HANDOFF IS DELIBERATELY NOT GATED ON A GREEN HEAD, and the obvious
  # improvement is the bug (grok, #64). Adding `&& check_state == "green"`
  # here reads as symmetry with the round gate above, but the two wakes have
  # opposite failure modes: ci-red fires at most ONCE PER HEAD by design (the
  # ledger id carries the oid), so under a red that no push can clear — a
  # runner outage, a failure already on main — ci-red goes quiet after its one
  # session and a green-gated handoff would then wake nothing at all. That is
  # ceremony#163 exactly: full-panel approvals, mergeable, and stranded, which
  # is the incident #17 was filed from. A converged PR reaching the human with
  # a red check is a human's call to make; a converged PR reaching nobody is
  # the failure this module exists to end. ---
  local my_open converged handoff_prs=""
  my_open="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft --jq '.[] | select(.isDraft | not) | .number' 2>/dev/null || echo err)"
  if [ "$my_open" = "err" ]; then
    warn "$R: handoff detection failed; skipping"
  else
    for N in $my_open; do
      converged="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid mergeable
          labels(first:50){nodes{name}}
          reviewRequests(first:50){nodes{requestedReviewer{... on User{login}}}}
          latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
        } } }' -f owner="$owner" -f name="$name" -F num="$N" 2>/dev/null \
        | jq -r --argjson panel "$panel_json" --arg needs_human "$LABEL_NEEDS_HUMAN" \
            -f "$DUTY_DIR/lib/jq/converged.jq" \
        || echo err)"
      case "$converged" in
        true)  handoff_prs="$handoff_prs $N" ;;
        false) : ;;
        # UNKNOWN mergeability is GitHub's post-merge recompute flap; the
        # next tick sees the real value. Logged distinctly so a converged-
        # but-deferred PR is never mistaken for an unconverged round.
        defer-unknown) log "$R#$N: converged but mergeability UNKNOWN — deferring to next tick" ;;
        *)     warn "$R#$N: handoff-state fetch failed; skipping" ;;
      esac
    done
    for N in $handoff_prs; do
      log "$R#$N: round converged — launching handoff session"
      ensure_main_clone "$R" "$dir" || continue
      run_session handoff "$R#$N" "$dir" "$TIMEOUT_HANDOFF" \
        "$(render_prompt handoff.txt ME="$ME" REPO="$R" NUM="$N" \
          HUMAN="$FLEET_HUMAN" LABEL_NEEDS_HUMAN="$LABEL_NEEDS_HUMAN")"
    done
    [ -z "$handoff_prs" ] && log "$R: no handoff duty"
  fi

  # --- REBASE: only CONFLICTING fires; UNKNOWN waits out the flap. Drafts
  # excluded — a conflicting draft belongs to resume, and a panel must never
  # be requested on a draft. ---
  local conflict_prs
  conflict_prs="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,mergeable,isDraft \
    --jq '.[] | select((.isDraft | not) and .mergeable == "CONFLICTING") | .number' 2>/dev/null || echo err)"
  if [ "$conflict_prs" = "err" ]; then
    warn "$R: rebase detection failed; skipping"
  elif [ -n "$conflict_prs" ]; then
    for N in $conflict_prs; do
      log "$R#$N: conflicting — launching rebase session"
      ensure_main_clone "$R" "$dir" || continue
      run_session rebase "$R#$N" "$dir" "$TIMEOUT_REBASE" \
        "$(render_prompt rebase.txt ME="$ME" REPO="$R" NUM="$N" WT_RULES="$wt_rules")"
    done
  else
    log "$R: no rebase duty"
  fi

  # --- WORKTREE hygiene: a build/* worktree is removable only when its
  # branch has PR history AND no PR on it remains open — `--state all` with
  # a joined state list, so a newer closed PR can never shadow an older open
  # one (the .[0]-of-newest-first bug in codex's variant could delete a live
  # branch). A branch with no PR at all is an in-flight claim: resume's
  # business, stays. A dirty worktree is never force-removed. ---
  if [ -d "$dir/.git" ]; then
    git -C "$dir" worktree prune 2>/dev/null || true
    local wt_branch wt_path pr_states
    while read -r wt_branch wt_path; do
      [ -z "$wt_branch" ] && continue
      pr_states="$(gh pr list -R "$R" --author "$ME" --head "$wt_branch" \
        --state all --json state --jq '[.[].state] | join(" ")' 2>/dev/null || echo err)"
      case "$pr_states" in
        err)       warn "$R: worktree-hygiene PR lookup failed for $wt_branch; leaving it" ;;
        ""|*OPEN*) : ;;
        *)
          log "$R: $wt_branch is done ($pr_states) — removing worktree $wt_path"
          if git -C "$dir" worktree remove "$wt_path" 2>/dev/null; then
            git -C "$dir" branch -D "$wt_branch" 2>/dev/null || true
          else
            warn "worktree $wt_path not clean; leaving it for inspection"
          fi
          git -C "$dir" worktree prune 2>/dev/null || true
          ;;
      esac
    done < <(git -C "$dir" worktree list --porcelain \
      | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/build\//{b=$2; sub("refs/heads/","",b); print b, p}')
  fi
}
