#!/usr/bin/env bash
# shared/test/conf.sh — standalone conf subject suite.
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


suite_finish
