#!/usr/bin/env bash
# CREW: duty poller — every 5 min via cron (flock); collects review-request candidates and launches one grok reviewer session per repo that needs a verdict.
# duty poller — wakes a reviewer session only when a verdict is requested.
# Decides nothing: collects candidates from every source, merges into ONE
# set keyed by (repo, PR number), drops those already reviewed at head,
# launches grok once per repo if work remains, or exits quiet.
#
# Candidate sources (merged, not sequential passes):
#   1. API request check — any open PR in the heavy-duty org (plus known bot
#      forks) that lists ME in requested_reviewers. A review request IS
#      authorisation; the repo need not be on the poll list. Enumerated from
#      the pulls API, never gh search (search index lags).
#   2. repos.txt poll — ceremony backstop via search. Same candidate set as
#      (1); a PR matched by both is handled once per tick.
set -euo pipefail

# cron's PATH is minimal (/usr/bin:/bin). Put our tools first.
export PATH="/usr/local/bin:/home/grok/.grok/bin:/usr/bin:/bin${PATH:+:$PATH}"

DUTY_DIR="${HOME}/duty"
REPOS_FILE="${DUTY_DIR}/repos.txt"
ME="grok-bot-andresmgsl"

# Extra forks outside the org that still request us.
EXTRA_REPOS=(
  dan-claude-bot/incubator
  claude-bot-andresmgsl/incubator
)

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

# True (exit 0) if ME already has APPROVED or CHANGES_REQUESTED at current head.
# Uses pulls/reviews endpoint (does not lag) — never search.
already_reviewed_at_head() {
  local repo="$1" num="$2"
  local head_oid n
  head_oid="$(gh api "repos/${repo}/pulls/${num}" --jq .head.sha 2>/dev/null)" || return 1
  [[ -n "${head_oid}" && "${head_oid}" != "null" ]] || return 1
  n="$(gh api "repos/${repo}/pulls/${num}/reviews" --paginate \
    --jq "[.[] | select(.user.login == \"${ME}\") | select(.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\") | select(.commit_id == \"${head_oid}\")] | length" 2>/dev/null)" \
    || return 1
  [[ "${n}" -gt 0 ]]
}

# Ensure a clone exists at $DUTY_DIR/<basename> for session cwd.
ensure_clone() {
  local repo="$1"
  local clone="${DUTY_DIR}/$(basename "${repo}")"
  if [[ -d "${clone}/.git" ]]; then
    git -C "${clone}" fetch --quiet origin 2>/dev/null || true
    git -C "${clone}" worktree prune 2>/dev/null || true
    return 0
  fi
  echo "$(ts) cloning ${repo} -> ${clone}"
  git clone --quiet "https://github.com/${repo}.git" "${clone}" 2>&1 \
    || { echo "$(ts) ERROR: clone failed for ${repo}" >&2; return 1; }
}

# Launch one reviewer session for repo R covering the given PR numbers.
launch_session() {
  local R="$1"
  shift
  local need=("$@")
  local clone repo_short
  repo_short="$(basename "${R}")"
  ensure_clone "${R}" || return 1
  clone="${DUTY_DIR}/${repo_short}"

  echo "$(ts) ${R}: ${#need[@]} need a verdict (${need[*]}) — launching session"

  # Non-interactive one-shot; full-auto is appropriate inside this box.
  # Session reads AGENTS.md and follows REVIEWER.md; every review ends in a verdict.
  # Tick-level de-dupe above cannot see a second submit inside the same session —
  # verdict posts MUST go through submit-verdict.sh; announces through
  # announce-reviewing.sh (mechanical one-shot each).
  # Checkout PR heads only in throwaway detached worktrees under ~/duty/trees.
  grok -p "You are the reviewer ${ME} in ${R}. Read AGENTS.md at the repo root and follow where it routes you. Review every open PR where your verdict is requested, per REVIEWER.md. For each candidate PR, check head vs your own reviews first (GET repos/${R}/pulls/N/reviews — not search): if you already have APPROVED or CHANGES_REQUESTED at the current head SHA, skip that PR.

ANNOUNCE IS ONE-SHOT (same discipline as verdicts):
- Before any work, announce via ONLY:
  ${DUTY_DIR}/announce-reviewing.sh ${R} <N> <full-head-sha>
  That script checks issues/<N>/comments for an exact ME body \`🔎 reviewing head <sha>\` and posts once or no-ops. NEVER call \`gh api .../comments\` or \`gh pr comment\` for the 🔎 marker yourself. If you already double-posted on a head: do NOT post a third; echo a line to ${DUTY_DIR}/duty.log and leave it.

VERDICT SUBMISSION IS ONE-SHOT (hard rule; supersedes tick-level dedup):
1. Compose the verdict body ONCE into a file. If you already composed a verdict for this head in this session, you are done — do not recompose, do not improve it.
2-6. NEVER call \`gh pr review\` directly. Submit only via:
   ${DUTY_DIR}/submit-verdict.sh ${R} <N> <approve|request-changes> <body-file>
   That script re-checks GET /repos/.../pulls/N/reviews immediately before submit, submits once, re-verifies via the same endpoint (trust it — search lags, this endpoint does not), and refuses a second submit. If verify shows your review, STOP even if gh looked ambiguous. If submit fails and verify shows nothing, it retries once with the IDENTICAL body — never regenerate. Exit 2 means already reviewed at head; treat as done.
If you discover you already double-posted a verdict on a head: do NOT post a third comment about it; echo a line to ${DUTY_DIR}/duty.log and leave it.

When a review requires checking out a PR head (tests, linters), use a detached throwaway worktree — never checkout in the main clone: git worktree add --detach ~/duty/trees/${repo_short}/review-<PR> <head-sha> ; run everything there; after the verdict: git worktree remove ~/duty/trees/${repo_short}/review-<PR> . Main clone stays on the default branch, always clean. PRs that need work this tick: ${need[*]}." \
    --permission-mode bypassPermissions \
    --always-approve \
    --cwd "${clone}" \
    || echo "$(ts) ${R}: session exited non-zero ($?)"
}

# --- argv / dependency gates ---

if [[ ! -f "${REPOS_FILE}" ]]; then
  echo "$(ts) ERROR: missing ${REPOS_FILE}" >&2
  exit 1
fi

if ! command -v grok >/dev/null 2>&1; then
  echo "$(ts) ERROR: grok not on PATH (${PATH})" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "$(ts) ERROR: gh not on PATH (${PATH})" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "$(ts) ERROR: jq not on PATH (${PATH})" >&2
  exit 1
fi

echo "$(ts) duty: start (grok=$(command -v grok) gh=$(command -v gh))"

# Once-per-boot sanity gate (inside flock). Marker written only when gh auth
# works, so dead credentials re-check every tick instead of silently skipping.
boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [ "$(cat "$HOME/duty/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
  { echo "== boot check $(date -Is) =="
    gh auth status || true
    df -h / | tail -1
    test -s "$HOME/.grok/auth.json" && echo "grok: credentials present" || echo "grok: no credentials" || true
  } >> "$HOME/duty/boot-check.log" 2>&1
  if gh auth status >/dev/null 2>&1; then
    echo "$boot_id" > "$HOME/duty/.boot-id"
  fi
fi

# --- ATTENTION duty (role-independent, ahead of the review queue) ---
# An open issue assigned to me carrying the `attention` label is a demand
# parked for me: triage, the operator, or a sibling agent decided a thread
# needs my hands and set it. Exactly one wake per demand; the pickup session
# acks by REMOVING the label (that re-arms the wake), then does the demanded
# work per role. Runs before the candidate sweep so it fires even when no
# verdict is owed (the sweep exits quiet below). A session that dies before
# acking is relaunched next tick — idempotent, the flag is still up.
# (ceremony#83; the wake is spec'd in FLEET.md. An @-mention is an FYI that
# demands nothing; only `attention` wakes a session.)
attn_rows="$(gh api "/issues?filter=assigned&state=open&labels=attention&per_page=100" \
  --jq '.[] | "\(.repository.full_name) \(.number)"' 2>/dev/null)" \
  || { attn_rows=""; echo "$(ts) WARN: attention fetch failed this tick"; }
if [[ -z "${attn_rows}" ]]; then
  echo "$(ts) attention: none"
else
  while read -r a_repo a_num; do
    [[ -n "${a_num:-}" ]] || continue
    echo "$(ts) attention: ${a_repo}#${a_num} — launching pickup session"
    ensure_clone "${a_repo}" || continue
    a_clone="${DUTY_DIR}/$(basename "${a_repo}")"
    grok -p "You are ${ME}. Issue ${a_repo}#${a_num} is assigned to you and carries the attention label: a demand was parked there for you. FIRST, the ack — post one short comment (📌 picked up) unless an unanswered 📌 of yours already sits at the bottom of the thread, then REMOVE the label: gh api -X DELETE repos/${a_repo}/issues/${a_num}/labels/attention — the removal re-arms the wake for the next demand. THEN read the full thread plus whatever it links, work out what is being demanded of you, and do it whole per your role. Read AGENTS.md at the repo root and follow where it routes you (REVIEWER.md for a verdict, BUILDER.md for a claim). An authorization or ruling that unblocks an acceptance criterion on an issue you have claimed IS build work: do it now. Touch the label only to remove it as your ack; set nothing, and never spawn work off a bare @-mention." \
      --permission-mode bypassPermissions \
      --always-approve \
      --cwd "${a_clone}" \
      || echo "$(ts) attention: ${a_repo}#${a_num} pickup exited non-zero ($?)"
  done <<< "${attn_rows}"
fi

# =====================================================================
# ONE candidate set: merge API request-check + repos.txt search, then
# dedupe by (repo, PR number) before any launch.
# Rows: "repo\tnumber\tcreated_at\tsource"
# =====================================================================
declare -A CAND_CREATED=()  # "owner/repo#num" -> created_at (earliest wins)
declare -A CAND_SOURCES=()  # "owner/repo#num" -> "api+search" etc.

add_candidate() {
  local repo="$1" num="$2" created="${3:-}" source="$4"
  local key="${repo}#${num}"
  if [[ -n "${CAND_CREATED[${key}]+x}" ]]; then
    CAND_SOURCES["${key}"]="${CAND_SOURCES[${key}]}+${source}"
    # Keep the earliest created_at we have seen.
    if [[ -n "${created}" && -n "${CAND_CREATED[${key}]}" && "${created}" < "${CAND_CREATED[${key}]}" ]]; then
      CAND_CREATED["${key}"]="${created}"
    fi
    return 0
  fi
  CAND_CREATED["${key}"]="${created:-9999-99-99T99:99:99Z}"
  CAND_SOURCES["${key}"]="${source}"
}

echo "$(ts) duty: collect candidates (API request-check ∪ repos.txt search)"

# --- source 1: API requested_reviewers across org + bot forks ---
mapfile -t sweep_repos < <(
  {
    gh api /orgs/heavy-duty/repos --paginate --jq '.[].full_name' 2>/dev/null || true
    printf '%s\n' "${EXTRA_REPOS[@]}"
  } | awk 'NF && !seen[$0]++'
)

api_count=0
for R in "${sweep_repos[@]}"; do
  while IFS=$'\t' read -r num created; do
    [[ -n "${num}" ]] || continue
    add_candidate "${R}" "${num}" "${created}" "api"
    api_count=$((api_count + 1))
  done < <(
    gh api "repos/${R}/pulls?state=open&per_page=100" --paginate \
      --jq ".[] | select([.requested_reviewers[].login] | index(\"${ME}\")) | \"\\(.number)\\t\\(.created_at)\"" \
      2>/dev/null || true
  )
done
echo "$(ts) duty: API request-check raw hits=${api_count} (pre-merge)"

# --- source 2: repos.txt search backstop ---
search_count=0
while IFS= read -r R || [[ -n "${R}" ]]; do
  [[ -z "${R}" || "${R}" =~ ^[[:space:]]*# ]] && continue
  R="${R//[[:space:]]/}"

  clone="${DUTY_DIR}/$(basename "${R}")"
  if [[ -d "${clone}/.git" ]]; then
    git -C "${clone}" worktree prune 2>/dev/null || true
  fi

  while IFS= read -r num; do
    [[ -n "${num}" ]] || continue
    # Search list has no created_at cheaply; leave blank so API's wins if both.
    add_candidate "${R}" "${num}" "" "search"
    search_count=$((search_count + 1))
  done < <(
    gh pr list \
      --repo "${R}" \
      --search "review-requested:${ME}" \
      --state open \
      --limit 100 \
      --json number \
      --jq '.[].number' 2>/dev/null || true
  )
done < "${REPOS_FILE}"
echo "$(ts) duty: repos.txt search raw hits=${search_count} (pre-merge)"

# --- merge: unique keys, oldest first ---
mapfile -t cand_keys < <(
  for key in "${!CAND_CREATED[@]}"; do
    printf '%s\t%s\n' "${CAND_CREATED[${key}]}" "${key}"
  done | sort -t$'\t' -k1,1 | cut -f2-
)

if [[ ${#cand_keys[@]} -eq 0 ]]; then
  echo "$(ts) duty: 0 unique candidates — quiet"
  echo "$(ts) duty: done"
  exit 0
fi

echo "$(ts) duty: ${#cand_keys[@]} unique candidate(s) after merge"

# Filter already-reviewed-at-head; group remaining by repo (oldest first).
declare -A NEED=()        # repo -> space-separated pr numbers
declare -a REPO_ORDER=()  # first-seen repo order (follows oldest-first keys)

for key in "${cand_keys[@]}"; do
  R="${key%%#*}"
  num="${key#*#}"
  src="${CAND_SOURCES[${key}]}"
  if already_reviewed_at_head "${R}" "${num}"; then
    echo "$(ts) ${key}: latest ${ME} review already on current head — skip (${src})"
    continue
  fi
  echo "$(ts) ${key}: needs verdict (${src})"
  if [[ -z "${NEED[${R}]+x}" ]]; then
    REPO_ORDER+=("${R}")
    NEED["${R}"]="${num}"
  else
    NEED["${R}"]="${NEED[${R}]} ${num}"
  fi
done

if [[ ${#REPO_ORDER[@]} -eq 0 ]]; then
  echo "$(ts) duty: all candidates already reviewed at head — quiet"
  echo "$(ts) duty: done"
  exit 0
fi

# One launch per repo, covering its full need-list once this tick.
for R in "${REPO_ORDER[@]}"; do
  # shellcheck disable=SC2206
  need=( ${NEED[${R}]} )
  [[ ${#need[@]} -gt 0 ]] || continue
  launch_session "${R}" "${need[@]}"
done

echo "$(ts) duty: done"
