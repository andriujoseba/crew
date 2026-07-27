# duty-attention.sh — the role-independent attention wake (FLEET.md,
# ceremony#83). An open issue assigned to me carrying the `attention` label
# is a demand parked for me. Exactly one wake per demand; the pickup session
# acks by REMOVING the label (that re-arms the wake), then does the work per
# role. A session that dies before acking is relaunched next tick — the flag
# is still up, so the path is crash-only by construction. One API call, the
# authenticated-user issues endpoint: cross-repo and without a search index.
#
# THE QUERY IS CROSS-REPO; THE ACTION IS NOT (crew#66, danmt's ruling
# 2026-07-27). The endpoint returns demands from every repo the identity can
# see, and this module used to launch a session on all of them — for a builder,
# after ensure_main_clone and with the full worktree/round rule set attached.
# That is write authority on a repo no operator listed, and it was the one hole
# left in the containment story `repos-default.txt` asserts without exception:
# narrowing repos.txt confined every other module and not this one, which is
# the same shape as the reviewer gap the drill found (#52).
#
# Rows outside the registry are now reported and never acted on, exactly as an
# out-of-scope review request or authored PR already is. The cost is real and
# was argued before the ruling: an assignment plus a label IS a targeted
# authorization, so a cross-repo handoff to a box now waits for an operator to
# add the repo — and the box most likely to be handed work outside its beat is
# the one that stops answering. That is why the report is not only a log line
# (see the alert below): a bounded wake that fails silently would trade an
# unbounded write surface for a broken channel to the human.
#
# shellcheck shell=bash

# _attention_partition REGISTRY — split rows against the box's registry.
# stdin: "<repo> <num> <updated>"; stdout: the same rows prefixed IN or OUT.
#
# Separated from the wake so the ruling is testable without gh: the partition
# IS the ruling, and a source-invariant grep would only prove the file mentions
# repos.txt, not that a demand outside it stays unacted.
_attention_partition() {
  local registry="$1" repo num upd
  while read -r repo num upd; do
    [ -n "${num:-}" ] || continue
    if printf '%s\n' "$registry" | grep -qxF "$repo"; then
      printf 'IN %s %s %s\n' "$repo" "$num" "$upd"
    else
      printf 'OUT %s %s %s\n' "$repo" "$num" "$upd"
    fi
  done
}

duty_attention() {
  local rows
  # updated_at travels so the out-of-scope report can name WHEN, and so a
  # re-parked demand reads as new rather than as the same stale row.
  rows="$(gh api "/issues?filter=assigned&state=open&labels=$LABEL_ATTENTION&per_page=100" \
    --jq '.[] | "\(.repository.full_name) \(.number) \(.updated_at)"' 2>/dev/null)" \
    || { warn "attention fetch failed this tick"; return 0; }
  if [ -z "$rows" ]; then
    log "attention: none"
    return 0
  fi

  local registry partitioned inside outside
  registry="$(read_repo_list "$REPOS_FILE")"
  partitioned="$(printf '%s\n' "$rows" | _attention_partition "$registry")"
  inside="$(printf '%s\n' "$partitioned" | awk '$1 == "IN" { print $2, $3 }')"
  outside="$(printf '%s\n' "$partitioned" | awk '$1 == "OUT" { print $2 "#" $3, $4 }')"

  # Reported on every tick's worth of state CHANGE, not every tick: a standing
  # out-of-scope demand would otherwise write 288 identical lines a day and
  # bury the log it exists to inform (#59's rule).
  local sc_state="$DUTY_DIR/.suppressed-attention-scope" sc_prev sc_now
  sc_prev="$(cat "$sc_state" 2>/dev/null || true)"
  printf '%s\n' "$outside" \
    | report_suppressed "$sc_state" "attention: outside repos.txt, NOT picked up"
  sc_now="$(cat "$sc_state" 2>/dev/null || true)"
  # ...and it reaches the OPERATOR, not just duty.log. An attention demand is
  # the human's channel to this box; bounding it without telling anyone would
  # turn "the box ignored me" into something only a log tail can explain. Same
  # channel the boot gate and the auth watchdog already use, and best-effort by
  # contract — a box with no Telegram token simply logs.
  # An `if`, not `[ … ] && alert`: as a trailing statement that form returns
  # non-zero whenever the condition is false, and set -e would end the tick
  # (#25/#30).
  if [ -n "$sc_now" ] && [ "$sc_now" != "$sc_prev" ]; then
    alert "📥 $(hostname): attention demand(s) outside this box's repos.txt, NOT picked up — $(printf '%s\n' "$outside" | awk 'NF{printf "%s ", $1}')— add the repo to ~/duty/repos.txt, or move the issue to one this box carries"
  fi

  if [ -z "${inside//[[:space:]]/}" ]; then
    log "attention: none in registry"
    return 0
  fi
  rows="$inside"

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
      extra="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name") $(render_prompt fragment-round-rules.txt TRIAGE="$FLEET_TRIAGE" BENCH="$FLEET_BENCH" MARK_ADDRESSING="$MARK_ADDRESSING") $(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")"
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
