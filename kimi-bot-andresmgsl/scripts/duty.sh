# duty.sh — the review duty loop: request-check sweep, dedup, review rounds. Fires every 5 min via system cron.

#!/usr/bin/env bash
set -euo pipefail

# Cron runs with a minimal PATH; kimi lives outside the usual directories.
export PATH="$HOME/.kimi-code/bin:$PATH"
if ! command -v kimi >/dev/null 2>&1; then
    echo "$(date -Iseconds) ERROR: kimi not found in PATH: $PATH" >&2
    exit 1
fi

DUTY_DIR="$HOME/duty"
REPOS_FILE="$DUTY_DIR/repos.txt"
REPOS_DIR="$DUTY_DIR/repos"
ME="$(gh api user --jq .login)"

# Once-per-boot sanity gate: first tick after a reboot logs auth/disk/CLI
# health. The marker is written only when gh auth works, so a box with dead
# credentials re-checks every tick instead of silently skipping duty.
boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [ "$(cat "$DUTY_DIR/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
    { echo "== boot check $(date -Is) =="
      gh auth status || true
      df -h / | tail -1
      kimi doctor || true
    } >> "$DUTY_DIR/boot-check.log" 2>&1
    if gh auth status >/dev/null 2>&1; then
        echo "$boot_id" > "$DUTY_DIR/.boot-id"
    fi
fi
# Drop stale worktree registrations left by crashed review rounds.
for d in "$REPOS_DIR"/*/*/; do
    [ -d "$d" ] || continue
    git -C "$d" worktree prune 2>/dev/null || true
done

mkdir -p "$REPOS_DIR"

# --- ATTENTION duty (role-independent, ahead of the review queue) ---
# An open issue assigned to me carrying the `attention` label is a demand
# parked for me: triage, the operator, or a sibling agent decided a thread
# needs my hands and set it. Exactly one wake per demand; the pickup session
# acks by REMOVING the label (that re-arms the wake), then does the demanded
# work per role. This runs BEFORE the review candidate set so it fires even
# on an empty review queue (which exits early below). A session that dies
# before acking is relaunched next tick — idempotent, the flag is still up.
# (ceremony#83; the wake is spec'd in FLEET.md. An @-mention is an FYI that
# demands nothing; only `attention` wakes a session.)
attn_rows=$(gh api "/issues?filter=assigned&state=open&labels=attention&per_page=100" \
  --jq '.[] | "\(.repository.full_name) \(.number)"' 2>/dev/null) \
  || { attn_rows=""; echo "$(date -Iseconds) WARN: attention fetch failed this tick"; }
if [ -z "$attn_rows" ]; then
  echo "$(date -Iseconds) attention: none"
else
  while read -r a_repo a_num; do
    [ -z "${a_num:-}" ] && continue
    echo "$(date -Iseconds) attention: $a_repo#$a_num — launching pickup session"
    a_checkout="$REPOS_DIR/$a_repo"
    if [[ ! -d "$a_checkout/.git" ]]; then
      mkdir -p "$(dirname "$a_checkout")"
      gh repo clone "$a_repo" "$a_checkout"
    else
      git -C "$a_checkout" fetch --quiet origin || true
    fi
    if ( cd "$a_checkout" && kimi -p "You are $ME. Issue $a_repo#$a_num is assigned to you and carries the attention label: a demand was parked there for you. FIRST, the ack — post one short comment (📌 picked up) unless an unanswered 📌 of yours already sits at the bottom of the thread, then REMOVE the label: gh api -X DELETE repos/$a_repo/issues/$a_num/labels/attention — the removal re-arms the wake for the next demand. THEN read the full thread plus whatever it links, work out what is being demanded of you, and do it whole per your role. Read AGENTS.md at the repo root and follow where it routes you (REVIEWER.md for a verdict, BUILDER.md for a claim). An authorization or ruling that unblocks an acceptance criterion on an issue you have claimed IS build work: do it now. Touch the label only to remove it as your ack; set nothing, and never spawn work off a bare @-mention."); then
      echo "$(date -Iseconds) attention: $a_repo#$a_num pickup returned"
    else
      echo "$(date -Iseconds) attention: $a_repo#$a_num pickup FAILED"
    fi
  done <<< "$attn_rows"
fi

# THE CANDIDATE SET — one set, two sources, deduped by (repo, PR).
#
# Source 1 (FIRST, authoritative): the request check. Any open PR anywhere in
# the heavy-duty org, or in a bot fork, that names me in requested_reviewers
# IS my authorisation — the repo does not need to be adopted, and no repo
# filter may gate this. Enumerated directly from the API — never gh search,
# whose index lags and has burned us before. GitHub drops me from
# requested_reviewers the moment I submit a review, so this list is
# self-clearing: a true outstanding queue, and anything on it is work owed.
CANDIDATES="$(mktemp)"
trap 'rm -f "$CANDIDATES"' EXIT

for R in $(gh api /orgs/heavy-duty/repos --paginate --jq '.[].full_name') \
         dan-claude-bot/incubator claude-bot-andresmgsl/incubator; do
    gh api "repos/$R/pulls?state=open&per_page=100" \
        --jq ".[] | select([.requested_reviewers[].login] | index(\"$ME\")) | \"\(.created_at) $R#\(.number) \(.head.sha)\"" \
        2>/dev/null || true
done > "$CANDIDATES"

# Source 2: the repo-list poll — a backstop for ceremony, not the definition
# of the job. Merge into the SAME set; a PR matched by both is handled once.
while IFS= read -r R || [[ -n "$R" ]]; do
    [[ -z "$R" || "$R" =~ ^# ]] && continue
    for N in $(gh pr list --repo "$R" --search "review-requested:$ME" --json number --limit 1000 --jq '.[].number' 2>/dev/null || true); do
        [ -n "$N" ] || continue
        grep -qF "$R#$N " "$CANDIDATES" && continue
        gh api "repos/$R/pulls/$N" --jq '"\(.created_at) '"$R#$N"' \(.head.sha)"' >> "$CANDIDATES" || true
    done
done < "$REPOS_FILE"

# Oldest first.
sort -o "$CANDIDATES" "$CANDIDATES"

# Verdict dedup, against my own latest review's SHA via the pulls/N/reviews
# endpoint (it does not lag; the search index does). Group survivors by repo.
declare -A REPO_PRS=()
while read -r _created key head _rest; do
    [ -n "${key:-}" ] || continue
    R="${key%#*}"; N="${key#*#}"
    latest="$(gh api "repos/$R/pulls/$N/reviews?per_page=100" \
        --jq "[.[] | select(.user.login==\"$ME\")] | sort_by(.submitted_at) | last | .commit_id // \"\"")"
    if [ "$latest" = "$head" ]; then
        # The re-request rule: a review-requested event NEWER than my latest
        # review at this unchanged head is answered with an auto-approve, not
        # silence — a re-request at the same tree means the stale verdict
        # must not sit as a blocker. (Self-clearing: after the approve, my
        # latest review is newer than the request, and GitHub drops me from
        # requested_reviewers on submit.)
        my_review_at="$(gh api "repos/$R/pulls/$N/reviews?per_page=100" \
            --jq "[.[] | select(.user.login==\"$ME\")] | sort_by(.submitted_at) | last | .submitted_at // \"\"")"
        req_at="$(gh api --paginate "repos/$R/issues/$N/timeline?per_page=100" \
            --jq "[.[] | select(.event==\"review_requested\" and .requested_reviewer.login==\"$ME\")] | sort_by(.created_at) | last | .created_at // \"\"" 2>/dev/null || true)"
        if [ -n "$req_at" ] && [ -n "$my_review_at" ] && [[ "$req_at" > "$my_review_at" ]]; then
            # Re-verify immediately before submitting — if the head moved
            # since the enumeration, this needs a real review, not an approve.
            head_now="$(gh api "repos/$R/pulls/$N" --jq .head.sha)"
            if [ "$head_now" = "$head" ]; then
                if gh pr review "$N" --repo "$R" --approve \
                    --body "Re-requested at unchanged head $head — my latest review already covers this tree; approving per the re-request rule."; then
                    echo "$(date -Iseconds) $key: auto-approved re-request at unchanged head $head"
                else
                    echo "$(date -Iseconds) $key: auto-approve FAILED at head $head — will retry next tick"
                fi
            else
                echo "$(date -Iseconds) $key: head moved to $head_now during dedup — queued for review"
                REPO_PRS[$R]="${REPO_PRS[$R]:-}$N "
            fi
        else
            echo "$(date -Iseconds) $key: latest review already covers head $head; skipping"
        fi
        continue
    fi
    REPO_PRS[$R]="${REPO_PRS[$R]:-}$N "
done < "$CANDIDATES"

if [ "${#REPO_PRS[@]}" -eq 0 ]; then
    echo "$(date -Iseconds) queue empty — nothing outstanding"
    exit 0
fi

for R in "${!REPO_PRS[@]}"; do
    prs="${REPO_PRS[$R]% }"
    echo "$(date -Iseconds) $R: outstanding: $prs"

    # Ensure a fresh checkout exists for the reviewer to work in.
    checkout="$REPOS_DIR/$R"
    if [[ ! -d "$checkout/.git" ]]; then
        echo "$(date -Iseconds) cloning $R into $checkout"
        mkdir -p "$(dirname "$checkout")"
        gh repo clone "$R" "$checkout"
    fi

    # Move into the checkout so AGENTS.md is at the repo root for the agent.
    cd "$checkout"
    git fetch --quiet origin
    default_branch=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's@^origin/@@')
    git checkout --quiet "${default_branch:-main}"
    git pull --quiet origin "${default_branch:-main}"

    prompt="You are the reviewer kimi-bot-andresmgsl in ${R}. Read AGENTS.md at the repo root and follow where it routes you. These open PRs request your review, oldest first: ${prs}. Review each per REVIEWER.md. Every review ends in a verdict — approve or request changes, never a bare comment. If your latest review already covers the current head, skip that PR. ANNOUNCE DEDUP: the round-opening comment (🔎 reviewing head <sha>) is posted at most once per (PR, head) — before posting it, check your own comments on the PR (gh api repos/${R}/issues/<N>/comments, filter user.login==kimi-bot-andresmgsl) and skip the announce if you already announced that exact head. Verdict submission is ONE-SHOT: compose the verdict body ONCE into a file, then submit ONLY via ~/duty/review-submit.sh ${R} <PR> approve|request-changes <body-file> — it re-checks the pulls/N/reviews endpoint immediately before and after submitting. If it says ALREADY-COVERED or LANDED, you are done — never submit a second time to make sure. If it says NOT-LANDED, retry once with the identical body file; never regenerate the body. If you discover you double-posted, note it in your reply and move on — do not post about it in the PR. When a review requires checking out a PR head (tests, linters), do it in a detached worktree — git worktree add --detach ~/duty/trees/${R##*/}/review-<PR> <head-sha> — run everything there, and after posting your verdict remove it with git worktree remove ~/duty/trees/${R##*/}/review-<PR>. Never check out PR heads in the main clone; it stays parked on the default branch, always clean."
    echo "$(date -Iseconds) invoking kimi for $R (PRs: $prs)"
    kimi -p "$prompt"
    echo "$(date -Iseconds) kimi returned for $R"
done

echo "$(date -Iseconds) duty loop complete"
