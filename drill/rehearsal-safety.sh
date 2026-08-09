#!/usr/bin/env bash
# Safety interlocks for drill/rehearsal.sh. The caller supplies bx(), BOX_NAME,
# and REPOS_BACKUP; keeping these functions separate makes failure cleanup
# fixture-testable without a box or credentials.
# shellcheck disable=SC2088  # stored tildes expand inside the box via bx()

# A newline, named so the snapshot patterns below read as patterns.
REHEARSAL_NL=$'\n'
# Why the teardown comparison said no, in the words the round summary carries.
# Set beside each refusal so the notify verdict reports the actual state — a
# box that never answered is not a box that restored the wrong bytes.
REHEARSAL_TEARDOWN_REASON=""
# 1 once the pre-drill ~/duty/repos.txt has actually been copied aside. This is
# NOT the same fact as "REPOS_BACKUP is set": the handle is assigned before the
# copy runs, so a round whose `cp` failed carries one too. Teardown needs the
# copy, not the handle — a backup that was made and is then missing is a
# teardown failure, while a backup that was never made is nothing to vouch for,
# and only this flag tells those two apart (#423, round 3).
REHEARSAL_BACKUP_TAKEN=0

rehearsal_disarm_cron() {
  bx "if command -v crontab >/dev/null 2>&1; then
        tmp=\$(mktemp)
        crontab -l 2>/dev/null | grep -vF ~/duty/bin/tick.sh >\"\$tmp\" || true
        crontab \"\$tmp\"; rc=\$?
        rm -f \"\$tmp\"
        exit \"\$rc\"
      fi"
}

# The copy and the truncate are two box calls, not one `cp && : >`, so the
# round can record that the copy succeeded BEFORE anything overwrites the file
# it copied. Nothing truncates ~/duty/repos.txt until REHEARSAL_BACKUP_TAKEN is
# 1, which is the invariant rehearsal_cleanup reads.
rehearsal_begin_isolation() {
  REPOS_BACKUP="~/duty/repos.txt.pre-drill-$$"
  REHEARSAL_BACKUP_TAKEN=0
  bx "cp ~/duty/repos.txt $REPOS_BACKUP" || return 1
  REHEARSAL_BACKUP_TAKEN=1
  bx ": > ~/duty/repos.txt" &&
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

# --- reading a registry off the box, in the three states it can be in ------

# rehearsal_registry_snapshot PATH — read a file on the box and say which of
# the three things is true, because telling them apart is teardown's whole job:
#
#   prints `absent`               — the box says the file is not there
#   prints `present` + contents   — the box read it
#   returns non-zero              — the box did not answer at all
#
# The third state is why this exists. `bx "test -f X"` is a two-state read of
# a three-state world: a box that has gone away returns non-zero exactly like
# a box reporting an absent file, and the caller then takes the absent branch
# and vouches for a registry nobody looked at. Likewise `cat X || true` turns
# an unreadable file into the empty string, which compares equal to an empty
# pre-drill file. "The box did not say" is not "the file was not there", and
# neither of them is "read, and it was empty" (#423, round 2).
rehearsal_registry_snapshot() {
  local path="$1" out
  out="$(bx "if [ -e $path ]; then printf 'present\n'; cat $path; else printf 'absent\n'; fi")" \
    || return 1
  case "$out" in
    absent | present | present"$REHEARSAL_NL"*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# The two readers for a snapshot. A file that exists and is empty snapshots as
# exactly `present`, so the text is taken by stripping the marker line and
# never by anything that reads an empty remainder as a failure.
rehearsal_snapshot_present() { [ "${1%%"$REHEARSAL_NL"*}" = present ]; }
rehearsal_snapshot_text() {
  case "$1" in
    present"$REHEARSAL_NL"*) printf '%s' "${1#present"$REHEARSAL_NL"}" ;;
  esac
}

# rehearsal_work_registry_matches_pre_drill STATE PRE_TEXT RESTORE_FAILED —
# repos.txt on the box, after the restore, against the bytes the backup held
# before it was moved. Nothing was backed up ⇒ nothing to vouch for; anything
# the box would not answer ⇒ NOT a pass, because the criterion is a comparison
# and a comparison nobody could make is not one. A backup this round MADE and
# cannot now find is the third thing again: the box was left holding whatever
# the drill put there, and no pre-drill bytes survive to compare it with.
rehearsal_work_registry_matches_pre_drill() {
  local state="$1" expected="$2" restore_failed="${3:-0}" snap
  REHEARSAL_TEARDOWN_REASON=""
  case "$state" in
    none) return 0 ;;
    absent)
      [ "$restore_failed" -eq 0 ] && return 0
      REHEARSAL_TEARDOWN_REASON="teardown could not restore repos.txt"
      echo "TEARDOWN: ~/duty/repos.txt could not be restored" >&2
      return 1
      ;;
    lost)
      REHEARSAL_TEARDOWN_REASON="teardown could not find the pre-drill repos.txt backup this round made"
      echo "TEARDOWN: the pre-drill repos.txt backup this round made is gone; ~/duty/repos.txt is unvouched for" >&2
      return 1
      ;;
    unanswerable)
      REHEARSAL_TEARDOWN_REASON="teardown could not read the pre-drill repos.txt backup"
      echo "TEARDOWN: the box did not say whether the pre-drill repos.txt backup was there; ~/duty/repos.txt is unvouched for" >&2
      return 1
      ;;
  esac
  if [ "$restore_failed" -ne 0 ]; then
    REHEARSAL_TEARDOWN_REASON="teardown could not restore repos.txt"
    echo "TEARDOWN: ~/duty/repos.txt could not be restored" >&2
    return 1
  fi
  if ! snap="$(rehearsal_registry_snapshot "~/duty/repos.txt")"; then
    REHEARSAL_TEARDOWN_REASON="teardown could not read repos.txt back"
    echo "TEARDOWN: ~/duty/repos.txt could not be read back after the restore" >&2
    return 1
  fi
  if ! rehearsal_snapshot_present "$snap"; then
    REHEARSAL_TEARDOWN_REASON="teardown left no repos.txt at all"
    echo "TEARDOWN: ~/duty/repos.txt is not there after the restore" >&2
    return 1
  fi
  [ "$(rehearsal_snapshot_text "$snap")" = "$expected" ] && return 0
  REHEARSAL_TEARDOWN_REASON="teardown left repos.txt unlike its pre-drill contents"
  echo "TEARDOWN: ~/duty/repos.txt differs from its pre-drill contents" >&2
  return 1
}

rehearsal_cleanup() {
  local rc="${1:-$?}"
  local repos_state=none repos_pre="" snap
  local repos_restore_failed=0 notify_restore_failed=0
  # The pre-drill bytes, read BEFORE the restore moves the backup away. The
  # restore is then asserted by COMPARISON and never by having exited 0: a
  # command that succeeds against the wrong bytes leaves the box working or
  # watching a set nobody chose, while the round reports a clean teardown.
  #
  # Three states, not two. This probe used to be `bx "test -f $REPOS_BACKUP"`,
  # so a box that stopped answering mid-teardown read as "there was no backup"
  # and the comparison below returned success having compared nothing.
  #
  # And the `absent` answer is itself two facts, told apart by whether the copy
  # was ever taken. A round that copied the fleet registry aside and truncated
  # the original has a backup by construction; the box answering "not there"
  # then measures a LOSS, and vouching for repos.txt on that answer is the same
  # fail-open in a state the box positively reported (#423, round 3).
  if [ -n "${REPOS_BACKUP:-}" ]; then
    if snap="$(rehearsal_registry_snapshot "$REPOS_BACKUP")"; then
      if rehearsal_snapshot_present "$snap"; then
        repos_state=present
        repos_pre="$(rehearsal_snapshot_text "$snap")"
      elif [ "${REHEARSAL_BACKUP_TAKEN:-0}" -eq 1 ]; then
        repos_state=lost
      else
        repos_state=absent
      fi
    else
      repos_state=unanswerable
    fi
  fi
  # Both registries, one step. The notifier half is restored FIRST because a
  # box left watching a sandbox that teardown then deletes is the same class
  # of leftover as a box left working one — and the pairing is why #423 put
  # the restore here rather than in a leg that only runs when it runs.
  #
  # A failed restore is recorded, not merely printed: it is the strongest
  # evidence there is that the registry is NOT back, and the comparison below
  # takes it as an input. A warning on stderr reaches nobody.
  if declare -F rehearsal_notify_restore_registry >/dev/null 2>&1; then
    rehearsal_notify_restore_registry || {
      notify_restore_failed=1
      echo "WARNING: could not restore the pre-drill notify-repos.txt; stop the box: box down $BOX_NAME" >&2
    }
  fi
  if [ -n "${REPOS_BACKUP:-}" ]; then
    bx "if [ -f $REPOS_BACKUP ]; then mv $REPOS_BACKUP ~/duty/repos.txt; fi" || {
      repos_restore_failed=1
      echo "WARNING: could not restore the pre-drill repos.txt; stop the box: box down $BOX_NAME" >&2
    }
  fi
  # Both compared, after both restores have run, absent-before ⇒ absent-after
  # included. A mismatch controls the drill's verdict: cleanup_all takes this
  # return into the EXIT trap's exit status, so a box left holding the wrong
  # registry reds the round instead of being a warning nobody reads.
  if ! rehearsal_work_registry_matches_pre_drill \
      "$repos_state" "$repos_pre" "$repos_restore_failed"; then
    rc=1
    declare -F rehearsal_notify_verdict >/dev/null 2>&1 \
      && rehearsal_notify_verdict fail "${REHEARSAL_TEARDOWN_REASON:-teardown left repos.txt unlike its pre-drill contents}"
  fi
  if declare -F rehearsal_notify_registry_matches_pre_drill >/dev/null 2>&1 \
      && ! rehearsal_notify_registry_matches_pre_drill "$notify_restore_failed"; then
    rc=1
    rehearsal_notify_verdict fail "${REHEARSAL_TEARDOWN_REASON:-teardown left notify-repos.txt unlike its pre-drill contents}"
  fi
  rehearsal_disarm_cron \
    || echo "WARNING: could not disarm the drill cron; stop the box: box down $BOX_NAME" >&2
  return "$rc"
}
