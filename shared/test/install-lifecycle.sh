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

# 9. #96's three operator verbs, still fully offline. A stub box CLI makes
# hired engines drivable without a fleet; `exec` prints the requested box's
# stamp from a fixture file, while `list --json` supplies the names.
vshim="$WORK/version-shim"; mkdir -p "$vshim"
BOX_ENGINES="$WORK/box-engines"; export BOX_ENGINES
cat >"$vshim/box" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    if [ "${2:-}" = --json ]; then
      awk '{printf "%s{\"name\":\"%s\"}", sep, $1; sep=","} BEGIN{printf "["} END{print "]"}' "$BOX_ENGINES"
    fi
    ;;
  exec)
    name="${2:-}"
    awk -v name="$name" '$1 == name {$1=""; sub(/^ /, ""); print; exit}' "$BOX_ENGINES"
    ;;
esac
SHIM
chmod +x "$vshim/box"
export PATH="$vshim:$CREW_BIN:$PATH"
: >"$BOX_ENGINES"

versions_out="$("$CREW_HOME/versions/$VA/cli/crew" versions 2>&1)"
case "$versions_out" in
  *"$VA"*"(running)"*"$VC"*"(current)"*) ok "versions-marks-running-and-current" ;;
  *) bad "versions-marks-running-and-current (got '$versions_out')" ;;
esac
case "$versions_out" in
  *"crew use <version>"*"re-run install.sh"*) ok "versions-names-switch-and-install-hints" ;;
  *) bad "versions-names-switch-and-install-hints" ;;
esac

# Existing hired boxes MUST NOT block a host switch. They are independent
# engines; the switch succeeds and reports exactly who was left behind.
printf 'claude-builder crew@%s (aaa)\nkimi-reviewer crew@%s (bbb)\n' "$VB" "$VC" >"$BOX_ENGINES"
if use_out="$("$CREW_BIN/crew" use "$VA" 2>&1)"; then
  ok "use-under-hired-boxes-flips"
else
  bad "use-under-hired-boxes-flips (got '$use_out')"
fi
case "$use_out" in
  *"switched to $VA"*claude-builder*"$VB"*kimi-reviewer*"$VC"*"crew upgrade --all"*)
    ok "use-names-skewed-boxes-and-remedy" ;;
  *) bad "use-names-skewed-boxes-and-remedy (got '$use_out')" ;;
esac
same "use-effective-same-shell" "crew $VA ($CREW_HOME/versions/$VA)" \
  "$("$CREW_BIN/crew" --version)"
same "use-effective-new-shell" "crew $VA ($CREW_HOME/versions/$VA)" \
  "$(HOME="$HOME" PATH="$PATH" bash -c 'crew --version')"

if current_out="$("$CREW_BIN/crew" uninstall "$VA" --force 2>&1)"; then
  bad "uninstall-current-refuses"
else
  case "$current_out" in *CURRENT*) ok "uninstall-current-refuses" ;; *) bad "uninstall-current-refuses (got '$current_out')" ;; esac
fi

# A process whose argv holds this version's floor path is a live-console
# interlock. The test process does not open a socket; only the held tree path
# matters to the uninstall guard.
floor_path="$CREW_HOME/versions/$VB/fleet-floor/server/floor.py"
bash -c 'exec -a "$1" sleep 60' _ "$floor_path" &
floor_pid=$!
if floor_out="$("$CREW_BIN/crew" uninstall "$VB" --force 2>&1)"; then
  bad "uninstall-live-floor-refuses"
else
  case "$floor_out" in *"live crew floor"*"$floor_pid"*) ok "uninstall-live-floor-refuses" ;; *) bad "uninstall-live-floor-refuses (got '$floor_out')" ;; esac
fi
kill "$floor_pid" 2>/dev/null || true
wait "$floor_pid" 2>/dev/null || true

# rm's rc is never the verdict. Make versions/ non-writable so rm can empty
# the target but cannot remove its name; the explicit absence re-check must
# say INCOMPLETE and return 1.
chmod 555 "$CREW_HOME/versions"
if incomplete_out="$("$CREW_BIN/crew" uninstall "$VB" --force 2>&1)"; then
  bad "uninstall-survivor-is-incomplete"
else
  case "$incomplete_out" in *INCOMPLETE*"$VB"*) ok "uninstall-survivor-is-incomplete" ;; *) bad "uninstall-survivor-is-incomplete (got '$incomplete_out')" ;; esac
fi
chmod 755 "$CREW_HOME/versions"
CREW_REINSTALL=1 install_from "$SB"
"$CREW_BIN/crew" use "$VA" >/dev/null 2>&1
if "$CREW_BIN/crew" uninstall "$VB" --force >/dev/null 2>&1 &&
   [ ! -e "$CREW_HOME/versions/$VB" ]; then
  ok "uninstall-other-removes-and-proves"
else
  bad "uninstall-other-removes-and-proves"
fi

ln -sfn versions/gone "$CREW_HOME/current"
if dangling_out="$("$CREW_HOME/versions/$VA/cli/crew" uninstall "$VC" --force 2>&1)"; then
  bad "uninstall-dangling-current-refuses"
else
  case "$dangling_out" in *"current is dangling"*) ok "uninstall-dangling-current-refuses" ;; *) bad "uninstall-dangling-current-refuses (got '$dangling_out')" ;; esac
fi
"$CREW_HOME/versions/$VA/cli/crew" use "$VA" >/dev/null 2>&1

# The installer suite exports CREW_YES=1 globally; clear it here because this
# assertion drives the default refusal, then prove the explicit force path.
if all_out="$(CREW_YES='' "$CREW_BIN/crew" uninstall --all 2>&1)"; then
  bad "uninstall-all-hired-refuses"
else
  case "$all_out" in
    *claude-builder*kimi-reviewer*"keeps running autonomously"*unattended*"crew down"*--force*CREW_YES*"console only"*"'crew status'"*)
      ok "uninstall-all-hired-refuses-and-explains" ;;
    *) bad "uninstall-all-hired-refuses-and-explains (got '$all_out')" ;;
  esac
fi
: >"$BOX_ENGINES"
if "$CREW_BIN/crew" uninstall --all --force >/dev/null 2>&1 &&
   [ ! -e "$CREW_HOME" ] && [ ! -L "$CREW_BIN/crew" ]; then
  ok "uninstall-all-removes-console-and-path-link"
else
  bad "uninstall-all-removes-console-and-path-link"
fi

# All three verbs distinguish a checkout from disposable install data.
for verb in versions use uninstall; do
  args=()
  [ "$verb" = use ] && args=("$VA")
  [ "$verb" = uninstall ] && args=(--all --force)
  if worktree_out="$("$ROOT/cli/crew" "$verb" "${args[@]}" 2>&1)"; then
    bad "$verb-working-tree-refuses"
  else
    case "$worktree_out" in *"working tree"*"$ROOT"*) ok "$verb-working-tree-refuses" ;; *) bad "$verb-working-tree-refuses (got '$worktree_out')" ;; esac
  fi
done

echo
echo "install-lifecycle: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
