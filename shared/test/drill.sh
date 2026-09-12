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
cat >"$HARNESS/box" <<'BOX'
#!/usr/bin/env bash
[ "${1:-}" = exec ] || exit 1
[ "${DRILL_SECTION_A_UNREADABLE:-0}" -eq 0 ] || exit 2
if [ "${DRILL_SECTION_A_ARMED:-0}" -eq 1 ]; then
  printf 'armed\n'
else
  printf 'disarmed\n'
fi
BOX
chmod +x "$HARNESS/box"
PATH="$HARNESS:$PATH"
export PATH
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
    *" --roster "*)
      case "${DRILL_APP_ROSTER_STATUS:-compared}" in
        missing) : ;;
        *) printf '%s\n' "${DRILL_APP_ROSTER_STATUS:-compared}" >"$REHEARSAL_AGREEMENT_STATUS" ;;
      esac ;;
    *) printf '%s\n' "${DRILL_APP_STATUS:-compared}" >"$REHEARSAL_AGREEMENT_STATUS" ;;
  esac
}
skip() { echo "skip $1${2:+  — $2}"; }
case " $* " in
  *" --no-browser "*) ;;
  *)
    case "${DRILL_BROWSER_STATUS:-ok}" in
      ok) echo 'ok   browser walk against the real fleet (read-only)' ;;
      skip) skip "browser walk" "playwright-core not installed" ;;
      fail) echo 'FAIL browser walk against the real fleet (read-only)' ;;
      missing) : ;;
    esac ;;
esac
exit "${DRILL_APP_RC:-0}"
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
t drill-record-enumerates-all-declared-legs 12 \
  "$(grep -c '^## leg \(executed\|not-executed\) ' <<<"$tree_out")"
t drill-record-names-browser-exclusion 1 \
  "$(grep -c '^## leg not-executed browser  (skip; --no-app)' <<<"$tree_out")"
t drill-record-names-unrequested-armed-leg-with-app-disabled 1 \
  "$(grep -c '^## leg not-executed app-armed  (skip; --no-app)' \
    <<<"$tree_out")"

# The original three zero-execution findings remain visible with their actual
# states: breaker and notify name the operator exclusions in this fixture, and
# the browser is positively recorded as executed.
for excluded_leg in breaker notify; do
  t "drill-record-names-$excluded_leg-exclusion" 1 \
    "$(grep -c "^## leg not-executed $excluded_leg  (skip; --no-$excluded_leg-drill)" \
      <<<"$tree_out")"
done

# A new declaration with no call site cannot disappear. Mutate only the list:
# the runtime agreement check must add a named missing-result row and red.
UNWIRED="$HARNESS/rehearsal-all-unwired.sh"
sed 's/hygiene breaker resume/hygiene never-wired breaker resume/' \
  "$HARNESS/rehearsal-all.sh" >"$UNWIRED"
if unwired_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" bash "$UNWIRED" --tree "$SOURCE" --roles reviewer \
      --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  unwired_rc=0
else
  unwired_rc=$?
fi
t drill-unwired-declared-leg-reds 1 "$unwired_rc"
t drill-unwired-declared-leg-is-visible 1 \
  "$(grep -c '^## leg not-executed never-wired  (recorded 0 results; expected exactly one)' \
    <<<"$unwired_out")"
t drill-unwired-declared-leg-prevents-teardown 1 \
  "$(grep -cF 'kept       teardown  (round not green — boxes LEFT STANDING to inspect)' \
    <<<"$unwired_out")"

# Agreement is two-way: a summary result without a declaration must remain
# visible and red rather than falling outside the generated inventory.
UNDECLARED="$HARNESS/rehearsal-all-undeclared.sh"
sed 's/hygiene breaker resume/hygiene resume/' \
  "$HARNESS/rehearsal-all.sh" >"$UNDECLARED"
if undeclared_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" bash "$UNDECLARED" --tree "$SOURCE" --roles reviewer \
      --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  undeclared_rc=0
else
  undeclared_rc=$?
fi
t drill-undeclared-summary-leg-reds 1 "$undeclared_rc"
t drill-undeclared-summary-leg-is-visible 1 \
  "$(grep -c '^## leg undeclared breaker  (summary result has no declaration)' \
    <<<"$undeclared_out")"

# Not-executed is not a sufficient record by itself: the blocker is the fact
# that makes an exclusion evidence. Remove one reason and require a red row.
NO_REASON="$HARNESS/rehearsal-all-no-reason.sh"
sed 's/SUMMARY+=("skip       browser  (--no-app)")/SUMMARY+=("skip       browser")/' \
  "$HARNESS/rehearsal-all.sh" >"$NO_REASON"
if no_reason_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" bash "$NO_REASON" --tree "$SOURCE" --roles reviewer \
      --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  no_reason_rc=0
else
  no_reason_rc=$?
fi
t drill-unrun-leg-without-blocker-reds 1 "$no_reason_rc"
t drill-unrun-leg-without-blocker-is-visible 1 \
  "$(grep -c '^## leg not-executed browser  (missing blocker reason)' \
    <<<"$no_reason_out")"

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
# shellcheck disable=SC2016  # literal Markdown backticks in the record row
t drill-phase2-section-a-return-is-recorded 1 \
  "$(grep -cF 'PASS: Section A returned `crew-drill-reviewer` disarmed' <<<"$phase2_out")"
t drill-phase2-failure-runs-config 1 \
  "$(grep -cF 'ok         config  (operator mode + registry contract)' <<<"$phase2_out")"
t drill-phase2-failure-runs-app 1 \
  "$(grep -cF 'ok         app  (agreement compared; collector + page)' <<<"$phase2_out")"
t drill-phase2-records-browser-executed 1 \
  "$(grep -c '^## leg executed browser  (ok; read-only browser walk executed)' \
    <<<"$phase2_out")"
t drill-phase2-records-app-armed-blocker 1 \
  "$(grep -c '^## leg not-executed app-armed  (skip; not requested: no --app-roster; requires an armed member)' \
    <<<"$phase2_out")"
t drill-phase2-failure-invokes-config-and-app $'config\napp' "$(cat "$SECTION_LOG")"
t drill-phase2-summary-counts-four-passed 1 \
  "$(grep -cE '^## section states: 4 passed, 1 failed, [0-9]+ skipped/not-run$' <<<"$phase2_out")"

if armed_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_SECTION_A_ARMED=1 bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" \
      --roles reviewer --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  armed_rc=0
else
  armed_rc=$?
fi
t drill-section-a-armed-return-reds 1 "$armed_rc"
# shellcheck disable=SC2016  # literal Markdown backticks in the record row
t drill-section-a-armed-return-is-recorded 1 \
  "$(grep -cF 'FAIL: Section A returned `crew-drill-reviewer` armed' <<<"$armed_out")"

if unreadable_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_SECTION_A_UNREADABLE=1 bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" \
      --roles reviewer --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  unreadable_rc=0
else
  unreadable_rc=$?
fi
t drill-section-a-unreadable-return-reds 1 "$unreadable_rc"
# shellcheck disable=SC2016  # literal Markdown backticks in the record row
t drill-section-a-unreadable-return-is-recorded 1 \
  "$(grep -cF 'FAIL: Section A returned `crew-drill-reviewer` with crontab state unreadable' \
    <<<"$unreadable_out")"

# The third historical zero-execution leg also records a discovered host
# blocker rather than disappearing inside app's aggregate result.
if browser_skip_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_BROWSER_STATUS=skip DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
  browser_skip_rc=0
else
  browser_skip_rc=$?
fi
t drill-browser-blocker-makes-round-incomplete 2 "$browser_skip_rc"
t drill-browser-blocker-is-named-in-record 1 \
  "$(grep -c '^## leg not-executed browser  (INCOMPLETE; not executed: playwright-core not installed)' \
    <<<"$browser_skip_out")"

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
  "$(grep -cF 'ok         app-armed  (agreement compared; named roster, no additional boxes)' \
    <<<"$app_roster_out")"

# The named pass carries its own honest verdict. Exercise both non-green
# summaries rather than letting a stubbed `compared` make them dead branches.
if app_roster_incomplete_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_APP_ROSTER_STATUS=could-not-compare \
    DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  app_roster_incomplete_rc=0
else
  app_roster_incomplete_rc=$?
fi
t drill-armed-roster-noncomparable-is-incomplete 2 "$app_roster_incomplete_rc"
t drill-armed-roster-noncomparable-recorded 1 \
  "$(grep -cF 'INCOMPLETE app-armed  (agreement could-not-compare: no armed, ticking, clock-skewed box)' \
    <<<"$app_roster_incomplete_out")"

if app_roster_missing_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_APP_ROSTER_STATUS=missing DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  app_roster_missing_rc=0
else
  app_roster_missing_rc=$?
fi
t drill-armed-roster-missing-verdict-is-red 1 "$app_roster_missing_rc"
t drill-armed-roster-missing-verdict-recorded 1 \
  "$(grep -cF 'FAIL       app-armed  (agreement verdict missing)' \
    <<<"$app_roster_missing_out")"

if app_failure_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_APP_RC=1 DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  app_failure_rc=0
else
  app_failure_rc=$?
fi
t drill-app-failure-is-red 1 "$app_failure_rc"
t drill-detail-less-failure-record-closes-parenthesis 1 \
  "$(grep -c '^## leg executed app-armed  (FAIL)$' <<<"$app_failure_out")"

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
  "$(grep -cF 'INCOMPLETE app  (agreement could-not-compare: no armed, ticking, clock-skewed box)' \
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
phase2_wrong_count="${phase2_out/4 passed, 1 failed/5 passed, 0 failed}"
if grep -qE '^## section states: 4 passed, 1 failed, [0-9]+ skipped/not-run$' \
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

# --- the runbook documents exactly the legs the harness declares (#497) ------
# shared/docs/rehearsal.md is the prose an operator reads before a round, and
# it went a whole release without describing a single leg that release added.
# A census catches that once; this diff catches it every time. Both directions
# are asserted because they are different defects: a leg in the harness and not
# in the runbook is an operator running something nobody explained, and a leg
# in the runbook and not in the harness is an operator preparing for a leg that
# will never appear in the record.
#
# Neither side is a list maintained here. The harness's side is its own
# DECLARED_LEGS array — the same declaration the round checks its record
# against — and the runbook's side is the headings under `## The legs`, which
# that section states are the leg names. A third copy in this file would be the
# thing that drifts.
RUNBOOK="$ROOT/shared/docs/rehearsal.md"

runbook_harness_legs() {  # the harness's own declaration, one per line
  sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$ROOT/drill/rehearsal-all.sh" \
    | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d' | sort -u
}

runbook_documented_legs() {  # the `### <leg>` headings under `## The legs`
  awk '/^## The legs$/ { inside = 1; next }
       /^## / { inside = 0 }
       inside' "$RUNBOOK" \
    | sed -n 's/^### \([a-z][a-z-]*\)[^a-z-].*$/\1/p' | sort -u
}

runbook_prose_legs() {  # the enumerating sentence, read to its blank line
  # shellcheck disable=SC2016  # the backticks are Markdown in the runbook
  awk '/^The declared legs are:/ { inside = 1 }
       inside && /^$/ { exit }
       inside' "$RUNBOOK" \
    | grep -oE '`[a-z][a-z-]*`' | tr -d '`' | sort -u
}

t drill-runbook-harness-declares-legs 12 "$(runbook_harness_legs | n)"
t drill-runbook-documents-every-declared-leg '' \
  "$(comm -23 <(runbook_harness_legs) <(runbook_documented_legs) | paste -sd, -)"
t drill-runbook-documents-no-undeclared-leg '' \
  "$(comm -13 <(runbook_harness_legs) <(runbook_documented_legs) | paste -sd, -)"
# The section's own enumerating sentence is a third surface and drifts like any
# other, so it is held to the same declaration rather than to the headings.
t drill-runbook-prose-list-matches-declaration '' \
  "$(comm -3 <(runbook_harness_legs) <(runbook_prose_legs) | tr -d '\t' \
    | paste -sd, -)"

# Mutation: the leg the harness gained but nobody wrote up — the exact shape of
# this issue's own finding. Both the census and the runbook go stale silently,
# so the assertion above has to red on a declaration it has never seen.
MUTATED_ALL="$TMP/rehearsal-all-extra-leg.sh"
sed 's/^  installer config app browser app-armed teardown$/  installer config app browser app-armed teardown newleg/' \
  "$ROOT/drill/rehearsal-all.sh" >"$MUTATED_ALL"
t drill-runbook-extra-leg-mutation-applied 1 \
  "$(sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$MUTATED_ALL" \
    | grep -cw newleg || true)"
t drill-runbook-extra-leg-is-undocumented newleg \
  "$(comm -23 \
      <(sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$MUTATED_ALL" \
        | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d' | sort -u) \
      <(runbook_documented_legs) | paste -sd, -)"

# Mutation: a leg described in prose that the harness does not have. An
# operator prepares a prerequisite for a leg that can never reach the record.
MUTATED_DOC="$TMP/rehearsal-ghost-leg.md"
awk '{ print }
     /^### teardown — / { print ""; print "### ghostleg — a leg the harness does not have" }' \
  "$RUNBOOK" >"$MUTATED_DOC"
t drill-runbook-ghost-leg-mutation-applied 1 \
  "$(grep -cF '### ghostleg — ' "$MUTATED_DOC" || true)"
t drill-runbook-ghost-leg-is-undeclared ghostleg \
  "$(comm -13 <(runbook_harness_legs) \
      <(RUNBOOK="$MUTATED_DOC" runbook_documented_legs) | paste -sd, -)"

# The runbook describes the harness AFTER this window's repairs: the record it
# sends an operator to is the declared-leg block #495 landed, and the routing
# it describes is #492's derivation rather than the literal PR number that
# stood at :63 and :233. A number here is the same defect as a number in the
# scripts, which the assertion above already forbids.
t drill-runbook-names-the-declared-leg-record present \
  "$(grep -qF '## declared leg states:' "$RUNBOOK" && echo present || echo absent)"
t drill-runbook-hardcodes-no-pr-number 0 \
  "$(grep -cE 'PR #[0-9]' "$RUNBOOK" || true)"

# --- the drill box is minted at the drilled role's own size (#607 D4) -------
# rehearsal.sh minted every role at a flat 2 cpu / 4GiB / 20GiB, which is not
# what `crew new` does for any role in the fleet — so the one thing a green
# rehearsal could never say anything about was role sizing, and it took an
# OOM-killed reviewer to find that out.
#
# The production block is EXTRACTED AND RUN, not grepped: what matters is the
# three figures it resolves for a given role, and a grep would go green on a
# block that read the right file and resolved nothing from it.
# shellcheck disable=SC2016  # match literal production shell source
size_block="$(sed -n '/^ROLE_CONF="\$SOURCE_TREE/,/^fi$/p' "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # the printf runs in the CHILD, on its variables
drill_size_for() { # ROLE [TREE]
  env SOURCE_TREE="${2:-$ROOT}" ROLE="$1" bash -c \
    "$size_block"'; printf "%s %s %s\n" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK"' 2>&1
}
conf_size_for() { # ROLE
  bash -c '. "$1"; printf "%s %s %s\n" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK"' \
    _ "$SHARED/conf/roles/$1.conf"
}
for drill_role in reviewer triage builder; do
  t "drill-box-sized-at-$drill_role-role-size" "$(conf_size_for "$drill_role")" \
    "$(drill_size_for "$drill_role")"
done
# ...and the roles must not all resolve to one size, which is the defect this
# replaces and the state three equal comparisons above would still pass in.
t drill-box-size-differs-by-role different \
  "$([ "$(drill_size_for reviewer)" != "$(drill_size_for triage)" ] \
      && echo different || echo identical)"

# No size literal remains in that file. Comments are excluded from the
# population on purpose — the block's own comment quotes the literal it
# removed, and a guard that could not survive being explained would be
# rewritten rather than kept.
t drill-role-script-holds-no-size-literal 0 \
  "$(grep -vE '^[[:space:]]*#' "$ROOT/drill/rehearsal.sh" \
     | grep -cE -- '--(cpu|memory|disk)[= ]+[0-9]' || true)"

# The role conf is a REQUIRED INPUT, declared with the drill's other three, so
# a source that cannot say how big a $ROLE box is is refused at acquisition and
# attributed like every other missing input — not later, as a box step that
# stopped for reasons of its own.
# shellcheck disable=SC2016  # match literal production shell source
t drill-role-conf-is-a-required-input 1 \
  "$(grep -c '^for required in .*shared/conf/roles/\$ROLE\.conf' "$ROOT/drill/rehearsal.sh" || true)"

# A conf that declares no figures is REFUSED, not guessed past: minting at a
# size the fleet does not use is what this leg exists to stop.
DRILL_NOSIZE="$TMP/nosize-tree"
mkdir -p "$DRILL_NOSIZE/shared/conf/roles"
printf 'TIMEOUT_REVIEW=1\n' >"$DRILL_NOSIZE/shared/conf/roles/reviewer.conf"
nosize_out="$(drill_size_for reviewer "$DRILL_NOSIZE")"; nosize_rc=$?
t drill-box-size-undeclared-is-refused 1 "$nosize_rc"
t drill-box-size-undeclared-says-why 1 \
  "$(grep -c 'declares no BOX_CPU' <<<"$nosize_out" || true)"
missing_out="$(drill_size_for reviewer "$TMP/no-such-tree")"; missing_rc=$?
t drill-box-size-missing-conf-is-refused 1 "$missing_rc"
t drill-box-size-missing-conf-names-the-path 1 \
  "$(grep -c 'no role conf at' <<<"$missing_out" || true)"

# --- the drill mints through the ONE writer (#679 D9) -----------------------
# The drill carried its own copy of `box new --template "$AGENT-box"`, and box
# 0.10.0 refuses that spelling — so on a host at the version `crew down --force`
# requires, phase 0 died at box creation with `exit 1` before a single assertion
# ran. Gate A could not fail late and be read; it could not START.
#
# PINNED IN TWO PLACES, BECAUSE ONE OF THEM CANNOT FAIL ON ITS OWN. This suite
# stubs the role script wholesale, so nothing here executes rehearsal.sh's mint
# and a source-text guard is all this file can offer for the call site. What it
# CAN do is drive the helper that call site now runs — the same function, the
# same argv, against a stub box — so the sequence itself is asserted
# behaviourally and the drill's line is asserted to be a call into it. Between
# them, reintroducing a hand-spelled mint in rehearsal.sh reds here.

# The call site: one call into the writer, and no mint of its own. Comments are
# stripped first — this file explains the retirement it is subject to, and a
# guard that could not survive being explained would be rewritten rather than
# kept, which is the rule the size-literal guard above already states.
DRILL_CODE="$(grep -vE '^[[:space:]]*#' "$ROOT/drill/rehearsal.sh")"
t drill-mint-names-no-retired-template 0 \
  "$(grep -c -- '--template' <<<"$DRILL_CODE" || true)"
t drill-mint-spells-no-box-new-of-its-own 0 \
  "$(grep -cE '(^|[^_[:alnum:]])box new' <<<"$DRILL_CODE" || true)"
# shellcheck disable=SC2016  # match the literal production shell source
t drill-mint-calls-the-one-writer 1 \
  "$(grep -c 'box_mint_fresh "\$BOX_NAME" "\$AGENT"' <<<"$DRILL_CODE" || true)"
# The log line named a template that no longer exists, which is the half a fix
# to the command alone leaves behind: a green drill narrating a retired object.
t drill-mint-log-line-names-no-template 0 \
  "$(grep -c 'minting .*template' <<<"$DRILL_CODE" || true)"

# The helper is read out of $SOURCE_TREE and the drill refuses a source that
# predates it, rather than falling back to a spelling it would then own a second
# copy of.
t drill-mint-helper-is-a-required-input 1 \
  "$(grep -c 'no mint helper at' <<<"$DRILL_CODE" || true)"

# ONE writer in the whole tree (#679 D9's criterion, read directly): exactly one
# site invokes the bootstrap. Comments are stripped, and cli/crew's operator
# recovery line — which PRINTS the command for a human to type rather than
# running it — is not an invocation and is excluded by the leading-`rig` anchor.
t drill-bootstrap-has-exactly-one-writer 1 \
  "$(grep -rn --include='*.sh' --include=crew -hE '^[[:space:]]*rig bootstrap ' \
       "$ROOT/cli" "$ROOT/shared/lib" "$ROOT/drill" 2>/dev/null | wc -l | tr -d ' ')"

# ...and behaviourally, at the box transport boundary. This is the drill's own
# mint: the same function phase 0 calls, driven with a stub `box` on PATH.
MINT_SHIM="$TMP/mint-shim"
MINT_STATE="$TMP/mint-state"
mkdir -p "$MINT_SHIM" "$MINT_STATE"
cat >"$MINT_SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  new) shift; printf 'new %s\n' "$*" >>"$MINT_STATE/calls" ;;
  root) printf 'root %s\n' "$2" >>"$MINT_STATE/calls"; cat >"$MINT_STATE/script-$2" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$MINT_SHIM/box"
mint_out="$(
  export MINT_STATE PATH="$MINT_SHIM:$PATH"
  # shellcheck source=shared/lib/box-mint.sh
  . "$ROOT/shared/lib/box-mint.sh"
  box_mint_fresh crew-drill-reviewer kimi 4 8GiB 60GiB 2>&1
)"; mint_rc=$?
t drill-mint-sequence-exits-zero 0 "$mint_rc"
# A mint that worked says nothing: the repair advice below is for the box that
# was created and then not converged, and printing it on the success path would
# make it noise a reader learns to skip.
t drill-mint-sequence-is-quiet-when-it-works "" "$mint_out"
t drill-mint-sequence-is-blank-at-the-roles-size \
  "new --name crew-drill-reviewer --user kimi --cpu 4 --memory 8GiB --disk 60GiB" \
  "$(grep '^new ' "$MINT_STATE/calls")"
t drill-mint-sequence-opens-the-root-door \
  "root crew-drill-reviewer" "$(grep '^root ' "$MINT_STATE/calls")"
t drill-mint-sequence-bootstraps-the-agents-role \
  "rig bootstrap kimi-box" \
  "$(grep -E '^rig bootstrap ' "$MINT_STATE/script-crew-drill-reviewer" || true)"
t drill-mint-sequence-emits-no-template 0 \
  "$(grep -c -- '--template' "$MINT_STATE/calls" || true)"
t drill-mint-sequence-bootstrap-names-no-user 0 \
  "$(grep -c -- '--user' "$MINT_STATE/script-crew-drill-reviewer" || true)"

# --- the attention census: recorded, then asserted, never refused (#714) -----
#
# Phase 2 used to exit 1 the moment the box identity carried an `attention`
# demand in any repository outside the sandbox, which is a real account's
# normal state — so Gate A could not run on the operator's own host and every
# role loop stayed UNPROVEN. Both halves of the replacement are driven here:
# the census that records those demands before the first authenticated tick,
# and the assertion that reads the engine's own suppressed report back after
# it. Every box read goes through the caller's bx(), so none of this needs a
# drill host, credentials, or a network.
ATT_SANDBOX="host/crew-drill-builder"
ATT_MARK="📌 picked up"
ATT_CENSUS=""
ATT_CENSUS_PAGE2=""
ATT_CENSUS_RC=0
ATT_MARK_CONF="$ATT_MARK"
ATT_LABEL_CONF="attention"
ATT_LOG_BASE=10
ATT_LOG_GEN=111
ATT_SLICE=current
ATT_SCOPE=""
ATT_LOG=""
ATT_PICKUPS_BEFORE=""
ATT_PICKUPS_AFTER=""
# Set to a directory and the log reads stop being fixture strings: the command
# the host composed is EVAL'd against a real duty.log under that HOME, so
# `stat`, `tail` and a real `mv` decide the answer. Group (h) is the only
# caller, because that is the only group about the file moving. A fixture that
# re-implemented the branch host-side would pass under its own mutation.
ATT_BOX_HOME=""
# What the box did BETWEEN the two halves — which, on the real host, is the
# tick. Eval'd inside att_drive's subshell.
ATT_BETWEEN=""
# When set, the comment read must carry this mark or the box declines.
ATT_MARK_EXPECT=""

# att_box_conf DEFAULTS_LABEL DEFAULTS_MARK [FLEET_LABEL FLEET_MARK] — the two
# real configuration files under ATT_BOX_HOME, so the conf read is executed
# rather than answered. With no third argument the box has no operator file.
att_box_conf() {
  mkdir -p "$ATT_BOX_HOME/duty/conf"
  printf 'LABEL_ATTENTION="%s"\nMARK_PICKUP="%s"\n' "$1" "$2" \
    >"$ATT_BOX_HOME/duty/conf/fleet.defaults.conf"
  rm -f "$ATT_BOX_HOME/duty/conf/fleet.conf"
  [ "$#" -lt 3 ] || printf 'LABEL_ATTENTION="%s"\nMARK_PICKUP="%s"\n' "$3" "$4" \
    >"$ATT_BOX_HOME/duty/conf/fleet.conf"
}

# The box, in the reads the two halves make of it. Each answer is a fixture
# variable, and `X` in a pickup table is the box declining to answer — the
# state the predicates must red on rather than read as zero.
att_bx() {
  local cmd="$1" key table v
  case "$cmd" in
    *'/issues?filter=assigned'*)
      [ "$ATT_CENSUS_RC" -eq 0 ] || return 1
      # The endpoint answers the label it was ASKED for, and nothing else. A
      # census keyed on a name the operator moved away from reads an empty set
      # off a board that is full — group (i).
      case "$cmd" in
        *"labels=$ATT_LABEL_CONF"*) ;;
        *) return 0 ;;
      esac
      [ -z "$ATT_CENSUS" ] || printf '%s\n' "$ATT_CENSUS"
      # ...and a second page that exists on the server and is invisible to a
      # read which does not ask for it, which is how the endpoint behaves and
      # what group (f) is about. Empty everywhere else, so every other case
      # sees the single-page box it always saw.
      case "$cmd" in
        *--paginate*) [ -z "$ATT_CENSUS_PAGE2" ] || printf '%s\n' "$ATT_CENSUS_PAGE2" ;;
      esac
      ;;
    # A REAL BOX HOME RUNS THE COMMAND IN A FRESH SHELL, not `eval`. The real
    # transport is `box exec … bash -lc` (drill/rehearsal.sh), which starts
    # with bash's default options; `eval` runs it inside THIS suite, which sets
    # `-u` and `pipefail` on line 3. A composed command that relies on either
    # then passes here and fails in the box — and worse, one that SETS
    # `pipefail` for itself cannot be mutated away in a harness that was
    # supplying it anyway: dropping it left drill.sh green while the shipped
    # read laundered a failed `head` into the checksum of nothing (round 1).
    # A fixture must not hand the implementation an option the box will not.
    #
    # Its stderr is dropped, and only its stderr: the composed command does not
    # muffle its own reads — in a real drill those messages belong on the
    # operator's console — and the two unreadable-log groups make them shout. A
    # suite that prints `error reading` while passing teaches a reader to skim
    # past the word. What the fixture actually claims is a graded row, not
    # noise: `…-fixture-really-cannot-read` asserts the read fails.
    #
    # One read, two values, resolved two different ways (the label takes the
    # operator's fleet.conf, the wire mark does not) — so the fixture answers
    # with the pair the box's own configuration would.
    *fleet.defaults.conf*)
      if [ -n "$ATT_BOX_HOME" ]; then ( HOME="$ATT_BOX_HOME"; bash -c "$cmd" 2>/dev/null )
      else printf '%s\n%s\n' "$ATT_LABEL_CONF" "$ATT_MARK_CONF"; fi ;;
    # The line count AND the generation it was counted against.
    *'wc -l < ~/duty/duty.log'*)
      if [ -n "$ATT_BOX_HOME" ]; then ( HOME="$ATT_BOX_HOME"; bash -c "$cmd" 2>/dev/null )
      else printf '%s %s\n' "$ATT_LOG_BASE" "$ATT_LOG_GEN"; fi ;;
    # The duty.log slice read — matched on a string only the composed command
    # carries, so it cannot be confused with the count above.
    *'slice: lost'*)
      if [ -n "$ATT_BOX_HOME" ]; then ( HOME="$ATT_BOX_HOME"; bash -c "$cmd" 2>/dev/null )
      else
        printf 'slice: %s\n' "$ATT_SLICE"
        [ "$ATT_SLICE" = lost ] || [ -z "$ATT_LOG" ] || printf '%s\n' "$ATT_LOG"
      fi ;;
    *suppressed-attention-scope*) [ -z "$ATT_SCOPE" ] || printf '%s\n' "$ATT_SCOPE" ;;
    *'/comments?per_page=100'*)
      # A comment search for a mark nothing writes finds nothing, and this box
      # says so by declining rather than by answering 0 — the delta's own
      # fail-closed branch. Group (i) sets this to the WIRE mark, so a read
      # that let fleet.conf move it is killed on behaviour.
      case "${ATT_MARK_EXPECT:-}" in
        '') ;;
        *) case "$cmd" in *"$ATT_MARK_EXPECT"*) ;; *) return 1 ;; esac ;;
      esac
      key="$(sed -n "s|.*repos/\([^']*\)/issues/\([0-9]*\)/comments.*|\1#\2|p" <<<"$cmd")"
      if [ "${ATT_PHASE:-before}" = before ]; then table="$ATT_PICKUPS_BEFORE"; else table="$ATT_PICKUPS_AFTER"; fi
      v="$(awk -v k="$key" '$1 == k { print $2; exit }' <<<"$table")"
      [ "$v" != X ] || return 1
      printf '%s\n' "${v:-0}"
      ;;
    *) return 1 ;;
  esac
}

# att_drive take|both [drain] — run the halves against the fixture box and
# print the rows they emit. The caller supplies ok()/fail() exactly as
# rehearsal.sh does, so a row's GRADE is observed and not inferred from a
# return code.
#
# `drain` is the REAL transport's stdin behaviour, and without it this harness
# cannot see the defect it is here to pin: rehearsal.sh's bx() is `box exec …
# bash -lc`, and `box exec` DRAINS the stdin it inherits (drill/rehearsal-app.sh
# :540-550, found by running that leg and not by reading it). A plain att_bx
# never touches stdin, so a per-demand box read that eats its own loop reads
# green through it. The subshell's own stdin is /dev/null so the drain
# terminates on every call rather than on a terminal — the loop input a
# truncating implementation eats is its `<<<` here-string, which is inside the
# function either way.
att_drive() {
  (
    ok()   { echo "ok $1"; }
    fail() { echo "FAIL $1"; }
    if [ "${2:-}" = drain ]; then
      bx() { cat >/dev/null 2>&1 || true; att_bx "$1"; }
    else
      bx() { att_bx "$1"; }
    fi
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    ATT_PHASE=before
    rehearsal_attention_census_take "$ATT_SANDBOX" || echo "TAKE-RC=$?"
    [ "$1" = both ] || exit 0
    # The tick, in whatever the group needs it to have done to the box.
    [ -z "$ATT_BETWEEN" ] || eval "$ATT_BETWEEN"
    ATT_PHASE=after
    rehearsal_attention_census_assert "$ATT_SANDBOX" || echo "ASSERT-RC=$?"
  ) </dev/null
}

# att_pickup_rows ROWS — the pickup census in isolation, through a draining
# box, so a truncated table is unambiguously that function's and not a grading
# artifact somewhere above it.
att_pickup_rows() {
  (
    bx() { cat >/dev/null 2>&1 || true; att_bx "$1"; }
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    ATT_PHASE=before
    rehearsal_attention_pickup_counts "$1" "$ATT_MARK"
  ) </dev/null
}
att_ok()   { grep -c '^ok ' <<<"$1" || true; }
att_fail() { grep -c '^FAIL ' <<<"$1" || true; }

# (a) two demands parked outside the sandbox, and a tick that suppressed both.
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\n')"
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_PICKUPS_BEFORE="$(printf 'heavy-duty/incubator#468 0\nheavy-duty/incubator#469 3\n')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"
ATT_BOTH="$(att_drive both)"
# The demand is RECORDED and the round continues. This is the case that made
# Gate A unrunnable on the operator's host: before #714 the preamble exited 1
# here, and there was no census to take.
t drill-attention-census-records-two 1 \
  "$(grep -c '^ok attention census: 2 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_BOTH" || true)"
t drill-attention-census-names-each-demand 2 \
  "$(grep -c '^  census: heavy-duty/incubator#46[89]$' <<<"$ATT_BOTH" || true)"
t drill-attention-census-suppressed-both-green 0 "$(att_fail "$ATT_BOTH")"
# Six rows, counted rather than approximated: the census row, the one negative
# session row, and a suppressed + no-pickup pair PER recorded demand. A leg
# that graded the demands as a set would read green here with two rows.
t drill-attention-census-suppressed-rows 7 "$(att_ok "$ATT_BOTH")"
# A demand that already carried pickup comments from an earlier life is not a
# failure: the assertion is a DELTA across the tick, and #469 arrives with 3.
t drill-attention-census-standing-pickups-are-not-a-pickup 1 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#469 drew no pickup$' <<<"$ATT_BOTH" || true)"

# The log line alone is enough when the state file has been emptied: both
# records are accepted, because report_suppressed writes the line only on a
# CHANGE and removes the file when the set empties.
ATT_SCOPE=""
t drill-attention-census-log-line-alone-is-evidence 0 "$(att_fail "$(att_drive both)")"
# ...and the state file alone is enough when the line was written on an earlier
# tick, which is every --reuse pass.
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_LOG='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
t drill-attention-census-scope-state-alone-is-evidence 0 "$(att_fail "$(att_drive both)")"

# (b) one recorded demand with neither record naming it — the D3 miss.
ATT_SCOPE='heavy-duty/incubator#468 2026-09-10T21:00:00Z'
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 1 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_MISS="$(att_drive both)"
t drill-attention-census-unsuppressed-demand-fails 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#469 seen and suppressed$' <<<"$ATT_MISS" || true)"
t drill-attention-census-unsuppressed-names-what-it-read 1 \
  "$(grep -c '^  read: neither ~/duty/.suppressed-attention-scope nor an "attention: outside repos.txt" line names heavy-duty/incubator#469$' <<<"$ATT_MISS" || true)"
# ...and the round stops: the half returns non-zero, which is what rehearsal.sh
# exits on before another tick can strike.
t drill-attention-census-unsuppressed-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_MISS" || true)"
# The demand that WAS suppressed still reads green beside it — a miss is per
# demand, not a verdict on the census.
t drill-attention-census-miss-is-per-demand 1 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#468 seen and suppressed$' <<<"$ATT_MISS" || true)"

# (c) a session dispatched to a repository other than the sandbox.
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=heavy-duty/incubator#468 timeout=1800s log=/l holder=x sid=2')"
ATT_STRAY="$(att_drive both)"
t drill-attention-census-outside-session-fails 1 \
  "$(grep -c '^FAIL attention census: no attention session launched outside host/crew-drill-builder$' <<<"$ATT_STRAY" || true)"
t drill-attention-census-outside-session-quotes-the-record 1 \
  "$(grep -c '^  read: SESSION START kind=attention key=heavy-duty/incubator#468 ' <<<"$ATT_STRAY" || true)"
t drill-attention-census-outside-session-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_STRAY" || true)"

# A new pickup comment across the tick is the third miss, and the one that says
# the wake actually ACTED on a demand outside the registry.
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_PICKUPS_AFTER="$(printf 'heavy-duty/incubator#468 1\nheavy-duty/incubator#469 3\n')"
ATT_PICKED="$(att_drive both)"
t drill-attention-census-new-pickup-fails 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#468 drew no pickup$' <<<"$ATT_PICKED" || true)"
t drill-attention-census-new-pickup-quotes-the-delta 1 \
  "$(grep -c '^  read: heavy-duty/incubator#468 drew 1 new "📌 picked up" comment(s) across the tick (0 -> 1)$' <<<"$ATT_PICKED" || true)"
# A comment read the box would not answer is a red, not a zero: an absence is
# established by reading the source, never by failing to read it.
ATT_PICKUPS_AFTER="$(printf 'heavy-duty/incubator#468 X\nheavy-duty/incubator#469 3\n')"
ATT_UNREAD="$(att_drive both)"
t drill-attention-census-unreadable-comments-fail 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#468 drew no pickup$' <<<"$ATT_UNREAD" || true)"
t drill-attention-census-unreadable-comments-say-so 1 \
  "$(grep -c '^  read: could not read the "📌 picked up" comment count of heavy-duty/incubator#468 (before: 0, after: unreadable)$' <<<"$ATT_UNREAD" || true)"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"

# (d) an identity carrying nothing outside the sandbox: the census reports 0
# and the leg asserts nothing, which is the behaviour that shipped before this.
ATT_CENSUS=""
ATT_ZERO="$(att_drive both)"
t drill-attention-census-zero-reports-zero 1 \
  "$(grep -c '^ok attention census: 0 demand(s) parked outside host/crew-drill-builder$' <<<"$ATT_ZERO" || true)"
t drill-attention-census-zero-asserts-nothing 1 "$(att_ok "$ATT_ZERO")"
t drill-attention-census-zero-is-green 0 "$(att_fail "$ATT_ZERO")"

# The census fails CLOSED. The read it replaced ended in `|| true`, so a box
# that would not answer read as a clean bill of health; the caller refuses on
# this rc, and the reason it prints comes back in the same variable.
ATT_CENSUS_RC=1
ATT_UNANSWERED="$(att_drive take)"
t drill-attention-census-unreadable-box-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$ATT_UNANSWERED" || true)"
t drill-attention-census-unreadable-box-emits-no-row 0 "$(att_ok "$ATT_UNANSWERED")"
ATT_CENSUS_RC=0
# ...and so does a box whose installed configuration resolves no MARK_PICKUP: a
# no-pickup assertion counting a needle nothing writes is green on every board.
ATT_CENSUS='heavy-duty/incubator 468'
ATT_MARK_CONF=""
t drill-attention-census-no-mark-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$(att_drive take)" || true)"
ATT_MARK_CONF="$ATT_MARK"

# The refusal itself is gone from the preamble. A census that reads everything
# correctly and is still guarded by an `exit` on a non-empty result would leave
# Gate A exactly where #714 found it, and no fixture above would notice.
t drill-attention-census-preamble-refuses-no-parked-demand 0 \
  "$(grep -c 'no parked demand outside' "$ROOT/drill/rehearsal.sh" || true)"
# shellcheck disable=SC2016  # a literal source match: "$SANDBOX" is the text
t drill-attention-census-preamble-calls-both-halves 2 \
  "$(grep -cE 'rehearsal_attention_census_(take|assert) "\$SANDBOX"' "$ROOT/drill/rehearsal.sh" || true)"
# The assertion must run AFTER the wake rows: the suppressed report it reads is
# written by the same duty_attention call, above the same partition, that
# dispatched the sandbox demand. Read earlier it would be some other tick's.
t drill-attention-census-asserts-after-the-wake ordered \
  "$(awk '/rehearsal_attention_census_take/{take=NR}
          /label removed \(ack re-arms\)/{wake=NR}
          /rehearsal_attention_census_assert/{assert=NR}
          END{print (take && wake && assert && take < wake && wake < assert) ? "ordered" : "OUT-OF-ORDER"}' \
      "$ROOT/drill/rehearsal.sh")"
# ...and the sandbox demand must be minted BEFORE the census is taken (#714,
# round 4). Both reads are one page of an endpoint that answers newest first,
# so minting after the census displaces the OLDEST outside demand off the page
# the engine will fetch, and the assert half then grades a row no correct
# engine can hold a record for. Group (g) below drives that failure; this row
# is the ordering it turns on, and no fixture driving the two halves can pin
# it, because the mint is the caller's and not theirs.
#
# The census still precedes the wake marker: it captures duty.log's length,
# and D3's negative-session assertion reads only what was written after it.
t drill-attention-census-mints-the-sandbox-demand-first ordered \
  "$(awk '/drill: attention wake /{ if (!mint) mint = NR }
          /rehearsal_attention_census_take/{ if (!take) take = NR }
          /-- attention wake --/{ if (!wake) wake = NR }
          END{print (mint && take && wake && mint < take && take < wake) ? "ordered" : "OUT-OF-ORDER"}' \
      "$ROOT/drill/rehearsal.sh")"

# (e) THE PER-DEMAND BOX READ MUST NOT EAT THE LOOP IT RUNS IN (#714, round 1).
#
# Every case above drives a box that never touches stdin, and the real one
# drains it. A pickup census whose read swallowed its own row list counted the
# FIRST demand and nothing else — and did not fail quietly: demands 2..N took
# the fail-closed `could not read` branch, the assert half returned 1, and
# rehearsal.sh refused the round. That is acceptance criterion 1 unmet on every
# identity carrying more than one parked demand, which is the host this issue
# was minted from (heavy-duty/incubator #468, #469, #470 on dan-office-workstation).
#
# THREE demands, not two: one cannot tell a loop that ran once from a loop that
# ran, and two cannot tell a loop that ran once from a loop that read the row
# list one line short.
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\nheavy-duty/incubator 470\n')"
ATT_SCOPE="$(printf '%s\n' \
  'heavy-duty/incubator#468 2026-09-10T21:00:00Z' \
  'heavy-duty/incubator#469 2026-09-10T21:00:01Z' \
  'heavy-duty/incubator#470 2026-09-10T21:00:02Z')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 3 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) heavy-duty/incubator#470(2026-09-10T21:00:02Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_PICKUPS_BEFORE="$(printf '%s\n' \
  'heavy-duty/incubator#468 0' 'heavy-duty/incubator#469 0' 'heavy-duty/incubator#470 0')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"
# The function alone, so a short table is unambiguously its own doing.
t drill-attention-census-pickup-read-does-not-eat-its-loop 3 \
  "$(att_pickup_rows "$ATT_CENSUS" | grep -c . || true)"
t drill-attention-census-pickup-read-names-the-last-demand 1 \
  "$(att_pickup_rows "$ATT_CENSUS" | grep -c '^heavy-duty/incubator#470 0$' || true)"
# ...and the whole leg through the same box: eight rows (the census row, the
# negative session row, and a suppressed + no-pickup pair per demand), no FAIL,
# and no refusal. A truncating read reds the last two pairs on the branch
# written for a box that will not answer, which reads as a real finding.
ATT_DRAIN="$(att_drive both drain)"
t drill-attention-census-draining-box-grades-every-demand 3 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#4[0-9]* drew no pickup$' <<<"$ATT_DRAIN" || true)"
t drill-attention-census-draining-box-is-green 0 "$(att_fail "$ATT_DRAIN")"
t drill-attention-census-draining-box-rows 9 "$(att_ok "$ATT_DRAIN")"
t drill-attention-census-draining-box-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_DRAIN" || true)"
# The OTHER direction the drain runs in, and the second guard's own kill: the
# read closes its own stdin, so it cannot eat a CALLER's loop either. Nothing
# drives this function per row today; the fd-3 guard above protects its own
# loop and could not protect that one, which is why the redirect is on the call
# as well. Both rows red if either guard is dropped, and neither is a grep for
# source text.
att_pickup_rows_nested() {
  (
    bx() { cat >/dev/null 2>&1 || true; att_bx "$1"; }
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    ATT_PHASE=before
    local repo num
    while read -r repo num; do
      [ -n "${num:-}" ] || continue
      rehearsal_attention_pickup_counts "$repo $num" "$ATT_MARK"
    done <<<"$1"
  ) </dev/null
}
t drill-attention-census-pickup-read-does-not-eat-a-caller-loop 3 \
  "$(att_pickup_rows_nested "$ATT_CENSUS" | grep -c . || true)"

# (f) THE CENSUS'S WINDOW IS THE ENGINE'S WINDOW (#714, round 2).
#
# The census is not an independent enumeration of what the identity carries:
# it is a mirror of the page duty_attention itself fetched, because the assert
# half then demands, per recorded row, that the engine has a suppressed record
# for it. The engine's read is unpaginated (shared/lib/duty-attention.sh:115)
# and its .suppressed-attention-scope file is re-derived from that one page's
# partition — so on a host carrying more than a page of demands, a record
# exists for page 1 and cannot exist for page 2, no matter how correct the
# engine is. That is exactly the box modelled here: page 1 answers a plain
# read, pages 1+2 answer a `--paginate`d one, and the scope file names page 1.
#
# Today's code records the page-1 set and the leg is green. Add `--paginate`
# to the census read and all four rows below red: the census row names three
# demands, #470 is graded, `…#470 seen and suppressed` FAILs against an engine
# that did nothing wrong, and the round stops — the false refusal this issue
# removes, re-created one tick later. So this is the kill the window did not
# have, and it is behaviour, not a grep for the absence of a flag.
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\n')"
ATT_CENSUS_PAGE2="$(printf 'heavy-duty/incubator 470\n')"
ATT_SCOPE="$(printf '%s\n' \
  'heavy-duty/incubator#468 2026-09-10T21:00:00Z' \
  'heavy-duty/incubator#469 2026-09-10T21:00:01Z')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
# #470 is in the pickup tables so that a paginating census reds on the ONE
# thing it should — no engine record — and not on a table lookup that happens
# to be short.
ATT_PICKUPS_BEFORE="$(printf '%s\n' \
  'heavy-duty/incubator#468 0' 'heavy-duty/incubator#469 0' 'heavy-duty/incubator#470 0')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"
ATT_WINDOW="$(att_drive both drain)"
t drill-attention-census-window-is-the-engines-window 1 \
  "$(grep -c '^ok attention census: 2 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_WINDOW" || true)"
t drill-attention-census-window-omits-the-second-page 0 \
  "$(grep -c '470' <<<"$ATT_WINDOW" || true)"
t drill-attention-census-window-is-green 0 "$(att_fail "$ATT_WINDOW")"
t drill-attention-census-window-rows 7 "$(att_ok "$ATT_WINDOW")"
ATT_CENSUS_PAGE2=""

# (g) THE PAGE BOUNDARY: THE DRILL'S OWN FIXTURE MOVES THE ENGINE'S PAGE
# (#714, round 4).
#
# Group (f) proves the census does not read WIDER than the engine, holding both
# pages static across the tick. That is not the only way the two windows come
# apart, and the other way is the drill's own doing. `/issues?filter=assigned`
# answers newest first, and the census and duty_attention each read one
# `per_page=100` page of it — so minting the sandbox `attention` demand INSERTS
# a row at the head of that page and displaces the oldest outside demand off
# the engine's next fetch. A census taken before the mint records 100 rows; the
# engine correctly writes records for the 99 it fetched; the displaced
# hundredth reds and the round stops. That is the false refusal this issue
# removes, re-created one tick later at the boundary.
#
# 100 rows, the engine's real per_page, because the cap IS the boundary: below
# it both orderings record the same set and there is nothing to see. Newest
# first, so `#1` is the oldest demand and the one that falls off.
#
# The two orderings are driven against ONE correct engine — its suppressed
# scope is the post-mint page either way, because the tick always runs after
# the mint. What differs is only which page the census read.
att_page() { # att_page STAGED — the rows one per_page=100 read yields, with
             # the sandbox demand dropped as the census's own --jq drops it
  { [ "$1" = 1 ] && printf '%s 7\n' "$ATT_SANDBOX"
    awk 'BEGIN { for (i = 100; i >= 1; i--) printf "heavy-duty/incubator %d\n", i }'
  } | head -n 100 | awk -v s="$ATT_SANDBOX" '$1 != s'
}
ATT_SCOPE="$(att_page 1 | awk '{ printf "%s#%s 2026-09-11T00:00:00Z\n", $1, $2 }')"
ATT_LOG='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
# Explicit zeroes for every row of the WIDER page, so the displaced demand reds
# on the one thing it should — no engine record — and never on a pickup table
# that happened to be short.
ATT_PICKUPS_BEFORE="$(att_page 0 | awk '{ print $1 "#" $2 " 0" }')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"

# The ordering that shipped through round 3: census first, mint second.
ATT_CENSUS="$(att_page 0)"
ATT_EARLY="$(att_drive both drain)"
t drill-attention-census-boundary-early-census-records-100 1 \
  "$(grep -c '^ok attention census: 100 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_EARLY" || true)"
t drill-attention-census-boundary-early-census-fails-the-displaced-demand 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#1 seen and suppressed$' <<<"$ATT_EARLY" || true)"
t drill-attention-census-boundary-early-census-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_EARLY" || true)"
# One red, and it is a red against an engine that did nothing wrong: the other
# 99 demands are graded and green beside it.
t drill-attention-census-boundary-early-census-reds-only-that-one 1 "$(att_fail "$ATT_EARLY")"
t drill-attention-census-boundary-early-census-grades-every-row 202 "$(att_ok "$ATT_EARLY")"

# The ordering this round ships: mint first, so the census's page IS the page
# the engine will fetch.
ATT_CENSUS="$(att_page 1)"
ATT_STAGED="$(att_drive both drain)"
t drill-attention-census-boundary-staged-census-records-the-engines-page 1 \
  "$(grep -c '^ok attention census: 99 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_STAGED" || true)"
t drill-attention-census-boundary-staged-census-omits-the-displaced-demand 0 \
  "$(grep -c '^  census: heavy-duty/incubator#1$' <<<"$ATT_STAGED" || true)"
t drill-attention-census-boundary-staged-census-is-green 0 "$(att_fail "$ATT_STAGED")"
t drill-attention-census-boundary-staged-census-grades-every-row 201 "$(att_ok "$ATT_STAGED")"
t drill-attention-census-boundary-staged-census-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_STAGED" || true)"

# ...and the two above are the two sides, documented. THIS is the kill: which
# page the census reads is not a property of either half — it is decided by the
# order rehearsal.sh calls them in — so the fixture READS that order off the
# production file and drives the page it implies. Move the mint back below the
# census and these two rows red on behaviour, through the real functions,
# against an engine that did nothing wrong.
att_staged_by_source() {
  awk '/drill: attention wake /{ if (!mint) mint = NR }
       /rehearsal_attention_census_take/{ if (!take) take = NR }
       END { print (mint && take && mint < take) ? 1 : 0 }' \
    "$ROOT/drill/rehearsal.sh"
}
ATT_CENSUS="$(att_page "$(att_staged_by_source)")"
ATT_SOURCED="$(att_drive both drain)"
t drill-attention-census-boundary-source-ordering-is-green 0 "$(att_fail "$ATT_SOURCED")"
t drill-attention-census-boundary-source-ordering-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_SOURCED" || true)"

# (h) DUTY.LOG ROTATES UNDER THE CENSUS (#714, round 5).
#
# The take half counts duty.log's lines; the assert half reads what was written
# after them. shared/bin/tick.sh:31-34 moves that file to duty.log.1 once it
# passes 5 MiB, BEFORE opening the append redirect for the run — deliberately,
# and its own comment says why. A drill box is reused between passes and its
# cron has been striking since install, so the tick this leg is about can put
# the round's records near line 1 of a FRESH file and leave `tail -n +<count+1>`
# returning nothing. Every D2 row then reads green over evidence nobody read:
# an absence established by failing to read, which is the exact failure this
# leg exists to stop, one file down from the demands.
#
# THE BOX HERE IS A REAL DIRECTORY. The command the host composes is eval'd
# against it, `stat` reads real inodes, and the rotation between the halves is
# a real `mv` — because a fixture that re-implements the branch host-side
# passes under its own mutation and proves nothing about the command that ships.
ATT_BOX_HOME="$TMP/att-box"
mkdir -p "$ATT_BOX_HOME/duty"
ATT_ROT_WARN='WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) '
# The generation the census counts: 100 lines of an EARLIER pass, one of them
# an attention session dispatched outside the sandbox. It is a previous life's
# and must stay out of this round's slice — which is what the line count is for
# and why a rotation-aware read still has to apply it to the rotated file.
att_rot_setup() {
  att_box_conf attention "$ATT_MARK"
  rm -f "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  { awk 'BEGIN { for (i = 1; i <= 49; i++) printf "tick %d duty run end\n", i }'
    echo 'SESSION START kind=attention key=heavy-duty/incubator#470 timeout=1800s log=/l holder=x sid=0'
    awk 'BEGIN { for (i = 51; i <= 100; i++) printf "tick %d duty run end\n", i }'
  } >"$ATT_BOX_HOME/duty/duty.log"
}
# What the ticks did. Tick 1 appends this round's suppressed report to the
# generation the census counted; tick 2 finds it over the threshold, rotates,
# and writes its own records into a fresh one. BOTH halves are this round's,
# which is why the slice has to span them.
att_rot_tick() {
  printf '%s\n' "$ATT_ROT_WARN" >>"$ATT_BOX_HOME/duty/duty.log"
  mv "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  { echo 'tick 2026-09-11T18:00:00Z duty run start'
    printf '%s\n' "$ATT_ROT_FRESH"
  } >"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_rot_tick'
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\n')"
# NO state file: the suppressed evidence exists only in the rotated tail, so a
# read that misses that tail cannot pass by another route.
ATT_SCOPE=""
ATT_PICKUPS_BEFORE="$(printf 'heavy-duty/incubator#468 0\nheavy-duty/incubator#469 0\n')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"

# h1 — the case codex-bot reported: the saved line number exceeds the fresh
# log's length, and the fresh generation carries an outside attention session.
ATT_ROT_FRESH='SESSION START kind=attention key=outside/repo#7 timeout=1800s log=/l holder=x sid=9'
att_rot_setup
ATT_ROTATED="$(att_drive both drain)"
t drill-attention-census-rotation-sees-the-outside-session 1 \
  "$(grep -c '^FAIL attention census: no attention session launched outside host/crew-drill-builder$' <<<"$ATT_ROTATED" || true)"
t drill-attention-census-rotation-quotes-the-outside-session 1 \
  "$(grep -c '^  read: SESSION START kind=attention key=outside/repo#7 ' <<<"$ATT_ROTATED" || true)"
t drill-attention-census-rotation-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_ROTATED" || true)"

# h2 — the same rotation with a fresh generation that did nothing wrong. This
# is the row that kills three implementations at once: the shipped one (an
# empty slice, so the suppressed report in the rotated tail is missed and both
# demands red), a read of the new generation alone (same), and a whole-file
# read (the previous pass's outside session at line 50 reds a correct round).
# Only a slice spanning duty.log.1's tail and all of duty.log is green here.
ATT_ROT_FRESH='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
att_rot_setup
ATT_ROT_CLEAN="$(att_drive both drain)"
t drill-attention-census-rotation-clean-is-green 0 "$(att_fail "$ATT_ROT_CLEAN")"
t drill-attention-census-rotation-reads-the-rotated-tail 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_ROT_CLEAN" || true)"
t drill-attention-census-rotation-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_ROT_CLEAN" || true)"

# h3 — the generation is on NEITHER file: two rotations, or a box rebuilt under
# the round. Nothing can be concluded from what is left, so the leg says so and
# stops — and emits no other assert row at all, because a red bounding row
# beside four vacuous greens is the same lie in a longer form.
#
# Note what decides this row and what does not. The second `mv` frees the
# counted generation's inode, and whether the kernel then hands that very
# number back to the `echo` below is the FILESYSTEM's business: tmpfs does not,
# ext4 does. This row must land `lost` either way, which it does only because
# the mark carries the counted lines' checksum as well as the inode — a reused
# inode arrives under a first line the census never counted. h4 drives the
# reuse case deterministically rather than waiting for a filesystem to do it.
att_rot_lose() {
  att_rot_tick
  mv "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  echo 'tick 2026-09-11T18:05:00Z duty run start' >"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_rot_lose'
att_rot_setup
ATT_ROT_LOST="$(att_drive both drain)"
t drill-attention-census-lost-generation-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_ROT_LOST" || true)"
t drill-attention-census-lost-generation-says-what-it-read 1 \
  "$(grep -c '^  read: the duty.log generation the census counted is now neither duty.log nor duty.log.1' <<<"$ATT_ROT_LOST" || true)"
t drill-attention-census-lost-generation-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_ROT_LOST" || true)"
# One ok row, and it is the take half's census row: nothing downstream of the
# slice is graded at all.
t drill-attention-census-lost-generation-grades-nothing-after-it 1 "$(att_ok "$ATT_ROT_LOST")"

# h4 — THE COUNTED GENERATION'S NUMBER, WORN BY A FILE THAT IS NOT IT. The log
# is truncated in place and rewritten: `>` re-uses the open inode by
# construction, on every filesystem, so this forges the identity h3 can only
# forge when the kernel happens to co-operate. It is also a real state — a
# rebuilt box, or anything that rewrites the log in place — and the round's
# suppressed report, appended before the truncation, is destroyed with it.
#
# This is the row that kills an inode-only mark, which is what this leg shipped
# with until ci-shell graded it on ext4: that implementation reads `current`,
# runs `tail -n +101` off the end of a two-line file, and returns an empty
# slice, so the bounding row greens and four vacuous assertions are graded
# against evidence that no longer exists. The fresh generation is deliberately
# INNOCENT — it names the sandbox, not an outside repo — so nothing but the
# bounding row can red here, and a mark that cannot tell the files apart is
# caught by the greens it produces and not by a coincidence.
att_rot_truncate() {
  printf '%s\n' "$ATT_ROT_WARN" >>"$ATT_BOX_HOME/duty/duty.log"
  printf '%s\n' 'tick 2026-09-11T18:05:00Z duty run start' "$ATT_ROT_FRESH" \
    >"$ATT_BOX_HOME/duty/duty.log"
}
ATT_ROT_FRESH='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
ATT_BETWEEN='att_rot_truncate'
att_rot_setup
ATT_ROT_SAME_INODE_GEN="$(stat -c %i "$ATT_BOX_HOME/duty/duty.log")"
ATT_ROT_REUSED="$(att_drive both drain)"
# The fixture only proves what it claims if the inode really did survive: a
# truncation that silently replaced the file would make this an expensive
# duplicate of h3.
t drill-attention-census-reused-inode-fixture-kept-the-inode "$ATT_ROT_SAME_INODE_GEN" \
  "$(stat -c %i "$ATT_BOX_HOME/duty/duty.log")"
t drill-attention-census-reused-inode-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_ROT_REUSED" || true)"
t drill-attention-census-reused-inode-says-what-it-read 1 \
  "$(grep -c '^  read: the duty.log generation the census counted is now neither duty.log nor duty.log.1' <<<"$ATT_ROT_REUSED" || true)"
t drill-attention-census-reused-inode-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_ROT_REUSED" || true)"
t drill-attention-census-reused-inode-grades-nothing-after-it 1 "$(att_ok "$ATT_ROT_REUSED")"

# h5 — NOTHING ROTATED, AND THE COUNT STILL DECIDES WHOSE LINES THESE ARE.
# The offset is what makes a reused drill box safe: `--reuse` passes leave
# their records behind, and one of them is an attention session dispatched
# outside the sandbox by a PREVIOUS life. It sits above the census mark, so it
# is not this round's and the negative assertion must not see it.
#
# This is the row claude-bot's round-1 nit asked for: the same expression is
# killed one branch down by h2, but only where the log rotated. Every other
# fixture that lands on `current` either answers a canned string instead of
# running the composed command, or starts from an empty log — where
# `tail -n +1` and `cat` are the same read and no mutation can tell them
# apart. Here they differ by exactly one line, and it is a damning one.
att_prev_setup() {
  att_box_conf attention "$ATT_MARK"
  rm -f "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  { awk 'BEGIN { for (i = 1; i <= 49; i++) printf "tick %d duty run end\n", i }'
    echo 'SESSION START kind=attention key=heavy-duty/incubator#470 timeout=1800s log=/l holder=x sid=0'
  } >"$ATT_BOX_HOME/duty/duty.log"
}
# This round, appended to that same file: the suppressed report both demands
# are graded against, and a session that names the sandbox. No `mv` anywhere.
att_prev_tick() {
  printf '%s\n' "$ATT_ROT_WARN" \
    'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1' \
    >>"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_prev_tick'
att_prev_setup
ATT_PREV="$(att_drive both drain)"
# The seed is the whole fixture: without that line above the mark, a whole-file
# read and a bounded one agree and the row below proves nothing.
t drill-attention-census-previous-pass-fixture-seeded-the-line 1 \
  "$(grep -c 'key=heavy-duty/incubator#470 ' "$ATT_BOX_HOME/duty/duty.log" || true)"
t drill-attention-census-previous-pass-is-not-this-round 0 "$(att_fail "$ATT_PREV")"
t drill-attention-census-previous-pass-suppressed-both 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_PREV" || true)"
t drill-attention-census-previous-pass-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_PREV" || true)"

# h6 — A DUTY.LOG THAT IS THERE AND WILL NOT READ (round 1, codex-bot).
#
# The third state again, on the file rather than on the board: not "the log was
# empty" and not "the generation is gone", but "nobody read it". Before this
# round every read on this path laundered its own failure — `wc -l … || echo 0`
# made an unopenable log a log of length 0, `head | cksum` with no `pipefail`
# made a failed read the checksum of nothing, and the slice recomputed the mark
# the SAME way, matched itself, and returned `slice: current` with an empty
# body. Every D2 row then graded green over a file nobody had read.
#
# THE FIXTURE DOES NOT USE `chmod 000`. Root reads a 0000 file, and neither a
# builder box nor a CI runner is guaranteed to be non-root, so a permission
# fixture can pass vacuously on the machine that is supposed to grade it — the
# exact failure mode this group is about, wearing a fixture's clothes. A
# duty.log that is a DIRECTORY fails `wc -l <`, `head` and `tail` with EISDIR
# under every uid, which is the state under test: it exists, and it will not
# read.
att_unreadable_make() {
  rm -rf "$ATT_BOX_HOME/duty/duty.log"
  mkdir "$ATT_BOX_HOME/duty/duty.log"
}
att_unreadable_cannot_read() {
  if wc -l <"$ATT_BOX_HOME/duty/duty.log" >/dev/null 2>&1; then echo readable; else echo unreadable; fi
}
# (h6a) unreadable at the census: the take half refuses, and rehearsal.sh's
# caller stops the round there. NOTHING is graded — not even the census row,
# which is emitted after this read for exactly that reason.
att_box_conf attention "$ATT_MARK"
rm -f "$ATT_BOX_HOME/duty/duty.log.1"
att_unreadable_make
ATT_BETWEEN=""
ATT_UNREADABLE_TAKE="$(att_drive take drain)"
t drill-attention-census-unreadable-fixture-really-cannot-read unreadable \
  "$(att_unreadable_cannot_read)"
t drill-attention-census-unreadable-log-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$ATT_UNREADABLE_TAKE" || true)"
t drill-attention-census-unreadable-log-grades-nothing 0 "$(att_ok "$ATT_UNREADABLE_TAKE")"
t drill-attention-census-unreadable-log-fails-nothing 0 "$(att_fail "$ATT_UNREADABLE_TAKE")"
# ...and the directory goes before the next block seeds a file there. `rm -f`
# cannot remove one, so a setup that assumes a file would silently leave THIS
# state standing and grade the next case against it.
rm -rf "$ATT_BOX_HOME/duty/duty.log"

# (h6b) readable at the census and unreadable by the time the evidence is read
# — a rebuilt box, a mount that went away under the round. The census is taken,
# so there IS something to grade; the bounding row is what grades it, and it
# reds rather than certifying a read that did not happen. `unreadable` and not
# `lost`: a file that will not open cannot be ruled out as the counted
# generation either, and `lost` would be a conclusion the leg did not earn.
att_prev_setup
ATT_BETWEEN='att_unreadable_make'
ATT_UNREADABLE_MID="$(att_drive both drain)"
t drill-attention-census-unreadable-mid-round-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_UNREADABLE_MID" || true)"
t drill-attention-census-unreadable-mid-round-says-what-it-read 1 \
  "$(grep -c '^  read: the box has a duty.log it could not read' <<<"$ATT_UNREADABLE_MID" || true)"
t drill-attention-census-unreadable-mid-round-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_UNREADABLE_MID" || true)"
# The census row, and nothing downstream of the slice.
t drill-attention-census-unreadable-mid-round-grades-nothing-after-it 1 \
  "$(att_ok "$ATT_UNREADABLE_MID")"
rm -rf "$ATT_BOX_HOME/duty/duty.log"

# (h6c) the box had NO duty.log at the census, and the one it has now will not
# read. The `fresh` branch is the one path whose read is not vouched for by the
# generation mark — there was no generation to mark — so it is the branch where
# a `cat` hidden behind `2>/dev/null || true` returns an empty slice that looks
# exactly like a box which simply wrote nothing this round.
att_box_conf attention "$ATT_MARK"
rm -rf "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
ATT_BETWEEN='att_unreadable_make'
ATT_UNREADABLE_FRESH="$(att_drive both drain)"
t drill-attention-census-unreadable-fresh-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_UNREADABLE_FRESH" || true)"
t drill-attention-census-unreadable-fresh-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_UNREADABLE_FRESH" || true)"
t drill-attention-census-unreadable-fresh-grades-nothing-after-it 1 \
  "$(att_ok "$ATT_UNREADABLE_FRESH")"
rm -rf "$ATT_BOX_HOME/duty/duty.log"

# (h6d) ...and the other side of that judgement, which is why `unreadable` is
# asked LAST. A drill box reused across passes can carry a duty.log.1 nobody
# can open — a rebuild left it root-owned, a mount went away. It says nothing
# about a generation that has already been identified BY READING IT: `cur`
# matched on both the inode and the counted lines, so this round's lines are
# exactly where the census said they were. A leg that asked "did every read
# succeed?" before "do I know where my lines are?" would stop a sound round
# over a file it never needed.
att_prev_setup
rm -rf "$ATT_BOX_HOME/duty/duty.log.1"
mkdir "$ATT_BOX_HOME/duty/duty.log.1"
ATT_BETWEEN='att_prev_tick'
ATT_UNREADABLE_ROT="$(att_drive both drain)"
t drill-attention-census-unreadable-rotated-file-is-not-this-rounds-problem 0 \
  "$(att_fail "$ATT_UNREADABLE_ROT")"
t drill-attention-census-unreadable-rotated-file-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_UNREADABLE_ROT" || true)"
t drill-attention-census-unreadable-rotated-file-still-grades-both 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_UNREADABLE_ROT" || true)"
rm -rf "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"

ATT_BOX_HOME=""
ATT_BETWEEN=""

# ...and a box that does not answer the slice read in the shape it was asked
# reds the same way. `slice:` with no generation word is the third state again:
# not "the log was empty", but "nobody read it".
ATT_SLICE=unanswered
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_UNBOUNDED="$(att_drive both)"
t drill-attention-census-unbounded-slice-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_UNBOUNDED" || true)"
t drill-attention-census-unbounded-slice-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_UNBOUNDED" || true)"
ATT_SLICE=current
# ...and the take half refuses outright when the box will not say WHICH
# generation it counted, for the reason the census itself refuses: a slice
# resolved against nothing would silently be the whole file, every tick.
ATT_LOG_GEN=""
t drill-attention-census-no-log-generation-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$(att_drive take)" || true)"
ATT_LOG_GEN=111

# (i) THE LABEL IS THE BOX'S, NOT THIS FILE'S (#714, round 5).
#
# duty_attention fetches `labels=$LABEL_ATTENTION` (duty-attention.sh:115), and
# LABEL_ATTENTION is NOT one of the six wire marks load_fleet_conf restores
# over fleet.conf (common/conf.sh:14-24) — so an operator file moves it. A
# census keyed on the literal `attention` then reads an EMPTY set off a board
# that is full: zero demands recorded, nothing asserted, and the leg reports a
# clean bill of health for a filter it never exercised. Same defect as the
# --paginate window and the page boundary, third disguise.
# ...and the wire mark goes the OTHER way, from the SAME read: load_fleet_conf
# restores MARK_PICKUP over fleet.conf, so an override of it must be read and
# then discarded exactly as the loader discards it. One box, both resolutions,
# and this box is real — the two configuration files exist and the read is
# executed against them, so neither direction is pinned by a grep for source
# text and a read that mixed them up is killed on behaviour.
ATT_BOX_HOME="$TMP/att-conf-box"
mkdir -p "$ATT_BOX_HOME/duty"
# The operator moved BOTH names. Only one of them is theirs to move.
att_box_conf attention "$ATT_MARK" needs-human '🔧 not the wire mark'
ATT_LABEL_CONF="needs-human"   # what the endpoint will answer to
ATT_MARK_EXPECT="$ATT_MARK"    # ...and the comment read must still carry the wire mark
: >"$ATT_BOX_HOME/duty/duty.log"
att_conf_tick() {
  printf '%s\n%s\n' "$ATT_ROT_WARN" \
    'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1' \
    >>"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_conf_tick'
ATT_RENAMED="$(att_drive both)"
t drill-attention-census-renamed-label-records-the-demands 1 \
  "$(grep -c '^ok attention census: 2 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_RENAMED" || true)"
t drill-attention-census-renamed-label-asserts-them 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_RENAMED" || true)"
t drill-attention-census-wire-mark-ignores-the-operator-file 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] drew no pickup$' <<<"$ATT_RENAMED" || true)"
t drill-attention-census-renamed-label-is-green 0 "$(att_fail "$ATT_RENAMED")"
ATT_BOX_HOME=""
ATT_BETWEEN=""
ATT_MARK_EXPECT=""
ATT_LABEL_CONF="attention"
# A box whose configuration resolves no LABEL_ATTENTION refuses, like the mark.
ATT_LABEL_CONF=""
t drill-attention-census-no-label-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$(att_drive take)" || true)"
ATT_LABEL_CONF="attention"

# --- the breaker leg grades only what it CONFIRMED (#724) --------------------
#
# The 0.1.3-rc2 round failed seven breaker assertions on `triage` and six on
# `reviewer`, and passed outright on `builder` — same engine, same threshold,
# same lane, three roles. What varied was not the engine but whether the tick
# the leg fired ever reached the lane, and the leg had no way to tell the
# difference. Both directions were live: two roles red on the engine's behalf,
# and an absence that happened to look right would have read green.
#
# The two shapes are staged here rather than on a box, because a defect whose
# trigger is "an earlier leg closed the fixture" or "the previous run still
# holds the lock" cannot be scheduled on a real host — the rc2 round produced
# one of each by accident, five weeks apart from the code that grades them.
#
# THE BOX IS A REAL FILE. duty.log is written by the tick stub and read by the
# shipped `tail -n +$first` through a HOME-scoped bash, so the slice boundary
# is exercised rather than handed to the predicate ready-made: a leg that lost
# track of `first` would grade a previous tick's lines and pass a fixture that
# only ever returned the slice it was asked for.
BRK_HOME="$TMP/brk-box"
BRK_TRACE="$TMP/brk-trace"
BRK_REASON="$TMP/brk-reason"
BRK_TS="2026-09-12T15:54:29Z"
BRK_KIND=attention
BRK_LABEL=attention
BRK_THRESHOLD=3
BRK_TRIES=3
BRK_SLICES=(NOTHING)
BRK_ISSUE_STATE=open
BRK_ISSUE_LABELS=""
BRK_ISSUE_READABLE=1
BRK_REOPEN_WORKS=1
BRK_LABEL_STICKS=1
BRK_TICK_N=0
BRK_REOPENS=0

brk_note() { printf '%s\n' "$1" >>"$BRK_TRACE"; }

# One tick's worth of duty.log, by name. `LOCK` is the line tick.sh writes when
# flock refuses it (shared/bin/tick.sh:90) — the slice that is not evidence.
brk_slice_lines() {
  case "$1" in
    LOCK)
      printf '%s duty tick skipped: previous run still holds the lock (running unknown)\n' \
        "$BRK_TS" ;;
    TERMINAL)
      printf '%s SESSION START kind=%s key=owner/repo#1 timeout=5s log=/tmp/t\n' \
        "$BRK_TS" "$BRK_KIND"
      printf '%s SESSION END kind=%s key=owner/repo#1 rc=1 dur=1s outcome=TERMINAL acted=no\n' \
        "$BRK_TS" "$BRK_KIND" ;;
    TRIP)
      brk_slice_lines TERMINAL
      printf '%s WARN: session breaker: kind=%s tripped after %s consecutive terminal failures\n' \
        "$BRK_TS" "$BRK_KIND" "$BRK_THRESHOLD" ;;
    SUPPRESSED)
      printf '%s SESSION SKIP kind=%s key=owner/repo#1 reason=terminal-breaker count=%s\n' \
        "$BRK_TS" "$BRK_KIND" "$BRK_THRESHOLD" ;;
    RECOVERED)
      printf '%s session breaker: kind=%s recovered; dispatch resumed\n' \
        "$BRK_TS" "$BRK_KIND"
      printf '%s SESSION START kind=%s key=owner/repo#1 timeout=5s log=/tmp/r\n' \
        "$BRK_TS" "$BRK_KIND" ;;
    NOTHING) ;;
  esac
}

# The Nth tick writes the Nth scripted slice; past the end the last one repeats,
# so an unbounded lock is spelled `BRK_SLICES=(LOCK)` rather than by counting.
brk_tick() {
  local spec
  BRK_TICK_N=$((BRK_TICK_N + 1))
  brk_note tick
  if [ "$BRK_TICK_N" -le "${#BRK_SLICES[@]}" ]; then
    spec="${BRK_SLICES[$((BRK_TICK_N - 1))]}"
  else
    spec="${BRK_SLICES[$((${#BRK_SLICES[@]} - 1))]}"
  fi
  # The recovered session acks the demand, which is what the post-recovery
  # clear assertion reads. Modelled here so that row is graded against the
  # board rather than against a stub that always says yes.
  [ "$spec" != RECOVERED ] || BRK_ISSUE_LABELS=""
  brk_slice_lines "$spec" >>"$BRK_HOME/duty/duty.log"
}

brk_bx() {
  local cmd="$1"
  case "$cmd" in
    *alerts.log*)
      printf '🚨 crew-drill: %s session dispatch stopped after %s terminal failures (acted=no) — /tmp/s.log\n' \
        "$BRK_KIND" "$BRK_THRESHOLD" ;;
    *'wc -l < ~/duty/duty.log'*) wc -l <"$BRK_HOME/duty/duty.log" ;;
    *'duty/bin/tick.sh'*) brk_tick ;;
    # A real box runs the command in a fresh shell with `~` expanded against
    # its own HOME, which is how the slice boundary gets exercised at all.
    *'tail -n +'*) ( HOME="$BRK_HOME"; bash -c "$cmd" 2>/dev/null ) ;;
    *) return 0 ;;
  esac
}

# The board. A label POST on a CLOSED issue succeeds and arms nothing, which is
# the whole point: this stub accepts it exactly as GitHub does, so a leg that
# grades the request still reads green here and is killed by the state rows.
brk_gh() {
  local url="" method=GET field
  while [ "$#" -gt 0 ]; do
    case "$1" in
      api) shift ;;
      -X) method="$2"; shift 2 ;;
      -f)
        field="$2"; shift 2
        case "$field" in
          state=open)
            BRK_REOPENS=$((BRK_REOPENS + 1))
            brk_note reopen
            [ "$BRK_REOPEN_WORKS" -ne 1 ] || BRK_ISSUE_STATE=open ;;
          'labels[]='*)
            brk_note "label:${field#labels[]=}"
            if [ "$BRK_LABEL_STICKS" -eq 1 ]; then
              BRK_ISSUE_LABELS="${BRK_ISSUE_LABELS:+$BRK_ISSUE_LABELS,}${field#labels[]=}"
            fi ;;
        esac ;;
      *) url="$1"; shift ;;
    esac
  done
  case "$method:$url" in
    GET:*)
      [ "$BRK_ISSUE_READABLE" -eq 1 ] || return 1
      jq -nc --arg s "$BRK_ISSUE_STATE" --arg l "$BRK_ISSUE_LABELS" \
        '{state:$s,labels:($l|split(",")|map(select(length>0)|{name:.}))}' ;;
  esac
  return 0
}

brk_reset() {
  rm -rf "$BRK_HOME"
  mkdir -p "$BRK_HOME/duty"
  : >"$BRK_HOME/duty/duty.log"
  : >"$BRK_TRACE"
  rm -f "$BRK_REASON"
  BRK_TICK_N=0
  BRK_REOPENS=0
}

# brk_drive — run the shipped leg against the fixture box and print the rows it
# emits, then its verdict. ok()/fail()/skip()/check()/wait_for() are supplied
# exactly as rehearsal.sh supplies them, so a row's GRADE is observed and not
# inferred: `INCOMPLETE, reason named, never FAIL` is a claim about which of
# these four a row went to, and nothing else can see that.
brk_drive() {
  (
    export REHEARSAL_BREAKER_TICK_TRIES="$BRK_TRIES"
    export REHEARSAL_BREAKER_TICK_WAIT=0
    # shellcheck source=drill/rehearsal-breaker.sh
    . "$ROOT/drill/rehearsal-breaker.sh"
    AGENT=kimi
    FAILS=()
    REHEARSAL_BREAKER_REASON_FILE="$BRK_REASON"
    # The facts are the fixture's, so the rows below are about grading and not
    # about the box read that resolves them; that read is driven against the
    # real shipped conf in shared/test/common.sh.
    rehearsal_breaker_load_installed_facts() {
      REHEARSAL_BREAKER_THRESHOLD="$BRK_THRESHOLD"
      REHEARSAL_BREAKER_KIND="$BRK_KIND"
      REHEARSAL_BREAKER_STATE=/tmp/breaker-state
      REHEARSAL_BREAKER_LABEL="$BRK_LABEL"
    }
    rehearsal_breaker_profile_has_hook() { return 0; }
    rehearsal_breaker_terminal_fixture_is_classified() { return 0; }
    rehearsal_breaker_install_fixture() {
      REHEARSAL_BREAKER_DIR=/tmp/breaker-fixture
      return 0
    }
    rehearsal_breaker_restore_cli_for_recovery() { return 0; }
    rehearsal_breaker_restore_cli() { return 0; }
    rehearsal_breaker_profile_is_restored() { return 0; }
    bx() { brk_bx "$1"; }
    gh() { brk_gh "$@"; }
    ok()   { echo "ok $1"; }
    fail() { FAILS+=("$1"); echo "FAIL $1"; }
    skip() { echo "skip $1"; }
    check()    { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
    wait_for() { local n="$2"; shift 2; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
    rc=0
    rehearsal_breaker_drill owner/repo 1 reviewer || rc=$?
    printf 'RC=%s\nTICKS=%s\nREOPENS=%s\n' "$rc" "$BRK_TICK_N" "$BRK_REOPENS"
  )
}
brk_ok()   { grep -c '^ok ' <<<"$1" || true; }
brk_fail() { grep -c '^FAIL ' <<<"$1" || true; }
brk_v()    { grep -c "^$2=$3\$" <<<"$1" || true; }
brk_trace() { awk "NR<=$1" "$BRK_TRACE" | paste -sd' ' -; }

# (a) THE NON-REGRESSION SHAPE, and the baseline every row below is a delta
# from: an open fixture whose ticks all run. This is `builder`'s round in rc2,
# which passed outright and must keep passing.
BRK_SLICES=(TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED RECOVERED)
brk_reset
BRK_GREEN="$(brk_drive)"
t drill-breaker-running-ticks-round-is-green 0 "$(brk_fail "$BRK_GREEN")"
t drill-breaker-running-ticks-round-returns-pass 1 "$(brk_v "$BRK_GREEN" RC 0)"
t drill-breaker-running-ticks-grades-every-row 18 "$(brk_ok "$BRK_GREEN")"
t drill-breaker-running-ticks-fires-six-ticks 1 "$(brk_v "$BRK_GREEN" TICKS 6)"
t drill-breaker-open-fixture-is-not-reopened 1 "$(brk_v "$BRK_GREEN" REOPENS 0)"
t drill-breaker-running-ticks-trips-the-lane 1 \
  "$(grep -c '^ok breaker: lane trips once at installed threshold for kimi$' <<<"$BRK_GREEN" || true)"

# (b) THE FIXTURE AN EARLIER LEG CLOSED — the `triage` role's round.
#
# `gh api -X POST …/labels` returns 201 on a closed issue and arms nothing:
# duty_attention fetches `/issues?filter=assigned&state=open`, so a closed
# issue is not a candidate. The leg reopens it BEFORE firing, and the trace row
# is the one that says "before": a reopen that happened after the first tick
# would leave every assertion below still green.
BRK_ISSUE_STATE=closed
brk_reset
BRK_CLOSED="$(brk_drive)"
t drill-breaker-closed-fixture-is-reopened 1 "$(brk_v "$BRK_CLOSED" REOPENS 1)"
t drill-breaker-closed-fixture-reopened-before-any-tick 'reopen label:attention tick' \
  "$(brk_trace 3)"
t drill-breaker-reopened-fixture-arms 1 \
  "$(grep -c '^ok breaker: attention lane fixture armed$' <<<"$BRK_CLOSED" || true)"
t drill-breaker-reopened-fixture-round-is-green 0 "$(brk_fail "$BRK_CLOSED")"
t drill-breaker-reopened-fixture-round-returns-pass 1 "$(brk_v "$BRK_CLOSED" RC 0)"

# (c) ...and the re-read is the assertion, not the reopen request. A board that
# accepts the PATCH and stays closed is exactly what the old code could not
# see, because the only thing it ever looked at was an exit status.
BRK_ISSUE_STATE=closed
BRK_REOPEN_WORKS=0
brk_reset
BRK_STUCK="$(brk_drive)"
t drill-breaker-unreopenable-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_STUCK" || true)"
t drill-breaker-unreopenable-fixture-names-what-it-read 1 \
  "$(grep -c '^  read: state=closed labels=attention$' <<<"$BRK_STUCK" || true)"
# The point of failing there: nothing downstream is graded, because there is
# no armed lane for any of it to be about.
t drill-breaker-unreopenable-fixture-fires-no-tick 1 "$(brk_v "$BRK_STUCK" TICKS 0)"
t drill-breaker-unreopenable-fixture-reds-the-leg 1 "$(brk_v "$BRK_STUCK" RC 1)"
BRK_ISSUE_STATE=open
BRK_REOPEN_WORKS=1

# (d) The other half of the same re-read: an OPEN issue the label did not stick
# to. Same row, same silence downstream, and the reading distinguishes the two
# without the operator opening the board.
BRK_LABEL_STICKS=0
brk_reset
BRK_UNLABELLED="$(brk_drive)"
t drill-breaker-unlabelled-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_UNLABELLED" || true)"
t drill-breaker-unlabelled-fixture-names-what-it-read 1 \
  "$(grep -c '^  read: state=open labels=$' <<<"$BRK_UNLABELLED" || true)"
t drill-breaker-unlabelled-fixture-fires-no-tick 1 "$(brk_v "$BRK_UNLABELLED" TICKS 0)"
BRK_LABEL_STICKS=1

# (e) A BOARD THAT WILL NOT READ is not an armed lane either. The third state
# again: not "the fixture is wrong" but "nobody looked at it".
BRK_ISSUE_READABLE=0
brk_reset
BRK_UNREADABLE="$(brk_drive)"
t drill-breaker-unreadable-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_UNREADABLE" || true)"
t drill-breaker-unreadable-fixture-says-so 1 \
  "$(grep -c '^  read: the fixture issue could not be read$' <<<"$BRK_UNREADABLE" || true)"
t drill-breaker-unreadable-fixture-fires-no-tick 1 "$(brk_v "$BRK_UNREADABLE" TICKS 0)"
BRK_ISSUE_READABLE=1

# (f) THE LABEL IS THE BOX'S, NOT THIS FILE'S. LABEL_ATTENTION is not one of
# the six wire marks load_fleet_conf restores over fleet.conf, so an operator
# file moves it and duty_attention then fetches that name. Arming the literal
# `attention` on such a box sets a label the engine never asks for — the lane
# is unarmed, every row below is about a dispatch nobody requested, and the
# arming row says it succeeded. Same defect as (b), keyed on the name instead
# of on the state.
BRK_LABEL=needs-human
brk_reset
BRK_RENAMED="$(brk_drive)"
t drill-breaker-renamed-label-is-the-one-posted 1 \
  "$(grep -c '^label:needs-human$' "$BRK_TRACE" || true)"
t drill-breaker-renamed-label-never-posts-the-literal 0 \
  "$(grep -c '^label:attention$' "$BRK_TRACE" || true)"
t drill-breaker-renamed-label-round-is-green 0 "$(brk_fail "$BRK_RENAMED")"
BRK_LABEL=attention

# (g) THE SKIP-ONLY SLICE — the `reviewer` role's round.
#
# tick.sh takes the box flock with `-n` and logs one line when a previous run
# still holds it. That tick returns immediately, so the leg's back-to-back loop
# spent its whole budget inside two seconds and graded five slices describing
# ticks that never executed. Nothing here is FAIL: the leg never reached the
# lane, so it has nothing to say about it, and saying it anyway is what put
# seven red rows against a working engine.
BRK_SLICES=(LOCK)
brk_reset
BRK_LOCKED="$(brk_drive)"
t drill-breaker-skip-only-slice-is-never-graded 0 \
  "$(grep -c 'remains below installed threshold' <<<"$BRK_LOCKED" || true)"
t drill-breaker-skip-only-slice-fails-nothing 0 "$(brk_fail "$BRK_LOCKED")"
t drill-breaker-skip-only-slice-is-incomplete 1 "$(brk_v "$BRK_LOCKED" RC 2)"
t drill-breaker-skip-only-slice-names-the-reason 1 \
  "$(grep -c '^skip breaker: terminal dispatch 1 never ran; leg INCOMPLETE$' <<<"$BRK_LOCKED" || true)"
t drill-breaker-skip-only-slice-records-the-reason \
  'terminal dispatch 1 never ran: 3 ticks refused by a held lock' \
  "$(cat "$BRK_REASON" 2>/dev/null)"
# ...and it re-fired rather than giving up on the first refusal. The bound is
# the fixture's 3, so a leg that fired once and a leg that fired forever are
# both distinguished from the one shipped here.
t drill-breaker-skip-only-slice-refires-to-the-bound 1 "$(brk_v "$BRK_LOCKED" TICKS 3)"

# (h) ...and the rc2 reviewer shape exactly: dispatch 1 LANDED, and everything
# after it was refused. This is the row that separates the fix from a leg that
# merely checks its first tick — the graded row for dispatch 1 is real and must
# survive, while the round still stops rather than grading what came after.
BRK_SLICES=(TERMINAL LOCK)
brk_reset
BRK_MIXED="$(brk_drive)"
t drill-breaker-landed-dispatch-still-graded 1 \
  "$(grep -c '^ok breaker: terminal dispatch 1 remains below installed threshold$' <<<"$BRK_MIXED" || true)"
t drill-breaker-refused-dispatch-is-not-graded 0 \
  "$(grep -c 'dispatch 2 remains below installed threshold' <<<"$BRK_MIXED" || true)"
t drill-breaker-refused-dispatch-fails-nothing 0 "$(brk_fail "$BRK_MIXED")"
t drill-breaker-refused-dispatch-is-incomplete 1 "$(brk_v "$BRK_MIXED" RC 2)"
t drill-breaker-refused-dispatch-names-which-one 1 \
  "$(grep -c '^skip breaker: terminal dispatch 2 never ran; leg INCOMPLETE$' <<<"$BRK_MIXED" || true)"
t drill-breaker-refused-dispatch-fires-one-plus-the-bound 1 \
  "$(brk_v "$BRK_MIXED" TICKS 4)"

# (i) A LOCK THAT CLEARS is the case the bound exists for, and the one the
# other two groups cannot show: the leg WAITS and re-fires, and the round then
# grades a lane it really did reach. Without this row, "never grade a skip"
# would be satisfied by a leg that simply gave up.
BRK_SLICES=(LOCK LOCK TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED RECOVERED)
BRK_TRIES=5
brk_reset
BRK_CLEARS="$(brk_drive)"
t drill-breaker-lock-that-clears-is-waited-out 0 "$(brk_fail "$BRK_CLEARS")"
t drill-breaker-lock-that-clears-round-returns-pass 1 "$(brk_v "$BRK_CLEARS" RC 0)"
t drill-breaker-lock-that-clears-grades-every-row 18 "$(brk_ok "$BRK_CLEARS")"
t drill-breaker-lock-that-clears-counts-the-refusals 1 "$(brk_v "$BRK_CLEARS" TICKS 8)"
BRK_TRIES=3

# (j) The stopped-lane ticks and the recovery tick go through the same gate.
# Three tick sites, and a fix applied to one of them leaves the other two
# grading refusals — which is how this defect survived #424's own fixtures.
BRK_SLICES=(TERMINAL TERMINAL TRIP LOCK)
brk_reset
BRK_STOPPED_LOCKED="$(brk_drive)"
t drill-breaker-stopped-lane-refusal-is-incomplete 1 \
  "$(brk_v "$BRK_STOPPED_LOCKED" RC 2)"
t drill-breaker-stopped-lane-refusal-fails-nothing 0 \
  "$(brk_fail "$BRK_STOPPED_LOCKED")"
t drill-breaker-stopped-lane-refusal-names-the-tick 1 \
  "$(grep -c '^skip breaker: stopped-lane tick 1 never ran; leg INCOMPLETE$' <<<"$BRK_STOPPED_LOCKED" || true)"
t drill-breaker-stopped-lane-refusal-does-not-grade-suppression 0 \
  "$(grep -c 'following ticks skip the stopped lane' <<<"$BRK_STOPPED_LOCKED" || true)"

BRK_SLICES=(TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED LOCK)
brk_reset
BRK_RECOVERY_LOCKED="$(brk_drive)"
t drill-breaker-recovery-refusal-is-incomplete 1 \
  "$(brk_v "$BRK_RECOVERY_LOCKED" RC 2)"
t drill-breaker-recovery-refusal-fails-nothing 0 \
  "$(brk_fail "$BRK_RECOVERY_LOCKED")"
t drill-breaker-recovery-refusal-names-the-tick 1 \
  "$(grep -c '^skip breaker: recovery tick never ran; leg INCOMPLETE$' <<<"$BRK_RECOVERY_LOCKED" || true)"
t drill-breaker-recovery-refusal-does-not-grade-recovery 0 \
  "$(grep -c 'later tick recovers and launches a session' <<<"$BRK_RECOVERY_LOCKED" || true)"
BRK_SLICES=(NOTHING)

suite_finish
