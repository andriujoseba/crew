#!/usr/bin/env bash
# GitHub-server ordering predicate shared by the live rehearsal and fixtures.

rehearsal_review_announce_precedes_verdict_from_json() {
  local identity="$1" head="$2" comments_json="$3" reviews_json="$4"
  jq -en --arg identity "$identity" --arg head "$head" \
    --argjson comments "$comments_json" --argjson reviews "$reviews_json" '
      [$comments[]
        | select(.user.login == $identity and .body == ("🔎 reviewing head " + $head))
        | .created_at] as $announces
      | [$reviews[]
          | select(
              .user.login == $identity
              and .commit_id == $head
              and (.state == "APPROVED" or .state == "CHANGES_REQUESTED")
            )
          | .submitted_at] as $verdicts
      | if ($announces | length) != 1 then
          error("review ordering: expected exactly one announce for identity and head")
        elif ($verdicts | length) == 0 then
          error("review ordering: expected a verdict for identity and head")
        elif $announces[0] < ($verdicts | min) then
          true
        else
          error("review ordering: announce must precede verdict")
        end
    ' >/dev/null
}

rehearsal_review_announce_precedes_verdict() {
  local repo="$1" pr="$2" identity="$3" head="$4" comments_json reviews_json
  comments_json="$(gh api "repos/$repo/issues/$pr/comments" --paginate | jq -s add)" || return
  reviews_json="$(gh api "repos/$repo/pulls/$pr/reviews" --paginate | jq -s add)" || return
  rehearsal_review_announce_precedes_verdict_from_json \
    "$identity" "$head" "$comments_json" "$reviews_json"
}
