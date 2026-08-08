#!/usr/bin/env bash
# Sourceable worktree-hygiene drill helpers. The live leg runs after the
# role-specific phase-2 block; its predicates stay here so CI can mutate the
# ref, record and log inputs without a drill host.

REHEARSAL_HYGIENE_CLONE=""
REHEARSAL_HYGIENE_WORKTREES=""
REHEARSAL_HYGIENE_BRANCHES=""
REHEARSAL_HYGIENE_REFS=""

rehearsal_hygiene_tip_has_all_dirt() {
  local tree="$1"
  grep -qxF README.md <<<"$tree" \
    && grep -qxF hygiene-root-untracked.txt <<<"$tree" \
    && grep -qxF hygiene-untracked/nested.txt <<<"$tree"
}

rehearsal_hygiene_record_names_payload() {
  local body="$1" remote="$2" ref="$3"
  grep -Fq "\`$remote\` remote as \`$ref\`" <<<"$body" \
    && grep -Fq '1 modified, 2 untracked' <<<"$body" \
    && grep -Fq 'staged and differed from the working tree' <<<"$body" \
    && grep -Fq 'git checkout FETCH_HEAD^' <<<"$body"
}

rehearsal_hygiene_push_precedes_removal() {
  local log_text="$1" push_line remove_line
  push_line="$(grep -nF 'drill hygiene: preservation push landed' <<<"$log_text" \
    | head -1 | cut -d: -f1)"
  remove_line="$(grep -nF 'drill hygiene: forced removal invoked' <<<"$log_text" \
    | head -1 | cut -d: -f1)"
  [ -n "$push_line" ] && [ -n "$remove_line" ] \
    && [ "$push_line" -lt "$remove_line" ]
}

rehearsal_hygiene_refusal_is_intact() {
  local before="$1" after="$2" first_log="$3" second_log="$4"
  [ "$before" = "$after" ] \
    && [ "$(grep -c 'WARN:' <<<"$first_log" || true)" -eq 1 ] \
    && [ "$(grep -c 'WARN:' <<<"$second_log" || true)" -eq 0 ]
}

rehearsal_hygiene_box_snapshot() {
  local path="$1"
  bx "set -e
    git -C '$path' status --porcelain --untracked-files=all
    sha256sum '$path/README.md' '$path/hygiene-root-untracked.txt' \
      '$path/hygiene-untracked/nested.txt'
    git -C '$path' show :README.md
  "
}

rehearsal_hygiene_cleanup() {
  local wt branch ref
  [ -n "$REHEARSAL_HYGIENE_CLONE" ] || return 0
  for wt in $REHEARSAL_HYGIENE_WORKTREES; do
    bx "git -C '$REHEARSAL_HYGIENE_CLONE' worktree remove --force '$wt' >/dev/null 2>&1 || true"
  done
  for branch in $REHEARSAL_HYGIENE_BRANCHES; do
    bx "git -C '$REHEARSAL_HYGIENE_CLONE' branch -D '$branch' >/dev/null 2>&1 || true
        git -C '$REHEARSAL_HYGIENE_CLONE' push -q origin --delete '$branch' >/dev/null 2>&1 || true"
  done
  for ref in $REHEARSAL_HYGIENE_REFS; do
    bx "git -C '$REHEARSAL_HYGIENE_CLONE' push -q origin --delete '$ref' >/dev/null 2>&1 || true"
  done
  bx "git -C '$REHEARSAL_HYGIENE_CLONE' remote remove fork >/dev/null 2>&1 || true
      rm -rf ~/duty/.rehearsal-hygiene-shim" >/dev/null 2>&1 || true
  REHEARSAL_HYGIENE_CLONE=""
  REHEARSAL_HYGIENE_WORKTREES=""
  REHEARSAL_HYGIENE_BRANCHES=""
  REHEARSAL_HYGIENE_REFS=""
}

rehearsal_hygiene_fixture() {
  local repo="$1" branch="$2" path="$3" stamp="$4"
  bx "set -euo pipefail
    clone='$REHEARSAL_HYGIENE_CLONE'
    git -C \"\$clone\" fetch -q origin main
    git -C \"\$clone\" worktree remove --force '$path' >/dev/null 2>&1 || true
    git -C \"\$clone\" branch -D '$branch' >/dev/null 2>&1 || true
    git -C \"\$clone\" push -q origin --delete '$branch' >/dev/null 2>&1 || true
    git -C \"\$clone\" worktree add -q -b '$branch' '$path' origin/main
    printf 'fixture %s\n' '$stamp' >'$path/hygiene-fixture.txt'
    git -C '$path' add hygiene-fixture.txt
    git -C '$path' commit -q -m 'drill: stage hygiene fixture'
    git -C '$path' push -q -u origin '$branch'
  " || return 1

  REHEARSAL_HYGIENE_WORKTREES="$REHEARSAL_HYGIENE_WORKTREES $path"
  REHEARSAL_HYGIENE_BRANCHES="$REHEARSAL_HYGIENE_BRANCHES $branch"
  return 0
}

rehearsal_hygiene_close_fixture_pr() {
  local repo="$1" branch="$2" pr
  pr="$(bx "gh api 'repos/$repo/pulls' -f title='drill: hygiene $branch' \
    -f head='$branch' -f base=main \
    -f body='Drill fixture for dirty-worktree hygiene; close without merging.' \
    --jq .number")" || return 1
  [ -n "$pr" ] || return 1
  bx "gh api -X PATCH 'repos/$repo/pulls/$pr' -f state=closed >/dev/null" \
    || return 1
  printf '%s\n' "$pr"
}

rehearsal_hygiene_add_dirt() {
  local path="$1" stamp="$2"
  bx "set -e
    printf 'staged %s\n' '$stamp' >'$path/README.md'
    git -C '$path' add README.md
    printf 'working %s\n' '$stamp' >'$path/README.md'
    printf 'root %s\n' '$stamp' >'$path/hygiene-root-untracked.txt'
    mkdir -p '$path/hygiene-untracked'
    printf 'nested %s\n' '$stamp' >'$path/hygiene-untracked/nested.txt'
  "
}

rehearsal_hygiene_install_git_trace() {
  # shellcheck disable=SC2016  # the command and generated shim expand in the box
  bx 'set -e
    shim="$HOME/duty/.rehearsal-hygiene-shim"
    mkdir -p "$shim"
    real_git="$(command -v git)"
    cat >"$shim/git" <<EOF
#!/usr/bin/env bash
real_git="$real_git"
is_push=0
is_force_remove=0
seen_worktree=0
seen_remove=0
for arg in "\$@"; do
  [ "\$arg" != push ] || is_push=1
  [ "\$arg" != worktree ] || seen_worktree=1
  [ "\$arg" != remove ] || seen_remove=1
  if [ "\$arg" = --force ] && [ "\$seen_worktree" -eq 1 ] && [ "\$seen_remove" -eq 1 ]; then
    is_force_remove=1
  fi
done
if [ "\$is_push" -eq 1 ]; then
  "\$real_git" "\$@"; rc=\$?
  [ "\$rc" -ne 0 ] || echo "drill hygiene: preservation push landed" >>"\$HOME/duty/duty.log"
  exit "\$rc"
fi
if [ "\$is_force_remove" -eq 1 ]; then
  echo "drill hygiene: forced removal invoked" >>"\$HOME/duty/duty.log"
fi
exec "\$real_git" "\$@"
EOF
    chmod +x "$shim/git"
  '
}

rehearsal_hygiene_release() {
  local repo="$1" branch="$2" path="$3" pr="$4" ledger="$5"
  bx "set -uo pipefail
    DUTY_DIR=\"\$HOME/duty\"
    source \"\$DUTY_DIR/lib/common.sh\"
    load_conf
    ME=\"$(gh api user --jq .login)\"
    source \"\$DUTY_DIR/lib/duty-builder.sh\"
    PATH=\"\$DUTY_DIR/.rehearsal-hygiene-shim:\$PATH\"
    _wt_release '$REHEARSAL_HYGIENE_CLONE' '$repo' '$branch' '$path' '$pr' '$ledger'
  "
}

rehearsal_hygiene_drill() {
  local repo="$1" role="$2" slug stamp box_home good_branch bad_branch good_wt bad_wt
  local good_ref bad_ref good_pr bad_pr first_line good_log tree staged record
  local before after first_refusal second_refusal
  if [ "${REHEARSAL_HYGIENE_DRILL:-1}" -eq 0 ]; then
    skip "hygiene: dirty worktree preservation and refusal (--no-hygiene-drill)"
    return 0
  fi

  slug="${repo//\//__}"
  stamp="$(date -u +%Y%m%d%H%M%S)-$$"
  # shellcheck disable=SC2016  # HOME belongs to the box
  box_home="$(bx 'printf %s "$HOME"')" || return 1
  good_branch="build/hygiene-$role"
  bad_branch="build/hygiene-refusal-$role"
  good_ref="wip/$good_branch"
  bad_ref="wip/$bad_branch"
  good_wt="$box_home/duty/trees/hygiene-$role"
  bad_wt="$box_home/duty/trees/hygiene-refusal-$role"
  REHEARSAL_HYGIENE_CLONE="$box_home/duty/work/$slug"
  REHEARSAL_HYGIENE_REFS="$good_ref $bad_ref"

  if ! bx "test -d '$REHEARSAL_HYGIENE_CLONE/.git' || gh repo clone '$repo' '$REHEARSAL_HYGIENE_CLONE' -- --quiet"; then
    fail "hygiene: sandbox main clone available"
    return 1
  fi
  ok "hygiene: sandbox main clone available"
  rehearsal_hygiene_cleanup
  REHEARSAL_HYGIENE_CLONE="$box_home/duty/work/$slug"
  REHEARSAL_HYGIENE_REFS="$good_ref $bad_ref"
  check "hygiene: prior fixture refs and worktrees are absent" bx \
    "! git -C '$REHEARSAL_HYGIENE_CLONE' ls-remote --exit-code origin \
       'refs/heads/$good_ref' 'refs/heads/$bad_ref' >/dev/null 2>&1 \
     && ! test -e '$good_wt' && ! test -e '$bad_wt'"
  rehearsal_hygiene_install_git_trace \
    || { fail "hygiene: git ordering trace installed"; return 1; }
  ok "hygiene: git ordering trace installed"

  if ! rehearsal_hygiene_fixture "$repo" "$good_branch" "$good_wt" "$stamp" \
      || ! good_pr="$(rehearsal_hygiene_close_fixture_pr "$repo" "$good_branch")" \
      || ! rehearsal_hygiene_add_dirt "$good_wt" "$stamp"; then
    fail "hygiene: preservation fixture staged"
    return 1
  fi
  ok "hygiene: preservation fixture carries tracked, root-untracked, nested-untracked and distinct staged work"
  first_line="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
  if rehearsal_hygiene_release "$repo" "$good_branch" "$good_wt" "$good_pr" \
      "\$HOME/duty/.rehearsal-hygiene-ledger" >/dev/null; then
    ok "hygiene: preserved dirty worktree released"
  else
    fail "hygiene: preserved dirty worktree released"
  fi
  good_log="$(bx "tail -n +$first_line ~/duty/duty.log")"
  tree="$(bx "git -C '$REHEARSAL_HYGIENE_CLONE' fetch -q origin \
      'refs/heads/$good_ref' \
    && git -C '$REHEARSAL_HYGIENE_CLONE' ls-tree -r --name-only FETCH_HEAD")" || tree=""
  check "hygiene: wip tip carries all three dirty-work shapes" \
    rehearsal_hygiene_tip_has_all_dirt "$tree"
  staged="$(bx "git -C '$REHEARSAL_HYGIENE_CLONE' show FETCH_HEAD^:README.md")" || staged=""
  check "hygiene: staged snapshot is the commit below the tip" bash -c \
    "[ \"\$1\" = 'staged $stamp' ]" _ "$staged"
  record="$(bx "gh api 'repos/$repo/issues/$good_pr/comments' --jq \
    '[.[] | select(.body | startswith(\"🗃️ Uncommitted work preserved\"))] | last | .body // \"\"'")" || record=""
  check "hygiene: upstream record names remote, ref and every dirty-work class" \
    rehearsal_hygiene_record_names_payload "$record" origin "$good_ref"
  check "hygiene: confirmed push precedes forced removal in duty.log" \
    rehearsal_hygiene_push_precedes_removal "$good_log"
  check "hygiene: worktree is gone only after preservation" bx "! test -e '$good_wt'"

  if ! rehearsal_hygiene_fixture "$repo" "$bad_branch" "$bad_wt" "$stamp-refusal" \
      || ! bad_pr="$(rehearsal_hygiene_close_fixture_pr "$repo" "$bad_branch")" \
      || ! rehearsal_hygiene_add_dirt "$bad_wt" "$stamp-refusal"; then
    fail "hygiene: refusal fixture staged"
    return 1
  fi
  ok "hygiene: refusal fixture staged"
  before="$(rehearsal_hygiene_box_snapshot "$bad_wt")" || before="snapshot-failed"
  bx "git -C '$REHEARSAL_HYGIENE_CLONE' remote add fork \
      'file:///rehearsal-hygiene-unwritable/$stamp.git'"
  first_refusal="$(rehearsal_hygiene_release "$repo" "$bad_branch" "$bad_wt" \
    "$bad_pr" "\$HOME/duty/.rehearsal-hygiene-refusal-ledger" 2>&1 || true)"
  second_refusal="$(rehearsal_hygiene_release "$repo" "$bad_branch" "$bad_wt" \
    "$bad_pr" "\$HOME/duty/.rehearsal-hygiene-refusal-ledger" 2>&1 || true)"
  after="$(rehearsal_hygiene_box_snapshot "$bad_wt")" || after="snapshot-failed-after"
  check "hygiene: failed push keeps README.md, hygiene-root-untracked.txt and hygiene-untracked/nested.txt, reported once" \
    rehearsal_hygiene_refusal_is_intact \
      "$before" "$after" "$first_refusal" "$second_refusal"
  check "hygiene: failed push lands no wip ref" bx \
    "! git -C '$REHEARSAL_HYGIENE_CLONE' ls-remote --exit-code fork \
       'refs/heads/$bad_ref' >/dev/null 2>&1"

  rehearsal_hygiene_cleanup
  check "hygiene: teardown removed fixture branches, refs and worktrees" bx \
    "! git -C '$box_home/duty/work/$slug' ls-remote --exit-code origin \
       'refs/heads/$good_ref' 'refs/heads/$bad_ref' \
       'refs/heads/$good_branch' 'refs/heads/$bad_branch' >/dev/null 2>&1 \
     && ! test -e '$good_wt' && ! test -e '$bad_wt'"
}
