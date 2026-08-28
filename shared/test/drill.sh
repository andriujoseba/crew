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
cp "$ROOT/drill/rehearsal-report.sh" "$HARNESS/"
cat >"$HARNESS/rehearsal.sh" <<'ROLE'
#!/usr/bin/env bash
role="" remote="" ref="" tree="" source_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --source-ref) source_ref="$2"; shift 2 ;;
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
source_ref="${source_ref:--}"
printf '%s %s %s %s %s\n' "$role" "$remote" "$ref" "$shipped" "$source_ref" \
  >>"$DRILL_ROLE_LOG"
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
[ -z "${DRILL_APP_LOG:-}" ] || printf '%s\n' "$*" >>"$DRILL_APP_LOG"
[ -z "${REHEARSAL_AGREEMENT_STATUS:-}" ] || {
  case " $* " in
    *" --roster "*) printf 'compared\n' >"$REHEARSAL_AGREEMENT_STATUS" ;;
    *) printf '%s\n' "${DRILL_APP_STATUS:-compared}" >"$REHEARSAL_AGREEMENT_STATUS" ;;
  esac
}
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

# A named app roster adds an armed comparison after the generated drill-role
# comparison. It does not replace that pass and it does not invoke another
# role drill (therefore cannot mint another box).
APP_LOG="$TMP/app-passes.log"
: >"$TMP/armed.roster"
: >"$APP_LOG"
: >"$ROLE_LOG"
if app_roster_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  app_roster_rc=0
else
  app_roster_rc=$?
fi
t drill-armed-roster-second-pass-rc 0 "$app_roster_rc"
t drill-armed-roster-runs-two-app-passes 2 \
  "$(wc -l <"$APP_LOG" | tr -d ' ')"
t drill-armed-roster-first-pass-is-generated 1 \
  "$(sed -n '1p' "$APP_LOG" | grep -cF -- '--drill-roles reviewer --agent claude')"
t drill-armed-roster-second-pass-is-named 1 \
  "$(sed -n '2p' "$APP_LOG" | grep -cFx -- "--roster $TMP/armed.roster --no-browser")"
t drill-armed-roster-second-pass-is-read-only 0 \
  "$(sed -n '2p' "$APP_LOG" | grep -cE -- '--allow-control|--boxes' || true)"
t drill-armed-roster-mints-no-extra-role-box 1 \
  "$(wc -l <"$ROLE_LOG" | tr -d ' ')"
t drill-armed-roster-is-distinct-in-record 1 \
  "$(grep -cF 'ok         app-armed  (named roster, no additional boxes)' \
    <<<"$app_roster_out")"

# The named reading is independent of generated-role availability. A failed
# role still keeps the round red, but it must not erase the armed evidence leg.
: >"$APP_LOG"
: >"$ROLE_LOG"
if no_generated_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_ROLE_STAGE=none DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  no_generated_rc=0
else
  no_generated_rc=$?
fi
t drill-armed-roster-without-generated-member-stays-red 1 "$no_generated_rc"
t drill-armed-roster-without-generated-member-still-runs 1 \
  "$(grep -cFx -- "--roster $TMP/armed.roster --no-browser" "$APP_LOG")"
t drill-armed-roster-without-generated-member-records-both-legs 2 \
  "$(grep -cE '^##   (SKIPPED +app |ok +app-armed )' <<<"$no_generated_out")"
t drill-armed-roster-without-generated-member-prints-no-empty-scope 0 \
  "$(grep -cF 'app phase covers  —' <<<"$no_generated_out" || true)"

# Reject a typo before any role or installer work starts.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if missing_roster_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/missing.roster" 2>&1)"; then
  missing_roster_rc=0
else
  missing_roster_rc=$?
fi
t drill-missing-app-roster-fails-early 1 "$missing_roster_rc"
t drill-missing-app-roster-names-path 1 \
  "$(grep -cF "no app roster at '$TMP/missing.roster'" <<<"$missing_roster_out")"
t drill-missing-app-roster-runs-no-role 0 "$(wc -l <"$ROLE_LOG" | tr -d ' ')"
t drill-missing-app-roster-runs-no-installer 0 "$(wc -l <"$INSTALL_LOG" | tr -d ' ')"

# D1: valid disarmed comparisons are evidence, but not evidence for the armed
# criterion. With no second roster they make the round incomplete, not green.
if disarmed_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_STATUS=could-not-compare DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
  disarmed_rc=0
else
  disarmed_rc=$?
fi
t drill-disarmed-only-round-is-incomplete 2 "$disarmed_rc"
t drill-disarmed-only-record-says-could-not-compare 1 \
  "$(grep -cF 'INCOMPLETE app  (could not compare an armed, ticking, clock-skewed box)' \
    <<<"$disarmed_out")"
t drill-disarmed-only-record-has-no-green-app-row 0 \
  "$(grep -cE '^##   ok +app  ' <<<"$disarmed_out" || true)"

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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  phase2_retained_rc=0
else
  phase2_retained_rc=$?
fi
t drill-phase2-retained-stays-red 1 "$phase2_retained_rc"
t drill-phase2-retained-reports-kept-teardown 1 \
  "$(grep -cF 'kept       teardown  (round not green' <<<"$phase2_retained_out")"
t drill-phase2-retained-does-not-call-hygiene-skipped 1 \
  "$(grep -cF \
    'INCOMPLETE hygiene  (phase 2 ran without a hygiene result)' \
    <<<"$phase2_retained_out")"
if summary_count_matches_rows "$phase2_retained_out"; then r1=equal; else r1=MISMATCH; fi
t drill-phase2-retained-summary-counts-every-row equal "$r1"

: >"$SECTION_LOG"
if preinstall_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_REMOTE="$REMOTE" DRILL_ROLE_STAGE=none DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
  preinstall_rc=0
else
  preinstall_rc=$?
fi
t drill-preinstall-failure-stays-red 1 "$preinstall_rc"
t drill-preinstall-failure-reports-role 1 \
  "$(grep -cF 'FAIL       reviewer  (failed before an installed box existed)' <<<"$preinstall_out")"
for section in installer config; do
  t "drill-preinstall-skips-$section-by-role-install" 1 \
    "$(grep -cF "SKIPPED    $section  (blocked by role install: no installed drill box)" \
      <<<"$preinstall_out")"
done
t drill-preinstall-skips-app-by-role-install 1 \
  "$(grep -cF 'SKIPPED    app  (generated pass blocked by role install: no installed drill box)' \
    <<<"$preinstall_out")"
t drill-preinstall-invokes-no-independent-section 0 \
  "$(wc -l <"$SECTION_LOG" | tr -d ' ')"
if summary_count_matches_rows "$preinstall_out"; then r1=equal; else r1=MISMATCH; fi
t drill-preinstall-summary-counts-every-row equal "$r1"

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

# --- #492: the report target is derived from the ref actually drilled ---

# shellcheck source=drill/rehearsal-report.sh
. "$ROOT/drill/rehearsal-report.sh"
GH_REMOTE="https://github.com/heavy-duty/crew.git"
derive() { rehearsal_report_target "$1" "$2" || printf '(none)\n'; }

# Every ref shape that names a pull request, and the ones that only look like
# they do. A branch, a tag and a bare commit each name a tree any number of
# pull requests may carry, so none of them derives a target.
t drill-report-target-pull-head 'heavy-duty/crew PR #450' \
  "$(derive "$GH_REMOTE" refs/pull/450/head)"
t drill-report-target-pull-merge 'heavy-duty/crew PR #450' \
  "$(derive "$GH_REMOTE" refs/pull/450/merge)"
t drill-report-target-pull-unprefixed 'heavy-duty/crew PR #450' \
  "$(derive "$GH_REMOTE" pull/450/head)"
# The suffix is required. `pull/452` is an ordinary ref shape a branch may
# occupy, so deriving from it would route findings to a PR the round never
# drilled — the end-to-end half of this is the collision round below.
t drill-report-target-pull-bare-none '(none)' "$(derive "$GH_REMOTE" pull/450)"
t drill-report-target-refs-pull-bare-none '(none)' \
  "$(derive "$GH_REMOTE" refs/pull/450)"
t drill-report-target-scp-remote 'heavy-duty/crew PR #7' \
  "$(derive git@github.com:heavy-duty/crew.git refs/pull/7/head)"
t drill-report-target-ssh-url-remote 'heavy-duty/crew PR #12' \
  "$(derive ssh://git@github.com/heavy-duty/crew.git pull/12/merge)"
t drill-report-target-branch-none '(none)' "$(derive "$GH_REMOTE" main)"
t drill-report-target-tag-none '(none)' "$(derive "$GH_REMOTE" 0.1.2)"
t drill-report-target-sha-none '(none)' "$(derive "$GH_REMOTE" "$FIRST")"
t drill-report-target-empty-ref-none '(none)' "$(derive "$GH_REMOTE" '')"
t drill-report-target-nonnumeric-none '(none)' \
  "$(derive "$GH_REMOTE" refs/pull/abc/head)"
t drill-report-target-branch-named-pull-none '(none)' \
  "$(derive "$GH_REMOTE" refs/heads/pull/450/head)"
# A remote naming no owner/repo still routes: the number is the routing and the
# slug only disambiguates it.
t drill-report-target-local-remote-keeps-number 'PR #450' \
  "$(derive "$REMOTE" refs/pull/450/head)"

# Each exit, with a target and without one. The four kinds are every footer the
# drill prints, which is what "every exit path, not just the failure path" asks
# for.
TARGET='heavy-duty/crew PR #450'
footer() { rehearsal_report_footer "$1" "$2" reviewer crew-drill-reviewer; }
t drill-report-exit-fail-names-target 1 \
  "$(grep -cF "Report findings on $TARGET with" <<<"$(footer fail "$TARGET")")"
# The only footer whose instruction and evidence share a sentence: with no
# target the report instruction goes entirely, rather than surviving as a
# `Report findings with` that routes nowhere (D2, AC1's "or no instruction at
# all"). The box line below proves the evidence half is what stayed.
t drill-report-exit-fail-no-target-drops-instruction 0 \
  "$(grep -ciF 'report findings' <<<"$(footer fail '')" || true)"
t drill-report-exit-fail-no-target-still-collects 1 \
  "$(grep -cF 'Fixtures and box are left in place. Collect' \
    <<<"$(footer fail '')")"
t drill-report-exit-incomplete-names-target 1 \
  "$(grep -cF "must not be reported as one on $TARGET." \
    <<<"$(footer incomplete "$TARGET")")"
t drill-report-exit-incomplete-no-target-drops-instruction 1 \
  "$(grep -cF 'must not be reported as one.' <<<"$(footer incomplete '')")"
t drill-report-exit-pass-names-target 1 \
  "$(grep -cF "Report the pass on $TARGET." <<<"$(footer pass "$TARGET")")"
# The pass footer's instruction is its whole second sentence, so with no target
# the sentence goes rather than becoming a bare "Report the pass."
t drill-report-exit-pass-no-target-drops-sentence 1 \
  "$(grep -cxF 'All green, phase 2 included — the reviewer loop ran.' \
    <<<"$(footer pass '')")"
t drill-report-exit-round-incomplete-names-target 1 \
  "$(grep -cF "before reporting anything on $TARGET." \
    <<<"$(footer round-incomplete "$TARGET")")"
t drill-report-exit-round-incomplete-no-target-drops-instruction 1 \
  "$(grep -cF 'before reporting anything.' <<<"$(footer round-incomplete '')")"
# The footer that routes to a box keeps the box either way: what is dropped is
# the target, never the evidence the operator has to collect.
t drill-report-exit-fail-keeps-box-either-way 2 \
  "$(grep -cF 'box shell crew-drill-reviewer' \
    <<<"$(footer fail "$TARGET"; footer fail '')")"

targeted_exits=""
untargeted_exits=""
for exit_kind in fail incomplete pass round-incomplete; do
  targeted_exits+="$(footer "$exit_kind" "$TARGET")"$'\n'
  untargeted_exits+="$(footer "$exit_kind" '')"$'\n'
done
t drill-report-every-exit-names-the-target 4 \
  "$(grep -cF "$TARGET" <<<"$targeted_exits")"
t drill-report-no-exit-names-a-pr-without-one 0 \
  "$(grep -cE 'PR #' <<<"$untargeted_exits" || true)"
if rehearsal_report_footer not-an-exit "$TARGET" reviewer box >/dev/null 2>&1; then
  unknown_kind_rc=0
else
  unknown_kind_rc=$?
fi
t drill-report-unknown-exit-kind-refused 1 "$unknown_kind_rc"

# Mutation: the literal this issue exists to remove. No exit may reach a PR
# number except through the derivation.
t drill-report-scripts-hardcode-no-pr-number 0 \
  "$(cat "$ROOT/drill/rehearsal.sh" "$ROOT/drill/rehearsal-all.sh" \
    "$ROOT/drill/rehearsal-report.sh" | grep -cE 'PR #[0-9]' || true)"

# Mutation: a stale default standing in where nothing is derivable. The
# no-target cases above must red on it, or they are asserting nothing.
STALE_LIB="$TMP/rehearsal-report-stale.sh"
# shellcheck disable=SC2016  # mutate the literal production guard
sed 's/\[ -z "\$target" \] || on=" on \$target"/on=" on ${target:-crew PR #16}"/' \
  "$ROOT/drill/rehearsal-report.sh" >"$STALE_LIB"
t drill-report-stale-mutation-applied 1 "$(grep -cF 'crew PR #16' "$STALE_LIB")"
stale_exits="$(bash -c '
  . "$1"
  for kind in fail incomplete pass round-incomplete; do
    rehearsal_report_footer "$kind" "" reviewer crew-drill-reviewer
  done' _ "$STALE_LIB")"
if grep -qE 'PR #' <<<"$stale_exits"; then r1=red; else r1=FALSE_PASS; fi
t drill-report-stale-target-mutation-is-caught red "$r1"

# End to end. The orchestrator resolves the operator's ref to a commit before
# handing it to a role (#490), so a role could not derive a target from what it
# receives — the unresolved ref travels beside it as --source-ref, and the
# resolution invariant is unchanged.
git --git-dir="$REMOTE" update-ref refs/pull/450/head "$FIRST"
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO=""
if pull_out="$(DRILL_ROLE_RC=2 round_run "$HARNESS/rehearsal-all.sh" reviewer \
    refs/pull/450/head)"; then pull_rc=0; else pull_rc=$?; fi
t drill-report-pull-round-is-incomplete 2 "$pull_rc"
t drill-report-pull-round-names-target 1 \
  "$(grep -cF '## in and re-run before reporting anything on PR #450.' \
    <<<"$pull_out")"
t drill-report-pull-round-passes-source-ref refs/pull/450/head \
  "$(awk '{print $5}' "$ROLE_LOG")"
t drill-report-pull-round-still-resolves-ref "$FIRST" \
  "$(awk '{print $3}' "$ROLE_LOG")"

# A branch round derives nothing and says nothing, and hands the role no
# source ref to derive from either.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
git --git-dir="$REMOTE" update-ref refs/heads/main "$FIRST"
if main_out="$(DRILL_ROLE_RC=2 round_run "$HARNESS/rehearsal-all.sh" reviewer \
    main)"; then :; fi
t drill-report-branch-round-drops-instruction 1 \
  "$(grep -cF '## in and re-run before reporting anything.' <<<"$main_out")"
t drill-report-branch-round-names-no-pr 0 \
  "$(grep -cE 'PR #[0-9]' <<<"$main_out" || true)"
t drill-report-branch-round-passes-no-source-ref '-' \
  "$(awk '{print $5}' "$ROLE_LOG")"

# The collision, end to end: an ordinary branch whose name occupies the pull
# ref shape. `git fetch <remote> pull/452` drills the BRANCH — the round never
# goes near pull request 452 — so a footer naming it would route findings to a
# PR this round did not touch, which is this issue's own defect in a new place.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
git --git-dir="$REMOTE" update-ref refs/heads/pull/452 "$FIRST"
if collide_out="$(DRILL_ROLE_RC=2 round_run "$HARNESS/rehearsal-all.sh" reviewer \
    pull/452)"; then :; fi
t drill-report-branch-named-pull-round-resolves "$FIRST" \
  "$(awk '{print $3}' "$ROLE_LOG")"
t drill-report-branch-named-pull-round-names-no-pr 0 \
  "$(grep -cE 'PR #[0-9]' <<<"$collide_out" || true)"
t drill-report-branch-named-pull-round-passes-no-source-ref '-' \
  "$(awk '{print $5}' "$ROLE_LOG")"

# The role script's own wiring is stubbed out by the fixture above, so these
# three pins stand in for it — each one is a mutation that would otherwise
# leave the whole suite green while the footers named the wrong thing, or
# nothing.
role_script="$(cat "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # the needles are production source, not expansions
t drill-report-role-derives-from-source-ref 1 \
  "$(grep -cF 'rehearsal_report_target "$REMOTE" "${SOURCE_REF:-$REF}"' \
    <<<"$role_script")"
# shellcheck disable=SC2016  # ditto
t drill-report-role-derivation-guarded-by-tree 1 \
  "$(grep -B 2 -F 'rehearsal_report_target "$REMOTE"' <<<"$role_script" \
    | grep -cF 'if [ -z "$TREE" ]; then')"
# shellcheck disable=SC2016  # ditto
t drill-report-role-exits-pass-the-target 3 \
  "$(grep -cE '^ *rehearsal_report_footer (fail|incomplete|pass) "\$REPORT_TARGET"' \
    <<<"$role_script")"

# --tree drills a local checkout, so a ref passed beside it is not what was
# drilled and derives nothing.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if tree_report_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" DRILL_ROLE_RC=2 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --ref refs/pull/450/head \
      --roles reviewer --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then :; fi
t drill-report-tree-round-names-no-pr 0 \
  "$(grep -cE 'PR #[0-9]' <<<"$tree_report_out" || true)"
t drill-report-tree-round-passes-no-source-ref '-' \
  "$(awk '{print $5}' "$ROLE_LOG")"

suite_finish
