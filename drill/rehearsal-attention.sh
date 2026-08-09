#!/usr/bin/env bash
# Sourceable attention-wake drill helpers. The live leg runs only from
# rehearsal.sh's authenticated builder block; every predicate stays here so CI
# can mutate its inputs — the board reads, the session output, the box paths —
# without a drill host.
#
# What this covers that the two wake rows above it do not (#440). The
# role-independent wake rows assert the ACK: a pickup comment appears and the
# label comes off. Both were true before #301 and after it, so neither reads
# what #301 shipped:
#
#   1. dispatch without code — a builder attention wake on a claim with no open
#      PR and no build branch records the next build step, unassigns itself and
#      swaps claimed to ready, WITHOUT creating a branch, commit or PR
#      (shared/lib/duty-attention.sh, the builder route);
#   2. the timed-out pickup report — a session that exceeds TIMEOUT_ATTENTION
#      leaves one ⏱️ comment naming a STABLE log link, plants that link beside
#      the immutable run log, and fires the operator alert on the run log.
#
# The wake fixture's own demand forbids opening PRs, so the round could not
# tell a session that dispatched correctly from one that merely obeyed a
# prompt. This leg files its own fixture, whose demand ASKS for build work.
#
# Why the leg calls duty_attention directly instead of ticking. duty.sh runs
# duty_attention first and duty_builder second, and a correct dispatch is
# precisely an invitation to duty_builder: the same tick that dispatches may
# legitimately claim and build the issue it released. Asserting the absence of
# a PR after a whole tick would therefore red on correct behaviour. Calling the
# module directly — the shape rehearsal-hygiene.sh already uses for _wt_release
# — puts the assertion on what the attention session left behind, which is
# what #301 D1 is about.

if ! declare -F rehearsal_verdict_record >/dev/null 2>&1; then
  # shellcheck source=drill/rehearsal-verdict.sh
  . "$(dirname "${BASH_SOURCE[0]}")/rehearsal-verdict.sh"
fi

REHEARSAL_ATTENTION_REPO=""
REHEARSAL_ATTENTION_ISSUES=""
REHEARSAL_ATTENTION_NUM=""
REHEARSAL_ATTENTION_BRANCHES="[]"
REHEARSAL_ATTENTION_BRANCH_UNREADABLE=""

rehearsal_attention_verdict() {
  rehearsal_verdict_record "${REHEARSAL_ATTENTION_STATUS:-}" "$@"
}

# --- pure predicates: the dispatch half (§4) -------------------------------
#
# Each prints WHAT IT READ on stdout and returns non-zero when the fact does
# not hold, so the live row can quote the offender rather than a transcript.

# The engine's own link between a PR and the issue it serves: a closing keyword
# in the body, or a build branch named for the issue. A dispatch that also
# built is caught by either, and #301 exists to prevent both.
rehearsal_attention_prs_for_issue_from_json() {
  local issue="$1" pulls_json="$2" offenders
  offenders="$(jq -r --arg issue "$issue" '
    [ .[]
      | select(
          ((.body // "")
            | test(
                "(?im)(^|\\s)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s+#"
                + $issue + "([^0-9]|$)"
              ))
          or ((.head // "") | startswith("build/" + $issue + "-"))
        )
      | "#\(.number) (\(.head // "?"))"
    ] | .[]
  ' <<<"$pulls_json")" || return 2
  [ -z "$offenders" ] || { printf '%s\n' "$offenders"; return 1; }
  return 0
}

# Entries are {repo, name}, because the branch this row exists to catch is not
# on the sandbox. The route being drilled says so — shared/prompts/attention.txt
# reads "check the builder fork for a build/{{NUM}}-* branch" — and so does the
# engine's ORPHANS, duty-builder.sh reading repos/$ME/$name with fork pointed at
# https://github.com/$ME/$name.git (common.sh). A dispatch that did push would
# push there (git push -u fork), so reading only the sandbox is green on the one
# mutation the row is for.
#
# `unreadable` is the third input rather than a silent empty list: a source that
# exists and still will not list its branches must red here, not read as "no
# branches". A fork that does not exist yet is not in it — it cannot hold a
# pushed branch — and the collector drops it.
rehearsal_attention_build_branches_from_json() {
  local issue="$1" branches_json="$2" unreadable="${3:-}" offenders
  if [ -n "$unreadable" ]; then
    printf 'could not list branches of: %s\n' "$unreadable"
    return 1
  fi
  offenders="$(jq -r --arg issue "$issue" '
    [ .[]
      | select(((.name // "") | startswith("build/" + $issue + "-")))
      | "\(.repo // "?") \(.name // "?")"
    ] | .[]
  ' <<<"$branches_json")" || return 2
  [ -z "$offenders" ] || { printf '%s\n' "$offenders"; return 1; }
  return 0
}

rehearsal_attention_labels_from_json() {
  jq -r '[.labels[].name] | sort | join(" ")' <<<"$1"
}

rehearsal_attention_assignees_from_json() {
  jq -r '[.assignees[].login] | sort | join(" ")' <<<"$1"
}

# ready is set and claimed is gone: the swap, not merely the addition. A
# session that added ready and left claimed standing has not released anything.
rehearsal_attention_is_ready_from_json() {
  local issue_json="$1" labels
  labels="$(rehearsal_attention_labels_from_json "$issue_json")" || return 2
  printf '%s\n' "${labels:-<no labels>}"
  jq -e '([.labels[].name] | index("ready")) != null
    and ([.labels[].name] | index("claimed")) == null' \
    >/dev/null <<<"$issue_json"
}

rehearsal_attention_identity_released_from_json() {
  local identity="$1" issue_json="$2" assignees
  assignees="$(rehearsal_attention_assignees_from_json "$issue_json")" || return 2
  printf '%s\n' "${assignees:-<unassigned>}"
  jq -e --arg identity "$identity" \
    '([.assignees[].login] | index($identity)) == null' \
    >/dev/null <<<"$issue_json"
}

# "Records the next build step" without reading agent prose. The pickup mark is
# the only comment the ack owes; the route owes a second thing — the next build
# step — before it may release the claim. So the fact is: at least one comment
# by the identity in this run's window that is NOT the ack. Anything stronger
# would assert the fixture's wording back to itself.
rehearsal_attention_next_step_count_from_json() {
  local mark="$1" identity="$2" after="$3" comments_json="$4"
  jq -r --arg mark "$mark" --arg identity "$identity" --arg after "$after" '
    [ .[]
      | select(.user.login == $identity)
      | select((.created_at // "") > $after)
      | select(((.body // "") | ltrimstr(" ") | startswith($mark)) | not)
    ] | length
  ' <<<"$comments_json"
}

rehearsal_attention_records_next_step_from_json() {
  local count
  count="$(rehearsal_attention_next_step_count_from_json "$@")" || return 2
  printf '%s non-ack comment(s) by the identity in this run window\n' "${count:-0}"
  [ "${count:-0}" -ge 1 ]
}

# --- pure predicates: the timeout half (§5) --------------------------------

# post-once.sh dedups on the exact body, and the body names the STABLE link
# precisely so a retry's new timestamped path cannot defeat that. Two lowered
# invocations must therefore leave exactly one comment.
rehearsal_attention_timeout_count_from_json() {
  local mark="$1" comments_json="$2"
  jq -r --arg mark "$mark" \
    '[ .[] | select((.body // "") | contains($mark)) ] | length' \
    <<<"$comments_json"
}

rehearsal_attention_timeout_comment_once_from_json() {
  local count
  count="$(rehearsal_attention_timeout_count_from_json "$@")" || return 2
  printf '%s timeout comment(s)\n' "${count:-0}"
  [ "${count:-0}" -eq 1 ]
}

rehearsal_attention_timeout_names_link_from_json() {
  local mark="$1" link="$2" comments_json="$3" body
  # An empty link would make the grep below match any body at all — a vacuous
  # pass standing beside the run-log row that is already red for the same
  # reason. The two rows stay independent.
  if [ -z "$link" ]; then
    printf 'no stable link derived to check the comment against\n'
    return 1
  fi
  body="$(jq -r --arg mark "$mark" \
    '[ .[] | select((.body // "") | contains($mark)) | .body ] | .[0] // ""' \
    <<<"$comments_json")" || return 2
  printf '%s\n' "${body:-<no timeout comment>}"
  [ -n "$body" ] && grep -Fq -- "$link" <<<"$body"
}

# The stable link is DERIVED here rather than parsed out of the comment: an
# assertion that read the path from the body it is checking would only prove
# the body agrees with itself.
rehearsal_attention_stable_link_for() {
  local repo="$1" num="$2" run_log="$3" slug
  # Its own statement: a name declared by `local` is not yet readable by a
  # later assignment in the same `local`, so folding this in silently derived
  # `attention-_77-latest.log` and the row compared two wrong paths.
  slug="${repo//\//__}"
  [ -n "$run_log" ] || return 1
  printf '%s/attention-%s_%s-latest.log\n' "${run_log%/*}" "$slug" "$num"
}

rehearsal_attention_run_log_from_output() {
  local repo="$1" num="$2" out="$3" path
  path="$(grep -F "SESSION START kind=attention key=$repo#$num " <<<"$out" \
    | sed -n 's/.* log=\([^[:space:]]*\).*/\1/p' | tail -1)"
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

rehearsal_attention_alert_names_run_log() {
  local needle="$1" run_log="$2" alerts="$3" line
  line="$(grep -F "$needle" <<<"$alerts" | tail -1)"
  printf '%s\n' "${line:-<no timeout alert>}"
  [ -n "$line" ] && grep -Fq -- "$run_log" <<<"$line"
}

# The lowered budget lives in one shell and dies with it, so the restore is the
# process exiting. The round proves that by re-resolving the installed value
# rather than asserting it in a comment: same number before and after, and a
# number the lowered invocation could never have left behind.
rehearsal_attention_timeout_restored() {
  local before="$1" after="$2" lowered="$3"
  printf 'installed TIMEOUT_ATTENTION before=%s after=%s (lowered to %s)\n' \
    "${before:-<unset>}" "${after:-<unset>}" "$lowered"
  case "${before:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$before" = "${after:-}" ] && [ "$before" -gt "$lowered" ]
}

# Why the row above is red, when it is: a budget that never resolved is not a
# budget that was left lowered, and the aggregate summary names one cause.
rehearsal_attention_timeout_unresolved() {
  local before="$1" after="$2"
  case "${before:-}" in ''|*[!0-9]*) return 0 ;; esac
  case "${after:-}" in ''|*[!0-9]*) return 0 ;; esac
  return 1
}

# --- box and board reads ---------------------------------------------------

rehearsal_attention_open_prs_json() {
  local repo="$1" author="$2"
  # The pulls endpoint reflects a new PR immediately; search-backed listings
  # lag behind the invocation this leg is measuring.
  gh api "repos/$repo/pulls?state=open&per_page=100" --paginate \
    | jq -s --arg author "$author" \
      '[add[] | select(.user.login == $author) | {number, body, head: .head.ref}]'
}

# The two places a build/<issue>-* branch can be after a dispatch: the sandbox
# the demand lives on, and the builder fork the route names and a push targets.
rehearsal_attention_branch_sources() {
  local repo="$1" identity="$2"
  printf '%s\n%s/%s\n' "$repo" "$identity" "${repo##*/}"
}

# Fills REHEARSAL_ATTENTION_BRANCHES / _BRANCH_UNREADABLE rather than printing,
# so a source that fails to list is distinguishable from one with no branches.
rehearsal_attention_collect_branches() {
  local src part
  REHEARSAL_ATTENTION_BRANCHES="[]"
  REHEARSAL_ATTENTION_BRANCH_UNREADABLE=""
  for src in "$@"; do
    if part="$(gh api "repos/$src/branches?per_page=100" --paginate 2>/dev/null \
        | jq -s --arg r "$src" '[add[] | {repo: $r, name: .name}]' 2>/dev/null)" \
        && [ -n "$part" ]; then
      REHEARSAL_ATTENTION_BRANCHES="$(jq -s 'add' \
        <<<"$REHEARSAL_ATTENTION_BRANCHES"$'\n'"$part")" || return 1
    elif gh api "repos/$src" >/dev/null 2>&1; then
      REHEARSAL_ATTENTION_BRANCH_UNREADABLE="${REHEARSAL_ATTENTION_BRANCH_UNREADABLE:+$REHEARSAL_ATTENTION_BRANCH_UNREADABLE }$src"
    fi
    # A fork that does not exist yet cannot hold a pushed branch: skipped, not
    # recorded as unreadable.
  done
  return 0
}

rehearsal_attention_installed_timeout() {
  # shellcheck disable=SC2016  # HOME and the conf value resolve in the box
  bx 'set -uo pipefail
    DUTY_DIR="$HOME/duty"
    source "$DUTY_DIR/lib/common.sh"
    load_conf
    printf "%s\n" "${TIMEOUT_ATTENTION:-}"
  '
}

rehearsal_attention_stable_log_readable() {
  local link="$1"
  # -L is the link itself; -f and -r follow it, so a dangling link reds here.
  bx "[ -L '$link' ] && [ -f '$link' ] && [ -r '$link' ]"
}

# One real pickup session at the INSTALLED budget: the dispatch half is the
# route's own decision and has to be paid for.
rehearsal_attention_dispatch_invoke() {
  local identity="$1"
  bx "set -uo pipefail
    DUTY_DIR=\"\$HOME/duty\"
    source \"\$DUTY_DIR/lib/common.sh\"
    load_conf
    ME='$identity'
    source \"\$DUTY_DIR/lib/duty-attention.sh\"
    duty_attention
  " 2>&1
}

# The timeout half does not wait TIMEOUT_ATTENTION; it lowers it for one
# invocation (#440 §2). Both overrides are plain shell assignments made AFTER
# load_conf, in the process that calls duty_attention — nothing on the box is
# edited, so no exit path can leave a lowered budget behind. The stand-in CLI
# hangs rather than failing, which is what makes rc 124 deterministic instead
# of a race against a real CLI's startup.
#
# One backslash on the alert override's `$*`, not two. bx is a single shell
# layer (box exec … bash -lc "$1"), so the box's bash is the CONSUMER of this
# text: it wants to parse `"$*"`, and `\$` here is what survives to become it.
# rehearsal-breaker.sh's `\\$*` is the right count for its own context — that
# one sits inside a quoted heredoc, where the box's bash is the writer.
rehearsal_attention_timeout_invoke() {
  local identity="$1" budget="$2" capture="$3"
  bx "set -uo pipefail
    DUTY_DIR=\"\$HOME/duty\"
    source \"\$DUTY_DIR/lib/common.sh\"
    load_conf
    ME='$identity'
    source \"\$DUTY_DIR/lib/duty-attention.sh\"
    TIMEOUT_ATTENTION=$budget
    BOT_CLI_CMD=(sh -c 'sleep 600' drill-attention-timeout)
    alert() { printf '%s\n' \"\$*\" >>'$capture'; }
    duty_attention
  " 2>&1
}

# The registry the EXIT trap reads (rehearsal.sh:175). Split out from the filer
# so the cleanup path can be exercised without an API call.
rehearsal_attention_register_fixture() {
  local repo="$1" num="$2"
  REHEARSAL_ATTENTION_REPO="$repo"
  REHEARSAL_ATTENTION_ISSUES="${REHEARSAL_ATTENTION_ISSUES:+$REHEARSAL_ATTENTION_ISSUES }$num"
}

# The number comes back in a GLOBAL, not on stdout, and callers must not wrap
# this in a command substitution: bash runs one in a subshell, so a registry
# written there dies with it and the EXIT trap inherits an empty list. That
# leaves an open assigned claimed+attention fixture on the sandbox for the next
# duty tick to pick up — the exact state an interrupt, or the fixture
# precondition's early return, has to be able to unwind.
rehearsal_attention_file_fixture() {
  local repo="$1" identity="$2" title="$3" body="$4" num
  REHEARSAL_ATTENTION_NUM=""
  num="$(gh api "repos/$repo/issues" -f title="$title" -f body="$body" \
    -f "assignees[]=$identity" -f "labels[]=claimed" -f "labels[]=attention" \
    --jq .number)" || return 1
  [ -n "$num" ] || return 1
  rehearsal_attention_register_fixture "$repo" "$num"
  REHEARSAL_ATTENTION_NUM="$num"
}

rehearsal_attention_close_fixture() {
  local repo="$1" num="$2"
  gh api -X DELETE "repos/$repo/issues/$num/labels/attention" >/dev/null 2>&1 || true
  gh api -X PATCH "repos/$repo/issues/$num" -f state=closed >/dev/null 2>&1
}

# Neither mark is retyped here. The pickup mark is a wire value in the
# installed configuration and the timeout phrase is a literal in the installed
# module, so reading both back means an engine change moves these assertions
# with the engine instead of quietly changing their subject.
rehearsal_attention_load_installed_marks() {
  local pickup phrase
  REHEARSAL_ATTENTION_MARK_PICKUP=""
  REHEARSAL_ATTENTION_TIMEOUT_PHRASE=""
  # shellcheck disable=SC2016  # the wire variable expands inside the box
  pickup="$(bx '
    set -a
    . ~/duty/conf/fleet.defaults.conf
    printf "%s\n" "$MARK_PICKUP"
  ')" || pickup=""
  phrase="$(bx "
    sed -n 's/.*timeout_note=\"[^[:alnum:]]*\([a-z][^\";\$]*\).*/\1/p' \
      ~/duty/lib/duty-attention.sh | head -1
  ")" || phrase=""
  if [ -z "$pickup" ] || [ -z "$phrase" ]; then
    echo "attention: read pickup mark '$pickup', timeout phrase '$phrase'"
    fail "attention: installed pickup mark and timeout phrase resolve"
    return 1
  fi
  REHEARSAL_ATTENTION_MARK_PICKUP="$pickup"
  REHEARSAL_ATTENTION_TIMEOUT_PHRASE="$phrase"
  ok "attention: installed pickup mark and timeout phrase resolve"
}

# One bounded settle, then grade every row off the SAME read: the five dispatch
# facts describe one board state, and reading them at five different moments
# would let a row pass against a state another row already failed.
rehearsal_attention_settled_issue_json() {
  local repo="$1" num="$2" identity="$3" end=$((SECONDS + 60)) issue_json=""
  while :; do
    issue_json="$(gh api "repos/$repo/issues/$num" 2>/dev/null)" || issue_json=""
    if [ -n "$issue_json" ] \
        && rehearsal_attention_is_ready_from_json "$issue_json" >/dev/null 2>&1 \
        && rehearsal_attention_identity_released_from_json \
             "$identity" "$issue_json" >/dev/null 2>&1; then
      break
    fi
    [ "$SECONDS" -lt "$end" ] || break
    sleep 10
  done
  [ -n "$issue_json" ] || return 1
  printf '%s\n' "$issue_json"
}

# graded NAME PREDICATE... — run the predicate, print what it read indented
# under a failure, and grade the row. §7: a red names the value it read.
rehearsal_attention_graded() {
  local name="$1"; shift
  local read_back rc=0
  read_back="$("$@")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$name"
    return 0
  fi
  if [ -n "$read_back" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "  read: $line"
    done <<<"$read_back"
  fi
  fail "$name"
  return 1
}

rehearsal_attention_dispatch_half() {
  local repo="$1" identity="$2" mark="$3"
  local num filed_at issue_json pulls_json comments_json out
  local sources
  # NOT a command substitution: the registry the EXIT trap reads is written by
  # this call, and a subshell would discard it.
  rehearsal_attention_file_fixture "$repo" "$identity" \
    "drill: attention dispatch $(date -u +%H%M%S)" \
    "Drill demand: this claim has not started. Add a file named drill-attention.txt at the repo root containing one line, and open a pull request for it." \
    || { fail "attention: dispatch fixture filed"; return 1; }
  num="$REHEARSAL_ATTENTION_NUM"
  ok "attention: dispatch fixture filed"
  filed_at="$(gh api "repos/$repo/issues/$num" --jq .created_at)" || filed_at=""
  mapfile -t sources < <(rehearsal_attention_branch_sources "$repo" "$identity")

  # Fixture validity, not one of §4's five: the route branches on exactly these
  # two absences, so a fixture that already carried either would prove nothing.
  pulls_json="$(rehearsal_attention_open_prs_json "$repo" "$identity")" || pulls_json='[]'
  rehearsal_attention_collect_branches "${sources[@]}"
  if rehearsal_attention_prs_for_issue_from_json "$num" "$pulls_json" >/dev/null \
      && rehearsal_attention_build_branches_from_json "$num" \
           "$REHEARSAL_ATTENTION_BRANCHES" \
           "$REHEARSAL_ATTENTION_BRANCH_UNREADABLE" >/dev/null; then
    ok "attention: dispatch fixture starts with no PR and no build branch"
  else
    fail "attention: dispatch fixture starts with no PR and no build branch"
    return 1
  fi

  out="$(rehearsal_attention_dispatch_invoke "$identity")" || true
  if grep -Fq "SESSION START kind=attention key=$repo#$num " <<<"$out"; then
    ok "attention: dispatch wake launched a pickup session"
  else
    echo "  read: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"
    fail "attention: dispatch wake launched a pickup session"
  fi

  issue_json="$(rehearsal_attention_settled_issue_json "$repo" "$num" "$identity")" \
    || issue_json=""
  [ -n "$issue_json" ] || issue_json='{}'
  pulls_json="$(rehearsal_attention_open_prs_json "$repo" "$identity")" || pulls_json='[]'
  rehearsal_attention_collect_branches "${sources[@]}"
  comments_json="$(gh api "repos/$repo/issues/$num/comments?per_page=100" --paginate \
    | jq -s 'add // []')" || comments_json='[]'

  local dispatch_ok=0
  # §4, five rows. The two absence rows come first: they are what #301 exists
  # to prevent, and a leg checking only the label swap would pass a session
  # that dispatched AND built.
  rehearsal_attention_graded "attention: dispatch opened no PR for the claim" \
    rehearsal_attention_prs_for_issue_from_json "$num" "$pulls_json" || dispatch_ok=1
  rehearsal_attention_graded "attention: dispatch pushed no build/$num-* branch" \
    rehearsal_attention_build_branches_from_json "$num" \
      "$REHEARSAL_ATTENTION_BRANCHES" "$REHEARSAL_ATTENTION_BRANCH_UNREADABLE" \
    || dispatch_ok=1
  rehearsal_attention_graded "attention: dispatch left the issue ready" \
    rehearsal_attention_is_ready_from_json "$issue_json" || dispatch_ok=1
  rehearsal_attention_graded "attention: dispatch unassigned the identity" \
    rehearsal_attention_identity_released_from_json "$identity" "$issue_json" \
    || dispatch_ok=1
  rehearsal_attention_graded "attention: dispatch recorded the next build step" \
    rehearsal_attention_records_next_step_from_json \
      "$mark" "$identity" "$filed_at" "$comments_json" || dispatch_ok=1

  # Closed here, not at cleanup: a correct dispatch is an invitation to
  # duty_builder, and leaving a ready unassigned fixture on the board would
  # hand a later leg's tick a build nobody asked for.
  rehearsal_attention_close_fixture "$repo" "$num" || true
  return "$dispatch_ok"
}

rehearsal_attention_timeout_half() {
  local repo="$1" identity="$2" phrase="$3" capture="$4" budget="$5"
  local num first second run_log link comments_json alerts
  # One capture PER INVOCATION. run_session stamps the log at second
  # granularity (common.sh), so the two invocations name two different run
  # logs; a shared capture graded with tail -1 would check the second
  # invocation's alert against the first invocation's run log and red on a
  # correct engine. The pair has to come from one invocation, and the first is
  # the one the rest of this half already reads: post-once.sh dedups, so the
  # comment left on the board — and the stable link derived from it — is its.
  local capture_first="$capture.1" capture_second="$capture.2"
  # NOT a command substitution — see rehearsal_attention_file_fixture.
  rehearsal_attention_file_fixture "$repo" "$identity" \
    "drill: attention timeout $(date -u +%H%M%S)" \
    "Drill demand: this pickup is expected to exceed its budget. No action is required of a reader." \
    || { fail "attention: timeout fixture filed"; return 1; }
  num="$REHEARSAL_ATTENTION_NUM"
  ok "attention: timeout fixture filed"
  bx "rm -f '$capture_first' '$capture_second'" >/dev/null 2>&1 || true

  # Twice on purpose. rc 124 never commits the seen-ledger, so the demand is
  # still fresh the second time round — which is the only way to read whether
  # post-once.sh actually held the comment to one.
  first="$(rehearsal_attention_timeout_invoke "$identity" "$budget" "$capture_first")" || true
  second="$(rehearsal_attention_timeout_invoke "$identity" "$budget" "$capture_second")" || true
  if grep -Fq "outcome=TIMEOUT" <<<"$first" && grep -Fq "outcome=TIMEOUT" <<<"$second"; then
    ok "attention: both lowered invocations timed out"
  else
    echo "  read: $(grep -F 'SESSION END kind=attention' <<<"$first$second" | tr '\n' ' ')"
    fail "attention: both lowered invocations timed out"
  fi

  if run_log="$(rehearsal_attention_run_log_from_output "$repo" "$num" "$first")"; then
    ok "attention: timeout run log resolved from the session record"
  else
    fail "attention: timeout run log resolved from the session record"
    run_log=""
  fi
  link="$(rehearsal_attention_stable_link_for "$repo" "$num" "$run_log")" || link=""

  comments_json="$(gh api "repos/$repo/issues/$num/comments?per_page=100" --paginate \
    | jq -s 'add // []')" || comments_json='[]'
  # The FIRST invocation's alerts only — $run_log above is the first's.
  alerts="$(bx "cat '$capture_first' 2>/dev/null || true")" || alerts=""

  local timeout_ok=0
  # §5, four rows.
  rehearsal_attention_graded "attention: timeout comment posted exactly once" \
    rehearsal_attention_timeout_comment_once_from_json "$phrase" "$comments_json" \
    || timeout_ok=1
  rehearsal_attention_graded "attention: timeout comment names the stable log link" \
    rehearsal_attention_timeout_names_link_from_json "$phrase" "$link" "$comments_json" \
    || timeout_ok=1
  if [ -n "$link" ] && rehearsal_attention_stable_log_readable "$link"; then
    ok "attention: stable log link resolves to a readable file"
  else
    echo "  read: ${link:-<no link derived>} — $(bx "ls -l '$link' 2>&1 | head -1" 2>/dev/null || echo unreadable)"
    fail "attention: stable log link resolves to a readable file"
    timeout_ok=1
  fi
  rehearsal_attention_graded "attention: operator alert named the run log" \
    rehearsal_attention_alert_names_run_log \
      "$phrase for $repo#$num" "$run_log" "$alerts" || timeout_ok=1

  bx "rm -f '$capture_first' '$capture_second'" >/dev/null 2>&1 || true
  rehearsal_attention_close_fixture "$repo" "$num" || true
  return "$timeout_ok"
}

# rehearsal_attention_drill REPO IDENTITY — the builder-role leg (#440).
rehearsal_attention_drill() {
  local repo="$1" identity="$2" box_home capture budget=1
  local before after dispatch_rc=1 timeout_rc=1

  if [ "${REHEARSAL_ATTENTION_DRILL:-1}" -eq 0 ]; then
    skip "attention: dispatch without code and the timed-out pickup report (--no-attention-drill)"
    rehearsal_attention_verdict skip "--no-attention-drill"
    return 0
  fi
  if ! rehearsal_attention_load_installed_marks; then
    rehearsal_attention_verdict fail "installed pickup mark or timeout phrase does not resolve"
    return 1
  fi
  # shellcheck disable=SC2016  # HOME belongs to the box
  if ! box_home="$(bx 'printf %s "$HOME"')" || [ -z "$box_home" ]; then
    fail "attention: box home resolves"
    rehearsal_attention_verdict fail "box home does not resolve"
    return 1
  fi
  capture="$box_home/duty/.rehearsal-attention-alerts"

  before="$(rehearsal_attention_installed_timeout | tr -d '\r')" || before=""

  rehearsal_attention_dispatch_half "$repo" "$identity" \
    "$REHEARSAL_ATTENTION_MARK_PICKUP" && dispatch_rc=0
  rehearsal_attention_timeout_half "$repo" "$identity" \
    "$REHEARSAL_ATTENTION_TIMEOUT_PHRASE" "$capture" "$budget" && timeout_rc=0

  after="$(rehearsal_attention_installed_timeout | tr -d '\r')" || after=""
  if ! rehearsal_attention_graded "attention: installed pickup budget survives the lowered run" \
      rehearsal_attention_timeout_restored "$before" "$after" "$budget"; then
    # Two different causes behind one red row: a budget that did not resolve at
    # all is not a budget that was left lowered, and the summary line has to
    # name the one that happened.
    if rehearsal_attention_timeout_unresolved "$before" "$after"; then
      rehearsal_attention_verdict fail \
        "the installed pickup budget did not resolve (before=${before:-<unset>} after=${after:-<unset>})"
    else
      rehearsal_attention_verdict fail "the lowered pickup budget was not restored"
    fi
    return 1
  fi

  if [ "$dispatch_rc" -eq 0 ] && [ "$timeout_rc" -eq 0 ]; then
    rehearsal_attention_verdict ok "dispatch without code + timed-out pickup report"
    return 0
  fi
  rehearsal_attention_verdict fail "dispatch or timeout assertions red — see the run's rows"
  return 1
}

rehearsal_attention_cleanup() {
  local repo="${REHEARSAL_ATTENTION_REPO:-}" num
  [ -n "$repo" ] && [ -n "${REHEARSAL_ATTENTION_ISSUES:-}" ] || return 0
  for num in $REHEARSAL_ATTENTION_ISSUES; do
    gh api -X DELETE "repos/$repo/issues/$num/labels/attention" \
      >/dev/null 2>&1 || true
    gh api -X PATCH "repos/$repo/issues/$num" -f state=closed \
      >/dev/null 2>&1 || true
  done
  REHEARSAL_ATTENTION_ISSUES=""
}
