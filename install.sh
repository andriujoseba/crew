#!/usr/bin/env bash
set -euo pipefail

# crew installer — puts the `crew` CLI on PATH in a VERSIONED layout under
# $DEST:
#
#   $DEST/versions/<version>/    one full tree per installed version
#   $DEST/current -> versions/<version>        the default version
#   $BINDIR/crew  -> $DEST/current/cli/crew     the PATH entry
#
# Versions install side by side: a NEW version installs beside the old one and
# becomes the default; re-running with an already-installed version is a
# converging no-op (CREW_REINSTALL=1 replaces that version's tree). `crew
# versions` / `crew use` / `crew uninstall` (heavy-duty/crew#96) manage them
# once they land; this installer lays the ground they stand on.
#
# PORTED FROM box's install.sh (heavy-duty/box#79; rig#35 is the proof the port
# works), with three crew-specific rules — each a deliberate divergence:
#
#   * PER-USER ONLY, root REFUSED. box installs globally as root because OTHER
#     users execute its tree. crew is run by ONE operator against THEIR OWN
#     boxes, and box's restricted tier makes "their own" a real boundary — a
#     root-installed crew would act on ROOT's boxes. So a root install dies
#     with that reason rather than landing in a system location.
#
#   * FLIP, then REPORT the skew — never refuse it. box refuses to move the
#     default while boxes exist (box#66), because there one version owns the
#     boxes. Here the axes are independent (heavy-duty/crew#93, finding 2): the
#     host CLI version and each box's engine version are different things, and
#     flipping the CLI touches no box. So a new version becomes the default and
#     the installer reports the boxes still to be converged, rather than
#     blocking a switch for a reason that does not apply here.
#
#   * The entrypoint is `cli/crew`, not `bin/crew` — crew's command lives in
#     cli/. The PATH link points there; cli/crew resolves its own real path
#     (readlink -f) so $CREW_ROOT lands in the versioned tree, not $BINDIR.
#
# CREW IS PRIVATE (heavy-duty/crew#98): there is no public `curl | bash`
# channel to port. The source is a LOCAL tree — CREW_INSTALL_SOURCE, defaulting
# to the tree this script lives in — so a checkout installs itself, CI installs
# the code under review, and heavy-duty/crew#98's self-contained scp-able
# artifact installs by unpacking and pointing CREW_INSTALL_SOURCE at the
# result. Network distribution is #98's job, not this file's.

# Non-root installs per-user; root is refused outright (see the header). box's
# global-install branch is deliberately dropped.
if [ "$(id -u)" -eq 0 ]; then
  printf 'crew-install: ERROR: %s\n' \
    "refusing a root install. crew acts on the operator's OWN boxes, and box's restricted tier makes that a real boundary — a root-installed crew would act on root's boxes instead. Install it as the operator user (per-user, under \$HOME/.local)." >&2
  exit 1
fi
DEST="${CREW_HOME:-$HOME/.local/share/crew}"
BINDIR="${CREW_BIN:-$HOME/.local/bin}"

log() { printf 'crew-install: %s\n' "$*"; }
warn() { printf 'crew-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'crew-install: ERROR: %s\n' "$*" >&2; exit 1; }

# Ask a yes/no question. Under a piped invocation THIS SCRIPT may be stdin, so
# prompts read /dev/tty directly. No terminal (CI, a pipe with no tty) → there
# is nobody to ask: CREW_YES=1 is the non-interactive consent contract; without
# it we refuse rather than silently assume consent.
confirm() {  # $1 = question
  [ -n "${CREW_YES:-}" ] && return 0
  if ! { true >/dev/tty; } 2>/dev/null; then
    die "no terminal to confirm on. Re-run with CREW_YES=1 to proceed non-interactively (assumes yes to all prompts)."
  fi
  local reply
  printf 'crew-install: %s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# A version is a DIRECTORY NAME under versions/ — nothing else. One strict gate
# for every caller that builds a path from one: only [A-Za-z0-9._+-], no
# leading '.' or '-'. That forbids '/', '..'-escapes, spaces and
# option-lookalikes by construction — a crafted version dies HERE, never in an
# rm -rf or an ln. cli/crew carries a byte-identical copy; shared/test/run.sh
# diffs the two so the gates cannot drift.
valid_version() {
  case "$1" in
    ''|.*|-*) return 1 ;;
    *[!A-Za-z0-9._+-]*) return 1 ;;
  esac
  return 0
}

# Which boxes exist on this host? Prints their names (both tag generations) and
# succeeds when at least one exists. Bounded with `timeout` so a wedged daemon
# cannot hang the install (heavy-duty/crew#79 is exactly this hazard). Used
# ONLY to decide whether to report skew after a flip — never to refuse one.
existing_boxes() {
  command -v incus >/dev/null 2>&1 || return 1
  { timeout 10 incus list user.box=1 --format csv --columns n </dev/null
    timeout 10 incus list user.claudebox=1 --format csv --columns n </dev/null
  } 2>/dev/null | awk -F, 'NF && !seen[$1]++ { print $1 }' | grep .
}

# Flip $DEST/current to versions/<v> atomically: build the new link beside it,
# rename over. Plain `ln -sfn` is unlink+create — a window where current names
# nothing and a concurrent `crew` invocation dies mid-chain. cli/crew's
# `crew use` (heavy-duty/crew#96) flips with the same pattern.
flip_current() {
  ln -sfn "versions/$1" "$DEST/current.new.$$"
  mv -Tf "$DEST/current.new.$$" "$DEST/current"
}

# --- the source tree -------------------------------------------------------
# A LOCAL tree (see the header): CREW_INSTALL_SOURCE, or the tree this script
# lives in. install.sh sits at the repo root, so its own directory IS a crew
# tree — running `bash install.sh` from a checkout installs that checkout.
self="$(readlink -f "${BASH_SOURCE[0]}")"
SRC="${CREW_INSTALL_SOURCE:-$(cd "$(dirname "$self")" && pwd)}"
command -v tar >/dev/null 2>&1 || die "tar is required but was not found. Please install tar and re-run."

confirm "Install crew from $SRC?" || die "cancelled — nothing was changed."

# --- temp workspace --------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- acquire the tree ------------------------------------------------------
INSTALLED_FROM="local:$SRC"
if [ -d "$SRC" ]; then
  log "copying local tree $SRC"
  mkdir -p "$TMPDIR/tree"
  # tar, not cp -a: --exclude=.git, so a working checkout never carries its VCS
  # state (or its size) into the install tree.
  tar -C "$SRC" --exclude=.git -cf - . | tar -xf - -C "$TMPDIR/tree"
  EXTRACTED="$TMPDIR/tree"
elif [ -f "$SRC" ]; then
  log "extracting local tarball $SRC"
  tar -xzf "$SRC" -C "$TMPDIR" || die "failed to extract $SRC"
  EXTRACTED="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
else
  die "CREW_INSTALL_SOURCE is neither a directory nor a tarball: $SRC"
fi
[ -n "${EXTRACTED:-}" ] || die "could not find the source tree in $SRC"
[ -f "$EXTRACTED/cli/crew" ] || die "source does not contain cli/crew — is $SRC a crew tree?"

# The tree's own VERSION file names the directory it lands in — the version IS
# the identity of what is being installed.
new_ver="$(cat "$EXTRACTED/VERSION" 2>/dev/null || true)"
[ -n "$new_ver" ] || die "source has no VERSION file — cannot install it as a version"
valid_version "$new_ver" || die "the source's VERSION is not a sane directory name: '$new_ver'"

# --- install into $DEST/versions/<version> ---------------------------------
# Reap swap scratch from an interrupted prior run before installing:
# versions/*.new.<pid> and versions/*.old.<pid> are only ever transient (this
# run makes its own below). A kill leaves them behind, and #96's `crew versions`
# would otherwise list them (kimi-bot, #95). Remove them — but never the one
# `current` resolves to: an interrupted reinstall legitimately left a `.new.*`
# as the live tree, and removing it would dangle `current` (the next flip
# retires it). The trailing [0-9] keeps this to the pid-suffixed scratch, not a
# version whose name merely ends in something else.
cur_now="$(readlink -f "$DEST/current" 2>/dev/null || true)"
for d in "$DEST"/versions/*.new.[0-9]* "$DEST"/versions/*.old.[0-9]*; do
  [ -d "$d" ] || continue
  [ -n "$cur_now" ] && [ "$(readlink -f "$d")" = "$cur_now" ] && continue
  rm -rf "$d"
done

VDIR="$DEST/versions/$new_ver"
newly_installed=0
if [ -d "$VDIR" ]; then
  if [ -n "${CREW_REINSTALL:-}" ]; then
    # Replace THIS version's tree while keeping `current` resolvable at EVERY
    # interruption point. The naive swap — mv the live $VDIR aside, mv the
    # staged tree in — dangles `current` between the two renames when it points
    # at the version being replaced (the usual case: reinstalling the active
    # default). A kill in that window leaves `current` dangling until the next
    # install heals it (codex-bot and grok-bot both reproduced this on #95).
    #
    # The fix: when this version IS the active default, flip `current` onto the
    # fully-staged NEW tree FIRST — an atomic mv -Tf — so across both directory
    # renames `current` resolves to the new tree; flip it back to the canonical
    # path once that path holds the new tree. A non-default reinstall skips the
    # flips (nothing points here). Even a residual crash self-heals: the
    # default-version block below repoints a dangling `current` on the next run.
    log "CREW_REINSTALL=1 — replacing the installed $new_ver tree"
    stage="$VDIR.new.$$"; old="$VDIR.old.$$"
    rm -rf "$stage" "$old"
    chmod +x "$EXTRACTED/cli/crew"
    mv "$EXTRACTED" "$stage"
    active=0
    [ "$(readlink -f "$DEST/current" 2>/dev/null || true)" = "$(readlink -f "$VDIR" 2>/dev/null || true)" ] && active=1
    [ "$active" -eq 1 ] && flip_current "$new_ver.new.$$"   # current -> staged NEW tree
    # Swap by renames, delete LAST: rm-then-move leaves a hole the whole length
    # of the delete where a name resolves to nothing.
    mv "$VDIR" "$old"
    mv "$stage" "$VDIR"
    [ "$active" -eq 1 ] && flip_current "$new_ver"          # current -> canonical (now the NEW tree)
    rm -rf "$old"
    printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
    log "reinstalled $new_ver"
  else
    cur_from="$(cat "$VDIR/INSTALLED_FROM" 2>/dev/null || echo '<unknown source>')"
    log "crew $new_ver is already installed ($cur_from) — nothing to do."
    log "(CREW_REINSTALL=1 replaces this version's tree; 'crew versions' lists what is installed.)"
  fi
else
  log "installing $new_ver into $VDIR"
  mkdir -p "$DEST/versions"
  chmod +x "$EXTRACTED/cli/crew"
  mv "$EXTRACTED" "$VDIR"
  newly_installed=1
  # Record WHAT was installed, so a caller can assert it got what it asked for.
  printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
fi

# --- which version is the default? -----------------------------------------
# Flipping 'current' is the ONLY step that changes what an operator's `crew`
# runs. Unlike box (box#66), crew NEVER refuses the flip under existing boxes:
# the host CLI version and each box's engine version are independent axes
# (#93 finding 2). A fresh host (or a dangling current) is claimed; a re-run
# that installs no new default leaves the default alone; a genuinely new
# default flips, and then the skew it created is REPORTED.
cur="$(readlink -f "$DEST/current" 2>/dev/null || true)"
want="$(readlink -f "$VDIR")"
if [ -z "$cur" ] || [ ! -d "$cur" ]; then
  flip_current "$new_ver"
  log "default version: $new_ver"
elif [ "$cur" = "$want" ]; then
  : # already the default — nothing to flip
elif [ "$newly_installed" -eq 0 ]; then
  # A converge/no-op of a version that is NOT the default never moves the
  # default — a re-run must change nothing; switching is 'crew use', a
  # deliberate act.
  log "the default stays $(basename "$cur") — 'crew use $new_ver' switches."
else
  old_ver="$(basename "$cur")"
  flip_current "$new_ver"
  log "default version switched: $old_ver -> $new_ver ('crew use $old_ver' switches back)"
  # Report the skew the flip just created — never refuse it. Bounded, and
  # best-effort: this counts boxes (a fast, timeout-guarded incus list), not
  # each box's engine version, which would need a per-box exec that a wedged
  # box can hang (heavy-duty/crew#79). The engine axis is converged by its own
  # command, named here.
  if names="$(existing_boxes)"; then
    n="$(printf '%s\n' "$names" | grep -c .)"
    warn "the CLI default is now $new_ver, but $n hired box(es) still run the engine they were last hired with:"
    while IFS= read -r nm; do warn "  · $nm"; done <<<"$names"
    log "converge them to this CLI's engine when you are ready:  crew upgrade --all"
  fi
fi

# --- put crew on PATH ------------------------------------------------------
# ln -sfn converges, and that includes HEALING: a stale or dangling
# $BINDIR/crew must never block or wedge an install — it gets repointed at the
# current chain, whatever it said before.
mkdir -p "$BINDIR"
ln -sfn "$DEST/current/cli/crew" "$BINDIR/crew"
log "linked $BINDIR/crew -> $DEST/current/cli/crew"

# --- name an existing ~/crew checkout --------------------------------------
# Do NOT migrate or delete it (#95): it is the operator's working tree and may
# hold uncommitted work. Since #99 the host ships shared/+VERSION to the boxes,
# so ~/crew is no longer what `crew upgrade` pulls into — but it still shadows
# this installed crew on PATH. Naming beats a clever migration: PATH order
# decides which `crew` runs, so say so.
if [ -f "$HOME/crew/cli/crew" ] && [ -d "$HOME/crew/.git" ]; then
  warn "a crew git checkout also exists at $HOME/crew — its cli/crew and this installed one both answer to the name 'crew'."
  warn "  PATH order decides which runs (check: command -v crew). This installer left the checkout untouched."
fi

# --- PATH check ------------------------------------------------------------
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *)
    log "note: $BINDIR is not on your PATH."
    log "  add this to your shell rc (e.g. ~/.bashrc or ~/.zshrc):"
    log "      export PATH=\"$BINDIR:\$PATH\""
    ;;
esac

log "done (local:$SRC, version $new_ver) — try: crew help"
