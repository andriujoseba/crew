#!/usr/bin/env bash
# Focused fixtures for drill orchestration and immutable source acquisition.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"

SOURCE="$TMP/source"
REMOTE="$TMP/canonical.git"
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name fixture
git -C "$SOURCE" config user.email fixture@example.invalid
mkdir -p "$SOURCE/shared/test"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SOURCE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$SOURCE/shared/test/run.sh"
printf '0.0.0-test\n' >"$SOURCE/VERSION"
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm first
FIRST="$(git -C "$SOURCE" rev-parse HEAD)"
printf 'second\n' >"$SOURCE/SECOND"
git -C "$SOURCE" add SECOND
git -C "$SOURCE" commit -qm second
SECOND="$(git -C "$SOURCE" rev-parse HEAD)"
git clone -q --bare "$SOURCE" "$REMOTE"
git --git-dir="$REMOTE" update-ref refs/heads/main "$FIRST"
# Model GitHub's fork-network exact-object service: SECOND is in the canonical
# object store but no canonical ref advertises it.
git --git-dir="$REMOTE" config uploadpack.allowAnySHA1InWant true
git --git-dir="$REMOTE" config uploadpack.allowReachableSHA1InWant true

HARNESS="$TMP/harness"
mkdir -p "$HARNESS"
cp "$ROOT/drill/rehearsal-all.sh" "$ROOT/drill/rehearsal-notify.sh" \
  "$ROOT/drill/rehearsal-verdict.sh" "$ROOT/drill/rehearsal-hygiene.sh" \
  "$ROOT/drill/rehearsal-breaker.sh" "$ROOT/drill/rehearsal-safety.sh" \
  "$HARNESS/"
cat >"$HARNESS/rehearsal.sh" <<'ROLE'
#!/usr/bin/env bash
role="" remote="" ref="" tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --tree) tree="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$tree" ]; then
  shipped="$(git -C "$tree" rev-parse HEAD)"
elif [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
  shipped="$ref"
else
  shipped="$(git --git-dir="$DRILL_REMOTE" rev-parse "refs/heads/$ref")"
fi
remote="${remote:--}"
ref="${ref:--}"
printf '%s %s %s %s\n' "$role" "$remote" "$ref" "$shipped" >>"$DRILL_ROLE_LOG"
[ -z "${REHEARSAL_SECTION_STATUS:-}" ] \
  || printf '%s\n' "${DRILL_ROLE_STAGE:-phase2}" >"$REHEARSAL_SECTION_STATUS"
if [ -n "$tree" ]; then
  echo "== phase 0: crew at $shipped (tree $tree), static checks"
else
  echo "== phase 0: shipped $shipped from remote $remote ref $ref (creds-free inside box)"
fi
if [ "$(wc -l <"$DRILL_ROLE_LOG")" -eq 1 ] && [ -n "${DRILL_MOVE_TO:-}" ]; then
  git --git-dir="$DRILL_REMOTE" update-ref refs/heads/main "$DRILL_MOVE_TO"
fi
exit "${DRILL_ROLE_RC:-0}"
ROLE
chmod +x "$HARNESS/rehearsal.sh"
cat >"$HARNESS/install-drill.sh" <<'INSTALL'
#!/usr/bin/env bash
remote="" ref="" tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) remote="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --tree) tree="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$tree" ]; then shipped="$(git -C "$tree" rev-parse HEAD)"; else shipped="$ref"; fi
remote="${remote:--}"
ref="${ref:--}"
printf 'installer %s %s %s\n' "$remote" "$ref" "$shipped" >>"$DRILL_INSTALL_LOG"
exit 0
INSTALL
chmod +x "$HARNESS/install-drill.sh"
cat >"$HARNESS/rehearsal-config.sh" <<'CONFIG'
#!/usr/bin/env bash
printf 'config\n' >>"$DRILL_SECTION_LOG"
exit 0
CONFIG
cat >"$HARNESS/rehearsal-app.sh" <<'APP'
#!/usr/bin/env bash
printf 'app\n' >>"$DRILL_SECTION_LOG"
exit 0
APP
chmod +x "$HARNESS/rehearsal-config.sh" "$HARNESS/rehearsal-app.sh"

round_run() {  # <script> <roles> <ref>
  local script="$1" roles="$2" ref="$3"
  DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_MOVE_TO="${DRILL_MOVE_TO:-}" \
    DRILL_ROLE_STAGE="${DRILL_ROLE_STAGE:-phase2}" \
    DRILL_ROLE_RC="${DRILL_ROLE_RC:-0}" \
    bash "$script" --remote "$REMOTE" --ref "$ref" --roles "$roles" \
      --keep --no-app --no-config-drill \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1
}

# Resolve main once, then move it after the first role. Every role still gets
# and reports FIRST because the mutable name never crosses the orchestrator.
ROLE_LOG="$TMP/roles.log"
INSTALL_LOG="$TMP/installer.log"
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO="$SECOND"
if round_out="$(round_run "$HARNESS/rehearsal-all.sh" \
    'triage builder reviewer' main)"; then round_rc=0; else round_rc=$?; fi
t drill-one-resolution-round-rc 0 "$round_rc"
t drill-one-resolution-three-roles 3 "$(wc -l <"$ROLE_LOG" | tr -d ' ')"
t drill-one-resolution-one-passed-ref 1 "$(awk '{print $3}' "$ROLE_LOG" | sort -u | wc -l | tr -d ' ')"
t drill-one-resolution-passed-full-sha "$FIRST" "$(awk 'NR == 1 {print $3}' "$ROLE_LOG")"
t drill-moving-branch-one-shipped-tree 1 "$(awk '{print $4}' "$ROLE_LOG" | sort -u | wc -l | tr -d ' ')"
t drill-moving-branch-ships-original "$FIRST" "$(awk 'NR == 3 {print $4}' "$ROLE_LOG")"
t drill-moving-branch-installer-passed-full-sha "$FIRST" "$(awk '{print $3}' "$INSTALL_LOG")"
t drill-moving-branch-installer-ships-original "$FIRST" "$(awk '{print $4}' "$INSTALL_LOG")"
t drill-moving-branch-one-tree-across-round 1 \
  "$(awk '{print $4}' "$ROLE_LOG" "$INSTALL_LOG" | sort -u | wc -l | tr -d ' ')"
t drill-record-names-resolved-sha 1 \
  "$(grep -cF "## drilled source: $FIRST (remote $REMOTE ref main)" <<<"$round_out")"
t drill-three-phase-zero-lines 3 "$(grep -cF "phase 0: shipped $FIRST" <<<"$round_out")"

# Mutation: forwarding the mutable operator ref recreates the split as soon as
# the fixture moves main. This proves the moving-branch case is discriminating.
MUTABLE="$HARNESS/rehearsal-all-mutable.sh"
# shellcheck disable=SC2016  # mutate the literal production variable
sed 's/--ref "$RESOLVED_REF"/--ref "$INSTALL_REF"/' \
  "$HARNESS/rehearsal-all.sh" >"$MUTABLE"
git --git-dir="$REMOTE" update-ref refs/heads/main "$FIRST"
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO="$SECOND"
round_run "$MUTABLE" 'triage builder reviewer' main >/dev/null || true
t drill-moving-branch-mutation-diverges 2 \
  "$(awk '{print $4}' "$ROLE_LOG" | sort -u | wc -l | tr -d ' ')"

# A commit with no advertised canonical ref remains acquirable by its full ID.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO=""
if hidden_out="$(round_run "$HARNESS/rehearsal-all.sh" reviewer "$SECOND")"; then
  hidden_rc=0
else
  hidden_rc=$?
fi
t drill-hidden-commit-round-rc 0 "$hidden_rc"
t drill-hidden-commit-from-canonical "$REMOTE $SECOND $SECOND" \
  "$(awk '{print $2, $3, $4}' "$ROLE_LOG")"
t drill-hidden-commit-recorded 1 \
  "$(grep -cF "## drilled source: $SECOND (remote $REMOTE ref $SECOND)" <<<"$hidden_out")"
t drill-hidden-commit-installer-ref "$SECOND" "$(awk '{print $3}' "$INSTALL_LOG")"

# Tree mode identifies the actual local checkout and commit in both phase-0
# role evidence and the paste-ready summary; remote/ref defaults stay silent.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO=""
if tree_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer \
      --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then tree_rc=0; else tree_rc=$?; fi
t drill-tree-round-rc 0 "$tree_rc"
t drill-tree-role-ships-head "$SECOND" "$(awk '{print $4}' "$ROLE_LOG")"
t drill-tree-installer-ships-head "$SECOND" "$(awk '{print $4}' "$INSTALL_LOG")"
t drill-tree-record-names-head 1 \
  "$(grep -cF "## drilled source: $SECOND (tree $SOURCE)" <<<"$tree_out")"
t drill-tree-phase-zero-names-head 1 \
  "$(grep -cF "phase 0: crew at $SECOND (tree $SOURCE), static checks" <<<"$tree_out")"

# A red assertion inside phase 2 must not silently void the independent
# installer, config and app sections. The explicit stage channel distinguishes
# this from a role failure before an installed box existed (#491).
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
SECTION_LOG="$TMP/sections.log"
: >"$SECTION_LOG"
if phase2_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_ROLE_STAGE=phase2 DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer \
      --keep --no-resume-drill --no-attention-drill \
      --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  phase2_rc=0
else
  phase2_rc=$?
fi
t drill-phase2-failure-stays-red 1 "$phase2_rc"
t drill-phase2-failure-reports-role 1 \
  "$(grep -cF 'FAIL       reviewer  (phase 2 failed)' <<<"$phase2_out")"
t drill-phase2-failure-runs-section-a 1 \
  "$(grep -cF 'ok         installer  (Section A record emitted)' <<<"$phase2_out")"
t drill-phase2-failure-runs-config 1 \
  "$(grep -cF 'ok         config  (operator mode + registry contract)' <<<"$phase2_out")"
t drill-phase2-failure-runs-app 1 \
  "$(grep -cF 'ok         app  (collector + page)' <<<"$phase2_out")"
t drill-phase2-failure-invokes-config-and-app $'config\napp' "$(cat "$SECTION_LOG")"
t drill-phase2-summary-counts-three-passed 1 \
  "$(grep -cE '^## section states: 3 passed, 1 failed, [0-9]+ skipped/not-run$' <<<"$phase2_out")"

summary_count_matches_rows() {
  local record="$1" headline counted rows
  headline="$(sed -nE \
    's/^## section states: ([0-9]+) passed, ([0-9]+) failed, ([0-9]+) skipped\/not-run$/\1 \2 \3/p' \
    <<<"$record")"
  read -r passed failed skipped <<<"$headline"
  counted=$((passed + failed + skipped))
  rows="$(grep -c '^##   ' <<<"$record")"
  [ "$counted" -eq "$rows" ]
}

if summary_count_matches_rows "$phase2_out"; then r1=equal; else r1=MISMATCH; fi
t drill-phase2-keep-summary-counts-every-row equal "$r1"

if phase2_retained_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_REMOTE="$REMOTE" DRILL_ROLE_STAGE=phase2 DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
  phase2_retained_rc=0
else
  phase2_retained_rc=$?
fi
t drill-phase2-retained-stays-red 1 "$phase2_retained_rc"
t drill-phase2-retained-reports-kept-teardown 1 \
  "$(grep -cF 'kept       teardown  (round not green' <<<"$phase2_retained_out")"
if summary_count_matches_rows "$phase2_retained_out"; then r1=equal; else r1=MISMATCH; fi
t drill-phase2-retained-summary-counts-every-row equal "$r1"

required_later_sections() {
  local record="$1" section
  for section in installer config app; do
    grep -Eq "^##   (ok|FAIL|skip|SKIPPED|INCOMPLETE) +$section  " <<<"$record" \
      || return 1
  done
}
if required_later_sections "$phase2_out"; then r1=complete; else r1=MISSING; fi
t drill-phase2-record-names-every-later-section complete "$r1"
phase2_missing_app="$(sed '/^##   ok         app  /d' <<<"$phase2_out")"
if required_later_sections "$phase2_missing_app"; then r1=FALSE_PASS; else r1=red; fi
t drill-phase2-absent-section-mutation-reds red "$r1"
phase2_wrong_count="${phase2_out/3 passed, 1 failed/4 passed, 0 failed}"
if grep -qE '^## section states: 3 passed, 1 failed, [0-9]+ skipped/not-run$' \
    <<<"$phase2_wrong_count"; then r1=FALSE_PASS; else r1=red; fi
t drill-phase2-summary-count-mutation-reds red "$r1"

# Resolution failures belong to phase 0 and name both inputs before a role
# begins, so the operator can distinguish a bad ref from a role failure.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if bad_out="$(round_run "$HARNESS/rehearsal-all.sh" reviewer no-such-ref)"; then
  bad_rc=0
else
  bad_rc=$?
fi
t drill-unresolved-ref-rc 1 "$bad_rc"
case "$bad_out" in
  *"phase 0:"*"remote '$REMOTE'"*"ref 'no-such-ref'"*"to one commit"*) bad_named=named ;;
  *) bad_named=missing ;;
esac
t drill-unresolved-ref-names-reason named "$bad_named"
t drill-unresolved-ref-starts-no-role 0 "$(wc -l <"$ROLE_LOG" | tr -d ' ')"

# Invalid local role input is rejected before any remote resolution attempt.
if role_bad_out="$(round_run "$HARNESS/rehearsal-all.sh" not-a-role no-such-ref)"; then
  role_bad_rc=0
else
  role_bad_rc=$?
fi
t drill-invalid-role-rc 1 "$role_bad_rc"
case "$role_bad_out" in *"unknown role 'not-a-role'"*) role_bad_named=named ;; *) role_bad_named=missing ;; esac
t drill-invalid-role-named named "$role_bad_named"
t drill-invalid-role-skips-resolution 0 "$(grep -c 'cannot resolve remote' <<<"$role_bad_out" || true)"

# The record assertion itself must reject a summary that drops the SHA.
NO_RECORD="$HARNESS/rehearsal-all-no-record.sh"
# shellcheck disable=SC2016  # remove the literal production summary line
sed '/echo "## drilled source: \$RESOLVED_REF /d' \
  "$HARNESS/rehearsal-all.sh" >"$NO_RECORD"
: >"$ROLE_LOG"
if no_record_out="$(round_run "$NO_RECORD" reviewer "$FIRST")"; then :; fi
t drill-missing-record-sha-mutation-is-caught 0 \
  "$(grep -cF "## drilled source: $FIRST" <<<"$no_record_out" || true)"

# The role acquisition primitive is exact-object fetch plus detached checkout;
# clone --branch cannot accept the full SHA the orchestrator now passes.
# shellcheck disable=SC2016  # match literal production shell source
acquire_block="$(sed -n '/SOURCE_TREE="\$ACQUIRE_TMP\/source"/,/^fi$/p' \
  "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match literal production shell source
case "$acquire_block" in
  *'git -C "$ACQUIRE_TMP" init'*'fetch --quiet --depth=1'*'checkout --quiet --detach FETCH_HEAD'*) acquire_shape=exact ;;
  *) acquire_shape=other ;;
esac
t drill-role-acquires-exact-object exact "$acquire_shape"
t drill-role-does-not-clone-branch 0 \
  "$(grep -c 'git clone.*--branch' <<<"$acquire_block" || true)"

suite_finish
