#!/usr/bin/env bash
# drill/rehearsal.sh — the duty-engine rehearsal as one host-side script.
#
# Run on a box HOST (box + rig installed), from a crew checkout:
#
#   drill/rehearsal.sh [--agent <name>] [--box <name>] [--tree <path>]
#     [--remote <url>] [--ref <git-ref>] [--sandbox <owner/repo>] [--quick]
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

BOX_NAME=""
REF="crew/shared-duty"
REMOTE="https://github.com/dan-claude-bot/crew.git"
TREE=""
SANDBOX=""
QUICK=0
AGENT="claude"
# One box, one role — the fleet runs single-role boxes (fleet.roster), and
# a multi-role drill box would exercise a composite path nobody deploys.
# drill/rehearsal-all.sh runs the three in sequence.
ROLE="reviewer"

usage() {
  echo "usage: drill/rehearsal.sh [--agent <name>] [--role triage|builder|reviewer]"
  echo "         [--box <name>] [--tree <path>] [--remote <url>] [--ref <git-ref>]"
  echo "         [--sandbox <owner/repo>] [--quick]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT="$2"; shift 2 ;;
    --role)    ROLE="$2"; shift 2 ;;
    --box)     BOX_NAME="$2"; shift 2 ;;
    --tree)    TREE="$2"; shift 2 ;;
    --remote)  REMOTE="$2"; shift 2 ;;
    --ref)     REF="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --quick)   QUICK=1; shift ;;
    *) usage; exit 1 ;;
  esac
done

case "$ROLE" in
  triage|builder|reviewer) ;;
  *) echo "unknown --role '$ROLE' (triage, builder or reviewer)"; usage; exit 1 ;;
esac
# Per-role box and sandbox. Three boxes may share ONE gh identity without
# colliding *because* repos.txt is now the scope for every module: disjoint
# registries mean disjoint work. Under the old org-wide review sweep they
# would all have seen each other's PRs and raced.
[ -n "$BOX_NAME" ] || BOX_NAME="crew-drill-$ROLE"

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
SKIP=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
skip() { echo "skip $1"; SKIP=$((SKIP + 1)); }
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
ACQUIRE_TMP=""
# shellcheck source=drill/rehearsal-safety.sh
. "$ROOT/drill/rehearsal-safety.sh"
cleanup_all() {
  local rc=$?
  rehearsal_cleanup "$rc"
  if [ -n "$ACQUIRE_TMP" ] && [ -d "$ACQUIRE_TMP" ]; then
    rm -rf -- "$ACQUIRE_TMP"
  fi
  return "$rc"
}

command -v box >/dev/null || { echo "box CLI not found — this runs on a box host"; exit 1; }
command -v gh  >/dev/null || { echo "gh not found on the host (phase 2 needs it)"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found on the host"; exit 1; }

# --- the drill box -------------------------------------------------------
if ! box list --json 2>/dev/null | jq -e --arg n "$BOX_NAME" '.[] | select(.name == $n)' >/dev/null; then
  echo "== minting $BOX_NAME from the $AGENT-box template"
  box new --name "$BOX_NAME" --template "$AGENT-box" --cpu 2 --memory 4GiB --disk 20GiB || exit 1
fi
check "box reachable" bx "true"
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== phase 0: crew at $REF, static checks"
ACQUIRE_TMP="$(mktemp -d)"
if [ -n "$TREE" ]; then
  SOURCE_TREE="$(cd "$TREE" 2>/dev/null && pwd)" \
    || { echo "phase 0: --tree '$TREE' is not a readable directory"; exit 1; }
  SOURCE_DESC="tree $SOURCE_TREE"
else
  SOURCE_TREE="$ACQUIRE_TMP/source"
  SOURCE_DESC="remote $REMOTE ref $REF"
  if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$REF" --single-branch "$REMOTE" "$SOURCE_TREE"; then
    echo "phase 0: cannot resolve remote '$REMOTE' ref '$REF'; acquisition aborted before checks" >&2
    exit 1
  fi
fi
for required in shared/install.sh shared/test/run.sh; do
  [ -f "$SOURCE_TREE/$required" ] \
    || { echo "phase 0: $SOURCE_DESC resolved, but '$required' is missing; acquisition aborted before checks" >&2; exit 1; }
done
SOURCE_SHA="$(git -C "$SOURCE_TREE" rev-parse --verify HEAD 2>/dev/null)" \
  || { echo "phase 0: $SOURCE_DESC is not a resolved git tree"; exit 1; }
BUNDLE="$ACQUIRE_TMP/crew.bundle"
git -C "$SOURCE_TREE" bundle create "$BUNDLE" HEAD \
  || { echo "phase 0: could not bundle $SOURCE_DESC at $SOURCE_SHA"; exit 1; }
box exec "$BOX_NAME" -- bash -lc 'cat > /tmp/crew-rehearsal.bundle' <"$BUNDLE" \
  || { echo "phase 0: could not transfer the creds-free bundle into $BOX_NAME"; exit 1; }
bx "rm -rf ~/crew.rehearsal-new
    git clone --quiet /tmp/crew-rehearsal.bundle ~/crew.rehearsal-new
    test -f ~/crew.rehearsal-new/shared/install.sh
    test -f ~/crew.rehearsal-new/shared/test/run.sh
    rm -rf ~/crew
    mv ~/crew.rehearsal-new ~/crew" \
  || { echo "phase 0: transferred tree failed verification inside $BOX_NAME"; exit 1; }
RESOLVED_SHA="$(bx "git -C ~/crew rev-parse HEAD" | tr -d '\r\n')"
[ "$RESOLVED_SHA" = "$SOURCE_SHA" ] \
  || { echo "phase 0: transferred sha '$RESOLVED_SHA' does not match source '$SOURCE_SHA'"; exit 1; }
echo "== phase 0: resolved $RESOLVED_SHA from $SOURCE_DESC (creds-free inside box)"
check "fixture tests green" bx "~/crew/shared/test/run.sh | grep -q 'failed 0'"

echo "== phase 1: pre-auth engine install ($AGENT $ROLE)"
# Every drill tick is explicit. Arming cron here created an autonomous
# production bot merely to observe one scheduled boundary (#26).
bx "~/crew/shared/install.sh --agent '$AGENT' --role '$ROLE'" || fail "install"
rehearsal_disarm_cron || { echo "cannot disarm drill cron — refusing before any tick"; exit 1; }
sha="$(bx "git -C ~/crew rev-parse --short HEAD" | tr -d '\r\n')"
check "VERSION stamps crew@$sha"   bx "head -1 ~/duty/VERSION | grep -q 'crew@$sha'"
check "instance.conf $AGENT/$ROLE" bx "grep -q 'BOT_AGENT=$AGENT' ~/duty/conf/instance.conf && grep -q 'BOT_ROLES=\"$ROLE\"' ~/duty/conf/instance.conf"
check "drill is not cron-armed"    bx "! crontab -l 2>/dev/null | grep -q ~/duty/bin/tick.sh"
# A FLAGLESS reinstall re-resolves agent/role from FLEET_MANIFEST whenever the
# box's gh login has an entry. The drill borrows a fleet identity, so the
# flagless form silently replaced the role under test with that
# identity's manifest role — gating duty_review off for the rest of the run
# while every review check timed out. Reinstall with the same flags, and
# assert the role survived rather than trusting it.
check "reinstall stays disarmed"   bx "~/crew/shared/install.sh --agent '$AGENT' --role '$ROLE' && ! crontab -l 2>/dev/null | grep -q ~/duty/bin/tick.sh"
check "reinstall keeps role"       bx "grep -q 'BOT_ROLES=\"$ROLE\"' ~/duty/conf/instance.conf"
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
  skip "pre-auth: login WARN check (box was already gh-authenticated)"
  skip "pre-auth: no .boot-id marker check (box was already gh-authenticated)"
  skip "pre-auth: no sessions spawned check (box was already gh-authenticated)"
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
  # One sandbox PER ROLE. The three drill boxes may share one identity, but
  # never a registry: repos.txt is the scope for every module now, so
  # disjoint sandboxes are what keeps three concurrent drills from racing.
  [ -n "$SANDBOX" ] || SANDBOX="$HOST_ME/crew-drill-$ROLE"
  echo
  echo "== phase 2: authenticated $ROLE drills (box identity: $ME2, sandbox: $SANDBOX)"
  echo "   REMINDER: one box per identity PER SANDBOX — another box on $ME2 is safe"
  echo "   only while its repos.txt does not name $SANDBOX."

  # Sandbox repo + collaborator (invited by host, accepted by the box).
  if ! gh repo view "$SANDBOX" >/dev/null 2>&1; then
    gh repo create "$SANDBOX" --public --add-readme >/dev/null || fail "sandbox create"
  fi
  # The whole board vocabulary: triage keys on needs-triage and on strays
  # carrying none of ready/claimed/blocked/epic, and the builder keys on
  # ready. A missing label makes a fixture silently unbuildable.
  for _lbl in attention:d93f0b needs-triage:fbca04 ready:0e8a16 claimed:1d76db blocked:b60205 epic:5319e7; do
    gh api "repos/$SANDBOX/labels" -f name="${_lbl%%:*}" -f color="${_lbl##*:}" >/dev/null 2>&1 || true
  done
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
  # `gh api --jq` prints NOTHING when the filter yields null (real jq prints
  # "null"), so testing for the literal string could never match: label
  # present emitted "0", label absent emitted "". The check failed in BOTH
  # states. Compare inside the filter so a token reaches the shell either way.
  wait_for 300 "attention: label removed (ack re-arms)" bash -c \
    "gh api 'repos/$SANDBOX/issues/$inum' --jq '[.labels[].name] | index(\"attention\") == null' | grep -qx true"

  # ---- role-specific loops ---------------------------------------------
  # duty_attention above is role-independent and already ran. What follows
  # is gated on has_role in duty.sh, so each block only means anything on
  # the box that carries that role — which is why the drill is one box per
  # role rather than one box carrying all three.

  if [ "$ROLE" = "triage" ]; then
  # -- triage: a stray (no queue label) must draw a ruling --
  # duty-triage.sh detects two signals; the STRAY is the one a fixture can
  # create without presupposing triage's own vocabulary: an open issue
  # carrying none of ready/claimed/blocked/epic/needs-triage. The module
  # only DETECTS — the session does the labelling — so the assertion is on
  # what the session leaves behind, not on the signal.
  tnum="$(gh api "repos/$SANDBOX/issues" -f title="drill: triage stray $(date -u +%H%M%S)" \
    -f body="Drill fixture: an unlabelled open issue. Rule on it — leave one short ruling comment and put it in exactly one of ready/claimed/blocked (or epic). Do not open PRs." \
    --jq .number)"
  bx "~/duty/bin/tick.sh" || true
  wait_for 900 "triage: stray drew a ruling comment" bash -c \
    "gh api 'repos/$SANDBOX/issues/$tnum/comments' --jq '[.[] | select(.user.login == \"$ME2\")] | length' | grep -qv '^0$'"
  # The board invariant: no open issue may remain queue-unlabelled.
  wait_for 300 "triage: stray left the unlabelled queue" bash -c \
    "gh api 'repos/$SANDBOX/issues/$tnum' --jq '[.labels[].name] | any(. == \"ready\" or . == \"claimed\" or . == \"blocked\" or . == \"epic\" or . == \"needs-triage\")' | grep -qx true"
  # Same tick, second time: triage must not re-rule a settled issue.
  TCOMMENTS="$(gh api "repos/$SANDBOX/issues/$tnum/comments" --jq 'length')"
  bx "~/duty/bin/tick.sh" || true
  sleep 20
  check "triage: no second ruling on re-tick" bash -c \
    "[ \"\$(gh api 'repos/$SANDBOX/issues/$tnum/comments' --jq 'length')\" = '$TCOMMENTS' ]"

  elif [ "$ROLE" = "builder" ]; then
  # -- builder: an unassigned `ready` issue must become a PR --
  # ready+ASSIGNED is deliberately NOT pickable (an assignee means mid-claim;
  # counting those launched sessions with nothing to do). The fixture must
  # therefore leave the issue unassigned, or the builder correctly ignores it
  # and the drill would blame the engine for its own bad fixture.
  bnum="$(gh api "repos/$SANDBOX/issues" -f title="drill: build me $(date -u +%H%M%S)" \
    -f body="Drill fixture: add a file named drill-build.txt at the repo root containing one line. Open a PR. Keep it to that one change." \
    -f "labels[]=ready" --jq .number)"
  check "builder fixture is unassigned (ready+assigned is not pickable)" bash -c \
    "gh api 'repos/$SANDBOX/issues/$bnum' --jq '.assignees | length' | grep -qx 0"
  bx "~/duty/bin/tick.sh" || true
  wait_for 1800 "builder: opened a PR for the ready issue" bash -c \
    "gh pr list -R '$SANDBOX' --state open --author '$ME2' --json number --jq 'length' | grep -qv '^0\$'"
  bpr="$(gh pr list -R "$SANDBOX" --state open --author "$ME2" --json number --jq '.[0].number' 2>/dev/null || echo '')"
  if [ -n "$bpr" ]; then
    ok "builder: PR #$bpr authored by $ME2"
    check "builder: PR branch is build/*" bash -c \
      "gh api 'repos/$SANDBOX/pulls/$bpr' --jq .head.ref | grep -q '^build/'"
    check "builder: PR references the issue" bash -c \
      "gh api 'repos/$SANDBOX/pulls/$bpr' --jq '.body // \"\"' | grep -q '#$bnum'"
  else
    fail "builder: PR authored by $ME2"
  fi
  # The claim must be visible on the board, not just in the PR.
  wait_for 300 "builder: issue moved off ready (claimed)" bash -c \
    "gh api 'repos/$SANDBOX/issues/$bnum' --jq '[.labels[].name] | index(\"ready\") == null' | grep -qx true"
  # Re-tick must not phantom-rebuild: one PR, not two.
  BPRS="$(gh pr list -R "$SANDBOX" --state open --author "$ME2" --json number --jq 'length')"
  bx "~/duty/bin/tick.sh" || true
  sleep 20
  check "builder: no duplicate PR on re-tick" bash -c \
    "[ \"\$(gh pr list -R '$SANDBOX' --state open --author '$ME2' --json number --jq 'length')\" = '$BPRS' ]"

  else
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
fi

check "teardown: drill remains disarmed" bx "! crontab -l 2>/dev/null | grep -q ~/duty/bin/tick.sh"
echo
echo "== rehearsal summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  FAIL %s\n' "${FAILS[@]}"
  echo "Fixtures and box are left in place. Report findings on crew PR #16 with"
  echo "~/duty/duty.log and ~/duty/logs/* excerpts from: box shell $BOX_NAME"
  exit 1
fi
echo "All green. Report the pass on crew PR #16 — this clears the staged rollout."
