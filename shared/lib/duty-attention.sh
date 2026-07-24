# duty-attention.sh — the role-independent attention wake (FLEET.md,
# ceremony#83). An open issue assigned to me carrying the `attention` label
# is a demand parked for me. Exactly one wake per demand; the pickup session
# acks by REMOVING the label (that re-arms the wake), then does the work per
# role. A session that dies before acking is relaunched next tick — the flag
# is still up, so the path is crash-only by construction. One API call, the
# authenticated-user issues endpoint: cross-repo, no search index, reaches
# repos not in repos.txt.
#
# shellcheck shell=bash

duty_attention() {
  local rows
  rows="$(gh api "/issues?filter=assigned&state=open&labels=$LABEL_ATTENTION&per_page=100" \
    --jq '.[] | "\(.repository.full_name) \(.number)"' 2>/dev/null)" \
    || { warn "attention fetch failed this tick"; return 0; }
  if [ -z "$rows" ]; then
    log "attention: none"
    return 0
  fi

  # Route the demand by role. Builders get the full build machinery rules:
  # an authorization that unblocks a claimed issue's acceptance criterion IS
  # build work, done in the pickup session.
  local route
  if has_role triage; then
    route="Act per TRIAGE.md. Touch the label only to remove it as your ack; set nothing, and never spawn work off a bare @-mention."
  elif has_role builder; then
    route="Read AGENTS.md at the repo root and follow where it routes you: BUILDER.md for your claims (build in a worktree, never in the main clone), REVIEWER.md for verdicts. An authorization or ruling that unblocks an acceptance criterion on an issue you have claimed IS build work: do it now."
  else
    route="Read AGENTS.md at the repo root and follow where it routes you (REVIEWER.md for a verdict). Never spawn work off a bare @-mention."
  fi

  local repo num dir slug name extra prompt
  while read -r repo num; do
    [ -z "${num:-}" ] && continue
    slug="${repo//\//__}"; name="${repo##*/}"
    log "attention: $repo#$num — launching pickup session"
    dir="$WORK_DIR/$slug"
    if has_role builder; then
      ensure_main_clone "$repo" "$dir" || continue
      extra="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name") $(render_prompt fragment-round-rules.txt TRIAGE="$FLEET_TRIAGE" BENCH="$FLEET_BENCH") $(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")"
    else
      ensure_checkout "$repo" "$dir" || continue
      extra=""
    fi
    prompt="$(render_prompt attention.txt ME="$ME" REPO="$repo" NUM="$num" \
      MARK_PICKUP="$MARK_PICKUP" LABEL_ATTENTION="$LABEL_ATTENTION" \
      ROLE_ROUTE="$route" EXTRA_RULES="$extra")"
    run_session attention "$repo#$num" "$dir" "$TIMEOUT_ATTENTION" "$prompt"
  done <<<"$rows"
}
