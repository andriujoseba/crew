# duty-hygiene.sh — the unconditional backlog-hygiene sweep (triage role,
# hourly). There is no cheap shell test for "this label is no longer true",
# so this sweep is judgment-only: one session per repo, every interval,
# whatever the fast poll saw. It is the backstop for every fail-safe default
# in duty-triage.sh.
#
# shellcheck shell=bash

duty_hygiene() {
  local R dir
  log "hygiene sweep starting"
  while IFS= read -r R; do
    [ -z "$R" ] && continue
    log "$R: launching hygiene sweep"
    dir="$WORK_DIR/${R//\//__}"
    ensure_checkout "$R" "$dir" || continue
    run_session hygiene "$R" "$dir" "$TIMEOUT_HYGIENE" \
      "$(render_prompt hygiene.txt ME="$ME" REPO="$R")"
  done < <(read_repo_list "$REPOS_FILE")
  return 0
}
