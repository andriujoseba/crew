#!/usr/bin/env bash
# Contract tests for .github/scope-coverage.py — the guard on the scope map.
#
# Two halves, and the second is the one that matters. The first runs the guard
# over this repository's own tracked tree, which is the assertion the CI gate
# makes. The second drives it over fixture repositories built here: a tree with
# an unmapped directory, an exception with no reason, an exception that has
# stopped applying. A guard is only worth its green when its red has been seen,
# so every case below asserts the exit status AND what the guard said — a
# failure that does not name the path costs the same hand census the guard was
# written to stop paying (#500 D3).
#
# Offline, no credentials, no network: `git init` in a temp directory is the
# whole apparatus.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/.github/scope-coverage.py"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# A fixture repository: a scope map, an optional allow-list, and tracked files.
# `git add` is what makes a path tracked, so the fixture exercises the same
# enumeration CI does rather than a list handed to the guard.
#   fixture <name> <<'YAML' ... labeler.yml body ... YAML
fixture() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.github"
  cat >"$dir/.github/labeler.yml"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" config user.email t@e.st
  git -C "$dir" config user.name test
  printf '%s' "$dir"
}

# Track a file with content, creating its parent.
track() { mkdir -p "$(dirname "$1/$2")"; printf 'x\n' >"$1/$2"; git -C "$1" add -f "$2"; }

# Run the guard on a fixture, capturing both streams and the status.
run_guard() { OUT="$(python3 "$GUARD" --root "$1" 2>&1)"; RC=$?; }

# Assert the last run's status; and, where the case turns on it, what it said.
#   t_rc   <expected-rc> <name>
#   t_says <expected-rc> <name> <case-pattern>     — the guard names it
#   t_mute <expected-rc> <name> <case-pattern>     — and does not name this
t_rc()   { if [ "$RC" -eq "$1" ]; then ok "$2"; else bad "$2 (rc=$RC, got '$OUT')"; fi; }
t_says() {
  # shellcheck disable=SC2254  # $3 is a case pattern, deliberately unquoted
  case "$OUT" in $3) t_rc "$1" "$2" ;; *) bad "$2 (rc=$RC, unsaid, got '$OUT')" ;; esac
}
t_mute() {
  # shellcheck disable=SC2254  # $3 is a case pattern, deliberately unquoted
  case "$OUT" in $3) bad "$2 (rc=$RC, said, got '$OUT')" ;; *) t_rc "$1" "$2" ;; esac
}

# --- the repository's own tree ------------------------------------------------
# The assertion the CI gate makes, made here too so a builder sees it locally.
run_guard "$ROOT"
t_rc 0 "the-repository-tree-is-fully-covered"

# Green says what it checked: a count that could silently become zero is how a
# guard stops guarding without going red.
t_says 0 "green-reports-what-it-measured" '*tracked paths*rows*all covered.*'

# --- an unmapped directory ----------------------------------------------------
D="$(fixture unmapped <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["mapped/**"]
YAML
)"
track "$D" mapped/covered.md
track "$D" newthing/thing.md
track "$D" newthing/deeper/also.md
run_guard "$D"
t_rc 1 "an-unmapped-directory-is-red"
# D3: named, not counted. Both paths, not just the first.
t_says 1 "the-unmapped-path-is-named" '*newthing/thing.md*'
t_says 1 "every-unmapped-path-is-named-not-just-the-first" '*newthing/deeper/also.md*'
# The mapped sibling is not swept up in the complaint.
t_mute 1 "a-mapped-path-is-not-reported" '*unmapped: mapped/covered.md*'

# The same tree, with the directory mapped, is green — the guard is answering
# the map and not merely counting directories.
cat >"$D/.github/labeler.yml" <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["mapped/**", "newthing/**"]
YAML
run_guard "$D"
t_rc 0 "mapping-the-directory-turns-it-green"

# --- the declared allow-list --------------------------------------------------
D="$(fixture allow <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["mapped/**"]
YAML
)"
track "$D" mapped/covered.md
track "$D" loose.txt
run_guard "$D"
t_rc 1 "an-undeclared-loose-path-is-red"

printf 'loose.txt  # deliberately unmapped, and here is why\n' >"$D/.github/scope-coverage.allow"
run_guard "$D"
t_rc 0 "a-declared-exception-with-a-reason-is-green"

# D4: with a reason, or not at all — an entry that just names a path is the
# wholesale silencing the allow-list exists instead of.
printf 'loose.txt\n' >"$D/.github/scope-coverage.allow"
run_guard "$D"
t_says 2 "an-exception-without-a-reason-is-refused" '*no reason*'

# An exception that has stopped applying reads as covered and covers nothing.
printf 'loose.txt  # the reason\ngone.txt  # for a path that left\n' >"$D/.github/scope-coverage.allow"
run_guard "$D"
t_says 1 "an-exception-matching-nothing-is-red-and-named" '*gone.txt*matches no tracked path*'

# An exception for a path a row already covers hides the mapping.
printf 'loose.txt  # the reason\nmapped/covered.md  # already owned\n' >"$D/.github/scope-coverage.allow"
run_guard "$D"
t_says 1 "an-exception-a-row-already-covers-is-red-and-named" '*mapped/covered.md*hides the mapping*'

# --- refusals: the guard says so rather than guessing -------------------------
D="$(fixture badkey <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-all-files: ["mapped/**"]
YAML
)"
track "$D" mapped/covered.md
run_guard "$D"
t_says 2 "a-match-key-the-guard-does-not-evaluate-is-refused" '*any-glob-to-all-files*'

D="$(fixture badglob <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["mapped/*.{md,txt}"]
YAML
)"
track "$D" mapped/covered.md
run_guard "$D"
t_says 2 "a-glob-syntax-the-scope-job-reads-as-literal-is-refused" '*labeler.yml:3:*reads as literal characters*'

D="$(fixture emptyrow <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["mapped/**"]
"scope:hollow":
  - changed-files:
      - any-glob-to-any-file: []
YAML
)"
track "$D" mapped/covered.md
run_guard "$D"
t_rc 2 "an-empty-glob-list-is-refused"

# A tree with nothing tracked is not a pass. This is the shape a guard run from
# the wrong directory, or before a checkout, would otherwise take: zero paths,
# zero complaints, green.
D="$(fixture emptytree <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["mapped/**"]
YAML
)"
run_guard "$D"
t_says 2 "an-empty-tree-is-refused-not-passed" '*nothing was checked*'

D="$WORK/nomap"; mkdir -p "$D"; git -C "$D" init -q 2>/dev/null
run_guard "$D"
t_rc 2 "a-missing-scope-map-is-refused"

# --- the glob dialect ---------------------------------------------------------
# `dir/**` covers every depth below dir and nothing beside it — the property
# five of this PR's six mappings rest on.
D="$(fixture globstar <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["dir/**", "top.md"]
YAML
)"
track "$D" dir/one.md
track "$D" dir/a/b/two.md
track "$D" top.md
run_guard "$D"
t_rc 0 "globstar-covers-every-depth-and-a-literal-covers-itself"

track "$D" dirt/sibling.md
run_guard "$D"
t_says 1 "globstar-does-not-leak-into-a-sibling-with-the-same-prefix" '*dirt/sibling.md*'

# A leading dot is not special to the scope job, and four of this repo's rows
# are dotted paths. A translator that treated it as special would report them
# unmapped.
D="$(fixture dotfiles <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: [".github/workflows/**", ".ceremony/**"]
YAML
)"
track "$D" .github/workflows/one.yml
track "$D" .ceremony/AGENTS.md
run_guard "$D"
t_rc 0 "dotted-paths-match-their-rows"

# Both list spellings mean the same thing: this repo's file uses each.
D="$(fixture blocklist <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file:
          - "dir/**"
          - "top.md"
YAML
)"
track "$D" dir/one.md
track "$D" top.md
run_guard "$D"
t_rc 0 "a-block-glob-list-reads-the-same-as-an-inline-one"

# And the scope job accepts a bare glob where a list would do, so this guard
# has to read that spelling too rather than call the row unreadable.
D="$(fixture bareglob <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: "dir/**"
YAML
)"
track "$D" dir/one.md
run_guard "$D"
t_rc 0 "a-bare-glob-reads-the-same-as-a-one-item-list"

# A backslash is what the scope job itself refuses by name; a row carrying one
# fails the whole job, so this guard must not report the tree covered.
D="$(fixture backslash <<'YAML'
"scope:mapped":
  - changed-files:
      - any-glob-to-any-file: ["dir/a\\.md"]
YAML
)"
track "$D" dir/one.md
run_guard "$D"
t_rc 2 "a-backslash-escape-is-refused"

echo
echo "scope-coverage: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
