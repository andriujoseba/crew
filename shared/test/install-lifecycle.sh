#!/usr/bin/env bash
# shared/test/install-lifecycle.sh — real, OFFLINE installs of the crew CLI
# against the tree under test (no network, no root). Runs in CI (shared-ci.yml)
# and by hand. Asserts the versioned layout, root-resolution through the
# `current` symlink, coexistence/flip, the converging re-run, and — the
# regression codex-bot and grok-bot required on #95 — that an interrupted
# `CREW_REINSTALL` of the ACTIVE default never leaves `current` resolving to
# nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"            # repo root: the crew tree to install
SRC="${CREW_LIFECYCLE_SOURCE:-$ROOT}"
INSTALL="$ROOT/install.sh"

PASS=0 FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
same()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Hermetic: consent on, and HOME points into the scratch so the ~/crew
# checkout-naming probe never sees the runner's real home.
export CREW_YES=1 HOME="$WORK"
export CREW_HOME="$WORK/share" CREW_BIN="$WORK/bin"

VA=0.0.0-lifecycle-a VB=0.0.0-lifecycle-b
mk_src() {  # <dir> <version> — the tree under test, with VERSION rewritten
  mkdir -p "$1"
  tar -C "$SRC" --exclude=.git -cf - . | tar -xf - -C "$1"
  printf '%s\n' "$2" > "$1/VERSION"
}
SA="$WORK/src-a"; SB="$WORK/src-b"
mk_src "$SA" "$VA"
mk_src "$SB" "$VB"
install_from() { CREW_INSTALL_SOURCE="$1" bash "$INSTALL" >/dev/null 2>&1; }

# 1. fresh install → PATH link resolves under versions/, and the installed crew
#    runs THROUGH the current symlink (which is what proves $CREW_ROOT resolved
#    into the versioned tree, not $BINDIR).
install_from "$SA"
link="$(readlink -f "$CREW_BIN/crew" 2>/dev/null || true)"
case "$link" in
  */versions/"$VA"/cli/crew) ok "fresh-install-under-versions" ;;
  *) bad "fresh-install-under-versions (got '$link')" ;;
esac
if ( cd "$WORK" && "$CREW_BIN/crew" help >/dev/null 2>&1 ); then
  ok "installed-crew-runs-through-symlink"
else
  bad "installed-crew-runs-through-symlink"
fi

# 2. re-run the same version → no-op, current unchanged
before="$(readlink "$CREW_HOME/current")"
install_from "$SA"
same "reinstall-same-version-is-noop" "$before" "$(readlink "$CREW_HOME/current")"

# 3. install a second version → both coexist, current flips to it
install_from "$SB"
if [ -d "$CREW_HOME/versions/$VA" ] && [ -d "$CREW_HOME/versions/$VB" ]; then
  ok "two-versions-coexist"
else
  bad "two-versions-coexist"
fi
same "new-version-becomes-current" "versions/$VB" "$(readlink "$CREW_HOME/current")"

# 4. re-run the OLDER version → current must NOT move
install_from "$SA"
same "reinstall-older-does-not-flip" "versions/$VB" "$(readlink "$CREW_HOME/current")"

# 5. CREW_REINSTALL of a NON-default version → replaces its tree, current stays
CREW_REINSTALL=1 install_from "$SA"
same "reinstall-nondefault-current-stays" "versions/$VB" "$(readlink "$CREW_HOME/current")"

# 6. THE REGRESSION (#95 test plan; codex-bot + grok-bot): CREW_REINSTALL of the
#    ACTIVE default, KILLED the instant the live version dir is renamed aside —
#    the between-the-two-renames point — must leave `current` still resolving to
#    a crew tree, never dangling. A `mv` shim on PATH performs the aside-rename
#    (dest …/versions/<v>.old.<pid>) and then SIGKILLs the installer at that
#    exact point.
shim="$WORK/shim"; mkdir -p "$shim"
real_mv="$(command -v mv)"
cat > "$shim/mv" <<SHIM
#!/usr/bin/env bash
last="\${@: -1}"
"$real_mv" "\$@"; rc=\$?
case "\$last" in */versions/*.old.*) kill -KILL "\$PPID" 2>/dev/null ;; esac
exit \$rc
SHIM
chmod +x "$shim/mv"
# current is on $VB (the active default); reinstall $VB under the killer shim.
# Backgrounded and waited so the shell's own "Killed" job notice stays quiet —
# the SIGKILL is the point of the test, not an error.
PATH="$shim:$PATH" CREW_REINSTALL=1 CREW_INSTALL_SOURCE="$SB" bash "$INSTALL" >/dev/null 2>&1 &
wait "$!" 2>/dev/null || true
if [ -e "$CREW_HOME/current/cli/crew" ]; then
  ok "interrupted-reinstall-keeps-current-resolvable"
else
  bad "interrupted-reinstall-keeps-current-resolvable (current -> '$(readlink "$CREW_HOME/current" 2>/dev/null || echo '<none>')' dangles)"
fi

# 7. recovery: a normal install after the interrupted reinstall heals `current`
#    back onto the canonical version and reaps the orphaned old-tree scratch.
install_from "$SB"
same "post-interrupt-heals-to-canonical" "versions/$VB" "$(readlink "$CREW_HOME/current")"
if ( cd "$WORK" && "$CREW_BIN/crew" help >/dev/null 2>&1 ); then
  ok "post-interrupt-crew-runs"
else
  bad "post-interrupt-crew-runs"
fi

# 8. A legitimate version whose name RESEMBLES swap scratch (valid_version
#    accepts dots + digits, so `1.0.new.999` is a sane version name) must
#    survive a later normal install — the scratch reaper keys on identity
#    (VERSION == basename), not on the name shape (codex-bot, #95).
#    The reaper reads `current` at entry, so it also spares whatever `current`
#    resolves to; to prove guard 2 (VERSION==basename) and not merely guard 1
#    (is-current), `current` must have moved OFF the lookalike before the
#    reaping install: install it, flip past it with a fresh version, then let a
#    no-op re-run's reaper fire while `current` points elsewhere.
VS=1.0.new.999 VC=0.0.0-lifecycle-c
SS="$WORK/src-scratchlike"; SC="$WORK/src-c"
mk_src "$SS" "$VS"; mk_src "$SC" "$VC"
install_from "$SS"                       # current -> VS
sentinel="$CREW_HOME/versions/$VS/SENTINEL"
: > "$sentinel"
install_from "$SC"                       # fresh install flips current -> VC
same "flip-off-scratch-lookalike" "versions/$VC" "$(readlink "$CREW_HOME/current")"
install_from "$SA"                       # no-op re-run; its reaper fires, current=VC
if [ -d "$CREW_HOME/versions/$VS" ] && [ -e "$sentinel" ]; then
  ok "scratch-lookalike-version-survives-reaper"
else
  bad "scratch-lookalike-version-survives-reaper (tree/sentinel reaped)"
fi

echo
echo "install-lifecycle: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
