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
# files and clones are never touched; bin/lib/conf/prompts are replaced
# ATOMICALLY (write-then-rename — a model session can be mid-flight calling
# bin/submit-verdict.sh, and it must see the old file or the new one, never
# a half-written inode).
#
# MIGRATION from the per-box hand-rolled layout: old top-level entrypoints
# (~/duty/duty.sh, tick.sh, hygiene.sh, notify.sh, submit/announce helpers)
# are moved to ~/duty/legacy/ — their locks are DISJOINT from the new
# engine's, so a surviving old cron line would run a second engine in
# parallel and re-create the double-verdict incident class. Moving the files
# disarms any stale cron line; the crontab scan below then tells you exactly
# which lines to delete.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

command -v gh >/dev/null || { echo "gh not found — install and authenticate it first"; exit 1; }
command -v jq >/dev/null || { echo "jq not found — the duty engine requires it"; exit 1; }

# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/conf/fleet.conf"

# --- Resolve this box's configuration, one of three ways ---
#  explicit  --agent X --role Y   pre-auth bake (crew new): no gh identity
#                                 needed — the boot gate screams until the
#                                 operator logs in, which is correct.
#  manifest  gh token → FLEET_MANIFEST line (the standing fleet).
#  keep      existing conf/instance.conf (re-install/upgrade on a box whose
#            identity isn't in the manifest, or whose auth is down).
AGENT_ARG="" ROLE_ARG="" ARM_CRON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT_ARG="$2"; shift 2 ;;
    --role)  ROLE_ARG="$2";  shift 2 ;;
    --arm-cron) ARM_CRON=1; shift ;;
    *) echo "unknown argument '$1' (usage: install.sh [--agent <a> --role <r>] [--arm-cron])"; exit 1 ;;
  esac
done

ME="$(gh api user --jq .login 2>/dev/null || true)"
if [ -n "$AGENT_ARG" ] || [ -n "$ROLE_ARG" ]; then
  if [ -z "$AGENT_ARG" ] || [ -z "$ROLE_ARG" ]; then
    echo "--agent and --role go together"; exit 1
  fi
  BOT_AGENT="$AGENT_ARG"
  BOT_ROLE_LIST="$(printf '%s' "$ROLE_ARG" | tr ',' ' ')"
elif [ -n "$ME" ] && resolved="$(manifest_lookup "$ME")"; then
  read -r BOT_AGENT BOT_ROLE_LIST <<<"$resolved"
elif [ -f "$DUTY_DIR/conf/instance.conf" ]; then
  # shellcheck disable=SC1091
  source "$DUTY_DIR/conf/instance.conf"
  BOT_ROLE_LIST="$BOT_ROLES"
  echo "keeping existing instance config (agent: $BOT_AGENT, roles: $BOT_ROLE_LIST)${ME:+ — $ME is not in FLEET_MANIFEST}"
else
  echo "cannot resolve this box's configuration: no --agent/--role flags,"
  echo "no manifest entry${ME:+ for $ME}${ME:-" (gh not authenticated)"}, and no existing instance.conf"
  exit 1
fi
[ -f "$HERE/conf/agents/$BOT_AGENT.conf" ] || { echo "unknown agent profile '$BOT_AGENT'"; exit 1; }
for role in $BOT_ROLE_LIST; do
  [ -f "$HERE/conf/roles/$role.conf" ] || { echo "unknown role profile '$role'"; exit 1; }
done
IS_TRIAGE=0
case " $BOT_ROLE_LIST " in *" triage "*) IS_TRIAGE=1 ;; esac

mkdir -p "$DUTY_DIR/bin" "$DUTY_DIR/lib/jq" "$DUTY_DIR/conf/agents" \
         "$DUTY_DIR/conf/roles" "$DUTY_DIR/prompts" \
         "$DUTY_DIR/work" "$DUTY_DIR/trees" "$DUTY_DIR/logs"

# Atomic per-file install: new inode, then rename over the old name.
put() {  # put SRC DESTDIR
  local src="$1" destdir="$2" tmp
  tmp="$(mktemp "$destdir/.install.XXXXXX")"
  cp "$src" "$tmp"
  chmod --reference="$src" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  mv "$tmp" "$destdir/$(basename "$src")"
}

for f in "$HERE"/bin/*.sh; do put "$f" "$DUTY_DIR/bin"; chmod +x "$DUTY_DIR/bin/$(basename "$f")"; done
for f in "$HERE"/lib/*.sh; do put "$f" "$DUTY_DIR/lib"; done
for f in "$HERE"/lib/jq/*.jq; do put "$f" "$DUTY_DIR/lib/jq"; done
for f in "$HERE"/prompts/*.txt; do put "$f" "$DUTY_DIR/prompts"; done
for f in "$HERE"/conf/agents/*.conf; do put "$f" "$DUTY_DIR/conf/agents"; done
for f in "$HERE"/conf/roles/*.conf; do put "$f" "$DUTY_DIR/conf/roles"; done
put "$HERE/conf/fleet.conf" "$DUTY_DIR/conf"

# The instance resolution, re-derived every install (it is a pure function
# of the token and the manifest — never edited by hand).
tmp="$(mktemp "$DUTY_DIR/conf/.install.XXXXXX")"
{
  echo "# instance.conf — WRITTEN BY install.sh; derived from the fleet"
  echo "# manifest and this box's gh token. Do not edit; edit the manifest."
  echo "# shellcheck shell=bash disable=SC2034"
  echo "BOT_AGENT=$BOT_AGENT"
  echo "BOT_ROLES=\"$BOT_ROLE_LIST\""
} >"$tmp"
mv "$tmp" "$DUTY_DIR/conf/instance.conf"
# Remove the pre-profile fused config so nothing can source it stale.
rm -f "$DUTY_DIR/conf/bot.conf"

# Disarm the old hand-rolled layout: anything executable at ~/duty top level
# or old helper names in bin/ moves to legacy/. Old cron lines pointing at
# these paths then fail fast instead of running a parallel engine whose
# locks the new engine does not share.
LEGACY_MOVED=""
mkdir -p "$DUTY_DIR/legacy"
for old in duty.sh tick.sh hygiene.sh notify.sh submit-verdict.sh review-submit.sh \
           announce-review.sh announce-reviewing.sh submit-review.sh; do
  if [ -f "$DUTY_DIR/$old" ]; then
    mv "$DUTY_DIR/$old" "$DUTY_DIR/legacy/$old"
    LEGACY_MOVED="$LEGACY_MOVED $old"
  fi
done
for old in announce-review.sh announce-reviewing.sh submit-review.sh review-submit.sh; do
  if [ -f "$DUTY_DIR/bin/$old" ]; then
    mv "$DUTY_DIR/bin/$old" "$DUTY_DIR/legacy/bin-$old"
    LEGACY_MOVED="$LEGACY_MOVED bin/$old"
  fi
done
[ -n "$LEGACY_MOVED" ] && echo "moved old entrypoints to $DUTY_DIR/legacy/:$LEGACY_MOVED"

# Seed registries only if absent — their contents (and the reasoning in
# their comments) are box-local operator state.
if [ ! -f "$DUTY_DIR/repos.txt" ]; then
  cp "$HERE/conf/repos-default.txt" "$DUTY_DIR/repos.txt"
  echo "seeded $DUTY_DIR/repos.txt (edit it: it is the box's registry, not the job definition)"
fi
if [ "$IS_TRIAGE" -eq 1 ] && [ ! -f "$DUTY_DIR/notify-repos.txt" ]; then
  cp "$HERE/conf/notify-repos-default.txt" "$DUTY_DIR/notify-repos.txt"
  echo "seeded $DUTY_DIR/notify-repos.txt (the notifier's scope must stay WIDER than triage's — rig#112)"
fi

# Force one full boot-gate pass on the first new tick: the freshly installed
# bot.conf's CLI probe has never run on this box, and waiting for the next
# reboot to validate it means the first evidence of a wrong probe would be a
# failed session instead of the gate's loud degraded-mode alert.
rm -f "$DUTY_DIR/.boot-id"

# Version stamp: FLEET.md reconciles the deployed fleet against crew@SHA.
{
  echo "crew@$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "installed $(date -u '+%Y-%m-%dT%H:%M:%SZ') as ${ME:-<pre-auth>}"
} >"$DUTY_DIR/VERSION"

echo "installed for ${ME:-<pre-auth box>} (agent: $BOT_AGENT, roles: $BOT_ROLE_LIST)"

if [ "$ARM_CRON" -eq 1 ]; then
  # Replace any previous tick lines with the canonical one(s); everything
  # else in the crontab is preserved.
  {
    crontab -l 2>/dev/null | grep -vF "$DUTY_DIR/bin/tick.sh" || true
    echo "*/5 * * * * $DUTY_DIR/bin/tick.sh"
    [ "$IS_TRIAGE" -eq 1 ] && echo "*/5 * * * * $DUTY_DIR/bin/tick.sh notify"
  } | crontab -
  echo "crontab armed"
else
  echo
  echo "REPLACE the crontab (crontab -e) with exactly this — DELETE every old"
  echo "duty/tick/hygiene/notify line; the old and new engines do not share"
  echo "locks, and a surviving old line runs both in parallel:"
  echo "  */5 * * * * $DUTY_DIR/bin/tick.sh"
  if [ "$IS_TRIAGE" -eq 1 ]; then
    echo "  */5 * * * * $DUTY_DIR/bin/tick.sh notify"
    echo "(hygiene needs no cron line — it self-schedules inside the duty tick)"
  fi
fi
stale="$(crontab -l 2>/dev/null | grep -E 'duty|tick|hygiene|notify' | grep -vF "$DUTY_DIR/bin/tick.sh" || true)"
if [ -n "$stale" ]; then
  echo
  echo "WARNING — stale-looking cron lines found; delete these:"
  printf '%s\n' "$stale" | sed 's/^/  /'
fi
