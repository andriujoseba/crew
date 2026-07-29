#!/usr/bin/env bash
# install.sh — deploy the shared duty engine from a crew checkout to ~/duty.
#
# Run from the repo root on the target box:   shared/install.sh
#
# A standing box resolves its agent and role by BOX NAME from the roster that
# the host staged in ~/duty. The shipped example is the compatibility fallback
# for a direct install from a checkout.
#
# Idempotent and state-preserving: logs, state, and clones are never touched.
# Operator registry payloads converge only while the local registry remains
# untouched (or is made byte-identical to the incoming payload); all other
# bin/lib/conf/prompts files are replaced
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

# Seed payloads are a one-install transport, never a second registry source.
# Register cleanup before any validation or sourced operator file can fail.
cleanup_seed_payloads() {
  rm -f "$DUTY_DIR/.crew-seed-repos.txt" "$DUTY_DIR/.crew-seed-notify-repos.txt"
  rm -rf "$DUTY_DIR/.crew-seed-agents"
}
trap cleanup_seed_payloads EXIT

command -v gh >/dev/null || { echo "gh not found — install and authenticate it first"; exit 1; }
command -v jq >/dev/null || { echo "jq not found — the duty engine requires it"; exit 1; }

# cron_daemon_running — is there a cron daemon to run the armed crontab at all?
# `crontab -l` proving a line exists says nothing about that (#53). pgrep is
# not guaranteed on a minimal box image, so fall back to a ps scan; the caller
# only ever uses this to choose between two messages.
cron_daemon_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
  else
    # shellcheck disable=SC2009  # the pgrep branch above is preferred; this is
    # the fallback for an image that has no pgrep, so it cannot use pgrep
    ps -e 2>/dev/null | grep -qE '[[:space:]](cron|crond)$'
  fi
}

# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/conf/fleet.defaults.conf"
OPERATOR_CONF="$DUTY_DIR/conf/fleet.conf"
if [ ! -f "$OPERATOR_CONF" ]; then OPERATOR_CONF="$HERE/../examples/fleet.conf"; fi
# shellcheck disable=SC1090
source "$OPERATOR_CONF"

# --- Resolve this box's configuration, one of three ways ---
#  explicit  --agent X --role Y   pre-auth bake (crew new): no gh identity
#                                 needed — the boot gate screams until the
#                                 operator logs in, which is correct.
#  roster    --box NAME → fleet.roster (standing fleet).
#  keep      existing conf/instance.conf (re-install/upgrade on a box whose
#            name is not in the roster).
AGENT_ARG="" ROLE_ARG="" BOX_ARG="" ARM_CRON=0 CONVERGE_REGISTRIES=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT_ARG="$2"; shift 2 ;;
    --role)  ROLE_ARG="$2";  shift 2 ;;
    --box)   BOX_ARG="$2";   shift 2 ;;
    --converge-registries) CONVERGE_REGISTRIES=1; shift ;;
    --arm-cron) ARM_CRON=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown argument '$1' (usage: install.sh [--box <name> | --agent <a> --role <r>] [--arm-cron] [--force])"; exit 1 ;;
  esac
done

# --- The engine on this box is not overwritten in silence (#159) -------------
# A re-install replaces bin/, lib/, prompts/ and the profiles in place. Whatever
# the box was carrying — a hotfix, a debug probe, a half-finished experiment —
# is gone, and until now nothing said so: two defect reports and a 20-assertion
# test suite existed only on a box on 2026-07-29, and the next upgrade would
# have deleted all three without a word.
#
# The refusal IS the feature. The operator learns the box was patched at the
# last moment that knowledge is still useful. --force proceeds, as before.
#
# Three properties of where this sits:
#   · BEFORE anything is written, so a refusal changes nothing at all;
#   · in the installer rather than in `crew upgrade`, because the installer is
#     what overwrites — `crew hire` and `crew up` reach the same files and must
#     meet the same refusal;
#   · run from the INCOMING tree ($HERE), never the installed copy under
#     ~/duty/bin, which is the thing under suspicion.
# A box with no record (installed before content stamping) reads `unverified`
# and is NOT refused: the whole fleet blocking on the day this ships is how an
# instrument gets forced off with --force and never trusted again.
MANIFEST_TOOL="$HERE/bin/engine-manifest.sh"
if [ "$FORCE" -eq 0 ] && [ -x "$MANIFEST_TOOL" ]; then
  ENGINE_REPORT="$(env DUTY_DIR="$DUTY_DIR" "$MANIFEST_TOOL" --report --paths 2>/dev/null || true)"
  if [ "$(printf '%s\n' "$ENGINE_REPORT" | sed -n 's/^state=//p' | head -1)" = modified ]; then
    DIVERGED_FROM="$(printf '%s\n' "$ENGINE_REPORT" | sed -n 's/^recorded=//p' | head -1)"
    echo "crew: REFUSING to overwrite a MODIFIED engine in $DUTY_DIR" >&2
    echo "crew: these files are not what ${DIVERGED_FROM:-its recorded install} shipped:" >&2
    printf '%s\n' "$ENGINE_REPORT" | sed -n 's/^path=/crew:   · /p' >&2
    echo "crew: save anything you need from them — a re-install replaces every one." >&2
    echo "crew: then run the same command again with --force." >&2
    exit 1
  fi
fi

# Capture the pre-install profile without sourcing it, so the resolved values
# below cannot overwrite the evidence used to report a change (#36).
PRIOR_EXISTS=0 PRIOR_AGENT="" PRIOR_ROLES=""
if [ -f "$DUTY_DIR/conf/instance.conf" ]; then
  PRIOR_EXISTS=1
  PRIOR_AGENT="$(sed -n 's/^BOT_AGENT=//p' "$DUTY_DIR/conf/instance.conf" | head -1 | tr -d '"'\''\r')"
  PRIOR_ROLES="$(sed -n 's/^BOT_ROLES=//p' "$DUTY_DIR/conf/instance.conf" | head -1 | tr -d '"'\''\r')"
fi

if [ -n "$AGENT_ARG" ] || [ -n "$ROLE_ARG" ]; then
  [ -z "$BOX_ARG" ] || { echo "--box and --agent/--role are alternatives"; exit 1; }
  if [ -z "$AGENT_ARG" ] || [ -z "$ROLE_ARG" ]; then
    echo "--agent and --role go together"; exit 1
  fi
  BOT_AGENT="$AGENT_ARG"
  BOT_ROLE_LIST="$(printf '%s' "$ROLE_ARG" | tr ',' ' ')"
  RESOLVED_FROM="the --agent/--role flags"
elif [ -n "$BOX_ARG" ]; then
  ROSTER_SOURCE="$DUTY_DIR/fleet.roster"
  if [ ! -f "$ROSTER_SOURCE" ]; then ROSTER_SOURCE="$HERE/../examples/fleet.roster"; fi
  resolved="$(awk -v box="$BOX_ARG" '$1 == box {print $2, $3; exit}' "$ROSTER_SOURCE")"
  if [ -z "$resolved" ]; then
    echo "cannot resolve box '$BOX_ARG': no fleet.roster entry"
    exit 1
  fi
  read -r BOT_AGENT BOT_ROLE_LIST <<<"$resolved"
  BOT_ROLE_LIST="$(printf '%s' "$BOT_ROLE_LIST" | tr ',' ' ')"
  RESOLVED_FROM="fleet.roster (box $BOX_ARG)"
elif [ -f "$DUTY_DIR/conf/instance.conf" ]; then
  # shellcheck disable=SC1091
  source "$DUTY_DIR/conf/instance.conf"
  BOT_ROLE_LIST="$BOT_ROLES"
  RESOLVED_FROM="the existing instance.conf"
else
  echo "cannot resolve this box's configuration: pass --box <fleet-name>"
  echo "or --agent <agent> --role <role>; no existing instance.conf to keep"
  exit 1
fi
# An operator-transported profile satisfies the unknown-agent check: the host
# stages it into the seed dir BEFORE running this script (#75), precisely
# because this validation runs before conf/agents exists below — a profile
# that arrived only with that copy would fail its own validation, and the
# vendor would list in `crew profiles` yet die at `crew hire`.
AGENT_SEED_DIR="$DUTY_DIR/.crew-seed-agents"
[ -f "$AGENT_SEED_DIR/$BOT_AGENT.conf" ] || [ -f "$HERE/conf/agents/$BOT_AGENT.conf" ] ||
  { echo "unknown agent profile '$BOT_AGENT'"; exit 1; }
for role in $BOT_ROLE_LIST; do
  [ -f "$HERE/conf/roles/$role.conf" ] || { echo "unknown role profile '$role'"; exit 1; }
done

# A changed role adds or removes whole duty loops. Convergence is intentional,
# but it must never read like a no-op (#36). Changes survive stdout redirection.
CHANGE_NOTE="unchanged"
if [ "$PRIOR_EXISTS" -eq 0 ]; then
  CHANGE_NOTE="first install"
else
  changed=0
  if [ "$PRIOR_AGENT" != "$BOT_AGENT" ]; then
    echo "crew: AGENT CHANGED on this box: \"$PRIOR_AGENT\" -> \"$BOT_AGENT\"" >&2
    changed=1
  fi
  if [ "$PRIOR_ROLES" != "$BOT_ROLE_LIST" ]; then
    echo "crew: ROLES CHANGED on this box: \"$PRIOR_ROLES\" -> \"$BOT_ROLE_LIST\"" >&2
    echo "crew: this adds or removes whole duty loops — duty.sh gates every module on has_role" >&2
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    echo "crew: resolved from $RESOLVED_FROM" >&2
    CHANGE_NOTE="CHANGED — see the lines above"
  fi
fi

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
# Operator profiles land AFTER the shipped set so a same-named operator
# profile wins: load_conf sources whatever sits in conf/agents at runtime, so
# the precedence must be settled here, in the copy, not left to a reader.
# Absent seeds mean a direct-checkout install; the shipped set alone is the
# compatibility fallback, same as the roster above.
for f in "$AGENT_SEED_DIR"/*.conf; do
  [ -f "$f" ] || continue
  put "$f" "$DUTY_DIR/conf/agents"
done
for f in "$HERE"/conf/roles/*.conf; do put "$f" "$DUTY_DIR/conf/roles"; done
put "$HERE/conf/fleet.defaults.conf" "$DUTY_DIR/conf"
if [ "$OPERATOR_CONF" != "$DUTY_DIR/conf/fleet.conf" ]; then
  put "$OPERATOR_CONF" "$DUTY_DIR/conf"
fi

# The instance resolution, re-derived every install (it is a pure function
# of the box name and fleet.roster — never edited by hand).
tmp="$(mktemp "$DUTY_DIR/conf/.install.XXXXXX")"
{
  echo "# instance.conf — WRITTEN BY install.sh; derived from the fleet"
  echo "# roster and this box's name. Do not edit; edit fleet.roster."
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

# Registry convergence carries a per-box veto. An untouched copy follows the
# host; a locally changed copy is containment state and is never widened.
REPOS_SEED="$DUTY_DIR/.crew-seed-repos.txt"
NOTIFY_REPOS_SEED="$DUTY_DIR/.crew-seed-notify-repos.txt"
if [ ! -f "$REPOS_SEED" ]; then REPOS_SEED="$HERE/../examples/repos.txt"; fi
if [ ! -f "$NOTIFY_REPOS_SEED" ]; then NOTIFY_REPOS_SEED="$HERE/../examples/notify-repos.txt"; fi

replace_registry() { # SOURCE DESTINATION PROVENANCE
  local src="$1" dest="$2" provenance="$3" tmp hash_tmp incoming_hash
  incoming_hash="$(sha256sum "$src" | awk '{print $1}')"
  tmp="$(mktemp "$DUTY_DIR/.registry.XXXXXX")"
  cp "$src" "$tmp"
  mv "$tmp" "$dest"
  hash_tmp="$(mktemp "$DUTY_DIR/.registry-hash.XXXXXX")"
  printf '%s\n' "$incoming_hash" >"$hash_tmp"
  mv "$hash_tmp" "$provenance"
}

apply_registry() { # PAYLOAD DESTINATION SHIPPED_EXAMPLE PROVENANCE LABEL
  local payload="$1" dest="$2" example="$3" provenance="$4" label="$5"
  local current_hash incoming_hash recorded_hash example_hash
  if [ "$CONVERGE_REGISTRIES" -eq 0 ]; then
    if [ ! -f "$dest" ]; then cp "$payload" "$dest"; echo "seeded $dest"; fi
    return
  fi
  command -v sha256sum >/dev/null || { echo "sha256sum not found — registry provenance requires it"; exit 1; }
  incoming_hash="$(sha256sum "$payload" | awk '{print $1}')"
  if [ ! -f "$dest" ]; then
    replace_registry "$payload" "$dest" "$provenance"
    echo "converged $dest from the operator fleet definition"
    return
  fi
  current_hash="$(sha256sum "$dest" | awk '{print $1}')"
  if [ -f "$provenance" ]; then
    recorded_hash="$(head -1 "$provenance")"
    if [ "$current_hash" = "$recorded_hash" ] || [ "$current_hash" = "$incoming_hash" ]; then
      replace_registry "$payload" "$dest" "$provenance"
      if [ "$current_hash" = "$incoming_hash" ] && [ "$current_hash" != "$recorded_hash" ]; then
        echo "adopted and converged $dest from the operator fleet definition"
      else
        echo "converged $dest from the operator fleet definition"
      fi
      return
    fi
  else
    example_hash="$(sha256sum "$example" | awk '{print $1}')"
    if [ "$current_hash" = "$example_hash" ] || [ "$current_hash" = "$incoming_hash" ]; then
      replace_registry "$payload" "$dest" "$provenance"
      echo "adopted and converged $dest from the operator fleet definition"
      return
    fi
  fi
  echo "crew: ${BOX_ARG:-this box}: $label diverged from its last transported value — LEFT UNCHANGED" >&2
  echo "crew: to adopt it, make $dest byte-identical to the host's $label and run crew upgrade again" >&2
}

apply_registry "$REPOS_SEED" "$DUTY_DIR/repos.txt" "$HERE/../examples/repos.txt" \
  "$DUTY_DIR/.repos.txt.crew-provenance" repos.txt
if [ "$IS_TRIAGE" -eq 1 ]; then
  apply_registry "$NOTIFY_REPOS_SEED" "$DUTY_DIR/notify-repos.txt" \
    "$HERE/../examples/notify-repos.txt" "$DUTY_DIR/.notify-repos.txt.crew-provenance" notify-repos.txt
fi
rm -f "$DUTY_DIR/.crew-seed-repos.txt" "$DUTY_DIR/.crew-seed-notify-repos.txt"
rm -rf "$DUTY_DIR/.crew-seed-agents"
# A registry seeded before 2026-07-25 carries the SUPERSEDED header, which told
# its reader the reviewer queue was an org-wide requested_reviewers sweep that
# "this list cannot scope". duty-review.sh and duty-builder.sh are both
# registry-scoped now, so that paragraph denies containment the engine actually
# provides — and an operator reading it concludes the drill's isolation
# interlock cannot cover the reviewer, which is how #52 came to be filed
# against an engine that had already been fixed. A divergent registry remains
# box-local containment state; the false claim is flagged without rewriting it.
if grep -q 'cannot scope it' "$DUTY_DIR/repos.txt" 2>/dev/null; then
  echo
  echo "NOTE — $DUTY_DIR/repos.txt carries the pre-2026-07-25 header, which says the"
  echo "reviewer queue is org-wide and that no list can scope it. That is no longer true:"
  echo "repos.txt is the scope for review, build, triage and hygiene alike. Refresh the"
  echo "comment block from $HERE/../examples/repos.txt — your repo lines are yours to keep."
fi

# Force one full boot-gate pass on the first new tick: the freshly installed
# bot.conf's CLI probe has never run on this box, and waiting for the next
# reboot to validate it means the first evidence of a wrong probe would be a
# failed session instead of the gate's loud degraded-mode alert.
rm -f "$DUTY_DIR/.boot-id"

# The release version is identity; Git is optional provenance. Installed
# source trees deliberately have no .git, so a SHA can never be the stable
# value hire idempotency depends on.
CREW_VERSION="$(head -1 "$HERE/../VERSION" | tr -d '\r\n')"
CREW_SHA="$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || true)"
{
  if [ -n "$CREW_SHA" ]; then
    echo "crew@$CREW_VERSION ($CREW_SHA)"
  else
    echo "crew@$CREW_VERSION"
  fi
  echo "installed $(date -u '+%Y-%m-%dT%H:%M:%SZ') (agent=$BOT_AGENT roles=$BOT_ROLE_LIST)"
} >"$DUTY_DIR/VERSION"

# ...and what that version actually put here, hashed (#159). Recorded LAST, so
# it describes the tree as it now stands, and from the installed copy of the
# tool, so the record can only ever be written by the algorithm that will read
# it back. Identical bytes hash identically, so a converging re-run stays
# converging and the box stays `current`.
#
# A failure here does NOT fail the install: the box reads `unverified`, which is
# honest, and losing a working engine deployment over its instrument would be
# the wrong trade in both directions.
if ! env DUTY_DIR="$DUTY_DIR" "$DUTY_DIR/bin/engine-manifest.sh" --record 2>/dev/null; then
  echo "crew: WARNING — could not record the engine manifest; this box will read 'unverified'" >&2
fi

echo "installed (agent: $BOT_AGENT, roles: $BOT_ROLE_LIST)"
echo "  agent/role resolved from $RESOLVED_FROM — $CHANGE_NOTE"

if [ "$ARM_CRON" -eq 1 ]; then
  # Deliberately check after the atomic file install: a missing host package
  # must not discard a valid engine deployment, and install.sh is idempotent.
  # The resulting state is explicit and recoverable — installed, not armed —
  # while installing OS packages remains an administrator's responsibility.
  if ! command -v crontab >/dev/null 2>&1; then
    echo "crew: engine installed, but cron is not armed: the 'crontab' command is missing." >&2
    echo "crew: an administrator must install Debian/Ubuntu's cron package:" >&2
    echo "  sudo apt-get install cron" >&2
    echo "crew: this unprivileged installer will not perform that admin step." >&2
    echo "crew: then converge the installed engine by re-running:" >&2
    echo "  $HERE/install.sh --arm-cron" >&2
    exit 1
  fi
  # Replace any previous tick lines with the canonical one(s); everything
  # else in the crontab is preserved.
  {
    crontab -l 2>/dev/null | grep -vF "$DUTY_DIR/bin/tick.sh" || true
    echo "*/5 * * * * $DUTY_DIR/bin/tick.sh"
    if [ "$IS_TRIAGE" -eq 1 ]; then
      echo "*/5 * * * * $DUTY_DIR/bin/tick.sh notify"
    fi
  } | crontab -
  echo "crontab armed"
  # "armed" has only ever meant "the line is in the table". A box whose cron
  # DAEMON is not running reported `crontab armed` from `crew hire` and then
  # never ticked: three boxes armed the same way, one producing duty.log
  # output, and nothing in any output said which (#53).
  #
  # Worth stating plainly because it is the diagnosis the observation needed:
  # duty.sh logs `duty run start` before any role dispatch and `duty run end`
  # on every exit path, and tick.sh covers the rest (skipped, FAILED). An idle
  # tick is therefore NOT silent — a duty.log with nothing new means no tick
  # RAN, never a tick that ran and found no work. So a silent box is a cron
  # problem, and this is the moment to catch it.
  if cron_daemon_running; then
    echo "cron daemon running — first tick at the next 5-minute boundary"
  else
    echo "crew: WARNING — the crontab is armed, but NO cron daemon is running:" >&2
    echo "crew: this box will never tick, and its duty.log will stay silent." >&2
    echo "crew: an administrator must start it:  sudo service cron start" >&2
    echo "crew: then confirm a tick lands:       tail -f $DUTY_DIR/duty.log" >&2
  fi
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
stale=""
if command -v crontab >/dev/null 2>&1; then
  stale="$(crontab -l 2>/dev/null | grep -E 'duty|tick|hygiene|notify' | grep -vF "$DUTY_DIR/bin/tick.sh" || true)"
fi
if [ -n "$stale" ]; then
  echo
  echo "WARNING — stale-looking cron lines found; delete these:"
  printf '%s\n' "$stale" | sed 's/^/  /'
fi
