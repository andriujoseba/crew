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

# WHAT GETS PACKED IS AN INCLUDE SET (heavy-duty/crew#499), NOT A TREE MINUS
# EXCLUSIONS. The artifact used to carry everything the exclusion list did not
# name, and the exclusion list is install.sh's — written to decide what an
# INSTALL keeps, applied there on the way out of the stub. So the tarball was
# the whole repository and ~97% of every download was unpacked and thrown away:
# `fleet-floor/dev` alone, a design-time asset map read by nothing an install
# runs, is 50M of the tree's 55M.
#
# The two lists answer different questions and both stay. install.sh's asks
# "what must come OUT of a tree someone handed me", and it cannot become an
# include set: a checkout, a GitHub tarball and this artifact are all valid
# sources and only the last is built here. This one asks "what goes IN", which
# is the question with the safe failure mode — a directory added to the
# repository ships only when someone names it, where an exclusion list ships it
# until someone notices.
#
# The set is install.sh's keep list, enumerated. That is not a coincidence to be
# maintained by hand: shared/test/artifact.sh installs from this artifact and
# from the full tree and diffs the two trees, so a member dropped here, or a
# path this omits that an install turns out to need, reds there rather than on
# an operator's upgrade.
PAYLOAD_INCLUDED_PATHS=(
  VERSION                # names the version directory the install lands in
  README.md              # the installed tree's own documentation
  CHANGELOG.md           # what this version changed, on the box that runs it
  install.sh             # the entrypoint the stub hands the unpacked tree to
  cli                    # `cli/crew`, the command the PATH link points at
  examples               # cli/crew's configuration fallback
  shared/bin             # the engine `crew upgrade` pushes to every box
  shared/conf            # role, agent-profile and default configuration
  shared/crontab.example # the tick schedule an operator installs on a box
  shared/host-crontab.example # the maintenance schedule an operator installs on the HOST
  shared/docs            # the engine's own documentation, shipped beside it
  shared/install.sh      # the box-side installer `crew upgrade` runs
  shared/lib             # the engine's libraries
  shared/prompts         # the duty prompts the engine feeds each session
  shared/README.md       # the engine's entry documentation
  fleet-floor/index.html # the pre-built page `crew floor` serves
  fleet-floor/README.md  # the floor's own documentation
  fleet-floor/server     # the floor's collector and server
)

# WHAT IT IS TAKEN FROM IS THE COMMITTED TREE, not the working directory. At
# release time the workspace holds more than crew: ceremony checks ITSELF out
# into `.ceremony-src` inside it, in the same job, before this hook runs.
# `git archive HEAD` is exactly the tree the release commit names, on both
# doors. A --root that is not a git work tree — the offline test, a hand build
# from an unpacked tarball — is read as it is, there being no commit to prefer.
# The include set applies on BOTH branches: it is a property of the payload and
# not of how the payload's source was acquired, which is the mistake #365 made
# once already, filtering one acquisition branch and not the other.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pack="$work/tree"
mkdir -p "$pack"
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$top" ]; then top="$(cd "$top" && pwd -P)"; fi
if [ "$top" = "$root" ]; then
  git -C "$root" archive --format=tar HEAD -- "${PAYLOAD_INCLUDED_PATHS[@]}" | tar -xf - -C "$pack" \
    || die "could not export the include set at HEAD from '$root' — is every path in it committed?"
  say "packing the committed tree at $(git -C "$root" rev-parse --short HEAD), not the working directory"
else
  tar -C "$root" -cf - -- "${PAYLOAD_INCLUDED_PATHS[@]}" | tar -xf - -C "$pack" \
    || die "could not read the include set from '$root' — is it a crew tree?"
fi

# THE INCLUDE SET IS VALIDATED, not trusted, and in both directions. A missing
# member is a source that is not a crew tree, and a path outside the set is the
# regression this change exists to stop — either one aborts the release here,
# where the recovery is 'fix and re-tag', rather than on an operator's box.
for p in "${PAYLOAD_INCLUDED_PATHS[@]}"; do
  [ -e "$pack/$p" ] || die "the include set names '$p', which '$root' does not carry — refusing to publish a payload missing part of the product."
done
outside=''
while IFS= read -r f; do
  rel="${f#"$pack"/}"
  covered=''
  for p in "${PAYLOAD_INCLUDED_PATHS[@]}"; do
    case "$rel" in "$p"|"$p"/*) covered=1; break ;; esac
  done
  [ -n "$covered" ] || { outside="$rel"; break; }
done < <(find "$pack" -mindepth 1 \( -type f -o -type l \) -print)
[ -z "$outside" ] || die "the payload carries '$outside', which no include-set member covers — refusing to publish it."
unset p f rel covered

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

# THE SIZE IS ON THE RECORD (heavy-duty/crew#499 D4). An include set decays the
# way the exclusion list it replaces did — by someone adding a directory to it
# that nothing an install runs reads — and that decay is invisible in a
# checksum, invisible in the notes and invisible in a green check. So the figure
# is written where the cut is read, and it is written HERE rather than in either
# caller: the hook and the offline test drive one build, so a record only the
# hook emitted would be a record no test could see.
#
# stdout carries it unconditionally, that being the run log every door keeps.
# `$GITHUB_STEP_SUMMARY` carries it too when the runner offers one; the variable
# being set is the runner's promise that the file is writable, so a failed
# append is a broken promise and stops the release rather than losing the
# record it was the whole point of writing.
size_bytes="$(wc -c < "$art" | tr -d ' ')"
payload_files="$(find "$pack" -type f | wc -l | tr -d ' ')"
payload_kb="$(du -sk "$pack" | cut -f1)"
size_line="artifact size: $NAME-$version.sh is $size_bytes bytes; payload $payload_files files, $payload_kb KiB unpacked"
say "$size_line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "- \`$NAME-$version.sh\` — $size_bytes bytes; payload $payload_files files, $payload_kb KiB unpacked" \
    >> "$GITHUB_STEP_SUMMARY" \
    || die "could not record the artifact size in \$GITHUB_STEP_SUMMARY — the size is part of the release record, so it is not published without one."
fi
