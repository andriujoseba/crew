#!/usr/bin/env bash
# Sourceable resume-drill helpers. The live leg runs only from rehearsal.sh's
# authenticated builder block; the log predicates stay here so CI can mutate
# their inputs without a drill host.

if ! declare -F rehearsal_verdict_record >/dev/null 2>&1; then
  # shellcheck source=drill/rehearsal-verdict.sh
  . "$(dirname "${BASH_SOURCE[0]}")/rehearsal-verdict.sh"
fi

REHEARSAL_RESUME_NOOP_SET=0

rehearsal_resume_verdict() {
  rehearsal_verdict_record "${REHEARSAL_RESUME_STATUS:-}" "$@"
}

rehearsal_resume_load_installed_threshold() {
  local threshold
  REHEARSAL_RESUME_THRESHOLD=""
  # Read the value the installed lane adapter actually passes to the breaker.
  # Keeping the number out of the drill means an engine threshold change moves
  # the assertion with the engine instead of silently changing its subject.
  threshold="$(bx "
    sed -n '/^_resume_lane_breaker()/,/^}/p' ~/duty/lib/duty-builder.sh |
      sed -n 's/.*breaker=\([0-9][0-9]*\).*/\1/p' | head -1
  ")" || threshold=""
  case "$threshold" in
    ''|*[!0-9]*|0)
      fail "resume: installed zero-action threshold resolves"
      return 1 ;;
  esac
  REHEARSAL_RESUME_THRESHOLD="$threshold"
  ok "resume: installed zero-action threshold resolves"
}

rehearsal_resume_tick_log() {
  local first_line="$1"
  bx "tail -n +$first_line ~/duty/duty.log"
}

rehearsal_resume_tick() {
  # shellcheck disable=SC2016  # HOME expands inside the drill box
  bx '$HOME/duty/bin/tick.sh'
}

rehearsal_resume_pending_tick_from_log() {
  local repo="$1" pr="$2" log_text="$3"
  ! grep -Fq "$repo#$pr: green head owed a signal" <<<"$log_text" \
    && ! grep -Fq "SESSION START kind=resume key=$repo" <<<"$log_text"
}

rehearsal_resume_wake_tick_from_log() {
  local repo="$1" pr="$2" head="$3" log_text="$4"
  grep -Fq "$repo#$pr: green head owed a signal" <<<"$log_text" \
    && grep -Fq "at $head (#384)" <<<"$log_text" \
    && grep -Fq "SESSION START kind=resume key=$repo" <<<"$log_text"
}

rehearsal_resume_near_miss_tick_from_log() {
  local repo="$1" pr="$2" head="$3" comment_id="$4" log_text="$5"
  grep -Fq "$repo#$pr: comment $comment_id opens with an unrendered marker slot and names head $head" <<<"$log_text" \
    && grep -Fq "$repo#$pr: near-miss resume dispatch" <<<"$log_text" \
    && grep -Fq "SESSION START kind=resume key=$repo" <<<"$log_text"
}

rehearsal_resume_suppressed_tick_from_log() {
  local repo="$1" pr="$2" head="$3" threshold="$4" log_text="$5"
  grep -Fq "no resume duty: $repo#$pr near-miss lane suppressed at $head after $threshold zero-action dispatches" <<<"$log_text" \
    && ! grep -Fq "SESSION START kind=resume key=$repo" <<<"$log_text"
}

rehearsal_resume_noop_cli() {
  # The override is deliberately last in the builder role profile, which is
  # sourced after the agent profile. It makes a real resume session perform no
  # board or git action, the condition the breaker is meant to bound.
  if bx "cat >> ~/duty/conf/roles/builder.conf <<'EOF'
# rehearsal-resume-noop begin
BOT_CLI_CMD=(true)
# rehearsal-resume-noop end
EOF"; then
    REHEARSAL_RESUME_NOOP_SET=1
    return 0
  fi
  return 1
}

rehearsal_resume_restore_cli() {
  if bx "sed -i '/^# rehearsal-resume-noop begin$/,/^# rehearsal-resume-noop end$/d' ~/duty/conf/roles/builder.conf"; then
    REHEARSAL_RESUME_NOOP_SET=0
    return 0
  fi
  return 1
}

rehearsal_resume_advance_fixture_head() {
  local repo="$1" pr="$2" branch head_repo path sha content
  branch="$(gh api "repos/$repo/pulls/$pr" --jq .head.ref)" || return
  head_repo="$(gh api "repos/$repo/pulls/$pr" --jq .head.repo.full_name)" || return
  path=drill-build.txt
  sha="$(bx "gh api 'repos/$head_repo/contents/$path?ref=$branch' --jq .sha")" || return
  content="$(printf 'resume drill %s\n' "$(date -u +%s)" | base64 -w0)"
  bx "gh api -X PUT 'repos/$head_repo/contents/$path' \
    -f message='drill: advance resume fixture head' -f branch='$branch' \
    -f content='$content' -f sha='$sha' --jq .commit.sha"
}

rehearsal_resume_drill() {
  local repo="$1" pr="$2" context head old_head new_head first log_text comment_id
  local attempt threshold wake_asserted=0 stop_asserted=0
  context=drill/resume-head-settle

  if [ "${REHEARSAL_RESUME_DRILL:-1}" -eq 0 ]; then
    skip "resume: check-conclusion wake and zero-action stop (--no-resume-drill)"
    rehearsal_resume_verdict skip "--no-resume-drill"
    return 0
  fi
  if [ -z "$pr" ]; then
    skip "resume: check-conclusion wake and zero-action stop (builder fixture PR unavailable)"
    rehearsal_resume_verdict skip "builder fixture PR unavailable"
    return 0
  fi
  if ! rehearsal_resume_load_installed_threshold; then
    rehearsal_resume_verdict fail "installed zero-action threshold does not resolve"
    return 1
  fi
  threshold="$REHEARSAL_RESUME_THRESHOLD"

  if ! old_head="$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)"; then
    rehearsal_resume_verdict fail "fixture head could not be read"
    return 1
  fi
  if ! new_head="$(rehearsal_resume_advance_fixture_head "$repo" "$pr")" \
      || [ -z "$new_head" ]; then
    fail "resume: fixture head advances"
    rehearsal_resume_verdict fail "fixture head did not advance"
    return 1
  fi
  if [ "$new_head" = "$old_head" ]; then
    fail "resume: fixture head advances"
    rehearsal_resume_verdict fail "fixture head did not advance"
    return 1
  fi
  if ! wait_for 60 "resume: fixture head advances" \
      rehearsal_builder_head_is "$repo" "$pr" "$new_head"; then
    rehearsal_resume_verdict fail "fixture head did not settle"
    return 1
  fi
  head="$new_head"
  if rehearsal_set_builder_head_status "$repo" "$head" "$context" pending \
      'drill holds resume until the next check-conclusion tick'; then
    ok "resume: pending head status established"
  else
    fail "resume: pending head status established"
    rehearsal_resume_verdict fail "pending head status could not be established"
    return 1
  fi
  if rehearsal_resume_noop_cli; then
    ok "resume: zero-action session fixture installed"
  else
    fail "resume: zero-action session fixture installed"
    rehearsal_resume_verdict fail "zero-action session fixture could not be installed"
    return 1
  fi

  first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
  rehearsal_resume_tick || true
  log_text="$(rehearsal_resume_tick_log "$first")"
  if rehearsal_resume_pending_tick_from_log "$repo" "$pr" "$log_text"; then
    ok "resume: pending head remains unresumed for its tick"
  else
    fail "resume: pending head remains unresumed for its tick"
    rehearsal_resume_verdict fail "pending head resumed before check conclusion"
  fi

  if rehearsal_set_builder_head_status "$repo" "$head" "$context" success \
      'drill releases the check-conclusion wake'; then
    ok "resume: green head status established"
  else
    fail "resume: green head status established"
    rehearsal_resume_verdict fail "green head status could not be established"
  fi
  first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
  rehearsal_resume_tick || true
  log_text="$(rehearsal_resume_tick_log "$first")"
  if rehearsal_resume_wake_tick_from_log "$repo" "$pr" "$head" "$log_text"; then
    ok "resume: first tick after green resumes the parked PR"
    wake_asserted=1
  else
    fail "resume: first tick after green resumes the parked PR"
    rehearsal_resume_verdict fail "check-conclusion wake was not observed"
  fi

  comment_id="$(bx "gh api 'repos/$repo/issues/$pr/comments' -f body='{{MARK_ANSWERED}} $head' --jq .id")" || comment_id=""
  if [ -n "$comment_id" ]; then
    ok "resume: unrendered-marker fixture comment posted"
  else
    fail "resume: unrendered-marker fixture comment posted"
    rehearsal_resume_verdict fail "unrendered-marker fixture comment could not be posted"
  fi

  attempt=1
  while [ "$attempt" -le "$threshold" ]; do
    first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
    rehearsal_resume_tick || true
    log_text="$(rehearsal_resume_tick_log "$first")"
    if [ "$attempt" -eq 1 ]; then
      if rehearsal_resume_near_miss_tick_from_log \
          "$repo" "$pr" "$head" "$comment_id" "$log_text"; then
        ok "resume: unrendered marker warns with its comment and wakes next tick"
      else
        fail "resume: unrendered marker warns with its comment and wakes next tick"
        rehearsal_resume_verdict fail "unrendered-marker near-miss wake was not observed"
      fi
    fi
    attempt=$(( attempt + 1 ))
  done

  first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
  rehearsal_resume_tick || true
  log_text="$(rehearsal_resume_tick_log "$first")"
  if rehearsal_resume_suppressed_tick_from_log \
      "$repo" "$pr" "$head" "$threshold" "$log_text"; then
    ok "resume: unchanged head stops after the installed zero-action threshold"
    stop_asserted=1
  else
    fail "resume: unchanged head stops after the installed zero-action threshold"
    rehearsal_resume_verdict fail "zero-action stop was not observed"
  fi

  if [ "$REHEARSAL_RESUME_NOOP_SET" -eq 1 ] && rehearsal_resume_restore_cli; then
    ok "resume: normal builder CLI restored"
  else
    fail "resume: normal builder CLI restored"
    rehearsal_resume_verdict fail "normal builder CLI was not restored"
  fi
  if [ "$wake_asserted" -eq 1 ] && [ "$stop_asserted" -eq 1 ]; then
    rehearsal_resume_verdict ok "wake + zero-action stop"
  fi
  return 0
}
