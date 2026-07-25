#!/usr/bin/env bash
# drill/rehearsal.sh — the duty-engine rehearsal as one host-side script.
#
# Run on a box HOST (box + rig installed), from a crew checkout:
#
#   drill/rehearsal.sh [--agent <name>] [--box <name>] [--ref <git-ref>] [--sandbox <owner/repo>] [--quick]
#
# Phase 1 (pre-auth) runs unconditionally: install the engine in the drill
# box as the selected agent (claude by default) in the reviewer role and
# verify every creds-free behavior. Phase 2 runs automatically IF the box's
# gh and selected-agent CLIs are authenticated (the
# operator logs the box in between runs; the script never touches
# credentials): it mints its own GitHub fixtures — a sandbox repo under the
# HOST's gh identity, a collaborator invite the box accepts itself, an
# attention-labelled issue, a scratch PR with a review request — and
# verifies the attention wake, the review round through both one-shot
# gates, head dedup, the re-request auto-approve, and gate abuse.
#
# Every check prints `ok <name>` or `FAIL <name>`; the script exits
# non-zero if anything failed. Fixtures and the drill box are LEFT IN
# PLACE for inspection (re-runs reuse them), but the box is always left
# disarmed and its pre-drill repo registry is restored.
#
# Companion prose: shared/docs/rehearsal.md (what each check means and why).
# shellcheck disable=SC2088  # tildes in bx "…" strings expand in the BOX's
# login shell, which is exactly where those paths live
set -uo pipefail

BOX_NAME="crew-drill"
REF="crew/shared-duty"
SANDBOX=""
QUICK=0
AGENT="claude"

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT="$2"; shift 2 ;;
    --box)     BOX_NAME="$2"; shift 2 ;;
    --ref)     REF="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --quick)   QUICK=1; shift ;;
    *) echo "usage: drill/rehearsal.sh [--agent <name>] [--box <name>] [--ref <git-ref>] [--sandbox <owner/repo>] [--quick]"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CONF="$ROOT/shared/conf/agents/$AGENT.conf"
available_agents() {
  local f
  for f in "$ROOT"/shared/conf/agents/*.conf; do
    [ -f "$f" ] && basename "$f" .conf
  done | sort | paste -sd, -
}
case "$AGENT" in
  ''|*[!A-Za-z0-9_-]*)
    echo "unknown agent '$AGENT' — available agents: $(available_agents)" >&2
    exit 1 ;;
esac
if [ ! -f "$AGENT_CONF" ]; then
  echo "unknown agent '$AGENT' — available agents: $(available_agents)" >&2
  exit 1
fi
# The host needs only the human-facing hint. The authentication probe itself
# is sourced again and executed inside the box, against the box's filesystem.
# shellcheck source=/dev/null
. "$AGENT_CONF"
LOGIN_HINT="$AGENT_LOGIN_HINT"

PASS=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAILS+=("$1"); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }
wait_for() {  # wait_for <seconds> <name> <cmd...>
  local t="$1" name="$2"; shift 2
  local end=$((SECONDS + t))
  while [ "$SECONDS" -lt "$end" ]; do
    if "$@" >/dev/null 2>&1; then ok "$name"; return 0; fi
    sleep 10
  done
  fail "$name (timeout ${t}s)"
  return 1
}
bx() { box exec "$BOX_NAME" -- bash -lc "$1"; }
# shellcheck disable=SC2034  # read and updated by rehearsal-safety.sh
REPOS_BACKUP=""
# shellcheck source=drill/rehearsal-safety.sh
. "$ROOT/drill/rehearsal-safety.sh"

command -v box >/dev/null || { echo "box CLI not found — this runs on a box host"; exit 1; }
command -v gh  >/dev/null || { echo "gh not found on the host (phase 2 needs it)"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found on the host"; exit 1; }

# --- the drill box -------------------------------------------------------
if ! box list --json 2>/dev/null | jq -e --arg n "$BOX_NAME" '.[] | select(.name == $n)' >/dev/null; then
  echo "== minting $BOX_NAME from the $AGENT-box template"
  box new --name "$BOX_NAME" --template "$AGENT-box" --cpu 2 --memory 4GiB --disk 20GiB || exit 1
fi
check "box reachable" bx "true"
trap rehearsal_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== phase 0: crew at $REF, static checks"
bx "if [ ! -d ~/crew/.git ]; then git clone --quiet https://github.com/heavy-duty/crew ~/crew; fi
    git -C ~/crew fetch --quiet origin && git -C ~/crew checkout --quiet '$REF' \
    && git -C ~/crew pull --quiet --ff-only origin '$REF' 2>/dev/null || true"
check "fixture tests green" bx "~/crew/shared/test/run.sh | grep -q 'failed 0'"

echo "== phase 1: pre-auth engine install ($AGENT reviewer)"
# Every drill tick is explicit. Arming cron here created an autonomous
# production bot merely to observe one scheduled boundary (#26).
bx "~/crew/shared/install.sh --agent '$AGENT' --role reviewer" || fail "install"
rehearsal_disarm_cron || { echo "cannot disarm drill cron — refusing before any tick"; exit 1; }
sha="$(bx "git -C ~/crew rev-parse --short HEAD" | tr -d '\r\n')"
check "VERSION stamps crew@$sha"   bx "head -1 ~/duty/VERSION | grep -q 'crew@$sha'"
check "instance.conf $AGENT/reviewer" bx "grep -q 'BOT_AGENT=$AGENT' ~/duty/conf/instance.conf && grep -q 'BOT_ROLES=\"reviewer\"' ~/duty/conf/instance.conf"
check "drill is not cron-armed"    bx "! crontab -l 2>/dev/null | grep -q ~/duty/bin/tick.sh"
check "reinstall stays disarmed"   bx "~/crew/shared/install.sh && ! crontab -l 2>/dev/null | grep -q ~/duty/bin/tick.sh"
check "bad role refused"           bx "! ~/crew/shared/install.sh --agent '$AGENT' --role nosuchrole"

GH_AUTHED=0
bx "gh auth status >/dev/null 2>&1" && GH_AUTHED=1

# An authenticated engine can act on its first explicit tick. Preserve the
# operator's registry, then point the drill at nothing until its sandbox
# exists. EXIT/INT/TERM restore it and leave no cron behind.
if [ "$GH_AUTHED" -eq 1 ]; then
  rehearsal_begin_isolation \
    || { echo "cannot isolate repos.txt — refusing before any authenticated tick"; exit 1; }
fi

bx "~/duty/bin/tick.sh" || true
check "tick evidence: run start"   bx "grep -q 'duty run start' ~/duty/duty.log"
check "tick evidence: run end"     bx "grep -q 'duty run end' ~/duty/duty.log"
check "boot check ran"             bx "test -s ~/duty/boot-check.log"
if [ "$GH_AUTHED" -eq 0 ]; then
  check "pre-auth: login WARN logged"   bx "grep -q 'cannot resolve own login' ~/duty/duty.log"
  check "pre-auth: no .boot-id marker"  bx "! test -f ~/duty/.boot-id"
  check "pre-auth: no sessions spawned" bx "! ls ~/duty/logs/*.log 2>/dev/null | grep -q ."
else
  check "authed: .boot-id written"      bx "test -f ~/duty/.boot-id"
fi
check "lock contention -> 199 + message" bx "
  flock -n ~/duty/.duty.lock -c 'sleep 6' >/dev/null 2>&1 &
  sleep 1
  out=\$(~/duty/bin/duty.sh 2>&1); rc=\$?
  wait
  [ \$rc -eq 199 ] && echo \"\$out\" | grep -q 'already holds'"

if [ "$QUICK" -eq 0 ]; then
  echo "== scheduled-boundary check omitted: rehearsal ticks are explicit and cron stays disarmed (#26)"
fi

# --- phase 2 -------------------------------------------------------------
if [ "$GH_AUTHED" -eq 0 ] || ! bx "set -a; . ~/crew/shared/conf/agents/$AGENT.conf; bot_cli_probe"; then
  echo
  echo "== phase 2 SKIPPED: box not fully authenticated."
  echo "   Log it in (box shell $BOX_NAME → gh auth login; $LOGIN_HINT),"
  echo "   ensure no OTHER box runs the same identity, then re-run this script."
else
  ME2="$(bx "gh api user --jq .login" | tr -d '\r\n')"
  HOST_ME="$(gh api user --jq .login)"
  [ -n "$SANDBOX" ] || SANDBOX="$HOST_ME/crew-drill-sandbox"
  echo
  echo "== phase 2: authenticated drills (box identity: $ME2, sandbox: $SANDBOX)"
  echo "   REMINDER: one box per identity — if another box also runs $ME2, disarm its cron first."

  # Sandbox repo + collaborator (invited by host, accepted by the box).
  if ! gh repo view "$SANDBOX" >/dev/null 2>&1; then
    gh repo create "$SANDBOX" --public --add-readme >/dev/null || fail "sandbox create"
  fi
  gh api "repos/$SANDBOX/labels" -f name=attention -f color=d93f0b >/dev/null 2>&1 || true
  if ! gh api "repos/$SANDBOX/collaborators/$ME2" >/dev/null 2>&1; then
    gh api -X PUT "repos/$SANDBOX/collaborators/$ME2" -f permission=push >/dev/null 2>&1 || true
    bx "gh api /user/repository_invitations --jq '.[] | select(.repository.full_name == \"$SANDBOX\") | .id' \
        | while read -r i; do gh api -X PATCH /user/repository_invitations/\$i >/dev/null; done"
  fi
  wait_for 60 "box is a sandbox collaborator" gh api "repos/$SANDBOX/collaborators/$ME2"
  if ! rehearsal_narrow_to_sandbox "$SANDBOX"; then
    echo "repos.txt contains something other than '$SANDBOX' — refusing before a phase 2 tick"
    exit 1
  fi
  ok "safety interlock: repos.txt contains only the sandbox"

  # -- attention wake --
  inum="$(gh api "repos/$SANDBOX/issues" -f title="drill: attention wake $(date -u +%H%M%S)" \
    -f body="Drill demand: reply with exactly one short comment acknowledging this drill, then stop. Do not open PRs." \
    -f "assignees[]=$ME2" -f "labels[]=attention" --jq .number)"
  bx "~/duty/bin/tick.sh" || true
  wait_for 900 "attention: 📌 pickup comment" bash -c \
    "gh api 'repos/$SANDBOX/issues/$inum/comments' --jq '[.[] | select(.user.login == \"$ME2\")] | length' | grep -qv '^0$'"
  wait_for 300 "attention: label removed (ack re-arms)" bash -c \
    "gh api 'repos/$SANDBOX/issues/$inum' --jq '[.labels[].name] | index(\"attention\")' | grep -q null"

  # -- review round through the gates --
  main_sha="$(gh api "repos/$SANDBOX/git/ref/heads/main" --jq .object.sha)"
  br="drill-$(date -u +%H%M%S)"
  gh api "repos/$SANDBOX/git/refs" -f ref="refs/heads/$br" -f sha="$main_sha" >/dev/null
  gh api -X PUT "repos/$SANDBOX/contents/drill.txt" -f message="drill change" \
    -f branch="$br" -f content="$(printf 'drill %s\n' "$br" | base64 -w0)" >/dev/null
  pr="$(gh api "repos/$SANDBOX/pulls" -f title="drill: review round" -f head="$br" -f base=main \
    -f body="Drill PR: review per your role; a one-line verdict body is fine." --jq .number)"
  gh api "repos/$SANDBOX/pulls/$pr/requested_reviewers" -f "reviewers[]=$ME2" >/dev/null
  head_sha="$(gh api "repos/$SANDBOX/pulls/$pr" --jq .head.sha)"
  bx "~/duty/bin/tick.sh" || true
  wait_for 900 "review: 🔎 announce at head" bash -c \
    "gh api 'repos/$SANDBOX/issues/$pr/comments' --jq '.[] | select(.user.login == \"$ME2\") | .body' | grep -q '🔎 reviewing head $head_sha'"
  verdicts() { gh api "repos/$SANDBOX/pulls/$pr/reviews" --paginate | jq -s --arg m "$ME2" --arg h "$head_sha" \
    '[add[] | select(.user.login == $m and .commit_id == $h and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))] | length'; }
  have_verdict()      { [ "$(verdicts)" -ge 1 ]; }
  verdicts_unchanged() { [ "$(verdicts)" = "$VREF" ]; }
  wait_for 1200 "review: verdict pinned to head" have_verdict

  VREF="$(verdicts)"
  bx "~/duty/bin/tick.sh" || true
  sleep 20
  check "dedup: no second verdict on re-tick" verdicts_unchanged
  check "dedup: skip logged" bx "grep -q 'already covers head' ~/duty/duty.log"

  # -- re-request at unchanged head -> auto-approve through the gate --
  gh api "repos/$SANDBOX/pulls/$pr/requested_reviewers" -f "reviewers[]=$ME2" >/dev/null
  bx "~/duty/bin/tick.sh" || true
  wait_for 300 "re-request: auto-approved (supersede)" bash -c \
    "gh api 'repos/$SANDBOX/pulls/$pr/reviews' --paginate | jq -se --arg m \"$ME2\" \
      '[add[] | select(.user.login == \$m) | .body] | any(contains(\"re-request rule\"))'"

  # -- gate abuse: identical resubmit must be a no-op --
  VREF="$(verdicts)"
  check "gate: duplicate submit refused, exit 0" bx "
    printf 'drill duplicate probe' > /tmp/drill-body
    ~/duty/bin/submit-verdict.sh '$SANDBOX' '$pr' '$head_sha' approve /tmp/drill-body 2>&1 | grep -q 'already present'"
  check "gate: verdict count unchanged" verdicts_unchanged
  check "gate: short SHA refused" bx "! ~/duty/bin/submit-verdict.sh '$SANDBOX' '$pr' abc123 approve /tmp/drill-body"
fi

check "teardown: drill remains disarmed" bx "! crontab -l 2>/dev/null | grep -q ~/duty/bin/tick.sh"
echo
echo "== rehearsal summary: $PASS ok, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  FAIL %s\n' "${FAILS[@]}"
  echo "Fixtures and box are left in place. Report findings on crew PR #16 with"
  echo "~/duty/duty.log and ~/duty/logs/* excerpts from: box shell $BOX_NAME"
  exit 1
fi
echo "All green. Report the pass on crew PR #16 — this clears the staged rollout."
