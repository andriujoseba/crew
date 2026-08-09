#!/usr/bin/env bash
# Sourceable terminal-breaker drill helpers. The live leg runs last in phase 2;
# the log predicates stay here so CI can mutate their inputs without a box host.
# shellcheck disable=SC2016  # quoted commands expand HOME inside the drill box

REHEARSAL_BREAKER_DIR=""
REHEARSAL_BREAKER_ROLE_CONF=""
REHEARSAL_BREAKER_STATE=""
REHEARSAL_BREAKER_REPO=""
REHEARSAL_BREAKER_ISSUE=""

rehearsal_breaker_record_result() {
  local result="$1" result_file="${REHEARSAL_BREAKER_RESULT_FILE:-}"
  [ -z "$result_file" ] || printf '%s\n' "$result" >"$result_file"
}

rehearsal_breaker_combine_result() {
  local current="$1" role_rc="$2"
  if [ "$current" -eq 1 ] || { [ "$role_rc" -ne 0 ] && [ "$role_rc" -ne 2 ]; }; then
    printf '1\n'
  elif [ "$role_rc" -eq 0 ]; then
    printf '0\n'
  else
    printf '%s\n' "$current"
  fi
}

rehearsal_breaker_round_result() {
  local current="$1" breaker_result="$2"
  if [ "$breaker_result" -eq 1 ]; then
    printf '1\n'
  else
    printf '%s\n' "$current"
  fi
}

rehearsal_breaker_summary() {
  local enabled="$1" drilled="$2" result="$3"
  if [ "$enabled" -eq 0 ]; then
    printf '%s\n' "skip       breaker  (--no-breaker-drill)"
  elif [ "$result" -eq 0 ]; then
    printf '%s\n' "ok         breaker  (trip + single alert + recovery)"
  elif [ "$result" -eq 1 ]; then
    printf '%s\n' "FAIL       breaker"
  elif [ -z "${drilled// /}" ]; then
    printf '%s\n' "INCOMPLETE breaker  (no role reached a box)"
  else
    printf '%s\n' "INCOMPLETE breaker  (phase 2 skipped)"
  fi
}

rehearsal_breaker_load_installed_facts() {
  local threshold kind state
  threshold="$(bx "sed -n 's/^SESSION_TERMINAL_THRESHOLD=\([0-9][0-9]*\)$/\1/p' ~/duty/conf/fleet.defaults.conf | head -1")" \
    || threshold=""
  kind="$(bx "sed -n 's/^[[:space:]]*run_session \([^ ]*\) .*/\1/p' ~/duty/lib/duty-attention.sh | head -1")" \
    || kind=""
  case "$threshold" in ''|*[!0-9]*|0) threshold="" ;; esac
  case "$kind" in ''|*[!A-Za-z0-9_-]*) kind="" ;; esac
  if [ -z "$threshold" ] || [ -z "$kind" ]; then
    fail "breaker: installed threshold and lane kind resolve for $AGENT"
    return 1
  fi
  state="$(bx "set -a; . ~/duty/conf/fleet.defaults.conf; . ~/duty/lib/common.sh; DUTY_DIR=\$HOME/duty; _session_terminal_state '$kind'")" \
    || state=""
  if [ -z "$state" ]; then
    fail "breaker: installed state path resolves for $AGENT"
    return 1
  fi
  REHEARSAL_BREAKER_THRESHOLD="$threshold"
  REHEARSAL_BREAKER_KIND="$kind"
  REHEARSAL_BREAKER_STATE="$state"
  ok "breaker: installed threshold and lane kind resolve for $AGENT"
}

rehearsal_breaker_profile_has_hook() {
  local hook="$1"
  bx "set -a; . ~/duty/conf/agents/$AGENT.conf; declare -F '$hook' >/dev/null"
}

rehearsal_breaker_terminal_fixture_is_classified() {
  bx "set -a
    . ~/duty/conf/agents/$AGENT.conf
    printf '%s\n' \"Server: Error code: 403 - {'error': {'message': \\\"You've reached your usage limit for this billing cycle.\\\", 'type': 'access_terminated_error'}}\" > /tmp/crew-breaker-terminal.log
    rc=0
    bot_session_terminal /tmp/crew-breaker-terminal.log || rc=\$?
    rm -f /tmp/crew-breaker-terminal.log
    exit \$rc
  "
}

rehearsal_breaker_install_fixture() {
  local role="$1" encoded box_home fixture_dir role_conf
  box_home="$(bx 'printf %s "$HOME"')" || return 1
  [ -n "$box_home" ] || return 1
  fixture_dir="$box_home/.crew-breaker-drill"
  role_conf="$box_home/duty/conf/roles/$role.conf"
  # Refuse a stale fixture before arming cleanup with its old backup. Restoring
  # an unknown prior run over today's installed profile would be destructive.
  bx "test ! -e '$fixture_dir'" || return 1
  REHEARSAL_BREAKER_DIR="$fixture_dir"
  REHEARSAL_BREAKER_ROLE_CONF="$role_conf"
  encoded="$(printf '%s\n' "Server: Error code: 403 - {'error': {'message': \"You've reached your usage limit for this billing cycle.\", 'type': 'access_terminated_error'}}" | base64 -w0)"
  bx "set -e
    mkdir -p '$REHEARSAL_BREAKER_DIR/bin'
    cp '$REHEARSAL_BREAKER_ROLE_CONF' '$REHEARSAL_BREAKER_DIR/role.conf'
    printf '%s' '$encoded' | base64 -d > '$REHEARSAL_BREAKER_DIR/terminal.txt'
    cat > '$REHEARSAL_BREAKER_DIR/bin/agent' <<'EOF'
#!/usr/bin/env bash
cat '$REHEARSAL_BREAKER_DIR/terminal.txt'
exit 1
EOF
    chmod +x '$REHEARSAL_BREAKER_DIR/bin/agent'
    cat >> '$REHEARSAL_BREAKER_ROLE_CONF' <<'EOF'
# rehearsal-breaker begin
BOT_CLI_CMD=(\"$REHEARSAL_BREAKER_DIR/bin/agent\")
bot_cli_probe() { return 1; }
alert() { printf '%s\\n' \"\$*\" >>\"$REHEARSAL_BREAKER_DIR/alerts.log\"; }
# rehearsal-breaker end
EOF
  "
}

rehearsal_breaker_restore_cli() {
  [ -n "$REHEARSAL_BREAKER_DIR" ] || return 0
  if bx "set -e
    if [ -f '$REHEARSAL_BREAKER_DIR/role.conf' ] && [ -n '$REHEARSAL_BREAKER_ROLE_CONF' ]; then
      cp '$REHEARSAL_BREAKER_DIR/role.conf' '$REHEARSAL_BREAKER_ROLE_CONF'
    fi
    rm -rf '$REHEARSAL_BREAKER_DIR'
  "; then
    REHEARSAL_BREAKER_DIR=""
    return 0
  fi
  return 1
}

rehearsal_breaker_restore_cli_for_recovery() {
  [ -n "$REHEARSAL_BREAKER_DIR" ] || return 1
  bx "set -e
    cp '$REHEARSAL_BREAKER_DIR/role.conf' '$REHEARSAL_BREAKER_ROLE_CONF'
    cat >> '$REHEARSAL_BREAKER_ROLE_CONF' <<'EOF'
# rehearsal-breaker recovery begin
alert() { printf '%s\n' \"\$*\" >>\"$REHEARSAL_BREAKER_DIR/alerts.log\"; }
# rehearsal-breaker recovery end
EOF
  "
}

rehearsal_breaker_attention_is_clear_from_json() {
  jq -e '[.labels[].name] | index("attention") == null' >/dev/null <<<"$1"
}

rehearsal_breaker_attention_is_clear() {
  local repo="$1" issue="$2" issue_json
  issue_json="$(gh api "repos/$repo/issues/$issue")" || return 1
  rehearsal_breaker_attention_is_clear_from_json "$issue_json"
}

rehearsal_breaker_profile_is_restored() {
  [ -n "$REHEARSAL_BREAKER_ROLE_CONF" ] || return 1
  bx "test -f '$REHEARSAL_BREAKER_ROLE_CONF' && ! grep -qF '# rehearsal-breaker ' '$REHEARSAL_BREAKER_ROLE_CONF'"
}

rehearsal_breaker_cleanup() {
  rehearsal_breaker_restore_cli || true
  [ -z "$REHEARSAL_BREAKER_STATE" ] || bx "rm -f '$REHEARSAL_BREAKER_STATE'" >/dev/null 2>&1 || true
  if [ -n "$REHEARSAL_BREAKER_REPO" ] && [ -n "$REHEARSAL_BREAKER_ISSUE" ]; then
    gh api -X DELETE \
      "repos/$REHEARSAL_BREAKER_REPO/issues/$REHEARSAL_BREAKER_ISSUE/labels/attention" \
      >/dev/null 2>&1 || true
  fi
}

rehearsal_breaker_below_threshold_from_log() {
  local kind="$1" log_text="$2"
  grep -Fq "SESSION START kind=$kind" <<<"$log_text" \
    && grep -Fq "outcome=TERMINAL" <<<"$log_text" \
    && ! grep -Fq "session breaker: kind=$kind tripped" <<<"$log_text"
}

rehearsal_breaker_trip_from_log() {
  local kind="$1" threshold="$2" log_text="$3"
  [ "$(grep -cF "SESSION START kind=$kind" <<<"$log_text")" -eq "$threshold" ] \
    && [ "$(grep -cF "session breaker: kind=$kind tripped after $threshold consecutive terminal failures" <<<"$log_text")" -eq 1 ]
}

rehearsal_breaker_suppressed_from_log() {
  local kind="$1" threshold="$2" expected="$3" log_text="$4" matching_skips
  matching_skips="$(
    grep -F "SESSION SKIP kind=$kind" <<<"$log_text" \
      | grep -cF "reason=terminal-breaker count=$threshold" || true
  )"
  [ "$matching_skips" -eq "$expected" ] \
    && ! grep -Fq "SESSION START kind=$kind" <<<"$log_text"
}

rehearsal_breaker_recovered_from_log() {
  local kind="$1" log_text="$2"
  grep -Fq "session breaker: kind=$kind recovered; dispatch resumed" <<<"$log_text" \
    && grep -Fq "SESSION START kind=$kind" <<<"$log_text"
}

rehearsal_breaker_alert_count_is_one() {
  local kind="$1" alerts="$2"
  [ "$(grep -cF ": $kind session dispatch stopped after" <<<"$alerts" || true)" -eq 1 ]
}

rehearsal_breaker_tick_log() {
  local first="$1"
  bx "tail -n +$first ~/duty/duty.log"
}

rehearsal_breaker_drill() {
  local repo="$1" issue="$2" role="$3" first log_text all_log="" attempt
  local fixture_dir stopped_log="" stopped_ticks=0
  local threshold kind alerts failures_before
  if [ "${REHEARSAL_BREAKER_DRILL:-1}" -eq 0 ]; then
    skip "breaker: terminal lane trip and recovery (--no-breaker-drill)"
    return 0
  fi
  failures_before="${#FAILS[@]}"
  REHEARSAL_BREAKER_REPO="$repo"
  REHEARSAL_BREAKER_ISSUE="$issue"
  rehearsal_breaker_load_installed_facts || return 1
  threshold="$REHEARSAL_BREAKER_THRESHOLD"
  kind="$REHEARSAL_BREAKER_KIND"
  if bx "test ! -e '$REHEARSAL_BREAKER_STATE'"; then
    ok "breaker: $kind lane starts closed for $AGENT"
  else
    fail "breaker: $kind lane starts closed for $AGENT"
    return 1
  fi
  check "breaker: $AGENT profile defines bot_session_terminal" \
    rehearsal_breaker_profile_has_hook bot_session_terminal
  check "breaker: $AGENT profile defines bot_session_acted" \
    rehearsal_breaker_profile_has_hook bot_session_acted
  if ! rehearsal_breaker_profile_has_hook bot_session_terminal \
      || ! rehearsal_breaker_profile_has_hook bot_session_acted; then
    return 1
  fi
  check "breaker: terminal fixture is classified for $AGENT" \
    rehearsal_breaker_terminal_fixture_is_classified
  rehearsal_breaker_terminal_fixture_is_classified || return 1
  if rehearsal_breaker_install_fixture "$role"; then
    ok "breaker: staged $AGENT CLI installed"
  else
    fail "breaker: staged $AGENT CLI installed"
    return 1
  fi
  fixture_dir="$REHEARSAL_BREAKER_DIR"
  if gh api -X POST "repos/$repo/issues/$issue/labels" -f 'labels[]=attention' >/dev/null; then
    ok "breaker: attention lane fixture armed"
  else
    fail "breaker: attention lane fixture armed"
    return 1
  fi

  attempt=1
  while [ "$attempt" -le "$threshold" ]; do
    first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
    bx '$HOME/duty/bin/tick.sh' || true
    log_text="$(rehearsal_breaker_tick_log "$first")"
    all_log="$all_log${all_log:+$'\n'}$log_text"
    if [ "$attempt" -lt "$threshold" ]; then
      check "breaker: terminal dispatch $attempt remains below installed threshold" \
        rehearsal_breaker_below_threshold_from_log "$kind" "$log_text"
    fi
    attempt=$((attempt + 1))
  done
  check "breaker: lane trips once at installed threshold for $AGENT" \
    rehearsal_breaker_trip_from_log "$kind" "$threshold" "$all_log"

  while [ "$stopped_ticks" -lt 2 ]; do
    first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
    bx '$HOME/duty/bin/tick.sh' || true
    log_text="$(rehearsal_breaker_tick_log "$first")"
    stopped_log="$stopped_log${stopped_log:+$'\n'}$log_text"
    stopped_ticks=$((stopped_ticks + 1))
  done
  check "breaker: following ticks skip the stopped lane" \
    rehearsal_breaker_suppressed_from_log \
      "$kind" "$threshold" "$stopped_ticks" "$stopped_log"
  alerts="$(bx "cat '$REHEARSAL_BREAKER_DIR/alerts.log' 2>/dev/null || true")"
  check "breaker: $kind operator alert emitted exactly once while stopped" \
    rehearsal_breaker_alert_count_is_one "$kind" "$alerts"

  if rehearsal_breaker_restore_cli_for_recovery; then
    ok "breaker: real $AGENT CLI restored"
  else
    fail "breaker: real $AGENT CLI restored"
    return 1
  fi
  first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"
  bx '$HOME/duty/bin/tick.sh' || true
  log_text="$(rehearsal_breaker_tick_log "$first")"
  check "breaker: later tick recovers and launches a session" \
    rehearsal_breaker_recovered_from_log "$kind" "$log_text"
  wait_for 300 "breaker: attention label removed after recovered session" \
    rehearsal_breaker_attention_is_clear "$repo" "$issue"
  check "breaker: state is cleared after recovery" bx "test ! -e '$REHEARSAL_BREAKER_STATE'"
  if rehearsal_breaker_restore_cli; then
    ok "breaker: recovery alert interceptor removed"
  else
    fail "breaker: recovery alert interceptor removed"
    return 1
  fi
  check "breaker: teardown leaves no staged CLI" bx "test ! -e '$fixture_dir'"
  check "breaker: teardown restores the role profile" \
    rehearsal_breaker_profile_is_restored
  if [ "${#FAILS[@]}" -gt "$failures_before" ]; then return 1; fi
}
