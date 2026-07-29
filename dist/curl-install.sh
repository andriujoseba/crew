#!/usr/bin/env bash
set -euo pipefail
# dist/curl-install.sh — the anonymous `curl | bash` install channel
# (heavy-duty/crew#171).
#
#   curl -fsSL https://raw.githubusercontent.com/heavy-duty/crew/main/dist/curl-install.sh | bash
#
# DELIBERATELY TEMPORARY. It exists because crew is hosted on GitHub today, and
# it comes out when crew moves off GitHub after 0.1.0 — removal is `git rm` of
# this one file plus the README block that names it. That end date is why it is
# a script beside dist/fetch.sh rather than a network path grafted into
# install.sh: install.sh's source is a LOCAL tree by design, it stays
# offline-testable, and a bug here cannot reach the artifact or CI install
# paths.
#
# Same contract as dist/fetch.sh, different transport: IT FETCHES, install.sh
# INSTALLS. fetch.sh goes through an authenticated `gh`; this one is anonymous
# curl — no API, no token, just a redirect and a tarball. One knob:
#
#   (unset)          the latest published release        <- the default
#   CREW_REF=0.1.0   that release tag
#   CREW_REF=main    the development tip (a -dev VERSION)
#   CREW_INSTALL_SOURCE=<a crew tree>   a local tree; nothing is downloaded
#
# The scp-able artifact (#98) remains the primary, credential-free channel; the
# `gh` channel is untouched. This is a fourth, for the window in which crew
# lives on GitHub.

REPO='heavy-duty/crew'
REF="${CREW_REF:-}"

say() { printf 'crew-curl-install: %s\n' "$*"; }
die() { printf 'crew-curl-install: ERROR: %s\n' "$*" >&2; exit 1; }

# THE `curl | bash` TRAP, which has bitten box: under the one-liner THIS SCRIPT
# is bash's stdin, so a plain `read` consumes the rest of the script instead of
# the operator's answer — and passes every other way it is tested. Every prompt
# here reads /dev/tty, exactly as install.sh's confirm() does. No terminal (CI,
# a pipe with no tty) means there is nobody to ask: CREW_YES=1 is the
# non-interactive consent contract, and without it we refuse rather than
# silently assume consent.
confirm() {  # $1 = question
  [ -n "${CREW_YES:-}" ] && return 0
  if ! { true >/dev/tty; } 2>/dev/null; then
    die "no terminal to confirm on. Re-run with CREW_YES=1 to proceed non-interactively (assumes yes to all prompts)."
  fi
  local reply
  printf 'crew-curl-install: %s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- CREW_INSTALL_SOURCE still wins ----------------------------------------
# A local tree short-circuits the network entirely — no resolution, no
# download, not one request. This channel only ever adds a way to GET a tree;
# an operator who already has one keeps the offline path.
if [ -n "${CREW_INSTALL_SOURCE:-}" ]; then
  if [ ! -d "$CREW_INSTALL_SOURCE" ] || [ ! -f "$CREW_INSTALL_SOURCE/install.sh" ]; then
    die "CREW_INSTALL_SOURCE='$CREW_INSTALL_SOURCE' is not a crew tree with an install.sh in it. This channel short-circuits to a local TREE; for a tarball, extract it and run its install.sh directly."
  fi
  say "CREW_INSTALL_SOURCE is set — installing from $CREW_INSTALL_SOURCE. Nothing is downloaded."
  # Exported, not prefixed: the operator may have set it without exporting, and
  # install.sh reads it from its own environment.
  export CREW_INSTALL_SOURCE
  rc=0
  bash "$CREW_INSTALL_SOURCE/install.sh" || rc=$?
  exit "$rc"
fi

for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "$tool is required by this channel but was not found. The scp-able artifact (crew-<version>.sh) needs neither curl nor a network."
done

# --- say what this is about to do, BEFORE it does any of it ----------------
case "$REF" in
  '')   want='the latest published release' ;;
  main) want="the development tip (branch 'main')" ;;
  *)    want="ref '$REF'" ;;
esac
say "about to download crew from https://github.com/$REPO — $want — and install it under ${CREW_HOME:-$HOME/.local/share/crew}."
say "nothing has been downloaded yet."
confirm "Download $want of $REPO and install it?" \
  || die "cancelled — nothing was downloaded and nothing was changed."

# --- resolve the ref -------------------------------------------------------
# The latest release comes off GitHub's own /releases/latest redirect: a plain
# HEAD, no API and no token. Resolving it to a CONCRETE tag is the point — two
# operators running the same one-liner must get the same crew, and the
# provenance stamp must name what was installed, not the word "latest".
if [ -z "$REF" ]; then
  latest_url="https://github.com/$REPO/releases/latest"
  redirect="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$latest_url" 2>/dev/null)" \
    || die "could not reach $latest_url to resolve the latest release. This channel needs anonymous access to github.com; the scp-able artifact needs no network at all."
  case "$redirect" in
    *"/releases/tag/"*) REF="${redirect##*/releases/tag/}" ;;
    # No releases yet (GitHub sends /releases/latest to the releases index) or
    # a redirect we do not recognise. REFUSING IS THE WHOLE POINT: falling back
    # to the tip here would install a different tree for every operator, from
    # the same command, silently.
    *) die "$REPO has no published release to install — GitHub redirected $latest_url to '${redirect:-<nothing>}'. Refusing rather than quietly installing the development tip; CREW_REF=main asks for that on purpose." ;;
  esac
  REF="${REF%%\?*}"; REF="${REF%/}"
  say "latest release resolves to $REF"
fi

# One gate for the ref, whatever its origin, because it is about to be pasted
# into a URL and to name a file: only [A-Za-z0-9._+-], no leading '.' or '-'.
# install.sh's valid_version() guards the version directory the same way.
case "$REF" in
  ''|.*|-*)           die "refusing an unusable ref '$REF' — it must not be empty or start with '.' or '-'." ;;
  *[!A-Za-z0-9._+-]*) die "refusing an unusable ref '$REF' — CREW_REF (and a resolved tag) must be made of [A-Za-z0-9._+-]." ;;
esac

# --- download and hand it to install.sh ------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tarball="$tmp/$REPO-$REF.tar.gz"; mkdir -p "$(dirname "$tarball")"
url="https://codeload.github.com/$REPO/tar.gz/$REF"
say "downloading $url"
curl -fsSL -o "$tarball" "$url" \
  || die "could not download $url — if '$REF' is not a tag or branch of $REPO, that is the likely reason."
[ -s "$tarball" ] || die "the download of $url produced an empty file"

mkdir -p "$tmp/tree"
tar -xzf "$tarball" -C "$tmp/tree" \
  || die "what $url returned is not a readable gzip tarball"
SRCDIR="$(find "$tmp/tree" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "$SRCDIR" ] || die "the archive from $url contained no source tree"
[ -f "$SRCDIR/install.sh" ] \
  || die "the tree at $REF carries no install.sh — this channel installs crew trees, and $REF does not look like one"

# Run the FETCHED tree's install.sh — under the one-liner this script has no
# sibling tree at all, and installing a version with its own installer is the
# only self-consistent choice.
# Run it as a CHILD, not `exec`: a successful `exec` replaces this shell and its
# EXIT trap never fires, orphaning the download under $tmp (dist/fetch.sh
# learned this the same way). Capture the status and exit with it so the trap
# cleans up.
# CREW_YES=1 because consent was already given above, to this exact download —
# install.sh's own prompt would ask again about a temp path the operator never
# chose and cannot judge.
rc=0
CREW_INSTALL_SOURCE="$SRCDIR" CREW_INSTALLED_FROM="curl:$REPO ref:$REF" CREW_YES=1 \
  bash "$SRCDIR/install.sh" || rc=$?
exit "$rc"
