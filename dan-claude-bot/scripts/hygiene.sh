#!/usr/bin/env bash
# CREW NOTE: slow unconditional backlog sweep. Fires hourly via cron (flock-guarded). Runs a hygiene session per repo every time, signal or not.
# hygiene.sh — the slow, unconditional sweep (hourly via cron).
# Backlog hygiene is judgment work — flipping blocked→ready, reclaiming
# stale claims, closing obsolete issues — so it runs regardless of signals:
# there is no cheap shell test for "this label is no longer true".
set -euo pipefail

# cron ships PATH=/usr/bin:/bin — claude lives in ~/.local/bin.
export PATH="/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/home/claude"

DUTY_DIR="$HOME/duty"
REPOS_FILE="$DUTY_DIR/repos.txt"
WORK_DIR="$DUTY_DIR/work"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

checkout() {
  local repo="$1" dir="$WORK_DIR/${1//\//__}"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --quiet >/dev/null 2>&1 || true
  else
    git clone --quiet "https://github.com/$repo" "$dir"
  fi
  printf '%s\n' "$dir"
}

while IFS= read -r R; do
  [ -z "$R" ] && continue
  case "$R" in \#*) continue ;; esac

  log "$R: launching hygiene sweep"
  dir=$(checkout "$R")
  prompt="You are the triage agent dan-claude-bot in $R. Do backlog hygiene per TRIAGE.md: flip blocked issues to ready when their named blockers have landed, reclaim claimed issues with no open PR and no recent activity, close obsolete issues with reasons, keep every label on the board true, and keep epics' task lists current. If nothing needs doing, say so and exit."
  if (cd "$dir" && timeout 3000 claude -p --dangerously-skip-permissions "$prompt"); then
    log "$R: hygiene sweep completed"
  else
    log "$R: hygiene sweep FAILED or timed out (exit $?)"
  fi
done < "$REPOS_FILE"
