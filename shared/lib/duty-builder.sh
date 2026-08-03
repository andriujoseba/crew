# duty-builder.sh — builder wakes, in doctrine priority order (FLEET.md):
# resume → ci-red → build (ready issues / completed rounds) → handoff →
# rebase, plus worktree hygiene. ci-red precedes build because your own red
# head outranks a new claim (ceremony BUILDER.md); the block order in this
# file IS the tick order, and this header is what FLEET.md is reconciled
# against. All review predicates use latestOpinionatedReviews, NEVER
# latestReviews or reviewDecision: COMMENTED can mask a standing opinion in
# latestReviews, while reviewDecision exists only
# under branch protection and stays "" here — keying on it silently stalled
# rounds for a day (ceremony#26, #39).
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

BUILDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mutates the caller's dynamically scoped ready_count/ready_items. Withheld
# items must disappear from both the prompt and the eventual seen-ledger.
_gate_ready_for_open_pr() {
  if [ "$open_pr_count" -gt 0 ] && [ "$ready_count" -gt 0 ]; then
    log "$R: $open_pr_count open authored PR(s) occupy the build slot — not claiming a ready issue"
    ready_count=0
    ready_items=""
    return 0
  fi
  return 1
}

# _ready_lines_to_commit PRE_LINES POST_IDS — preserve the whole enumerated
# ready set only when the completed session declined every issue. If even one
# pre-session id is no longer pickable, the session acted on the set and none
# of the remaining (withheld) ready lines belongs in the ledger (#264).
_ready_lines_to_commit() {
  local pre_lines="$1" post_ids="$2" line id
  [ -n "${pre_lines//[[:space:]]/}" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%% *}"
    printf '%s\n' "$post_ids" | grep -qxF "$id" || return 0
  done <<<"$pre_lines"
  printf '%s\n' "$pre_lines"
}

# Existing boxes may already have pickable work buried by the old whole-set
# commit. Re-open every build signal once after upgrade; ready and round ids
# share a key shape, so the old file cannot be narrowed safely (#264 D5).
_repair_seen_build_264() {
  local marker="$DUTY_DIR/.seen-build.repair-264"
  [ -e "$marker" ] && return 0
  rm -f "$DUTY_DIR/.seen-build"
  find "$DUTY_DIR" -maxdepth 1 -type f -name '.suppressed-build.*' -delete 2>/dev/null || true
  : >"$marker"
  log "builder: repaired build ledgers for #264; cleared .seen-build and suppression state once"
}

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

# _mirror_rounds REPO NUM — mirror each whole-round reply into the PR body's
# `## Round log` (#91, ceremony#196 option B). The builder owes the reply and
# nothing else; the engine copies it into the body where the merging human
# looks. round-log.jq picks the author's comments after each round's newest
# verdict, keys each by `<!-- round:<head-sha> -->`, and returns the whole new
# body only when something is un-recorded — so an already-mirrored round makes
# a retry a no-op. Body writes go through REST: `gh pr edit --body-file` dies
# on crew's projects-classic GraphQL and writes nothing. This is best-effort
# and the handoff NEVER blocks on it (the same rule as the label write).
_mirror_rounds() {
  # FINAL (default false) is true only at the handoff straggler: it finalizes
  # the live last round too. Per-tick mirroring leaves the live round deferred
  # so a still-arriving round is never stamped "no written reply" (round-log.jq).
  local repo="$1" num="$2" final="${3:-false}" owner name payload newbody
  owner="${repo%%/*}"; name="${repo##*/}"
  # The assignment's status is tested outside the substitution: GraphQL errors
  # may write a non-empty JSON body to stdout, but their non-zero status still
  # reaches this guard (#155).
  payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      body
      headRefOid
      commits(last:100){nodes{commit{oid committedDate}}}
      reviews(first:100){nodes{author{login} state commit{oid} submittedAt}}
      comments(first:100){nodes{author{login} body createdAt}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)" \
    || { warn "$repo#$num: round-log fetch failed; body left as-is (handoff continues)"; return 0; }
  newbody="$(printf '%s' "$payload" \
    | jq -r --arg me "$ME" --argjson final "$final" -f "$DUTY_DIR/lib/jq/round-log.jq" 2>/dev/null)" \
    || { warn "$repo#$num: round-log render failed; body left as-is"; return 0; }
  [ -n "$newbody" ] || return 0   # every round already recorded — write nothing
  printf '%s' "$newbody" | jq -Rs '{body:.}' \
    | gh api -X PATCH "repos/$repo/pulls/$num" --input - >/dev/null 2>&1 \
    || warn "$repo#$num: round-log body write failed (handoff continues)"
}

# _handoff_comment REPO NUM — echo the engine-rendered handoff comment: the
# terminal facts and nothing composed. First line is MARK_HANDOFF + the head
# SHA so post-once.sh's exact-body dedup is stable across a retried tick.
# Echoes empty on a fetch failure (the caller then skips only the comment).
_handoff_comment() {
  local repo="$1" num="$2" owner name
  owner="${repo%%/*}"; name="${repo##*/}"
  gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      headRefOid
      latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null \
  | jq -r --arg mark "$MARK_HANDOFF" '
      .data.repository.pullRequest as $pr
      | ( $pr.latestOpinionatedReviews.nodes
          | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
                | .author.login) | unique ) as $approvers
      | $mark + " " + $pr.headRefOid + "\n\n"
        + "Every panel verdict approves the current head `" + $pr.headRefOid + "`"
        + (if ($approvers | length) > 0
           then " — " + ($approvers | map("@" + .) | join(", ")) else "" end)
        + ".\n\nThe round-by-round record is in the PR body **Round log**, above."
        + "\n\n_Rendered by the engine from the review state — no prose composed at handoff._"
    ' 2>/dev/null
}

# _handoff_finalize REPO NUM — the whole handoff, engine-side, no session and
# no clone (#91). Every step is idempotent and NONE gates the next: the label
# is what notify.sh polls, and making it contingent on a comment or a request
# that can fail is the invisible-escalation class the notifier exists to
# prevent. Order is chosen for crash-safety, not priority — state:needs-human
# is written LAST because it is the convergence refire guard (converged.jq's
# $not_handed): a box that dies before it refires next tick, and every write
# above is a no-op on the retry (post-once dedup, an already-requested
# reviewer, an already-present round marker). Requesting the human does not
# suppress the refire — converged.jq counts only PANEL requests, and the human
# is off-panel.
_handoff_finalize() {
  local repo="$1" num="$2" comment
  _mirror_rounds "$repo" "$num" true   # finalize the live round: the PR is converging
  comment="$(_handoff_comment "$repo" "$num")"
  if [ -n "$comment" ]; then
    "$BIN_DIR/post-once.sh" "$repo" "$num" "$comment" \
      || warn "$repo#$num: handoff comment did not post (best-effort; label still set)"
  else
    warn "$repo#$num: could not render the handoff comment this tick (best-effort)"
  fi
  gh api "repos/$repo/pulls/$num/requested_reviewers" \
    -f "reviewers[]=$FLEET_HUMAN" >/dev/null 2>&1 \
    || warn "$repo#$num: review request for @$FLEET_HUMAN failed (already requested?)"
  gh issue edit "$num" -R "$repo" --add-label "$LABEL_NEEDS_HUMAN" >/dev/null 2>&1 \
    || warn "$repo#$num: could not set $LABEL_NEEDS_HUMAN"
}

_report_unsignalled_hold() {
  local repo="$1" num="$2" head="$3" item fresh state
  item="$repo#$num@$head head"
  fresh="$(printf '%s\n' "$item" | ledger_filter "$DUTY_DIR/.seen-round-signal")"
  if [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" | ledger_commit "$DUTY_DIR/.seen-round-signal"
  fi
  state="$DUTY_DIR/.suppressed-round-signal.${repo//\//__}.$num"
  printf '%s\n' "$item" \
    | ledger_suppressed "$DUTY_DIR/.seen-round-signal" \
    | report_suppressed "$state" \
        "$repo#$num: no round-answered signal at head ${head:0:12} — not requesting (#133)"
}

# _request_panel REPO NUM PAYLOAD PANEL_JSON CHECK_STATE HC_HEAD — engine-side
# panel (re-)request, and state:bots-reviewing beside it (#133). This moves the
# request off the builder SESSION, where a session that died between its last
# push and its re-request left a PR that looked finished and was waiting for
# nobody — the blocker:unrequested shape.
#
# THE ENGINE ACTS ONLY ON THE SESSION'S SIGNAL, never on commit activity — the
# issue's hardest must-fail. The signal is a MARK_ANSWERED comment the session
# posts once it has answered the round whole (reply + any fix pushed) and after
# it first marks a PR ready-for-review. This function requests only when a
# MARK_ANSWERED for the CURRENT head is present: a mid-fix WIP push (green head,
# no answer yet) carries no such marker, so the panel is never re-requested
# under an unfinished round. A session that dies before posting the marker does
# not strand the PR — resume.txt re-posts it, so a missing marker only delays to
# the next tick, it never stalls forever (the old permanent-stall bug).
#
# PAYLOAD is the same GraphQL pullRequest object the handoff loop already
# fetched (now carrying comments), so this costs no extra call. Every write is
# best-effort and gates nothing — the same rule as _handoff_finalize.
_request_panel() {
  local repo="$1" num="$2" payload="$3" panel_json="$4" check_state="$5" hc_head="$6"
  local gql_head signal_json answered_head to_request rvr requested_any=0
  gql_head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
  [ -n "$gql_head" ] || { warn "$repo#$num: no head in payload; not requesting"; return 0; }
  # THE SIGNAL GATE. The latest MARK_ANSWERED comment of mine names the head the
  # round was answered at; the engine acts only when that head is the current
  # one. No marker, or a marker for a superseded head (a fix was pushed after
  # the answer and not yet re-signalled), means the round is not answered here —
  # hold, do not infer done-ness from the push.
  # The licence is ONE object, {sha, createdAt} (#286). This gate reads its sha;
  # request-panel.jq reads its createdAt to decide whether the signal answers a
  # verdict or merely predates it. Neither half is re-derived on the other side —
  # a second program means a second copy of the predicate.
  signal_json="$(printf '%s' "$payload" \
    | jq -c --arg me "$ME" --arg mark "$MARK_ANSWERED" \
        -f "$DUTY_DIR/lib/jq/answered-head.jq" 2>/dev/null)"
  [ -n "$signal_json" ] || signal_json='{"sha":"","createdAt":""}'
  answered_head="$(printf '%s' "$signal_json" | jq -r '.sha // ""' 2>/dev/null)"
  if [ "$answered_head" != "$gql_head" ]; then
    _report_unsignalled_hold "$repo" "$num" "$gql_head"
    return 0
  fi
  # The MECHANICAL half of the green-head precondition — the only half the
  # engine makes. Request only on a head whose check is green or absent; red and
  # pending both hold (wait, do not abandon — the next tick re-evaluates once the
  # check settles). The argued-exception (a red genuinely outside the PR) stays a
  # session judgement in fragment-round-rules.txt, never made here.
  case "$check_state" in
    green|none) : ;;
    *) log "$repo#$num: round answered but check at head is ${check_state:-unknown} — holding request (#45/#133)"; return 0 ;;
  esac
  # The green verdict must be ABOUT the head we would request on. head-checks.jq
  # read one gh-pr-list snapshot and this loop read a later GraphQL one; if a
  # push landed between them, defer a tick rather than request on a head whose
  # check nobody has seen settle.
  [ "$hc_head" = "$gql_head" ] || { log "$repo#$num: head moved mid-tick — deferring panel request"; return 0; }
  to_request="$(printf '%s' "$payload" \
    | jq -r --argjson panel "$panel_json" --argjson signal "$signal_json" \
        -f "$DUTY_DIR/lib/jq/request-panel.jq" 2>/dev/null)"
  # Nothing to request is now the ROUND-CLOSED case as well as the
  # nothing-owed one (#286): a panel that answered with CHANGES_REQUESTED spends
  # the signal, and the ball returns to the builder through round_owed and
  # state:addressing, which log it there. Silent here on purpose — a handed-off
  # PR stays in this loop for every tick until the human merges it, and a line
  # per tick per PR would bury the writes that matter.
  [ -n "${to_request//[[:space:]]/}" ] || return 0
  # One reviewer per call, not a batched reviewers[] array: a single 422 (an
  # already-pending request that raced the predicate) must not drop the others.
  for rvr in $to_request; do
    [ -n "$rvr" ] || continue
    if gh api "repos/$repo/pulls/$num/requested_reviewers" -f "reviewers[]=$rvr" >/dev/null 2>&1; then
      requested_any=1
    else
      warn "$repo#$num: panel request for @$rvr did not land (already requested?)"
    fi
  done
  # state:bots-reviewing rides along in the SAME act. It buys no latency —
  # review_requested carries it in seconds — it is here so the write is atomic
  # with the request that causes it, exactly as _handoff_finalize sets
  # state:needs-human beside its human request. Best-effort; gates nothing.
  if [ "$requested_any" -eq 1 ]; then
    log "$repo#$num: engine requested panel ($(printf '%s' "$to_request" | tr '\n' ' ')) at ${gql_head:0:12}"
    gh issue edit "$num" -R "$repo" --add-label "$LABEL_BOTS_REVIEWING" >/dev/null 2>&1 \
      || warn "$repo#$num: could not set $LABEL_BOTS_REVIEWING (reconciler will)"
  fi
  return 0
}

# --- The dirty-worktree report: once per (worktree, dirt), never per tick ---
#
# Leaving a dirty worktree alone is right — a `--force` here deletes
# uncommitted work irrecoverably, and no log line is worth that. What was
# wrong is that the engine said so on EVERY pass, forever, about a condition
# nothing in the loop can change: the same two lines every five minutes for
# days on build/77-fleet-action-status (PR #103, merged). A warning that
# repeats forever is not a warning, it is wallpaper, and this fleet already
# has a family of defects that survived because a signal was present and
# unread (#114, #147, #155, #158). So the ledger buys silence for a condition
# already stated once — not for an unstated one (#59).
#
# THE DIRT GOES IN THE ID, AND THE VALUE IS A FIXED SENTINEL — the ci-red
# scheme (#17) for the same reason: ledger_filter re-fires when the VALUE
# sorts greater, and a dirt fingerprint has no order. Keyed the ordinary way,
# a worktree that became dirty in a NEW way whose fingerprint happened to sort
# below the old one would be suppressed — losing the report exactly when the
# condition changed, which is the one thing this ledger must not do.
#
# `cksum`, not `sha256sum`: this is an identity for a local state file, not
# provenance, and cksum is POSIX, so the engine gains no new dependency. A
# collision costs one un-repeated warning about a worktree already reported.
_wt_dirt_id() { # $1=repo $2=branch $3=porcelain text -> ledger id
  printf '%s:%s@%s' "$1" "$2" \
    "$(printf '%s' "$3" | cksum | awk '{print $1 "-" $2}')"
}

_wt_dirt_summary() { # $1=porcelain text -> what made it dirty, in two counts
  printf '%s\n' "$1" | awk '
    /^\?\?/ { u++; next }
    NF      { m++ }
    END     { printf "%d modified, %d untracked", m+0, u+0 }'
}

# _wt_hygiene_report LEDGER REPO BRANCH PATH — say it once, and say what it
# costs. "leaving it for inspection" never told the reader the price: the
# worktree holds its branch, so the next `git worktree add` for that branch
# fails with "already checked out", on somebody else's build, later, with no
# obvious connection to the warning nobody was reading. Always returns 0 —
# whether it spoke or not is not the caller's business.
_wt_hygiene_report() {
  local ledger="$1" repo="$2" branch="$3" path="$4" dirt item
  dirt="$(git -C "$path" status --porcelain 2>/dev/null | sort)"
  item="$(printf '%s\tdirty' "$(_wt_dirt_id "$repo" "$branch" "$dirt")")"
  [ -n "$(printf '%s\n' "$item" | ledger_filter "$ledger")" ] || return 0
  warn "$repo: worktree $path not clean ($(_wt_dirt_summary "$dirt")); leaving it for inspection — it holds $branch, so a later 'git worktree add' for that branch fails with 'already checked out'"
  # Committed here, not after a session: no session runs on this signal, and
  # what is suppressed is a repeated REPORT of an unchanged condition, not
  # work a crashed session still owes.
  printf '%s\n' "$item" | ledger_commit "$ledger"
  return 0
}

# _stranded_resume_due STATE THRESHOLD — count consecutive duty ticks for
# open, ready authored PR heads that have no current-head MARK_ANSWERED signal.
# stdin is one repo#num@head key per PR. The head belongs in the key so every
# push starts again at one; keys absent this tick (draft, signalled, or closed)
# disappear. stdout is the PR number for each key reaching THRESHOLD.
_stranded_resume_due() {
  local state="$1" threshold="$2" key num next tmp
  local -A previous=() current=()
  tmp="$state.tmp.$$"
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r key next; do
      [ -n "$key" ] || continue
      previous["$key"]="${next:-0}"
    done <"$state"
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ -n "${current[$key]+x}" ] && continue
    next=$(( ${previous[$key]:-0} + 1 ))
    current["$key"]="$next"
    if [ "$next" -ge "$threshold" ]; then
      num="${key#*#}"; num="${num%@*}"
      printf '%s\n' "$num"
    fi
  done
  : >"$tmp"
  for key in "${!current[@]}"; do
    printf '%s\t%s\n' "$key" "${current[$key]}" >>"$tmp"
  done
  mv "$tmp" "$state"
}

# _stranded_resume_keys REPO ME MARK — stdin is the authored open-PR listing
# used by resume detection. Emit only ready PR heads whose latest signal from
# this builder does not name the current head. Drafts already use the original
# resume path and must never be double-counted here.
_stranded_resume_keys() {
  local repo="$1" me="$2" mark="$3" pr num head answered
  # Use the signal gate's parser rather than maintaining a second definition
  # of MARK_ANSWERED. In particular, fleet comments may wrap the SHA in
  # backticks or put punctuation after the marker; answered-head.jq accepts
  # both, and resume must classify the exact same bodies the request gate does.
  # That parser returns the whole licence, {sha, createdAt}, since #286. Resume
  # asks only "does the latest signal name this head", so it reads the sha half
  # — the same half _request_panel gates on. The time half is the request
  # side's: whether a signal was spent by the verdicts answering it says nothing
  # about whether a session died before posting it.
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    num="$(printf '%s' "$pr" | jq -r '.number')"
    head="$(printf '%s' "$pr" | jq -r '.headRefOid')"
    answered="$(printf '%s' "$pr" \
      | jq -c '{data:{repository:{pullRequest:{comments:{nodes:(.comments // [])}}}}}' \
      | jq -r --arg me "$me" --arg mark "$mark" \
          -f "$BUILDER_LIB_DIR/jq/answered-head.jq" \
      | jq -r '.sha // ""')"
    [ "$answered" = "$head" ] || printf '%s#%s@%s\n' "$repo" "$num" "$head"
  done < <(jq -c '.[] | select(.isDraft | not)')
}

# --- The resume gate (#314) -------------------------------------------------
#
# Resume was the one wake in this engine with no doable-work condition: it
# fired whenever `draft_nums` was non-empty, and `draft_nums` is every open
# draft I author, so a correctly PARKED draft woke a full model session every
# tick, forever, with no self-heal and no cap. PR #311 spent 58 sessions at one
# head across 4h45m, each posting a resume marker and a worklog checkpoint and
# committing nothing; the operator disarming the box is what stopped it.
#
# THE BUILDER'S OWN OUTPUT IS NOT A SIGNAL, and that is the whole decision.
# Nothing outside the builder ever spoke on #311, so a naive "anything changed"
# fingerprint would have re-armed itself on each of those 58 markers and
# suppressed nothing — the self-resetting trap LABELS.md already records for the
# staleness sweep ("label churn is not activity … or the sweep would reset
# itself"). Comments and reviews authored by ME are excluded by construction.
#
# THE HEAD GOES IN THE ID, THE TIMESTAMPS GO IN THE VALUE — the ci-red scheme
# (#17), for the reason recorded at that block: ledger_filter re-fires when the
# VALUE sorts greater, and a SHA has no order, so a head carried in the value
# would suppress exactly the corrective push it must wake on. Carried in the id,
# a new head is an id never seen and always fires, which is the issue's "the
# builder's own commits count: a push is progress" without asking a SHA to
# compare. What remains in the value is then all ISO-8601 — foreign comment,
# foreign review, referenced issue — so a lexical max is a chronological one.

# _resume_pr_fingerprints REPO — stdin is the authored open-PR listing resume
# detection already fetches. One tab-separated line per DRAFT:
#   <repo>#<num>@<head>  <referenced issue or empty>
#
# THE FOREIGN HALF IS NOT READ FROM THE LISTING, and that is not a style choice.
# `gh pr list --json comments,reviews` generates `comments(first: 100)` /
# `reviews(first: 100)` and does not paginate those nested connections, so the
# array is oldest-first and truncated: `max` over it is the newest of the FIRST
# hundred, and it stops moving for good once the thread passes that mark.
# Measured on the incident PR itself — `gh pr list --json number,comments`
# returns exactly 100 for #311, newest returned `2026-08-03T00:05:52Z`, while
# `/issues/311/comments --paginate` has 124. A builder that floods its own PR
# past 100 comments would be left permanently unwakeable by anyone speaking on
# it, which fails this gate's central criterion on precisely the shape it exists
# for. The newest-foreign lookup therefore goes through _resume_newest_foreign
# below, and the listing no longer fetches those fields at all.
#
# The issue reference is read from the BODY, never from the branch name: crew
# branches are `<type>/<issue>-<slug>` and only some are `build/` (#315 is
# `docs/302-rehearsal-remote`). `Closes #N` and `Refs #N` are the two forms
# BUILDER.md writes; the GitHub closing synonyms ride along. `Part of
# owner/repo#N` is deliberately NOT matched — that form is cross-repo, so the
# number does not address an issue in this repo at all — and neither is a bare
# `#N`, because crew bodies cite epics and siblings in prose and the first such
# mention is not the authorizing one. The leading `(^|[^a-z])` is a word
# boundary: without it `the operator discloses #99 in passing` yields issue 99,
# costing a gh call per tick and a WARN naming a wake nobody declared.
_resume_pr_fingerprints() {
  local repo="$1"
  jq -r --arg repo "$repo" '
    .[] | select(.isDraft)
    | ( first( (.body // "")
               | capture("(^|[^a-z])(closes|refs|fixes|resolves)[ \t]+#(?<n>[0-9]+)"; "i")
               | .n ) // "" ) as $issue
    | "\($repo)#\(.number)@\(.headRefOid)\t\($issue)"
  '
}

# _resume_newest_foreign REPO NUM ME — the newest activity on PR NUM not
# authored by ME, as an ISO-8601 stamp, or empty when nobody else has spoken.
# Nonzero means the lookup itself failed and the answer is unknown.
#
# Paginated REST, not the listing's capped GraphQL connections (above), and not
# a single page of either: `sort`/`direction` are NOT parameters of
# `GET /repos/{owner}/{repo}/issues/{n}/comments` — they belong to the
# repo-level `/issues/comments` list — so GitHub ignores them and a `per_page=1`
# read returns the OLDEST comment, pinning the fingerprint to the first thing
# ever posted. Verified on #311: `-f per_page=3 -f sort=created -f
# direction=desc` returns the same three stamps as the unsorted call, oldest
# first. Full pagination is what actually answers "the newest, at any thread
# length"; it costs ceil(n/100) calls per draft per tick, which is one for a
# normal draft and two for #311's 124, against ~1 draft per builder.
#
# ME is filtered in awk rather than in jq because `gh api --jq` takes no --arg,
# and a login interpolated into a jq program is a login that can break it.
_resume_newest_foreign() {
  local repo="$1" num="$2" me="$3" raw
  raw="$( {
      gh api --paginate "repos/$repo/issues/$num/comments?per_page=100" \
        --jq '.[] | "\(.user.login // "")\t\(.created_at // "")"' \
      && gh api --paginate "repos/$repo/pulls/$num/reviews?per_page=100" \
        --jq '.[] | "\(.user.login // "")\t\(.submitted_at // "")"'
    } 2>/dev/null )" || return 1
  printf '%s\n' "$raw" \
    | awk -F'\t' -v me="$me" '$1 != me && $2 != "" { print $2 }' \
    | sort | tail -1
}

# _resume_breaker STATE THRESHOLD — the zero-action circuit breaker. stdin is
# one `<key>\t<fresh|held>` line per draft this tick, `fresh` meaning the ledger
# would dispatch it; stdout is `<key>\t<dispatch|suppress|hold>\t<count>`.
#
# _stranded_resume_due's shape, with one deliberate difference: a key the gate
# HELD this tick keeps its count instead of being dropped. The breaker bounds
# what the ledger does not catch — a chatty external actor waking one head over
# and over — and those wakes are consecutive DISPATCHES, not consecutive ticks,
# so a quiet tick in between must not silently reset the count. Keys absent from
# stdin entirely (merged, closed, or no longer a draft) still disappear, so the
# state cannot grow without bound.
#
# The head is in the key, so any commit resets the count to one: "produced no
# commit" needs no separate observation. Counting on dispatch rather than on
# rc 0 is also deliberate — a session that crashes before committing anything is
# one of the zero-action dispatches this is here to bound.
_resume_breaker() {
  local state="$1" threshold="$2" key want count tmp
  local -A previous=() current=()
  tmp="$state.tmp.$$"
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r key count; do
      [ -n "$key" ] || continue
      previous["$key"]="${count:-0}"
    done <"$state"
  fi
  while IFS=$'\t' read -r key want; do
    [ -n "$key" ] || continue
    [ -n "${current[$key]+x}" ] && continue
    count="${previous[$key]:-0}"
    if [ "$want" != fresh ]; then
      current["$key"]="$count"
      printf '%s\thold\t%s\n' "$key" "$count"
    elif [ "$count" -ge "$threshold" ]; then
      current["$key"]="$count"
      printf '%s\tsuppress\t%s\n' "$key" "$count"
    else
      count=$(( count + 1 ))
      current["$key"]="$count"
      printf '%s\tdispatch\t%s\n' "$key" "$count"
    fi
  done
  : >"$tmp"
  for key in "${!current[@]}"; do
    printf '%s\t%s\n' "$key" "${current[$key]}" >>"$tmp"
  done
  mv "$tmp" "$state"
}

# _resume_gate REPO SLUG LISTING — the whole doable-work decision for this
# repo's drafts. It says out loud, once per tick, which drafts it withheld and
# why: a ledger trades a burn for SILENCE, and silence is how the fleet starves
# (#59).
#
# Its two answers come back in GLOBALS, not on stdout, because every one of
# those reports is a log line and log writes to stdout (tick.sh redirects the
# whole tick there). A function that returned the dispatch set through the same
# channel would fold its own reporting into the draft list.
#   RESUME_DISPATCH_NUMS  the space-joined draft numbers resume may dispatch for
#   RESUME_COMMIT_LINES   the ledger lines the SESSION must earn — committed by
#                         the caller only on rc 0, the rule .seen-build and
#                         .seen-ci-red already follow, so a crashed session
#                         re-dispatches next tick rather than losing its wake.
_resume_gate() {
  local repo="$1" slug="$2" listing="$3"
  local key foreign issue issue_ts lines="" fresh want verdict count num head
  local dispatch_nums="" breaker=3 wake fingerprints
  local -A ts_by_key=() issue_by_key=()
  RESUME_COMMIT_LINES=""
  RESUME_DISPATCH_NUMS=""
  # FAIL OPEN, AND SAY SO. jq's stderr is no longer swallowed, and a filter that
  # breaks returns nonzero here so the caller keeps its pre-gate draft list: a
  # broken gate must not become a silent permanent stall, which is the exact
  # failure #59 names ("stop paying, do not stop saying") and the one this whole
  # PR is built on. Nothing is committed on this path, so the next working tick
  # decides afresh.
  if ! fingerprints="$(printf '%s' "$listing" | _resume_pr_fingerprints "$repo")"; then
    warn "$repo: the resume fingerprint filter failed; dispatching resume ungated this tick"
    return 1
  fi
  while IFS=$'\t' read -r key issue; do
    [ -n "$key" ] || continue
    num="${key#*#}"; num="${num%@*}"
    # The floor is `0`, which sorts below any ISO-8601 stamp: a draft nobody
    # else has touched still produces a well-formed ledger line rather than a
    # blank second field, which ledger_filter's NF>=2 guard would drop silently.
    if ! foreign="$(_resume_newest_foreign "$repo" "$num" "$ME")"; then
      warn "$repo#$num: the foreign-activity lookup failed for the resume fingerprint; using the issue half this tick"
      foreign=""
    fi
    [ -n "$foreign" ] || foreign="0"
    # THE REFERENCED ISSUE IS IN THE FINGERPRINT, at one API call per draft per
    # tick, because without it the gate converts a flood into a stall: on this
    # very incident the wake landed as a comment on #290, not on #311, and a
    # PR-only fingerprint would have held the builder asleep through its own
    # park being lifted. Drafts per builder are ~1; the call is affordable and
    # the stall is not. REST, not `gh issue view` — that path dies on crew's
    # projects-classic GraphQL — and `updated_at` moves on label events as well
    # as comments, which is what a park lifted by label alone looks like.
    issue_ts=""
    if [ -n "$issue" ]; then
      issue_ts="$(gh api "repos/$repo/issues/$issue" --jq '.updated_at' 2>/dev/null || echo "")"
      [ -n "$issue_ts" ] || warn "$repo: issue #$issue lookup failed for the resume fingerprint; using the PR half this tick"
    fi
    [ -n "$issue_ts" ] && [ "$issue_ts" \> "$foreign" ] && foreign="$issue_ts"
    ts_by_key["$key"]="$foreign"
    issue_by_key["$key"]="$issue"
    lines="$lines$key $foreign"$'\n'
  done <<<"$fingerprints"
  [ -n "${lines//[[:space:]]/}" ] || return 0
  fresh="$(printf '%s' "$lines" | ledger_filter "$DUTY_DIR/.seen-resume")"
  # One line per withheld draft, every tick it is withheld — not report_suppressed's
  # speak-on-change. This branch already logs once per tick either way, so naming
  # the drafts it skipped adds no volume and removes the one thing #59 warns
  # about: a suppression nobody can see.
  printf '%s' "$lines" \
    | ledger_suppressed "$DUTY_DIR/.seen-resume" \
    | while read -r key _; do
        [ -n "$key" ] || continue
        log "no resume duty: ${key%@*} unchanged at ${key##*@}"
      done
  while IFS=$'\t' read -r key verdict count; do
    [ -n "$key" ] || continue
    num="${key#*#}"; num="${num%@*}"; head="${key##*@}"
    case "$verdict" in
      dispatch)
        dispatch_nums="$dispatch_nums $num"
        RESUME_COMMIT_LINES="$RESUME_COMMIT_LINES$key ${ts_by_key[$key]}"$'\n'
        if [ "$count" -eq "$breaker" ]; then
          # The park declares what it waits on, and the WARN carries it where
          # one is parseable: a human or a chair reading duty.log should not
          # have to open the PR to learn which issue the wake is expected on.
          if [ -n "${issue_by_key[$key]}" ]; then
            wake="$repo#${issue_by_key[$key]}"
          else
            wake="none parseable from the PR body"
          fi
          # ASSERT ONLY WHAT IS OBSERVED. The trip fires as the third dispatch
          # goes out, so only the first two are known to have produced nothing;
          # the third has not run yet. Naming all three as commitless would be
          # one session ahead of the evidence.
          warn "$repo#$num: resume dispatch $count of $count at head ${head:0:12} — the previous $(( count - 1 )) produced no commit, and after this one resume is suppressed at this head until it moves (#314); declared wake: $wake"
        fi
        ;;
      suppress)
        log "no resume duty: $repo#$num breaker-suppressed at $head after $count zero-action dispatches — only a push clears it (#314)"
        ;;
      *) : ;;   # held by the ledger; already named above
    esac
  done < <(
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if printf '%s\n' "$fresh" | grep -qxF "$key ${ts_by_key[$key]}"; then
        printf '%s\tfresh\n' "$key"
      else
        printf '%s\theld\n' "$key"
      fi
    done < <(printf '%s' "$lines" | awk 'NF{print $1}') \
      | _resume_breaker "$DUTY_DIR/.resume-zero-action.$slug" "$breaker"
  )
  RESUME_DISPATCH_NUMS="${dispatch_nums# }"
}

# _ci_red_rollup_settled EXPECTED_HEAD — stdin is the post-session gh-pr-view
# object. Success means this ci-red ledger item may be committed. A pending
# rollup at the same head, or an unreadable snapshot, remains retryable. Head
# movement is settled for the old key; the new head gets its own ledger id.
_ci_red_rollup_settled() {
  local expected_head="$1" snapshot head state
  snapshot="$(cat)"
  head="$(printf '%s' "$snapshot" | jq -r '.headRefOid // ""' 2>/dev/null)"
  [ -n "$head" ] || return 1
  [ "$head" != "$expected_head" ] && return 0
  state="$(printf '%s' "$snapshot" \
    | jq -c '[. + {reviewRequests:[], latestOpinionatedReviews:[]}]' 2>/dev/null \
    | jq -r --argjson panel '[]' --arg repo _ \
        -f "$BUILDER_LIB_DIR/jq/head-checks.jq" 2>/dev/null | cut -f4)"
  [ -n "$state" ] && [ "$state" != "pending" ]
}

duty_builder() {
  local duty_repos R
  _repair_seen_build_264
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
  round_rules="$(render_prompt fragment-round-rules.txt TRIAGE="$FLEET_TRIAGE" BENCH="$FLEET_BENCH" MARK_ADDRESSING="$MARK_ADDRESSING" MARK_ANSWERED="$MARK_ANSWERED")"
  oneshot_rules="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")"

  # --- RESUME: interrupted work of mine, checked FIRST. Three shapes: an open
  # draft PR (a session died mid-build), or a claimed issue whose build/*
  # branch exists on my fork with no open PR (died between first push and
  # `gh pr create`). I hold the duty lock, so nothing else of mine can be
  # mid-flight — that lock is what makes resume detection sound. ---
  local resume_json draft_nums orphan_nums="" stranded_nums="" stranded_keys
  local claimed_nums open_heads merged_heads N branch
  # `comments` and `reviews` are deliberately NOT requested: those nested
  # connections are generated as `first: 100` and never paginate, so reading the
  # foreign half from here caps it at the oldest hundred (_resume_pr_fingerprints).
  resume_json="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft,headRefOid,body 2>/dev/null || echo err)"
  if [ "$resume_json" = "err" ]; then
    draft_nums=err
    stranded_keys=err
  else
    draft_nums="$(printf '%s' "$resume_json" | jq -r '.[] | select(.isDraft) | .number' \
      2>/dev/null | tr '\n' ' ' || echo err)"
    stranded_keys="$(printf '%s' "$resume_json" \
      | _stranded_resume_keys "$R" "$ME" "$MARK_ANSWERED" 2>/dev/null || echo err)"
  fi
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
  if [ "$draft_nums" = "err" ] || [ "$stranded_keys" = "err" ] \
    || [ "$claimed_nums" = "err" ] || [ "$open_heads" = "err" ] || [ "$merged_heads" = "err" ]; then
    warn "$R: resume detection failed (a listing errored); skipping resume this tick"
    draft_nums=""
  else
    stranded_nums="$(printf '%s\n' "$stranded_keys" \
      | _stranded_resume_due "$DUTY_DIR/.resume-unsignalled.$slug" 12 \
      | tr '\n' ' ')"
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
    # THE DOABLE-WORK GATE (#314). Every other wake in this engine is
    # ledger-filtered; resume was the one that was not, and a park is invisible
    # to a bare "is there a draft" test. Applied to DRAFTS only: an orphaned
    # claim has no PR to fingerprint, and a stranded ready PR already carries
    # its own 12-tick counter above.
    # Fail open: a gate that cannot run leaves the pre-gate draft list standing
    # and has already warned. Over-dispatching for one tick is recoverable; a
    # silent stall is what #314 is about.
    if _resume_gate "$R" "$slug" "$resume_json"; then
      draft_nums="$RESUME_DISPATCH_NUMS"
    fi
  fi
  if [ -n "${draft_nums// /}" ] || [ -n "${orphan_nums// /}" ] || [ -n "${stranded_nums// /}" ]; then
    log "$R: resume duty (drafts: ${draft_nums:-none}; orphaned claims:${orphan_nums:-" none"}; unsignalled ready PRs: ${stranded_nums:-none})"
    ensure_main_clone "$R" "$dir" || return 0
    RUN_SESSION_RC=1
    run_session resume "$R" "$dir" "$TIMEOUT_RESUME" \
      "$(render_prompt resume.txt ME="$ME" REPO="$R" NAME="$name" \
        DRAFTS="${draft_nums:-none}" ORPHANS="${orphan_nums:-none}" \
        STRANDED="${stranded_nums:-none}" \
        MARK_RESUME="$MARK_RESUME" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules")"
    # Committed only on rc 0, exactly as .seen-build and .seen-ci-red are: a
    # crashed or timed-out session must re-dispatch next tick, never lose the
    # wake it never got to act on.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then
      printf '%s' "$RESUME_COMMIT_LINES" | ledger_commit "$DUTY_DIR/.seen-resume"
    fi
  else
    log "$R: no resume duty"
  fi

  panel_json="$(panel_for_repo "$R" "$dir" "$ME" | jq -c --arg me "$ME" '. - [$me]')"

  # --- One listing of my open PRs, several facts. The state of the check at
  # the head was never read by this engine at all: `statusCheckRollup` appeared
  # nowhere in it. That single omission is both #45 (a fix round opened on a red
  # head spends a full panel round relaying a failure the author already had)
  # and #17 (a red head with no round owed and no conflict woke nothing, so an
  # approved, mergeable PR stranded on a transient CI failure). One datum, two
  # bugs — and the round-owed signal was already fetching this exact listing, so
  # headRefOid and statusCheckRollup ride along for no additional call.
  local mine_json mine_rows pr_payload N
  mine_json="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft,reviewRequests,updatedAt,headRefOid,statusCheckRollup \
    2>/dev/null || echo err)"
  if [ "$mine_json" = "err" ]; then
    mine_rows=err
  else
    # Fetch the head-carrying opinionated verdicts before any session so they
    # can drive round_owed. The gh-pr-list latestReviews field cannot
    # substitute: COMMENTED masks a standing blocker there, and its commit.oid
    # is empty (#147). Handoff deliberately fetches again after the sessions:
    # this early snapshot can be an hour old by then.
    for N in $(printf '%s' "$mine_json" \
      | jq -r '.[] | select(.isDraft | not) | .number'); do
      pr_payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
        } } }' -f owner="$owner" -f name="$name" -F num="$N" 2>/dev/null || echo '')"
      if [ -z "$pr_payload" ]; then
        warn "$R#$N: review fetch failed; round reads not-owed this tick (request and handoff fetch later)"
        continue
      fi
      mine_json="$(printf '%s' "$mine_json" | jq -c \
        --argjson num "$N" \
        --argjson reviews "$(printf '%s' "$pr_payload" \
          | jq -c '.data.repository.pullRequest.latestOpinionatedReviews.nodes')" \
        'map(if .number == $num then . + {latestOpinionatedReviews:$reviews} else . end)')"
    done
    mine_rows="$(printf '%s' "$mine_json" \
      | jq -r --argjson panel "$panel_json" --arg repo "$R" \
        -f "$DUTY_DIR/lib/jq/head-checks.jq" 2>/dev/null || echo err)"
  fi

  # The check state and head SHA per PR, indexed by number — the green-head
  # precondition the engine's panel request is gated on (#133). Read off the
  # same head-checks rows the round gate already computed, so the request rides
  # the one gh-pr-list snapshot and adds no call. head_by_num pins which head
  # that check state describes, so a push landing after this snapshot defers the
  # request rather than requesting on a head nobody has seen settle.
  local -A check_by_num=() head_by_num=()
  local _hc_key _hc_upd _hc_head _hc_state _hc_rest _hc_num
  if [ "$mine_rows" != "err" ]; then
    while IFS=$'\t' read -r _hc_key _hc_upd _hc_head _hc_state _hc_rest; do
      [ -n "$_hc_key" ] || continue
      _hc_num="${_hc_key##*#}"
      check_by_num[$_hc_num]="$_hc_state"
      head_by_num[$_hc_num]="$_hc_head"
    done <<<"$mine_rows"
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
            CHECKS="${red_checks:-unknown}" WT_RULES="$wt_rules" \
            ROUND_RULES="$round_rules")"
        if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
          local settled_json
          settled_json="$(gh pr view "$red_num" -R "$R" \
            --json number,isDraft,updatedAt,headRefOid,statusCheckRollup \
            2>/dev/null || echo err)"
          if [ "$settled_json" = "err" ]; then
            warn "$R#$red_num: check rollup re-read failed; leaving ci-red head uncommitted"
          else
            if ! printf '%s' "$settled_json" | _ci_red_rollup_settled "${red_key##*@}"; then
              log "$R#$red_num: check still pending after ci-red session; leaving head uncommitted for retry"
            else
              printf '%s\thead\n' "$red_key" | ledger_commit "$DUTY_DIR/.seen-ci-red"
            fi
          fi
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
  local ready_json ready_count ready_assigned cr_count open_pr_count head_checks="-"
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
  # ADMIT `green` OR `none`; HOLD `red` AND `pending` (danmt's ruling, #64).
  #
  # The gate is a whitelist for the same reason `is_green` is: "everything but
  # red" is a fallthrough, and a fallthrough is what the CANCELLED bug was.
  # The three states are three different facts and get three behaviours.
  #
  #   red      HELD, and it is the author's own work. Wakes ci-red above.
  #   pending  HELD, and it is NOT the author's work — it is a check that has
  #            not answered yet. Opening the round now spends the panel on a
  #            head that may go red, which is exactly what #45 measured on
  #            crew#40. Transient by definition: the item re-evaluates next
  #            tick (5 minutes) and admits itself once the check settles
  #            green. Must NOT wake ci-red — nothing has failed.
  #   none     ADMITTED. Terminal, not transient: a repo with no CI configured
  #            is `none` FOREVER, so holding on it means the engine can never
  #            open a review round in that repo at all. head-checks.jq already
  #            rules this a state of its own rather than a not-green one — "a
  #            repo with no CI configured and a repo whose checks all passed
  #            are different facts, and only one of them is evidence."
  #
  # Two holds, two messages. A pending hold that borrowed the red wording
  # ("CI first") would tell the operator the author owes work when the author
  # owes nothing but a wait, and that misreading is the whole distinction the
  # ruling draws.
  #
  # An admitted `none` head still travels into the build prompt: the session is
  # bound by the same green-at-the-head rule, and `none` is the one state where
  # there is no check coming to wait for. Telling it so beats it inferring so.
  local blocked_rounds held_rounds
  if [ "$mine_rows" = "err" ]; then
    cr_items=""
    cr_count=err
    head_checks="-"
  else
    cr_items="$(awk -F'\t' '$5 == "owed" && ($4 == "green" || $4 == "none") { print $1, $2 }' <<<"$mine_rows")"
    blocked_rounds="$(awk -F'\t' '$5 == "owed" && $4 == "red" { print $1 }' <<<"$mine_rows")"
    for N in $blocked_rounds; do
      log "$N: round owed, but the check at its head is RED — CI first, no panel round (#45)"
    done
    held_rounds="$(awk -F'\t' '$5 == "owed" && $4 == "pending" { print $1 }' <<<"$mine_rows")"
    for N in $held_rounds; do
      log "$N: round owed, but the check at its head has not finished — waiting for it to settle, no panel round yet (#45)"
    done
    # Admitted on no evidence rather than on green: named, and handed on.
    head_checks="$(awk -F'\t' '$5 == "owed" && $4 == "none" { s = s (s ? "; " : "") $1 " (no checks configured)" } END { print s }' <<<"$mine_rows")"
    [ -n "$head_checks" ] && log "$R: round(s) admitted with no check at the head — $head_checks"
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
  if [ "$cr_count" != "err" ]; then
    # Any open authored PR occupies the active-build slot. A completed round
    # still wakes so it can be answered, but ready work never starts beside an
    # awaiting-review or draft PR. Post-merge waits have no open PR to count.
    open_pr_count="$(printf '%s' "$mine_json" | jq 'length' 2>/dev/null || echo 0)"
    _gate_ready_for_open_pr || true
  fi
  if [ "$cr_count" = "err" ]; then
    warn "$R: build-duty detection failed; skipping build this tick"
  elif [ "$ready_count" -gt 0 ] || [ "$cr_count" -gt 0 ]; then
    log "$R: build duty (ready unclaimed=$ready_count, whole rounds owed=$cr_count)"
    ensure_main_clone "$R" "$dir" || return 0
    RUN_SESSION_RC=1
    run_session build "$R" "$dir" "$TIMEOUT_BUILD" \
      "$(render_prompt build.txt ME="$ME" REPO="$R" TRIAGE="$FLEET_TRIAGE" \
        CLAIM="$BIN_DIR/claim-issue.sh" \
        HEAD_CHECKS="$head_checks" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules" ONESHOT_RULES="$oneshot_rules")"
    # Record what this session SAW, at the state it saw it in — but only if the
    # session actually ran to completion. A crash or timeout leaves the ids
    # uncommitted so the next tick retries: declined and never-got-there must
    # not look the same to the ledger.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
      local ready_commit="" post_ready_json post_ready_ids
      if [ -n "${ready_items//[[:space:]]/}" ]; then
        if post_ready_json="$(gh issue list -R "$R" --state open --label "$LABEL_READY" \
          --json number,assignees 2>/dev/null)"; then
          post_ready_ids="$(printf '%s' "$post_ready_json" | jq -r --arg repo "$R" \
            '.[] | select((.assignees | length) == 0) | "\($repo)#\(.number)"' 2>/dev/null || true)"
          ready_commit="$(_ready_lines_to_commit "$ready_items" "$post_ready_ids")"
        else
          warn "$R: post-session ready re-query failed; committing no ready lines (#264)"
        fi
      fi
      printf '%s\n%s\n' "$ready_commit" "$cr_items" | ledger_commit "$DUTY_DIR/.seen-build"
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
  if [ "$mine_json" = "err" ]; then
    warn "$R: handoff detection failed; skipping"
  else
    # Stay on the same authored-PR snapshot used above. A second listing could
    # add a PR for which this tick has no cached review payload, or drop one
    # whose round was just evaluated.
    my_open="$(printf '%s' "$mine_json" \
      | jq -r '.[] | select(.isDraft | not) | .number')"
    for N in $my_open; do
      # Round-log mirroring runs EVERY tick over my open PRs — not only at
      # handoff — so the body's Round log tracks each round as it is answered
      # (#91 / ceremony#196: "at re-request time"). Since #133 the re-request is
      # the engine's own act (_request_panel, just below), so this sweep and the
      # request share the tick — mirror first, then request. Marker-keyed and
      # idempotent, so a re-tick writes nothing. Best-effort: never blocks the
      # request or the handoff detection below.
      # final=false: per-tick mirroring records only superseded rounds and
      # defers the live one, so a round mid-flight is never stamped as answered
      # before its whole-round reply lands (round-log.jq live-round note).
      _mirror_rounds "$R" "$N" false
      # Sessions above can run for up to an hour and can push a new head while
      # reviewers also act. Fetch again here so request-panel and convergence
      # never act on the early round-detection snapshot (#147). This one read
      # drives both panel request and convergence; a fetch failure or GraphQL
      # error body skips both this tick.
      # createdAt and submittedAt are the ORDERING evidence (#286): whether the
      # signal answers a verdict or merely predates it is a question about time,
      # and this payload already drives the request, so asking for the two
      # timestamps costs no extra call.
      if ! pr_payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid mergeable
          labels(first:50){nodes{name}}
          comments(last:100){nodes{author{login} body createdAt}}
          reviewRequests(first:50){nodes{requestedReviewer{... on User{login}}}}
          latestOpinionatedReviews(first:50){nodes{author{login} state submittedAt commit{oid}}}
        } } }' -f owner="$owner" -f name="$name" -F num="$N" 2>/dev/null)"; then
        warn "$R#$N: PR state fetch failed; skipping request and handoff this tick"
        continue
      fi
      if ! printf '%s' "$pr_payload" \
        | jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1; then
        warn "$R#$N: PR state payload unusable; skipping request and handoff this tick"
        continue
      fi
      # Request the panel when the round is signalled answered at a green head
      # (#133). When it requests, converged.jq below returns false on the same
      # payload (not every panelist approves the head), so the two never both
      # fire — no continue needed.
      _request_panel "$R" "$N" "$pr_payload" "$panel_json" \
        "${check_by_num[$N]:-}" "${head_by_num[$N]:-}"
      converged="$(printf '%s' "$pr_payload" \
        | jq -r --argjson panel "$panel_json" --arg needs_human "$LABEL_NEEDS_HUMAN" \
            -f "$DUTY_DIR/lib/jq/converged.jq" 2>/dev/null || echo err)"
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
    # Option B (#91, ceremony#196): handoff is fully mechanical — no session,
    # no clone. The engine mirrors any un-recorded rounds into the body's Round
    # log, posts the factual handoff comment, requests the human, and sets
    # state:needs-human. No prose is composed here, so no model is spent; the
    # authored record already lives in the Round log, written per round.
    for N in $handoff_prs; do
      log "$R#$N: round converged — handing off (no session, no clone)"
      _handoff_finalize "$R" "$N"
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
        "$(render_prompt rebase.txt ME="$ME" REPO="$R" NUM="$N" MARK_ANSWERED="$MARK_ANSWERED" WT_RULES="$wt_rules")"
    done
  else
    log "$R: no rebase duty"
  fi

  # --- WORKTREE hygiene: a build/* worktree is removable only when its
  # branch has PR history AND no PR on it remains open — `--state all` with
  # a joined state list, so a newer closed PR can never shadow an older open
  # one (the .[0]-of-newest-first bug in codex's variant could delete a live
  # branch). A branch with no PR at all is an in-flight claim: resume's
  # business, stays. A dirty worktree is never force-removed, and the fact
  # that it was left is reported once per (worktree, dirt state) rather than
  # on every tick (#167, _wt_hygiene_report above). ---
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
            _wt_hygiene_report "$DUTY_DIR/.seen-wt-dirty" "$R" "$wt_branch" "$wt_path"
          fi
          git -C "$dir" worktree prune 2>/dev/null || true
          ;;
      esac
    done < <(git -C "$dir" worktree list --porcelain \
      | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/build\//{b=$2; sub("refs/heads/","",b); print b, p}')
  fi
}
