#!/usr/bin/env bash
set -euo pipefail
# dist/release-artifact.sh — build one release's assets: the scp-able, offline
# installer `crew-<version>.sh` (README's primary channel) and its checksum
# sidecar `crew-<version>.sh.sha256`, dropped into the directory ceremony's
# release doors attach from (heavy-duty/crew#210).
#
# ONE build, TWO callers, on purpose: `.github/actions/release-artifact/`
# (the hook BOTH doors invoke — merge and tag) and `shared/test/artifact.sh`
# (offline, every CI run). A composite action cannot be invoked offline, so
# anything the hook re-typed for itself would be drift no test could catch —
# the bespoke `artifact` job this replaces was exactly that, and it published
# nothing for two releases. The hook is a thin wrapper over this file; the test
# drives this file.
#
# The checksum is a sidecar rather than a line appended to the release notes:
# the hook runs BEFORE `gh release create`, so there are no notes to append to,
# and rewriting the body afterwards raced the ceremony's own notes. `sha256sum
# -c crew-<version>.sh.sha256` consumes a sidecar directly.
#
# Failing here ABORTS the release, by contract (ceremony docs/CONSUMERS.md):
# the tag is created but nothing publishes. That is the intent — a release
# whose primary install channel is missing should not exist.

usage() {
  cat <<'USAGE'
release-artifact.sh — build a release's installer asset and its checksum sidecar
  --version VER      the release version, as the tag names it          [required]
  --root DIR         the tree to pack                   [default: this repo root]
  --assets-dir DIR   where the finished files land  [default: $RELEASE_ASSETS_DIR]
Writes <assets-dir>/crew-<VER>.sh and <assets-dir>/crew-<VER>.sh.sha256.
USAGE
}
say() { printf 'release-artifact: %s\n' "$*"; }
die() { printf 'release-artifact: ERROR: %s\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME=crew

version='' root='' assets=''
while [ $# -gt 0 ]; do
  case "$1" in
    --version)    version="${2:?--version needs a value}"; shift 2 ;;
    --root)       root="${2:?--root needs a value}"; shift 2 ;;
    --assets-dir) assets="${2:?--assets-dir needs a value}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$version" ] || die "--version is required"
[ -n "$root" ]    || root="$HERE/.."
[ -d "$root" ]    || die "--root '$root' is not a directory"
root="$(cd "$root" && pwd -P)"
# RELEASE_ASSETS_DIR is what ceremony exports to the hook; the flag is how the
# offline test drives the same code without inventing that environment.
[ -n "$assets" ]  || assets="${RELEASE_ASSETS_DIR:-}"
[ -n "$assets" ]  || die "no assets directory — pass --assets-dir, or set RELEASE_ASSETS_DIR (ceremony's hook exports it)."
mkdir -p "$assets" || die "could not create the assets directory '$assets'."
assets="$(cd "$assets" && pwd)"

art="$assets/$NAME-$version.sh"
sidecar="$art.sha256"

# WHAT GETS PACKED IS THE COMMITTED TREE, not the working directory. At release
# time the workspace holds more than crew: ceremony checks ITSELF out into
# `.ceremony-src` inside it, in the same job, before this hook runs. install.sh's
# payload exclusions name crew's own furniture and nothing a runner leaves
# beside it, so packing the directory as found would ship ceremony's repository
# inside crew's installer and install it on every box. `git archive HEAD` is
# exactly the tree the release commit names, on both doors. A --root that is not
# a git work tree — the offline test, a hand build from an unpacked tarball — is
# packed as it is, there being no commit to prefer.
pack="$root"
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$top" ] && top="$(cd "$top" && pwd -P)"
if [ "$top" = "$root" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  pack="$work/tree"
  mkdir -p "$pack"
  git -C "$root" archive --format=tar HEAD | tar -xf - -C "$pack" \
    || die "could not export the committed tree at HEAD from '$root'."
  say "packing the committed tree at $(git -C "$root" rev-parse --short HEAD), not the working directory"
fi

say "building $(basename "$art") from $root"
# A failed build is a stopped release, never an empty asset.
bash "$HERE/make-installer.sh" --name "$NAME" --version "$version" --root "$pack" --out "$art" \
  || die "the installer build failed — no asset is published rather than an empty one."
[ -s "$art" ] || die "the build left no usable artifact at '$art' — refusing to publish an empty asset."
# The stub verifies its own payload; make the release prove that here, where the
# recovery is 'fix and re-tag', rather than on the operator's target box.
bash "$art" --check >/dev/null 2>&1 \
  || die "the freshly built artifact fails its own --check — refusing to publish it."

# Written from inside the directory so the sidecar names the asset alone: a
# downloader runs `sha256sum -c crew-<version>.sh.sha256` beside the file.
( cd "$assets" && sha256sum "$NAME-$version.sh" > "$NAME-$version.sh.sha256" ) \
  || die "could not write the checksum sidecar."
[ -s "$sidecar" ] || die "the checksum sidecar '$sidecar' is empty."

say "wrote $(basename "$art") ($(wc -c < "$art" | tr -d ' ') bytes) and $(basename "$sidecar") in $assets"
