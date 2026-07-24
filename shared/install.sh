#!/usr/bin/env bash
# install.sh — deploy the shared duty engine from a crew checkout to ~/duty.
#
# Run from the repo root on the target box:   shared/install.sh
#
# The box's identity is read from its gh token (never a flag — the token IS
# the identity, and one box per identity is the fleet invariant). The crew
# checkout becomes the single source both the archive and the deployment
# come from: the per-bot script archives drifted from what actually ran (a
# header comment above kimi's shebang existed only in the archive).
#
# Idempotent and state-preserving: repos.txt, notify-repos.txt, logs, state
# files and clones are never touched; bin/lib/conf/prompts are replaced.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

command -v gh >/dev/null || { echo "gh not found — install and authenticate it first"; exit 1; }
command -v jq >/dev/null || { echo "jq not found — the duty engine requires it"; exit 1; }

ME="$(gh api user --jq .login)" || { echo "gh is not authenticated"; exit 1; }
BOT_CONF="$HERE/conf/bots/$ME.conf"
[ -f "$BOT_CONF" ] || { echo "no bot config for '$ME' at $BOT_CONF — add one first"; exit 1; }

mkdir -p "$DUTY_DIR/bin" "$DUTY_DIR/lib/jq" "$DUTY_DIR/conf" "$DUTY_DIR/prompts" \
         "$DUTY_DIR/work" "$DUTY_DIR/trees" "$DUTY_DIR/logs"

cp "$HERE"/bin/*.sh            "$DUTY_DIR/bin/"
cp "$HERE"/lib/*.sh            "$DUTY_DIR/lib/"
cp "$HERE"/lib/jq/*.jq         "$DUTY_DIR/lib/jq/"
cp "$HERE"/prompts/*.txt       "$DUTY_DIR/prompts/"
cp "$HERE/conf/fleet.conf"     "$DUTY_DIR/conf/fleet.conf"
cp "$BOT_CONF"                 "$DUTY_DIR/conf/bot.conf"
chmod +x "$DUTY_DIR"/bin/*.sh

# Seed the repo registry only if absent — its contents (and the reasoning in
# its comments) are box-local operator state.
if [ ! -f "$DUTY_DIR/repos.txt" ]; then
  cp "$HERE/conf/repos-default.txt" "$DUTY_DIR/repos.txt"
  echo "seeded $DUTY_DIR/repos.txt (edit it: it is the box's registry, not the job definition)"
fi

# Version stamp: FLEET.md reconciles the deployed fleet against crew@SHA.
{
  echo "crew@$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "installed $(date -u '+%Y-%m-%dT%H:%M:%SZ') as $ME"
} >"$DUTY_DIR/VERSION"

echo "installed for $ME (roles: $(bash -c "source '$DUTY_DIR/conf/bot.conf'; echo \"\$BOT_ROLES\""))"
echo
echo "crontab (crontab -e), replacing any previous duty/hygiene/notify lines:"
echo "  */5 * * * * $DUTY_DIR/bin/tick.sh"
if [ "$ME" = "$(bash -c "source '$DUTY_DIR/conf/fleet.conf'; echo \"\$FLEET_TRIAGE\"")" ]; then
  echo "  */5 * * * * $DUTY_DIR/bin/tick.sh notify"
  echo "(hygiene needs no cron line — it self-schedules inside the duty tick)"
fi
