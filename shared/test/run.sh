#!/usr/bin/env bash
# test/run.sh — fixture tests for the duty engine's pure logic. No gh, no
# network: everything here runs on bash+jq alone, in CI and on any box.
#
# These exist because three of five bots' self-assessments asked for exactly
# this ("fixture tests for detection predicates", "contract tests for the
# duty scripts", "plumbing one-liners deserve tests") and because the
# corpus-shaped blocker fixtures encode postmortem lesson 9: the parser must
# tolerate real issue-body prose, not parser-shaped strings.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(dirname "$HERE")"
ROOT="$(dirname "$SHARED")"
PASS=0 FAIL=0

t() {  # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

# Source common.sh against a scratch DUTY_DIR.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck disable=SC1091
source "$SHARED/lib/common.sh"

# --- read_repo_list: comments (incl. inline), blanks, whitespace, missing
# trailing newline
printf '# a comment\nheavy-duty/ceremony\n\n  heavy-duty/rig  # inline note\n# tail\nheavy-duty/incubator' >"$TMP/repos.txt"
t repo-list "heavy-duty/ceremony
heavy-duty/rig
heavy-duty/incubator" "$(read_repo_list "$TMP/repos.txt")"
t repo-list-missing "" "$(read_repo_list "$TMP/nope.txt")"

# --- render_prompt: multiple slots, repeated slots, untouched unknowns
mkdir -p "$TMP/prompts"
printf 'You are {{ME}} in {{REPO}}; {{ME}} again; {{UNSET}} stays.' >"$TMP/prompts/x.txt"
t render "You are bot in o/r; bot again; {{UNSET}} stays." \
  "$(render_prompt x.txt ME=bot REPO=o/r)"

# --- has_role
# shellcheck disable=SC2034  # consumed by has_role inside sourced common.sh
BOT_ROLES="builder reviewer"
has_role builder && r1=yes || r1=no
has_role triage && r2=yes || r2=no
t has-role-yes yes "$r1"
t has-role-no no "$r2"

# --- manifest_lookup: agent + roles resolution
# shellcheck disable=SC2034  # consumed inside sourced common.sh
FLEET_MANIFEST="
dan-claude-bot=claude:triage
claude-bot-andresmgsl=claude:builder,reviewer
"
t manifest-single "claude triage" "$(manifest_lookup dan-claude-bot)"
t manifest-multi "claude builder reviewer" "$(manifest_lookup claude-bot-andresmgsl)"
manifest_lookup nobody-bot >/dev/null && r1=found || r1=absent
t manifest-missing absent "$r1"

# --- agent profiles and rehearsal selection -----------------------------
for profile in "$SHARED"/conf/agents/*.conf; do
  agent="$(basename "$profile" .conf)"
  if bash -c '. "$1"; type bot_cli_probe >/dev/null; test -n "$AGENT_LOGIN_HINT"' _ "$profile"; then
    r1=sourceable
  else
    r1=broken
  fi
  t "agent-conf-$agent-standalone" sourceable "$r1"
done

if unknown_out="$(bash "$ROOT/drill/rehearsal.sh" --agent nosuchagent 2>&1)"; then
  unknown_rc=0
else
  unknown_rc=$?
fi
t rehearsal-unknown-agent-rc 1 "$unknown_rc"
case "$unknown_out" in
  *"unknown agent 'nosuchagent'"*"claude"*"codex"*"grok"*"kimi"*) r1=listed ;;
  *) r1=missing ;;
esac
t rehearsal-unknown-agent-list listed "$r1"

# --- install.sh: crontab preflight and convergence (#25) ----------------
# A curated PATH makes "crontab absent" deterministic even on a workstation
# that happens to have cron installed. Everything install.sh legitimately
# needs is linked in; gh and git are fixture shims.
ISHIM="$TMP/install-bin"
IHOME="$TMP/install-home"
IDUTY="$IHOME/duty"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM" "$IHOME"
for cmd in bash basename cat chmod cp date dirname grep mkdir mktemp mv rm sed tr wc; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
printf '#!/usr/bin/env bash\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
chmod +x "$ISHIM/gh" "$ISHIM/git"

install_fixture() {
  env HOME="$IHOME" DUTY_DIR="$IDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" --agent claude --role reviewer "$@"
}

if install_out="$(install_fixture 2>&1)"; then r1=0; else r1=$?; fi
t install-no-cron-no-arm-rc 0 "$r1"
case "$install_out" in *"REPLACE the crontab"*) r1=manual ;; *) r1=missing ;; esac
t install-no-cron-no-arm-instructions manual "$r1"
case "$install_out" in *"command not found"*) r1=leaked ;; *) r1=clean ;; esac
t install-no-cron-no-arm-clean clean "$r1"

printf '15 3 * * * unrelated-job\n' >"$CRON_STATE"
before_cron="$(cat "$CRON_STATE")"
if install_out="$(install_fixture --arm-cron 2>&1)"; then r1=0; else r1=$?; fi
t install-no-cron-arm-rc 1 "$r1"
case "$install_out" in
  *"engine installed, but cron is not armed"*"administrator"*"sudo apt-get install cron"*"install.sh --arm-cron"*) r1=actionable ;;
  *) r1=missing ;;
esac
t install-no-cron-arm-message actionable "$r1"
case "$install_out" in *"command not found"*) r1=leaked ;; *) r1=clean ;; esac
t install-no-cron-arm-attributed clean "$r1"
t install-no-cron-arm-untouched "$before_cron" "$(cat "$CRON_STATE")"
[ -f "$IDUTY/VERSION" ] && r1=installed || r1=missing
t install-no-cron-arm-files-remain installed "$r1"

# shellcheck disable=SC2016  # fixture script expands these at execution time
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -l) [ ! -f "$CRON_STATE" ] || cat "$CRON_STATE" ;;\n  -) tmp="$CRON_STATE.new"; cat >"$tmp"; mv "$tmp" "$CRON_STATE" ;;\n  *) tmp="$CRON_STATE.new"; cat "$1" >"$tmp"; mv "$tmp" "$CRON_STATE" ;;\nesac\n' >"$ISHIM/crontab"
chmod +x "$ISHIM/crontab"
if install_out="$(install_fixture --arm-cron 2>&1)"; then r1=0; else r1=$?; fi
t install-with-cron-arm-rc 0 "$r1"
case "$install_out" in *"crontab armed"*) r1=armed ;; *) r1=missing ;; esac
t install-with-cron-arm-output armed "$r1"
t install-with-cron-preserves-existing 1 "$(grep -cF 'unrelated-job' "$CRON_STATE")"
t install-with-cron-one-tick 1 "$(grep -cF "$IDUTY/bin/tick.sh" "$CRON_STATE")"
install_fixture --arm-cron >/dev/null 2>&1
t install-with-cron-rerun-one-tick 1 "$(grep -cF "$IDUTY/bin/tick.sh" "$CRON_STATE")"

# --- rehearsal safety: isolate, fail closed, restore, disarm (#26) -------
RHOME="$TMP/rehearsal-home"
RDUTY="$RHOME/duty"
RCRON="$TMP/rehearsal-crontab"
mkdir -p "$RDUTY"
printf 'heavy-duty/ceremony\nheavy-duty/incubator\nheavy-duty/rig\n' >"$RDUTY/repos.txt"
printf '*/5 * * * * %s/bin/tick.sh\n17 2 * * * unrelated-job\n' "$RDUTY" >"$RCRON"
# shellcheck disable=SC2034  # consumed by sourced rehearsal safety functions
BOX_NAME=fixture
# shellcheck disable=SC2034  # consumed by sourced rehearsal safety functions
REPOS_BACKUP=""
BX_FAIL_WRITE=0
bx() {
  case "$1" in
    "printf "*" > ~/duty/repos.txt") [ "$BX_FAIL_WRITE" -eq 0 ] || return 1 ;;
  esac
  HOME="$RHOME" PATH="$ISHIM" CRON_STATE="$RCRON" bash -c "$1"
}
# shellcheck source=drill/rehearsal-safety.sh
source "$ROOT/drill/rehearsal-safety.sh"

rehearsal_begin_isolation && r1=isolated || r1=failed
t rehearsal-isolates-before-tick isolated "$r1"
t rehearsal-isolation-empty 0 "$(wc -l <"$RDUTY/repos.txt")"
rehearsal_narrow_to_sandbox owner/sandbox && r1=narrowed || r1=failed
t rehearsal-narrow-success narrowed "$r1"
t rehearsal-narrow-exact owner/sandbox "$(cat "$RDUTY/repos.txt")"
BX_FAIL_WRITE=1
rehearsal_narrow_to_sandbox owner/other && r1=continued || r1=refused
t rehearsal-narrow-fails-closed refused "$r1"
BX_FAIL_WRITE=0
rehearsal_cleanup 0
t rehearsal-restores-registry "heavy-duty/ceremony
heavy-duty/incubator
heavy-duty/rig" "$(cat "$RDUTY/repos.txt")"
t rehearsal-disarms-tick 0 "$(grep -cF "$RDUTY/bin/tick.sh" "$RCRON")"
t rehearsal-preserves-unrelated-cron 1 "$(grep -cF unrelated-job "$RCRON")"

# --- rehearsal phase 0: acquisition failures abort before checks (#27) --
P0SHIM="$TMP/phase0-bin"
P0HOME="$TMP/phase0-home"
P0LOG="$TMP/phase0-box.log"
mkdir -p "$P0SHIM" "$P0HOME"
# shellcheck disable=SC2016  # fixture expands state at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0LOG"\ncase "$1" in\n  list) printf "[]\\n" ;;\n  new|exec) exit 0 ;;\n  *) exit 2 ;;\nesac\n' >"$P0SHIM/box"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0SHIM/gh"
chmod +x "$P0SHIM/box" "$P0SHIM/gh"

if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --remote "$TMP/no-such-remote" \
    --ref nosuchbranch --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t rehearsal-bad-ref-rc 1 "$r1"
case "$p0out" in *"remote '$TMP/no-such-remote'"*"ref 'nosuchbranch'"*"aborted before checks"*) r1=attributed ;; *) r1=missing ;; esac
t rehearsal-bad-ref-attributed attributed "$r1"
t rehearsal-bad-ref-no-tick 0 "$(grep -cF 'exec crew-drill -- bash -lc ~/duty/bin/tick.sh' "$P0LOG" || true)"
case "$p0out" in *"fixture tests green"*|*"FAIL install"*) r1=cascaded ;; *) r1=stopped ;; esac
t rehearsal-bad-ref-no-cascade stopped "$r1"

BADTREE="$TMP/bad-tree"
mkdir -p "$BADTREE"
git -C "$BADTREE" init -q
printf 'not the engine\n' >"$BADTREE/README.md"
git -C "$BADTREE" add README.md
git -C "$BADTREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$BADTREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t rehearsal-invalid-tree-rc 1 "$r1"
case "$p0out" in *"shared/install.sh"*"missing"*"aborted before checks"*) r1=attributed ;; *) r1=missing ;; esac
t rehearsal-invalid-tree-attributed attributed "$r1"

# --- validate_sha
validate_sha "0123456789abcdef0123456789abcdef01234567" && r1=ok || r1=bad
validate_sha "0123456" && r2=ok || r2=bad
validate_sha "g123456789abcdef0123456789abcdef01234567" && r3=ok || r3=bad
t sha-full ok "$r1"
t sha-short bad "$r2"
t sha-nonhex bad "$r3"

# --- blockers.jq: corpus-shaped fixtures --------------------------------
BJQ="$SHARED/lib/jq/blockers.jq"
S='{"5":"CLOSED","6":"MERGED","10":"CLOSED","7":"OPEN"}'

# The canonical body shape from the triage contract, all blockers landed —
# including one inside the clause's parentheses; "Blocks #13" is the inverse
# relation and must not parse.
b1='[{"number":21,"body":"Part of #1. Blocked by #5, #6 (and #10 for the bootstrap). Blocks #13 (needs a tag)."}]'
t blockers-landed "21" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b1")"

# One blocker still open → stays blocked.
b2='[{"number":22,"body":"Blocked by #5 and #7."}]'
t blockers-open "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b2")"

# Unknown number → fail-safe: counts as still-open.
b3='[{"number":23,"body":"Blocked by #999."}]'
t blockers-unknown "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b3")"

# Cross-repo blocker must NOT resolve against the local number map — triage
# flips those by hand (TRIAGE.md). #5 is CLOSED locally, but this "#5" is
# other-org/other-repo#5.
b4='[{"number":24,"body":"Blocked by other-org/other-repo#5."}]'
t blockers-crossrepo "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b4")"

# Lowercase clause, sentence-final stop honored: #7 after the period is not
# part of the clause.
b5='[{"number":25,"body":"blocked by #5. Also mentions #7 later."}]'
t blockers-lowercase "25" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b5")"

# No clause at all → no lead.
b6='[{"number":26,"body":"Depends on vibes."},{"number":27,"body":null}]'
t blockers-none "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b6")"

# Two issues, one unblockable → only that one reported.
b7='[{"number":28,"body":"Blocked by #5."},{"number":29,"body":"Blocked by #7."}]'
t blockers-mixed "28" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b7")"

# --- converged.jq: handoff predicate ------------------------------------
CJQ="$SHARED/lib/jq/converged.jq"
PANEL='["rev-a","rev-b"]'
mk_pr() {  # head mergeable labels requests reviews
  jq -n --arg head "$1" --arg m "$2" --argjson labels "$3" --argjson reqs "$4" --argjson revs "$5" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
REVS_STALE='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]'

t converged-true true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-outstanding-req false \
  "$(mk_pr "$H" MERGEABLE '[]' '["rev-b"]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-offpanel-req-ignored true \
  "$(mk_pr "$H" MERGEABLE '[]' '["danmt"]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-stale-approval false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_STALE" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-already-handed false \
  "$(mk_pr "$H" MERGEABLE '["state:needs-human"]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-unknown-mergeable defer-unknown \
  "$(mk_pr "$H" UNKNOWN '[]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-conflicting false \
  "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
# An empty panel must never converge vacuously (bare panel= line).
t converged-empty-panel false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | jq -r --argjson panel '[]' --arg needs_human state:needs-human -f "$CJQ")"

# --- rotate_log
printf 'x' >"$TMP/small.log"
rotate_log "$TMP/small.log"
[ -f "$TMP/small.log" ] && r1=kept || r1=gone
t rotate-small kept "$r1"

# --- seen-ledgers: ledger_filter / ledger_commit (the refire fix) ---------
# A wake whose signal is present but UNCHANGED must not re-launch a session;
# it may only wake on new-or-advanced activity. This is what stops the mention
# and held-discussion refire that burned the triage box's Fable quota.
LG="$TMP/ledger"
n() { awk 'NF{c++} END{print c+0}'; }
# cold ledger (first look): everything is new
t ledger-cold 2 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_commit "$LG"
# same state again: SUPPRESSED (the burn fix)
t ledger-suppress 0 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
# one timestamp advanced: only that id re-wakes
t ledger-advance "111 2026-07-24T20:30:00Z" "$(printf '111 2026-07-24T20:30:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG")"
# brand-new id wakes
t ledger-newid 1 "$(printf '333 2026-07-25T01:00:00Z\n' | ledger_filter "$LG" | n)"
# commit is monotonic: a stale (older) commit must not lower the mark
printf '111 2026-07-24T20:30:00Z\n' | ledger_commit "$LG"
printf '111 2026-07-01T00:00:00Z\n' | ledger_commit "$LG"
t ledger-monotonic 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"
# empty input is safe and preserves the ledger (no session -> nothing to commit)
printf '' | ledger_commit "$LG"
t ledger-empty-safe 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"

# cross-repo collision: discussion numbers are PER-REPO but the ledger is one
# file across every repo in repos.txt, so keys must be repo-qualified. After
# committing ceremony#1, an unchanged/older rig#1 must still wake — a bare "1"
# key would shadow it and triage would never see rig's discussion (codex, #16).
LG2="$TMP/ledger-disc"
printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_commit "$LG2"
t ledger-crossrepo-distinct 1 "$(printf 'heavy-duty/rig#1 2026-07-20T00:00:00Z\n' | ledger_filter "$LG2" | n)"
t ledger-crossrepo-samekey  0 "$(printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_filter "$LG2" | n)"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
