# NOTE (crew copy): the duty loop — review sweep, attention, resume/build/handoff/rebase/hygiene; fired by tick.sh every 5 minutes.
#!/usr/bin/env bash
set -euo pipefail

# Re-exec from a private snapshot: duty.sh gets edited between (and
# occasionally racing) ticks, and bash reads scripts lazily — an in-place
# write under a running tick corrupts the reader's byte offset mid-file.
# The snapshot dies with the run.
if [ -z "${DUTY_SNAPSHOT:-}" ]; then
  snap="$(mktemp /tmp/duty-snapshot.XXXXXX.sh)"
  cp "$0" "$snap"
  DUTY_SNAPSHOT="$snap" exec bash "$snap"
fi
trap 'rm -f "$DUTY_SNAPSHOT"' EXIT

# Cron runs a minimal environment: no ~/.local/bin on PATH, so `claude`
# (installed at ~/.local/bin/claude) would not resolve. Export it explicitly.
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Once-per-boot sanity gate (runs here because the flock is already held —
# cron wraps this script in `flock -n`). The kernel boot id changes on every
# reboot, so the first tick after any restart runs the checks and later
# ticks skip them. The marker is written ONLY when both CLIs' auth works —
# a broken box re-checks every tick instead of silently playing with dead
# credentials. This gate replaces any @reboot cron line.
boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [ "$(cat "$HOME/duty/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
  {
    echo "== boot check $(date -Is) =="
    # `|| true`: this script runs set -e; a dead credential must fall
    # through to the marker gate below (and re-check next tick), not kill
    # the whole duty tick before review duty even runs.
    gh auth status || true
    df -h / | tail -1
    claude auth status || true
    # Stale worktree entries from a crash get cleaned on the first tick
    # after reboot (one line per repo clone on disk).
    for d in "$HOME"/duty/work/*/; do
      { [ -d "$d/.git" ] && git -C "$d" worktree prune -v; } || true
    done
  } >> "$HOME/duty/boot-check.log" 2>&1
  if gh auth status >/dev/null 2>&1 \
    && claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
    echo "$boot_id" > "$HOME/duty/.boot-id"
  fi
fi

ME="claude-bot-andresmgsl"
# The review bench (ceremony CONTRIBUTING's roster, minus triage). Requests
# to identities outside this set — e.g. the human at handoff — never hold a
# build wake.
BENCH_RE='^(claude-bot-andresmgsl|codex-bot-andresmgsl|grok-bot-andresmgsl|kimi-bot-andresmgsl)$'
BENCH_JSON='["claude-bot-andresmgsl","codex-bot-andresmgsl","grok-bot-andresmgsl","kimi-bot-andresmgsl"]'
DUTY_DIR="$HOME/duty"
WORK_DIR="$DUTY_DIR/work"
# One worktree per PR under trees/<repo-slug>/ — the main clone in work/
# stays parked on the default branch, always clean: a crashed build can
# never dirty it (it corrupted the old build clone on 2026-07-22), and two
# duties never collide in one tree. Worktrees share the object store, so
# the disk cost is near zero.
TREES_DIR="$DUTY_DIR/trees"
REPOS_FILE="$DUTY_DIR/repos.txt"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# Fix rounds get the same visibility and memory rules as builds (operator
# protocol, 2026-07-22). Appended to every session prompt that can touch a
# round or a worklog.
ROUND_RULES="Fix-round protocol, three hard rules: (1) ROUND PICKUP IS ANNOUNCED — the moment you pick up a completed review round on your PR, before touching any code, post one comment: '🔧 addressing round on head <sha>' followed by a round analysis covering every blocking and non-blocking point from every reviewer, each marked agree / disagree / needs-ruling plus concretely how you will address it; this is your plan of record, so reviewers can object early if you misread a point. (2) COMMIT CADENCE — never more than 15 minutes between pushes while you are working; if 15 minutes pass, push whatever exists (WIP commits are explicitly fine; never rewrite pushed history mid-round — reviewers track head SHAs); if the tree is genuinely untouched because you are reading, thinking, or stuck, update your worklog comment instead with what you are doing and why there is no commit. Silence is the only violation: a stall must produce evidence of the stall. (3) THE WORKLOG LIVES THROUGH FIX ROUNDS — keep the '## Worklog' checkbox discipline going during round fixes exactly as during builds: add the round's fix steps as checkboxes to the PR body, check off and push as you complete them, and re-request the reviewers when the fix is done. THE PANEL IS THE BENCH MINUS THE AUTHOR — claude, codex, grok, kimi bots, never dan-claude-bot: triage rules on issues and answers questions, it does not vote on PRs, and a review request to it sits outstanding forever, making the PR look permanently short of a full round. When you need triage's attention, @-mention dan-claude-bot in a comment — that is the channel for rulings, not a review request. The same bench governs any roster a PR itself AUTHORS: if your build writes a panel list (a labels.conf panel= line, a CONTRIBUTING roster), write the current bench, never port a repo's stale pre-ceremony list — cast#143 shipped a kimi-less panel exactly that way, and the handoff then read the roster the PR had authored and handed off a reviewer short."

# One-shot verdict discipline (operator protocol, 2026-07-22), shared by
# every prompt that submits a verdict.
ONESHOT_RULES="VERDICT SUBMISSION IS ONE-SHOT, hard rule: compose the verdict body ONCE, write it to a file, and if you have already composed a verdict for this head in this session you are done — never recompose or 'improve' it. Submit ONLY via: $DUTY_DIR/bin/submit-verdict.sh <owner/repo> <pr-number> <head-sha> <approve|request-changes> <body-file> — never via gh pr review directly. The wrapper re-checks the pulls/<N>/reviews endpoint live immediately before submitting, submits once pinned to your head SHA, and verifies with that same endpoint; that endpoint reflects your review immediately (it is the SEARCH index that lags, not it) — trust its verdict: if it reports your review present, the submit succeeded even if command output looked ambiguous or errored, and you STOP. Never submit a second time to make sure — a duplicate verdict is a protocol violation; a missed one is recoverable next tick. If the wrapper retries, it reuses your identical body; you never regenerate. If you discover an existing double-post of yours, do not post a comment about it — mention it in your final output only."

# Worktree rules text for a given repo (slug, name) — used by every
# session prompt that may touch git, in and outside the main loop.
wt_rules_for() {
  local name_="$2" wt_="$TREES_DIR/$1"
  printf '%s' "Worktree rules — you are launched in the MAIN clone: it stays parked on the default branch, always clean; fetch here, NEVER edit, commit, test, or rebase here. Every PR gets its own worktree under $wt_/. At claim time create branch and worktree in one step: git fetch origin && git worktree add $wt_/build-<N>-<short-slug> -b build/<N>-<short-slug> origin/main. To work on an existing branch: if git worktree list already shows its worktree, reuse it — never add a second one; if the branch exists but has no worktree, attach one: git worktree add $wt_/<dirname> <branch> (dirname is the branch name with / replaced by -). Push with git push -u fork <branch> (origin is the upstream repo, fork is your fork $ME/$name_). If git worktree add fails with 'already checked out', the main clone or a stale worktree is holding that branch — fix the holder (git worktree list, git worktree prune); never fall back to building in the main clone."
}

# Ensure a checkout of repo $1 exists at $2 (clone if missing, fetch if present).
# Never resets branches: a session owns its own git state.
ensure_checkout() {
  local repo="$1" dir="$2"
  if [ ! -d "$dir/.git" ]; then
    gh repo clone "$repo" "$dir" -- --quiet
  else
    git -C "$dir" fetch --quiet --all --prune || log "WARN: fetch failed in $dir"
  fi
}

# Ensure the MAIN clone of repo $1 at $2 with a `fork` remote at $3: parked
# on the default branch, fetch-only — builds happen in worktrees, never here.
ensure_main_clone() {
  local repo="$1" dir="$2" fork_url="$3"
  if [ ! -d "$dir/.git" ]; then
    gh repo clone "$repo" "$dir" -- --quiet
  fi
  git -C "$dir" remote get-url fork >/dev/null 2>&1 \
    || git -C "$dir" remote add fork "$fork_url"
  git -C "$dir" fetch --quiet --all --prune || log "WARN: fetch failed in $dir"
}

run_session() {
  local dir="$1" kind="$2" prompt="$3"
  log "launching $kind session in $dir"
  if (cd "$dir" && claude -p "$prompt" --dangerously-skip-permissions); then
    log "$kind session finished"
  else
    log "WARN: $kind session exited non-zero"
  fi
}

log "duty run start"

# --- REVIEW candidates: ONE set from TWO sources, then act once each
# (operator protocol 2026-07-23: grok and kimi double-announced on
# ceremony#32 when the request sweep and the repo-list poll each acted on
# the same PR in one tick). Source 1, authoritative: the org-wide
# requested_reviewers sweep — I may review anywhere in the heavy-duty org
# plus the named bot forks; a review request IS the authorisation, and the
# pulls API never lags. Source 2, backstop: the repos.txt search poll (the
# search index lags — it only ADDS candidates the sweep may have missed,
# e.g. after an org-enumeration failure). Merged and deduplicated by
# repo#number BEFORE acting, oldest first. GitHub drops me from
# requested_reviewers the moment I submit, so the set is self-clearing:
# anything in it is work I owe.
SWEEP_REPOS_EXTRA="dan-claude-bot/incubator claude-bot-andresmgsl/incubator"
candidates=""
org_repos=$(gh api /orgs/heavy-duty/repos --paginate --jq '.[].full_name' || echo err)
if [ "$org_repos" = "err" ]; then
  log "WARN: review: org repo enumeration failed this tick; the repos.txt backstop still collects"
  org_repos=""
fi
my_pr_repos=""
for SR in $org_repos $SWEEP_REPOS_EXTRA; do
  # One pulls page per repo, consumed twice: review candidates (requested
  # on me) AND author-side duty repos (open PRs authored by me) — the
  # second read costs no extra API call.
  page=$(gh api "repos/$SR/pulls?state=open&per_page=100" 2>/dev/null) || continue
  candidates="$candidates
$(printf '%s' "$page" | jq -r ".[] | select(.draft | not) | select([.requested_reviewers[].login] | index(\"$ME\")) | \"\(.created_at) $SR \(.number)\"" 2>/dev/null)"
  if printf '%s' "$page" | jq -e "[.[] | select(.user.login == \"$ME\")] | length > 0" >/dev/null 2>&1; then
    my_pr_repos="$my_pr_repos $SR"
  fi
done
while IFS= read -r BR; do
  [ -z "$BR" ] && continue
  candidates="$candidates
$(gh pr list -R "$BR" --state open --search "review-requested:$ME" \
    --json number,createdAt,isDraft \
    --jq '.[] | select(.isDraft | not) | "\(.createdAt) '"$BR"' \(.number)"' 2>/dev/null)"
done < "$REPOS_FILE"
# One candidate per (repo, PR) — first mention wins (sweep precedes the
# backstop in the input), then oldest-first for the acting order.
candidates=$(printf '%s\n' "$candidates" | awk 'NF==3 && !seen[$2"#"$3]++' | sort)
if [ -z "$candidates" ]; then
  log "review: no outstanding review requests anywhere"
else
  while read -r _created SR N; do
    [ -z "${N:-}" ] && continue
    s_owner="${SR%%/*}"; s_name="${SR##*/}"; s_slug="${SR//\//__}"
    # Per-PR dedup: my own latest review's SHA vs the live head — never
    # the search index.
    pair=$(gh api graphql \
      -f query='query($owner:String!,$name:String!,$num:Int!,$me:String!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid reviews(author:$me,last:1){nodes{commit{oid}}} } } }' \
      -f owner="$s_owner" -f name="$s_name" -F num="$N" -f me="$ME" \
      --jq '.data.repository.pullRequest | "\(.headRefOid) \(.reviews.nodes[0].commit.oid // "none")"' \
      || echo err err)
    s_head="${pair%% *}"; s_mine="${pair##* }"
    if [ "$s_head" != "err" ] && [ "$s_mine" = "$s_head" ]; then
      log "review: $SR#$N: my latest review already covers head ${s_head:0:12}; skipping (request mid-clear or stale search)"
      continue
    fi
    log "review: $SR#$N requests my verdict — launching review session"
    dir="$WORK_DIR/$s_slug-review"
    ensure_checkout "$SR" "$dir"
    run_session "$dir" review "You are the reviewer $ME in $SR; PR #$N lists you as a requested reviewer — the request IS your authorisation, whatever the repo. Read AGENTS.md (or .ceremony/AGENTS.md) at the repo root if present and follow where it routes you; REVIEWER.md governs the role. Determine the current head SHA first; if your latest review already covers it, exit without announcing or submitting anything. Otherwise ANNOUNCE FIRST, idempotently: run $DUTY_DIR/bin/announce-review.sh $SR $N <head-sha> — it posts the 🔎 comment only if you have never announced that exact (PR, head); if it reports already-announced, post nothing yourself, and if a double already exists leave it — never a third, and no comment about it. Then do the work, then submit the verdict: approve or request changes, never a bare comment. Review checkout discipline: fetch the PR head (git fetch origin pull/$N/head), check it out DETACHED in a throwaway worktree (git worktree add --detach <path> <head-sha>), review there, and remove the worktree after the verdict — never review on a named branch checkout in this clone. $ONESHOT_RULES"
  done <<< "$candidates"
fi


# --- ATTENTION duty: an issue assigned to me carrying the `attention`
# label is a demand parked for me — the writer (triage, the human, a
# sibling agent) decides a thread needs my hands, applies the label, and
# exactly one wake fires (operator design 2026-07-23, replacing the
# notification-mention wake: mentions re-arm on every comment, so chatty
# threads would burn a claude session per tick on nothing actionable;
# labels are this org's shared state machine and fire once per demand).
# One API call, no search index: the authenticated-user issues endpoint.
# The session's FIRST act is the ack: post the pickup comment, remove the
# label — that removal re-arms the wake — then do the demand whole. A
# session that dies before removing the label is relaunched next boundary.
attn_rows=$(gh api "/issues?filter=assigned&state=open&labels=attention&per_page=100" \
  --jq '.[] | "\(.repository.full_name) \(.number)"' 2>/dev/null) \
  || { attn_rows=""; log "WARN: attention fetch failed this tick"; }
if [ -z "$attn_rows" ]; then
  log "attention: none"
else
  while read -r a_repo a_num; do
    [ -z "${a_num:-}" ] && continue
    a_slug="${a_repo//\//__}"; a_name="${a_repo##*/}"
    log "attention: $a_repo#$a_num — launching pickup session"
    dir="$WORK_DIR/$a_slug"
    ensure_main_clone "$a_repo" "$dir" "https://github.com/$ME/$a_name.git"
    run_session "$dir" attention "You are $ME. Issue $a_repo#$a_num is assigned to you and carries the attention label: a demand was parked there for you. FIRST, the ack — post one short comment ('📌 picked up') unless an unanswered 📌 of yours already sits at the bottom of the thread, then REMOVE the attention label (gh api -X DELETE repos/$a_repo/issues/$a_num/labels/attention) — the removal re-arms the wake for future demands. THEN read the full thread plus whatever it links, work out what is being demanded of you, and do it whole per your role (BUILDER.md for your claims, REVIEWER.md for verdicts; AGENTS.md routes). An authorization or ruling that unblocks an acceptance criterion on your claimed issue IS build work: do it now per the rules below. $(wt_rules_for "$a_slug" "$a_name") $ROUND_RULES $ONESHOT_RULES"
  done <<< "$attn_rows"
fi

# Mentions stay visible but never spawn sessions: one evidence line per
# tick. A mention that needs my hands becomes an `attention` label —
# that is the contract.
m_count=$(gh api "/notifications?all=false&per_page=50" \
  --jq '[.[] | select(.unread) | select(.reason == "mention")] | length' 2>/dev/null || echo "?")
log "mentions backlog (informational, no wake): $m_count unread"
# --- Author-side duty repos: repos.txt PLUS every repo where I author an
# open PR (read off the sweep's own pulls pages). The review sweep went
# org-wide but resume/build/handoff/rebase stayed repos.txt-scoped, so
# cast#143's converged round sat unowed for 40 minutes with every tick
# looking only at ceremony (operator catch, 2026-07-23). Claims are minted
# only in ceremony, so orphan-resume detection stays covered by repos.txt.
duty_repos=$({ cat "$REPOS_FILE"; printf '%s\n' $my_pr_repos; } | awk 'NF && !seen[$0]++')

while IFS= read -r R; do
  [ -z "$R" ] && continue
  slug="${R//\//__}"
  owner="${R%%/*}"; name="${R##*/}"
  fork_url="https://github.com/$ME/$name.git"
  WT_RULES="$(wt_rules_for "$slug" "$name")"

  # --- RESUME duty: interrupted work of mine — checked FIRST, before every
  # other wake. Two shapes: an open DRAFT PR of mine (a one-shot session
  # died mid-build), or an issue claimed by me whose build/* branch exists
  # on my fork with no open PR (died between the first push and `gh pr
  # create`). I hold the duty lock, so nothing else can be running it. The
  # session resumes — never re-claims, never re-branches, never opens a
  # duplicate PR. ---
  draft_nums=$(gh pr list -R "$R" --state open --author "$ME" --draft \
    --json number --jq '.[].number' | tr '\n' ' ' || echo err)
  orphan_nums=""
  claimed_nums=$(gh issue list -R "$R" --state open --label claimed \
    --assignee "$ME" --json number --jq '.[].number' || echo err)
  open_heads=$(gh pr list -R "$R" --state open --author "$ME" \
    --json headRefName --jq '.[].headRefName' || echo err)
  if [ "$draft_nums" = "err" ] || [ "$claimed_nums" = "err" ] || [ "$open_heads" = "err" ]; then
    log "WARN: $R resume detection failed (drafts=$draft_nums claimed=$claimed_nums); skipping"
    draft_nums=""
  else
    for N in $claimed_nums; do
      # A branch for issue N on my fork (build/N-<slug>), not behind any
      # open PR of mine → the claim is orphaned mid-build.
      branch=$(gh api "repos/$ME/$name/git/matching-refs/heads/build/$N-" \
        --jq '.[0].ref // "" | sub("^refs/heads/"; "")' 2>/dev/null || echo "")
      [ -z "$branch" ] && continue
      if ! printf '%s\n' "$open_heads" | grep -qx "$branch"; then
        orphan_nums="$orphan_nums $N"
      fi
    done
  fi
  if [ -n "${draft_nums// /}" ] || [ -n "${orphan_nums// /}" ]; then
    log "$R: resume duty (my open drafts: ${draft_nums:-none}; claimed issues with a branch but no PR:${orphan_nums:-" none"})"
    dir="$WORK_DIR/$slug"
    ensure_main_clone "$R" "$dir" "$fork_url"
    run_session "$dir" resume "You are the builder $ME in $R. Read AGENTS.md at the repo root; BUILDER.md governs. Interrupted work of yours was detected — you hold the duty lock, so nothing else can be running it. Do NOT re-claim, do NOT start a fresh branch, do NOT open a duplicate PR. My open draft PRs: ${draft_nums:-none}. My claimed issues with a build/* branch on my fork ($ME/$name) but no open PR:${orphan_nums:-" none"}. For each draft PR: post one comment — ⟲ resuming from <head-sha> (the branch head's SHA) — re-read the '## Worklog' section of the PR body, and continue from the last unchecked step, checking items off and pushing after each one, until the PR is ready-for-review per BUILDER.md. If the draft has no '## Worklog', reconstruct one from the issue's acceptance criteria and what the branch already contains, add it to the PR body, then continue. For each orphaned claimed issue: post ⟲ resuming from <head-sha> on the ISSUE (no PR exists yet), fetch the build/* branch from the fork, open the draft PR from it immediately (Closes #N, with a '## Worklog' checklist), and continue the same way. $WT_RULES $ROUND_RULES"
  else
    log "$R: no resume duty"
  fi

  # --- BUILD duty: ready issues, or my own PRs with changes requested.
  # Abandoned drafts and orphaned claims are NOT build duty — the resume
  # duty above owns them, checked first, precisely so a fresh build session
  # never races or duplicates interrupted work. ---
  ready_count=$(gh issue list -R "$R" --state open --label ready \
    --json number --jq 'length' || echo err)
  # CHANGES_REQUESTED is actionable only once the round is whole: rounds
  # are answered whole (BUILDER.md), so as long as any bench review request
  # is still outstanding on the PR, an early changes-request means keep
  # waiting, not start fixing. Computed from latestReviews, NOT
  # reviewDecision: reviewDecision exists only under branch protection and
  # stays "" here (the handoff block's ceremony#26 discovery — the same
  # quirk silently stalled PR #39's round on 2026-07-22). Drafts are
  # excluded: resume duty owns them.
  cr_count=$(gh pr list -R "$R" --state open --author "$ME" \
    --json isDraft,latestReviews,reviewRequests \
    --jq '[.[] | select(.isDraft | not)
      | select([.latestReviews[]? | select(.state == "CHANGES_REQUESTED")
                | .author.login | select(test("'"$BENCH_RE"'"))] | length > 0)
      | select(([.reviewRequests[]? | .login // empty
                 | select(test("'"$BENCH_RE"'"))] | length) == 0)] | length' || echo err)
  if [ "$ready_count" = "err" ] && [ "$cr_count" != "err" ]; then
    # Issue listing can fail where issues are disabled (forks); that must
    # not blind the PR-based round detection (seen on my incubator fork).
    log "WARN: $R ready-issue detection failed (issues disabled?); counting 0"
    ready_count=0
  fi
  if [ "$cr_count" = "err" ]; then
    log "WARN: $R build-duty detection failed (changes-requested=err); skipping"
  elif [ "$ready_count" -gt 0 ] || [ "$cr_count" -gt 0 ]; then
    log "$R: build duty (ready issues=$ready_count, my PRs with changes requested=$cr_count)"
    dir="$WORK_DIR/$slug"
    ensure_main_clone "$R" "$dir" "$fork_url"
    run_session "$dir" build "You are the builder $ME in $R. Read AGENTS.md at the repo root, then act per BUILDER.md: first answer any round your open PRs owe — the whole round, one reply, re-request the non-approvers; otherwise pick ONE ready unclaimed issue (the roster in CONTRIBUTING points you at the release-flow and guards machinery), claim it, build it. Checkpoint discipline — the board and the branch are your only memory; assume this box can die at any moment, and anything uncommitted or not in the worklog is lost: open your PR as DRAFT as soon as the branch has its first commit, with a '## Worklog' section in the body listing your planned steps as checkboxes; check each item off and push every time you complete one. When the issue leaves you blocked or unsure, post the question as a comment on the issue and @-mention dan-claude-bot (triage owns the spec) — then keep working on what's unblocked, or wait, per BUILDER.md. Never guess your way past a spec gap. $WT_RULES $ROUND_RULES"
  else
    log "$R: no build duty"
  fi

  # --- HANDOFF duty: a converged round of mine that owes the human ---
  # reviewDecision==APPROVED exists only under branch protection and stays
  # "" here (observed on ceremony#26 with three approvals in), so
  # convergence is computed directly: every bench identity but me has a
  # latest opinionated review, it approves, and it approves the CURRENT
  # head. Guards: non-draft (drafts are invisible to the panel on purpose)
  # and state:needs-human not already set — danmt is non-bench, so without
  # that guard the wake would refire forever after a successful handoff.
  handoff_prs=""
  my_open=$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft --jq '.[] | select(.isDraft | not) | .number' || echo err)
  if [ "$my_open" = "err" ]; then
    log "WARN: $R handoff detection failed; skipping"
  else
    for N in $my_open; do
      converged=$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid mergeable
          labels(first:50){nodes{name}}
          reviewRequests(first:50){nodes{requestedReviewer{... on User{login}}}}
          latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
        } } }' -f owner="$owner" -f name="$name" -F num="$N" \
        | jq --argjson bench "$BENCH_JSON" --arg me "$ME" '
          .data.repository.pullRequest as $pr
          | ($bench - [$me]) as $panel
          | (($pr.reviewRequests.nodes | map(.requestedReviewer.login // empty)
              | map(select(. as $l | ($bench | index($l)) != null)) | length) == 0) as $no_bench_reqs
          | (($pr.labels.nodes | map(.name) | index("state:needs-human")) == null) as $not_handed
          | ($pr.latestOpinionatedReviews.nodes
             | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
                   | .author.login)) as $head_approvers
          | (($panel - $head_approvers) | length == 0) as $panel_approves
          | ($pr.mergeable == "MERGEABLE") as $merges
          | ($no_bench_reqs and $not_handed and $panel_approves and $merges)' \
        || echo err)
      case "$converged" in
        true)  handoff_prs="$handoff_prs $N" ;;
        false) : ;;
        *)     log "WARN: $R#$N handoff-state fetch failed; skipping" ;;
      esac
    done
    for N in $handoff_prs; do
      log "$R#$N: round converged — launching handoff session"
      dir="$WORK_DIR/$slug"
      ensure_main_clone "$R" "$dir" "$fork_url"
      run_session "$dir" handoff "You are the builder $ME in $R; PR #$N is yours. Your PR's round has converged. Per BUILDER.md's handoff: (1) post the closing round summary — what shipped, what each round changed, what was verified, any post-merge residue; (2) request danmt's review on the PR; (3) add the state:needs-human label. Then stop — the PR is the human's."
    done
    [ -z "$handoff_prs" ] && log "$R: no handoff duty"
  fi

  # --- REBASE duty: an open PR of mine that no longer merges ---
  # Only CONFLICTING fires. UNKNOWN is GitHub's post-merge recompute flap —
  # it shows for ~a minute after every merge on main, and treating it as a
  # conflict means rebasing on phantoms after each merge; the next poll
  # sees the recomputed value, so UNKNOWN just waits. Drafts are excluded:
  # a conflicting draft is the draft-resume build duty's problem, and
  # re-requesting a panel on a draft would be wrong (drafts are invisible
  # to the panel on purpose).
  conflict_prs=$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,mergeable,isDraft \
    --jq '.[] | select((.isDraft | not) and .mergeable == "CONFLICTING") | .number' || echo err)
  if [ "$conflict_prs" = "err" ]; then
    log "WARN: $R rebase detection failed; skipping"
  elif [ -n "$conflict_prs" ]; then
    for N in $conflict_prs; do
      log "$R#$N: conflicting — launching rebase session"
      dir="$WORK_DIR/$slug"
      ensure_main_clone "$R" "$dir" "$fork_url"
      run_session "$dir" rebase "You are the builder $ME in $R; PR #$N is yours and no longer merges. Rebase its branch onto the current main, resolve the conflicts, and push. Then post a one-line note on the PR saying you rebased, and re-request every panel reviewer — your push staled their approvals, and an approval is of a specific head. Do the rebase inside the PR's own worktree. $WT_RULES"
    done
  else
    log "$R: no rebase duty"
  fi

  # --- WORKTREE hygiene: a build/* worktree whose PR is merged or closed
  # (and no open PR remains on that head) is done — remove the worktree,
  # delete the local branch, prune. A branch with no PR at all is an
  # in-flight claim (resume duty's business), so it stays. A dirty worktree
  # is never force-removed: log and leave it for inspection. ---
  main_dir="$WORK_DIR/$slug"
  if [ -d "$main_dir/.git" ]; then
    git -C "$main_dir" worktree prune || true
    while read -r wt_branch wt_path; do
      [ -z "$wt_branch" ] && continue
      pr_states=$(gh pr list -R "$R" --author "$ME" --head "$wt_branch" \
        --state all --json state --jq '[.[].state] | join(" ")' || echo err)
      case "$pr_states" in
        err)    log "WARN: $R worktree-hygiene PR lookup failed for $wt_branch; leaving it" ;;
        ""|*OPEN*) : ;;
        *)
          log "$R: $wt_branch is done ($pr_states) — removing worktree $wt_path"
          if git -C "$main_dir" worktree remove "$wt_path"; then
            git -C "$main_dir" branch -D "$wt_branch" || true
          else
            log "WARN: worktree $wt_path not clean; leaving it for inspection"
          fi
          git -C "$main_dir" worktree prune || true
          ;;
      esac
    done < <(git -C "$main_dir" worktree list --porcelain \
      | awk '/^worktree /{p=$2} /^branch refs\/heads\/build\//{b=$2; sub("refs/heads/","",b); print b, p}')
  fi

done <<< "$duty_repos"

log "duty run end"
