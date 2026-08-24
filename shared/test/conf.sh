#!/usr/bin/env bash
# shared/test/conf.sh — standalone conf subject suite.
# shellcheck disable=SC2100  # fixture result labels containing hyphens are strings
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"
# shellcheck source=shared/lib/duty-builder.sh
source "$SHARED/lib/duty-builder.sh"

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
printf '%s\n' "$*" >>"$GH_CALLS"
case "${EVENT_PAYLOAD:-readable}:$*" in
  unreadable:*fixture/overlap*) printf '{"message":"API rate limit exceeded"}\n' ;;
  unreadable:*) printf '[{"type":"IssuesEvent","actor":{"login":"other-builder"},"payload":{"action":"assigned","assignee":{"login":"other-builder"}}}]\n' ;;
  empty:*) printf '[]\n' ;;
  readable:*) printf '[{"type":"IssuesEvent","actor":{"login":"local-triage"},"payload":{"action":"opened"}}]\n' ;;
  foreign:*) printf '[{"type":"IssuesEvent","actor":{"login":"%s"},"payload":{"action":"assigned","assignee":{"login":"%s"}}}]\n' \
        "$FOREIGN_ACTOR" "$FOREIGN_ACTOR" ;;
esac
EOF
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat >"$OFSHIM/jq" <<'EOF'
#!/usr/bin/env bash
[ -z "${JQ_SUCCESS_STDERR:-}" ] || printf '%s\n' "$JQ_SUCCESS_STDERR" >&2
exec "$REAL_JQ" "$@"
EOF
chmod +x "$OFSHIM/box" "$OFSHIM/gh" "$OFSHIM/jq"
before_registry="$(cat "$OFROOT/repos.txt")"
GH_CALLS="$TMP/overlap-gh-calls"
overlap_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=foreign FOREIGN_ACTOR=other-builder GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$overlap_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-names-repo-and-foreign-actor named "$r1"
case "$overlap_out" in *"registries LEFT UNCHANGED"*"operators must decide"*) r1=operator ;; *) r1=actioned ;; esac
t fleet-overlap-resolution-is-operator operator "$r1"
t fleet-overlap-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

stderr_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=foreign FOREIGN_ACTOR=other-builder \
  JQ_SUCCESS_STDERR='synthetic jq warning' GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$stderr_out" in *"synthetic jq warning"*) r1=CONTAMINATED ;; *) r1=isolated ;; esac
t fleet-overlap-successful-jq-stderr-is-not-data isolated "$r1"
case "$stderr_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=preserved ;;
  *) r1=LOST ;;
esac
t fleet-overlap-successful-jq-stderr-preserves-data preserved "$r1"

disjoint_out="$(env CREW_CONFIG_DIR="$OFROOT" GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$disjoint_out" in *"WARN one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-disjoint-is-silent silent "$r1"
t fleet-disjoint-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

printf 'fixture/overlap\nfixture/zlater\n' >"$OFROOT/repos.txt"
if unreadable_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=unreadable GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"; then
  r1=survived
else
  r1=FAILED
fi
t fleet-overlap-unreadable-payload-survives survived "$r1"
case "$unreadable_out" in
  *"NOTE one-repo-one-fleet: unreadable recent board activity for fixture/overlap"*"overlap detection skipped"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-unreadable-payload-names-repo named "$r1"
case "$unreadable_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/zlater"*) r1=continued ;;
  *) r1=STOPPED ;;
esac
t fleet-overlap-unreadable-payload-continues continued "$r1"

empty_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=empty GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$empty_out" in *"one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-overlap-empty-array-is-silent silent "$r1"
printf 'fixture/overlap\n' >"$OFROOT/repos.txt"
if grep -q 'repos/fixture/outside/events' "$GH_CALLS"; then r1=QUERIED; else r1=silent; fi
t fleet-out-of-scope-activity-is-not-queried silent "$r1"

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

# --- valid_version: ONE gate, in install.sh and cli/crew, must not drift.
# The installer builds versions/<v> paths from a version, and cli/crew builds
# them for `crew use`/`uninstall` (heavy-duty/crew#96); a divergence is how a
# crafted version slips past one gate and into an rm/ln behind the other. box's
# test/cli.sh diffs its pair the same way. Assert the two copies are
# byte-identical, then drive the gate against the path-escaping shapes it exists
# to refuse.
vv_extract() { awk '/^valid_version\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$1"; }
t valid_version-parity "$(vv_extract "$ROOT/install.sh")" "$(vv_extract "$ROOT/cli/crew")"
eval "$(vv_extract "$ROOT/cli/crew")"
for bad in "" "." ".hidden" "-rf" "../evil" "a/b" "a b" "a;b"; do
  if valid_version "$bad"; then got=accept; else got=reject; fi
  t "valid_version-refuses[$bad]" reject "$got"
done
for ok in "0.1.0" "0.1.0-dev" "0.1.0-rc1" "1.2.3+meta"; do
  if valid_version "$ok"; then got=accept; else got=reject; fi
  t "valid_version-accepts[$ok]" accept "$got"
done

# --- convergence: rig's role marker, parsed (crew#220) ----------------------
# `crew hire` is crew's irreversible verb — it installs the engine and arms
# cron — and since #220 the thing that authorizes it is this parse. A box whose
# tenant role never converged was indistinguishable from a healthy one in every
# column crew had, so the marker became the discriminator; what the marker MEANS
# is decided here, in eight lines that no fixture fleet can exercise fully.
#
# Extracted and eval'd out of cli/crew, the same way valid_version above is:
# these are the shapes a real /etc/rig/role takes (heavy-duty/rig,
# commands/bootstrap-tenant.sh writes the tenant line, commands/bootstrap.sh
# the machine one) plus the hand-edited near-misses, and a stub box can only
# ever answer with one of them at a time.
# vv_extract above assumes a multi-line body, which is fine for the one
# function it takes. report_field is a ONE-LINER, and on that shape a
# stop-at-`^}` rule never fires on its own line — it runs on to the next
# function's closing brace and evals that too. It happened to be harmless here,
# which is exactly the kind of silence that stops being harmless the day
# somebody inserts a function between the two. So this one closes on its own
# line when the definition is self-contained.
cv_extract() { awk -v f="$2" '
  $0 ~ "^"f"\\(\\) \\{" { print; if ($0 ~ /\}[[:space:]]*$/) exit; p=1; next }
  p { print; if ($0 ~ /^\}$/) exit }
' "$1"; }
eval "$(cv_extract "$ROOT/cli/crew" report_field)"
eval "$(cv_extract "$ROOT/cli/crew" marker_fault)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_of)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_detail)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_recovery)"
# An extraction that came back empty leaves every assertion below testing a
# function that does not exist — and `t` between two empty strings passes. The
# suite would report the gate as covered while executing none of it, which is
# the same shape of silence the manifest parse sat in. Say so once, here.
cv_lifted=""
for cv_f in report_field marker_fault convergence_of convergence_detail convergence_recovery; do
  declare -F "$cv_f" >/dev/null || cv_lifted="$cv_lifted $cv_f"
done
t convergence-functions-lifted "" "$cv_lifted"

# A box that answered NOTHING is `unknown`, and unknown is not converged. This
# is rule 5 of #220's spec and the whole safety property: the defect closed is a
# broken box passing for a healthy one, so the case crew cannot see into must
# refuse rather than proceed. An empty capture is what an unreachable box, a
# stopped box and a `box exec` that died all produce.
t convergence-empty-capture-is-unknown unknown "$(convergence_of "")"
t convergence-no-probe-line-is-unknown unknown "$(convergence_of "marker=role=claude-box tenant=yes host=no")"

# Answered, and rig never wrote a marker: the reported case. The bootstrap
# failed, so the vendor CLI was never installed.
t convergence-answered-without-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\n')")"
t convergence-empty-marker-value-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=\n')")"

# The tenant line rig actually writes.
t convergence-tenant-marker-is-converged converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box tenant=yes host=no\n')")"
# …for every agent in the bench, since the role name is data and not a fixed set.
for cv_agent in claude codex grok kimi; do
  t "convergence-tenant-marker[$cv_agent]" converged \
    "$(convergence_of "$(printf 'probe=ok\nmarker=role=%s-box tenant=yes host=no\n' "$cv_agent")")"
done
# Hand-edited with tabs or doubled spaces reads the same way, rather than
# silently failing to match — whitespace is normalised before the field test,
# exactly as rig's own root_door_of does it.
t convergence-tenant-marker-tabs-are-normalised converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box\ttenant=yes\thost=no\n')")"
t convergence-tenant-marker-double-space-is-normalised converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box  tenant=yes  host=no\n')")"

# A MACHINE marker is not an agent tenant. rig writes this shape for the
# `-server` roles and for a guest joined as a workload; a crew member is a box
# guest converged by the tenant bootstrap, and nothing else installed its
# vendor CLI.
t convergence-machine-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=workload-server root-door=open host=no join=yes join-by=rig\n')")"
t convergence-host-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=staging-server root-door=closed host=yes join=yes join-by=rig\n')")"

# HALF A MARKER is not a converged box. #220 pins the verdict on both fields —
# "parses to a non-empty `role=`, and carries `tenant=yes`" — and rig writes the
# two in one line, so a marker with one and not the other is a box interrupted
# partway through converging. Reading it as converged would hire on the strength
# of the half that happened to land.
t convergence-refuses-marker-without-a-role incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=tenant=yes host=no\n')")"
t convergence-refuses-empty-role-field incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role= tenant=yes host=no\n')")"
case "$(convergence_detail "$(printf 'probe=ok\nmarker=tenant=yes host=no\n')")" in
  *"no role="*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-half-written-marker named "$r1"

# The verdict and the reason are ONE reader, so they cannot drift apart. A row
# reading INCOMPLETE beside a detail saying nothing is missing is a refusal an
# operator cannot act on, and that is what two copies of this parse decay into.
cv_disagree=""
for cv_m in 'role=claude-box tenant=yes host=no' 'role=workload-server root-door=open host=no' \
            'role= tenant=yes host=no' 'tenant=yes' 'role=claude-box tenant=yesish'; do
  cv_v="$(convergence_of "$(printf 'probe=ok\nmarker=%s\n' "$cv_m")")"
  cv_d="$(convergence_detail "$(printf 'probe=ok\nmarker=%s\n' "$cv_m")")"
  case "$cv_v:$cv_d" in
    converged:*|incomplete:?*) : ;;
    *) cv_disagree="$cv_disagree [$cv_m -> $cv_v / ${cv_d:-<silence>}]" ;;
  esac
done
t convergence-verdict-and-detail-agree "" "$cv_disagree"

# MUST FAIL — the field-anchoring. rig#77 is the scar: an unanchored pattern let
# `root-door=closedish` resolve as `closed` and pass the one gate authorizing an
# irreversible act. Hiring is crew's irreversible act, so a value that merely
# EXTENDS `yes`, or a key that merely ENDS in `tenant`, must not authorize it.
for cv_bad in "tenant=yesish" "tenant=yes-not" "xtenant=yes" "no-tenant=yes" "tenant=no" "tenant=YES"; do
  t "convergence-refuses-near-miss[$cv_bad]" incomplete \
    "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box %s host=no\n' "$cv_bad")")"
done

# The three causes take three different actions, so the detail must name which
# one it is. Collapsing them into "not converged" throws away the only part of
# the refusal an operator can act on.
case "$(convergence_detail "")" in
  *"did not answer"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-unreadable-case named "$r1"
case "$(convergence_detail "$(printf 'probe=ok\n')")" in
  *"/etc/rig/role"*"never converged"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-missing-marker named "$r1"
case "$(convergence_detail "$(printf 'probe=ok\nmarker=role=workload-server root-door=open host=no\n')")" in
  *"machine role"*"role=workload-server"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-quotes-the-machine-marker named "$r1"

# The recovery is the three commands `box` itself prints when the bootstrap
# hook fails, and it names the box's OWN tenant — a generic one is a command
# that fails when pasted.
t convergence-recovery-names-the-tenant \
  "box shell kimi-reviewer → sudo rig bootstrap kimi-box → box snapshot kimi-reviewer bootstrapped" \
  "$(convergence_recovery kimi-reviewer kimi)"
# An off-roster box names no agent. A placeholder an operator can fill in beats
# a malformed `rig bootstrap -box`.
case "$(convergence_recovery adhoc-box "")" in
  *"rig bootstrap <agent>-box"*) r1=placeholder ;; *) r1=MALFORMED ;;
esac
t convergence-recovery-without-an-agent-is-a-placeholder placeholder "$r1"
# It must never advise the verb that caused the incident. `crew hire` on a box
# the table told the operator to hire is the whole of #220.
case "$(convergence_recovery kimi-reviewer kimi)" in
  *"crew hire"*) r1=ADVISES_HIRE ;; *) r1=bootstrap ;;
esac
t convergence-recovery-does-not-advise-crew-hire bootstrap "$r1"

# --- convergence: rig's marker and manifest, as the real files (crew#220) ---
# THE REAL TEXT, not a fixture format. Read on 2026-08-01 from inside a
# rig-converged tenant box — the box this branch was built in, which is itself
# a rig box — with the files written by rig 0.3.2-dev on the same day:
#
#     $ ls -l /etc/rig/
#     -rw-r--r-- 1 root root 129 Aug  1 12:31 manifest
#     -rw-r--r-- 1 root root  35 Aug  1 12:31 role
#     $ cat /etc/rig/role
#     role=claude-box tenant=yes host=no
#     $ cat /etc/rig/manifest
#     schema=1
#     bootstrapped_by=0.3.2-dev
#     bootstrapped_at=2026-08-01T12:31:11Z
#     converged_by=0.3.2-dev
#     converged_at=2026-08-01T12:31:11Z
#
# The parse is asserted against THAT, byte for byte, rather than against a
# shape read out of rig's source: reading the writer tells you what rig means
# to emit, and only the artifact tells you what it emitted. Both files are
# 0644, which is the other fact this read establishes — crew's exec must not
# grow a `sudo`, because a `sudo` in a non-interactive `box exec` is itself a
# way to turn a converged box into a false INCOMPLETE.
cv_real_role='role=claude-box tenant=yes host=no'
cv_real_manifest="$(printf '%s\n' \
  'schema=1' \
  'bootstrapped_by=0.3.2-dev' \
  'bootstrapped_at=2026-08-01T12:31:11Z' \
  'converged_by=0.3.2-dev' \
  'converged_at=2026-08-01T12:31:11Z')"
# …assembled into the capture rig_report produces from them: `probe=ok`, the
# marker's first line, and the manifest prefixed a line at a time. The box side
# does no interpreting precisely so that this — the part that decides meaning —
# is reachable from here.
cv_real_report="$(printf 'probe=ok\nmarker=%s\n%s\n' "$cv_real_role" \
  "$(printf '%s\n' "$cv_real_manifest" | sed 's|^|rig:|')")"

t convergence-real-marker-is-converged converged "$(convergence_of "$cv_real_report")"
t convergence-real-manifest-converged-by 0.3.2-dev \
  "$(report_field rig:converged_by "$cv_real_report")"
t convergence-real-manifest-converged-at 2026-08-01T12:31:11Z \
  "$(report_field rig:converged_at "$cv_real_report")"
# The namespace, and the `^` that makes it real. `schema=1` unprefixed would
# answer a `report_field schema` somebody adds later; prefixed, and read with an
# anchor, it cannot. Drop the `^` from report_field and this is the assertion
# that reds — the namespace becomes decoration.
t convergence-real-manifest-keys-are-namespaced "" "$(report_field schema "$cv_real_report")"
t convergence-real-marker-survives-the-manifest "$cv_real_role" \
  "$(report_field marker "$cv_real_report")"

# MUST FAIL — the manifest's own `closedish`, and it is a NAMING discipline
# rather than an anchoring one. rig puts `bootstrapped_by=`/`bootstrapped_at=`
# TWO LINES ABOVE the `converged_*` pair, so any read that goes after the
# FAMILY — `.*_at=`, "grab the timestamp" — answers with the bootstrap's, which
# is the date the box was first built rather than the one that authorized the
# hire. The guard is that every read names the whole key. On the real text
# above the two pairs are equal, which is exactly why that text cannot catch it
# alone: this is the same box re-converged later by a newer rig, where they
# differ and the wrong answer is visible.
cv_reconverged="$(printf 'probe=ok\nmarker=%s\n%s\n' "$cv_real_role" "$(printf '%s\n' \
  'rig:schema=1' \
  'rig:bootstrapped_by=0.3.1' \
  'rig:bootstrapped_at=2026-07-04T08:00:00Z' \
  'rig:converged_by=0.3.2-dev' \
  'rig:converged_at=2026-08-01T12:31:11Z')")"
t convergence-converged-by-is-not-bootstrapped-by 0.3.2-dev \
  "$(report_field rig:converged_by "$cv_reconverged")"
t convergence-converged-at-is-not-bootstrapped-at 2026-08-01T12:31:11Z \
  "$(report_field rig:converged_at "$cv_reconverged")"
# …and from the other direction: a PARTIAL key name gets nothing. `verged_at`
# is a tail of `converged_at`, and a read loose enough to accept it is a read
# loose enough to accept `bootstrapped_at` too — same defect, cheaper to see.
t convergence-read-refuses-a-suffix-key "" \
  "$(report_field rig:verged_at "$cv_reconverged")"

# CORROBORATING, NEVER LOAD-BEARING. A box whose rig predates the manifest
# (rig#61) has a valid role line and no provenance at all — old, not broken.
# Gating the verdict on `converged_at` would turn every box on that rig into a
# refusal, which #220's test plan names as the outcome worse than the bug.
cv_no_manifest="$(printf 'probe=ok\nmarker=%s\n' "$cv_real_role")"
t convergence-without-a-manifest-is-still-converged converged "$(convergence_of "$cv_no_manifest")"
t convergence-without-a-manifest-reports-no-provenance "" \
  "$(report_field rig:converged_by "$cv_no_manifest")"
# …and the inverse must not rescue anything: a full manifest beside a role file
# that never got written is still INCOMPLETE. The manifest cannot vouch for a
# convergence the marker does not claim.
t convergence-manifest-without-a-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\n%s\n' "$(printf '%s\n' "$cv_real_manifest" | sed 's|^|rig:|')")")"

# The marker path is rig's, and it is not crew's to invent. Asserted against the
# source so a refactor that "tidies" it to a crew-shaped path is caught here
# rather than on a real host — crew reads what rig writes, and rig writes these
# two (rig#61 for the manifest).
if grep -q '/etc/rig/role' "$ROOT/cli/crew" && grep -q '/etc/rig/manifest' "$ROOT/cli/crew"; then
  r1=rigs
else
  r1=INVENTED
fi
t convergence-reads-rigs-own-paths rigs "$r1"

# Both files are 0644 on a real box, so the read takes no privilege — and must
# never acquire one. A `sudo` in a NON-INTERACTIVE `box exec` prompts, or fails,
# and either way turns a converged box into a false INCOMPLETE: the refusal
# would then be crew's own doing, on a box that was fine.
rig_report_source="$(cv_extract "$ROOT/cli/crew" rig_report)"
if grep -q 'sudo' <<<"$rig_report_source"; then
  r1=ESCALATES
else
  r1=unprivileged
fi
t convergence-reads-the-marker-without-sudo unprivileged "$r1"
# …and it goes through bxn, never a fresh literal `box exec`. This helper runs
# inside `while read … done < <(read_roster)` in status, hire-all and up, and a
# raw exec there drains the roster FIFO and converges ONE box out of N with
# rc=0 (#48). bxn is the only shape that pins stdin to /dev/null.
if grep -qE '^[[:space:]]*bxn ' <<<"$rig_report_source" &&
   ! grep -q 'box exec' <<<"$rig_report_source"; then
  r1=bxn
else
  r1=RAW_EXEC
fi
t convergence-reads-the-marker-through-bxn bxn "$r1"

# --- cli/crew's self-description: the table is the source of truth (#97) ----
# The property under test is ANTI-DRIFT, not cosmetics. Before #97 the command
# list lived three times — the header comment printed as help, a hand-written
# dispatch case, and each verb's usage string — and it had already diverged.
# These assertions are what make "the help cannot drift from the code" a fact
# rather than a comment.
CLIBIN="$ROOT/cli/crew"
CLISHIM="$TMP/cli-bin"
mkdir -p "$CLISHIM"
cat >"$CLISHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CLISHIM/box"
crewcli() { PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@"; }
crewrc()  { PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" >/dev/null 2>&1; echo $?; }

# Every row's function EXISTS. This is the assertion that makes the table safe
# to dispatch from: a row naming a function nobody wrote is a runtime
# "command not found" on a verb the help advertises.
missing_fn=""
while IFS='^' read -r verb _ _ fn; do
  [ -n "$verb" ] || continue
  grep -q "^$fn()" "$CLIBIN" || missing_fn="$missing_fn $verb->$fn"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-table-functions-exist "" "$missing_fn"

# Every row has a summary — an empty one renders a blank line in `crew help`,
# which is how a verb becomes invisible while still being dispatchable.
empty_sum=""
while IFS='^' read -r verb _ sum _; do
  [ -n "$verb" ] || continue
  [ -n "$sum" ] || empty_sum="$empty_sum $verb"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-table-summaries-present "" "$empty_sum"

# ...and the REVERSE, which is the direction that actually rots: a verb
# implemented but never added to the table. The first version of this suite
# only checked table -> function, so a `cmd_usage` added by a later PR would
# have been dispatchable-by-nobody and invisible in `crew help` with every
# assertion green. Found while rebasing onto #95, which is exactly when a
# sibling PR could have introduced one.
orphan=""
while read -r fn; do
  grep -qF "^$fn\"" "$CLIBIN" || orphan="$orphan $fn"
done < <(grep -oE '^cmd_[a-z_]+\(\)' "$CLIBIN" | sed 's/()//')
t cli-every-verb-has-a-table-row "" "$orphan"

# Every verb appears in `crew help`, and `crew help <verb>` works for each.
help_all="$(crewcli help 2>&1)"
absent="" helpfail=""
while IFS='^' read -r verb _ _ _; do
  [ -n "$verb" ] || continue
  case "$help_all" in *"  $verb "*) : ;; *) absent="$absent $verb" ;; esac
  [ "$(crewrc help "$verb")" = 0 ] || helpfail="$helpfail $verb"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-help-lists-every-verb "" "$absent"
t cli-help-per-command-works "" "$helpfail"

# The two exit codes, which is the whole reason for the split: a caller must
# be able to tell "you typo'd" from "the fleet is broken".
t cli-unknown-command-is-2   2 "$(crewrc nonsensecommand)"
t cli-missing-arg-is-2       2 "$(crewrc hire)"
t cli-unknown-flag-is-2      2 "$(crewrc floor --bogus)"
t cli-flag-before-verb-is-2  2 "$(crewrc --dry-run up)"
t cli-absent-box-is-1        1 "$(crewrc status nosuchbox)"
t cli-help-is-0              0 "$(crewrc help)"
t cli-version-is-0           0 "$(crewrc --version)"

# A value-taking flag with NO value is a malformed invocation, so it must exit
# 2 like every other one — not die through bash's own `set -u` unbound-variable
# handler at exit 1, which is what `$2` and `${2:?...}` both did (codex, review
# of #106). Every value-taking option on every verb, because the defect was
# per-site and so is the fix.
badval=""
for spec in "new --role" "new --agent" "new --name" "new --from" \
            "hire b --role" "hire b --agent" "hire b --ref" "hire-all --ref" \
            "floor --port" "floor --bind" "floor --user" "floor --pass" \
            "floor --interval" "floor --roster"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || badval="$badval [$spec->$rc]"
done
t cli-missing-option-value-is-2 "" "$badval"

# ...and an EMPTY value is refused the same way, which is what the `${2:?}`
# sites already did and what the plain `$2` sites silently accepted.
t cli-empty-option-value-is-2 2 "$(crewrc new --agent "")"

# An unknown flag on the two one-liner parsers was SILENTLY IGNORED — worse
# than the wrong exit code, because `crew hire-all --dry-run` hired the whole
# fleet while reading like a rehearsal.
t cli-hire-all-unknown-flag-is-2 2 "$(crewrc hire-all --dry-run)"
t cli-up-unknown-flag-is-2       2 "$(crewrc up --bogus)"
t cli-up-dry-run-still-works     0 "$(crewrc up --dry-run)"

# `up --dry-run` must describe the hire that follows a create (#218). Drive a
# mixed roster through the real CLI in both modes: the box shim records the
# convergence probe at the top of every real hire_box call, giving the
# equality property without copying cmd_up's roster arithmetic into the test.
UPCONF="$TMP/up-dry-run-config"
UPSHIM="$TMP/up-dry-run-bin"
UPSTATE="$TMP/up-dry-run-state"
UPCALLS="$TMP/up-dry-run-calls"
UP_VERSION="$(head -1 "$ROOT/VERSION" | tr -d '\r\n')"
mkdir -p "$UPCONF" "$UPSHIM"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$UPCONF/"
cat >"$UPCONF/fleet.roster" <<'EOF'
fresh claude builder
running codex reviewer
stopped kimi reviewer
EOF
cat >"$UPSHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat >"$UPSHIM/box" <<'EOF'
#!/usr/bin/env bash
json_state() {
  awk 'BEGIN { printf "[" } { printf "%s{\"name\":\"%s\",\"status\":\"%s\"}", sep, $1, $2; sep="," } END { print "]" }' "$UPSTATE"
}
case "$1" in
  list) json_state ;;
  info)
    state="$(awk -v name="$2" '$1 == name { print $2; exit }' "$UPSTATE")"
    printf '[{"name":"%s","status":"%s"}]\n' "$2" "$state"
    ;;
  new)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s running\n' "$name" >>"$UPSTATE"
    printf 'mutate:new:%s\n' "$name" >>"$UPCALLS"
    ;;
  start)
    printf 'mutate:start:%s\n' "$2" >>"$UPCALLS"
    ;;
  exec)
    name="$2"
    script="${*: -1}"
    case "$script" in
      *'/etc/rig/role'*)
        printf 'hire:%s\n' "$name" >>"$UPCALLS"
        printf 'probe=ok\nmarker=role=fixture tenant=yes host=no\n'
        ;;
      *'engine-manifest.sh'*)
        printf 'engine:%s\n' "$name" >>"$UPCALLS"
        printf 'state=current\nstamp=crew@%s fixture\nrecorded=crew@%s fixture\n' "$UP_VERSION" "$UP_VERSION"
        ;;
      *'repos.txt'*) printf 'fixture/operator-repo\n' ;;
      *) printf 'exec:%s\n' "$name" >>"$UPCALLS" ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$UPSHIM/gh" "$UPSHIM/box"
up_reset() {
  printf 'running running\nstopped stopped\n' >"$UPSTATE"
  : >"$UPCALLS"
}
up_run() {
  env CREW_CONFIG_DIR="$UPCONF" UPSTATE="$UPSTATE" UPCALLS="$UPCALLS" UP_VERSION="$UP_VERSION" \
    PATH="$UPSHIM:$PATH" bash "$CLIBIN" up "$@"
}

: >"$UPSTATE"
: >"$UPCALLS"
if up_new_out="$(up_run --dry-run 2>&1)"; then up_new_rc=0; else up_new_rc=$?; fi
t cli-up-dry-run-all-new-exits-zero 0 "$up_new_rc"
t cli-up-dry-run-all-new-reports-every-create 3 \
  "$(grep -c ': WOULD create ' <<<"$up_new_out" || true)"
t cli-up-dry-run-all-new-reports-every-hire 3 \
  "$(grep -c ": WOULD hire (new box — engine crew@$UP_VERSION, cron armed)$" <<<"$up_new_out" || true)"
case "$up_new_out" in
  *'up --dry-run: 3 would be created, 0 started, 3 hired'*) r1=complete ;;
  *) r1="$up_new_out" ;;
esac
t cli-up-dry-run-all-new-summary complete "$r1"
t cli-up-dry-run-all-new-touches-nothing "" "$(cat "$UPCALLS")"

up_reset
if up_dry_out="$(up_run --dry-run 2>&1)"; then up_dry_rc=0; else up_dry_rc=$?; fi
t cli-up-dry-run-mixed-exits-zero 0 "$up_dry_rc"
t cli-up-dry-run-new-box-hires 1 \
  "$(grep -c "^fresh: WOULD hire (new box — engine crew@$UP_VERSION, cron armed)$" <<<"$up_dry_out" || true)"
t cli-up-dry-run-existing-wording 2 \
  "$(grep -c ": WOULD hire (currently: crew@$UP_VERSION fixture)$" <<<"$up_dry_out" || true)"
case "$up_dry_out" in
  *'up --dry-run: 1 would be created, 1 started, 3 hired'*) r1=complete ;;
  *) r1="$up_dry_out" ;;
esac
t cli-up-dry-run-summary complete "$r1"
t cli-up-dry-run-does-not-mutate "" "$(grep '^mutate:' "$UPCALLS" || true)"
t cli-up-dry-run-does-not-probe-new-box "" "$(grep ':fresh$' "$UPCALLS" || true)"
dry_hires="$(grep -c ': WOULD hire ' <<<"$up_dry_out" || true)"

up_reset
if up_run >/dev/null 2>&1; then up_real_rc=0; else up_real_rc=$?; fi
t cli-up-real-run-mixed-exits-zero 0 "$up_real_rc"
t cli-up-dry-run-hire-count-matches-real "$dry_hires" \
  "$(grep -c '^hire:' "$UPCALLS" || true)"
t cli-up-real-run-still-creates-and-starts 'mutate:new:fresh
mutate:start:stopped' "$(grep '^mutate:' "$UPCALLS" || true)"

# create-all is a fleet convergence verb: one failed box must not prevent the
# remaining roster rows from being attempted, and the final report is the
# operator's record of the partial run (#219).
CACONF="$TMP/create-all-config"
CASHIM="$TMP/create-all-bin"
CA_CALLS="$TMP/create-all-calls"
mkdir -p "$CACONF" "$CASHIM"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$CACONF/"
cat >"$CACONF/fleet.roster" <<'EOF'
one claude triage
two codex builder
three grok reviewer
four kimi reviewer
five claude reviewer
six codex reviewer
seven grok reviewer
EOF
cat >"$CASHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '%s\n' "${BOX_LIST:-[]}" ;;
  new)
    name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$name" >>"$CA_CALLS"
    [ "$name" != "${FAIL_NAME:-}" ]
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CASHIM/box"
ca_run() {
  env CREW_CONFIG_DIR="$CACONF" CA_CALLS="$CA_CALLS" \
    BOX_LIST="${BOX_LIST:-[]}" FAIL_NAME="${FAIL_NAME:-}" \
    PATH="$CASHIM:$PATH" bash "$CLIBIN" create-all
}
BOX_LIST='[{"name":"three"}]' FAIL_NAME=four
: >"$CA_CALLS"
if ca_out="$(ca_run 2>&1)"; then ca_rc=0; else ca_rc=$?; fi
t cli-create-all-partial-is-nonzero 1 "$ca_rc"
t cli-create-all-continues-after-failure "one
two
four
five
six
seven" "$(cat "$CA_CALLS")"
case "$ca_out" in
  *"create-all: 5 created, 1 existing, 1 failed (four)."*) r1=complete ;;
  *) r1="$ca_out" ;;
esac
t cli-create-all-partial-summary complete "$r1"

# The all-pass path retains the established closing text byte-for-byte.
BOX_LIST='[]' FAIL_NAME=''
: >"$CA_CALLS"
if ca_all_out="$(ca_run 2>&1)"; then ca_all_rc=0; else ca_all_rc=$?; fi
t cli-create-all-all-pass-is-zero 0 "$ca_all_rc"
case "$ca_all_out" in
  *"7 created. Next: log each new box in by hand"*) r1=unchanged ;;
  *) r1="$ca_all_out" ;;
esac
t cli-create-all-all-pass-summary-unchanged unchanged "$r1"

# ...and `crew upgrade --bogus` took the flag as a BOX NAME, printing
# "upgrade FAILED on --bogus" and exiting 0 — a report, not a verdict (kimi).
t cli-upgrade-unknown-flag-is-2  2 "$(crewrc upgrade --bogus)"

# The mirror of the missing-value case: an argument BEYOND the synopsis was
# silently ignored. `crew help hire unexpected` printed hire's help and exited
# 0 (codex, round 2). The verbs with while-loop parsers already refused these;
# the ones reading "${1:-}" positionally never looked.
overrun=""
for spec in "help hire junk" "status a b" "profiles junk" "down junk" \
            "create-all junk" "gold a b c"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || overrun="$overrun [$spec->$rc]"
done
t cli-excess-arguments-are-2 "" "$overrun"
# ...and the accepted forms still work, so the guard cannot over-reach.
t cli-help-one-arg-still-ok  0 "$(crewrc help hire)"
t cli-help-no-arg-still-ok   0 "$(crewrc help)"

# resolve_engine's ref failures split the same way (codex, round 3). Three are
# invocation faults — a shape that can never be valid, a ref resolving to
# nothing, a ref in the wrong form for the mode — and exit 2. Shared by
# `hire --ref`, `hire-all --ref` and `upgrade --ref`, so assert it on each.
badref=""
for spec in "upgrade --all --ref -bad" "hire somebox --ref -bad" "hire-all --ref -bad" \
            "upgrade --all --ref nosuchref-xyz"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || badref="$badref [$spec->$rc]"
done
t cli-malformed-ref-is-2 "" "$badref"

# A typo points somewhere rather than only failing.
case "$(crewcli hier 2>&1)" in *"did you mean 'hire'"*) r1=suggested ;; *) r1=SILENT ;; esac
t cli-typo-suggests suggested "$r1"

# --version names the version AND the root: with two installs on PATH, the
# root is how you settle which crew you just ran.
ver_out="$(crewcli --version 2>&1)"
case "$ver_out" in "crew $(head -1 "$ROOT/VERSION" | tr -d '\r\n') ("*")") r1=named ;; *) r1="$ver_out" ;; esac
t cli-version-names-version-and-root named "$r1"

# `adopt` is retired but must not break a caller — and must not be advertised.
case "$(crewcli adopt 2>&1)" in *"'adopt' is now 'hire'"*) r1=warned ;; *) r1=SILENT ;; esac
t cli-adopt-alias-warns warned "$r1"
case "$help_all" in *adopt*) r1=ADVERTISED ;; *) r1=hidden ;; esac
t cli-adopt-not-in-help hidden "$r1"

# The header comment is no longer a second command list. It used to BE the
# help output, and it drifted; a reader who re-adds a verb table there
# re-creates the defect #97 closed.
# The shape being forbidden is a LISTING — an indented comment line that
# begins with `crew <verb>`, which is exactly how the old table was written
# and how it drifted. Prose that quotes a command mid-sentence is fine and is
# not what re-creates the defect; matching on that would forbid explaining it.
relisted="$(sed -n '2,/^set -euo pipefail/p' "$CLIBIN" | grep -cE '^#[[:space:]]+crew [a-z-]+' || true)"
t cli-header-is-not-a-command-list 0 "$relisted"

# --- the examples fallback creates and arms NOTHING (#216) ------------------
# A host with no operator config at all resolves to $CREW_ROOT/examples and,
# before this, presented as a fully configured seven-box fleet: `crew up`
# there created seven boxes and armed cron against the three live
# repositories the shipped registry then named. The fallback itself stays —
# it is deliberate and the config rehearsal covers it. What it loses is the
# ability to create or arm.
#
# The fixture must reproduce the REPORTED environment exactly, because every
# other test in this file arrives here through a configured path: HOME with no
# .config/crew, XDG unset, CREW_CONFIG_DIR unset, and a $PWD carrying no
# fleet.roster. Get any one of those wrong and resolution lands on an operator
# directory, CONFIG_IS_OPERATOR is 1, and the whole block asserts nothing.
FBHOME="$TMP/fallback-home"
FBPWD="$TMP/fallback-pwd"
mkdir -p "$FBHOME" "$FBPWD"
fbcrew() {  # stdout+stderr, from the unconfigured host
  (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" 2>&1)
}
fbrc() {
  (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" >/dev/null 2>&1)
  echo $?
}

# The fixture proves itself first: if this says operator, every assertion
# below is vacuous.
case "$(fbcrew status)" in
  *"NO operator fleet definition"*) r1=fallback ;;
  *) r1=OPERATOR ;;
esac
t cli-fallback-fixture-is-really-the-fallback fallback "$r1"

# Every mutating verb refuses, and every one of them names `crew init` — the
# refusal is only useful if it says what to do instead. Asserted per verb
# rather than on a sample: the defect was per-call-site and so is the fix.
#
# `floor` refuses too (#244) and is deliberately NOT in this list: fbrc runs
# each spec in the FOREGROUND with no timeout, so a regressed floor refusal
# would serve until the CI job's own limit rather than fail here. Its cases
# live in fleet-floor/test/cli.sh, which owns the verb, caps every process it
# starts and watches the port. Add it here and this suite hangs on the day the
# assertion matters.
refused="" unnamed=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  [ "$(fbrc $spec)" != 0 ] || refused="$refused [$spec]"
  # shellcheck disable=SC2086
  case "$(fbcrew $spec)" in *"crew init"*) : ;; *) unnamed="$unnamed [$spec]" ;; esac
done <<'SPECS'
new claude-triage
create-all
hire claude-triage
hire-all
up
down
upgrade --all
gold somebox
SPECS
t cli-fallback-mutating-verbs-refuse "" "$refused"
t cli-fallback-refusal-names-crew-init "" "$unnamed"

# ...and the read-only verbs still WORK, because inspecting a host in this
# state is exactly what they are for. A fix that made `crew status` refuse
# would take away the one instrument that explains the refusals.
t cli-fallback-status-still-works   0 "$(fbrc status)"
t cli-fallback-profiles-still-works 0 "$(fbrc profiles)"
t cli-fallback-dry-run-still-works  0 "$(fbrc up --dry-run)"

# Each of them says what it is reading. The reported symptom was a table
# nobody could tell apart from a configured fleet's, so the banner is the
# fix's user-visible half and is asserted by content, not by presence.
bannerless=""
for verb in status profiles; do
  case "$(fbcrew "$verb")" in
    *"NO operator fleet definition"*"$ROOT/examples"*) : ;;
    *) bannerless="$bannerless [$verb]" ;;
  esac
done
case "$(fbcrew up --dry-run)" in
  *"NO operator fleet definition"*"$ROOT/examples"*) : ;;
  *) bannerless="$bannerless [up --dry-run]" ;;
esac
t cli-fallback-read-only-verbs-banner "" "$bannerless"

# The banner is on stderr, so the tables stay machine-readable: a row-parsing
# caller must not have to filter it back out. This is the assertion that keeps
# a later "make it more visible" edit from breaking every such caller silently.
fb_stdout="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" status 2>/dev/null) )"
case "$fb_stdout" in
  *"NO operator fleet definition"*) r1=ON_STDOUT ;;
  *MEMBER*) r1=rows-only ;;
  *) r1="$fb_stdout" ;;
esac
t cli-fallback-banner-is-on-stderr rows-only "$r1"

# THE REGRESSION THAT MATTERS MORE THAN THE BUG: a real fleet must behave
# exactly as before. A fix that makes configured hosts refuse is a fleet
# outage; the bug it replaces is one confusing table.
OPCONF="$TMP/op-config"
mkdir -p "$OPCONF"
cp "$ROOT/examples/fleet.roster" "$ROOT/examples/fleet.conf" "$OPCONF/"
printf '# an operator registry\nfixture/operator-repo\n' >"$OPCONF/repos.txt"
printf '# an operator notify registry\nfixture/operator-repo\n' >"$OPCONF/notify-repos.txt"
opcrew() {
  (cd "$FBPWD" && env -u XDG_CONFIG_HOME -u CREW_ROSTER CREW_CONFIG_DIR="$OPCONF" \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" 2>&1)
}
overreach=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  case "$(opcrew $spec)" in
    *"refuses under the shipped example"*|*"NO operator fleet definition"*)
      overreach="$overreach [$spec]" ;;
  esac
done <<'SPECS'
status
profiles
up --dry-run
new claude-triage
create-all
hire claude-triage
hire-all
up
down
upgrade --all
gold somebox
SPECS
t cli-operator-config-never-refused-or-bannered "" "$overreach"

# $PWD discovery is an operator definition too — the third resolution hop, and
# the one a developer running crew from a config directory relies on. Banner
# it and this fix breaks that workflow.
pwdcrew_out="$(cd "$OPCONF" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" status 2>&1)"
case "$pwdcrew_out" in
  *"NO operator fleet definition"*) r1=BANNERED ;;
  *) r1=clean ;;
esac
t cli-pwd-discovery-is-operator clean "$r1"

# The shipped registry ships EMPTY. Asserted by parsing rather than by diffing
# a literal, so a future edit that re-adds a live repository reds this instead
# of shipping a scaffold aimed at somebody else's board.
t cli-examples-registry-is-empty 0 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$ROOT/examples/repos.txt" || true)"

# ...and the same must be true one hop later, of what an operator actually
# gets: `crew init` seeds from examples/, so a fresh fleet definition starts
# aimed at nothing and stays that way until the operator names a repo.
INIT_TARGET="$TMP/init-seeded"
init_rc="$(fbrc init "$INIT_TARGET")"
t cli-init-still-works-under-fallback 0 "$init_rc"
t cli-init-seeds-an-empty-registry 0 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$INIT_TARGET/repos.txt" 2>/dev/null || true)"

# Validation parity: the completeness check ran only for operator definitions,
# so the LEAST trusted directory got the LEAST verification. Both directions
# are asserted, because the property is that the check does not care who wrote
# the directory.
FBROOT="$TMP/fallback-root"
mkdir -p "$FBROOT/cli"
cp "$CLIBIN" "$FBROOT/cli/crew"
cp "$ROOT/VERSION" "$FBROOT/VERSION"
ln -s "$SHARED" "$FBROOT/shared"
cp -R "$ROOT/examples" "$FBROOT/examples"
rm -f "$FBROOT/examples/repos.txt"
fb_incomplete="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$FBROOT/cli/crew" status 2>&1) )"
case "$fb_incomplete" in
  *"is incomplete; missing: repos.txt"*) r1=refused ;;
  *) r1="$fb_incomplete" ;;
esac
t cli-fallback-incompleteness-is-fatal refused "$r1"

# fleet.conf is named by the same criterion, so it is asserted by the same
# route rather than assumed to follow from repos.txt.
FBROOT2="$TMP/fallback-root-noconf"
mkdir -p "$FBROOT2/cli"
cp "$CLIBIN" "$FBROOT2/cli/crew"
cp "$ROOT/VERSION" "$FBROOT2/VERSION"
ln -s "$SHARED" "$FBROOT2/shared"
cp -R "$ROOT/examples" "$FBROOT2/examples"
rm -f "$FBROOT2/examples/fleet.conf"
fb_noconf="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$FBROOT2/cli/crew" status 2>&1) )"
case "$fb_noconf" in
  *"is incomplete; missing: fleet.conf"*) r1=refused ;;
  *) r1="$fb_noconf" ;;
esac
t cli-fallback-missing-fleet-conf-is-fatal refused "$r1"

OPINCOMPLETE="$TMP/op-incomplete"
mkdir -p "$OPINCOMPLETE"
cp "$ROOT/examples/fleet.roster" "$ROOT/examples/fleet.conf" "$OPINCOMPLETE/"
op_incomplete="$( (cd "$FBPWD" && env -u XDG_CONFIG_HOME -u CREW_ROSTER \
  CREW_CONFIG_DIR="$OPINCOMPLETE" HOME="$FBHOME" PATH="$CLISHIM:$PATH" \
  bash "$CLIBIN" status 2>&1) )"
case "$op_incomplete" in
  *"is incomplete; missing: repos.txt"*) r1=refused ;;
  *) r1="$op_incomplete" ;;
esac
t cli-operator-incompleteness-is-fatal refused "$r1"

# --- CI split: route the browser walk without dropping coverage (#138) -----
# Repo furniture, in the same family as valid_version-parity above: assertions
# about a file the engine never executes, kept here because the property is
# anti-drift and every way of losing it is silent.
CI_SHELL="$ROOT/.github/workflows/ci-shell.yml"
CI_FLOOR="$ROOT/.github/workflows/ci-floor.yml"

ci_paths() {
  trigger="$1"
  workflow="$2"
  awk -v trigger="$trigger" '
    $0 == "  " trigger ":" { in_trigger = 1; next }
    in_trigger && /^  [[:alnum:]_-]+:/ { exit }
    in_trigger && /^    paths: \[/ {
      sub(/^    paths: \[/, "")
      sub(/\]$/, "")
      print
    }
  ' "$workflow" \
    | tr ',' '\n' | tr -d " '\"" | sed '/^$/d' | sort -u
}

# The old filter's product paths survive across the union. Its deleted
# self-path is replaced by both new workflows' paths. ci-floor.yml also routes
# to ci-shell so edits to that workflow run the assertions below; it is the one
# intentional overlap. Explicitly naming .ceremony/** prevents two
# mutually-agreeing filters from dropping the path that caught #363.
CI_EXPECTED="$(printf '%s\n' \
  '.ceremony/**' '.github/workflows/ci-floor.yml' '.github/workflows/ci-shell.yml' \
  'cli/**' 'dist/**' 'drill/**' 'examples/**' 'fleet-floor/**' 'install.sh' 'shared/**' | sort)"
CI_SHELL_PR_PATHS="$(ci_paths pull_request "$CI_SHELL")"
CI_FLOOR_PR_PATHS="$(ci_paths pull_request "$CI_FLOOR")"
CI_UNION="$(printf '%s\n%s\n' "$CI_SHELL_PR_PATHS" "$CI_FLOOR_PR_PATHS")"
t ci-path-union-preserves-coverage "$CI_EXPECTED" "$(printf '%s\n' "$CI_UNION" | sort -u)"
CI_OVERLAP="$(comm -12 <(printf '%s\n' "$CI_SHELL_PR_PATHS") <(printf '%s\n' "$CI_FLOOR_PR_PATHS"))"
t ci-path-overlap-is-only-floor-self-edit '.github/workflows/ci-floor.yml' "$CI_OVERLAP"
case "$CI_SHELL_PR_PATHS" in *'.ceremony/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-shell-keeps-ceremony-fixtures present "$r1"
case "$CI_SHELL_PR_PATHS" in *'.github/workflows/ci-floor.yml'*) r1=present ;; *) r1=MISSING ;; esac
t ci-floor-self-edit-routes-to-shell present "$r1"

# The three routing cases, plus the load-bearing CLI coverage on the cheap
# side. Native paths do the routing; a billed filter job is forbidden.
ci_shell_paths="$CI_SHELL_PR_PATHS"
case "$ci_shell_paths" in *'shared/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-shared-routes-to-shell present "$r1"
case "$ci_shell_paths" in *'cli/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-cli-routes-to-shell present "$r1"
case "$CI_FLOOR_PR_PATHS" in *'fleet-floor/**'*) r1=floor ;; *) r1=MISSING ;; esac
t ci-fleet-floor-routes-to-floor floor "$r1"
if grep -q 'fleet-floor/test/run.sh --no-browser' "$CI_SHELL"; then r1=covered; else r1=DROPPED; fi
t ci-shell-runs-floor-cli-fixtures covered "$r1"
if grep -Eq 'paths-filter|filter-changes|changes:' "$CI_SHELL" "$CI_FLOOR"; then r1=BILLED; else r1=native; fi
t ci-routing-uses-native-paths native "$r1"

# Both workflows inherit the draft wake/gate, per-ref cancellation and the
# push-to-main post-merge run. A missing half is a checkless current head.
for ci_yml in "$CI_SHELL" "$CI_FLOOR"; do
  ci_name="$(sed -n 's/^name: //p' "$ci_yml")"
  ci_types=",$(sed -n 's/^ *types: *\[\(.*\)\].*$/\1/p' "$ci_yml" | tr -d ' '),"
  for ev in opened synchronize reopened ready_for_review; do
    case "$ci_types" in *",$ev,"*) r1=present ;; *) r1=MISSING ;; esac
    t "$ci_name-trigger-fires-on[$ev]" present "$r1"
  done
  ci_if="$(awk '/^  check:/{p=1} p && /^    if:/{print; exit}' "$ci_yml")"
  case "$ci_if" in *github.event.pull_request.draft*) r1=payload ;; *) r1=MISSING ;; esac
  t "$ci_name-gates-on-draft-payload" payload "$r1"
  case "$ci_if" in *state:*|*label*) r1=LABEL ;; *) r1=payload-only ;; esac
  t "$ci_name-gate-is-not-label" payload-only "$r1"
  case "$ci_if" in *github.event_name*) r1=explicit ;; *) r1=COERCION ;; esac
  t "$ci_name-push-exemption-is-explicit" explicit "$r1"
  t "$ci_name-pushes-run-on-main" 1 "$(grep -c '^    branches: \[main\]$' "$ci_yml")"
  t "$ci_name-push-preserves-union-filter" "$CI_EXPECTED" "$(ci_paths push "$ci_yml")"
  ci_group="$(sed -n 's/^  group: *//p' "$ci_yml")"
  # shellcheck disable=SC2016  # Match the literal GitHub expression in YAML.
  case "$ci_group" in *'${{ github.ref }}'*) r1=per-ref ;; *) r1=TOO-COARSE ;; esac
  t "$ci_name-concurrency-is-per-ref" per-ref "$r1"
  t "$ci_name-cancels-superseded-runs" 1 "$(grep -c '^  cancel-in-progress: true$' "$ci_yml")"
done

# Every old step is routed. The expensive browser invocation exists only on
# the floor side; the cheap side still executes the headless floor/CLI suite.
t ci-check-names-are-distinct 2 \
  "$(sed -n 's/^    name: \(ci-.*\)$/\1/p' "$CI_SHELL" "$CI_FLOOR" | sort -u | wc -l | tr -d ' ')"
for command in 'shared/test/run.sh' 'shared/test/install-lifecycle.sh' \
  'shared/test/artifact.sh' 'shared/test/install-drill.sh'; do
  t "ci-shell-keeps[$command]" 1 "$(grep -Fc "run: $command" "$CI_SHELL")"
done
t ci-floor-keeps-python-syntax 1 "$(grep -Fc 'python3 -m py_compile fleet-floor/server/floor.py' "$CI_FLOOR")"
t ci-floor-keeps-browser-gate 1 "$(grep -Fc 'FLOOR_TEST_REQUIRE_BROWSER=1 fleet-floor/test/run.sh' "$CI_FLOOR")"
t ci-floor-keeps-built-page-check 1 "$(grep -Fc 'git diff --exit-code -- fleet-floor/index.html' "$CI_FLOOR")"
# shellcheck disable=SC2016  # Match the literal loop variable in workflow YAML.
t ci-floor-keeps-bash-syntax 1 "$(grep -Fc 'bash -n "$f"' "$CI_FLOOR")"
t ci-floor-keeps-shellcheck 1 "$(grep -c '^      - name: shellcheck (floor)$' "$CI_FLOOR")"

# The cheap cross-layer contracts that make a browser skip safe (#138 edges 1
# and 6). cmd_floor must keep the server/build/env bridge, and every operator
# command the console names must remain in the CLI's dispatch table.
CI_CREW="$ROOT/cli/crew"
CI_FLOOR_FN="$(sed -n '/^cmd_floor()/,/^}/p' "$CI_CREW")"
case "$CI_FLOOR_FN" in *'fleet-floor/index.html'*'CREW_FLOOR_PORT='*'CREW_FLOOR_BIND='*'CREW_FLOOR_USER='*'CREW_FLOOR_PASS='*'CREW_FLOOR_INTERVAL='*'CREW_FLOOR_ROSTER='*'fleet-floor/server/floor.py'*) r1=bridged ;; *) r1=BROKEN ;; esac
t cli-floor-server-contract bridged "$r1"
CI_CONSOLE_VERBS='down floor hire init new profiles status up upgrade'
CI_CONSOLE_PROSE_VERBS='and cut hangs makes on reads stopped would'
CI_CONSOLE_CANDIDATES="$(grep -ohE 'crew [a-z][a-z-]*' \
  "$ROOT/fleet-floor/server/floor.py" "$ROOT/fleet-floor/src/app.js" \
  | sed 's/^crew //' | sort -u \
  | grep -Ev "^($(printf '%s' "$CI_CONSOLE_PROSE_VERBS" | tr ' ' '|'))$")"
t floor-named-crew-verb-roster-is-complete "$CI_CONSOLE_VERBS" \
  "$(printf '%s\n' "$CI_CONSOLE_CANDIDATES" | paste -sd ' ' -)"
CI_COMMAND_ROWS="$(sed -n '/^CMDS=(/,/^)/p' "$CI_CREW")"
for verb in $CI_CONSOLE_VERBS; do
  if grep -q "crew $verb" "$ROOT/fleet-floor/server/floor.py" "$ROOT/fleet-floor/src/app.js" &&
     grep -q "^  \"$verb\\^" <<<"$CI_COMMAND_ROWS"; then
    r1=dispatchable
  else
    r1=MISSING
  fi
  t "floor-named-crew-verb-dispatches[$verb]" dispatchable "$r1"
done

# --- #159: the stamp is a claim, the manifest is the evidence ---------------
# ~/duty/VERSION said what was SHIPPED and nothing ever looked at what was
# THERE, so a hand-edited engine reported as in-sync and the next upgrade
# deleted the edit in silence. Three surfaces, asserted in order: the
# instrument, the installer that records and refuses, and the status the
# operator reads.

# --- the instrument, against a scratch tree -------------------------------
EM="$SHARED/bin/engine-manifest.sh"
EMDUTY="$TMP/manifest-duty"
mkdir -p "$EMDUTY/bin" "$EMDUTY/lib/jq" "$EMDUTY/prompts" "$EMDUTY/conf/roles" "$EMDUTY/conf/agents"
printf 'echo duty\n'    >"$EMDUTY/bin/duty.sh"
printf 'common\n'       >"$EMDUTY/lib/common.sh"
printf '.a\n'           >"$EMDUTY/lib/jq/x.jq"
printf 'prompt\n'       >"$EMDUTY/prompts/p.txt"
printf 'role\n'         >"$EMDUTY/conf/roles/reviewer.conf"
printf 'agent\n'        >"$EMDUTY/conf/agents/claude.conf"
printf 'defaults\n'     >"$EMDUTY/conf/fleet.defaults.conf"
printf 'crew@9.9.9 (deadbee)\ninstalled 2026-07-29T00:00:00Z\n' >"$EMDUTY/VERSION"
em() { env DUTY_DIR="$EMDUTY" bash "$EM" "$@"; }
em_field() { em --report | sed -n "s/^$1=//p" | head -1; }

# A box with an engine and no record is UNVERIFIED, never modified: on the day
# this ships every box in the fleet is in exactly this state, and a fleet-wide
# false alarm is how an instrument gets ignored forever.
t manifest-no-record-is-unverified unverified "$(em_field state)"
t manifest-no-record-has-no-recorded-version "" "$(em_field recorded)"
em --record
t manifest-after-record-is-current current "$(em_field state)"
t manifest-records-the-stamp "crew@9.9.9 (deadbee)" "$(em_field recorded)"

# MUST FAIL: a hash over names and mtimes. touch moves every mtime and no
# content, and a same-size edit moves content and no size.
touch "$EMDUTY/bin/duty.sh" "$EMDUTY/lib/common.sh"
t manifest-touch-is-not-modification current "$(em_field state)"
printf 'echo DUTY\n' >"$EMDUTY/bin/duty.sh"   # same byte count, different bytes
t manifest-same-size-edit-is-modified modified "$(em_field state)"
t manifest-edit-names-the-path "path=modified bin/duty.sh" \
  "$(em --report --paths | grep '^path=')"
t manifest-modified-still-names-its-version "crew@9.9.9 (deadbee)" "$(em_field recorded)"

# Re-shipping identical bytes converges: the same content hashes the same, so a
# converging re-run stays converging and still says so.
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"
t manifest-identical-bytes-converge current "$(em_field state)"

# An added file and a deleted one are somebody's hand on the box too, and the
# hashes alone cannot tell them apart from each other — the names must be in
# the manifest, which is why it is a listing and not one digest.
printf 'hotfix\n' >"$EMDUTY/bin/hotfix.sh"
t manifest-added-file-is-detected modified "$(em_field state)"
t manifest-added-file-is-named "path=added bin/hotfix.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin/hotfix.sh" "$EMDUTY/lib/jq/x.jq"
t manifest-deleted-file-is-named "path=removed lib/jq/x.jq" "$(em --report --paths | grep '^path=')"
printf '.a\n' >"$EMDUTY/lib/jq/x.jq"

# MUST FAIL: enumerating `-type f`. find does not follow symlinks, so a symlink
# is neither `f` nor `d` and a -type f walk goes straight past it — one
# `ln -s /anything ~/duty/bin/hotfix.sh` was an executable path the record
# never named and every upgrade certified clean.
ln -s /bin/sh "$EMDUTY/bin/hotfix.sh"
t manifest-added-symlink-is-detected modified "$(em_field state)"
t manifest-added-symlink-is-named "path=added bin/hotfix.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin/hotfix.sh"
t manifest-after-symlink-removed-is-current current "$(em_field state)"

# A symlink is hashed by what it IS, never by what it points at. sha256sum on a
# link silently hashes the referent, so a shipped file replaced by a link to a
# byte-identical copy elsewhere would read `current` while the engine executes
# a file the record never measured.
cp "$EMDUTY/bin/duty.sh" "$TMP/manifest-duty-elsewhere.sh"
rm -f "$EMDUTY/bin/duty.sh"
ln -s "$TMP/manifest-duty-elsewhere.sh" "$EMDUTY/bin/duty.sh"
t manifest-file-swapped-for-link-is-modified modified "$(em_field state)"
t manifest-file-swapped-for-link-is-named "path=modified bin/duty.sh" \
  "$(em --report --paths | grep '^path=')"

# ...and the same link DANGLING must still be a verdict, not a crash: sha256sum
# on a broken link fails, and under `pipefail` that would take state() down with
# it — the instrument going silent on the one box that needs it.
rm -f "$EMDUTY/bin/duty.sh"
ln -s "$TMP/no-such-file-anywhere" "$EMDUTY/bin/duty.sh"
if em --state >/dev/null 2>&1; then r1=0; else r1=$?; fi
t manifest-dangling-link-does-not-crash 0 "$r1"
t manifest-dangling-link-is-modified modified "$(em_field state)"
rm -f "$EMDUTY/bin/duty.sh"
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"

# Nor is a symlink the only entry a -type f walk misses; the rule that survives
# review is the simple one — under an engine root, anything that is not a
# directory is engine surface.
mkfifo "$EMDUTY/lib/pipe"
t manifest-added-fifo-is-detected modified "$(em_field state)"
t manifest-added-fifo-is-named "path=added lib/pipe" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/lib/pipe"

# An engine ROOT replaced by a symlink is the same hole one level up: the link
# must be named AND the tree behind it still measured, or an operator redirects
# bin/ and every file the engine runs goes unread.
mkdir -p "$TMP/manifest-elsewhere-bin"
mv "$EMDUTY/bin/duty.sh" "$TMP/manifest-elsewhere-bin/duty.sh"
rmdir "$EMDUTY/bin"
ln -s "$TMP/manifest-elsewhere-bin" "$EMDUTY/bin"
t manifest-redirected-root-is-named "path=added bin" "$(em --report --paths | grep '^path=')"
printf 'echo TAMPERED\n' >"$TMP/manifest-elsewhere-bin/duty.sh"
t manifest-redirected-root-still-measures-content \
  "path=added bin
path=modified bin/duty.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin"
mkdir -p "$EMDUTY/bin"
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"
t manifest-after-root-restored-is-current current "$(em_field state)"

# Every root install.sh writes into is covered — a gap here is a file an
# operator can edit invisibly, and the list is easy to under-fill by hand.
for f in bin/duty.sh lib/common.sh lib/jq/x.jq prompts/p.txt \
         conf/roles/reviewer.conf conf/agents/claude.conf conf/fleet.defaults.conf; do
  printf 'tampered\n' >>"$EMDUTY/$f"
  t "manifest-covers[$f]" modified "$(em_field state)"
  case "$f" in
    bin/duty.sh)              printf 'echo duty\n' >"$EMDUTY/$f" ;;
    lib/common.sh)            printf 'common\n'    >"$EMDUTY/$f" ;;
    lib/jq/x.jq)              printf '.a\n'        >"$EMDUTY/$f" ;;
    prompts/p.txt)            printf 'prompt\n'    >"$EMDUTY/$f" ;;
    conf/roles/reviewer.conf) printf 'role\n'      >"$EMDUTY/$f" ;;
    conf/agents/claude.conf)  printf 'agent\n'     >"$EMDUTY/$f" ;;
    *)                        printf 'defaults\n'  >"$EMDUTY/$f" ;;
  esac
done
t manifest-restored-tree-is-current current "$(em_field state)"

# Per-box state and configuration are OUT of the manifest, each for its own
# reason: duty.log and the work trees change on every tick; instance.conf is
# machine-derived and the drill itself appends to it (rehearsal.sh's
# AUTO_APPROVE_REREQUEST fixture); fleet.conf is transported on every install;
# the registries carry their own divergence provenance in apply_registry.
# Any of these inside the manifest reports a healthy fleet as modified.
mkdir -p "$EMDUTY/work" "$EMDUTY/trees" "$EMDUTY/logs"
printf 'tick\n'                     >"$EMDUTY/duty.log"
printf 'AUTO_APPROVE_REREQUEST=0\n' >"$EMDUTY/conf/instance.conf"
printf 'FLEET_BENCH="x"\n'          >"$EMDUTY/conf/fleet.conf"
printf 'owner/repo\n'               >"$EMDUTY/repos.txt"
printf 'scratch\n'                  >"$EMDUTY/work/session.json"
t manifest-ignores-per-box-state current "$(em_field state)"

# A record this shape cannot read is unverified, not modified: the algorithm
# ships WITH the engine, so a record from another format version must never
# read as somebody's edit.
cp "$EMDUTY/.engine-manifest" "$TMP/manifest-v1-backup"
sed -i '1s/.*/# crew-engine-manifest v99 crew@9.9.9/' "$EMDUTY/.engine-manifest"
t manifest-foreign-format-is-unverified unverified "$(em_field state)"
cp "$TMP/manifest-v1-backup" "$EMDUTY/.engine-manifest"

# No engine at all is `absent`, which is not a fault to report — it is `crew
# hire`, and the status table already says so.
mv "$EMDUTY/VERSION" "$TMP/manifest-version-backup"
t manifest-no-engine-is-absent absent "$(em_field state)"
mv "$TMP/manifest-version-backup" "$EMDUTY/VERSION"

# --- the installer: records, then refuses ---------------------------------
# Real installs into a scratch DUTY_DIR, through the same curated PATH the
# other installer fixtures use.
MHOME="$TMP/manifest-install-home"
MDUTY="$MHOME/duty"
mkdir -p "$MHOME"
minstall() {
  env HOME="$MHOME" DUTY_DIR="$MDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" --agent claude --role reviewer "$@"
}
mstate() { env DUTY_DIR="$MDUTY" bash "$EM" --state; }
minstall >/dev/null 2>&1
t install-records-a-manifest current "$(mstate)"
t install-manifest-names-the-version "crew@$(head -1 "$ROOT/VERSION") (fixture-sha)" \
  "$(env DUTY_DIR="$MDUTY" bash "$EM" --report | sed -n 's/^recorded=//p')"

# The converging re-run: identical bytes, so the box is still current and the
# installer does not refuse itself.
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-reship-identical-rc 0 "$r1"
t install-reship-identical-stays-current current "$(mstate)"

# The half of this issue that loses work: a modified tree is REFUSED, and
# nothing is written.
printf '# hotfix by hand\n' >>"$MDUTY/bin/duty.sh"
hotfix_before="$(cat "$MDUTY/bin/duty.sh")"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-modified-rc 1 "$r1"
case "$refuse_out" in *"REFUSING to overwrite a MODIFIED engine"*) r1=refused ;; *) r1=SILENT ;; esac
t install-refusal-is-loud refused "$r1"
case "$refuse_out" in *"modified bin/duty.sh"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-path named "$r1"
case "$refuse_out" in *"crew@$(head -1 "$ROOT/VERSION")"*) r1=versioned ;; *) r1=BARE ;; esac
t install-refusal-names-the-version versioned "$r1"
t install-refusal-changes-nothing "$hotfix_before" "$(cat "$MDUTY/bin/duty.sh")"

# --force is the whole escape hatch, and it must actually proceed.
if minstall --force >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-force-proceeds-rc 0 "$r1"
case "$(cat "$MDUTY/bin/duty.sh")" in *"hotfix by hand"*) r1=SURVIVED ;; *) r1=overwritten ;; esac
t install-force-overwrites overwritten "$r1"
t install-force-re-records-current current "$(mstate)"

# The other half of --force, and the reason it is an escape hatch rather than a
# laundering step: a file the incoming tree does not ship must not RIDE THROUGH
# it. Copying over matching names converges every file the tree has and says
# nothing about one it does not, so before this an added ~/duty/bin/hotfix.sh
# was refused, then survived --force, then got hashed into the new record — the
# box read `current` with unshipped executable code in it, certified by the
# instrument built to catch exactly that.
printf '#!/bin/sh\necho hotfix\n' >"$MDUTY/bin/hotfix.sh"
chmod +x "$MDUTY/bin/hotfix.sh"
added_before="$(cat "$MDUTY/bin/hotfix.sh")"
t install-added-file-reads-modified modified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-refuses-added-file 1 "$r1"
if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-added-file-rc 0 "$r1"
if [ -e "$MDUTY/bin/hotfix.sh" ]; then r1=SURVIVED; else r1=gone; fi
t install-force-removes-the-added-file gone "$r1"
# Moved, not deleted: the hotfix nobody told the fleet about is evidence.
t install-force-parks-it-in-legacy "$added_before" "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$force_out" in
  *"moved unshipped engine file to legacy/: bin/hotfix.sh"*) r1=named ;;
  *) r1=SILENT ;;
esac
t install-force-names-what-it-moved named "$r1"
case "$(cat "$MDUTY/.engine-manifest")" in *hotfix*) r1=BLESSED ;; *) r1=absent ;; esac
t install-force-does-not-record-the-added-file absent "$r1"
t install-force-over-added-file-is-current current "$(mstate)"
# ...and the engine that was installed around it is intact.
if [ -x "$MDUTY/bin/duty.sh" ]; then r1=installed; else r1=MISSING; fi
t install-force-sweep-leaves-the-engine installed "$r1"

# The sweep enumerates the same surface the manifest does, or the hole above
# reopens in the installer: `find -type f` walks past a symlink, so an added
# LINK was refused, survived --force, and was then recorded as shipped. This
# also lands on the plain legacy/ name the added FILE above already took, so it
# is the collision case too: the first park must survive, because parking
# instead of deleting is an evidence argument and evidence the next run
# silently replaces is not evidence.
ln -s /bin/sh "$MDUTY/bin/hotfix.sh"
t install-added-symlink-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-added-symlink 1 "$r1"
case "$refuse_out" in *"added bin/hotfix.sh"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-symlink named "$r1"
if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-added-symlink-rc 0 "$r1"
if [ -e "$MDUTY/bin/hotfix.sh" ] || [ -L "$MDUTY/bin/hotfix.sh" ]; then r1=SURVIVED; else r1=gone; fi
t install-force-removes-the-added-symlink gone "$r1"
case "$(cat "$MDUTY/.engine-manifest")" in *hotfix*) r1=BLESSED ;; *) r1=absent ;; esac
t install-force-does-not-record-the-added-symlink absent "$r1"
t install-force-over-added-symlink-is-current current "$(mstate)"
# Parked as the link it was — not as a copy of whatever it pointed at.
parked_link=""
for p in "$MDUTY"/legacy/bin/hotfix.sh.*; do
  [ -e "$p" ] || [ -L "$p" ] || continue
  parked_link="${p##*/}"; break
done
if [ -L "$MDUTY/legacy/bin/$parked_link" ]; then r1='link'; else r1=NOT-A-LINK; fi
t install-force-parks-the-symlink-as-a-link link "$r1"
t install-force-parks-the-symlink-target /bin/sh \
  "$(readlink "$MDUTY/legacy/bin/$parked_link" 2>/dev/null)"
t install-second-park-keeps-the-first "$added_before" \
  "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$force_out" in *"kept as bin/$parked_link"*) r1=named ;; *) r1=SILENT ;; esac
t install-collided-park-names-where-it-went named "$r1"

# The same hole one component UP, and the reason the sweep alone cannot close
# it: the sweep descends a symlinked root but never sweeps the root entry, so an
# operator's `ln -s elsewhere ~/duty/bin` was detected, refused — and then
# survived --force, was written into the record, and the box read `current` with
# its engine executing out of a directory this version never shipped. Detection
# already names the redirect, so blessing it is worse than never having looked.
REDIR="$TMP/manifest-redirect-target"
mkdir -p "$REDIR"
mv "$MDUTY/bin" "$REDIR/bin"
ln -s "$REDIR/bin" "$MDUTY/bin"
t install-redirected-root-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-redirected-root 1 "$r1"
case "$refuse_out" in *"added bin"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-redirected-root named "$r1"
# ...and the refusal changed nothing: the redirect is still exactly as it was.
if [ -L "$MDUTY/bin" ]; then r1=intact; else r1=DISTURBED; fi
t install-refusal-leaves-the-redirect-alone intact "$r1"

if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-redirected-root-rc 0 "$r1"
# The convergence: a real directory where the link was, not a link crew ships.
if [ -d "$MDUTY/bin" ] && [ ! -L "$MDUTY/bin" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-redirect-with-a-real-dir real "$r1"
# Moved, not deleted — and parked as a LINK, so the target it pointed at is the
# evidence, sitting outside the engine surface.
redir_park=""
for p in "$MDUTY"/legacy/bin "$MDUTY"/legacy/bin.*; do
  if [ -L "$p" ]; then redir_park="$p"; break; fi
done
if [ -n "$redir_park" ]; then r1='link'; else r1=NOT-PARKED-AS-LINK; fi
t install-force-parks-the-redirect-as-a-link link "$r1"
t install-force-parks-the-redirect-target "$REDIR/bin" \
  "$(readlink "$redir_park" 2>/dev/null)"
case "$force_out" in
  *"replaced redirected engine directory with a real one: bin"*) r1=named ;;
  *) r1=SILENT ;;
esac
t install-force-names-the-redirect-it-replaced named "$r1"
# The record must not carry the redirect: `bin` as an entry is the blessing.
case "$(sed -n 's/.*  \(bin\)$/\1/p' "$MDUTY/.engine-manifest")" in
  bin) r1=BLESSED ;; *) r1=absent ;;
esac
t install-force-does-not-record-the-redirect absent "$r1"
t install-force-over-redirected-root-is-current current "$(mstate)"
if [ -x "$MDUTY/bin/duty.sh" ]; then r1=installed; else r1=MISSING; fi
t install-force-through-redirect-leaves-the-engine installed "$r1"
# The park above collided by construction: the added-file fixtures further up
# already left legacy/bin as a DIRECTORY holding hotfix.sh, so parking a link
# called `bin` had to take the timestamped name instead of replacing it. Evidence
# the next run overwrites is not evidence, and a redirect park is no exception.
t install-redirect-park-keeps-the-earlier-evidence "$added_before" \
  "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$redir_park" in
  *"/legacy/bin."*) r1=timestamped ;; *) r1=CLOBBERED-THE-DIRECTORY ;;
esac
t install-redirect-park-takes-a-free-name timestamped "$r1"

# One level FURTHER up, where it was not even detected: conf/ carries
# conf/roles, conf/agents and conf/fleet.defaults.conf without being a manifest
# root itself, so a redirect there resolved, hashed clean, and never refused —
# the whole role and agent set read from wherever an operator pointed it while
# the instrument said `current`.
#
# This is also why the contents are copied back through the link rather than the
# root simply emptied: OPERATOR_CONF falls back to the shipped example only when
# the box has no conf/fleet.conf of its own, so a normalization that dropped the
# redirect's contents would destroy a transported one.
printf 'FLEET_KEEPME=1\n' >>"$MDUTY/conf/fleet.conf"
minstall --force >/dev/null 2>&1   # re-record with the marker in place
mv "$MDUTY/conf" "$REDIR/conf"
ln -s "$REDIR/conf" "$MDUTY/conf"
t install-redirected-ancestor-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-redirected-ancestor 1 "$r1"
case "$refuse_out" in *"added conf"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-redirected-ancestor named "$r1"
minstall --force >/dev/null 2>&1
if [ -d "$MDUTY/conf" ] && [ ! -L "$MDUTY/conf" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-redirected-ancestor real "$r1"
# The per-box configuration behind the redirect came back with it.
case "$(cat "$MDUTY/conf/fleet.conf" 2>/dev/null)" in
  *FLEET_KEEPME*) r1=kept ;; *) r1=LOST ;;
esac
t install-redirect-normalization-keeps-the-operator-fleet-conf kept "$r1"
if [ -f "$MDUTY/conf/instance.conf" ]; then r1=present; else r1=MISSING; fi
t install-redirect-normalization-keeps-instance-conf present "$r1"
t install-force-over-redirected-ancestor-is-current current "$(mstate)"

# A DANGLING root redirect must not take the install down with it: there is no
# content to restore, so the right answer is an empty real directory the install
# then fills, not a crash under `set -e`.
rm -rf "$MDUTY/prompts"
ln -s "$TMP/manifest-redirect-nowhere" "$MDUTY/prompts"
t install-dangling-root-redirect-reads-modified modified "$(mstate)"
if minstall --force >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-force-over-dangling-root-redirect-rc 0 "$r1"
if [ -d "$MDUTY/prompts" ] && [ ! -L "$MDUTY/prompts" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-dangling-redirect real "$r1"
if [ -n "$(ls -A "$MDUTY/prompts" 2>/dev/null)" ]; then r1=filled; else r1=EMPTY; fi
t install-force-refills-the-dangling-redirect filled "$r1"
t install-force-over-dangling-redirect-is-current current "$(mstate)"

# A converging re-install sweeps NOTHING. Every install parking files in
# legacy/ would make the mechanism noise, and noise is how the one real one
# gets missed.
legacy_before="$(cd "$MDUTY/legacy" && find . -type f | LC_ALL=C sort)"
reship_out="$(minstall 2>&1)"
t install-clean-reship-sweeps-nothing "$legacy_before" \
  "$(cd "$MDUTY/legacy" && find . -type f | LC_ALL=C sort)"
case "$reship_out" in *"moved unshipped engine file"*) r1=NOISY ;; *) r1=quiet ;; esac
t install-clean-reship-is-quiet quiet "$r1"

# The migration: a box hired before content stamping has no record. It must
# read unverified, must NOT be refused, and one install must cure it.
rm -f "$MDUTY/.engine-manifest"
t install-pre-existing-box-is-unverified unverified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-pre-existing-box-is-not-refused 0 "$r1"
t install-pre-existing-box-is-cured current "$(mstate)"

# The obsolete half, on the box where it actually happens: an `unverified` box
# is deliberately NOT refused, so nothing else would ever notice the module it
# has been carrying since two versions ago. The install that cures it sweeps it
# — at depth, and without --force — instead of recording it as shipped.
rm -f "$MDUTY/.engine-manifest"
printf 'dead\n' >"$MDUTY/lib/jq/obsolete.jq"
t install-obsolete-file-box-is-unverified unverified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-unforced-sweep-rc 0 "$r1"
if [ -e "$MDUTY/lib/jq/obsolete.jq" ]; then r1=SURVIVED; else r1=gone; fi
t install-unforced-sweeps-the-obsolete-file gone "$r1"
t install-unforced-sweep-parks-it dead "$(cat "$MDUTY/legacy/lib/jq/obsolete.jq" 2>/dev/null)"
case "$(cat "$MDUTY/.engine-manifest")" in *obsolete*) r1=BLESSED ;; *) r1=absent ;; esac
t install-unforced-sweep-does-not-record-it absent "$r1"
t install-unforced-sweep-is-current current "$(mstate)"

# --- crew status: what the operator reads ---------------------------------
# A box is a directory here: the stub runs `box exec` bodies with HOME pointed
# into it, so the REAL engine-manifest.sh runs against a REAL installed tree
# and the column is asserted end to end rather than against a mocked verdict.
MSROOT="$TMP/status-boxes"
MSSHIM="$TMP/status-bin"
MSCONF="$TMP/status-fleet"
MSCALLS="$TMP/status-box-calls"
MSINSTALL_SCRIPTS="$TMP/status-install-scripts"
mkdir -p "$MSSHIM" "$MSCONF" "$MSROOT"
printf 'fixture-box claude reviewer\n' >"$MSCONF/fleet.roster"
printf 'FLEET_BENCH="b"\nFLEET_TRIAGE="t"\nFLEET_HUMAN="h"\n' >"$MSCONF/fleet.conf"
printf 'owner/repo\n' >"$MSCONF/repos.txt"
cat >"$MSSHIM/box" <<'EOF'
#!/usr/bin/env bash
# box list/info/exec against $MSROOT/<name>, one directory per box.
case "$1" in
  list) printf '[{"name":"fixture-box"}]\n' ;;
  info) printf '[{"status":"running"}]\n' ;;
  exec)
    name="$2"
    printf '%s\n' "$name" >>"$MSCALLS"
    shift 3                      # past: exec <name> --
    # what is left is `bash -lc <script>`. Run the script with -c rather than
    # -lc: a login shell would source this workstation's profile, and the box
    # under test is meant to be the directory and nothing else. DUTY_DIR is
    # unset because a real box has none — it resolves from HOME, which is the
    # resolution under test.
    case "$3" in *shared/install.sh*) printf '%s\n' "$3" >>"$MSINSTALL_SCRIPTS" ;; esac
    env -u DUTY_DIR HOME="$MSROOT/$name" CRON_STATE="$MSROOT/$name/crontab" bash -c "$3"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$MSSHIM/box"
ln -sf "$(command -v jq)" "$MSSHIM/jq"
# Since #189 `crew status` asks the box whether cron is armed. The shim runs
# these scripts on the HOST, so a real `crontab -l` would read whoever's
# crontab is running the suite — and on a box host that genuinely carries a
# tick.sh line the row would flip depending on the machine. Pin it. The fixture
# box is ARMED, which is the ordinary case and the one the round-trip budget
# below is about; the disarmed path is asserted separately, further down.
cat >"$MSSHIM/crontab" <<'CRONEOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l)
    [ -n "${MSCRON_EMPTY:-}" ] && exit 0
    # The paused shape as the console's PAUSE_SH actually writes it: the live
    # line commented out with the marker in front. Both counts are then
    # non-trivial — armed 0, paused 1 — which is the only shape that catches a
    # record whose fields have been shifted onto a second line.
    if [ -n "${MSCRON_PAUSED:-}" ]; then
      printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n'
    elif [ -f "$CRON_STATE" ]; then
      cat "$CRON_STATE"
    else
      printf '*/5 * * * * $HOME/duty/bin/tick.sh\n'
    fi
    ;;
  -) tmp="$CRON_STATE.new"; cat >"$tmp"; mv "$tmp" "$CRON_STATE" ;;
  *) tmp="$CRON_STATE.new"; cat "$1" >"$tmp"; mv "$tmp" "$CRON_STATE" ;;
esac
CRONEOF
chmod +x "$MSSHIM/crontab"
crewstatus() {
  env CREW_CONFIG_DIR="$MSCONF" MSROOT="$MSROOT" MSCALLS="$MSCALLS" \
    PATH="$MSSHIM:$PATH" bash "$ROOT/cli/crew" status "$@" 2>&1
}
# The fixture box IS the installed tree from the installer fixtures above.
mkdir -p "$MSROOT/fixture-box"
cp -R "$MDUTY" "$MSROOT/fixture-box/duty"
# ...and it has ticked once. Not decoration: it pins the round-trip count
# asserted below at the steady state #159 is about — a box that has never
# ticked is a different state, and it has its own coverage in
# fleet-floor/test/cli.sh (the table's NOTE, #224; the detail view's line,
# #221).
#
# It used to say the never-ticked case was UNREACHABLE here: with no duty.log
# at all the row's `tail -n 1` exited 1, and under `set -o pipefail` that
# killed cmd_status's loop after the header. #224 fixed that — the fallback
# renders, the loop survives — so the reason this fixture ticks is now the
# count above and nothing else.
printf '2026-07-29T00:00:00Z duty run start\n' >"$MSROOT/fixture-box/duty/duty.log"

# #283 — exercise the real upgrade branch and installer, not a reconstruction
# of its grep. The script capture proves which flags reached install.sh; the
# state-backed crontab shim proves what the installer left behind.
upgradefixture() {
  : >"$MSINSTALL_SCRIPTS"
  env CREW_CONFIG_DIR="$MSCONF" MSROOT="$MSROOT" MSCALLS="$MSCALLS" \
    MSINSTALL_SCRIPTS="$MSINSTALL_SCRIPTS" PATH="$MSSHIM:$PATH" \
    bash "$ROOT/cli/crew" upgrade fixture-box >/dev/null 2>&1
}
resolved_tick="$MSROOT/fixture-box/duty/bin/tick.sh"

paused_cron="#CREW-FLOOR-PAUSED */5 * * * * $resolved_tick"
printf '%s\n' "$paused_cron" >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=PASSED; else r1=absent; fi
t upgrade-paused-box-passes-no-arm-flag absent "$r1"
t upgrade-paused-box-keeps-crontab "$paused_cron" "$(cat "$MSROOT/fixture-box/crontab")"

armed_cron="*/5 * * * * $resolved_tick"
printf '%s\n' "$armed_cron" >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=present; else r1=MISSING; fi
t upgrade-armed-box-keeps-arm-flag present "$r1"
t upgrade-armed-box-has-one-canonical-tick 1 \
  "$(grep -cF "$resolved_tick" "$MSROOT/fixture-box/crontab")"

: >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=PASSED; else r1=absent; fi
t upgrade-never-armed-box-passes-no-arm-flag absent "$r1"
t upgrade-never-armed-box-keeps-crontab '' "$(cat "$MSROOT/fixture-box/crontab")"

# Restore the ordinary armed fixture consumed by the status cases below.
printf '%s\n' "$armed_cron" >"$MSROOT/fixture-box/crontab"

status_out="$(crewstatus)"
case "$status_out" in *INTEGRITY*) r1=present ;; *) r1=MISSING ;; esac
t status-has-an-integrity-column present "$r1"
case "$status_out" in *"fixture-box"*current*) r1=current ;; *) r1=OTHER ;; esac
t status-clean-box-reads-current current "$r1"

# The round-trip budget (#159 acceptance): reading integrity must ride the exec
# `crew status` already made. Three per box — the engine report, the auth/tick
# read, and the last log line — which is exactly what it cost before this
# existed, when the first of the three was a bare `head -1 ~/duty/VERSION`.
: >"$MSCALLS"
crewstatus >/dev/null
t status-round-trips-per-box 3 "$(grep -c . "$MSCALLS")"

# #189 — an UNARMED box. `crew status` says so and names the fix, instead of
# printing the newest duty.log line, which on a box whose cron is gone is a
# fact about the past that reads exactly like a working box. The floor answers
# from the same counts; drill/rehearsal-app.sh compares the two on real
# hardware, and that comparison is the thing that had never once run.
status_out="$(MSCRON_EMPTY=1 crewstatus)"
case "$status_out" in *"fixture-box"*disarmed*"crew hire"*) r1=named ;; *) r1="$status_out" ;; esac
t status-unarmed-box-says-disarmed named "$r1"
# ...and it costs one round trip LESS, not more: the log-line read is skipped
# precisely because its answer would mislead. The budget above is the ceiling.
: >"$MSCALLS"
MSCRON_EMPTY=1 crewstatus >/dev/null
t status-round-trips-unarmed 2 "$(grep -c . "$MSCALLS")"

# #189, round 1 (codex/grok/kimi, all three) — a PAUSED box must be told to
# resume, never to re-hire. `grep -c` PRINTS the count and exits 1 when it is
# zero, so a `|| echo 0` guard appended a SECOND zero and pushed the paused
# count onto line two; `read` saw only line one and the note came out
# "disarmed — crew hire". Armed and empty-crontab both parse that away, which
# is why the first cut of these tests went green: this case is the one shape
# where both counts are non-trivial, and it is the shape a real operator makes
# by clicking Pause.
status_out="$(MSCRON_PAUSED=1 crewstatus)"
case "$status_out" in
  *"fixture-box"*"paused by operator"*) r1=paused ;;
  *"fixture-box"*disarmed*)             r1=WRONG-FIX-NAMED ;;
  *)                                    r1="$status_out" ;;
esac
t status-paused-box-says-paused paused "$r1"

# A modified box, end to end.
printf '# hotfix by hand\n' >>"$MSROOT/fixture-box/duty/bin/duty.sh"
status_out="$(crewstatus)"
case "$status_out" in *MODIFIED*) r1=shouts ;; *) r1=SILENT ;; esac
t status-modified-box-shouts shouts "$r1"
case "$status_out" in *"MODIFIED since crew@$(head -1 "$ROOT/VERSION")"*) r1=named ;; *) r1=UNNAMED ;; esac
t status-modified-names-the-version named "$r1"

# MUST FAIL: modified and skew collapsing into one state. They ask for
# different actions — skew says "ship the engine", modified says "find out
# what someone did here" — so the HOST/ENGINE pair and the INTEGRITY column
# have to disagree independently. Here the box is at the host's own version
# and still modified: nothing about skew can be producing this word.
host_v="$(head -1 "$ROOT/VERSION")"
ms_row="$(printf '%s\n' "$status_out" | grep '^fixture-box' || true)"
case "$ms_row" in
  *"$host_v"*"crew@$host_v"*MODIFIED*) r1=same-version-and-modified ;;
  *) r1=COLLAPSED ;;
esac
t status-modified-is-not-skew same-version-and-modified "$r1"

# The per-box view lists the files, on the same single exec.
detail_out="$(crewstatus fixture-box)"
case "$detail_out" in *"integrity: MODIFIED"*"modified bin/duty.sh"*) r1=listed ;; *) r1=MISSING ;; esac
t status-detail-lists-the-files listed "$r1"
case "$detail_out" in *"--force"*) r1=told ;; *) r1=SILENT ;; esac
t status-detail-names-the-override told "$r1"

# A box hired before content stamping: no record AND no tool to compute one.
# It reads unverified in the table, never modified.
rm -f "$MSROOT/fixture-box/duty/.engine-manifest" "$MSROOT/fixture-box/duty/bin/engine-manifest.sh"
status_out="$(crewstatus)"
case "$status_out" in *unverified*) r1=unverified ;; *MODIFIED*) r1=MODIFIED ;; *) r1=OTHER ;; esac
t status-pre-existing-box-reads-unverified unverified "$r1"

# --- git identity: the second carrier of the box's login (#294) -------------
# The split rotated the gh credential and left git naming the pre-split
# account, so a builder's commits were bylined by the reviewer. These assert
# the derivation: gh says who the box is, git is made to agree, and a box that
# cannot be made to agree runs nothing.
#
# GIT_CONFIG_GLOBAL, not $HOME: the suite inherits the real HOME (see the
# export at the top), and a test that writes `git config --global` without
# this rewrites the identity of whoever ran it — which on a live box is the
# very byline #294 exists to protect.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-294"
: >"$GIT_CONFIG_GLOBAL"
GHLOG="$TMP/gh-calls-294"; : >"$GHLOG"

# The address table. Every row is a shape that reaches this parser in the
# fleet as it stands today, not a hypothetical.
t gitid-parses-id-prefixed-form cndgrr \
  "$(git_identity_login '59120057+cndgrr@users.noreply.github.com')"
t gitid-parses-bare-form cndgrr \
  "$(git_identity_login 'cndgrr@users.noreply.github.com')"
t gitid-folds-case cndgrr \
  "$(git_identity_login 'CNDGRR@Users.NoReply.GitHub.COM')"
t gitid-parses-a-hyphenated-login claude-bot-andresmgsl \
  "$(git_identity_login 'claude-bot-andresmgsl@users.noreply.github.com')"
# Not a noreply address names nobody — deliberately, per the comment on the
# function: the fleet provisions noreply addresses only, so anything else is
# an address no code here wrote.
t gitid-rejects-a-real-email "" "$(git_identity_login 'dan@example.com')"
t gitid-rejects-empty "" "$(git_identity_login '')"
t gitid-rejects-missing-local-part "" "$(git_identity_login '@users.noreply.github.com')"
t gitid-rejects-empty-id "" "$(git_identity_login '+cndgrr@users.noreply.github.com')"
# A non-numeric prefix is not an id GitHub issued. Half-parsing it would read
# `andresmgsl+cndgrr@…` as cndgrr, which is a login this box does not hold.
t gitid-rejects-non-numeric-id "" \
  "$(git_identity_login 'andresmgsl+cndgrr@users.noreply.github.com')"
# The domain must END the address; a lookalike suffix must not match.
t gitid-rejects-lookalike-domain "" \
  "$(git_identity_login '59120057+cndgrr@users.noreply.github.com.example.net')"
# Whitespace INSIDE the address names nobody. Deleting it would manufacture an
# identity out of an address GitHub attributes to no account — the parser's own
# version of the bug this file is about.
t gitid-rejects-an-interior-space "" \
  "$(git_identity_login 'cnd grr@users.noreply.github.com')"
t gitid-rejects-a-space-around-the-id "" \
  "$(git_identity_login '59120057 + cndgrr@users.noreply.github.com')"
t gitid-rejects-a-space-in-the-domain "" \
  "$(git_identity_login 'cndgrr@users.noreply.git hub.com')"
# The EDGES are still trimmed: that is a value a hand-edited config presents,
# and the address inside it is unambiguous.
t gitid-trims-surrounding-whitespace cndgrr \
  "$(git_identity_login '  59120057+cndgrr@users.noreply.github.com
')"
t gitid-rejects-whitespace-only "" "$(git_identity_login '   ')"

# --- the must-fail proof (#294's test plan) ---------------------------------
# A duty environment whose user.email does not match $ME. Reverting the assert
# greens a box that commits as somebody else, which is today's behaviour and
# the point.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-mismatched-email-is-refused refused "$r1"

# The SAME foreign address in the id-prefixed form — the row #294 singles out
# as the one that matters, because a parser that greened anything containing a
# '+' would green every foreign address on the fleet and still pass the bare
# row above.
git config --global user.email '1234567+claude-bot-andresmgsl@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-foreign-id-prefixed-form-is-refused refused "$r1"

# An address that is only this box's login once its interior whitespace is
# deleted is NOT this box's login. git config stores the value verbatim, so
# this is a state a real ~/.gitconfig can hold, and greening it would byline
# every commit to nobody while the guard reported a converged box.
git config --global user.email 'cnd grr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-interior-space-email-is-refused refused "$r1"

# Both forms of this box's own address pass. One is what provisioning writes,
# the other is what the 2026-08-02 hand sweep wrote; an assert that took only
# the first would red every box that sweep already repaired.
git config --global user.email '59120057+cndgrr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=ok; else r1=REFUSED; fi
t gitid-id-prefixed-form-passes ok "$r1"
git config --global user.email 'cndgrr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=ok; else r1=REFUSED; fi
t gitid-hand-swept-bare-form-passes ok "$r1"
if git_identity_ok CNDGRR; then r1=ok; else r1=REFUSED; fi
t gitid-login-comparison-is-case-insensitive ok "$r1"

# No configured identity is a mismatch, not a pass: git then authors commits
# as whatever the box template left behind, which is how this started.
git config --global --unset user.email
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-unset-email-is-refused refused "$r1"
# And an empty login can never be satisfied — a caller with no $ME must not
# accidentally green every box.
git config --global user.email '59120057+cndgrr@users.noreply.github.com'
if git_identity_ok ""; then r1=GREEN; else r1=refused; fi
t gitid-empty-login-is-refused refused "$r1"

# --- convergence ------------------------------------------------------------
# shellcheck disable=SC2317  # invoked indirectly, by converge_git_identity
gh() { echo "$*" >>"$GHLOG"; printf '%s\t%s\n' "$GH_STUB_LOGIN" "$GH_STUB_ID"; }
GH_STUB_LOGIN=cndgrr GH_STUB_ID=59120057

# The steady state costs NOTHING: already converged, so no network call. This
# runs on every tick of every box, so a stray `gh api user` here is a fleet's
# worth of requests for a fact already on local disk.
: >"$GHLOG"
converge_git_identity cndgrr
t gitid-converged-returns-ok 0 "$?"
t gitid-steady-state-makes-no-gh-call "" "$(cat "$GHLOG")"

# The hand-swept bare form is already converged too — it must NOT be rewritten
# on every upgrade for the rest of time.
git config --global user.email 'cndgrr@users.noreply.github.com'
: >"$GHLOG"
converge_git_identity cndgrr
t gitid-bare-form-is-not-rewritten 'cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"

# The repair: a box carrying the pre-split account converges to its own.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
: >"$GHLOG"
converge_git_identity cndgrr >/dev/null
t gitid-repair-returns-ok 0 "$?"
t gitid-repair-writes-id-prefixed-address '59120057+cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"
t gitid-repair-writes-the-name cndgrr "$(git config --global user.name)"
t gitid-repair-spends-one-gh-call 1 "$(wc -l <"$GHLOG")"

# No argument is install.sh's call — it has no $ME, so gh alone decides.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
converge_git_identity >/dev/null
t gitid-no-argument-converges-from-gh '59120057+cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"

# A dead credential must NOT be repaired-by-guess. There is no source of truth
# to copy, so the copy is left alone and the caller is told — which is what
# makes duty.sh refuse rather than run a session under a name it cannot verify.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
# shellcheck disable=SC2317
gh() { return 1; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-dead-credential-refuses 1 "$?"
t gitid-dead-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"

# A credential that ROTATED between duty.sh resolving $ME and this call must
# refuse, not converge. Converging would write the NEW account and return 0
# while the tick carries on as the OLD $ME — a session acting as one identity
# whose commits byline another, which is #294 one call later rather than
# fixed. Refusing costs one tick; the next one reads both halves consistently.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
# shellcheck disable=SC2317
gh() { printf '%s\t%s\n' andriujoseba 12345678; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-rotated-credential-refuses 1 "$?"
t gitid-rotated-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
# The rotation guard is the CALLER's to invoke: install.sh passes no login
# because it has no $ME, and its whole job is to write whatever gh now says.
converge_git_identity >/dev/null 2>&1
t gitid-no-argument-follows-the-rotation '12345678+andriujoseba@users.noreply.github.com' \
  "$(git config --global user.email)"

# A malformed id is the same class: an address built from it would attribute
# to nobody, and writing it would look like a repair while fixing nothing.
# The starting address is set here rather than inherited from the block above,
# so this case reds for its own reason and not for a neighbour's.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
# shellcheck disable=SC2317
gh() { printf '%s\t%s\n' cndgrr 'not-a-number'; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-non-numeric-id-refuses 1 "$?"
t gitid-non-numeric-id-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
unset -f gh
unset GIT_CONFIG_GLOBAL

# --- the engine actually asks, and refuses before it dispatches -------------
# Static, because duty.sh is a script and not a sourceable module. These are
# the assertions that make REVERTING the fix red: without them a reviewer's
# green tells them the helper works, not that anything calls it.
DUTYSH="$SHARED/bin/duty.sh"
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -Fq 'converge_git_identity "$ME"' "$DUTYSH"; then r1=called; else r1=MISSING; fi
t gitid-duty-converges-against-me called "$r1"

# Ordering is the whole claim: "before any session runs". A converge placed
# after the first dispatch would pass every helper test above and still let a
# session commit under another droid's name.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
conv_line="$(grep -n 'converge_git_identity "\$ME"' "$DUTYSH" | head -1 | cut -d: -f1)"
disp_line="$(grep -n '^duty_attention$' "$DUTYSH" | head -1 | cut -d: -f1)"
if [ -n "$conv_line" ] && [ -n "$disp_line" ] && [ "$conv_line" -lt "$disp_line" ]; then
  r1=before
else
  r1="AFTER(converge=$conv_line dispatch=$disp_line)"
fi
t gitid-converge-precedes-the-first-duty before "$r1"

# And the refusal ends the tick rather than logging and carrying on.
# shellcheck disable=SC2016  # match the literal duty.sh awk range
if awk_range_grep_Fq '/converge_git_identity "\$ME"/,/^fi$/' "$DUTYSH" 'exit 0'; then
  r1=exits
else
  r1=CONTINUES
fi
t gitid-refusal-ends-the-tick exits "$r1"

# install.sh writes it through the ENGINE, not a private copy of the rule. A
# second implementation of "which login is this box" is how the panel copy
# (#285) and the git copy (#294) both happened.
if grep -Fq 'converge_git_identity' "$SHARED/install.sh"; then r1=derived; else r1=MISSING; fi
t gitid-install-uses-the-shared-helper derived "$r1"

if "$SHARED/test/claim.test.sh"; then r1=0; else r1=$?; fi
t claim-regression-suite 0 "$r1"


# --- rehearsal reviewer announce ordering (#192) --------------------------
# shellcheck source=drill/review-order.sh
source "$ROOT/drill/review-order.sh"
REVIEW_HEAD="$(printf 'a%.0s' {1..40})"
REVIEW_BEFORE_COMMENTS='[{"user":{"login":"reviewer"},"body":"🔎 reviewing head '"$REVIEW_HEAD"'","created_at":"2026-07-30T10:00:00Z","guest_clock":"2099-01-01T00:00:00Z"}]'
REVIEW_AFTER_COMMENTS='[{"user":{"login":"reviewer"},"body":"🔎 reviewing head '"$REVIEW_HEAD"'","created_at":"2026-07-30T10:06:00Z","guest_clock":"2000-01-01T00:00:00Z"}]'
REVIEW_VERDICTS='[{"user":{"login":"reviewer"},"commit_id":"'"$REVIEW_HEAD"'","state":"APPROVED","submitted_at":"2026-07-30T10:05:00Z"}]'

if rehearsal_review_announce_precedes_verdict_from_json \
    reviewer "$REVIEW_HEAD" "$REVIEW_BEFORE_COMMENTS" "$REVIEW_VERDICTS"; then
  review_order_rc=0
else
  review_order_rc=$?
fi
t rehearsal-review-announce-before-verdict-rc 0 "$review_order_rc"

if review_order_out="$(rehearsal_review_announce_precedes_verdict_from_json \
    reviewer "$REVIEW_HEAD" "$REVIEW_AFTER_COMMENTS" "$REVIEW_VERDICTS" 2>&1)"; then
  review_order_rc=0
else
  review_order_rc=$?
fi
t rehearsal-review-announce-after-verdict-rc 5 "$review_order_rc"
case "$review_order_out" in
  *"review ordering: announce must precede verdict"*) r1=named ;;
  *) r1=missing ;;
esac
t rehearsal-review-announce-after-verdict-names-ordering named "$r1"
# The mutation leaves the two existing predicates satisfied: the announce is
# still present at this head and still appears exactly once.
t rehearsal-review-after-verdict-presence-still-passes 1 \
  "$(jq -r --arg h "$REVIEW_HEAD" '[.[] | select(.body == ("🔎 reviewing head " + $h))] | length' \
    <<<"$REVIEW_AFTER_COMMENTS")"
t rehearsal-review-after-verdict-dedup-still-passes 1 \
  "$(jq -r '[.[] | select(.body | startswith("🔎 reviewing head"))] | length' \
    <<<"$REVIEW_AFTER_COMMENTS")"

# --- install.sh: crontab preflight and convergence (#25) ----------------
# A curated PATH makes "crontab absent" deterministic even on a workstation
# that happens to have cron installed. Everything install.sh legitimately
# needs is linked in; gh and git are fixture shims.
ISHIM="$TMP/install-bin"
IHOME="$TMP/install-home"
IDUTY="$IHOME/duty"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM" "$IHOME"
# find/sort/tail/xargs joined the list with #159's engine manifest: the curated
# PATH is the box's whole world here, and a tool missing from it degrades the
# install to `unverified` instead of failing, which would hide the very thing
# these fixtures assert.
for cmd in awk bash basename cat chmod cp date dirname env find grep head mkdir mktemp mv readlink rm sed sha256sum sort tail tr wc xargs; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
# If install.sh ever infers from hostname again, make the regression reproduce
# the dangerous case deterministically rather than depend on this test host.
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
# shellcheck disable=SC2016  # expanded when the fixture shim runs
printf '#!/usr/bin/env bash\n[ "${FIXTURE_GITLESS:-0}" != 1 ] || exit 1\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
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
t install-version-with-provenance \
  "crew@$(head -1 "$ROOT/VERSION") (fixture-sha)" "$(head -1 "$IDUTY/VERSION")"

# The installed package shape has no .git. Run that actual shape, rather than
# trusting the Git shim used by the rest of the installer fixtures.
GITLESS_ROOT="$TMP/gitless-crew"
GITLESS_HOME="$TMP/gitless-home"
mkdir -p "$GITLESS_ROOT" "$GITLESS_HOME"
cp -R "$SHARED" "$GITLESS_ROOT/shared"
cp -R "$ROOT/examples" "$GITLESS_ROOT/examples"
cp "$ROOT/VERSION" "$GITLESS_ROOT/VERSION"
if FIXTURE_GITLESS=1 HOME="$GITLESS_HOME" DUTY_DIR="$GITLESS_HOME/duty" \
  PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
  /bin/bash "$GITLESS_ROOT/shared/install.sh" --agent claude --role reviewer \
  >"$TMP/gitless-install.out" 2>&1; then r1=0; else r1=$?; fi
t install-gitless-rc 0 "$r1"
t install-gitless-stamps-version \
  "crew@$(head -1 "$ROOT/VERSION")" "$(head -1 "$GITLESS_HOME/duty/VERSION")"
case "$(head -1 "$GITLESS_HOME/duty/VERSION")" in
  *unknown*) r1=unknown ;;
  *) r1=versioned ;;
esac
t install-gitless-never-unknown versioned "$r1"

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
  case " $* " in
    *" --converge-registries "*)
      [ -f "$RDUTY/.crew-seed-repos.txt" ] ||
        cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-seed-repos.txt"
      [ -f "$RDUTY/.crew-example-repos.txt" ] ||
        cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-example-repos.txt"
      [ -f "$RDUTY/.crew-example-notify-repos.txt" ] ||
        cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-example-notify-repos.txt"
      [ -f "$RDUTY/.crew-seed-notify-repos.txt" ] ||
        cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-seed-notify-repos.txt"
      ;;
  esac
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
printf 'fixture/shipped-example\n' >"$RDUTY/repos.txt"
printf 'fixture/shipped-example\n' >"$RDUTY/.crew-example-repos.txt"
printf 'fixture/migrated\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-adopts-example fixture/migrated "$(cat "$RDUTY/repos.txt")"
t install-transported-example-discarded absent \
  "$([ -e "$RDUTY/.crew-example-repos.txt" ] && printf present || printf absent)"
rm -f "$RDUTY/.repos.txt.crew-provenance"
printf 'fixture/unknown-local\n' >"$RDUTY/repos.txt"
printf 'fixture/incoming\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-vetoes-unknown fixture/unknown-local "$(cat "$RDUTY/repos.txt")"

# Convergence must fail closed when any one-shot transport leg is absent.
# Call install.sh directly: roster_install deliberately backfills the payloads
# so the ordinary convergence cases exercise the complete host transport.
printf 'fixture/notify-contained\n' >"$RDUTY/notify-repos.txt"
for missing_payload in \
  .crew-seed-repos.txt \
  .crew-seed-notify-repos.txt \
  .crew-example-repos.txt \
  .crew-example-notify-repos.txt; do
  cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-seed-repos.txt"
  cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-seed-notify-repos.txt"
  cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-example-repos.txt"
  cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-example-notify-repos.txt"
  rm -f "$RDUTY/$missing_payload"
  before_repos="$(cat "$RDUTY/repos.txt")"
  before_notify_repos="$(cat "$RDUTY/notify-repos.txt")"
  if refusal_out="$(env HOME="$RHOME" DUTY_DIR="$RDUTY" PATH="$ISHIM" \
    CRON_STATE="$CRON_STATE" /bin/bash "$SHARED/install.sh" \
    --box claude-builder --converge-registries 2>&1)"; then
    r1=0
  else
    r1=$?
  fi
  t "install-incomplete-$missing_payload-refused" 1 "$r1"
  case "$refusal_out" in
    *"missing transported registry payload $missing_payload"*) r1=named ;;
    *) r1="missing: $refusal_out" ;;
  esac
  t "install-incomplete-$missing_payload-named" named "$r1"
  t "install-incomplete-$missing_payload-keeps-repos" \
    "$before_repos" "$(cat "$RDUTY/repos.txt")"
  t "install-incomplete-$missing_payload-keeps-notify-repos" \
    "$before_notify_repos" "$(cat "$RDUTY/notify-repos.txt")"
done
rm -f "$RDUTY/notify-repos.txt"

runtime_fleet="$(DUTY_DIR="$RDUTY" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s|%s" "$FLEET_HUMAN" "$MARK_PICKUP"')"
t install-loads-defaults-then-operator 'fixture-human|📌 picked up' "$runtime_fleet"
# MARK_HANDOFF is a protocol mark like the others: an operator fleet.conf must
# not be able to override it (post-once.sh's dedup keys on the first line, so a
# drifted mark would silently double-post the handoff). Same wire-pin (#91).
printf 'MARK_HANDOFF="not-the-protocol"\n' >>"$RDUTY/conf/fleet.conf"
t handoff-mark-wire-pinned '🤝 handed off at head' \
  "$(DUTY_DIR="$RDUTY" bash -c '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s" "$MARK_HANDOFF"')"
printf 'claude-builder claude triage\n' >"$RDUTY/fleet.roster"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-triage-notify-seed fixture/wide "$(cat "$RDUTY/notify-repos.txt")"

# The role registry is conf/roles/*.conf and nothing else; a second list — a
# "role manifest" — is what this refuses. Two unrelated manifests have since
# turned up, so rather than delete the guard it subtracts exactly those two
# uses: the content hash of the installed ENGINE tree (#159), and rig's
# PROVENANCE file (#220 — /etc/rig/manifest, which rig owns and crew only
# reads; crew declares no roles in it and could not, since it never writes it).
# A `manifest` that is neither is still a duplicated registry, and the
# subtraction is per LINE, so the qualified phrase has to be written out every
# time it appears in these files.
manifest_hits="$(grep -Rsinw 'manifest' "$SHARED/docs" "$SHARED/README.md" "$SHARED/conf" \
    "$SHARED/lib" "$SHARED/install.sh" "$ROOT/examples/fleet.roster" "$ROOT/cli/crew" \
    "$ROOT/drill" 2>/dev/null \
    | grep -vi 'engine[ ._-]manifest' | grep -vi 'rig[ /._-]manifest' || true)"
if [ -n "$manifest_hits" ]; then
  r1="DUPLICATED: $manifest_hits"
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

# #283 — every reader of the armed state must agree that only a live tick
# line counts. A paused line contains tick.sh too, so an unanchored probe makes
# routine maintenance silently resume a box the operator deliberately paused.
status_tick_pattern="$(sed -n 's/.*grep -cE "\([^"]*tick\\\.sh\)".*/\1/p' "$ROOT/cli/crew" | head -1)"
upgrade_tick_pattern="$(sed -n 's/.*grep -qE "\([^"]*tick\\\.sh\)".*/\1/p' "$ROOT/cli/crew" | tail -1)"
floor_tick_pattern="$(sed -n "s/.*grep -cE '\([^']*tick\\\\\.sh\)'.*/\1/p" "$ROOT/fleet-floor/server/probe.sh" | head -1)"
t upgrade-status-armed-pattern-is-present present "$([ -n "$status_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-armed-pattern-is-present present "$([ -n "$upgrade_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-floor-armed-pattern-is-present present "$([ -n "$floor_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-armed-pattern-matches-status "$status_tick_pattern" "$upgrade_tick_pattern"
t upgrade-armed-pattern-matches-floor "$floor_tick_pattern" "$upgrade_tick_pattern"

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
if grep -qE '^[1-9][0-9]*$' <<<"$_in"; then r1=passed; else r1=refused; fi
  t "count-predicate-refuses-${_in:-empty}" refused "$r1"
done
if grep -qE '^[1-9][0-9]*$' <<<'3'; then r1=passed; else r1=refused; fi
t count-predicate-accepts-real-count passed "$r1"
# The shape it replaced, pinned so nobody reintroduces it. Uses gh's error
# JSON, not empty input: -v on an empty stream is shell/grep dependent, but
# ANY non-"0" line — which is what a failed gh call prints to stdout — makes
# the old predicate return 0. That is the realistic failure and it is
# deterministic everywhere.
if grep -qv '^0$' <<<'{"message":"Not Found","status":"404"}'; then r1=fail-open; else r1=fail-closed; fi
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

# --- notify repo set: work repos union additive handoff targets (#316) ----
# Run the real notifier with an empty-board gh shim. This observes every
# repository it queries without network access or duplicating its set logic in
# the test. A repo in repos.txt is always covered; notify-repos.txt only adds
# cross-repo targets; overlap is queried once.
NSHIM="$TMP/notify-bin"
NLOG="$TMP/notify-gh.log"
mkdir -p "$NSHIM"
cat >"$NSHIM/gh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-R" ]; then printf '%s\n' "$2" >>"$NLOG"; break; fi
  shift
done
printf '[]\n'
EOF
chmod +x "$NSHIM/gh"
printf '\nBOT_PATH_PREPEND=%q\n' "$NSHIM" >>"$LHOME/duty/conf/agents/claude.conf"
printf 'fixture/work-only\nfixture/both\n' >"$LHOME/duty/repos.txt"
printf 'fixture/notify-only\nfixture/both\n' >"$LHOME/duty/notify-repos.txt"
printf 'fixture-token\n' >"$LHOME/.tg_bot_token"
printf 'fixture-chat\n' >"$LHOME/.tg_chat_id"
: >"$NLOG"
env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh" >/dev/null
t notify-repos-union "fixture/both
fixture/notify-only
fixture/work-only" "$(sort "$NLOG")"
t notify-repos-overlap-once 1 "$(grep -cxF fixture/both "$NLOG")"

# A present but unreadable additive registry takes the same explicit fallback
# path: the work set remains covered, the sweep succeeds, and the operator is
# told that only repos.txt participated.
chmod 000 "$LHOME/duty/notify-repos.txt"
: >"$NLOG"
if notify_unreadable_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh")"; then
  notify_unreadable_rc=0
else
  notify_unreadable_rc=$?
fi
t notify-repos-unreadable-rc 0 "$notify_unreadable_rc"
t notify-repos-unreadable-fallback "fixture/both
fixture/work-only" "$(sort "$NLOG")"
case "$notify_unreadable_out" in
  *"notify-repos.txt missing — falling back to repos.txt"*) r1=logged ;;
  *) r1=SILENT ;;
esac
t notify-repos-unreadable-fallback-is-logged logged "$r1"
chmod 600 "$LHOME/duty/notify-repos.txt"

# With no additive registry the work set is still watched, and the existing
# fallback log remains explicit.
rm -f "$LHOME/duty/notify-repos.txt"
: >"$NLOG"
notify_fallback_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh")"
t notify-repos-fallback "fixture/both
fixture/work-only" "$(sort "$NLOG")"
case "$notify_fallback_out" in
  *"notify-repos.txt missing — falling back to repos.txt"*) r1=logged ;;
  *) r1=SILENT ;;
esac
t notify-repos-fallback-is-logged logged "$r1"

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
t rehearsal-isolation-records-the-copy 1 "$REHEARSAL_BACKUP_TAKEN"

# Must fail: the copy did not happen. The flag teardown reads is the COPY, not
# the handle — the handle is assigned first, so a round whose `cp` failed
# carries one too, and reading it as "a backup exists" is what let a deleted
# backup pass as "nothing to vouch for". Nothing may truncate the registry on
# this path either.
ISO_CALLS="$TMP/rehearsal-isolation-calls"
: >"$ISO_CALLS"
(
  bx() {
    printf '%s\n' "$1" >>"$ISO_CALLS"
    case "$1" in *"cp ~/duty/repos.txt"*) return 1 ;; esac
  }
  rehearsal_begin_isolation
  printf 'rc=%s taken=%s\n' "$?" "$REHEARSAL_BACKUP_TAKEN"
) >"$TMP/rehearsal-isolation-failed-copy"
t rehearsal-isolation-failed-copy-refuses 'rc=1 taken=0' \
  "$(cat "$TMP/rehearsal-isolation-failed-copy")"
t rehearsal-isolation-failed-copy-truncates-nothing 0 \
  "$(grep -cF ': > ~/duty/repos.txt' "$ISO_CALLS")"
# ...and on the path that does work, the copy is the FIRST thing the box is
# asked to do, so the flag is set before anything can overwrite what it names.
: >"$ISO_CALLS"
(
  bx() { printf '%s\n' "$1" >>"$ISO_CALLS"; }
  rehearsal_begin_isolation
) >/dev/null 2>&1
t rehearsal-isolation-copies-first 'cp' "$(head -1 "$ISO_CALLS" | cut -c1-2)"
t rehearsal-isolation-truncates-after 1 \
  "$(grep -cF ': > ~/duty/repos.txt' "$ISO_CALLS")"
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


# --- the 0.1.2 operator surfaces: every assertion red on a staged answer -
# drill/rehearsal-app-surfaces.sh holds the seven assertions drill/rehearsal-
# app.sh makes about what 0.1.2 shipped into the operator's view (#420). They
# run on a drill HOST, which CI does not have — so they are exercised the way
# the other rehearsal helpers already are here: the leg's reporters stubbed,
# the file sourced, and a WRONG answer staged into the input each assertion
# reads. An assertion nobody can red is an assertion nobody has checked, which
# is #50's defect stated once more.
SURF="$TMP/app-surfaces"
mkdir -p "$SURF"

# One truthful fleet, four boxes: two hired and answering, one never created,
# one deployed but not talking. Every payload below is this one with exactly
# one field moved, so a red is attributable to that field and nothing else.
surf_payload() {  # surf_payload '<python mutating p>' → the fleet payload
  python3 - "$1" <<'PY'
import json, sys
p = {
    "version": "crew 0.1.2 (/opt/crew)",
    # `state`, `paused` and `disarmed` are the three fields fleetState() reads
    # (fleet-floor/src/app.js:1282-1285): a DRAWN unit that is offline lands in
    # Disarmed when either flag is set and in Silent when neither is. They are
    # here because the filter assertion compares the page's groups against the
    # sets they imply — crew-b disarmed, crew-d silent — rather than only
    # against whoever the page happened to list.
    "units": [
        {"box": "crew-a", "engine": "0.1.2", "integrity": "current",
         "hired": "yes", "note": "", "state": "idle",
         "paused": False, "disarmed": False},
        {"box": "crew-b", "engine": "0.1.2", "integrity": "modified",
         "hired": "yes", "note": "", "state": "offline",
         "paused": False, "disarmed": True},
        {"box": "crew-c", "engine": "", "integrity": "",
         "hired": "no", "note": "not created — crew new crew-c",
         "state": "offline", "paused": False, "disarmed": False},
        {"box": "crew-d", "engine": "0.1.2", "integrity": "unverified",
         "hired": "unknown", "note": "stopped", "state": "offline",
         "paused": False, "disarmed": False},
    ],
}
u = {b["box"]: b for b in p["units"]}
exec(sys.argv[1])
print(json.dumps(p))
PY
}
surf_payload 'pass'                                     >"$SURF/fleet.json"
surf_payload 'p["version"] = "crew 9.9.9 (/staged)"'    >"$SURF/fleet-wrong-version.json"
surf_payload 'p["version"] = "version unavailable"'     >"$SURF/fleet-no-version.json"
surf_payload 'u["crew-b"]["integrity"] = "current"'     >"$SURF/fleet-integrity-lie.json"
surf_payload 'u["crew-c"]["note"] = "not created"'      >"$SURF/fleet-no-repair-verb.json"
surf_payload 'p["units"] = [b for b in p["units"] if b["box"] != "crew-d"]' \
                                                        >"$SURF/fleet-drops-a-box.json"
# The same drop, of the one box that IS a measured absence — so the payload is
# short AND nothing in it carries `hired=no`, which is the pair that used to
# read as "every roster box is deployed".
surf_payload 'p["units"] = [b for b in p["units"] if b["box"] != "crew-c"]' \
                                                        >"$SURF/fleet-drops-the-undeployed-box.json"
surf_payload 'u["crew-c"]["note"] = "box inventory unreadable: box list failed"' \
                                                        >"$SURF/fleet-inventory-unreadable.json"
# Short BECAUSE the inventory failed: an unmeasured fleet, which must keep
# skipping rather than being read as the dropped-box regression.
surf_payload '
u["crew-b"]["note"] = "box inventory unreadable: box list failed"
p["units"] = [b for b in p["units"] if b["box"] != "crew-c"]
'                                                       >"$SURF/fleet-inventory-unreadable-and-short.json"
surf_payload 'u["crew-c"].update(hired="yes", engine="0.1.2", integrity="current", note="")' \
                                                        >"$SURF/fleet-all-deployed.json"
surf_payload 'u["crew-d"]["note"] = ""'                 >"$SURF/fleet-all-answered.json"
# Every declared box undeployed — #204's empty floor, the state the panel
# naming `crew hire` exists for.
surf_payload '
for b in p["units"]:
    b.update(hired="no", engine="", integrity="", state="offline",
             note="not hired — crew hire " + b["box"])
'                                                       >"$SURF/fleet-all-undeployed.json"
# The floor and the CLI disagreeing about one box: the payload says crew-b is
# deliberately stopped and `crew status` does not.
surf_payload 'u["crew-b"]["disarmed"] = False'          >"$SURF/fleet-b-not-disarmed.json"
# Two boxes deliberately stopped — an ordinary fleet, and the one that puts two
# members into the disarmed direction's blind set.
surf_payload 'u["crew-d"]["disarmed"] = True'           >"$SURF/fleet-two-disarmed.json"
# Nothing quiet at all: every drawn box is ticking, so neither state group has
# a member and the filter has nothing to classify.
surf_payload '
for b in p["units"]:
    b["state"] = "idle"
'                                                       >"$SURF/fleet-none-quiet.json"

printf 'crew-a claude builder\ncrew-b codex reviewer\ncrew-c grok triage\ncrew-d kimi builder\n' \
  >"$SURF/roster"
SURF_ROSTER="$SURF/roster"
# What each box answers to `engine-manifest.sh --state`, standing in for the
# `box exec` the leg does — the second reader #190's assertion cross-checks the
# floor against.
printf 'crew-a current\ncrew-b modified\ncrew-d unverified\n' >"$SURF/integrity"
printf 'crew-a current\ncrew-b tampered\ncrew-d unverified\n' >"$SURF/integrity-fourth-word"
: >"$SURF/integrity-silent"
SURF_INTEG="$SURF/integrity"

# The leg's reporters, in a SUBSHELL so run.sh's own t() survives the stubbing:
# each verdict comes back as one "<ok|FAIL|skip> <label> <reason>" line on
# stdout, which is the whole interface the assertions below match against.
# The REASON is on the line and not only the label, because criterion 3 is
# about the reason: "no assertion silently passes when its precondition is
# absent" is a claim about what the skip SAYS, and a skip whose stated reason
# is not true is the defect the #204 gate below exists to close. Newlines are
# flattened so one verdict stays one line.
# shellcheck disable=SC2317  # the stubs are reached through "$@", which is an
# indirection shellcheck cannot follow — every one of them is called by the
# sourced assertions below.
surf() {  # surf <fn> [args...] → one verdict line per assertion the fn makes
  (
    emit() { local v="$1" m; shift; m="$*"; printf '%s %s\n' "$v" "${m//$'\n'/ }"; }
    ok()   { emit ok "$@"; }
    fail() { emit FAIL "$@"; }
    skip() { emit skip "$@"; }
    t()    { if [ "$2" = "$3" ]; then printf 'ok %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; }
    jqf()  { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
    roster_rows()   { grep -vE '^[[:space:]]*(#|$)' "$SURF_ROSTER"; }
    # The caller supplies this reader, and on a real host it shells into a box.
    # SURF_GREEDY_READER makes it behave like the one that does — `box exec`
    # inherits the loop's stdin and drains it — which truncated the roster loop
    # to its first box on the host, silently, while the label kept claiming the
    # fleet.
    box_integrity() {
      # Bounded, because the drain must not outlive the thing it is draining:
      # once the roster moved to fd 3 this `cat` no longer meets the loop's
      # pipe at all, it meets whatever stdin the suite was STARTED with — and
      # an unbounded read of a socket that nobody is going to close hangs the
      # whole suite forever. It reaches EOF instantly against a pipe or
      # /dev/null (which is CI, and is the pre-fix code path this case reds
      # on), so the bound costs nothing where it is not needed.
      [ -n "${SURF_GREEDY_READER:-}" ] && { timeout 1 cat >/dev/null 2>&1 || true; }
      awk -v b="$1" '$1 == b { print $2 }' "$SURF_INTEG"
    }
    # shellcheck source=drill/rehearsal-app-surfaces.sh
    source "$ROOT/drill/rehearsal-app-surfaces.sh"
    "$@"
  )
}
surf_says() {  # surf_says <verdict lines> <label substring> → ok|FAIL|skip|absent
  local line
  line="$(printf '%s\n' "$1" | grep -F -- "$2" | head -1)"
  [ -n "$line" ] || { printf 'absent'; return 0; }
  printf '%s' "${line%% *}"
}

# --- #347: the header names the version of the crew SERVING the page -----
SURF_V="floor: the API names the serving host"
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-truthful-header ok "$(surf_says "$r1" "$SURF_V")"
r1="$(surf app_surface_version "$SURF/fleet-wrong-version.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-staged-wrong-version FAIL "$(surf_says "$r1" "$SURF_V")"
# The server dropped what the launcher passed and served its placeholder.
r1="$(surf app_surface_version "$SURF/fleet-no-version.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-placeholder-served FAIL "$(surf_says "$r1" "$SURF_V")"
# The launcher and the page agree on a version this tree is not: the half that
# stops the assertion being a fixture comparing itself to itself.
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" 0.1.1)"
t app-surface-347-stale-release-named FAIL "$(surf_says "$r1" "$SURF_V")"
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" '')"
t app-surface-347-no-version-file FAIL "$(surf_says "$r1" "$SURF_V")"

# --- #190: the verdict on the tile is the BOX's own word -----------------
SURF_I="floor: every hired box's integrity verdict"
SURF_IV="floor: every integrity verdict is one of the three words"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-truthful-verdicts ok "$(surf_says "$r1" "$SURF_I")"
t app-surface-190-truthful-vocabulary ok "$(surf_says "$r1" "$SURF_IV")"
# The label names how many boxes were compared, and it must be all three that
# answered — not the one the loop happened to reach.
t app-surface-190-compares-every-box ok "$(surf_says "$r1" "verdict is the box's own answer (3 boxes)")"
# The reader that shells into a box drains the loop's stdin. Reading the roster
# on fd 3 is what keeps that from truncating the loop to its first member — a
# real host defect, found by running the leg, invisible to a stub reader that
# does not touch stdin.
r1="$(SURF_GREEDY_READER=1 surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-greedy-reader-visits-every-box ok "$(surf_says "$r1" "verdict is the box's own answer (3 boxes)")"
# The floor prints `current` for a box whose own manifest says `modified` —
# exactly the reassurance #190 exists to stop the page inventing.
r1="$(surf app_surface_integrity "$SURF/fleet-integrity-lie.json")"
t app-surface-190-staged-floor-lie FAIL "$(surf_says "$r1" "$SURF_I")"
SURF_INTEG="$SURF/integrity-fourth-word"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-fourth-word-red FAIL "$(surf_says "$r1" "$SURF_IV")"
SURF_INTEG="$SURF/integrity-silent"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
# No box answered the second reader, so there is nothing to compare — and the
# precondition is NAMED rather than passing quietly.
t app-surface-190-unanswerable-skips skip "$(surf_says "$r1" "$SURF_I")"
t app-surface-190-names-the-silent-box skip "$(surf_says "$r1" "integrity: crew-a")"
SURF_INTEG="$SURF/integrity"

# --- #204: not deployed is COUNTED and not DRAWN -------------------------
SURF_ND="floor: a roster box that is not deployed is counted"
SURF_NC="floor: the not-deployed boxes are counted but not drawn"
r1="$(surf app_surface_not_deployed "$SURF/fleet.json" 4)"
t app-surface-204-truthful-repair-verb ok "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-truthful-counts ok "$(surf_says "$r1" "$SURF_NC")"
r1="$(surf app_surface_not_deployed "$SURF/fleet-no-repair-verb.json" 4)"
t app-surface-204-staged-silent-note FAIL "$(surf_says "$r1" "$SURF_ND")"
# The filter applied one layer too high: the box is gone from the payload, so
# the fleet silently shrinks instead of keeping its declared size. Reds at the
# completeness gate now, which owns this direction and names the missing box —
# so the arithmetic assertion downstream is never reached and is `absent`.
r1="$(surf app_surface_not_deployed "$SURF/fleet-drops-a-box.json" 4)"
t app-surface-204-staged-shrunk-fleet FAIL "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-shrunk-fleet-names-the-box FAIL "$(surf_says "$r1" "never reported: crew-d")"
t app-surface-204-shrunk-fleet-stops-at-the-gate absent "$(surf_says "$r1" "$SURF_NC")"
# The same drop, of the box that is the fleet's ONLY measured absence. This is
# the direction the mutation above cannot reach: with `crew-c` gone no unit
# carries `hired=no`, so the empty-set branch used to conclude "every one of
# the 4 roster boxes is deployed" over a three-unit payload — #204's own
# regression reported as a fleet that does not exercise it. It must FAIL, not
# skip (codex-bot at 4bde9ce; triage's Must-fail in #420's test plan).
r1="$(surf app_surface_not_deployed "$SURF/fleet-drops-the-undeployed-box.json" 4)"
t app-surface-204-drops-the-undeployed-box FAIL "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-drops-the-undeployed-box-named FAIL "$(surf_says "$r1" "never reported: crew-c")"
r1="$(surf app_surface_not_deployed "$SURF/fleet-inventory-unreadable.json" 4)"
t app-surface-204-unmeasured-absence-skips skip "$(surf_says "$r1" "$SURF_ND")"
# ...and it keeps that precedence when the failed inventory ALSO cost the
# payload a unit: an unmeasured fleet is not the dropped-box regression, so it
# must still skip by its own reason rather than red at the gate.
r1="$(surf app_surface_not_deployed "$SURF/fleet-inventory-unreadable-and-short.json" 4)"
t app-surface-204-unreadable-outranks-the-gate skip "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-unreadable-names-its-reason skip "$(surf_says "$r1" "the box inventory did not answer for: crew-b")"
# The gate must not red a correct fleet: a complete payload with no measured
# absence still skips, with the one reason that is now true of it.
r1="$(surf app_surface_not_deployed "$SURF/fleet-all-deployed.json" 4)"
t app-surface-204-no-such-box-skips skip "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-complete-fleet-skip-reason skip "$(surf_says "$r1" "every one of the 4 roster boxes is deployed")"

# --- #218: `crew up --dry-run` names every box and touches nothing -------
printf 'crew-a: WOULD hire (currently: 2026-08-01T00:00Z)\ncrew-b: WOULD hire (currently: 2026-08-01T00:00Z)\ncrew-c: WOULD create (grok/triage)\ncrew-c: WOULD hire (new box — engine crew@0.1.2, cron armed)\ncrew-d: WOULD start\ncrew-d: WOULD SKIP — not converged; crew hire crew-d would refuse\n\nup --dry-run: 1 would be created, 1 started, 3 hired\n' \
  >"$SURF/up-dry.txt"
grep -v '^crew-d: ' "$SURF/up-dry.txt" >"$SURF/up-dry-silent.txt"
grep -v '^up --dry-run: ' "$SURF/up-dry.txt" >"$SURF/up-dry-no-summary.txt"
printf 'roster deadbeef\nboxes crew-a:running,crew-b:running,crew-d:stopped\ncron crew-a c0ffee\ncron crew-b c0ffee\ncron crew-d c0ffee\n' \
  >"$SURF/before.fp"
cp "$SURF/before.fp" "$SURF/after.fp"
# The one thing --dry-run promises never to do: a box that did not exist before
# the command exists after it.
sed 's/^boxes .*/boxes crew-a:running,crew-b:running,crew-c:running,crew-d:stopped/' \
  "$SURF/before.fp" >"$SURF/after-created.fp"
sed 's/^boxes .*/boxes UNREADABLE/' "$SURF/before.fp" >"$SURF/before-unreadable.fp"
# A component that did not answer, marked as such rather than hashed. Both of
# these used to be INVISIBLE: a failed `box_read` was piped straight into
# sha256sum, so two failed reads produced the same hash of the empty string and
# compared equal — "unchanged" over a crontab nobody read.
sed 's/^cron crew-d .*/cron crew-d UNREADABLE/' "$SURF/before.fp" \
  >"$SURF/before-cron-unreadable.fp"
awk '{ $NF = "UNREADABLE"; print }' "$SURF/before.fp" \
  >"$SURF/before-all-unreadable.fp"
# ...and the box that answered and genuinely has no crontab. Its read succeeded,
# so it is a measured fact and must still compare: the fix must not turn every
# un-armed box into an unreadable one.
EMPTY_SHA='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
sed "s/^cron crew-d .*/cron crew-d $EMPTY_SHA/" "$SURF/before.fp" \
  >"$SURF/before-cron-empty.fp"
# One side read it, the other did not: there is no comparison to make, and the
# side that answered is not evidence about the side that did not.
sed 's/^cron crew-d .*/cron crew-d UNREADABLE/' "$SURF/before.fp" \
  >"$SURF/after-cron-unreadable.fp"
# A component that was there before and is gone after is movement, not silence.
grep -v '^cron crew-d ' "$SURF/before.fp" >"$SURF/after-box-gone.fp"

SURF_D0="crew up --dry-run exits 0"
SURF_DN="crew up --dry-run names a planned action"
SURF_DS="crew up --dry-run summarises"
SURF_DC="crew up --dry-run changed nothing"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-truthful-rc ok "$(surf_says "$r1" "$SURF_D0")"
t app-surface-218-truthful-per-box ok "$(surf_says "$r1" "$SURF_DN")"
t app-surface-218-truthful-summary ok "$(surf_says "$r1" "$SURF_DS")"
t app-surface-218-truthful-unchanged ok "$(surf_says "$r1" "$SURF_DC")"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-created.fp" 0)"
t app-surface-218-staged-created-a-box FAIL "$(surf_says "$r1" "$SURF_DC")"
r1="$(surf app_surface_dry_run "$SURF/up-dry-silent.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-staged-unnamed-box FAIL "$(surf_says "$r1" "$SURF_DN")"
r1="$(surf app_surface_dry_run "$SURF/up-dry-no-summary.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-staged-no-summary FAIL "$(surf_says "$r1" "$SURF_DS")"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after.fp" 1)"
t app-surface-218-nonzero-rc-red FAIL "$(surf_says "$r1" "$SURF_D0")"
# Half the fingerprint was never taken, so "unchanged" is split rather than
# claimed over a comparison that compared less than it says. Both fingerprints
# are the SAME FILE here, which is the point: identical failures are identical,
# and `diff` called that agreement.
SURF_DP="crew up --dry-run moved none of the"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-unreadable.fp" "$SURF/before-unreadable.fp" 0)"
t app-surface-218-unreadable-inventory-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-unreadable-inventory-still-compares ok "$(surf_says "$r1" "$SURF_DP")"
# The crontab half of the same defect, and the one with no marker at all before
# this: an unreachable box and a timed-out box both hashed to the empty string.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-cron-unreadable.fp" "$SURF/before-cron-unreadable.fp" 0)"
t app-surface-218-unreadable-crontab-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-unreadable-crontab-still-compares ok "$(surf_says "$r1" "$SURF_DP")"
# Nothing answered on either side. There is no partial claim left to make, so
# the partial `ok` must not be printed either.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-all-unreadable.fp" "$SURF/before-all-unreadable.fp" 0)"
t app-surface-218-nothing-readable-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-nothing-readable-claims-nothing absent "$(surf_says "$r1" "$SURF_DP")"
# One side answered and the other did not: still no comparison, and the side
# that answered is not evidence about the side that did not.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-cron-unreadable.fp" 0)"
t app-surface-218-one-sided-read-skips skip "$(surf_says "$r1" "$SURF_DC")"
# ...but a box that ANSWERED and has no crontab is a measured fact, and must
# still compare. The repair must not turn every un-armed box into an unread one.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-cron-empty.fp" "$SURF/before-cron-empty.fp" 0)"
t app-surface-218-empty-crontab-still-compares ok "$(surf_says "$r1" "$SURF_DC")"
# A component present before and absent after is movement, not silence — the
# shape a dry run that deleted something would leave.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-box-gone.fp" 0)"
t app-surface-218-component-vanished FAIL "$(surf_says "$r1" "$SURF_DC")"

# --- #308: an unanswered probe is unknown, never never-hired -------------
t app-surface-308-picks-the-silent-box crew-d \
  "$(surf app_surface_silent_box "$SURF/fleet.json")"
t app-surface-308-no-silent-box-to-ask '' \
  "$(surf app_surface_silent_box "$SURF/fleet-all-answered.json")"
printf 'box: crew-d\nengine: unknown — the box did not answer\n' >"$SURF/status-unknown.txt"
printf 'box: crew-d\nengine: not hired (no engine)\n'            >"$SURF/status-never-hired.txt"
printf 'box: crew-d\n'                                          >"$SURF/status-no-engine-line.txt"
SURF_S="an unanswered probe reads unknown"
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-unknown.txt" 0)"
t app-surface-308-truthful-unknown ok "$(surf_says "$r1" "$SURF_S")"
# The wrong repair: the operator is sent to `crew hire` for a box that is
# hired and not talking.
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-never-hired.txt" 0)"
t app-surface-308-staged-never-hired FAIL "$(surf_says "$r1" "$SURF_S")"
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-no-engine-line.txt" 2)"
t app-surface-308-no-engine-line-red FAIL "$(surf_says "$r1" "$SURF_S")"

# --- #345: `no build duty` names a cause and a count ---------------------
{ printf 'crew-a 12:00 heavy-duty/crew: no build duty (board empty)\n'
  printf 'crew-b 12:00 heavy-duty/crew: no build duty (slot held by #402; board holds 3 ready)\n'
  printf 'crew-d 12:00 heavy-duty/crew: no build duty (2 ready, 1 round(s) held by seen-ledger)\n'
} >"$SURF/nbd.txt"
printf 'crew-a 12:00 heavy-duty/crew: no build duty\n' >"$SURF/nbd-bare.txt"
: >"$SURF/nbd-empty.txt"
SURF_N="duty.log: every no build duty line names a cause"
r1="$(surf app_surface_no_build_duty "$SURF/nbd.txt")"
t app-surface-345-truthful-causes ok "$(surf_says "$r1" "$SURF_N")"
# The bare line #345 replaced: indistinguishable from the burial bug.
r1="$(surf app_surface_no_build_duty "$SURF/nbd-bare.txt")"
t app-surface-345-staged-bare-line FAIL "$(surf_says "$r1" "$SURF_N")"
r1="$(surf app_surface_no_build_duty "$SURF/nbd-empty.txt")"
t app-surface-345-nothing-logged-skips skip "$(surf_says "$r1" "no build duty names a cause")"

# --- the page halves: the walk's own named lines ------------------------
{ printf '  ok   floor: the canvas header paints the serving host version\n'
  printf '  ok   render: the engine tile carries its integrity verdict\n'
} >"$SURF/walk.out"
printf '  FAIL floor: the canvas header paints the serving host version\n' >"$SURF/walk-failed.out"
: >"$SURF/walk-never-reached.out"
SURF_W="page: the header renders"
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk.out")"
t app-surface-walk-line-present ok "$(surf_says "$r1" "$SURF_W")"
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk-failed.out")"
t app-surface-walk-line-failed FAIL "$(surf_says "$r1" "$SURF_W")"
# A walk that exits 0 having never reached the check proves nothing about it.
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk-never-reached.out")"
t app-surface-walk-never-reached FAIL "$(surf_says "$r1" "$SURF_W")"

# --- #312: disarmed is a decision, silent is an alarm --------------------
surf_page() {  # surf_page '<python mutating q>' → the page reader's payload
  python3 - "$1" <<'PY'
import json, sys
# `empty` is what drill/rehearsal-page-read.js reads off #emptyfloor: whether
# the panel is in the DOM at all, whether syncEmptyFloor has it shown, and its
# text. On a fleet with consoles drawn it is present and not shown, which is
# the shape the truthful fixture below carries.
q = {"live": True, "tiles": "4units3hired",
     "disarmed": ["crew-b"], "silent": ["crew-d"],
     "empty": {"present": True, "shown": False, "text": ""}}
exec(sys.argv[1])
print(json.dumps(q))
PY
}
# The empty floor as the page actually paints it (app.js:1681-1686), and the
# tile row that goes with a fleet where nothing is deployed: `hidden` is 4, so
# the hired tile renders, reading 0.
EMPTY_TEXT='NO BOX IS HIRED YET The fleet roster declares 4 boxes, and none of them is running an engine. A console appears here as its box is hired. crew hire <box>'
surf_page 'pass'                                     >"$SURF/page.json"
surf_page 'q["disarmed"], q["silent"] = [], ["crew-b"]' >"$SURF/page-alarms-a-decision.json"
surf_page 'q["silent"] = ["crew-b"]'                 >"$SURF/page-both-groups.json"
surf_page 'q["disarmed"] = ["crew-z"]'               >"$SURF/page-unknown-box.json"
surf_page 'q["disarmed"], q["silent"] = [], []'      >"$SURF/page-no-members.json"
surf_page 'q["live"] = False'                        >"$SURF/page-demo.json"
surf_page 'q["tiles"] = "3units3hired"'              >"$SURF/page-shrunk.json"
surf_page 'q["tiles"] = "4units"'                    >"$SURF/page-no-hired-tile.json"
surf_page 'q["tiles"] = "4units4hired"'              >"$SURF/page-furniture.json"
# The two dropped-member stages: a page that lists nobody wrongly, by listing
# nobody at all. Before both directions were asserted these PASSED.
surf_page 'q["silent"] = []'                         >"$SURF/page-drops-silent.json"
surf_page 'q["disarmed"] = []'                       >"$SURF/page-drops-disarmed.json"
# The page agreeing with a payload that calls crew-b silent, so the only thing
# left to disagree is `crew status`.
surf_page 'q["disarmed"], q["silent"] = [], ["crew-b", "crew-d"]' \
                                                     >"$SURF/page-b-silent.json"
# Two boxes the operator deliberately stopped, correctly grouped: the fleet the
# blind-set arity defect reds falsely when both are also logged out.
surf_page 'q["disarmed"], q["silent"] = ["crew-b", "crew-d"], []' \
                                                     >"$SURF/page-two-disarmed.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True, 'text': '''$EMPTY_TEXT'''}" \
                                                     >"$SURF/page-empty.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': False, 'shown': False, 'text': ''}" \
                                                     >"$SURF/page-empty-no-panel.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': False, 'text': '''$EMPTY_TEXT'''}" \
                                                     >"$SURF/page-empty-hidden.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True,
              'text': 'NO BOX IS HIRED YET The fleet roster declares 4 boxes.'}" \
                                                     >"$SURF/page-empty-no-verb.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True,
              'text': 'THE FLEET ROSTER IS EMPTY No box is declared. crew new <box>'}" \
                                                     >"$SURF/page-empty-wrong-verb.json"
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  disarmed\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status.txt"
# The same fleet, logged out. cli/crew:2123 gives a missing credential the note
# column outright, so the disarmed word never reaches it — the normal starting
# state on a drill host, and it must not read as a disagreement.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status-logged-out.txt"
# TWO boxes logged out, which is the arity that matters: the blind set was
# accumulated as a display string (`crew-b, crew-d`) and then tested token-wise,
# so every member but the last kept a comma and read as NOT blind — a false
# FAIL on a correct page, invisible with the one-box fixture above (codex-bot,
# claude-bot, #428). Creds-free is the normal starting state on a drill host and
# two quiet boxes is an ordinary fleet, so this is the shape that reds #400's
# round against a page that is right.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   convergence unknown\n'
} >"$SURF/status-both-blind.txt"
# ...and the same, with both blind boxes DISARMED rather than one of each, so
# the members that must not red are the ones the disarmed direction iterates.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   ⚠ log in: box shell crew-d\n'
} >"$SURF/status-two-disarmed-blind.txt"
# ...and the same fleet where the CLI simply does not agree: crew-b is armed
# and ticking as far as `crew status` can tell.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  2026-08-08T11:04Z reviewed #428\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status-b-armed.txt"

SURF_F="page: the state filter separates disarmed from silent"
SURF_T="page: the unit tile counts the declared roster"
SURF_E="page: an all-undeployed floor names the repair verb"
SURF_FC="page: the state filter agrees with crew status for every box"
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-truthful-split ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-204-page-truthful-tiles ok "$(surf_says "$r1" "$SURF_T")"
# Nothing was blind to `crew status`, so the reader's own caveat is not raised.
t app-surface-312-nothing-unclassifiable absent "$(surf_says "$r1" "$SURF_FC")"
# The load-bearing direction, and the whole of #312: a box the operator
# deliberately stopped counted in the alarm group.
r1="$(surf app_surface_page_groups "$SURF/page-alarms-a-decision.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-staged-decision-as-alarm FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-both-groups.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-both-groups-at-once FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-unknown-box.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-grouped-box-cli-never-saw FAIL "$(surf_says "$r1" "$SURF_F")"
# The other direction, which is the correction: a page that drops a genuinely
# silent box — or a genuinely disarmed one — has no member to be wrong about,
# and passed until the groups were compared as sets.
r1="$(surf app_surface_page_groups "$SURF/page-drops-silent.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-page-drops-a-silent-box FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-drops-disarmed.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-page-drops-a-disarmed-box FAIL "$(surf_says "$r1" "$SURF_F")"
# The two readers disagreeing, each way round. The payload calls crew-b
# disarmed and the CLI shows it ticking...
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-b-armed.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-cli-does-not-confirm-disarmed FAIL "$(surf_says "$r1" "$SURF_F")"
# ...and the CLI calls crew-b deliberately stopped while the payload has it in
# the alarm group, which is #312's original defect read from the other reader.
r1="$(surf app_surface_page_groups "$SURF/page-b-silent.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet-b-not-disarmed.json")"
t app-surface-312-cli-says-stopped-payload-does-not FAIL "$(surf_says "$r1" "$SURF_F")"
# A logged-out box: `crew status` cannot answer for it, so it is named in its
# own skip and the page-side verdict still stands. Counting it as a
# disagreement would red a correct page on every creds-free host.
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-logged-out.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-credential-note-does-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-credential-note-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# TWO blind boxes, one from each group — the cheaper reproduction, since the
# blind set is filled from the disarmed boxes before the silent ones, so the
# disarmed member is the one that carried the comma.
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-both-blind.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-two-blind-boxes-do-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-two-blind-boxes-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# ...and both of them DISARMED, which is the case put directly to the loop that
# tests blind membership. A correct page must skip here and not FAIL.
r1="$(surf app_surface_page_groups "$SURF/page-two-disarmed.json" "$SURF/status-two-disarmed-blind.txt" 4 crew-c 3 "$SURF/fleet-two-disarmed.json")"
t app-surface-312-two-blind-disarmed-do-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-two-blind-disarmed-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# The set is machine-readable and the message is a copy of it: both boxes are
# named, comma-joined, and neither naming nor membership depends on the other.
t app-surface-312-blind-skip-names-both skip "$(surf_says "$r1" "armed-ness would be in: crew-b, crew-d")"
r1="$(surf app_surface_page_groups "$SURF/page-no-members.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet-none-quiet.json")"
t app-surface-312-no-member-to-classify skip "$(surf_says "$r1" "$SURF_F")"
# The demo payload is not this host, so neither group may be read off it.
r1="$(surf app_surface_page_groups "$SURF/page-demo.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-demo-payload-skips skip "$(surf_says "$r1" "$SURF_F")"
t app-surface-204-demo-payload-skips skip "$(surf_says "$r1" "$SURF_T")"
t app-surface-204-demo-payload-skips-empty-floor skip "$(surf_says "$r1" "$SURF_E")"
r1="$(surf app_surface_page_groups "$SURF/page-shrunk.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-204-staged-shrunk-tile FAIL "$(surf_says "$r1" "$SURF_T")"
# Fully deployed: the count half still holds, and the hired tile is furniture.
r1="$(surf app_surface_page_groups "$SURF/page-no-hired-tile.json" "$SURF/status.txt" 4 '' 4 "$SURF/fleet.json")"
t app-surface-204-page-fully-deployed ok "$(surf_says "$r1" "$SURF_T")"
r1="$(surf app_surface_page_groups "$SURF/page-furniture.json" "$SURF/status.txt" 4 '' 4 "$SURF/fleet.json")"
t app-surface-204-page-permanent-hired-tile FAIL "$(surf_says "$r1" "$SURF_T")"
# A floor with a console drawn is not the empty-floor state, and the drill will
# not un-hire a box to reach it: skipped by name, never quietly passed.
t app-surface-204-empty-floor-skips-when-drawn skip "$(surf_says "$r1" "$SURF_E")"

# --- #204's other half: the floor with nothing on it ---------------------
# Four declared boxes, none deployed. The issue asks for this floor to name
# `crew hire` in as many words, and nothing here read it before.
SURF_ALLND="crew-a crew-b crew-c crew-d"
r1="$(surf app_surface_page_groups "$SURF/page-empty.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-names-crew-hire ok "$(surf_says "$r1" "$SURF_E")"
# The count half still holds on that floor: 4 declared, 0 with a console.
t app-surface-204-empty-floor-tiles ok "$(surf_says "$r1" "$SURF_T")"
# A blank stage with no words on it is the state #204 named as the defect.
r1="$(surf app_surface_page_groups "$SURF/page-empty-no-panel.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-no-panel FAIL "$(surf_says "$r1" "$SURF_E")"
# In the DOM but never shown is the same blank stage to an operator.
r1="$(surf app_surface_page_groups "$SURF/page-empty-hidden.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-hidden FAIL "$(surf_says "$r1" "$SURF_E")"
# It says how many boxes are declared and stops — the count without the next
# step, which is the half the issue calls a requirement on the fix.
r1="$(surf app_surface_page_groups "$SURF/page-empty-no-verb.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-no-repair-verb FAIL "$(surf_says "$r1" "$SURF_E")"
# `crew new` is the wrong verb for a roster that DOES declare boxes: they exist
# to be hired, and telling the operator to create more is the wrong repair.
r1="$(surf app_surface_page_groups "$SURF/page-empty-wrong-verb.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-wrong-verb FAIL "$(surf_says "$r1" "$SURF_E")"
# ...and it is the RIGHT verb when the roster declares nothing at all, which is
# the other branch syncEmptyFloor renders.
r1="$(surf app_surface_page_groups "$SURF/page-empty-wrong-verb.json" "$SURF/status.txt" 0 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-roster-names-crew-new ok "$(surf_says "$r1" "$SURF_E")"

# --- rehearsal phase 0: acquisition failures abort before checks (#27) --
P0SHIM="$TMP/phase0-bin"
P0HOME="$TMP/phase0-home"
P0LOG="$TMP/phase0-box.log"
mkdir -p "$P0SHIM" "$P0HOME"
# shellcheck disable=SC2016  # fixture expands state at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0LOG"\ncase "$1" in\n  list) printf "[]\\n" ;;\n  new|exec) exit 0 ;;\n  *) exit 2 ;;\nesac\n' >"$P0SHIM/box"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0SHIM/gh"
chmod +x "$P0SHIM/box" "$P0SHIM/gh"
: >"$P0LOG"

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

# --tree is a promise that SOURCE_SHA identifies the tree the operator means
# to drill, including the committed ref phase 1 installs (#183). Refuse every
# dirty shape before the first box operation and show the paths and reason.
P0TREE="$TMP/phase0-tree"
mkdir -p "$P0TREE/shared/test" "$P0TREE/cli"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0TREE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$P0TREE/shared/test/run.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0TREE/cli/crew"
printf '0.0.0-test\n' >"$P0TREE/VERSION"
chmod +x "$P0TREE/shared/install.sh" "$P0TREE/shared/test/run.sh" "$P0TREE/cli/crew"
git -C "$P0TREE" init -q
git -C "$P0TREE" add .
git -C "$P0TREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture

: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
case "$p0out" in *"has uncommitted changes"*) r2=refused ;; *) r2=passed-guard ;; esac
t rehearsal-clean-tree-passes-guard passed-guard "$r2"
if grep -Eq '^(list|new) ' "$P0LOG"; then r2=reached-box; else r2=stopped-early; fi
t rehearsal-clean-tree-reaches-box reached-box "$r2"

printf '# dirty shared\n' >>"$P0TREE/shared/install.sh"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-shared-rc 1 "$r1"
case "$p0out" in
  *"shared/install.sh"*"SOURCE_SHA must name the tree"*"phase 1 installs"*"crew hire --ref"*) r2=attributed ;;
  *) r2=missing ;;
esac
t rehearsal-dirty-shared-attributed attributed "$r2"
t rehearsal-dirty-shared-before-box 0 "$(wc -l <"$P0LOG")"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal-all.sh" --roles reviewer --tree "$P0TREE" \
    --quick --no-app --no-config-drill --no-install-drill 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-all-passes-dirty-refusal-rc 1 "$r1"
case "$p0out" in *"has uncommitted changes"*"FAIL       reviewer"*) r2=passed ;; *) r2=swallowed ;; esac
t rehearsal-all-passes-dirty-refusal passed "$r2"

git -C "$P0TREE" restore shared/install.sh
printf '# dirty cli\n' >>"$P0TREE/cli/crew"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-cli-rc 1 "$r1"
case "$p0out" in *"cli/crew"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-cli-names-path named "$r2"
t rehearsal-dirty-cli-before-box 0 "$(wc -l <"$P0LOG")"

git -C "$P0TREE" restore cli/crew
printf '0.0.1-staged\n' >"$P0TREE/VERSION"
git -C "$P0TREE" add VERSION
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-staged-rc 1 "$r1"
case "$p0out" in *"VERSION"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-staged-names-path named "$r2"
t rehearsal-dirty-staged-before-box 0 "$(wc -l <"$P0LOG")"

git -C "$P0TREE" restore --staged --worktree VERSION
printf 'untracked\n' >"$P0TREE/NEW-FILE"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-untracked-rc 1 "$r1"
case "$p0out" in *"NEW-FILE"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-untracked-names-path named "$r2"
t rehearsal-dirty-untracked-before-box 0 "$(wc -l <"$P0LOG")"
rm -f "$P0TREE/NEW-FILE"

P0NONGIT="$TMP/phase0-not-git"
mkdir -p "$P0NONGIT/shared/test"
printf 'fixture\n' >"$P0NONGIT/shared/install.sh"
printf 'fixture\n' >"$P0NONGIT/shared/test/run.sh"
printf 'fixture\n' >"$P0NONGIT/VERSION"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0NONGIT" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-non-git-tree-rc 1 "$r1"
case "$p0out" in *"must be a git checkout with a clean working tree"*) r2=owned ;; *) r2=raw ;; esac
t rehearsal-non-git-tree-owned-error owned "$r2"
t rehearsal-non-git-tree-before-box 0 "$(wc -l <"$P0LOG")"

# A missing host git gets its own preflight reason, before the source guard or
# any box operation can turn it into a misleading checkout error.
P0NOGITSHIM="$TMP/phase0-no-git-bin"
mkdir -p "$P0NOGITSHIM"
ln -s "$(command -v dirname)" "$P0NOGITSHIM/dirname"
ln -s "$P0SHIM/box" "$P0NOGITSHIM/box"
ln -s "$P0SHIM/gh" "$P0NOGITSHIM/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0NOGITSHIM/jq"
chmod +x "$P0NOGITSHIM/jq"
: >"$P0LOG"
if p0out="$(PATH="$P0NOGITSHIM" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  /usr/bin/bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-missing-git-rc 1 "$r1"
case "$p0out" in *"git not found on the host"*) r2=owned ;; *) r2=misattributed ;; esac
t rehearsal-missing-git-owned-error owned "$r2"
t rehearsal-missing-git-before-box 0 "$(wc -l <"$P0LOG")"

# Remote/ref acquisition already uses git clone, but must not inherit the
# --tree-only clean-status probe.
P0GSHIM="$TMP/phase0-git-bin"
P0GITLOG="$TMP/phase0-git.log"
REAL_GIT="$(command -v git)"
mkdir -p "$P0GSHIM"
# shellcheck disable=SC2016  # expanded by the shim at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0GITLOG"\ncase " $* " in\n  *" status "*)\n    if [ "${P0GIT_FAIL_STATUS:-0}" -eq 1 ]; then echo "fixture status failure" >&2; exit 42; fi\n    if [ "${P0GIT_WARN_STATUS:-0}" -eq 1 ]; then echo "fixture status warning" >&2; fi ;;\nesac\nexec "$REAL_GIT" "$@"\n' >"$P0GSHIM/git"
chmod +x "$P0GSHIM/git"

# A warning from a successful status is not a dirty path and must not make a
# clean checkout refuse. A failed status retains its stderr in crew's error.
: >"$P0GITLOG"
: >"$P0LOG"
if p0out="$(PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" P0GIT_WARN_STATUS=1 \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
case "$p0out" in *"has uncommitted changes"*) r2=refused ;; *) r2=passed-guard ;; esac
t rehearsal-status-warning-is-not-dirty passed-guard "$r2"
if grep -Eq '^(list|new) ' "$P0LOG"; then r2=reached-box; else r2=stopped-early; fi
t rehearsal-status-warning-reaches-box reached-box "$r2"

: >"$P0GITLOG"
: >"$P0LOG"
if p0out="$(PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" P0GIT_FAIL_STATUS=1 \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-status-failure-rc 1 "$r1"
case "$p0out" in *"could not inspect"*"fixture status failure"*) r2=owned ;; *) r2=missing ;; esac
t rehearsal-status-failure-owned-error owned "$r2"
t rehearsal-status-failure-before-box 0 "$(wc -l <"$P0LOG")"

P0REMOTE="$TMP/phase0-remote.git"
P0REF="$(git -C "$P0TREE" branch --show-current)"
git clone -q --bare "$P0TREE" "$P0REMOTE"
: >"$P0GITLOG"
: >"$P0LOG"
PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" \
  bash "$ROOT/drill/rehearsal.sh" --remote "$P0REMOTE" \
    --ref "$P0REF" --quick >/dev/null 2>&1 || true
if grep -Eq '(^|[[:space:]])status([[:space:]]|$)' "$P0GITLOG"; then r2=probed; else r2=untouched; fi
t rehearsal-remote-skips-clean-tree-probe untouched "$r2"

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

# The suite/reference extraction, archive selection and phase-0 verifier are
# one contract: each can drift independently, and empty inputs never cover it.
P0COVER_SUITE="$TMP/phase0-cover-suite.sh"
P0COVER_REHEARSAL="$TMP/phase0-cover-rehearsal.sh"
cp "$HERE/common.sh" "$P0COVER_SUITE"
cp "$ROOT/drill/rehearsal.sh" "$P0COVER_REHEARSAL"
# shellcheck disable=SC2016  # write a literal synthetic suite dependency
printf '%s%s\n' '$ROOT' '/postmortems' >>"$P0COVER_SUITE"
t phase0-new-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/common.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a literal brace-form suite dependency
printf '%s%s\n' '${ROOT}' '/postmortems/report.md' >>"$P0COVER_SUITE"
t phase0-braced-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/common.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a dependency beneath the excluded subtree
printf '%s%s\n' '$ROOT' '/fleet-floor/dev/assets.json' >>"$P0COVER_SUITE"
t phase0-excluded-suite-path-refused excluded:fleet-floor/dev \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/common.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # replace the block with the literal legacy command
sed -i '/BEGIN phase-0 archive selection/,/END phase-0 archive selection/c\
# BEGIN phase-0 archive selection\
tar czf "$ENGINE_ARCHIVE" -C "$SOURCE_TREE" shared VERSION\
# END phase-0 archive selection' "$P0COVER_REHEARSAL"
t phase0-legacy-archive-selection-refused archive:archive-selection-mismatch \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
: >"$P0COVER_SUITE"
t phase0-empty-suite-root-list-refused empty-suite-roots \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
: >"$P0COVER_REHEARSAL"
t phase0-empty-verified-root-list-refused empty-verified-roots \
  "$(phase0_coverage_result "$HERE/common.sh" "$P0COVER_REHEARSAL")"

# Exercise the in-box verifier, not just its static root list. The fixture is
# a valid clean git tree with one required root deliberately absent; phase 0
# must attribute that truncation before it can run the staged suite.
P0VERIFYTREE="$TMP/phase0-verify-tree"
P0VERIFYHOME="$TMP/phase0-verify-home"
P0VERIFYSHIM="$TMP/phase0-verify-bin"
mkdir -p "$P0VERIFYTREE"/{.ceremony,.github,cli,drill,fleet-floor,shared/test} \
  "$P0VERIFYHOME" "$P0VERIFYSHIM"
printf 'fixture\n' >"$P0VERIFYTREE/.ceremony/marker"
printf 'fixture\n' >"$P0VERIFYTREE/.github/marker"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0VERIFYTREE/cli/crew"
printf 'fixture\n' >"$P0VERIFYTREE/drill/marker"
printf 'fixture\n' >"$P0VERIFYTREE/fleet-floor/marker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0VERIFYTREE/install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0VERIFYTREE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$P0VERIFYTREE/shared/test/run.sh"
printf '0.0.0-test\n' >"$P0VERIFYTREE/VERSION"
chmod +x "$P0VERIFYTREE/cli/crew" "$P0VERIFYTREE/install.sh" \
  "$P0VERIFYTREE/shared/install.sh" "$P0VERIFYTREE/shared/test/run.sh"
git -C "$P0VERIFYTREE" init -q
git -C "$P0VERIFYTREE" add .
git -C "$P0VERIFYTREE" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm fixture
# shellcheck disable=SC2016  # the shim receives and executes rehearsal's script argument
printf '%s\n' '#!/usr/bin/env bash
case "$1" in
  list) printf "[]\n" ;;
  new) exit 0 ;;
  exec)
    shift 5
    HOME="$P0VERIFYHOME" bash -lc "$1" ;;
  *) exit 2 ;;
esac' >"$P0VERIFYSHIM/box"
chmod +x "$P0VERIFYSHIM/box"
if p0out="$(PATH="$P0VERIFYSHIM:$P0SHIM:$PATH" P0VERIFYHOME="$P0VERIFYHOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0VERIFYTREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t phase0-truncated-tree-rc 1 "$r1"
case "$p0out" in *"transferred engine failed verification"*) r1=attributed ;; *) r1=missing ;; esac
t phase0-truncated-tree-attributed attributed "$r1"
case "$p0out" in *"fixture tests green"*) r1=ran-suite ;; *) r1=stopped-before-suite ;; esac
t phase0-truncated-tree-stops-before-suite stopped-before-suite "$r1"

# --- install-drill step 9: engine/cron/tick survival, both paths (#341) --
# The tick leg used to demand an unchanged, NON-EMPTY last duty.log line. A box
# hired seconds earlier has no duty.log at all — it is written at the first
# cron boundary — so on the drill's own standalone path the assertion failed by
# construction. Observed on crew-drill-011, 2026-08-03: the drill read an empty
# tail and redded, and the box's first tick fired 14s later, AFTER the console
# removal.
#
# These fixtures drive the predicate itself, not a host: a fake box home, the
# crontab shim above, and a clock the wait spends instead of the suite's wall
# time. As with the rehearsal-safety block above, the caller's bx() is what
# makes that possible; each block defines its own and nothing after either one
# calls it.
SHOME="$TMP/survival-home"
SDUTY="$SHOME/duty"
SCRON="$TMP/survival-crontab"
SURVIVAL_CLOCK=0
SURVIVAL_TICK_AT=""
SURVIVAL_RESTAMP_AT=""
SURVIVAL_DISARM_AT=""

# survival_reset <engine> <armed|disarmed> [last duty.log line]
# The third argument is the whole difference between the two paths: a borrowed
# box arrives with tick history, a freshly hired one does not.
survival_reset() {
  rm -rf "$SHOME"; mkdir -p "$SDUTY/bin"
  printf '%s\n' "$1" >"$SDUTY/VERSION"
  : >"$SCRON"
  if [ "$2" = armed ]; then
    printf '*/5 * * * * %s/bin/tick.sh\n17 2 * * * unrelated-job\n' "$SDUTY" >"$SCRON"
  fi
  [ -z "${3:-}" ] || printf '%s\n' "$3" >"$SDUTY/duty.log"
  SURVIVAL_CLOCK=0
  SURVIVAL_TICK_AT=""
  SURVIVAL_RESTAMP_AT=""
  SURVIVAL_DISARM_AT=""
}

bx() { HOME="$SHOME" PATH="$ISHIM" CRON_STATE="$SCRON" bash -c "$1"; }
# shellcheck source=drill/install-survival.sh
source "$ROOT/drill/install-survival.sh"
# The two seams, taken over: the clock only moves when the predicate sleeps, so
# the real 300+90s budget is exercised in no wall time at all — and the tick
# lands when the fixture's boundary strikes, the way a surviving engine's does.
# The two *_AT breakages are how a box is made to lose engine or cron INSIDE the
# wait window, which is the only place the second engine/cron read can see them.
install_survival_now() { printf '%s\n' "$SURVIVAL_CLOCK"; }
install_survival_sleep() {
  SURVIVAL_CLOCK=$((SURVIVAL_CLOCK + $1))
  if [ -n "$SURVIVAL_TICK_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_TICK_AT" ]; then
    printf 'tick %s duty run end\n' "$SURVIVAL_TICK_AT" >>"$SDUTY/duty.log"
  fi
  if [ -n "$SURVIVAL_RESTAMP_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_RESTAMP_AT" ]; then
    printf 'crew@9.9.9-someone-elses\n' >"$SDUTY/VERSION"
  fi
  if [ -n "$SURVIVAL_DISARM_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_DISARM_AT" ]; then
    : >"$SCRON"
  fi
}
# Which surfaces the detail blames, as a list — the D2 assertion in one line.
survival_surfaces() {
  printf '%s' "$INSTALL_SURVIVAL_DETAIL" | tr ';' '\n' |
    sed 's/^ *//;s/:.*//' | tr '\n' ',' | sed 's/,$//'
}

# The budget is the box's own schedule, not a constant this file guesses at.
t survival-budget-reads-the-cron-period 150 "$(install_survival_budget '*/1 * * * * /h/duty/bin/tick.sh')"
t survival-budget-default-when-unparsable 390 "$(install_survival_budget '17 2 * * * /h/duty/bin/tick.sh')"
t survival-budget-default-when-cron-empty 390 "$(install_survival_budget '')"

# --- the fresh-box path: no duty.log before the removal
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
t survival-fresh-box-takes-the-wait-path fresh "$INSTALL_SURVIVAL_PATH"
t survival-fresh-box-label-describes-arrival "the box arrived with no duty.log" "$INSTALL_SURVIVAL_PATH_LABEL"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-passes-on-the-observed-tick survived "$r1"
t survival-fresh-box-reports-the-new-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"
[ "$SURVIVAL_CLOCK" -le 390 ] && r1=bounded || r1=OVERRAN
t survival-fresh-wait-stops-at-one-boundary-plus-grace bounded "$r1"

# The mutation #192's precedent requires: step 9's leg as it read before this
# fix — one read, no wait — against the same fixture that just passed.
SURVIVAL_WAIT="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_wait_for_tick() {
  INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"; [ -n "$INSTALL_SURVIVAL_TICK" ]
}
install_survival_check && r1=survived || r1=red
t survival-deleting-the-wait-reds-the-fresh-box red "$r1"
t survival-deleting-the-wait-still-names-tick tick "$(survival_surfaces)"
eval "$SURVIVAL_WAIT"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-restoring-the-wait-passes-the-same-fixture survived "$r1"

# A fresh box whose engine never ticks again is the failure this path exists to
# catch, and it must be reported as the tick — not as the removal transcript.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-fresh-box-with-no-tick-reds red "$r1"
t survival-fresh-box-with-no-tick-names-tick tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in *"duty.log"*"390s"*) r1=says-what-it-read ;; *) r1=OPAQUE ;; esac
t survival-fresh-box-with-no-tick-says-what-it-read says-what-it-read "$r1"
t survival-fresh-box-with-no-tick-waited-the-budget 390 "$SURVIVAL_CLOCK"

# --- a tick that lands DURING the uninstall proves nothing
# The wait measures against the log as the COMPLETED removal left it, not the
# empty read taken before it. A boundary striking while `crew uninstall` runs
# writes a line the console was still installed for; accepting it would pass
# step 9 at zero elapsed time on a box whose engine never ticked again.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
t survival-uninstall-tick-still-takes-the-wait-path fresh "$INSTALL_SURVIVAL_PATH"
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-tick-during-uninstall-alone-reds red "$r1"
t survival-tick-during-uninstall-names-tick tick "$(survival_surfaces)"
t survival-tick-during-uninstall-waits-the-budget 390 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"tick during uninstall"*"already there"*) r1=says-the-stale-line ;; *) r1=OPAQUE ;;
esac
t survival-tick-during-uninstall-says-the-stale-line says-the-stale-line "$r1"

# …and that same box passes the moment the engine ticks after the removal.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-tick-during-uninstall-then-a-real-tick-passes survived "$r1"
t survival-tick-during-uninstall-reports-the-later-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"

# The mutation the case exists for: the baseline-blind wait — first non-empty
# line wins — takes the during-uninstall line as its evidence and concludes in
# no time at all, which is the false pass this fixture must catch.
SURVIVAL_WAIT_PRE="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    [ -z "$INSTALL_SURVIVAL_TICK" ] || return 0
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}
install_survival_check && r1=survived || r1=red
t survival-baseline-blind-wait-false-passes-the-uninstall-tick survived "$r1"
t survival-baseline-blind-wait-spends-nothing 0 "$SURVIVAL_CLOCK"
eval "$SURVIVAL_WAIT_PRE"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-restoring-the-baseline-reds-the-same-fixture red "$r1"

# --- the wait window is not a blind spot
# Up to a whole cron period passes inside the wait, so engine and cron are read
# again on the other side of it: a box that loses either one in there did not
# outlive its console, and the detail names the read that saw it go.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
SURVIVAL_RESTAMP_AT=305
install_survival_check && r1=survived || r1=red
t survival-engine-restamped-inside-the-wait-reds red "$r1"
t survival-engine-restamped-inside-the-wait-names-engine engine "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"after the 390s tick wait"*) r1=says-which-read ;; *) r1=OPAQUE ;;
esac
t survival-engine-restamped-inside-the-wait-says-which-read says-which-read "$r1"

survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
SURVIVAL_DISARM_AT=305
install_survival_check && r1=survived || r1=red
t survival-cron-disarmed-inside-the-wait-reds red "$r1"
t survival-cron-disarmed-inside-the-wait-names-cron cron "$(survival_surfaces)"

# A surface that missed before the wait is reported once, at the read that saw
# it — the second pass must not double it into the detail.
survival_reset '' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-engine-gone-reds red "$r1"
t survival-fresh-box-engine-gone-reported-once engine "$(survival_surfaces)"

# --- the borrowed-box context: history, with the same post-removal wait
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
t survival-borrowed-box-records-history-context history "$INSTALL_SURVIVAL_PATH"
t survival-borrowed-box-label-describes-arrival "the box arrived with tick history" "$INSTALL_SURVIVAL_PATH_LABEL"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-newer-post-removal-line-passes survived "$r1"
t survival-borrowed-box-reports-the-new-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"
[ "$SURVIVAL_CLOCK" -le 390 ] && r1=bounded || r1=OVERRAN
t survival-borrowed-wait-stops-at-one-boundary-plus-grace bounded "$r1"

# A borrowed box whose engine dies with its console spends the full budget and
# reds. This explicitly inverts the old borrowed-box pass on an unchanged log.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-unchanged-log-now-reds red "$r1"
t survival-borrowed-box-unchanged-log-names-tick tick "$(survival_surfaces)"
t survival-borrowed-box-unchanged-log-waits-the-budget 390 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"2026-08-03T15:14:01Z duty run end"*"box arrived with"*) r1=names-arrival-tick ;; *) r1=OPAQUE ;;
esac
t survival-borrowed-box-failure-retains-pre-removal-tick names-arrival-tick "$r1"

survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
rm -f "$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-emptied-log-still-reds red "$r1"

# A tick written during uninstall is the post-removal baseline, not survival
# evidence. The borrowed context must exclude it exactly as the fresh one does.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-borrowed-tick-during-uninstall-alone-reds red "$r1"
t survival-borrowed-tick-during-uninstall-names-tick tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"2026-08-03T15:14:01Z duty run end"*"2026-08-03T15:19:01Z tick during uninstall"*) r1=says-both-lines ;; *) r1=OPAQUE ;;
esac
t survival-borrowed-tick-during-uninstall-says-both-lines says-both-lines "$r1"

# …and that same borrowed box passes once a later boundary proves survival.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-borrowed-tick-during-uninstall-then-real-tick-passes survived "$r1"

# Restore the old byte-identical borrowed-path comparison. It reds the healthy
# fixture above as soon as it sees the uninstall-boundary line and never waits
# for the later proof. This is the reported flake's negative mutation.
SURVIVAL_WAIT_HISTORY="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_wait_for_tick() {
  INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
  [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" = "$INSTALL_SURVIVAL_TICK_PRE" ]
}
install_survival_check && r1=survived || r1=red
t survival-restoring-borrowed-byte-identical-compare-reds red "$r1"
eval "$SURVIVAL_WAIT_HISTORY"

# Pointing the wait at TICK_PRE instead of the post-removal read accepts the
# during-uninstall line at zero elapsed time. The correct baseline reds it.
SURVIVAL_WAIT_POST="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    if [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" != "$INSTALL_SURVIVAL_TICK_PRE" ]; then
      return 0
    fi
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}
install_survival_check && r1=survived || r1=red
t survival-borrowed-pre-removal-baseline-false-passes survived "$r1"
t survival-borrowed-pre-removal-baseline-spends-nothing 0 "$SURVIVAL_CLOCK"
eval "$SURVIVAL_WAIT_POST"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-restoring-borrowed-post-removal-baseline-reds red "$r1"

# --- the real survival failures, on the surfaces they happened to
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
: >"$SCRON"
install_survival_check && r1=survived || r1=red
t survival-cron-removed-by-hand-reds red "$r1"
t survival-cron-removed-by-hand-names-cron-first cron,tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in *"tick.sh"*) r1=says-what-it-read ;; *) r1=OPAQUE ;; esac
t survival-cron-removed-says-what-it-read says-what-it-read "$r1"
t survival-borrowed-box-cron-removed-does-not-wait 0 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in *"tick: not waited for"*) r1=says-no-wait ;; *) r1=OPAQUE ;; esac
t survival-borrowed-box-cron-removed-says-no-wait says-no-wait "$r1"
case "$INSTALL_SURVIVAL_DETAIL" in *"2026-08-03T15:14:01Z duty run end"*) r1=names-arrival-tick ;; *) r1=OPAQUE ;; esac
t survival-borrowed-box-cron-removed-retains-pre-removal-tick names-arrival-tick "$r1"

# The same removal on a fresh box: no boundary can strike, so the wait is not
# entered at all and the report says so rather than blaming the tick alone.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
: >"$SCRON"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-cron-removed-reds red "$r1"
t survival-fresh-box-cron-removed-names-cron-first cron,tick "$(survival_surfaces)"
t survival-fresh-box-cron-removed-does-not-wait 0 "$SURVIVAL_CLOCK"

survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf 'crew@9.9.9-someone-elses\n' >"$SDUTY/VERSION"
install_survival_check && r1=survived || r1=red
t survival-engine-restamped-reds red "$r1"
t survival-engine-restamped-names-engine-first engine,tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"crew@9.9.9-someone-elses"*"crew@0.0.0-drill-b"*) r1=says-both ;; *) r1=OPAQUE ;;
esac
t survival-engine-restamped-says-read-and-expected says-both "$r1"

survival_reset '' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-engine-gone-reds red "$r1"
t survival-engine-gone-names-engine-first engine,tick "$(survival_surfaces)"

# The driver reads the predicate from here and reports the surfaces, so the
# transcript that misled #341 cannot come back as the evidence.
if grep -qF 'install_survival_before' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'install_survival_check' "$ROOT/drill/install-drill.sh"; then r1=wired; else r1=MISSING; fi
t survival-driver-uses-the-shared-predicate wired "$r1"
# shellcheck disable=SC2016  # the driver's literal line is the pattern
if grep -qF '($INSTALL_SURVIVAL_PATH_LABEL)' "$ROOT/drill/install-drill.sh"; then r1=context; else r1=LOST; fi
t survival-driver-pass-line-keeps-arrival-context context "$r1"
# shellcheck disable=SC2016  # the driver's literal line is the pattern
if grep -qF 'fail "step 9: positive engine/cron/tick survival observation" "$INSTALL_SURVIVAL_DETAIL"' \
     "$ROOT/drill/install-drill.sh"; then r1=surfaces; else r1=TRANSCRIPT; fi
t survival-driver-fails-with-the-surfaces surfaces "$r1"
if grep -qE 'tick_(pre_remove|after)' "$ROOT/drill/install-drill.sh"; then r1=INLINE; else r1=extracted; fi
t survival-driver-keeps-no-inline-copy extracted "$r1"

# --- drill/install-payload.sh: #365's payload rule, per channel (#421) ----
# Same shape as the survival block above: the predicate is driven against
# fixtures rather than a host — a stub installer, stub guards, and installed
# trees built by hand. No bx() is needed at all here, because the thing under
# assertion is an ordinary directory: install-drill.sh's installs are
# host-side, into its own scratch CREW_HOME.
#
# One convention departs from the rest of this file: every hyphenated verdict
# word assigned below is QUOTED. shellcheck reads `r2=a-b` as arithmetic
# (SC2100) once it has seen `a` as a variable name, and under -x it keeps the
# names of every file this one sources — so whether a bare word here parses
# depends on a declaration in some other file. `roots-still-green` was armed by
# this block's own `local roots`; `first-upgrade-artifact` was armed from
# outside the branch entirely, when #432 landed a `first=` in
# drill/rehearsal-resume.sh, which line 324 sources. ci-shell runs shellcheck
# unfiltered, so an info-level finding is a red build. Quoting says "literal"
# and cannot be armed by a name this file never mentions.
PHOME="$TMP/payload"

# payload_src <declared roots, space separated> <bound in guard A> <bound in B>
# A stub source tree: the installer's list and the two offline guards that
# spell the size bound, in the shape install-payload.sh reads them.
payload_src() {
  local roots p; read -ra roots <<<"$1"
  rm -rf "$PHOME/src"; mkdir -p "$PHOME/src/shared/test"
  { printf 'PAYLOAD_EXCLUDED_PATHS=(\n'
    for p in "${roots[@]}"; do [ -z "$p" ] || printf '  %s  # a reason\n' "$p"; done
    printf ')\n'
  } >"$PHOME/src/install.sh"
  # shellcheck disable=SC2016  # `$kb` is the guard's literal text
  [ "$2" = - ] || printf 'if [ "$kb" -lt %s ]; then\n' "$2" >"$PHOME/src/shared/test/install-lifecycle.sh"
  [ "$2" = - ] && : >"$PHOME/src/shared/test/install-lifecycle.sh"
  # shellcheck disable=SC2016  # same
  [ "$3" = - ] || printf 'if [ "$kb" -lt %s ]; then\n' "$3" >"$PHOME/src/shared/test/artifact.sh"
  [ "$3" = - ] && : >"$PHOME/src/shared/test/artifact.sh"
  return 0
}

# payload_tree <name> <root to plant, or -> <filler KiB> → echoes the path
payload_tree() {
  local dir="$PHOME/trees/$1"
  rm -rf "$dir"; mkdir -p "$dir/cli"
  [ "$2" = - ] || mkdir -p "$dir/$2"
  head -c "$(( $3 * 1024 ))" /dev/zero >"$dir/filler"
  printf '%s\n' "$dir"
}

# The predicate's own report, captured. A subshell supplies the pass()/fail()
# the caller owes it, so neither name escapes into the suite around it.
payload_run() {  # <source tree> <installed tree>
  ( pass() { printf 'PASS %s\n' "$1"; }
    fail() { printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
    # shellcheck source=drill/install-payload.sh
    . "$ROOT/drill/install-payload.sh"
    install_payload_assert payload "$1" "$2" )
}
payload_verdict() { case "$1" in *FAIL*) printf 'red\n' ;; *) printf 'green\n' ;; esac; }

CLEAN_ROOTS='.git drill shared/test fleet-floor/dev fleet-floor/test'

# A tree that ships none of them, well under the bound.
#
# The expectation for the reported size is `du -skL`'s own reading of this
# tree, never a hard-coded window: du charges directory inodes per filesystem,
# so the two directories below cost 0 blocks on the tmpfs a box's $TMP usually
# is and 4 KiB each on a runner's ext4 — 64 KiB here and 72 KiB there, for the
# same fixture. A band is green on one and red on the other for a reason that
# is not the predicate's. Equality against du is also the stronger assertion:
# it pins the line to the measurement rather than to a range a constant could
# sit in, and payload-two-trees-report-different-sizes below closes the last
# way a constant could still satisfy it.
payload_src "$CLEAN_ROOTS" 3072 3072
payload_dir="$(payload_tree clean - 64)"
payload_kb="$(du -skL "$payload_dir" | cut -f1)"
r1="$(payload_run "$PHOME/src" "$payload_dir")"
t payload-clean-tree-passes green "$(payload_verdict "$r1")"
case "$r1" in *"is $payload_kb KiB, within the 3072 KiB bound"*) r2=measured ;; *) r2="$r1" ;; esac
t payload-pass-line-carries-the-measured-size measured "$r2"
case "$r1" in *"none of the installer's 5 excluded roots"*) r2=counted ;; *) r2="$r1" ;; esac
t payload-pass-line-counts-the-roots-it-walked counted "$r2"

# MUST FAIL: a tree carrying fleet-floor/dev reds, NAMING that path — and it is
# not a size finding, so the size assertion beside it still passes. A leg that
# only redded on the bound would report "over budget" and leave the operator to
# work out which root came back.
r1="$(payload_run "$PHOME/src" "$(payload_tree fat-dev fleet-floor/dev 64)")"
t payload-dev-root-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-dev-root-names-the-path named "$r2"
case "$r1" in *"PASS payload: installed tree is"*) r2='size-still-green' ;; *) r2="$r1" ;; esac
t payload-dev-root-is-not-a-size-finding size-still-green "$r2"

# MUST FAIL: under the bound and still carrying a test root. This is the case a
# size-only check passes.
r1="$(payload_run "$PHOME/src" "$(payload_tree small-test shared/test 64)")"
t payload-test-root-under-budget-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: shared/test"*) r2=named ;; *) r2="$r1" ;; esac
t payload-test-root-under-budget-names-the-path named "$r2"

# …and the mirror: no excluded root anywhere, and fat. The bound is the only
# thing that catches the next big directory nobody thought to exclude.
payload_fat_dir="$(payload_tree fat-clean - 4096)"
payload_fat_kb="$(du -skL "$payload_fat_dir" | cut -f1)"
r1="$(payload_run "$PHOME/src" "$payload_fat_dir")"
t payload-over-bound-reds red "$(payload_verdict "$r1")"
case "$r1" in *"within the 3072 KiB bound — measured $payload_fat_kb KiB"*) r2='says-both' ;; *) r2="$r1" ;; esac
t payload-over-bound-names-bound-and-measurement says-both "$r2"
# Two trees, two different readings: whatever the filesystem charges for the
# directories, a 4096 KiB tree cannot measure the same as a 64 KiB one. This is
# what stops a predicate that printed a constant from satisfying both cases
# above, which is the force the removed band was carrying.
if [ "$payload_fat_kb" -gt "$payload_kb" ]; then r2=differ; else r2="$payload_kb vs $payload_fat_kb"; fi
t payload-two-trees-report-different-sizes differ "$r2"

# MUST FAIL: a DANGLING SYMLINK at an excluded root (#431 round 2, codex). One
# planted link used to produce two PASS lines on the tree that most needs a
# finding: `-e` is false for it, so the root walk did not see it, and `du -skL`
# then could not walk the tree — exiting non-zero and printing a partial total
# of 0, which is under any bound. Both halves are asserted here, because either
# one alone still lets a fat `fleet-floor/dev` arrive behind a broken link.
payload_dangling_dir="$(payload_tree dangling-root - 64)"
mkdir -p "$payload_dangling_dir/fleet-floor"
ln -s missing-target "$payload_dangling_dir/fleet-floor/dev"
r1="$(payload_run "$PHOME/src" "$payload_dangling_dir")"
t payload-dangling-excluded-root-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-dangling-excluded-root-names-the-path named "$r2"
# The exact false green, pinned out by its own text: a failed measurement must
# never be reported as a small tree.
case "$r1" in
  *"is 0 KiB, within"*) r2='FALSE-GREEN' ;;
  *"size measured"*)    r2='measurement-red' ;;
  *)                    r2="$r1" ;;
esac
t payload-dangling-root-is-not-a-zero-kib-pass measurement-red "$r2"

# MUST FAIL: the measurement guard STANDS ALONE. A dangling symlink at a path
# that is not an excluded root leaves the root walk correctly green, so the
# only thing that can red this tree is du's own status — which is the proof
# that the size assertion is not being carried by the root finding beside it.
payload_unmeasurable_dir="$(payload_tree unmeasurable - 64)"
ln -s missing-target "$payload_unmeasurable_dir/cli/orphan"
r1="$(payload_run "$PHOME/src" "$payload_unmeasurable_dir")"
t payload-unmeasurable-tree-reds red "$(payload_verdict "$r1")"
case "$r1" in *"PASS payload: installed tree carries none"*) r2='roots-still-green' ;; *) r2="$r1" ;; esac
t payload-unmeasurable-tree-is-not-a-root-finding roots-still-green "$r2"
# and it reports du's own status and words, not a bound verdict: "could not
# measure" and "too big" are different facts for whoever reads the drill record.
case "$r1" in *"size measured — du -skL exited 1"*) r2='says-du' ;; *) r2="$r1" ;; esac
t payload-unmeasurable-tree-carries-dus-own-status says-du "$r2"
case "$r1" in *"within the 3072 KiB bound"*) r2='BOUND-VERDICT' ;; *) r2='not-a-bound-verdict' ;; esac
t payload-unmeasurable-tree-is-not-a-bound-finding not-a-bound-verdict "$r2"

# MUST FAIL: a fat artifact tree reds where the checkout tree is clean. The
# channels are asserted separately for exactly this reason — one verdict per
# installed tree, never one inferred from another.
r1="$(payload_run "$PHOME/src" "$(payload_tree channel-checkout - 64)")"
r2="$(payload_run "$PHOME/src" "$(payload_tree channel-artifact fleet-floor/dev 4096)")"
t payload-per-channel-verdicts-are-independent "green red" \
  "$(payload_verdict "$r1") $(payload_verdict "$r2")"

# THE MUTATION THAT DELETES ITS OWN CHECK. Reverting #365 takes fleet-floor/dev
# out of PAYLOAD_EXCLUDED_PATHS, so a walk over only what the installer still
# names would go green on the very regression this leg exists for. The sentinel
# is unioned in, so the tree is still walked against it — and the installer
# having dropped it is a separate finding, not a silence.
payload_src '.git drill shared/test fleet-floor/test' 3072 3072
r1="$(payload_run "$PHOME/src" "$(payload_tree reverted fleet-floor/dev 4096)")"
t payload-reverted-exclusion-still-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-reverted-exclusion-still-names-the-root named "$r2"
# shellcheck source=drill/install-payload.sh
. "$ROOT/drill/install-payload.sh"
install_payload_installer_names_sentinel "$PHOME/src" && r1=named || r1=dropped
t payload-reverted-exclusion-reported-against-the-source dropped "$r1"
payload_src "$CLEAN_ROOTS" 3072 3072
install_payload_installer_names_sentinel "$PHOME/src" && r1=named || r1=dropped
t payload-declared-sentinel-is-reported-named named "$r1"

# The bound is READ, and reading it doubles as a drift check between the two
# guards that both spell it: disagreement is a defect this drill will not pick
# a winner for.
t payload-bound-read-from-the-guards 3072 "$(install_payload_budget_kb "$PHOME/src")"
payload_src "$CLEAN_ROOTS" 3072 4096
r1="$(payload_run "$PHOME/src" "$(payload_tree disagree - 64)")"
t payload-guards-disagreeing-on-the-bound-reds red "$(payload_verdict "$r1")"
case "$r1" in *"disagree on the size bound"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-guards-disagreeing-says-so says-so "$r2"
payload_src "$CLEAN_ROOTS" - -
r1="$(payload_run "$PHOME/src" "$(payload_tree nobound - 64)")"
t payload-no-bound-in-the-guards-reds red "$(payload_verdict "$r1")"
case "$r1" in *"no installed-tree size bound"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-no-bound-says-so says-so "$r2"
payload_src "$CLEAN_ROOTS" 3072 3072
rm -f "$PHOME/src/shared/test/artifact.sh"
r1="$(payload_run "$PHOME/src" "$(payload_tree noguard - 64)")"
case "$r1" in *"artifact.sh is missing"*) r2='names-the-guard' ;; *) r2="$r1" ;; esac
t payload-missing-guard-names-it names-the-guard "$r2"

# An installer whose list stopped parsing is a red, never an empty walk.
payload_src '' 3072 3072
r1="$(payload_run "$PHOME/src" "$(payload_tree noparse - 64)")"
t payload-unparsable-exclusion-list-reds red "$(payload_verdict "$r1")"
case "$r1" in *"did not parse"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-unparsable-exclusion-list-says-so says-so "$r2"
# …and a tree that is not there is its own finding, reached only once the two
# reads above have succeeded — which is why the source is restored first.
payload_src "$CLEAN_ROOTS" 3072 3072
r1="$(payload_run "$PHOME/src" "$PHOME/trees/does-not-exist")"
case "$r1" in *"nothing at"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-absent-installed-tree-says-so says-so "$r2"

# The rule the shipped tree actually carries, read through the same predicate
# the drill uses — so a guard reworded past the read reds here and not on a
# release night.
PAYLOAD_SHIPPED_BOUND="$(install_payload_budget_kb "$ROOT")"
case "$PAYLOAD_SHIPPED_BOUND" in [1-9]*) r1=numeric ;; *) r1="$PAYLOAD_SHIPPED_BOUND" ;; esac
t payload-shipped-bound-is-readable numeric "$r1"
payload_excluded_roots="$(install_payload_excluded_roots "$ROOT")"
grep -qx 'shared/test' <<<"$payload_excluded_roots" && r1=walked || r1=MISSING
t payload-shipped-list-names-the-test-root walked "$r1"
install_payload_installer_names_sentinel "$ROOT" && r1=named || r1=dropped
t payload-shipped-installer-excludes-the-sentinel named "$r1"

# CRITERION: no size constant is spelled in drill/. Asserted against the bound
# as read, so it keeps holding after the number moves.
if grep -rqF "$PAYLOAD_SHIPPED_BOUND" "$ROOT/drill/"; then r1=SPELLED; else r1='read-not-typed'; fi
t payload-drill-spells-no-size-constant read-not-typed "$r1"

# The driver reads the predicate from here, at all three installed trees.
# shellcheck disable=SC2016  # the driver's literal lines are the patterns
if grep -qF '. "$ROOT/drill/install-payload.sh"' "$ROOT/drill/install-drill.sh"; then
  r1=sourced; else r1=MISSING; fi
t payload-driver-sources-the-shared-predicate sourced "$r1"
r1="$(grep -c 'install_payload_assert ' "$ROOT/drill/install-drill.sh")"
t payload-driver-asserts-three-installed-trees 3 "$r1"
# shellcheck disable=SC2016  # same
if grep -qF 'versions/$VA' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'CREW_HOME/current' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'ARTIFACT_HOME/share/current' "$ROOT/drill/install-drill.sh"; then
  r1='first-upgrade-artifact'; else r1=INCOMPLETE; fi
t payload-driver-covers-first-upgrade-and-artifact first-upgrade-artifact "$r1"

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
CJ_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
REVS_STALE='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$CJ_OLD'"}}]'
# The maintainer (#452). Off-panel by construction — that is the whole reason
# the human's verdict needed its own term here — and the ONE off-panel identity
# this predicate reads.
CJ_HUMAN="danmt"
# The clock D1's ordering is read against, #286's rule applied to the human's
# verdict: CJ_T_BLOCK is when the block landed, CJ_T_SIG_NEW a signal that
# ANSWERS it, CJ_T_SIG_OLD one that merely PREDATES it.
CJ_T_SIG_OLD="2026-08-11T09:00:00Z"
CJ_T_BLOCK="2026-08-11T10:00:00Z"
CJ_T_SIG_NEW="2026-08-11T11:00:00Z"
# No signal posted — the shape answered-head.jq returns when the session has
# never declared a round answered on this PR, and the default here because most
# of these fixtures are indifferent to it.
CJ_NO_SIG='{"sha":"","createdAt":""}'
cj() {  # cj [signal-json] [panel-json] [human]
  jq -r --argjson panel "${2:-$PANEL}" --arg needs_human state:needs-human \
    --arg human "${3-$CJ_HUMAN}" --argjson signal "${1:-$CJ_NO_SIG}" -f "$CJQ"
}

t converged-true true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | cj)"
t converged-outstanding-req false \
  "$(mk_pr "$H" MERGEABLE '[]' '["rev-b"]' "$REVS_OK" | cj)"
t converged-offpanel-req-ignored true \
  "$(mk_pr "$H" MERGEABLE '[]' '["danmt"]' "$REVS_OK" | cj)"
t converged-stale-approval false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_STALE" | cj)"
t converged-already-handed false \
  "$(mk_pr "$H" MERGEABLE '["state:needs-human"]' '[]' "$REVS_OK" | cj)"
t converged-unknown-mergeable defer-unknown \
  "$(mk_pr "$H" UNKNOWN '[]' '[]' "$REVS_OK" | cj)"
t converged-conflicting false \
  "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_OK" | cj)"
# An empty panel must never converge vacuously (bare panel= line).
t converged-empty-panel false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | cj '' '[]')"

# --- #452: the HUMAN's own verdict disqualifies convergence -------------------
# BUILDER.md's Handoff ends "address what comes back and re-hand-off the same
# way", and this predicate is what made that impossible: every wake is scoped to
# $panel and the maintainer is off-panel, so a human CHANGES_REQUESTED left this
# true — the panel still approved the head, and a review does not move
# mergeable. The reconciler took state:needs-human off, the next tick refired
# the handoff, re-requested the human and re-set the label, and the reconciler's
# human-request clause made it stick. The PR bounced back at the human carrying
# a fresh nag and the change request never reached the builder.
CJ_BLOCK_AT_HEAD='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"'$CJ_HUMAN'"},"state":"CHANGES_REQUESTED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$H'"}}]'
CJ_BLOCK_SUPERSEDED='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"'$CJ_HUMAN'"},"state":"CHANGES_REQUESTED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$CJ_OLD'"}}]'
CJ_HUMAN_APPROVED='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"'$CJ_HUMAN'"},"state":"APPROVED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$H'"}}]'
cj_sig() { jq -cn --arg sha "$1" --arg at "$2" '{sha:$sha,createdAt:$at}'; }

# The headline: a standing human block at the head, never answered.
t converged-human-block-at-head false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj)"
# D1's SPEND, and the reason the disqualifier is not simply permanent: an answer
# with argument moves no head, so request-panel.jq finds nobody to re-request —
# the panel already approves this tree — and only the handoff can put the PR back
# in front of the human. A signal at this head, posted after the block, converges.
t converged-human-block-answered true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$H" "$CJ_T_SIG_NEW")")"
# MUST-FAIL, the #286 ordering: a signal that PREDATES the block did not answer
# it. Reading the sha alone — the licence before #286 gave it a createdAt — would
# let one signal posted before the human ever reviewed cancel every later block.
t converged-human-block-stale-signal false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$H" "$CJ_T_SIG_OLD")")"
# An equal-second tie holds, exactly as it does in request-panel.jq: fail-closed
# costs one tick and the next signal clears it.
t converged-human-block-tied-signal false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$H" "$CJ_T_BLOCK")")"
# A signal for some OTHER head is not a signal at this one, however new it is.
t converged-human-block-signal-other-head false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$CJ_OLD" "$CJ_T_SIG_NEW")")"
# MUST-FAIL, D1's HEAD SCOPING. The block sits at a superseded head and the panel
# approves the current one — the builder pushed the fix. This MUST converge: the
# handoff is the only thing that re-requests the human, so an any-head
# disqualifier would stop the very act that clears it. Deadlock, not caution.
t converged-human-block-superseded-head true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_SUPERSEDED" | cj)"
# The human approving changes nothing — only CHANGES_REQUESTED closes a round.
t converged-human-approved true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_HUMAN_APPROVED" | cj)"
# MUST-FAIL, D3: $human ALONE, never "not in $panel". An advisory off-panel
# reviewer stays advisory (BUILDER.md) and triage does not vote on PRs. Keying on
# panel membership passes every other case here and blocks every handoff on the
# board the first time anyone off-panel leaves a verdict.
CJ_ADVISORY_BLOCK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"dan-claude-bot"},"state":"CHANGES_REQUESTED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$H'"}}]'
t converged-advisory-block-ignored true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_ADVISORY_BLOCK" | cj)"
# An empty $human matches nobody: what a caller that is not asking about a round
# passes, and the guard that keeps a fleet with no FLEET_HUMAN configured from
# matching a review whose author.login the API returned as null.
t converged-empty-human-arg-ignores-block true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj '' '' '')"
# A block with NO submittedAt holds, the same fail-closed direction: an absent
# timestamp cannot prove the signal answered it.
CJ_BLOCK_UNTIMED="$(printf '%s' "$CJ_BLOCK_AT_HEAD" | jq -c 'map(del(.submittedAt))')"
t converged-human-block-untimed-holds false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_UNTIMED" | cj "$(cj_sig "$H" "$CJ_T_SIG_NEW")")"

# --- addressing.jq: round-close predicate, the MIRROR of converged.jq (#130) --
# Same payload builder (mk_pr), same panel, same head-scoping — the point is
# that the two predicates agree on every input and differ only in the
# conclusion. Reuses H / REVS_OK from the converged block above.
AJQ="$SHARED/lib/jq/addressing.jq"
OLDH="cccccccccccccccccccccccccccccccccccccccc"
# A closed round without full approval: rev-a requests changes AT the head,
# rev-b approves AT the head. Every panelist opinionated, one is not an approval.
REVS_ADDR='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
# The ceremony#136 mixed round: one approval staled by a push (rev-a at an OLD
# head), the other panelist yet to review at all. NOT closed — still awaiting.
REVS_MIXED_OPEN='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$OLDH'"}}]'
addr() { jq -r --argjson panel "$PANEL" --arg addressing state:addressing -f "$AJQ"; }

# The core: a landed non-approving verdict with the whole panel opinionated at
# the head → state:addressing. This is the exact inverse of converged-true.
t addressing-closed-without-approval true "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR" | addr)"
# All approved at head → converged, NOT addressing (the two never both fire).
t addressing-all-approved-is-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | addr)"
# The #136 mixed round: a stale approval + an unreviewed panelist is a round
# still OPEN (bots-reviewing), not a closed one — addressing must not fire.
t addressing-mixed-open-round-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_MIXED_OPEN" | addr)"
# A stale approval + a head change-request (rev-a CR@head, rev-b approved OLD
# head) is not all-reviewed-at-head → not closed yet.
REVS_ADDR_STALE='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$OLDH'"}}]'
t addressing-not-all-at-head-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR_STALE" | addr)"
# Idempotent: the label already stands → writes nothing (re-tick no-op).
t addressing-already-set-false false "$(mk_pr "$H" MERGEABLE '["state:addressing"]' '[]' "$REVS_ADDR" | addr)"
# A live panel request means the round is still open — do not stamp addressing
# over a head that was just (re-)requested; the reconciler would flip it back.
t addressing-live-request-false false "$(mk_pr "$H" MERGEABLE '[]' '["rev-a"]' "$REVS_ADDR" | addr)"
# An empty panel never closes a round vacuously (mirror of converged-empty-panel).
t addressing-empty-panel-false false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | jq -r --argjson panel '[]' --arg addressing state:addressing -f "$AJQ")"
# Mergeability is irrelevant to addressing: a conflicting PR can still owe a fix.
t addressing-conflicting-still-addresses true "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_ADDR" | addr)"

# --- #130 must-fail guards (the issue's test plan, addressing-scoped) ---------
# The engine write is optimistic, the reconciler authoritative: nothing in the
# addressing path may gate a verdict or write a state it does not own.
# state:addressing must never be written before the verdict lands, and the write
# is best-effort — the marker is the `|| warn` trailing the add-label.
if grep -q '_mark_addressing' "$SHARED/lib/duty-review.sh"; then r1=wired; else r1=MISSING; fi
t addressing-wired-after-verdict wired "$r1"
# shellcheck disable=SC2016  # the grep literal contains $LABEL_ADDRESSING on purpose
if grep -q 'could not set \$LABEL_ADDRESSING' "$SHARED/lib/duty-review.sh"; then r1='best-effort'; else r1=GATING; fi
t addressing-write-is-best-effort best-effort "$r1"
# The addressing writer never touches state:building (out of scope) or
# state:needs-human (the handoff's, not the reviewer's).
if grep -RIn 'state:building' "$SHARED/lib/duty-review.sh" >/dev/null 2>&1; then r1=WRITES-IT; else r1=absent; fi
t addressing-never-writes-state-building absent "$r1"
# The predicate keys approvals/reviews on the head, same as converged.jq — a
# stale verdict at an old head is not a closed round.
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/addressing.jq"; then r1=head-keyed; else r1=CHANGED; fi
t addressing-keys-on-head head-keyed "$r1"


suite_finish
