#!/usr/bin/env bash
# Live duty poller: every five minutes it resumes builds, reviews requested PRs, and advances owned work.
set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin"

duty_dir="$HOME/duty"
repos_file="$duty_dir/repos.txt"
log_file="$duty_dir/duty.log"
projects_dir="$HOME/projects"
trees_dir="$duty_dir/trees"
identity="codex-bot-andresmgsl"

exec 9>"$duty_dir/.lock"
flock -n 9 || exit 0

boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [ "$(cat "$HOME/duty/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
  {
    echo "== boot check $(date -Is) =="
    gh auth status
    codex login status
    df -h / | tail -1
    while IFS= read -r repo || [[ -n "$repo" ]]; do
      [[ -d "$projects_dir/${repo##*/}/.git" ]] || continue
      git -C "$projects_dir/${repo##*/}" worktree prune
    done < "$repos_file"
  } >> "$HOME/duty/boot-check.log" 2>&1
  if gh auth status >/dev/null 2>&1; then
    echo "$boot_id" > "$HOME/duty/.boot-id"
  fi
fi

exec >>"$log_file" 2>&1

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

worktree_for_branch() { # $1 main clone, $2 branch
  git -C "$1" worktree list --porcelain | awk -v branch="refs/heads/$2" '
    $1 == "worktree" { path = $2 }
    $1 == "branch" && $2 == branch { print path; exit }
  '
}

attach_worktree() { # $1 repo, $2 main clone, $3 branch
  local repo="$1" main="$2" branch="$3" path
  path="$(worktree_for_branch "$main" "$branch")"
  if [[ -n "$path" ]]; then
    printf '%s\n' "$path"
    return
  fi
  path="$trees_dir/${repo##*/}/${branch//\//-}"
  mkdir -p "${path%/*}"
  if ! git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$main" fetch fork "$branch:refs/heads/$branch"
  fi
  git -C "$main" worktree add "$path" "$branch" >&2
  printf '%s\n' "$path"
}

clean_completed_worktrees() { # $1 repo, $2 main clone
  local repo="$1" main="$2" path branch pr_state
  while IFS=$'\t' read -r path branch; do
    [[ "$branch" == build/* ]] || continue
    pr_state="$(gh api "repos/$repo/pulls?state=all&head=$identity:$branch&per_page=1" \
      --jq '.[0].state // ""')"
    [[ "$pr_state" == closed ]] || continue
    if git -C "$main" worktree remove "$path"; then
      git -C "$main" branch -D "$branch"
      echo "$(timestamp) removed completed worktree $path ($branch)"
    else
      echo "$(timestamp) ERROR: completed worktree $path is dirty or locked; refusing forced removal"
    fi
  done < <(git -C "$main" worktree list --porcelain | awk '
    $1 == "worktree" { path = $2 }
    $1 == "branch" { sub("refs/heads/", "", $2); print path "\t" $2 }
  ')
  git -C "$main" worktree prune
}

enumerate_review_queue() {
  local me="$1" repo request_time created_at
  while IFS= read -r repo; do
    while IFS=$'\t' read -r pr_number title head_sha created_at; do
      [[ -n "$pr_number" ]] || continue
      request_time="$(gh api --paginate "repos/$repo/issues/$pr_number/timeline?per_page=100" \
        --jq ".[] | select(.event == \"review_requested\" and .requested_reviewer.login == \"$me\") | .created_at" \
        2>/dev/null | tail -n1)"
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "${request_time:-$created_at}" "$repo" "$pr_number" "$head_sha" "$title"
    done < <(gh api "repos/$repo/pulls?state=open&per_page=100" \
      --jq ".[] | select([.requested_reviewers[].login] | index(\"$me\")) |
        [.number, .title, .head.sha, .created_at] | @tsv" 2>/dev/null || true)
  done < <(
    {
      gh api /orgs/heavy-duty/repos --paginate --jq '.[].full_name'
      for bot in dan-claude-bot claude-bot-andresmgsl codex-bot-andresmgsl \
          grok-bot-andresmgsl kimi-bot-andresmgsl; do
        gh api "/users/$bot/repos?per_page=100" --paginate \
          --jq '.[] | select(.fork) | .full_name'
      done
      sed '/^[[:space:]]*$/d' "$repos_file"
    } | sort -u
  )
}

run_review_queue() {
  local me="$1" requested_at repo pr_number head_sha title latest_own
  local review_git_dir review_parent review_tree codex_status
  while IFS=$'\t' read -r requested_at repo pr_number head_sha title; do
    [[ -n "$repo" ]] || continue
    latest_own="$(gh api --paginate "repos/$repo/pulls/$pr_number/reviews?per_page=100" \
      --jq ".[] | select(.user.login == \"$me\") | [.submitted_at, .commit_id] | @tsv" \
      | sort | tail -n1 | cut -f2)"
    if [[ "$latest_own" == "$head_sha" ]]; then
      echo "$(timestamp) REVIEW queue skipped for $repo#$pr_number (own verdict covers $head_sha)"
      continue
    fi

    review_git_dir="$duty_dir/review-clones/${repo//\//--}.git"
    review_parent="$duty_dir/review-trees/${repo//\//--}"
    mkdir -p "${review_git_dir%/*}" "$review_parent"
    if [[ ! -d "$review_git_dir" ]]; then
      git clone --bare "https://github.com/$repo.git" "$review_git_dir"
    fi
    git --git-dir="$review_git_dir" worktree prune
    git --git-dir="$review_git_dir" fetch origin "pull/$pr_number/head"
    review_tree="$(mktemp -d "$review_parent/pr-$pr_number-XXXXXX")"
    git --git-dir="$review_git_dir" worktree add --detach "$review_tree" FETCH_HEAD

    echo "$(timestamp) GLOBAL REVIEW duty detected for $repo#$pr_number, requested $requested_at: $title"
    codex_status=0
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$review_tree" \
      "You are reviewer $me for $repo PR #$pr_number at head $head_sha. The review request is your authorization even if this repository is not adopted. Read the repository's AGENTS.md and applicable reviewer instructions if present, then review this one PR from this detached throwaway worktree. Before analysis, NEVER post the 🔎 comment directly; invoke $duty_dir/announce-review.sh $repo $pr_number $head_sha exactly once. That gate checks and verifies the exact PR/head announcement through the issue-comments API and skips an existing announcement. Deduplicate verdicts against your own latest review SHA using GET repos/$repo/pulls/$pr_number/reviews, never search. Compose the verdict body exactly once in a file and never regenerate it. NEVER invoke gh pr review directly; submit once through $duty_dir/submit-review.sh $repo $pr_number $head_sha APPROVE\\|REQUEST_CHANGES BODY_FILE. The helper performs the immediate pre-submit and post-submit endpoint checks and identical-body retry rule. Every review ends in approve or request-changes, never a bare comment." \
      || codex_status=$?

    if ! git --git-dir="$review_git_dir" worktree remove "$review_tree"; then
      echo "$(timestamp) ERROR: review worktree $review_tree could not be removed cleanly"
    fi
    git --git-dir="$review_git_dir" worktree prune
    if (( codex_status != 0 )); then
      echo "$(timestamp) ERROR: reviewer session failed for $repo#$pr_number (status $codex_status)"
    fi
  done < <(
    enumerate_review_queue "$me" \
      | sort -t$'\t' -k2,2 -k3,3n -u \
      | sort -t$'\t' -k1,1
  )
}

# ATTENTION duty (role-independent, ahead of every per-role queue): an open
# issue assigned to me carrying the `attention` label is a demand parked for
# me — triage, the operator, or a sibling agent decided a thread needs my
# hands and set it. Exactly one wake per demand; the pickup session acks by
# REMOVING the label (that re-arms the wake), then does the demanded work per
# role. It is cross-repo (assigned to me anywhere), so it runs once here, not
# inside the repos.txt loop. A session that dies before acking is relaunched
# next tick — idempotent, the flag is still up. (ceremony#83; FLEET.md wake.
# An @-mention is an FYI that demands nothing; only `attention` wakes work.)
run_attention_queue() {
  local me="$1" a_repo a_num a_dir attn_rows
  attn_rows="$(gh api "/issues?filter=assigned&state=open&labels=attention&per_page=100" \
    --jq '.[] | "\(.repository.full_name) \(.number)"' 2>/dev/null)" \
    || { echo "$(timestamp) WARN: attention fetch failed this tick"; return 0; }
  if [[ -z "$attn_rows" ]]; then
    echo "$(timestamp) attention: none"
    return 0
  fi
  while read -r a_repo a_num; do
    [[ -n "$a_num" ]] || continue
    a_dir="$projects_dir/${a_repo##*/}"
    if [[ ! -d "$a_dir/.git" ]]; then
      echo "$(timestamp) cloning $a_repo into $a_dir"
      gh repo clone "$a_repo" "$a_dir"
    fi
    echo "$(timestamp) ATTENTION duty detected for $a_repo#$a_num — launching pickup session"
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$a_dir" \
      "You are $me and issue $a_repo#$a_num is assigned to you carrying the attention label: a demand was parked there for you. FIRST, the ack — post one short comment (📌 picked up) on the issue unless an unanswered 📌 of yours already sits at the bottom of the thread, then REMOVE the label with: gh api -X DELETE repos/$a_repo/issues/$a_num/labels/attention. The removal re-arms the wake for the next demand. THEN read the full thread and everything it links, work out what is being demanded of you, and do it whole per your role. Read AGENTS.md at the repo root and follow where it routes you: BUILDER.md for your claims (build in a worktree, never in this main clone), REVIEWER.md for verdicts. An authorization or ruling that unblocks an acceptance criterion on an issue you have claimed IS build work: do it now. Touch the label only to remove it as your ack; set nothing, and never spawn work off a bare @-mention." \
      || echo "$(timestamp) ERROR: attention session failed for $a_repo#$a_num (status $?)"
  done <<< "$attn_rows"
}

echo "$(timestamp) duty poll started"

for command_name in gh codex; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$(timestamp) ERROR: $command_name is unavailable on PATH=$PATH"
    exit 1
  fi
done

ME="$(gh api user --jq .login)"
run_attention_queue "$ME"
run_review_queue "$ME"

while IFS= read -r repo || [[ -n "$repo" ]]; do
  [[ -n "$repo" ]] || continue

  repo_dir="$projects_dir/${repo##*/}"
  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "$(timestamp) cloning $repo into $repo_dir"
    gh repo clone "$repo" "$repo_dir"
  fi
  if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
    echo "$(timestamp) ERROR: main clone $repo_dir is dirty; refusing duty work"
    continue
  fi
  default_branch="$(git -C "$repo_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  default_branch="${default_branch#origin/}"
  default_branch="${default_branch:-main}"
  git -C "$repo_dir" switch "$default_branch" >/dev/null
  git -C "$repo_dir" fetch origin
  if ! git -C "$repo_dir" remote get-url fork >/dev/null 2>&1; then
    git -C "$repo_dir" remote add fork "https://github.com/$identity/${repo##*/}.git"
  fi
  git -C "$repo_dir" fetch fork
  clean_completed_worktrees "$repo" "$repo_dir"

  mapfile -t draft_resumes < <(gh pr list --repo "$repo" --state open \
    --author "$identity" --draft --json number,headRefName,headRefOid \
    --jq '.[] | [.number, .headRefName, .headRefOid] | @tsv')
  issue_resume=""
  if (( ${#draft_resumes[@]} == 0 )); then
    mapfile -t claimed_issues < <(gh issue list --repo "$repo" --state open \
      --assignee "$identity" --label claimed --json number --jq '.[].number')
    mapfile -t build_refs < <(gh api --paginate \
      "repos/$identity/${repo##*/}/git/matching-refs/heads/build/" \
      --jq '.[] | [.ref, .object.sha] | @tsv' 2>/dev/null || true)
    for issue_number in "${claimed_issues[@]}"; do
      for build_ref in "${build_refs[@]}"; do
        IFS=$'\t' read -r ref_name head_sha <<<"$build_ref"
        branch_name="${ref_name#refs/heads/}"
        [[ "$branch_name" == "build/$issue_number-"* ]] || continue
        open_pr_count="$(gh api "repos/$repo/pulls?state=open&head=$identity:$branch_name" --jq 'length')"
        if (( open_pr_count == 0 )); then
          issue_resume="$issue_number"$'\t'"$branch_name"$'\t'"$head_sha"
          break 2
        fi
      done
    done
  fi
  if (( ${#draft_resumes[@]} > 0 )); then
    IFS=$'\t' read -r resume_pr resume_branch resume_sha <<<"${draft_resumes[0]}"
    resume_tree="$(attach_worktree "$repo" "$repo_dir" "$resume_branch")"
    echo "$(timestamp) RESUME duty detected for $repo PR #$resume_pr at $resume_sha in $resume_tree"
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$resume_tree" \
      "You are resuming interrupted builder work as $identity in $repo. This is the existing worktree for draft PR #$resume_pr, branch $resume_branch at head $resume_sha. Read AGENTS.md and follow BUILDER.md. Do not re-claim, create a branch or worktree, open another PR, or build in the main clone. First post exactly: ⟲ resuming from $resume_sha. Then re-read the draft PR body's ## Worklog and continue from its last unchecked step. All edits, commits, tests, and rebases happen in this worktree. Check off each completed item and push every checkpoint; assume uncommitted work and anything absent from the worklog will be lost."
    continue
  elif [[ -n "$issue_resume" ]]; then
    IFS=$'\t' read -r resume_issue resume_branch resume_sha <<<"$issue_resume"
    resume_tree="$(attach_worktree "$repo" "$repo_dir" "$resume_branch")"
    echo "$(timestamp) RESUME duty detected for $repo issue #$resume_issue on $resume_branch at $resume_sha in $resume_tree"
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$resume_tree" \
      "You are resuming interrupted builder work as $identity in $repo. This is the existing worktree for claimed issue #$resume_issue, branch $resume_branch at head $resume_sha, with no open PR. Read AGENTS.md and follow BUILDER.md. Do not re-claim, create a fresh branch or worktree, open a duplicate PR, or build in the main clone. First post exactly on issue #$resume_issue: ⟲ resuming from $resume_sha. Continue inside this worktree. Open the branch's one draft PR with a ## Worklog checkbox plan. All edits, commits, tests, and rebases happen here. Check off each completed item and push every checkpoint; assume uncommitted work and anything absent from the worklog will be lost."
    continue
  fi

  ready_count="$(gh issue list --repo "$repo" --state open --label ready \
    --json number --jq 'length')"
  changes_requested_count="$(gh pr list --repo "$repo" --state open \
    --author "$identity" --json reviewDecision,reviewRequests \
    --jq '[.[] | select(
      .reviewDecision == "CHANGES_REQUESTED" and
      ([.reviewRequests[] | select(.login == "claude-bot-andresmgsl" or .login == "codex-bot-andresmgsl" or .login == "grok-bot-andresmgsl" or .login == "kimi-bot-andresmgsl")] | length) == 0
    )] | length')"
  if (( ready_count > 0 || changes_requested_count > 0 )); then
    echo "$(timestamp) BUILD duty detected for $repo ($ready_count ready issue(s), $changes_requested_count changes-requested PR(s))"
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$repo_dir" \
      "You are the builder $identity in $repo. This directory is the clean main clone; fetch and inspect here but never build here. Read AGENTS.md, then act per BUILDER.md. The review bench is claude-bot-andresmgsl, codex-bot-andresmgsl, grok-bot-andresmgsl, and kimi-bot-andresmgsl, minus the PR author; dan-claude-bot is triage-only and is never a reviewer. First answer any round your open PRs owe, but only when no bench review requests remain outstanding — an early changes-request means keep waiting for every panel verdict on the current head. The instant you pick up a completed round, before touching code post one PR comment beginning exactly: 🔧 addressing round on head <sha>. In that same comment analyze every blocking and non-blocking point from every reviewer, label each agree, disagree, or needs-ruling, and state concretely how you will address it. This is the round plan of record. Add that round's fix steps as checkboxes under ## Worklog in the PR body. For any owned PR, find and reuse its worktree with git worktree list; if absent, attach the existing branch under $trees_dir/${repo##*/}. Never add a second worktree or build in this main clone. During a fix round, never allow more than 15 minutes of silence: push a WIP or completed commit at least every 15 minutes and never rewrite pushed history; if the tree is genuinely untouched while reading, thinking, or blocked, update the round worklog comment within 15 minutes with what you are doing and why there is no commit. Check off Worklog fixes and push as each completes, then answer the round whole and re-request every non-approver. Otherwise pick ONE ready unclaimed issue, claim it, slug it, then create branch and worktree in one step: git fetch origin; git worktree add $trees_dir/${repo##*/}/build-N-slug -b build/N-slug origin/$default_branch. If that reports already checked out, fix the holder; never fall back to the main clone. Perform every edit, commit, test, and rebase inside the PR worktree. As soon as the branch has its first commit, push it to fork and open the PR as a draft with a ## Worklog checkbox plan. Check off items and push each checkpoint. When blocked or unsure, comment on the issue and @-mention dan-claude-bot. Never guess past a spec gap."
  fi

  conflict_count="$(gh pr list --repo "$repo" --state open \
    --author "$identity" --json mergeable \
    --jq '[.[] | select(.mergeable == "CONFLICTING")] | length')"
  if (( conflict_count > 0 )); then
    echo "$(timestamp) REBASE duty detected for $repo ($conflict_count conflicting PR(s))"
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$repo_dir" \
      "You are the builder $identity in $repo. This is the clean main clone; never rebase or edit here. Read AGENTS.md and follow BUILDER.md. For each CONFLICTING PR, find and reuse its branch worktree with git worktree list, or attach the existing branch under $trees_dir/${repo##*/} if absent. Never create a second worktree; if git says already checked out, fix the holder. Rebase onto origin/$default_branch, resolve, test, and push only inside that worktree, then post a one-line note and re-request every panel reviewer — claude-bot-andresmgsl, codex-bot-andresmgsl, grok-bot-andresmgsl, and kimi-bot-andresmgsl, minus the author. Never request dan-claude-bot. Act only on CONFLICTING; ignore UNKNOWN."
  fi

  # shellcheck disable=SC2016 # $pr is a jq variable, not a shell expansion.
  handoff_count="$(gh pr list --repo "$repo" --state open \
    --author "$identity" --json headRefOid,isDraft,labels,mergeable,reviewDecision,reviewRequests,reviews \
    --jq '[.[] | . as $pr | select(
      (.isDraft | not) and
      (.reviewDecision == "APPROVED" or
        (["claude-bot-andresmgsl", "grok-bot-andresmgsl", "kimi-bot-andresmgsl"] | all(. as $reviewer |
          ([$pr.reviews[] | select(.author.login == $reviewer and .commit.oid == $pr.headRefOid)] | sort_by(.submittedAt) | last | .state) == "APPROVED"
        ))) and
      .mergeable != "CONFLICTING" and
      ([.reviewRequests[] | select(.login == "claude-bot-andresmgsl" or .login == "codex-bot-andresmgsl" or .login == "grok-bot-andresmgsl" or .login == "kimi-bot-andresmgsl")] | length) == 0 and
      ([.labels[].name | select(. == "state:needs-human")] | length) == 0
    )] | length')"
  if (( handoff_count > 0 )); then
    echo "$(timestamp) HANDOFF duty detected for $repo ($handoff_count converged PR(s))"
    codex exec --dangerously-bypass-approvals-and-sandbox --cd "$repo_dir" \
      "Your PR's round has converged. Per BUILDER.md's handoff: (1) post the closing round summary — what shipped, what each round changed, what was verified, any post-merge residue; (2) request danmt's review on the PR; (3) add the state:needs-human label. Then stop — the PR is the human's."
  fi
done <"$repos_file"

echo "$(timestamp) duty poll finished"
