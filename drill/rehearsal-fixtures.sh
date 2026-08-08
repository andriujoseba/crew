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

rehearsal_report_occupied_builder_slot() {
  local author="$1"
  fail "builder: opened a PR for the ready issue"
  fail "builder: PR authored by $author for this run's fixture issue"
  skip "builder fixture is unassigned (ready+assigned is not pickable)"
  skip "builder: PR branch is build/*"
  skip "builder: issue moved off ready (claimed)"
  skip "builder: no duplicate PR on re-tick"
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
