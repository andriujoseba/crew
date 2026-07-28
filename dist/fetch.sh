#!/usr/bin/env bash
set -euo pipefail
# dist/fetch.sh — the gh-authenticated install channel (heavy-duty/crew#98,
# channel 3). For a machine that ALREADY holds an authenticated `gh` (danmt's
# own): resolve a release tag, fetch that ref's source tarball THROUGH gh — which
# works against a PRIVATE repo, with no anonymous URL and no `raw.githubusercontent`
# — and hand it to install.sh via CREW_INSTALL_SOURCE. It fetches; install.sh
# installs. The scp-able artifact remains the primary, credential-free channel;
# this one is a convenience where `gh` is already present.
#
#   dist/fetch.sh [--repo OWNER/REPO] [--ref latest|TAG] [-- <install.sh args>]
#
# Everything after `--` is passed to install.sh (e.g. CREW_YES=1 belongs in the
# environment, but --arm-cron-style flags would ride here).

REPO='heavy-duty/crew'
REF='latest'
die() { printf 'crew-fetch: ERROR: %s\n' "$*" >&2; exit 1; }

install_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --ref)  REF="${2:?--ref needs a value}"; shift 2 ;;
    --)     shift; install_args=("$@"); break ;;
    -h|--help)
      sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh is required for this channel. Use the scp-able artifact instead — it needs no gh."
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INSTALL="$HERE/../install.sh"
[ -f "$INSTALL" ] || die "cannot find install.sh next to me at $INSTALL"

# Resolve a moving 'latest' to a concrete tag so provenance records what was
# actually installed, not the word 'latest'.
if [ "$REF" = latest ]; then
  REF="$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null)" \
    || die "could not resolve the latest release of $REPO via gh (is it authenticated, and does a release exist?)"
  [ -n "$REF" ] || die "$REPO has no latest release to resolve"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tarball="$tmp/$REPO-$REF.tgz"; mkdir -p "$(dirname "$tarball")"
printf 'crew-fetch: fetching %s@%s via gh\n' "$REPO" "$REF"
gh api "repos/$REPO/tarball/$REF" > "$tarball" \
  || die "could not fetch the source tarball for $REPO@$REF via gh"
[ -s "$tarball" ] || die "gh returned an empty tarball for $REPO@$REF"

# install.sh's tarball path takes the single top-level directory of the archive,
# whatever gh named it (owner-repo-<sha>/). Name the provenance for the version
# dir so an installed tree records the ref it came from.
CREW_INSTALL_SOURCE="$tarball" CREW_INSTALLED_FROM="gh:$REPO tag:$REF" \
  exec bash "$INSTALL" "${install_args[@]}"
