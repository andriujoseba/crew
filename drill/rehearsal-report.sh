#!/usr/bin/env bash
# Where a drill round's findings go, derived from the source that round
# actually drilled. Sourced by drill/rehearsal.sh and drill/rehearsal-all.sh
# and driven directly by shared/test/drill.sh.
#
# Both callers already hold the remote and the operator's ref when they print
# their exit footer, so the derivation is pure string work: no `gh`, no network,
# no second resolution (#492 D4). That bound is the reason the answer is a ref
# shape and not "the PR containing this commit" — the latter is a lookup, and a
# drill footer is not worth one.

# rehearsal_report_repo_slug REMOTE
# Print `<owner>/<repo>` for a remote that names one, and return 0. Return 1
# for anything else — a local path, a bare directory, an empty string.
rehearsal_report_repo_slug() {
  local remote="${1:-}"
  remote="${remote%/}"
  remote="${remote%.git}"
  remote="${remote%/}"
  [[ "$remote" =~ ^([a-z][a-z0-9+.-]*://)?([^/@[:space:]]+@)?[A-Za-z0-9._-]+(:[0-9]+)?[:/]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]] \
    || return 1
  printf '%s/%s\n' "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

# rehearsal_report_pr_number REF
# Print the pull request number a ref names, and return 0. Return 1 where the
# ref names no pull request. Only the pull ref forms answer: a branch, a tag
# and a bare commit each name a tree that any number of pull requests — or
# none — may carry, and guessing between them is how a footer starts naming
# the wrong PR.
rehearsal_report_pr_number() {
  local ref="${1:-}"
  [[ "$ref" =~ ^(refs/)?pull/([0-9]+)(/(head|merge))?$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}"
}

# rehearsal_report_target REMOTE REF
# Print the report target for a round drilled from REMOTE at REF — the string
# a footer names, `<owner>/<repo> PR #<n>` — and return 0. Print nothing and
# return 1 where no target is derivable, which is the common case: a round
# drilling `main`, a tag or a local tree has no pull request to route findings
# to, and the caller then drops the instruction rather than printing a stale
# one (#492 D2). The slug is dropped rather than the whole target where the
# remote does not name one, because the PR number is the routing and the slug
# only disambiguates it.
rehearsal_report_target() {
  local remote="${1:-}" ref="${2:-}" number="" slug=""
  number="$(rehearsal_report_pr_number "$ref")" || return 1
  if slug="$(rehearsal_report_repo_slug "$remote")"; then
    printf '%s PR #%s\n' "$slug" "$number"
  else
    printf 'PR #%s\n' "$number"
  fi
}
