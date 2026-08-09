#!/usr/bin/env bash
# Sourceable notifier-union helpers for drill/rehearsal.sh. The live leg runs
# from phase 2, after the safety interlock has passed; every predicate it
# reads with stays here so CI can mutate their inputs without a drill host.
#
# What the leg is for: since #316 the operator's watch set is
# `repos.txt ∪ notify-repos.txt`, where the second file used to SHADOW the
# first. The regression that change fixed is invisible by construction — its
# only evidence is a notification that did not arrive — so the union is
# asserted in BOTH directions on one notify run. Asserting the
# notify-repos.txt half alone would pass the exact pre-#316 bug, which got the
# notify list right and dropped the work list.
#
# The leg widens the WATCH set and never the WORK set. repos.txt is the scope
# for review, build, triage and hygiene, and the phase 2 interlock exists to
# hold it at one sandbox; a leg that widened it would defeat the containment
# the drill is there to keep. So repos.txt is re-read after notify-repos.txt
# is written and the round aborts if it moved.
# shellcheck disable=SC2088  # tildes in bx "…" strings expand in the BOX's
# login shell, which is exactly where those paths live

# rehearsal_registry_snapshot and its two readers live in rehearsal-safety.sh,
# which rehearsal.sh sources first. Sourced on its own — CI's fixtures do that,
# and so does anyone reading this file — pull it in rather than let a missing
# helper be the reason this file cannot be exercised alone. Definitions only,
# so a second source is a no-op.
if ! declare -F rehearsal_registry_snapshot >/dev/null 2>&1; then
  # shellcheck source=drill/rehearsal-safety.sh
  . "$(dirname "${BASH_SOURCE[0]}")/rehearsal-safety.sh"
fi

# Set by rehearsal_notify_write_registry, read by the restore below and by
# rehearsal_cleanup, which restores both registries in one step.
REHEARSAL_NOTIFY_BACKUP=""
REHEARSAL_NOTIFY_ABSENT=0
# "<repo> <pr>" per line, so a run killed mid-leg does not leave a handoff
# fixture open — the builder block's slot check reads open PRs, and on a host
# whose gh identity is also the box's these would occupy it.
REHEARSAL_NOTIFY_FIXTURES=""
# The pre-drill notify-repos.txt, captured before the leg writes over it, so
# rehearsal_cleanup can compare the RESTORED file against it rather than
# trusting that the restore command exited 0. CAPTURED distinguishes "the file
# was empty before the drill" from "the leg never got far enough to look",
# which an empty PRE_TEXT cannot: only the first is something to vouch for.
REHEARSAL_NOTIFY_PRE_TEXT=""
REHEARSAL_NOTIFY_CAPTURED=0

# --- the leg's own verdict ------------------------------------------------

# The round summary cannot read this leg's outcome off the role's exit code.
# rehearsal_notify_drill returns 0 both when the union is asserted and when the
# operator channel is unreachable and the leg skips, and the role's rc moves
# for reasons that have nothing to do with the leg — so rehearsal-all.sh
# printed `ok notify` for a round that asserted nothing, and `FAIL notify` for
# a role that failed somewhere else entirely. The leg writes its own verdict
# where the summary reads it, and the summary folds THAT.
#
# rehearsal_notify_verdict <ok|skip|fail> [reason] — appended, never
# overwritten: worst-wins across the lines is what the fold below is for, and
# an append cannot lose an earlier failure to a later assertion's pass.
rehearsal_notify_verdict() {
  local verdict="$1" reason="${2:-}"
  [ -n "${REHEARSAL_NOTIFY_STATUS:-}" ] || return 0
  printf '%s %s %s\n' "${ROLE:-unknown}" "$verdict" "$reason" \
    >>"$REHEARSAL_NOTIFY_STATUS" 2>/dev/null || true
  return 0
}

# rehearsal_notify_worst_verdict VERDICT_TEXT — the ROUND's notify verdict,
# folded from the per-role lines. Worst wins: the leg is role-independent, so
# one box that could not assert the union is the round's answer however green
# the others were, exactly as the role loop already treats one red box.
# Prints "<verdict> <reason>"; returns 1 when no role wrote a verdict at all,
# which is phase 2 never reaching the leg and is reported as INCOMPLETE, never
# as a pass. An unreadable verdict token grades as `fail` for the same reason:
# a line the summary cannot classify is not evidence that anything passed.
rehearsal_notify_worst_verdict() {
  local role verdict reason rank best="" best_reason="" best_rank=0
  while read -r role verdict reason; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      ok)   rank=1 ;;
      skip) rank=2 ;;
      *)    rank=3; verdict=fail ;;
    esac
    if [ "$rank" -gt "$best_rank" ]; then
      best_rank="$rank"; best="$verdict"; best_reason="$reason"
    fi
  done <<<"$1"
  [ -n "$best" ] || return 1
  printf '%s %s\n' "$best" "$best_reason"
}

# --- pure predicates ------------------------------------------------------

# rehearsal_notify_last_run_from_log LOG_TEXT — the last COMPLETE notify run
# in the text, "notify run start" through "notify run end". Empty when no run
# finished. Slicing is what makes "on the same tick" an assertion rather than
# a hope: two notifications a tick apart satisfy every per-repo grep.
rehearsal_notify_last_run_from_log() {
  awk '
    index($0, "notify run start") { active = 1; buf = "" }
    active { buf = buf $0 "\n" }
    index($0, "notify run end") { if (active) { last = buf; active = 0 } }
    END { printf "%s", last }
  ' <<<"$1"
}

# rehearsal_notify_delivered_from_log REPO PR LOG_TEXT — did the notifier
# announce this PR to the operator? A message id, not "(msg none)": the
# criterion is that the notification REACHED the channel, and a failed send
# still writes the sweep's line.
rehearsal_notify_delivered_from_log() {
  local repo="$1" pr="$2" log_text="$3" line
  line="$(grep -F "$repo#$pr: notified needs-human at " <<<"$log_text" | tail -n 1)"
  [ -n "$line" ] || return 1
  grep -qE '\(msg [0-9]+\)$' <<<"$line"
}

# rehearsal_notify_union_from_log WORK_REPO WORK_PR NOTIFY_REPO NOTIFY_PR LOG_TEXT
# Both halves of the watch set, on one run. Names the missing repository and
# returns 5 for the repos.txt half (the half the old bug dropped), 6 for the
# notify-repos.txt half, 7 for neither.
rehearsal_notify_union_from_log() {
  local work_repo="$1" work_pr="$2" notify_repo="$3" notify_pr="$4" log_text="$5"
  local run work=0 extra=0
  run="$(rehearsal_notify_last_run_from_log "$log_text")"
  if [ -z "$run" ]; then
    echo "notify union: no complete notify run in the log slice — nothing to read a union from" >&2
    return 7
  fi
  rehearsal_notify_delivered_from_log "$work_repo" "$work_pr" "$run" && work=1
  rehearsal_notify_delivered_from_log "$notify_repo" "$notify_pr" "$run" && extra=1
  [ "$work" -eq 1 ] || echo "notify union: $work_repo#$work_pr (repos.txt half) never reached the operator on this run — the pre-#316 shadowing bug drops exactly this half" >&2
  [ "$extra" -eq 1 ] || echo "notify union: $notify_repo#$notify_pr (notify-repos.txt half) never reached the operator on this run" >&2
  if [ "$work" -eq 1 ] && [ "$extra" -eq 1 ]; then return 0; fi
  if [ "$work" -eq 1 ]; then return 6; fi
  if [ "$extra" -eq 1 ]; then return 5; fi
  return 7
}

# rehearsal_notify_watch_set_is_from_log COUNT LOG_TEXT — the notifier's own
# count of the set it swept. Two sandboxes and nothing else is the containment
# assertion: a fleet repository surviving in notify-repos.txt shows up here
# and nowhere else in this leg.
rehearsal_notify_watch_set_is_from_log() {
  local expected="$1" log_text="$2" run
  run="$(rehearsal_notify_last_run_from_log "$log_text")"
  [ -n "$run" ] || return 1
  grep -Fq "sweep done — $expected repos," <<<"$run"
}

# rehearsal_notify_work_registry_intact SANDBOX BEFORE_TEXT AFTER_TEXT — the
# interlock, re-asserted rather than bypassed. The union must widen
# notifications and nothing else, so repos.txt must be byte-identical to what
# the interlock left AND still name only the work sandbox. Returns 5 when the
# file moved, 6 when it names something other than the one sandbox.
rehearsal_notify_work_registry_intact() {
  local sandbox="$1" before="$2" after="$3"
  if [ "$before" != "$after" ]; then
    echo "notify: repos.txt changed while notify-repos.txt was written — the watch set may widen, the work set never" >&2
    echo "  before: $(printf '%s' "$before" | tr '\n' ' ')" >&2
    echo "  after:  $(printf '%s' "$after" | tr '\n' ' ')" >&2
    return 5
  fi
  if [ "$(grep -c . <<<"$after")" -ne 1 ] || ! grep -qxF "$sandbox" <<<"$after"; then
    echo "notify: repos.txt no longer names only the work sandbox $sandbox" >&2
    echo "  contents: $(printf '%s' "$after" | tr '\n' ' ')" >&2
    return 6
  fi
  return 0
}

# rehearsal_notify_candidate_is_safe CANDIDATE WORK_SANDBOX PRE_DRILL_TEXT —
# the interlock's rule applied to the second file. The notify sandbox must be
# an owner/repo slug this run minted: never the work sandbox (a union of one
# repository asserts nothing), and never anything the host's pre-drill
# registries already named, which is where the real fleet lives. Returns 5,
# 6 or 7 for the three refusals, in that order.
rehearsal_notify_candidate_is_safe() {
  local candidate="$1" work="$2" pre_drill="$3" malformed=1
  # The same slug shape teardown.sh refuses on, for the same reason: a name
  # that is not owner/repo cannot be reasoned about at all.
  case "$candidate" in
    */*/*|/*|*/) malformed=1 ;;
    */*) malformed=0 ;;
    *) malformed=1 ;;
  esac
  if [ "$malformed" -eq 1 ]; then
    echo "notify: '$candidate' is not an <owner>/<repo> slug — refusing to write it to notify-repos.txt" >&2
    return 5
  fi
  if [ "$candidate" = "$work" ]; then
    echo "notify: the notify sandbox and the work sandbox are both $candidate — a union of one repository asserts nothing" >&2
    return 6
  fi
  if grep -qxF "$candidate" <<<"$pre_drill"; then
    echo "notify: $candidate is named in this host's pre-drill registry — the notify half must be a sandbox this run minted, never a repository the fleet works" >&2
    return 7
  fi
  return 0
}

# --- the box side ---------------------------------------------------------

# The operator channel, probed where the engine writes it rather than by
# intercepting a network call. Prints one word: ok, no-credentials,
# unreachable, or rejected.
rehearsal_notify_channel_status() {
  # shellcheck disable=SC2016  # every expansion below is the box's
  bx '
    if [ ! -r "$HOME/.tg_bot_token" ] || [ ! -r "$HOME/.tg_chat_id" ]; then
      printf "no-credentials\n"; exit 0
    fi
    tok="$(cat "$HOME/.tg_bot_token")"
    if ! resp="$(curl -sS -m 15 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null)"; then
      printf "unreachable\n"; exit 0
    fi
    if printf "%s" "$resp" | jq -e ".ok == true" >/dev/null 2>&1; then
      printf "ok\n"
    else
      printf "rejected\n"
    fi
  ' 2>/dev/null | tr -d '\r' | tail -n 1
}

# The handoff label comes from the installed configuration, never retyped
# here: a label rename in the engine must move this assertion with it instead
# of silently changing its subject.
rehearsal_notify_load_installed_handoff_label() {
  local label
  REHEARSAL_NOTIFY_LABEL=""
  # shellcheck disable=SC2016  # the label variable expands inside the box
  if ! label="$(bx '
    set -a
    . ~/duty/conf/fleet.defaults.conf
    printf "%s\n" "$LABEL_NEEDS_HUMAN"
  ' | tr -d '\r' | sed '/^$/d' | head -1)" || [ -z "$label" ]; then
    fail "notify: installed handoff label resolves"
    return 1
  fi
  REHEARSAL_NOTIFY_LABEL="$label"
  ok "notify: installed handoff label resolves"
}

rehearsal_notify_read_work_registry() { bx "cat ~/duty/repos.txt 2>/dev/null || true"; }

# Everything the host pointed this box at before the drill: the interlock's
# backup of repos.txt plus whatever notify-repos.txt shipped with — which on a
# real box names the fleet. Both are forbidden as the notify half, and this
# must be read before either file is written.
rehearsal_notify_pre_drill_registry() {
  bx "cat ${REPOS_BACKUP:-/dev/null} ~/duty/notify-repos.txt 2>/dev/null || true"
}

# Back up notify-repos.txt and REPLACE it with the one sandbox. Replace, not
# append: the file a real box ships with names the fleet, and a drill that
# left those lines standing would sweep production repositories on its own
# tick.
rehearsal_notify_write_registry() {
  local sandbox="$1" snap
  REHEARSAL_NOTIFY_BACKUP="~/duty/notify-repos.txt.pre-drill-$$"
  # Three-state, because the absent branch becomes an `rm -f` at teardown: a
  # probe the box did not answer must never license deleting the operator's
  # real notify-repos.txt. Unanswerable ⇒ write nothing and say so; there is
  # then no backup to restore and nothing for teardown to vouch for.
  if ! snap="$(rehearsal_registry_snapshot "~/duty/notify-repos.txt")"; then
    REHEARSAL_NOTIFY_BACKUP=""
    return 1
  fi
  if rehearsal_snapshot_present "$snap"; then
    REHEARSAL_NOTIFY_ABSENT=0
    bx "cp ~/duty/notify-repos.txt $REHEARSAL_NOTIFY_BACKUP" || return 1
  else
    REHEARSAL_NOTIFY_ABSENT=1
  fi
  bx "printf '%s\n' '$sandbox' > ~/duty/notify-repos.txt" \
    && bx "[ \"\$(wc -l < ~/duty/notify-repos.txt)\" -eq 1 ] && grep -qxF '$sandbox' ~/duty/notify-repos.txt"
}

# Restore, in the same step that restores the box's registry (rehearsal_cleanup
# calls this). Absent before the drill means absent after it — a file this leg
# created is not a pre-drill state to preserve.
rehearsal_notify_restore_registry() {
  [ -n "$REHEARSAL_NOTIFY_BACKUP" ] || return 0
  if [ "$REHEARSAL_NOTIFY_ABSENT" -eq 1 ]; then
    bx "rm -f ~/duty/notify-repos.txt" || return 1
  else
    bx "if [ -f $REHEARSAL_NOTIFY_BACKUP ]; then mv $REHEARSAL_NOTIFY_BACKUP ~/duty/notify-repos.txt; fi" || return 1
  fi
  REHEARSAL_NOTIFY_BACKUP=""
  return 0
}

# rehearsal_notify_registries_restored WORK_SANDBOX PRE_DRILL_NOTIFY_TEXT —
# asserted by comparison, not by having called the restore: the pre-drill
# notify-repos.txt must be back byte for byte (or gone, where there was none),
# and repos.txt must still be the interlock's one line.
rehearsal_notify_registries_restored() {
  local sandbox="$1" expected="$2" actual
  if [ "$REHEARSAL_NOTIFY_ABSENT" -eq 1 ]; then
    bx "! test -e ~/duty/notify-repos.txt" || return 1
  else
    actual="$(bx "cat ~/duty/notify-repos.txt 2>/dev/null || true")"
    [ "$actual" = "$expected" ] || return 1
  fi
  actual="$(rehearsal_notify_read_work_registry)"
  [ "$(grep -c . <<<"$actual")" -eq 1 ] && grep -qxF "$sandbox" <<<"$actual"
}

# rehearsal_notify_registry_matches_pre_drill — notify-repos.txt AFTER
# rehearsal_cleanup's restore, compared with the bytes it carried before the
# leg wrote over it. The in-leg rehearsal_notify_registries_restored above runs
# where the leg still can report; this one runs where the round actually ends,
# and it exists because a restore command that exits 0 having moved the wrong
# bytes leaves a box watching a set nobody chose while the drill reports a
# clean teardown. Absent before the drill means absent after it. A leg that
# never captured has nothing to vouch for and passes.
rehearsal_notify_registry_matches_pre_drill() {
  local restore_failed="${1:-0}" snap
  REHEARSAL_TEARDOWN_REASON=""
  [ "${REHEARSAL_NOTIFY_CAPTURED:-0}" -eq 1 ] || return 0
  if [ "$restore_failed" -ne 0 ]; then
    REHEARSAL_TEARDOWN_REASON="teardown could not restore notify-repos.txt"
    echo "TEARDOWN: ~/duty/notify-repos.txt could not be restored" >&2
    return 1
  fi
  if ! snap="$(rehearsal_registry_snapshot "~/duty/notify-repos.txt")"; then
    REHEARSAL_TEARDOWN_REASON="teardown could not read notify-repos.txt back"
    echo "TEARDOWN: ~/duty/notify-repos.txt could not be read back after the restore" >&2
    return 1
  fi
  if [ "${REHEARSAL_NOTIFY_ABSENT:-0}" -eq 1 ]; then
    rehearsal_snapshot_present "$snap" || return 0
    REHEARSAL_TEARDOWN_REASON="teardown left notify-repos.txt behind; the box had none before the drill"
    echo "TEARDOWN: ~/duty/notify-repos.txt is still in place; the box had none before the drill" >&2
    return 1
  fi
  if ! rehearsal_snapshot_present "$snap"; then
    REHEARSAL_TEARDOWN_REASON="teardown left no notify-repos.txt where the box had one"
    echo "TEARDOWN: ~/duty/notify-repos.txt is not there after the restore" >&2
    return 1
  fi
  [ "$(rehearsal_snapshot_text "$snap")" = "$REHEARSAL_NOTIFY_PRE_TEXT" ] && return 0
  REHEARSAL_TEARDOWN_REASON="teardown left notify-repos.txt unlike its pre-drill contents"
  echo "TEARDOWN: ~/duty/notify-repos.txt differs from its pre-drill contents" >&2
  return 1
}

rehearsal_notify_tick() { bx "~/duty/bin/tick.sh notify"; }

rehearsal_notify_log() {
  local first_line="$1"
  bx "tail -n +$first_line ~/duty/notify.log 2>/dev/null || true"
}

rehearsal_notify_log_lines() { bx "wc -l < ~/duty/notify.log 2>/dev/null || echo 0"; }

# --- the fixtures ---------------------------------------------------------

# A notifiable event is an open, non-draft PR carrying the handoff label and
# no blocker — the notifier's one and only trigger. Prints "<pr>".
rehearsal_notify_stage_handoff_pr() {
  local repo="$1" slug="$2" label="$3" main_sha branch pr
  main_sha="$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)" || return 1
  branch="drill-notify-$slug"
  gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main_sha" >/dev/null || return 1
  gh api -X PUT "repos/$repo/contents/drill-notify.txt" \
    -f message="drill: notifiable change" -f branch="$branch" \
    -f content="$(printf 'drill notify %s\n' "$slug" | base64 -w0)" >/dev/null || return 1
  pr="$(gh api "repos/$repo/pulls" -f title="drill: handoff fixture" -f head="$branch" \
    -f base=main -f body="Drill fixture for the notifier union. Nobody reviews this." \
    --jq .number)" || return 1
  # The label must exist before it can be applied; the sandbox vocabulary is
  # created by hand for exactly this reason.
  gh api "repos/$repo/labels" -f name="$label" -f color=0e8a16 >/dev/null 2>&1 || true
  gh api "repos/$repo/issues/$pr/labels" -f "labels[]=$label" >/dev/null || return 1
  printf '%s\n' "$pr"
}

# The caller records the fixture, never this function: it is read through a
# command substitution, and a subshell's assignment to the cleanup list would
# be lost exactly where the cleanup matters.
rehearsal_notify_record_fixture() {
  REHEARSAL_NOTIFY_FIXTURES="$REHEARSAL_NOTIFY_FIXTURES$1 $2
"
}

# Closing the fixtures is also what resolves them in the operator's chat: the
# next pass edits each 🟣 row to its ✖ CLOSED form, so the leg leaves no live
# handoff behind in a channel a human reads.
rehearsal_notify_close_fixtures() {
  local repo pr failed=0
  [ -n "$REHEARSAL_NOTIFY_FIXTURES" ] || return 0
  while read -r repo pr; do
    [ -n "$pr" ] || continue
    gh api -X PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null \
      || { echo "notify: WARNING — could not close handoff fixture $repo#$pr" >&2; failed=1; }
  done <<<"$REHEARSAL_NOTIFY_FIXTURES"
  REHEARSAL_NOTIFY_FIXTURES=""
  return "$failed"
}

# --- the leg --------------------------------------------------------------

# rehearsal_notify_drill WORK_SANDBOX HOST_IDENTITY ROLE
#
# Returns 0 when the leg ran or skipped, and 2 when the interlock it
# re-asserts has failed — the caller aborts the round there rather than
# continuing with a work registry nobody can vouch for.
rehearsal_notify_drill() {
  local work="$1" host="$2" role="$3"
  local notify_sandbox channel pre_drill before after label
  local work_pr="" notify_pr="" first log_text pre_notify_text="" notify_snap=""
  local union_rc

  if [ "${REHEARSAL_NOTIFY_DRILL:-1}" -eq 0 ]; then
    skip "notify: union over repos.txt and notify-repos.txt (--no-notify-drill)"
    rehearsal_notify_verdict skip "--no-notify-drill"
    return 0
  fi

  channel="$(rehearsal_notify_channel_status)"
  if [ "$channel" != ok ]; then
    skip "notify: union over repos.txt and notify-repos.txt (operator channel unreachable on this host: ${channel:-unknown})"
    rehearsal_notify_verdict skip "operator channel unreachable: ${channel:-unknown}"
    return 0
  fi
  ok "notify: operator channel reachable from the drill box"

  rehearsal_notify_load_installed_handoff_label \
    || { rehearsal_notify_verdict fail "installed handoff label does not resolve"; return 0; }
  label="$REHEARSAL_NOTIFY_LABEL"

  # `crew-drill-<role>-notify`, which teardown.sh removes by exact name. A
  # round on a fresh box mints it; a --reuse round finds the previous round's
  # and says so rather than reporting a mint that did not happen.
  notify_sandbox="$host/crew-drill-$role-notify"
  if gh repo view "$notify_sandbox" >/dev/null 2>&1; then
    echo "notify: $notify_sandbox stands from an earlier round — reusing it; teardown removes it"
  elif ! gh repo create "$notify_sandbox" --public --add-readme >/dev/null; then
    fail "notify: the drill's own second sandbox is in place for the notify half"
    rehearsal_notify_verdict fail "the notify half's sandbox could not be minted"
    return 0
  fi
  ok "notify: the drill's own second sandbox is in place for the notify half"

  # Captured through the three-state read, so an unreadable file cannot enter
  # the round as empty bytes: teardown would then compare the restored fleet
  # registry against "" and pass. CAPTURED is set only once the box has
  # actually answered — it is the flag that says there is something to vouch
  # for, and it must not be set by a read that failed.
  if ! notify_snap="$(rehearsal_registry_snapshot "~/duty/notify-repos.txt")"; then
    fail "notify: the box could not be asked what notify-repos.txt held before the drill"
    rehearsal_notify_verdict fail "the pre-drill notify-repos.txt could not be read"
    return 0
  fi
  pre_notify_text="$(rehearsal_snapshot_text "$notify_snap")"
  REHEARSAL_NOTIFY_PRE_TEXT="$pre_notify_text"
  REHEARSAL_NOTIFY_CAPTURED=1
  before="$(rehearsal_notify_read_work_registry)"
  pre_drill="$(rehearsal_notify_pre_drill_registry)"
  if rehearsal_notify_candidate_is_safe "$notify_sandbox" "$work" "$pre_drill"; then
    ok "notify: the notify half is a sandbox this run minted, not a repository the fleet works"
  else
    fail "notify: the notify half is a sandbox this run minted, not a repository the fleet works"
    rehearsal_notify_verdict fail "the notify candidate is not a sandbox this run may name"
    return 0
  fi

  if rehearsal_notify_write_registry "$notify_sandbox"; then
    ok "notify: notify-repos.txt names only the second sandbox"
  else
    fail "notify: notify-repos.txt names only the second sandbox"
    rehearsal_notify_verdict fail "notify-repos.txt could not be narrowed to the second sandbox"
    return 0
  fi

  after="$(rehearsal_notify_read_work_registry)"
  if rehearsal_notify_work_registry_intact "$work" "$before" "$after"; then
    ok "notify: repos.txt unchanged — the union widened the watch set and not the work set"
  else
    fail "notify: repos.txt unchanged — the union widened the watch set and not the work set"
    rehearsal_notify_verdict fail "repos.txt widened while the union was being staged"
    return 2
  fi

  if work_pr="$(rehearsal_notify_stage_handoff_pr "$work" "work-$(date -u +%H%M%S)" "$label")" \
      && [ -n "$work_pr" ]; then
    rehearsal_notify_record_fixture "$work" "$work_pr"
    ok "notify: handoff fixture staged in the repos.txt sandbox"
  else
    work_pr=""
    fail "notify: handoff fixture staged in the repos.txt sandbox"
    rehearsal_notify_verdict fail "the repos.txt half's handoff fixture could not be staged"
  fi
  if notify_pr="$(rehearsal_notify_stage_handoff_pr "$notify_sandbox" "extra-$(date -u +%H%M%S)" "$label")" \
      && [ -n "$notify_pr" ]; then
    rehearsal_notify_record_fixture "$notify_sandbox" "$notify_pr"
    ok "notify: handoff fixture staged in the notify-repos.txt sandbox"
  else
    notify_pr=""
    fail "notify: handoff fixture staged in the notify-repos.txt sandbox"
    rehearsal_notify_verdict fail "the notify-repos.txt half's handoff fixture could not be staged"
  fi

  if [ -z "$work_pr" ] || [ -z "$notify_pr" ]; then
    # Not a skip verdict: the fixture failure above already recorded `fail`,
    # and these two lines are what that failure cost, not a reason of their own.
    skip "notify: the watch set swept is exactly the two sandboxes"
    skip "notify: both halves of the union reached the operator on one tick"
  else
    first="$(( $(rehearsal_notify_log_lines) + 1 ))"
    rehearsal_notify_tick || true
    log_text="$(rehearsal_notify_log "$first")"
    if rehearsal_notify_watch_set_is_from_log 2 "$log_text"; then
      ok "notify: the watch set swept is exactly the two sandboxes"
    else
      fail "notify: the watch set swept is exactly the two sandboxes"
      rehearsal_notify_verdict fail "the swept watch set was not exactly the two sandboxes"
    fi
    rehearsal_notify_union_from_log \
      "$work" "$work_pr" "$notify_sandbox" "$notify_pr" "$log_text"
    union_rc=$?
    if [ "$union_rc" -eq 0 ]; then
      # The one place the leg records a pass: `ok notify` in the round summary
      # means a role actually read both halves out of one notify run, and
      # nothing weaker.
      ok "notify: both halves of the union reached the operator on one tick"
      rehearsal_notify_verdict ok "both halves on one tick"
    else
      fail "notify: both halves of the union reached the operator on one tick"
      rehearsal_notify_verdict fail "the union was not delivered on one tick (rc $union_rc)"
    fi
  fi

  # One more pass after the fixtures close edits both messages to their ✖ form,
  # so the drill leaves no live 🟣 row in a channel a human reads. Best effort —
  # the assertions above are the leg, this is manners.
  rehearsal_notify_close_fixtures || true
  rehearsal_notify_tick || true

  if rehearsal_notify_restore_registry; then
    :
  else
    echo "notify: WARNING — could not restore notify-repos.txt" >&2
  fi
  if rehearsal_notify_registries_restored "$work" "$pre_notify_text"; then
    ok "notify: teardown restored both registries to their pre-drill contents"
  else
    fail "notify: teardown restored both registries to their pre-drill contents"
    rehearsal_notify_verdict fail "the registries were not as expected after the leg's restore"
  fi
  return 0
}
