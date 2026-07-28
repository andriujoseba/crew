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
for cmd in awk bash basename cat chmod cp date dirname grep head mkdir mktemp mv rm sed sha256sum tr wc; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
# If install.sh ever infers from hostname again, make the regression reproduce
# the dangerous case deterministically rather than depend on this test host.
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
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

# --- install.sh: fleet.roster is the one agent/role declaration (#35) ----
RHOME="$TMP/roster-home"
RDUTY="$RHOME/duty"
mkdir -p "$RHOME"
roster_install() {
  env HOME="$RHOME" DUTY_DIR="$RDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
roster_install --box claude-builder >/dev/null 2>&1
t install-roster-hire-role 'BOT_ROLES="builder"' "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"
roster_install --box claude-builder >/dev/null 2>&1
t install-roster-upgrade-keeps-role 'BOT_ROLES="builder"' "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"
t install-roster-agent 'BOT_AGENT=claude' "$(grep '^BOT_AGENT=' "$RDUTY/conf/instance.conf")"

# Flagless means preserve, never infer from a production-looking hostname.
roster_install --agent claude --role reviewer >/dev/null 2>&1
roster_install >/dev/null 2>&1
t install-flagless-keeps-explicit-role 'BOT_ROLES="reviewer"' \
  "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"

while read -r roster_box roster_agent roster_role _roster_from; do
  roster_install --box "$roster_box" >/dev/null 2>&1
  hire_conf="$(grep -E '^BOT_(AGENT|ROLES)=' "$RDUTY/conf/instance.conf")"
  roster_install --box "$roster_box" >/dev/null 2>&1
  upgrade_conf="$(grep -E '^BOT_(AGENT|ROLES)=' "$RDUTY/conf/instance.conf")"
  t "install-hire-upgrade-stable-$roster_box" "$hire_conf" "$upgrade_conf"
  t "install-roster-declares-$roster_box" \
    "BOT_AGENT=$roster_agent
BOT_ROLES=\"$roster_role\"" "$upgrade_conf"
done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/examples/fleet.roster")

# A roster staged by the host beats the shipped fallback.
printf 'claude-builder claude reviewer\n' >"$RDUTY/fleet.roster"
roster_install --box claude-builder >/dev/null 2>&1
t install-staged-roster-wins 'BOT_ROLES="reviewer"' \
  "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"

# Operator config and untouched registries converge; local divergence vetoes.
printf 'FLEET_HUMAN="fixture-human"\nMARK_PICKUP="not-the-protocol"\n' >"$RDUTY/conf/fleet.conf"
rm -f "$RDUTY/repos.txt" "$RDUTY/notify-repos.txt"
printf 'fixture/first\n' >"$RDUTY/.crew-seed-repos.txt"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-operator-conf-transport 'FLEET_HUMAN="fixture-human"' \
  "$(grep '^FLEET_HUMAN=' "$RDUTY/conf/fleet.conf")"
t install-registry-first-convergence fixture/first "$(cat "$RDUTY/repos.txt")"
t install-builder-notify-triage-only absent \
  "$([ -f "$RDUTY/notify-repos.txt" ] && printf present || printf absent)"
t install-seed-payload-discarded absent \
  "$([ -e "$RDUTY/.crew-seed-repos.txt" ] || [ -e "$RDUTY/.crew-seed-notify-repos.txt" ] && printf present || printf absent)"

printf 'fixture/second\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-converges-untouched fixture/second "$(cat "$RDUTY/repos.txt")"
printf 'fixture/contained\n' >"$RDUTY/repos.txt"
printf 'fixture/third\n' >"$RDUTY/.crew-seed-repos.txt"
veto_out="$(roster_install --box claude-builder --converge-registries 2>&1)"
t install-registry-vetoes-divergence fixture/contained "$(cat "$RDUTY/repos.txt")"
case "$veto_out" in *"claude-builder: repos.txt diverged"*"LEFT UNCHANGED"*) r1=named ;; *) r1=silent ;; esac
t install-registry-veto-is-loud named "$r1"

# The documented adoption path must work even when provenance records the
# older transported value: manually matching the incoming bytes adopts it.
printf 'fixture/third\n' >"$RDUTY/repos.txt"
printf 'fixture/third\n' >"$RDUTY/.crew-seed-repos.txt"
adopt_out="$(roster_install --box claude-builder --converge-registries 2>&1)"
t install-registry-adopts-manual-match fixture/third "$(cat "$RDUTY/repos.txt")"
case "$adopt_out" in *"adopted and converged"*) r1=adopted ;; *) r1=missing ;; esac
t install-registry-adoption-is-visible adopted "$r1"

# A current-fleet copy matching the shipped example can be adopted without
# provenance; an unknown local copy cannot.
rm -f "$RDUTY/.repos.txt.crew-provenance"
cp "$ROOT/examples/repos.txt" "$RDUTY/repos.txt"
printf 'fixture/migrated\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-adopts-example fixture/migrated "$(cat "$RDUTY/repos.txt")"
rm -f "$RDUTY/.repos.txt.crew-provenance"
printf 'fixture/unknown-local\n' >"$RDUTY/repos.txt"
printf 'fixture/incoming\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-vetoes-unknown fixture/unknown-local "$(cat "$RDUTY/repos.txt")"

runtime_fleet="$(DUTY_DIR="$RDUTY" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s|%s" "$FLEET_HUMAN" "$MARK_PICKUP"')"
t install-loads-defaults-then-operator 'fixture-human|📌 picked up' "$runtime_fleet"
printf 'claude-builder claude triage\n' >"$RDUTY/fleet.roster"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-triage-notify-seed fixture/wide "$(cat "$RDUTY/notify-repos.txt")"

if grep -Rsiqw 'manifest' "$SHARED/docs" "$SHARED/README.md" "$SHARED/conf" \
    "$SHARED/lib" "$SHARED/install.sh" "$ROOT/examples/fleet.roster" "$ROOT/cli/crew" \
    "$ROOT/drill"; then
  r1=DUPLICATED
else
  r1=single-source
fi
t install-no-second-role-registry single-source "$r1"
if grep -q -- "--box '\$b'" "$ROOT/cli/crew" || grep -q "install_identity_args.*\\\$b" "$ROOT/cli/crew"; then
  r1=box-keyed
else
  r1=UNKEYED
fi
t upgrade-passes-roster-box-key box-keyed "$r1"

# --- crew upgrade --all is roster-scoped, not host-wide (#37) ------------
# `--all` used to mean box_names(): every box on the host, each installed
# with --arm-cron. That reached off-roster boxes -- a drill box between runs
# carries a real identity and a production registry and is deliberately
# disarmed -- and armed them by routine maintenance.
UROSTER="$TMP/upgrade-roster"
printf '# comment\nclaude-triage    claude  triage\nclaude-builder   claude  builder\n\n' >"$UROSTER"
roster_names_fixture() { grep -vE '^[[:space:]]*(#|$)' "$UROSTER" | awk '{print $1}'; }
host_boxes_fixture() { printf 'claude-triage\ncrew-drill-reviewer\nclaude-builder\nsome-other-box\n'; }
t upgrade-roster-names "claude-triage
claude-builder" "$(roster_names_fixture)"
t upgrade-targets-are-roster-and-host "claude-builder
claude-triage" \
  "$(comm -12 <(roster_names_fixture | sort) <(host_boxes_fixture | sort))"
t upgrade-skips-off-roster "crew-drill-reviewer
some-other-box" \
  "$(comm -23 <(host_boxes_fixture | sort) <(roster_names_fixture | sort))"
# The drill box is the case that matters: present on the host, absent from
# the roster, and therefore never touched by --all.
case "$(comm -12 <(roster_names_fixture | sort) <(host_boxes_fixture | sort))" in
  *crew-drill*) r1=reached ;; *) r1=untouched ;;
esac
t upgrade-never-reaches-drill-box untouched "$r1"

# --- duty.sh lock sentinel: 199 AND the message --------------------------
# A bare non-zero `flock` under `set -euo pipefail` exited duty.sh AT the
# flock line, so the 199 branch never ran and a contended manual invocation
# printed nothing at all. Both halves are asserted: the exit code alone was
# always correct, which is why this survived unnoticed — only the drill's
# "lock contention -> 199 + message" check saw the silence.
LHOME="$TMP/lock-home"
mkdir -p "$LHOME"
env HOME="$LHOME" DUTY_DIR="$LHOME/duty" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
  /bin/bash "$SHARED/install.sh" --agent claude --role reviewer >/dev/null 2>&1
flock -n "$LHOME/duty/.duty.lock" -c 'sleep 3' >/dev/null 2>&1 &
lock_bg=$!
sleep 1
if lock_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" /bin/bash "$LHOME/duty/bin/duty.sh" 2>&1)"; then
  lock_rc=0
else
  lock_rc=$?
fi
wait "$lock_bg" 2>/dev/null || true
t duty-lock-sentinel-rc 199 "$lock_rc"
case "$lock_out" in *"already holds"*) r1=message ;; *) r1=silent ;; esac
t duty-lock-sentinel-message message "$r1"

# --- count predicates must fail CLOSED on empty and on error output ------
# `grep -qv '^0$'` reads as "the count is not zero", but -v selects lines
# that do NOT match, so it returns 0 for EMPTY input and for gh's error JSON
# — the check went green when the API call failed. Same defect class as the
# null check in #29: a predicate whose failure mode looks like success.
for _in in '' '0' '{"message":"Not Found","status":"404"}'; do
  if printf '%s' "$_in" | grep -qE '^[1-9][0-9]*$'; then r1=passed; else r1=refused; fi
  t "count-predicate-refuses-${_in:-empty}" refused "$r1"
done
if printf '3' | grep -qE '^[1-9][0-9]*$'; then r1=passed; else r1=refused; fi
t count-predicate-accepts-real-count passed "$r1"
# The shape it replaced, pinned so nobody reintroduces it. Uses gh's error
# JSON, not empty input: -v on an empty stream is shell/grep dependent, but
# ANY non-"0" line — which is what a failed gh call prints to stdout — makes
# the old predicate return 0. That is the realistic failure and it is
# deterministic everywhere.
if printf '%s' '{"message":"Not Found","status":"404"}' | grep -qv '^0$'; then r1=fail-open; else r1=fail-closed; fi
t count-predicate-old-shape-was-fail-open fail-open "$r1"

# --- notify.sh lock sentinel: same set -e trap as duty.sh (#30) ----------
# duty.sh was fixed for this; notify.sh has the identical preamble and was
# missed. Asserted the same way: the exit code alone was always right, so
# only the message distinguishes fixed from broken.
flock -n "$LHOME/duty/.notify.lock" -c 'sleep 3' >/dev/null 2>&1 &
nlock_bg=$!
sleep 1
if nlock_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" /bin/bash "$LHOME/duty/bin/notify.sh" 2>&1)"; then
  nlock_rc=0
else
  nlock_rc=$?
fi
wait "$nlock_bg" 2>/dev/null || true
t notify-lock-sentinel-rc 199 "$nlock_rc"
case "$nlock_out" in *"already holds"*) r1=message ;; *) r1=silent ;; esac
t notify-lock-sentinel-message message "$r1"

# --- attention label predicate: never let a null reach the shell ---------
# `gh api --jq` prints NOTHING for a null result (real jq prints "null"), so
# `index("attention") | grep -q null` matched in NEITHER state: present
# emitted "0", absent emitted "". The predicate must emit a token both ways.
t label-predicate-gone    true  "$(printf '{"labels":[]}\n' | jq -r '[.labels[].name] | index("attention") == null')"
t label-predicate-present false "$(printf '{"labels":[{"name":"attention"}]}\n' | jq -r '[.labels[].name] | index("attention") == null')"

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

# --- ledger_suppressed: the exact inverse of ledger_filter (#59) ------------
# The two must partition the input between them. If they can ever disagree, the
# engine either pays for work it meant to suppress or goes quiet about work it
# meant to report — and the second is the dangerous one.
LG3="$TMP/ledger-inv"
printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | ledger_commit "$LG3"
IN3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T11:00:00Z\no/r#3 2026-07-27T09:00:00Z\n')"
# #1 unchanged -> suppressed; #2 advanced -> fresh; #3 unseen -> fresh
t suppressed-unchanged "o/r#1 2026-07-27T10:00:00Z" "$(printf '%s\n' "$IN3" | ledger_suppressed "$LG3")"
t suppressed-fresh-count 2 "$(printf '%s\n' "$IN3" | ledger_filter "$LG3" | n)"
# Partition: filter + suppressed together account for every input line, exactly
# once. Asserted rather than assumed — the set-arithmetic version of this that
# I wrote first reported NOTHING suppressed whenever the fresh list was empty.
t suppressed-partitions 3 "$(printf '%s\n' "$IN3" | { ledger_filter "$LG3"; printf '%s\n' "$IN3" | ledger_suppressed "$LG3"; } | n)"
t suppressed-disjoint 0 "$(comm -12 \
  <(printf '%s\n' "$IN3" | ledger_filter "$LG3" | sort) \
  <(printf '%s\n' "$IN3" | ledger_suppressed "$LG3" | sort) | n)"
# A cold ledger hides nothing.
t suppressed-cold 0 "$(printf 'o/r#9 2026-07-27T10:00:00Z\n' | ledger_suppressed "$TMP/nope" | n)"

# --- report_suppressed: stop paying, do NOT stop saying (#59) ---------------
# A ledger converts a burn into silence. An unactioned item is still a live
# board-invariant violation, so the suppressed set has to surface — but at one
# tick per five minutes, a line every tick would bury the log it informs. So:
# warn when the SET CHANGES, and again from scratch after it clears.
ST="$TMP/suppressed-state"
r1="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r1" in *"1 item(s)"*"o/r#1"*) r2=warned ;; *) r2="$r1" ;; esac
t report-first warned "$r2"
# Same set again: silent.
t report-repeat "" "$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
# Set grows: speaks again.
r3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r3" in *"2 item(s)"*) r4=warned ;; *) r4="$r3" ;; esac
t report-grew warned "$r4"
# Emptied: silent, and the state file goes, so a recurrence is reported afresh
# rather than being swallowed as "same as last time".
t report-cleared "" "$(printf '' | report_suppressed "$ST" "o/r: board")"
if [ -f "$ST" ]; then r5=kept; else r5=removed; fi
t report-state-removed removed "$r5"
r6="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r6" in *"1 item(s)"*) r7=warned ;; *) r7="$r6" ;; esac
t report-recurrence-speaks warned "$r7"
# Blank lines are not items and must not render as the malformed `()`.
r8="$(printf '\no/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$TMP/sup-blank" "review")"
case "$r8" in *'()'*) r9=MALFORMED ;; *) r9=clean ;; esac
t report-blank-line-format clean "$r9"

# An incomplete sweep cannot compare its partial set with the previous complete
# set. Preserve the state byte-for-byte; otherwise one flaky repo makes every
# healthy repo's standing suppression look changed twice (drop + return).
ST_PART="$TMP/sup-partial"
printf 'o/a#1 T1\no/b#1 T1\n' | report_suppressed "$ST_PART" "review" >/dev/null
before_part="$(cat "$ST_PART")"
printf 'o/a#1 T1\n' \
  | report_suppressed_if_complete 0 "$ST_PART" "review" >/dev/null
t report-partial-preserves-state "$before_part" "$(cat "$ST_PART")"
# The next complete steady set remains silent, proving the partial tick did not
# replace the state and manufacture a second warning when repo B returns.
t report-after-partial-still-settled "" \
  "$(printf 'o/a#1 T1\no/b#1 T1\n' \
      | report_suppressed_if_complete 1 "$ST_PART" "review")"

# --- suppression state must be PER REPO (#60 review) ------------------------
# Both duty modules call report_suppressed inside a per-repo loop. With ONE
# shared state file, repo B's set replaces repo A's, and a repo with nothing
# suppressed rm -f's the file outright — so A's unchanged set looks new on the
# next tick and warns again, every tick, on exactly the 3-repo production box
# this was written to protect. codex-bot and grok-bot both caught it; grok-bot
# reproduced the flip-flop with these helpers.
sup_says() { if grep -q 'item(s)'; then echo warned; else echo silent; fi; }
SUP_A='o/a#1 2026-07-27T10:00:00Z'
SUP_B='o/b#1 2026-07-27T10:00:00Z'

# Per-repo files: each repo settles independently and stays quiet.
STA="$TMP/sup.o_a"; STB="$TMP/sup.o_b"
printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" >/dev/null
t report-perrepo-a-settles silent "$(printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" | sup_says)"
t report-perrepo-b-settles silent "$(printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" | sup_says)"

# The shape that was wrong, kept as a negative control: sharing one file makes
# A speak again after B has been through it. If this ever reads `silent` the
# helper has changed and the per-repo keying above may no longer be load-bearing.
SUP_SHARED="$TMP/sup.shared"
printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$SUP_SHARED" "o/b: board" >/dev/null
t report-shared-state-refires warned "$(printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" | sup_says)"

# ...and the modules must actually key by repo, not just be capable of it.
for pair in "duty-triage.sh:suppressed-triage-board" "duty-builder.sh:suppressed-build"; do
  mod="${pair%%:*}"; sfile="${pair##*:}"
  if grep -qE "$sfile\.\\\$\{?(R|slug)" "$SHARED/lib/$mod"; then r1=perrepo; else r1=SHARED; fi
  t "suppression-state-perrepo-$mod" perrepo "$r1"
done

# --- every state signal is ledgered (#59) -----------------------------------
# The engine had TWO ledgers, both in triage, while builder and reviewer had
# none — so any signal cleared by an in-session action the agent may DECLINE
# re-fired a model session every tick forever. These pin the wiring: a new
# signal site added without a ledger is the regression.
for pair in "duty-triage.sh:.seen-triage-board" "duty-builder.sh:.seen-build" \
            "duty-review.sh:.seen-review" "duty-attention.sh:.seen-attention"; do
  mod="${pair%%:*}"; led="${pair##*:}"
  if grep -q "$led" "$SHARED/lib/$mod"; then r1=ledgered; else r1=UNGUARDED; fi
  t "signal-ledgered-$mod" ledgered "$r1"
  # ...and committed only after a session that actually completed.
  if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/$mod"; then r1=gated; else r1=UNGATED; fi
  t "ledger-commit-gated-$mod" gated "$r1"
  # ...and what it hides must be reported.
  if grep -q 'report_suppressed' "$SHARED/lib/$mod"; then r1=reported; else r1=SILENT; fi
  t "suppression-reported-$mod" reported "$r1"
done

# The reviewer must carry updated_at from the existing pulls page, partition
# before assembling per-repo prompts, and commit that repo's exact fresh set.
REVIEW_MOD="$SHARED/lib/duty-review.sh"
if grep -Fq "\\(.updated_at) \\(\$sr) \\(.number)" "$REVIEW_MOD"; then r1=carried; else r1=MISSING; fi
t review-carries-updated-at carried "$r1"
if grep -q 'fresh_items=.*ledger_filter.*seen-review' "$REVIEW_MOD" &&
   grep -q 'suppressed=.*ledger_suppressed.*seen-review' "$REVIEW_MOD"; then
  r1=partitioned
else
  r1=UNPARTITIONED
fi
t review-partitions-before-prompt partitioned "$r1"
commit_block="$(awk '
  /if \[ "\$\{RUN_SESSION_RC:-1\}" -eq 0 \]; then/ { inside=1 }
  inside { print }
  inside && /^[[:space:]]*fi$/ { exit }
' "$REVIEW_MOD")"
if grep -Fq "\${repo_items[\$SR]}" <<<"$commit_block" &&
   grep -Fq "ledger_commit \"\$DUTY_DIR/.seen-review\"" <<<"$commit_block"; then
  r1=exact
else
  r1=MISMATCH
fi
t review-commits-prompted-set exact "$r1"
if grep -q 'report_suppressed_if_complete.*sweep_complete' "$REVIEW_MOD"; then
  r1=guarded
else
  r1=UNGUARDED
fi
t review-partial-sweep-preserves-report-state guarded "$r1"

# Behavioral mixed case: #5 is unchanged and suppressed; #6 in the same repo
# is fresh. Only #6 enters the prompted/committed set. After that successful
# commit both are settled; advancing #5's updated_at wakes it again.
RLG="$TMP/review-ledger"
printf 'o/r#5 T1\n' | ledger_commit "$RLG"
RQ="$(printf 'o/r#5 T1\no/r#6 T1\n')"
RP="$(printf '%s\n' "$RQ" | ledger_filter "$RLG")"
RS="$(printf '%s\n' "$RQ" | ledger_suppressed "$RLG")"
t review-mixed-prompt-only-fresh "o/r#6 T1" "$RP"
t review-mixed-report-only-suppressed "o/r#5 T1" "$RS"
printf '%s\n' "$RP" | ledger_commit "$RLG"
t review-mixed-commit-settles-both 0 "$(printf '%s\n' "$RQ" | ledger_filter "$RLG" | n)"
t review-advanced-suppressed-rewakes "o/r#5 T2" \
  "$(printf 'o/r#5 T2\n' | ledger_filter "$RLG")"

# --- the registry bounds EVERY module, attention included (#52, #66) ------
# drill/rehearsal.sh narrows repos.txt to a single sandbox repo and REFUSES to
# tick if it cannot. That is containment only for modules which actually
# consult the file, so it is asserted rather than believed.
#
# The list was review, builder, triage, hygiene. The reviewer was the exception
# until 2026-07-25 (an org-wide requested_reviewers sweep no registry could
# bound) — which is what #52 was filed doubting — and the attention wake was
# the exception until 2026-07-27, when danmt ruled on #66 that the registry
# bounds it too. `examples/repos.txt` asserted the universal for two days longer
# than the engine honoured it, and that header is what an operator reads when
# deciding whether narrowing the file contains a box.
for mod in review builder triage hygiene attention; do
  if grep -q 'REPOS_FILE' "$SHARED/lib/duty-$mod.sh"; then r1=scoped; else r1=UNSCOPED; fi
  t "registry-scoped-$mod" scoped "$r1"
done

# ...and scoped BEHAVIOURALLY, not just by mentioning the file. The partition
# is the ruling, so it is exercised directly: a grep for REPOS_FILE would pass
# against a module that read the registry and then ignored it.
# Definition-only at the top level, so sourcing costs nothing and runs nothing.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-attention.sh"
ATT_REG="$(printf 'heavy-duty/ceremony\nheavy-duty/rig\n')"
ATT_ROWS="$(printf 'heavy-duty/ceremony 12 T1\nouter/thing 7 T2\nheavy-duty/rig 3 T3\n')"
ATT_OUT="$(printf '%s\n' "$ATT_ROWS" | _attention_partition "$ATT_REG")"
t attention-in-registry-acted "IN heavy-duty/ceremony 12 T1
IN heavy-duty/rig 3 T3" "$(printf '%s\n' "$ATT_OUT" | grep '^IN ')"
t attention-outside-registry-not-acted "OUT outer/thing 7 T2" \
  "$(printf '%s\n' "$ATT_OUT" | grep '^OUT ')"
# A prefix must not count as membership: `heavy-duty/rig` in the registry must
# not authorize `heavy-duty/rig-fork`. grep -qxF, never a substring match.
t attention-prefix-is-not-membership "OUT heavy-duty/rig-fork 9 T4" \
  "$(printf 'heavy-duty/rig-fork 9 T4\n' | _attention_partition "$ATT_REG" | grep '^OUT ')"
# An empty registry authorizes nothing — it must not read as "no filter".
t attention-empty-registry-acts-on-nothing "" \
  "$(printf '%s\n' "$ATT_ROWS" | _attention_partition "" | grep '^IN ' || true)"

# --- the attention wake is ledgered too (#59's last site) --------------------
# It looked exempt: the pickup session acks by REMOVING the label, so the
# signal self-clears, and the module documents a deliberate crash-only retry.
# Both true, and neither covers a session that COMPLETES and correctly declines
# to ack — needs a ruling, not this box's to answer, already handled. Nothing
# removes the label and the wake re-fires every tick.
#
# It is the worst place in the engine for that: TIMEOUT_ATTENTION is 1800s,
# duty_attention runs FIRST, and it runs for EVERY role on EVERY box, where
# every other signal site is confined to one role.
ALG="$TMP/attention-ledger"
ATT_IN="$(printf 'o/r#4 T1\no/r#9 T1\n')"
t attention-first-tick-both-fire 2 "$(printf '%s\n' "$ATT_IN" | ledger_filter "$ALG" | n)"
# #4's session completed and acked (the row is gone from the query next tick);
# #9's completed and declined, so only #9's id was committed.
printf 'o/r#9 T1\n' | ledger_commit "$ALG"
t attention-declined-does-not-refire 0 "$(printf 'o/r#9 T1\n' | ledger_filter "$ALG" | n)"
# ...but it is still SAID, once per change to the set.
t attention-declined-is-reported "o/r#9" \
  "$(printf 'o/r#9 T1\n' | ledger_suppressed "$ALG" | cut -d' ' -f1)"
# A comment, an edit or a re-label advances updated_at — look again, which is
# exactly when the box should.
t attention-touched-demand-rewakes 1 "$(printf 'o/r#9 T2\n' | ledger_filter "$ALG" | n)"
# A CRASHED session commits nothing, so the same id is still fresh next tick:
# the module's documented crash-only retry has to survive the ledger.
t attention-crashed-session-retries 1 "$(printf 'o/r#4 T1\n' | ledger_filter "$ALG" | n)"
# The commit is gated on the session's own rc, per demand — a sibling that
# succeeded must not settle one that died.
if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/duty-attention.sh"; then r1=gated; else r1=UNGATED; fi
t attention-ledger-commit-gated gated "$r1"
# ...and the WAKE PATH must be the filtered set, which everything above this
# line fails to prove: the assertions exercise ledger_filter, and the module
# would still mention .seen-attention (in the suppression report) with the
# filter deleted from the wake. Ripping `ledger_filter` out of the assignment
# left all of them green. So the structure is pinned too — the same shape
# duty-review.sh's `review-partitions-before-prompt` pins, and for the same
# reason.
ATT_MOD="$SHARED/lib/duty-attention.sh"
# The SAME hole, one level up, and this one shipped to review: the behavioural
# assertions call _attention_partition directly, so they cannot see a wake path
# that computes the partition and then ignores it. kimi ran exactly that
# mutation against d849f16 —
#
#   inside="$(printf '%s\n' "$rows" | awk '{ print $1 "#" $2, $3 }')"
#
# keeping the registry read and the partition function intact, and the suite
# stayed 185 ok / 0 failed. So the wiring is pinned too: the acted set and the
# reported set must both come from $partitioned, and $outside must be what
# feeds the suppression report the operator alert keys on.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
if grep -q 'inside=.*\$partitioned' "$ATT_MOD" &&
   grep -q 'outside=.*\$partitioned' "$ATT_MOD" &&
   grep -q 'printf .* "\$outside" *\\*$' "$ATT_MOD"; then
  r1=wired
else
  r1=UNWIRED
fi
t attention-acted-set-comes-from-the-partition wired "$r1"

# The two withheld sets are different events and must not read alike in
# duty.log: a ledger suppression is an item a session SAW and declined; an
# out-of-scope demand was never actionable by this box and no session ever saw
# it. The default phrase stays for the three ledger callers.
RSW="$TMP/rsw-state"
t report-suppressed-default-phrase reported \
  "$(printf 'x#1 T1\n' | report_suppressed "$RSW" "lbl" 2>&1 \
     | grep -q 'unactioned since a previous session' && echo reported || echo MISSING)"
rm -f "$RSW"
t report-suppressed-custom-phrase reported \
  "$(printf 'x#1 T1\n' | report_suppressed "$RSW" "lbl" "never actionable here" 2>&1 \
     | grep -q 'never actionable here' && echo reported || echo MISSING)"
rm -f "$RSW"
if grep -q 'report_suppressed .*sc_state.*\\$' "$ATT_MOD" &&
   grep -q 'this box does not carry' "$ATT_MOD"; then r1=distinct; else r1=BORROWED; fi
t attention-scope-report-has-its-own-phrase distinct "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -q 'fresh=.*ledger_filter.*\.seen-attention' "$ATT_MOD" &&
   grep -q 'rows="\$fresh"' "$ATT_MOD"; then
  r1=filtered
else
  r1=UNFILTERED
fi
t attention-wake-set-is-the-filtered-set filtered "$r1"

# The bound must not be silent, and for THIS module not only in duty.log: an
# attention demand is somebody deliberately handing this box work, so a bound
# that only logged would read to them as the box ignoring them.
if grep -q 'report_suppressed' "$SHARED/lib/duty-attention.sh"; then r1=reported; else r1=SILENT; fi
t attention-out-of-scope-reported reported "$r1"
if grep -q 'alert ' "$SHARED/lib/duty-attention.sh"; then r1=pinged; else r1=LOG-ONLY; fi
t attention-out-of-scope-pings-operator pinged "$r1"

# The drill's separate check survives the ruling, with a changed job: it used
# to be the ONLY containment for this module, and is now an independent
# verification that the filter above actually holds. Keeping it is the
# difference between testing the invariant and trusting it.
if grep -q 'rehearsal_attention_is_clear' "$ROOT/drill/rehearsal-safety.sh" &&
   grep -q 'rehearsal_attention_is_clear' "$ROOT/drill/rehearsal.sh"; then r1=checked; else r1=ASSUMED; fi
t "drill-checks-attention-outside-sandbox" checked "$r1"

# --- an idle tick is not a silent one (#53) -------------------------------
# The floor's SILENT rule is "no duty.log line for two tick boundaries", which
# is sound only if a tick that finds no work still writes. duty.sh logs
# `duty run start` before any role dispatch and `duty run end` on every exit
# path, and tick.sh covers the rest (skipped, FAILED) — so a duty.log with
# nothing new means no tick RAN, which is a cron problem, never a healthy idle
# box. That is the diagnosis #53 needed, and this keeps it true: an early
# `exit` added between the two lines would turn an idle box into an offline one
# on the console, and a silent box into an ambiguous one.
t duty-start-unconditional 1 "$(grep -c '^log "duty run start"' "$SHARED/bin/duty.sh")"
# Every exit path after the start line must have logged the end line first.
# A linear scan, deliberately: it is an approximation of control flow, but it
# catches the shape that actually regresses — a new early `exit` on a branch
# that forgot the evidence line.
t duty-end-on-every-exit "" "$(awk '
  /^log "duty run start"/ { started = 1; next }
  !started { next }
  /log "duty run end"/    { ended = 1 }
  /^[[:space:]]*exit / && !ended { print "line " NR; exit }
' "$SHARED/bin/duty.sh")"
# `crontab armed` must not be the last word: the crontab holding a line says
# nothing about a cron daemon existing to run it, and that gap is why three
# boxes reported armed and one ticked.
if grep -q 'cron_daemon_running' "$SHARED/install.sh"; then r1=checked; else r1=ASSUMED; fi
t install-verifies-cron-daemon checked "$r1"

# --- credential state reported by the flow (replaces the polled probes) ----
# These run against the REAL common.sh sourced above, with DUTY_DIR pointed at
# a scratch dir, so the marker contract the floor reads is asserted here and
# not merely described in a comment.

# alert() would try to curl Telegram from a unit test; the token files do not
# exist so it returns early, but stub it anyway — a test that depends on the
# absence of a file in $HOME is a test that fails on somebody's laptop.
alert() { :; }

AUTHDIR="$TMP/authstate"; mkdir -p "$AUTHDIR"
DUTY_DIR="$AUTHDIR"

note_auth_failure gh "401 Bad credentials"
t authfail-file-per-service present "$([ -f "$AUTHDIR/.auth-fail.gh" ] && echo present || echo MISSING)"
t authfail-does-not-touch-other-service absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo LEAKED || echo absent)"
t authfail-records-reason found \
  "$(grep -q '401 Bad credentials' "$AUTHDIR/.auth-fail.gh" && echo found || echo MISSING)"

# The first failure must win. Rewriting every tick resets mtime, so a
# credential that died on Monday reads as having died just now — and "when did
# this break" is the only question the file exists to answer.
FIRST="$(cat "$AUTHDIR/.auth-fail.gh")"
sleep 1
note_auth_failure gh "403 something else entirely"
t authfail-first-failure-wins "$FIRST" "$(cat "$AUTHDIR/.auth-fail.gh")"

clear_auth_failure gh
t authfail-cleared absent "$([ -f "$AUTHDIR/.auth-fail.gh" ] && echo PRESENT || echo absent)"
clear_auth_failure gh   # must be idempotent, not an error under set -e
t authfail-clear-idempotent 0 "$?"

# Multi-line reasons: gh's errors routinely are, and one record must stay one
# line or probe.sh's ::key contract silently gains phantom keys.
note_auth_failure vendor "$(printf 'line one\nline two\nline three')"
t authfail-single-line 1 "$(wc -l < "$AUTHDIR/.auth-fail.vendor")"
clear_auth_failure vendor

# check_vendor_credential's tri-state. 2 means "this profile cannot tell from
# local state" and MUST change nothing: neither raise an alarm nor clear a
# real failure someone still has to fix.
# shellcheck disable=SC2034  # read by check_vendor_credential in common.sh
AGENT_LOGIN_HINT="run the thing"
# shellcheck disable=SC2317  # invoked indirectly, by check_vendor_credential
bot_cli_present() { return 0; }
check_vendor_credential
t vendor-present-no-failure absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo PRESENT || echo absent)"

# shellcheck disable=SC2317
bot_cli_present() { return 1; }
check_vendor_credential
t vendor-absent-raises present \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo present || echo MISSING)"

# shellcheck disable=SC2317
bot_cli_present() { return 2; }
check_vendor_credential
t vendor-unknown-does-not-clear present \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo present || echo CLEARED)"
rm -f "$AUTHDIR/.auth-fail.vendor"
check_vendor_credential
t vendor-unknown-does-not-raise absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo RAISED || echo absent)"
unset -f bot_cli_present

# An older agent profile with neither function must be a no-op, not a failure:
# install.sh does not upgrade confs in place, so mid-rollout boxes will have
# exactly this shape.
check_vendor_credential
t vendor-legacy-profile-silent absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo RAISED || echo absent)"

# --- each agent profile reads its OWN credential store, locally -------------
# Driven against the real conf files with a fabricated HOME, because the whole
# claim of bot_cli_present is that it needs nothing but local disk.

CREDH="$TMP/credhome"; mkdir -p "$CREDH"
cred_rc() {  # cred_rc <agent> <home> -> rc of bot_cli_present
  local rc=0
  # Every vendor env override is cleared, not just the one under test: these
  # are read by the sourced profile, and inheriting the RUNNER's credentials
  # would make the result depend on whose machine ran the suite.
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$2" KIMI_CODE_HOME="" CODEX_HOME="" GROK_HOME="" \
    ANTHROPIC_API_KEY="" XAI_API_KEY=""
    # shellcheck disable=SC1090
    source "$SHARED/conf/agents/$1.conf"; bot_cli_present ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
# base64url with the padding stripped, the way a JWT actually arrives.
b64url() { base64 -w0 | tr '/+' '_-' | tr -d '='; }

# -- claude: refreshTokenExpiresAt, in MILLISECONDS
CH="$CREDH/claude"; mkdir -p "$CH/.claude"
CLAUDE_EXP_MS=$(( ($(date +%s) + 20 * 86400) * 1000 ))
jq -n --argjson r "$CLAUDE_EXP_MS" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-present 0 "$(cred_rc claude "$CH")"

# THE trap, and the reason this profile reads refreshTokenExpiresAt: an access
# token that lapsed hours ago while the refresh token is still good is the
# ordinary steady state, refreshed silently on next use. A profile testing
# `expiresAt` would call a perfectly healthy box logged out three times a day.
jq -n --argjson r "$CLAUDE_EXP_MS" --argjson a "$(( ($(date +%s) - 3600) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:$a,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-stale-access-token-is-fine 0 "$(cred_rc claude "$CH")"

# An expired REFRESH token is the real logout: nothing can renew it but a human.
jq -n --argjson r "$(( ($(date +%s) - 86400) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-expired-refresh 1 "$(cred_rc claude "$CH")"
t cred-claude-no-file 1 "$(cred_rc claude "$CREDH/nothing")"

# -- kimi: the refresh token is a JWT; its exp claim is the relogin deadline
KH="$CREDH/kimi"; mkdir -p "$KH/.kimi-code/credentials"
KIMI_EXP=$(( $(date +%s) + 30 * 86400 ))
# A payload sized so base64url PADDING is required — the case a naive decoder
# silently fails on.
KJWT="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code","sub":"u"}' "$KIMI_EXP" | b64url).sig"
jq -n --arg rt "$KJWT" \
  '{access_token:"a",refresh_token:$rt,expires_at:1,token_type:"Bearer"}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-present 0 "$(cred_rc kimi "$KH")"
t cred-kimi-no-file 1 "$(cred_rc kimi "$CREDH/nothing")"
# An expired refresh JWT is a logout, not merely "cannot tell".
KJWT_OLD="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code"}' "$(( $(date +%s) - 86400 ))" | b64url).sig"
jq -n --arg rt "$KJWT_OLD" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-expired-refresh 1 "$(cred_rc kimi "$KH")"
# Garbage in the JWT slot must be "cannot tell" (2), never a confident logout.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-unparseable-is-unknown 2 "$(cred_rc kimi "$KH")"

# -- codex: file-backed vs keyring-backed, and NO expiry at all
DH="$CREDH/codex"; mkdir -p "$DH/.codex"
jq -n '{auth_mode:"chatgpt",tokens:{access_token:"a.b.c",refresh_token:"opaque"}}' > "$DH/.codex/auth.json"
t cred-codex-present 0 "$(cred_rc codex "$DH")"
t cred-codex-no-file-is-logout 1 "$(cred_rc codex "$CREDH/nothing")"
# ...unless the box keeps its credential in the desktop keyring, where a
# missing auth.json is normal and must not be reported as a logout.
KB="$CREDH/codexkeyring"; mkdir -p "$KB/.codex"
echo 'cli_auth_credentials_store = "keyring"' > "$KB/.codex/config.toml"
t cred-codex-keyring-is-unknown 2 "$(cred_rc codex "$KB")"

# -- grok: its probe was already a local file test, so it is authoritative
# -- grok: a MAP of "<issuer>::<client_id>" slots, refresh token opaque
GH_="$CREDH/grok"; mkdir -p "$GH_/.grok"
jq -n '{"https://auth.x.ai::abc":{key:"j.w.t",refresh_token:"opaque",expires_at:"2026-07-27T19:54:18Z"}}' \
  > "$GH_/.grok/auth.json"
t cred-grok-present 0 "$(cred_rc grok "$GH_")"
t cred-grok-no-file 1 "$(cred_rc grok "$CREDH/nothing")"
# An empty map is a non-empty FILE. The old `[ -s ]` test called this logged
# in; it is a failed login, and the honest answer is "cannot tell".
echo '{}' > "$GH_/.grok/auth.json"
t cred-grok-empty-map-is-unknown 2 "$(cred_rc grok "$GH_")"

# No profile may define bot_cli_expiry: the floor tracks no expiry dates, and
# a profile still exporting one would be dead code drifting out of sync.
for agent in claude codex grok kimi; do
  r1=absent
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$agent.conf"; command -v bot_cli_expiry >/dev/null ) 2>/dev/null && r1=DEFINED
  t "cred-$agent-defines-no-expiry" absent "$r1"
done

# --- the per-tick path must not have reacquired a network auth probe -------
# `gh auth status` in the tick is the exact cost this change removed; it would
# pass every assertion above while restoring 7k requests/day.
# The boot gate ABOVE the identity call may still pay for a real probe once
# per boot — certainty is worth one round-trip there. What must never come
# back is a probe in the per-tick path, so the assertion is positional:
# nothing after `ME="$(gh_identity)"` may call it.
r1="$(awk '
  /ME="\$\(gh_identity\)"/ { after = 1 }
  after && /^[^#]*gh auth status/ { print "POLLED"; exit }
' "$SHARED/bin/duty.sh")"
r1="${r1:-clean}"
t tick-does-not-poll-gh-auth clean "$r1"
# ...and the identity call must be the one that harvests the expiry header.
if grep -q 'gh_identity' "$SHARED/bin/duty.sh"; then r1=wired; else r1=MISSING; fi
t tick-uses-gh-identity wired "$r1"
# No expiry date is tracked anywhere any more: four providers express it four
# ways and two cannot answer locally at all, so the countdown was the flaky
# half of the idea. A reintroduced record_token_expiry would put it back.
if grep -q 'record_token_expiry\|token-expiry' "$SHARED/lib/common.sh"; then r1=TRACKED; else r1=clean; fi
t no-expiry-date-tracked clean "$r1"

# Every agent profile must define bot_cli_present, or its box silently never
# reports vendor credential state at all.
missing=""
for agent in claude codex grok kimi; do
  grep -q 'bot_cli_present()' "$SHARED/conf/agents/$agent.conf" || missing="$missing $agent"
done
t agent-profiles-define-present "" "$missing"

# --- the two-boundary rule must exist once, not once per reader -----------
# floor.py derives it (2 * TICK_S), cli/crew names it, and probe.sh must not
# hold it at all: the box ships ::tickage and the HOST decides. A third copy
# inside the box, in a second language, meant changing TICK_S would leave the
# floor calling a box SILENT while both credential readers still said flowing
# — and rehearsal-app.sh asserts those two readers agree, so the drill would
# fail for a reason nobody would trace to a constant.
CREW_CLI="$(cd "$(dirname "$SHARED")" && pwd)/cli/crew"
FLOOR_PY="$(cd "$(dirname "$SHARED")" && pwd)/fleet-floor/server/floor.py"

FL_TICK="$(sed -n 's/^TICK_S = \([0-9]*\).*/\1/p' "$FLOOR_PY" | head -1)"
FL_SILENT=$(( ${FL_TICK:-0} * 2 ))
# shellcheck disable=SC2016  # matching crew's literal ${CREW_SILENT_AFTER:-600}
CL_SILENT="$(sed -n 's/^SILENT_AFTER_S="${CREW_SILENT_AFTER:-\([0-9]*\)}".*/\1/p' "$CREW_CLI" | head -1)"
t silent-rule-floor-derived 600 "$FL_SILENT"
t silent-rule-cli-matches-floor "$FL_SILENT" "$CL_SILENT"

# ...and the box must hold no threshold of its own. Comments and the log-tail
# line count are stripped before looking, so only real code counts.
PROBE_SH="$(cd "$(dirname "$SHARED")" && pwd)/fleet-floor/server/probe.sh"
if sed -e 's/#.*//' -e '/tail -n/d' "$PROBE_SH" | grep -qE '\b(600|SILENT_AFTER)\b'; then
  r1=BAKED
else
  r1=clean
fi
t probe-holds-no-threshold clean "$r1"
# The datum it ships instead:
if grep -q 'emit tickage' "$PROBE_SH"; then r1=emitted; else r1=MISSING; fi
t probe-emits-tickage emitted "$r1"
# --- head-checks.jq: the check at the head, and the round it gates (#45/#17) --
# The engine never read statusCheckRollup at all, which is both bugs at once: a
# fix round opened on a red head (#45) and a red head that woke nothing (#17).
HC="$SHARED/lib/jq/head-checks.jq"
hc() {  # hc <panel-json> <pr-array-json> -> rows
  printf '%s' "$2" | jq -r --argjson panel "$1" --arg repo "o/r" -f "$HC"
}
mk_prc() {  # mk_prc <rollup> [reviews] [requests] [isDraft]
  jq -cn --argjson c "$1" --argjson lr "${2:-[]}" --argjson rr "${3:-[]}" \
     --argjson d "${4:-false}" \
     '[{number:1, isDraft:$d, updatedAt:"T1", headRefOid:"abc1234",
        statusCheckRollup:$c, latestReviews:$lr, reviewRequests:$rr}]'
}
CHK_OK='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"}]'
CHK_BAD='[{"__typename":"CheckRun","name":"release-exercise / fixture-chain","status":"COMPLETED","conclusion":"FAILURE"}]'
CHK_RUNNING='[{"__typename":"CheckRun","name":"check","status":"IN_PROGRESS","conclusion":null}]'
CHK_CANCEL='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"CANCELLED"}]'
CHK_STALE='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"STALE"}]'
CHK_NEUTRAL='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"NEUTRAL"}]'
CHK_SKIPPED='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SKIPPED"}]'
# A conclusion this engine has never heard of. GitHub adds these.
CHK_UNKNOWN='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"QUANTUM_FAILURE"}]'
# The StatusContext shape. THIS is the fixture that matters: crew's own CI is a
# single CheckRun, so an implementation that discriminates on __typename and
# reads only .conclusion passes every other test in this file and reports a
# FAILING status context as green — a pass for a reason unrelated to the claim,
# which is #50's shape. Reintroduce that discrimination and these two go red.
SC_BAD='[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
SC_ERR='[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}]'
SC_MIX='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'

state_of() { hc '[]' "$(mk_prc "$1")" | cut -f4; }
t head-check-run-success      green   "$(state_of "$CHK_OK")"
t head-check-run-failure      red     "$(state_of "$CHK_BAD")"
t head-status-context-failure red     "$(state_of "$SC_BAD")"
t head-status-context-error   red     "$(state_of "$SC_ERR")"
t head-mixed-shapes-one-red   red     "$(state_of "$SC_MIX")"
t head-check-still-running    pending "$(state_of "$CHK_RUNNING")"
t head-no-checks-is-not-green none    "$(state_of '[]')"
# GREEN IS A WHITELIST; ANYTHING ELSE IS RED (codex, #64). The first version
# enumerated the failing conclusions and let the rest fall through to green,
# arguing a CANCELLED run is one superseded by a newer push. Wrong: the rollup
# is already scoped to the CURRENT head, so a superseded run is not in it — a
# cancelled one there is a manual or same-head-concurrency cancel, i.e. a head
# that is not passing. Reading it green defeated #45's gate and blinded #17's
# wake at the same time. This test previously asserted `green` and locked that
# in, which is why it is called out here rather than quietly flipped.
t head-cancelled-is-red       red     "$(state_of "$CHK_CANCEL")"
t head-stale-is-red           red     "$(state_of "$CHK_STALE")"
# ...and the point of a whitelist: a conclusion nobody has written a branch for
# fails CLOSED. Enumerating the bad ones would have gotten this wrong the same
# way, silently, the next time GitHub adds one.
t head-unknown-conclusion-is-red red  "$(state_of "$CHK_UNKNOWN")"
# The genuinely-not-a-failure conclusions stay green, or every skipped matrix
# leg would wake a builder.
t head-neutral-is-green       green   "$(state_of "$CHK_NEUTRAL")"
t head-skipped-is-green       green   "$(state_of "$CHK_SKIPPED")"
# Drafts are never rows: a panel is never requested on a draft, and a draft's
# red CI is the author's in-flight business (resume owns it).
t head-drafts-excluded "" "$(hc '[]' "$(mk_prc "$CHK_BAD" '[]' '[]' true)")"

# The failing check's name reaches the operator and the prompt, spaces and all
# — which is why the row is TAB-delimited and the names are last.
t head-failing-names-carried "release-exercise / fixture-chain (FAILURE)" \
  "$(hc '[]' "$(mk_prc "$CHK_BAD")" | cut -f6)"
t head-green-names-dash "-" "$(hc '[]' "$(mk_prc "$CHK_OK")" | cut -f6)"

# Round-owed, and the two facts arriving on one row.
CR_REQ='[{"state":"CHANGES_REQUESTED","author":{"login":"p1"}}]'
t head-round-owed-green owed "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_REQ")" | cut -f5)"
t head-round-owed-red-still-owed owed "$(hc '["p1"]' "$(mk_prc "$CHK_BAD" "$CR_REQ")" | cut -f5)"
t head-round-owed-red-is-red red "$(hc '["p1"]' "$(mk_prc "$CHK_BAD" "$CR_REQ")" | cut -f4)"
# An outstanding panel request means the round is not whole yet.
t head-round-not-whole - \
  "$(hc '["p1","p2"]' "$(mk_prc "$CHK_OK" "$CR_REQ" '[{"login":"p2"}]')" | cut -f5)"

# --- the ci-red ledger key: why the head is the ID, not the value (#17) -------
# ledger_filter re-fires when the value sorts GREATER, and a SHA has no order.
# This is the negative control for the scheme NOT used: keyed the ordinary way,
# a corrective push whose oid happens to sort below the previous one is
# suppressed — the wake would be lost exactly when the builder fixed something.
CLG_NAIVE="$TMP/ci-naive"
printf 'o/r#7 fff0000\n' | ledger_commit "$CLG_NAIVE"
t ci-red-naive-sha-value-loses-the-push 0 \
  "$(printf 'o/r#7 000ffff\n' | ledger_filter "$CLG_NAIVE" | n)"
# The scheme the module uses: head in the id, fixed sentinel value.
CLG="$TMP/ci-red"
printf 'o/r#7@fff0000\thead\n' | ledger_commit "$CLG"
t ci-red-new-head-wakes 1 "$(printf 'o/r#7@000ffff\thead\n' | ledger_filter "$CLG" | n)"
t ci-red-same-head-quiet 0 "$(printf 'o/r#7@fff0000\thead\n' | ledger_filter "$CLG" | n)"
# ...and an unchanged red head is reported rather than silently dropped (#59).
t ci-red-same-head-reported "o/r#7@fff0000" \
  "$(printf 'o/r#7@fff0000\thead\n' | ledger_suppressed "$CLG" | cut -f1)"

# --- the module's row slicing ------------------------------------------------
# The awk programs are asserted literally against the module AND run here on a
# fixture. Neither alone is enough: the grep proves the module still contains
# this expression, the fixture proves the expression is right. Edit both and
# the behaviour is still checked; edit the module alone and the grep fails.
BMOD="$SHARED/lib/duty-builder.sh"
# shellcheck disable=SC2016  # awk field refs, quoted exactly as the module has them
AWK_ROUNDS='$5 == "owed" && ($4 == "green" || $4 == "none") { print $1, $2 }'
# shellcheck disable=SC2016
AWK_BLOCKED='$5 == "owed" && $4 == "red" { print $1 }'
# shellcheck disable=SC2016
AWK_HELD='$5 == "owed" && $4 == "pending" { print $1 }'
# shellcheck disable=SC2016
AWK_RED='$4 == "red" { print $1 "@" $3 "\thead\t" $6 }'
for pair in "rounds:$AWK_ROUNDS" "blocked:$AWK_BLOCKED" "held:$AWK_HELD" "red:$AWK_RED"; do
  if grep -Fq "${pair#*:}" "$BMOD"; then r1=present; else r1=MISSING; fi
  t "ci-red-awk-in-module-${pair%%:*}" present "$r1"
done
ROWS="$(printf '%s\n' \
  "$(printf 'o/r#1\tT1\taaa\tred\towed\tcheck (FAILURE)')" \
  "$(printf 'o/r#2\tT2\tbbb\tgreen\towed\t-')" \
  "$(printf 'o/r#3\tT3\tccc\tred\t-\tcheck (FAILURE)')" \
  "$(printf 'o/r#4\tT4\tddd\tpending\towed\t-')")"
# #45: the red-headed round is NOT a build wake — and neither is the pending
# one (danmt's ruling, #64). Opening a round while the check is still running
# spends the panel on a head that may go red, which is what #45 measured on
# crew#40. Only o/r#2 (green) survives; o/r#4 (pending) is now held.
t ci-red-rounds-exclude-red "$(printf 'o/r#2 T2')" \
  "$(awk -F'\t' "$AWK_ROUNDS" <<<"$ROWS")"
# ...but neither hold is silent — the operator is told which round is held and
# why, and the two reasons are NOT interchangeable: red is the author's own
# work, pending is a wait that nobody owes anything for.
t ci-red-blocked-round-named "o/r#1" "$(awk -F'\t' "$AWK_BLOCKED" <<<"$ROWS")"
t ci-red-held-round-named "o/r#4" "$(awk -F'\t' "$AWK_HELD" <<<"$ROWS")"
# A pending head must NOT wake ci-red: nothing has failed, so there is no
# investigation to launch and no rerun to cap.
t pending-head-does-not-wake-ci-red "" \
  "$(awk -F'\t' "$AWK_RED" <<<"$(printf 'o/r#4\tT4\tddd\tpending\towed\t-')")"
# The two hold messages must not be the same string, or the pending hold reads
# as "CI first, fix it" and tells the operator the author owes work.
RED_MSG="$(grep -c 'the check at its head is RED' "$BMOD")"
HELD_MSG="$(grep -c 'has not finished' "$BMOD")"
t hold-messages-are-distinct "1 1" "$RED_MSG $HELD_MSG"
# #17: every red head wakes, round owed or not.
t ci-red-items-both-heads "$(printf 'o/r#1@aaa\thead\tcheck (FAILURE)\no/r#3@ccc\thead\tcheck (FAILURE)')" \
  "$(awk -F'\t' "$AWK_RED" <<<"$ROWS")"

# codex's regression ask, end to end rather than at the classifier: a CANCELLED
# head with a round owed must not reach the build wake, and must reach the
# ci-red wake instead. The classifier tests above prove `red`; these prove the
# consequence, which is what #45 and #17 are actually about.
CANCEL_ROW="$(hc '["p1"]' "$(mk_prc "$CHK_CANCEL" "$CR_REQ")")"
t head-cancelled-round-is-blocked "" "$(awk -F'\t' "$AWK_ROUNDS" <<<"$CANCEL_ROW")"
t head-cancelled-wakes-ci-red "o/r#1@abc1234" \
  "$(awk -F'\t' "$AWK_RED" <<<"$CANCEL_ROW" | cut -f1)"
t head-cancelled-named-in-the-wake "check (CANCELLED)" "$(cut -f6 <<<"$CANCEL_ROW")"

# --- the ceremony#163 regression case (#17's last acceptance criterion) ------
# The incident this issue was filed from, modelled end to end: a PR with
# current-head approvals from the full panel, mergeable, no changes requested,
# no conflict, no outstanding review request — and `release-exercise /
# fixture-chain` failed during job SETUP on an HTTP 429 fetching
# actions/checkout, so none of the PR's code ever ran. Every wake condition the
# builder had looked past it, and the PR sat.
C163_REVIEWS='[{"state":"APPROVED","author":{"login":"p1"}},{"state":"APPROVED","author":{"login":"p2"}}]'
C163="$(jq -cn --argjson lr "$C163_REVIEWS" --argjson c "$CHK_BAD" \
  '[{number:163, isDraft:false, updatedAt:"T9", headRefOid:"deadbee",
     statusCheckRollup:$c, latestReviews:$lr, reviewRequests:[]}]')"
C163_ROW="$(hc '["p1","p2"]' "$C163")"
# It owes no round — which is precisely why nothing woke for it before.
t c163-no-round-owed - "$(cut -f5 <<<"$C163_ROW")"
# It is red, so it wakes now.
t c163-head-is-red red "$(cut -f4 <<<"$C163_ROW")"
t c163-wakes-the-author "o/r#163@deadbee" \
  "$(awk -F'\t' "$AWK_RED" <<<"$C163_ROW" | cut -f1)"
t c163-names-the-failing-job "release-exercise / fixture-chain (FAILURE)" \
  "$(cut -f6 <<<"$C163_ROW")"
# ...and it must NOT become a build wake: claiming a new issue is the thing
# that was wrong to do while this PR sat red.
t c163-not-a-build-wake "" "$(awk -F'\t' "$AWK_ROUNDS" <<<"$C163_ROW")"
# One session per head, then quiet. A second tick on the same red head must not
# buy a second rerun — the "no blind-rerun loop" criterion, as data.
C163_LG="$TMP/c163"
C163_ITEM="$(awk -F'\t' "$AWK_RED" <<<"$C163_ROW")"
t c163-first-tick-fires 1 "$(printf '%s\n' "$C163_ITEM" | ledger_filter "$C163_LG" | n)"
printf '%s\n' "$C163_ITEM" | ledger_commit "$C163_LG"
t c163-second-tick-quiet 0 "$(printf '%s\n' "$C163_ITEM" | ledger_filter "$C163_LG" | n)"
# A corrective push is a new head, and wakes regardless of how the oid sorts.
t c163-corrective-push-wakes 1 \
  "$(printf 'o/r#163@0000001\thead\n' | ledger_filter "$C163_LG" | n)"

# --- wiring (#45/#17) --------------------------------------------------------
if grep -q 'statusCheckRollup' "$BMOD"; then r1=fetched; else r1=MISSING; fi
t ci-red-rollup-fetched fetched "$r1"
# No new API call: the rollup rides the listing the round signal was already
# fetching. Asserted as "requested exactly once, on a line that also carries
# latestReviews" — a second call added for it would be a second occurrence, and
# moving it to a listing of its own would drop latestReviews from that line.
# Comment lines are stripped first. The block above EXPLAINS that the rollup
# rides an existing call, so counting raw occurrences counts the explanation —
# a detector tripping on its own documentation, which this repo has now managed
# three separate times.
t ci-red-rollup-rides-round-listing 1 \
  "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c 'statusCheckRollup')"
if grep -q 'latestReviews,reviewRequests,updatedAt,headRefOid,statusCheckRollup' "$BMOD"; then
  r1=shared
else
  r1=SEPARATE
fi
t ci-red-rollup-on-the-round-call shared "$r1"
if grep -q '.seen-ci-red' "$BMOD"; then r1=ledgered; else r1=UNGUARDED; fi
t ci-red-signal-ledgered ledgered "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '.suppressed-ci-red.$slug' "$BMOD"; then r1=perrepo; else r1=SHARED; fi
t ci-red-suppression-perrepo perrepo "$r1"
# An idle tick must still write a line (#53): a block that logs only when it
# fires makes a quiet box and a busy box look identical.
if grep -q 'no ci-red duty' "$BMOD"; then r1=logged; else r1=SILENT; fi
t ci-red-idle-logs logged "$r1"
# #17's first acceptance criterion: the builder wakes for its own red PR BEFORE
# claiming another issue. Ordering in the file is the ordering in the tick.
ci_at="$(grep -n -- '--- CI-RED' "$BMOD" | head -1 | cut -d: -f1)"
build_at="$(grep -n -- '--- BUILD' "$BMOD" | head -1 | cut -d: -f1)"
if [ -n "$ci_at" ] && [ -n "$build_at" ] && [ "$ci_at" -lt "$build_at" ]; then
  r1=before
else
  r1=AFTER
fi
t ci-red-wakes-before-build before "$r1"
t ci-red-prompt-exists yes "$([ -f "$SHARED/prompts/ci-red.txt" ] && echo yes || echo NO)"
t ci-red-budget-defined yes \
  "$(grep -q '^TIMEOUT_CIRED=' "$SHARED/conf/roles/builder.conf" && echo yes || echo NO)"
# The doctrine half of #45 — the engine excludes the round, the rules say why.
if grep -q 'REVIEW REQUEST REQUIRES A GREEN CHECK' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=stated
else
  r1=SILENT
fi
t round-rules-state-green-head stated "$r1"
# ...including the exception, or the rule becomes one agents route around
# silently instead of arguing with in the open.
if grep -q 'argued exception' "$SHARED/prompts/fragment-round-rules.txt"; then r1=stated; else r1=SILENT; fi
t round-rules-state-exception stated "$r1"

# --- re-request by head, not by verdict (danmt, #64 round) -------------------
# BUILDER.md and build.txt both said to re-request "exactly the non-approvers",
# while converged.jq counts an approval ONLY at the current head:
#
#   map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid) | ...)
#     as $head_approvers
#   | (($panel - $head_approvers) | length == 0) as $panel_approves
#
# So the moment a fix round pushes a commit, an earlier approver goes stale, is
# not re-requested, never re-approves, and $panel - $head_approvers is never
# empty — the handoff wake cannot fire and the PR stalls looking finished. The
# same silent-stall shape as the reviewDecision bug (ceremony#26/#39). This PR
# was itself a live instance: grok approved at e13b0dd, the rebase onto #57
# moved the head, and re-requesting only the two change-requesters would have
# left it unconvergeable.
#
# rebase.txt already had the principle right — it is the one prompt where a
# push is guaranteed. Asserting the invariant rather than the prose: the
# predicate keys on the head, so the prompts that tell a builder whom to
# re-request must say head.
# shellcheck disable=SC2016  # the jq literal converged.jq contains
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/converged.jq"; then
  r1=head-keyed
else
  r1=CHANGED
fi
t converged-counts-approvals-at-head head-keyed "$r1"
for p in build.txt fragment-round-rules.txt; do
  if grep -qi 'by head, not by verdict' "$SHARED/prompts/$p"; then r1=stated; else r1=SILENT; fi
  t "rerequest-by-head-$p" stated "$r1"
done
# The no-push case must survive: re-requesting a fresh approver at an unchanged
# head is what AUTO_APPROVE_REREQUEST exists to absorb, and the rule must not
# tell builders to spam a panel that is still valid.
for p in build.txt fragment-round-rules.txt; do
  if grep -qi 'head did not move' "$SHARED/prompts/$p"; then r1=carved; else r1=MISSING; fi
  t "rerequest-unchanged-head-carveout-$p" carved "$r1"
done
if grep -q 'AUTO_APPROVE_REREQUEST' "$SHARED/conf/fleet.defaults.conf"; then r1=present; else r1=GONE; fi
t auto-approve-rerequest-still-backs-the-carveout present "$r1"

# --- the gate is a whitelist: green or none (danmt's ruling, #64) ------------
# Codex asked for `$4 == "green"`. The ruling took the pending half of that and
# refused the `none` half, because the two are not the same fact: pending is
# transient and resolves itself, `none` is terminal. These tests pin BOTH
# halves, so neither can be reintroduced by someone who reads only one of them.
GATE_ROWS="$(printf '%s\n' \
  "$(printf 'o/noci#1\tT1\taaa\tnone\towed\t-')" \
  "$(printf 'o/q#2\tT2\tbbb\tpending\towed\t-')" \
  "$(printf 'o/g#3\tT3\tccc\tgreen\towed\t-')" \
  "$(printf 'o/x#4\tT4\tddd\tred\towed\tcheck (FAILURE)')")"
t gate-admits-green-and-none "$(printf 'o/noci#1 T1\no/g#3 T3')" \
  "$(awk -F'\t' "$AWK_ROUNDS" <<<"$GATE_ROWS")"
t gate-holds-red "o/x#4" "$(awk -F'\t' "$AWK_BLOCKED" <<<"$GATE_ROWS")"
t gate-holds-pending "o/q#2" "$(awk -F'\t' "$AWK_HELD" <<<"$GATE_ROWS")"
# The `none` half, as a standing negative control. A repo with no CI configured
# is `none` FOREVER, so a gate of `$4 == "green"` does not delay its owed
# rounds — it retires them, and the engine can never open a review round in
# that repo again. head-checks.jq rules `none` a state of its own for exactly
# this reason; the gate has to agree with the classifier.
t gate-green-only-would-strand-the-ci-less-repo "o/g#3 T3" \
  "$(awk -F'\t' '$5 == "owed" && $4 == "green" { print $1, $2 }' <<<"$GATE_ROWS")"
# Every owed round is accounted for — admitted, held-red or held-pending. A
# state that falls out of all three is a round nobody wakes for and nobody
# reports, which is the silent-stall shape this whole PR is against.
t gate-partitions-every-owed-round 4 \
  "$(awk -F'\t' '$5 == "owed" && ($4 == "green" || $4 == "none" || $4 == "red" || $4 == "pending") { c++ } END { print c+0 }' <<<"$GATE_ROWS")"

# What the gate owes for admitting a head with NO evidence: name it. Same
# assert-the-literal-AND-run-it discipline as the row slicing above.
# shellcheck disable=SC2016  # awk field refs, quoted exactly as the module has them
AWK_NOCHECK='$5 == "owed" && $4 == "none" { s = s (s ? "; " : "") $1 " (no checks configured)" } END { print s }'
if grep -Fq "$AWK_NOCHECK" "$BMOD"; then r1=present; else r1=MISSING; fi
t nocheck-awk-in-module present "$r1"
t nocheck-heads-named "o/noci#1 (no checks configured)" \
  "$(awk -F'\t' "$AWK_NOCHECK" <<<"$GATE_ROWS")"
# A green-only set must produce the empty string, which is what the module
# turns into "-" — a literal "" reaching the prompt would read as a bug.
t nocheck-empty-when-all-green "" \
  "$(awk -F'\t' "$AWK_NOCHECK" <<<"$(printf 'o/g#3\tT3\tccc\tgreen\towed\t-')")"
# The datum has to REACH the session, or naming it in the log helps nobody:
# the slot exists in the prompt and the module fills it.
if grep -q '{{HEAD_CHECKS}}' "$SHARED/prompts/build.txt"; then r1=slotted; else r1=MISSING; fi
t build-prompt-has-head-checks-slot slotted "$r1"
# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if grep -q 'HEAD_CHECKS="\$head_checks"' "$BMOD"; then r1=rendered; else r1=MISSING; fi
t build-prompt-head-checks-rendered rendered "$r1"
# render_prompt leaves an unfilled slot in place verbatim, so a slot nobody
# fills would ship "{{HEAD_CHECKS}}" to the model as if it were prose.
printf 'checks: {{HEAD_CHECKS}}' >"$TMP/prompts/hc.txt"
t head-checks-slot-substitutes "checks: o/q#2 (pending)" \
  "$(render_prompt hc.txt HEAD_CHECKS="o/q#2 (pending)")"

# The request-side rule is where codex's scenario actually pays: a round
# answered with argument and NO push, re-requested under a still-running
# check that then fails. Nothing re-runs, because the head never moved.
if grep -qi 'NOT-YET-FINISHED IS NOT GREEN' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=ruled
else
  r1=SILENT
fi
t round-rules-rule-pending ruled "$r1"
# ...with the one carve-out that keeps a CI-less repo from waiting forever for
# a check that is never coming — the same `none` case as the gate above.
if grep -qi 'NO checks configured' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=carved
else
  r1=MISSING
fi
t round-rules-carve-out-no-checks carved "$r1"
# The ruled classification is ceremony's (BUILDER.md, operator 2026-07-27) and
# the classifier already implements it; the prompt must not disagree with
# either. cancelled/stale not green, skipped/neutral green.
for term in 'cancelled or stale' 'skipped or neutral'; do
  if grep -qi "$term" "$SHARED/prompts/fragment-round-rules.txt"; then r1=stated; else r1=SILENT; fi
  t "round-rules-ruled-classification-${term// /-}" stated "$r1"
done

# --- the duty order on paper matches the duty order in the code -------------
# FLEET.md states the fleet-standard order and points at these files as the
# mechanism; ceremony#190 merged that order with ci-red in it. A header that
# lags the module order is how the #149 drift went unnoticed, so it is
# asserted rather than remembered (grok, #64).
for f in bin/duty.sh lib/duty-builder.sh README.md; do
  if grep -q 'resume → ci-red' "$SHARED/$f"; then r1=named; else r1=STALE; fi
  t "duty-order-names-ci-red-${f//\//-}" named "$r1"
done
# Handoff is deliberately NOT gated on a green head, and the reason has to sit
# where the "obvious improvement" would be typed (grok, #64): ci-red fires once
# per head, so a green-gated handoff strands exactly ceremony#163 again.
if awk '/--- HANDOFF/,/--- REBASE/' "$BMOD" | grep -q 'NOT GATED ON A GREEN HEAD'; then
  r1=called-out
else
  r1=SILENT
fi
t handoff-green-gating-called-out called-out "$r1"

# --- configurable doctrine keeps the shipped prompts byte-identical (#76) ---
saved_prompts_dir="$PROMPTS_DIR"
PROMPTS_DIR="$SHARED/prompts"
# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=AGENTS.md DOCTRINE_TRIAGE=TRIAGE.md \
  DOCTRINE_BUILDER=BUILDER.md DOCTRINE_REVIEWER=REVIEWER.md
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  expected="$(sed \
    -e 's/{{DOCTRINE_ENTRYPOINT}}/AGENTS.md/g' \
    -e 's/{{DOCTRINE_TRIAGE}}/TRIAGE.md/g' \
    -e 's/{{DOCTRINE_BUILDER}}/BUILDER.md/g' \
    -e 's/{{DOCTRINE_REVIEWER}}/REVIEWER.md/g' "$prompt_path")"
  t "doctrine-default-byte-identical-$prompt_name" "$expected" \
    "$(render_prompt "$prompt_name")"
done

# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=GUIDE.md DOCTRINE_TRIAGE=OPERATE.md \
  DOCTRINE_BUILDER=CREATE.md DOCTRINE_REVIEWER=VERIFY.md
doctrine_leaks=""
doctrine_unresolved=""
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  rendered="$(render_prompt "$prompt_name")"
  if printf '%s' "$rendered" | grep -Eq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md'; then
    doctrine_leaks="$doctrine_leaks $prompt_name"
  fi
  if printf '%s' "$rendered" | grep -q '{{DOCTRINE_'; then
    doctrine_unresolved="$doctrine_unresolved $prompt_name"
  fi
done
t doctrine-custom-no-shipped-name-leaks "" "$doctrine_leaks"
t doctrine-custom-no-unresolved-slots "" "$doctrine_unresolved"
if grep -REq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md' "$SHARED/prompts"; then
  r1=HARDCODED
else
  r1=slotted
fi
t doctrine-templates-have-no-hardcoded-paths slotted "$r1"
PROMPTS_DIR="$saved_prompts_dir"

# --- crew host: one repo belongs to one fleet (#70) ----------------------
# The check consumes GitHub's shared board state, never another fleet's
# machine. Exercise it through `up --dry-run`: no box or registry mutation is
# needed to notice a foreign claim, and the same checkpoint runs for hire.
OFROOT="$TMP/overlap-fleet"
OFSHIM="$TMP/overlap-bin"
mkdir -p "$OFROOT" "$OFSHIM"
printf 'fixture-box claude builder\n' >"$OFROOT/fleet.roster"
printf 'fixture/overlap\n' >"$OFROOT/repos.txt"
printf 'FLEET_BENCH="local-reviewer"\nFLEET_TRIAGE="local-triage"\nFLEET_HUMAN="local-operator"\n' \
  >"$OFROOT/fleet.conf"
cat >"$OFSHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
cat >"$OFSHIM/gh" <<'EOF'
#!/usr/bin/env bash
case "${FOREIGN_ACTOR:-}" in
  "") printf '[{"type":"IssuesEvent","actor":{"login":"local-triage"},"payload":{"action":"opened"}}]\n' ;;
  *)  printf '[{"type":"IssuesEvent","actor":{"login":"%s"},"payload":{"action":"assigned","assignee":{"login":"%s"}}}]\n' \
        "$FOREIGN_ACTOR" "$FOREIGN_ACTOR" ;;
esac
EOF
chmod +x "$OFSHIM/box" "$OFSHIM/gh"
before_registry="$(cat "$OFROOT/repos.txt")"
overlap_out="$(env CREW_CONFIG_DIR="$OFROOT" FOREIGN_ACTOR=other-builder \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$overlap_out" in
  *"WARN one-repo-one-fleet: fixture/overlap belongs to @local-operator's fleet"*"claim by @other-builder indicates @other-builder's fleet"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-names-repo-and-both-fleets named "$r1"
case "$overlap_out" in *"registries LEFT UNCHANGED"*"operators must decide"*) r1=operator ;; *) r1=actioned ;; esac
t fleet-overlap-resolution-is-operator operator "$r1"
t fleet-overlap-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

disjoint_out="$(env CREW_CONFIG_DIR="$OFROOT" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$disjoint_out" in *"WARN one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-disjoint-is-silent silent "$r1"
t fleet-disjoint-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

# --- install.sh: the operator agent-profile transport contract (#75) --------
# The ordering is the whole difficulty (codex Blocking 4 on #73): install.sh
# refuses an unknown agent BEFORE it creates conf/agents, so a profile that
# arrived only with the conf copy would fail its own validation — a vendor
# that lists in `crew profiles` and dies at `crew hire`. The host stages
# operator profiles into ~/duty/.crew-seed-agents ahead of the run; these
# fixtures assert every clause: a seeded profile passes validation, the
# operator copy is what conf/agents carries (same-name wins where load_conf
# reads), the seed is consumed on success AND failure, and an unseeded
# unknown agent still dies.
PHOME="$TMP/profile-home"
PDUTY="$PHOME/duty"
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/vendorx.conf" <<'EOF'
# vendorx — operator-supplied fixture vendor (never shipped)
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="vendorx"
AGENT_LOGIN_HINT="vendorx auth login"
bot_cli_probe() { return 0; }
bot_cli_present() { command -v vendorx >/dev/null 2>&1; }
EOF
profile_install() {
  env HOME="$PHOME" DUTY_DIR="$PDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
if profile_install --agent vendorx --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-validates-before-conf-exists 0 "$r1"
[ -f "$PDUTY/conf/agents/vendorx.conf" ] && r1=installed || r1=missing
t operator-profile-lands-in-conf-agents installed "$r1"
if grep -q 'operator-supplied fixture vendor' "$PDUTY/conf/agents/vendorx.conf" 2>/dev/null; then
  r1=operator
else
  r1=other
fi
t operator-profile-is-the-operator-copy operator "$r1"
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed consumed "$r1"
# The shipped set still installs whole beside the operator's addition.
[ -f "$PDUTY/conf/agents/claude.conf" ] && r1=present || r1=missing
t operator-profile-shipped-set-intact present "$r1"

# Same-name precedence: an operator claude.conf beats the shipped one — and
# the win must hold at RUNTIME, where load_conf sources whatever
# conf/agents carries (common.sh:34); settled in the copy, not by a reader.
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/claude.conf" <<'EOF'
# claude — operator override fixture
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="claude"
AGENT_LOGIN_HINT="operator override wins"
bot_cli_probe() { return 0; }
bot_cli_present() { return 0; }
EOF
profile_install --agent claude --role reviewer >/dev/null 2>&1
if grep -q 'operator override fixture' "$PDUTY/conf/agents/claude.conf" 2>/dev/null; then
  r1=operator
else
  r1=shipped
fi
t operator-profile-same-name-wins operator "$r1"
# shellcheck disable=SC2016  # $DUTY_DIR and $AGENT_LOGIN_HINT expand in the child shell
runtime_hint="$(env DUTY_DIR="$PDUTY" HOME="$PHOME" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_conf; printf %s "$AGENT_LOGIN_HINT"')"
t operator-profile-wins-at-load_conf "operator override wins" "$runtime_hint"

# The gap the contract closes, inverted: an agent nobody transported and
# nobody ships must still die at validation, not at first duty tick.
if profile_install --agent vendory --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-unknown-still-refused 1 "$r1"

# A one-install transport on FAILURE too: a failing install (here: a role
# that does not exist, checked after the agent) must not leave seeds behind
# for a later bare run to resurrect.
mkdir -p "$PDUTY/.crew-seed-agents"
printf '# vendorz — fixture\n' >"$PDUTY/.crew-seed-agents/vendorz.conf"
profile_install --agent vendorz --role nosuchrole >/dev/null 2>&1 || true
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed-on-failure consumed "$r1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
