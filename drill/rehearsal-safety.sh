#!/usr/bin/env bash
# Safety interlocks for drill/rehearsal.sh. The caller supplies bx(), BOX_NAME,
# and REPOS_BACKUP; keeping these functions separate makes failure cleanup
# fixture-testable without a box or credentials.
# shellcheck disable=SC2088  # stored tildes expand inside the box via bx()

rehearsal_disarm_cron() {
  bx "if command -v crontab >/dev/null 2>&1; then
        tmp=\$(mktemp)
        crontab -l 2>/dev/null | grep -vF ~/duty/bin/tick.sh >\"\$tmp\" || true
        crontab \"\$tmp\"; rc=\$?
        rm -f \"\$tmp\"
        exit \"\$rc\"
      fi"
}

rehearsal_begin_isolation() {
  REPOS_BACKUP="~/duty/repos.txt.pre-drill-$$"
  bx "cp ~/duty/repos.txt $REPOS_BACKUP && : > ~/duty/repos.txt" &&
    bx "test ! -s ~/duty/repos.txt"
}

rehearsal_narrow_to_sandbox() {
  local sandbox="$1"
  bx "printf '%s\n' '$sandbox' > ~/duty/repos.txt" &&
    bx "[ \"\$(wc -l < ~/duty/repos.txt)\" -eq 1 ] && grep -qxF '$sandbox' ~/duty/repos.txt"
}

# rehearsal_attention_is_clear SANDBOX — print any parked attention demand this
# box would pick up from OUTSIDE the sandbox. Empty output means clear.
#
# Narrowing repos.txt scopes review, build, triage and hygiene — every module
# that reads REPOS_FILE. It does NOT scope ATTENTION, which runs first and for
# every role: duty-attention.sh reads the authenticated-user issues endpoint on
# purpose ("cross-repo, no search index, reaches repos not in repos.txt"), so
# an open issue assigned to this box's identity and carrying the `attention`
# label is a demand it will act on wherever it lives. The drill box borrows a
# fleet identity, so a real parked demand for that identity is exactly the
# thing at risk.
#
# So the interlock asserting "repos.txt contains only the sandbox" is TRUE and,
# for this surface, not sufficient — which is the worst combination, because it
# reads like coverage (#52). repos.txt cannot be made to scope attention; the
# honest containment is to check there is nothing outside the sandbox to pick
# up, and refuse the tick if there is. That is a check, not a claim.
rehearsal_attention_is_clear() {
  local sandbox="$1"
  bx "gh api '/issues?filter=assigned&state=open&labels=attention&per_page=100' \
        --jq '.[].repository.full_name' 2>/dev/null \
      | grep -vxF '$sandbox' || true"
}

# rehearsal_work_registry_matches_pre_drill HAD_BACKUP PRE_TEXT — repos.txt on
# the box, after the restore, against the bytes the backup held before it was
# moved. Nothing was backed up ⇒ nothing to vouch for.
rehearsal_work_registry_matches_pre_drill() {
  local had="$1" expected="$2" actual
  [ "$had" -eq 1 ] || return 0
  actual="$(bx "cat ~/duty/repos.txt 2>/dev/null || true")"
  [ "$actual" = "$expected" ] && return 0
  echo "TEARDOWN: ~/duty/repos.txt differs from its pre-drill contents" >&2
  return 1
}

rehearsal_cleanup() {
  local rc="${1:-$?}"
  local repos_had=0 repos_pre=""
  # The pre-drill bytes, read BEFORE the restore moves the backup away. The
  # restore is then asserted by COMPARISON and never by having exited 0: a
  # command that succeeds against the wrong bytes leaves the box working or
  # watching a set nobody chose, while the round reports a clean teardown.
  if [ -n "${REPOS_BACKUP:-}" ] && bx "test -f $REPOS_BACKUP"; then
    repos_had=1
    repos_pre="$(bx "cat $REPOS_BACKUP 2>/dev/null || true")"
  fi
  # Both registries, one step. The notifier half is restored FIRST because a
  # box left watching a sandbox that teardown then deletes is the same class
  # of leftover as a box left working one — and the pairing is why #423 put
  # the restore here rather than in a leg that only runs when it runs.
  if declare -F rehearsal_notify_restore_registry >/dev/null 2>&1; then
    rehearsal_notify_restore_registry \
      || echo "WARNING: could not restore the pre-drill notify-repos.txt; stop the box: box down $BOX_NAME" >&2
  fi
  if [ -n "${REPOS_BACKUP:-}" ]; then
    bx "if [ -f $REPOS_BACKUP ]; then mv $REPOS_BACKUP ~/duty/repos.txt; fi" \
      || echo "WARNING: could not restore the pre-drill repos.txt; stop the box: box down $BOX_NAME" >&2
  fi
  # Both compared, after both restores have run, absent-before ⇒ absent-after
  # included. A mismatch controls the drill's verdict: cleanup_all takes this
  # return into the EXIT trap's exit status, so a box left holding the wrong
  # registry reds the round instead of being a warning nobody reads.
  if ! rehearsal_work_registry_matches_pre_drill "$repos_had" "$repos_pre"; then
    rc=1
    declare -F rehearsal_notify_verdict >/dev/null 2>&1 \
      && rehearsal_notify_verdict fail "teardown left repos.txt unlike its pre-drill contents"
  fi
  if declare -F rehearsal_notify_registry_matches_pre_drill >/dev/null 2>&1 \
      && ! rehearsal_notify_registry_matches_pre_drill; then
    rc=1
    rehearsal_notify_verdict fail "teardown left notify-repos.txt unlike its pre-drill contents"
  fi
  rehearsal_disarm_cron \
    || echo "WARNING: could not disarm the drill cron; stop the box: box down $BOX_NAME" >&2
  return "$rc"
}
