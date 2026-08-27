#!/usr/bin/env bash
# Sourceable fixture and invariant helpers for drill/rehearsal.sh. These stay
# separate so their failure cases can be exercised without credentials or a
# host-side drill box.

rehearsal_load_installed_queue_labels() {
  local count
  # shellcheck disable=SC2016  # the label variables expand inside the box
  REHEARSAL_QUEUE_LABELS="$(bx '
    set -a
    . ~/duty/conf/fleet.defaults.conf
    printf "%s\n" \
      "$LABEL_READY" "$LABEL_CLAIMED" "$LABEL_BLOCKED" \
      "$LABEL_POST_MERGE" "$LABEL_EPIC" "$LABEL_NEEDS_TRIAGE"
  ' | sed '/^$/d' | sort -u)"
  count="$(printf '%s\n' "$REHEARSAL_QUEUE_LABELS" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -eq 6 ]; then
    ok "triage: installed queue-label set resolves six names"
    return 0
  fi

  echo "triage: installed queue-label set resolved $count name(s):"
  printf '%s\n' "$REHEARSAL_QUEUE_LABELS" | sed 's/^/  /'
  fail "triage: installed queue-label set resolves six names"
  return 1
}

rehearsal_load_installed_answer_mark() {
  local mark
  # shellcheck disable=SC2034  # sourced global consumed by rehearsal.sh
  REHEARSAL_MARK_ANSWERED=""
  # shellcheck disable=SC2016  # the wire variable expands inside the box
  if ! mark="$(bx '
    set -a
    . ~/duty/conf/fleet.defaults.conf
    printf "%s\n" "$MARK_ANSWERED"
  ')" || [ -z "$mark" ]; then
    fail "builder: installed round-answer mark resolves"
    return 1
  fi
  # shellcheck disable=SC2034  # sourced global consumed by rehearsal.sh
  REHEARSAL_MARK_ANSWERED="$mark"
  ok "builder: installed round-answer mark resolves"
}

rehearsal_builder_slot_prs_from_json() {
  jq -r '.[].number' <<<"$1"
}

rehearsal_builder_pr_for_issue_from_json() {
  local issue="$1" pulls_json="$2" pr
  pr="$(jq -r --arg issue "$issue" '
    [ .[]
      | select(
          (.body // "")
          | test(
              "(?im)(^|\\s)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s+#"
              + $issue + "([^0-9]|$)"
            )
        )
      | .number
    ]
    | if length == 1 then .[0] else empty end
  ' <<<"$pulls_json")" || return
  [ -n "$pr" ] || return 1
  printf '%s\n' "$pr"
}

rehearsal_builder_open_prs_json() {
  local repo="$1" author="$2"
  # The pulls endpoint reflects a new PR immediately; `gh pr list --author`
  # goes through search and can lag behind the tick the drill is measuring.
  gh api "repos/$repo/pulls?state=open&per_page=100" --paginate \
    | jq -s --arg author "$author" \
      '[add[] | select(.user.login == $author) | {number, body}]'
}

rehearsal_builder_slot_prs() {
  local repo="$1" author="$2" pulls_json
  pulls_json="$(rehearsal_builder_open_prs_json "$repo" "$author")" || return
  rehearsal_builder_slot_prs_from_json "$pulls_json"
}

rehearsal_builder_pr_for_issue() {
  local repo="$1" author="$2" issue="$3" pulls_json
  pulls_json="$(rehearsal_builder_open_prs_json "$repo" "$author")" || return
  rehearsal_builder_pr_for_issue_from_json "$issue" "$pulls_json"
}

rehearsal_fixture_record_issue() {
  local repo="$1" issue="$2"
  if [ -n "${REHEARSAL_FIXTURE_REPO:-}" ] \
      && [ "$REHEARSAL_FIXTURE_REPO" != "$repo" ]; then
    echo "teardown: refusing to mix fixture repositories: $REHEARSAL_FIXTURE_REPO and $repo" >&2
    return 1
  fi
  REHEARSAL_FIXTURE_REPO="$repo"
  REHEARSAL_FIXTURE_ISSUES="${REHEARSAL_FIXTURE_ISSUES:+$REHEARSAL_FIXTURE_ISSUES }$issue"
}

rehearsal_fixture_record_pr() {
  local repo="$1" pr="$2"
  if [ -n "${REHEARSAL_FIXTURE_REPO:-}" ] \
      && [ "$REHEARSAL_FIXTURE_REPO" != "$repo" ]; then
    echo "teardown: refusing to mix fixture repositories: $REHEARSAL_FIXTURE_REPO and $repo" >&2
    return 1
  fi
  REHEARSAL_FIXTURE_REPO="$repo"
  REHEARSAL_FIXTURE_PRS="${REHEARSAL_FIXTURE_PRS:+$REHEARSAL_FIXTURE_PRS }$pr"
}

rehearsal_open_sandbox_objects() {
  local repo="$1"
  gh api "repos/$repo/issues?state=open&per_page=100" --paginate \
    | jq -sr 'add[] | (if has("pull_request") then "pull" else "issue" end)
      + " #" + (.number | tostring) + " — " + .title'
}

rehearsal_cleanup_owned_fixtures() {
  local repo="${REHEARSAL_FIXTURE_REPO:-}" pr issue failed=0
  [ -n "$repo" ] || return 0

  for pr in ${REHEARSAL_FIXTURE_PRS:-}; do
    [ -n "$pr" ] || continue
    if gh api -X PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null; then
      echo "teardown: closed owned fixture PR #$pr"
    else
      echo "teardown: WARNING — could not close owned fixture PR #$pr" >&2
      failed=1
    fi
  done
  for issue in ${REHEARSAL_FIXTURE_ISSUES:-}; do
    [ -n "$issue" ] || continue
    if gh api -X PATCH "repos/$repo/issues/$issue" -f state=closed >/dev/null; then
      echo "teardown: closed owned fixture issue #$issue"
    else
      echo "teardown: WARNING — could not close owned fixture issue #$issue" >&2
      failed=1
    fi
  done

  if [ "$failed" -eq 0 ]; then
    REHEARSAL_FIXTURE_REPO=""
    REHEARSAL_FIXTURE_PRS=""
    REHEARSAL_FIXTURE_ISSUES=""
  fi
  return "$failed"
}

rehearsal_builder_fixture_panel_content() {
  local author="$1" reviewer="$2"
  printf 'panel[%s]=%s\n' "$author" "$reviewer"
}

rehearsal_install_builder_fixture_panel() {
  local repo="$1" author="$2" reviewer="$3" path=.github/labels.conf
  local content current_sha=""
  content="$(rehearsal_builder_fixture_panel_content "$author" "$reviewer")"
  current_sha="$(gh api "repos/$repo/contents/$path" --jq .sha 2>/dev/null || true)"
  if [ -n "$current_sha" ]; then
    gh api -X PUT "repos/$repo/contents/$path" \
      -f message="drill: set builder fixture panel" \
      -f content="$(printf '%s' "$content" | base64 -w0)" \
      -f sha="$current_sha" >/dev/null
  else
    gh api -X PUT "repos/$repo/contents/$path" \
      -f message="drill: set builder fixture panel" \
      -f content="$(printf '%s' "$content" | base64 -w0)" >/dev/null
  fi
}

rehearsal_builder_is_draft_from_json() {
  jq -e '.draft == true' >/dev/null <<<"$1"
}

rehearsal_builder_head_is_from_json() {
  local expected="$1" pull_json="$2"
  jq -e --arg expected "$expected" '.head.sha == $expected' \
    >/dev/null <<<"$pull_json"
}

rehearsal_builder_has_answer_signal_from_json() {
  local mark="$1" author="$2" head="$3" after="$4" comments_json="$5"
  jq -e \
    --arg mark "$mark" --arg author "$author" --arg head "$head" \
    --arg after "$after" '
    any(.[];
      .user.login == $author
      and (.created_at // "") > $after
      and ((.body // "") | startswith($mark))
      and (((.body // "") | ltrimstr($mark)
        | try capture("(?<sha>[0-9a-f]{40})").sha catch "") == $head)
    )
  ' >/dev/null <<<"$comments_json"
}

rehearsal_builder_check_state_from_json() {
  local context="$1" status_json="$2"
  jq -r --arg context "$context" '
    [(.statuses // [])[] | select(.context == $context)]
    | sort_by(.created_at)
    | last
    | .state // ""
  ' <<<"$status_json"
}

rehearsal_builder_requested_from_json() {
  local reviewer="$1" requested_json="$2"
  jq -e --arg reviewer "$reviewer" \
    'any((.users // [])[]; .login == $reviewer)' >/dev/null <<<"$requested_json"
}

rehearsal_builder_pr_is_draft() {
  local repo="$1" pr="$2" pull_json
  pull_json="$(gh api "repos/$repo/pulls/$pr")" || return
  rehearsal_builder_is_draft_from_json "$pull_json"
}

rehearsal_builder_head_is() {
  local repo="$1" pr="$2" expected="$3" pull_json
  pull_json="$(gh api "repos/$repo/pulls/$pr")" || return
  rehearsal_builder_head_is_from_json "$expected" "$pull_json"
}

rehearsal_builder_has_answer_signal() {
  local repo="$1" pr="$2" mark="$3" author="$4" head="$5" after="$6" comments_json
  comments_json="$(gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate | jq -s 'add')" || return
  rehearsal_builder_has_answer_signal_from_json \
    "$mark" "$author" "$head" "$after" "$comments_json"
}

rehearsal_builder_check_state() {
  local repo="$1" head="$2" context="$3" status_json
  status_json="$(gh api "repos/$repo/commits/$head/status")" || return
  rehearsal_builder_check_state_from_json "$context" "$status_json"
}

rehearsal_builder_requested() {
  local repo="$1" pr="$2" reviewer="$3" requested_json
  requested_json="$(gh api "repos/$repo/pulls/$pr/requested_reviewers")" || return
  rehearsal_builder_requested_from_json "$reviewer" "$requested_json"
}

rehearsal_builder_not_requested() {
  local repo="$1" pr="$2" reviewer="$3" requested_json
  requested_json="$(gh api "repos/$repo/pulls/$pr/requested_reviewers")" || return
  ! rehearsal_builder_requested_from_json "$reviewer" "$requested_json"
}

rehearsal_set_builder_head_status() {
  local repo="$1" head="$2" context="$3" state="$4" description="$5"
  gh api "repos/$repo/statuses/$head" \
    -f state="$state" -f context="$context" \
    -f description="$description" >/dev/null
}

rehearsal_builder_signal_window_from_json() {
  local mark="$1" author="$2" head="$3" after="$4" context="$5" comments_json="$6" status_json="$7" state
  if ! rehearsal_builder_has_answer_signal_from_json \
      "$mark" "$author" "$head" "$after" "$comments_json"; then
    printf 'waiting\n'
    return 0
  fi
  state="$(rehearsal_builder_check_state_from_json "$context" "$status_json")"
  if [ "$state" = pending ]; then
    printf 'caught\n'
  else
    printf 'closed:%s\n' "${state:-no-status}"
  fi
}

rehearsal_wait_builder_signal_window() {
  local seconds="$1" repo="$2" pr="$3" mark="$4" author="$5" head="$6" after="$7" context="$8"
  local end=$((SECONDS + seconds)) comments_json status_json result
  while [ "$SECONDS" -lt "$end" ]; do
    comments_json="$(gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate | jq -s 'add')" || comments_json='[]'
    status_json="$(gh api "repos/$repo/commits/$head/status")" || status_json='{"statuses":[]}'
    result="$(rehearsal_builder_signal_window_from_json \
      "$mark" "$author" "$head" "$after" "$context" "$comments_json" "$status_json")"
    case "$result" in
      caught)
        ok "builder: round answer is signalled while head check is pending"
        return 0 ;;
      closed:*)
        skip "builder: pending-check signal window closed before it could be observed (check ${result#closed:}); round answer signal was present"
        return 0 ;;
    esac
    sleep 10
  done
  fail "builder: round answer is signalled while head check is pending (timeout ${seconds}s)"
  return 1
}

rehearsal_wait_builder_signal_window_with_prereqs() {
  local mark="$4" after="$7"
  if [ -z "$mark" ]; then
    skip "builder: round answer signal window unavailable (installed answer mark unresolved)"
    return 0
  fi
  if [ -z "$after" ]; then
    skip "builder: round answer signal window unavailable (changes-requested review boundary unresolved)"
    return 0
  fi
  rehearsal_wait_builder_signal_window "$@"
}

rehearsal_report_missing_builder_pr() {
  skip "builder: initial PR is ready for its fixture panel"
  skip "builder: host reviewer requested for initial round"
  skip "builder: installed round-answer mark resolves"
  skip "builder: host changes-requested review submitted"
  skip "builder: pending head status established"
  skip "builder: changes-requested round returns PR to draft"
  skip "builder: round answer is signalled while head check is pending"
  skip "builder: fix round kept the fixture head stable"
  skip "builder: panel request withheld while head check is pending"
  skip "builder: settled head status established"
  skip "builder: panel request issued after head settles"
}

rehearsal_report_occupied_builder_slot() {
  local author="$1"
  fail "builder: opened a PR for the ready issue"
  fail "builder: PR authored by $author for this run's fixture issue"
  skip "builder fixture is unassigned (ready+assigned is not pickable)"
  skip "builder: PR branch is build/*"
  skip "builder: issue moved off ready (claimed)"
  skip "builder: no duplicate PR on re-tick"
  skip "builder: fixture panel names the host reviewer"
  skip "builder: initial PR is ready for its fixture panel"
  skip "builder: host reviewer requested for initial round"
  skip "builder: installed round-answer mark resolves"
  skip "builder: host changes-requested review submitted"
  skip "builder: pending head status established"
  skip "builder: changes-requested round returns PR to draft"
  skip "builder: round answer is signalled while head check is pending"
  skip "builder: fix round kept the fixture head stable"
  skip "builder: panel request withheld while head check is pending"
  skip "builder: settled head status established"
  skip "builder: panel request issued after head settles"
}

rehearsal_close_builder_fixture_prs() {
  local repo="$1" author="$2" pr prs failed=0
  if ! prs="$(rehearsal_builder_slot_prs "$repo" "$author")"; then
    echo "teardown: WARNING — could not list builder fixture PRs" >&2
    return 1
  fi
  while read -r pr; do
    [ -n "$pr" ] || continue
    if gh api -X PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null; then
      echo "teardown: closed builder fixture PR #$pr"
    else
      echo "teardown: WARNING — could not close builder fixture PR #$pr" >&2
      failed=1
    fi
  done <<<"$prs"
  return "$failed"
}

rehearsal_close_issue_fixtures() {
  local repo="$1" issues="$2" issue failed=0
  for issue in $issues; do
    [ -n "$issue" ] || continue
    if gh api -X PATCH "repos/$repo/issues/$issue" -f state=closed >/dev/null; then
      echo "teardown: closed triage fixture issue #$issue"
    else
      echo "teardown: WARNING — could not close triage fixture issue #$issue" >&2
      failed=1
    fi
  done
  return "$failed"
}
