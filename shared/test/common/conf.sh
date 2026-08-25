#!/usr/bin/env bash
# shared/test/common/conf.sh — standalone suite for shared/lib/common/conf.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- #285: per-author repository panels ------------------------------------
PANEL_REPO="$TMP/panel-repo"
git init -q "$PANEL_REPO"
mkdir -p "$PANEL_REPO/.github"
cat >"$PANEL_REPO/.github/labels.conf" <<'EOF'
panel=full-a full-b builder-one
panel[builder-one]=author-a author-b builder-one
panel[hyphen-builder]=hyphen-a hyphen-b
EOF
git -C "$PANEL_REPO" add .github/labels.conf
git -C "$PANEL_REPO" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$PANEL_REPO" update-ref refs/remotes/origin/main HEAD
t panel-author-line-preferred '["author-a","author-b","builder-one"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" builder-one)"
t panel-author-safety-subtraction '["author-a","author-b"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" builder-one | jq -c --arg me builder-one '. - [$me]')"
t panel-hyphen-author-literal '["hyphen-a","hyphen-b"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" hyphen-builder)"
t panel-missing-author-falls-back '["full-a","full-b","builder-one"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" unknown-builder)"

# A repo absent locally must choose the same author line from the contents API.
PANEL_API_CONF="$(base64 -w0 "$PANEL_REPO/.github/labels.conf")"
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { printf '%s\n' "$PANEL_API_CONF"; }
t panel-api-author-line '["author-a","author-b","builder-one"]' \
  "$(panel_for_repo owner/api "$TMP/not-cloned" builder-one)"
unset -f gh

# A stale/local config with no panel row retains the old contents-API fallback.
PANEL_EMPTY_REPO="$TMP/panel-empty-repo"
git init -q "$PANEL_EMPTY_REPO"
mkdir -p "$PANEL_EMPTY_REPO/.github"
printf '%s\n' 'scope:test|C5DEF5|fixture' >"$PANEL_EMPTY_REPO/.github/labels.conf"
git -C "$PANEL_EMPTY_REPO" add .github/labels.conf
git -C "$PANEL_EMPTY_REPO" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$PANEL_EMPTY_REPO" update-ref refs/remotes/origin/main HEAD
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { printf '%s\n' "$PANEL_API_CONF"; }
t panel-local-without-panel-uses-api '["full-a","full-b","builder-one"]' \
  "$(panel_for_repo owner/stale "$PANEL_EMPTY_REPO" unknown-builder)"
unset -f gh

# With neither repository config path available, the fleet bench is unchanged.
# shellcheck disable=SC2034  # consumed dynamically by sourced panel_for_repo
PANEL_SAVED_BENCH="${FLEET_BENCH-}"
PANEL_BENCH_WAS_SET="${FLEET_BENCH+x}"
FLEET_BENCH='bench-a bench-b'
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { return 1; }
t panel-bench-fallback '["bench-a","bench-b"]' \
  "$(panel_for_repo owner/missing "$TMP/not-cloned" builder-one)"
unset -f gh
if [ -n "$PANEL_BENCH_WAS_SET" ]; then
  FLEET_BENCH="$PANEL_SAVED_BENCH"
else
  unset FLEET_BENCH
fi

# Both request and convergence paths must receive an author-aware roster.
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq 'panel_for_repo "$R" "$dir" "$ME"' "$SHARED/lib/duty-builder.sh"; then r1=author_aware; else r1=FULL_PANEL; fi
t panel-builder-resolution author_aware "$r1"
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq 'panel_for_repo "$repo" "$WORK_DIR/${repo//\//__}-review" "$author"' "$SHARED/lib/duty-review.sh"; then r1=author_aware; else r1=FULL_PANEL; fi
t panel-reviewer-resolution author_aware "$r1"

suite_finish
