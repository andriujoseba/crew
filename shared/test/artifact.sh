#!/usr/bin/env bash
# shared/test/artifact.sh — crew#98's distribution channels, exercised OFFLINE
# against the tree under test. The scp-able artifact (dist/make-installer.sh):
# checksum-verified BEFORE unpack, a damaged copy refuses without touching
# $DEST, a successful install leaves no temp dir behind (the entrypoint runs as
# a child, not `exec`, so the stub's EXIT trap fires), artifact and
# CREW_INSTALL_SOURCE install byte-identical trees (bar the source-naming
# INSTALLED_FROM stamp, pinned on both sides), --version/--check identify a file
# without installing it, and the
# builder is generic (a differently-named tree builds and installs, with no
# 'crew' string in its stub). Then the gh-authenticated channel (dist/fetch.sh)
# against a stub `gh`. No network, no real gh, no root.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"            # repo root: the crew tree to pack
MK="$ROOT/dist/make-installer.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }
same_done_source() { # <case-name> <installer-output> <version-dir>
  source_stamp="$(cat "$3/INSTALLED_FROM" 2>/dev/null)"
  same "$1" "crew-install: done ($source_stamp, version $(cat "$3/VERSION" 2>/dev/null)) — try: crew help" \
    "$(printf '%s\n' "$2" | tail -n 1)"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CREW_YES=1 HOME="$WORK"

V=0.0.0-artifact
# A scratch crew tree with VERSION rewritten to a stable, recognizable value.
SRC="$WORK/src"; mkdir -p "$SRC"
tar -C "$ROOT" --exclude=.git -cf - . | tar -xf - -C "$SRC"
printf '%s\n' "$V" > "$SRC/VERSION"

ART="$WORK/crew-$V.sh"
if bash "$MK" --name crew --version "$V" --root "$SRC" --out "$ART" >/dev/null 2>&1 && [ -x "$ART" ]; then
  ok "build-artifact"
else
  bad "build-artifact"; echo; echo "artifact: passed $PASS, failed $FAIL"; exit 1
fi

# 1. --version identifies the file WITHOUT installing (no $DEST created).
DEST1="$WORK/d1"
vout="$(CREW_HOME="$DEST1/share" CREW_BIN="$DEST1/bin" bash "$ART" --version 2>&1)"
case "$vout" in *"crew $V"*"payload sha256:"*) ok "version-identifies-without-install" ;;
  *) bad "version-identifies-without-install (got '$vout')" ;; esac
if [ ! -e "$DEST1" ]; then ok "version-touches-no-dest"; else bad "version-touches-no-dest"; fi

# 2. --check verifies the intact payload.
if CREW_HOME="$DEST1/share" CREW_BIN="$DEST1/bin" bash "$ART" --check >/dev/null 2>&1; then
  ok "check-passes-on-intact"
else
  bad "check-passes-on-intact"
fi

# 3. install from the artifact → versioned layout, crew runs through current.
DA="$WORK/homeA"
artifact_out="$(HOME="$DA" CREW_HOME="$DA/share" CREW_BIN="$DA/bin" bash "$ART" 2>&1)"
link="$(readlink -f "$DA/bin/crew" 2>/dev/null || true)"
case "$link" in */versions/"$V"/cli/crew) ok "artifact-installs-versioned-layout" ;;
  *) bad "artifact-installs-versioned-layout (got '$link')" ;; esac
if ( cd "$WORK" && "$DA/bin/crew" help >/dev/null 2>&1 ); then
  ok "artifact-installed-crew-runs"
else
  bad "artifact-installed-crew-runs"
fi

# 3b. the success path cleans its temp dir. `exec`-ing the entrypoint would drop
#     the stub's `trap … EXIT` and orphan the unpacked tree under $tmp; a child
#     call lets the trap fire. Point TMPDIR at an empty sandbox so both the
#     stub's and install.sh's mktemp land there, and assert no dir survives a
#     clean install (grok + codex, round 1).
SB="$WORK/tmpbox"; mkdir -p "$SB"
DLA="$WORK/homeLeakA"
TMPDIR="$SB" HOME="$DLA" CREW_HOME="$DLA/share" CREW_BIN="$DLA/bin" bash "$ART" >/dev/null 2>&1
leftA="$(find "$SB" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)"
if [ -d "$DLA/share/versions/$V" ] && [ -z "$leftA" ]; then
  ok "artifact-success-cleans-temp-dir"
else
  bad "artifact-success-cleans-temp-dir (installed=$([ -d "$DLA/share/versions/$V" ] && echo y || echo n) leftovers='$leftA')"
fi

# 3c. THE PAYLOAD, INHERITED (#365) — asserted per channel rather than assumed
#     from test 4's tree comparison, which would go on passing if both channels
#     regressed together. Every channel here ends in install.sh, and install.sh
#     acquires its tree two ways: the artifact and `dist/curl-install.sh` (test
#     11) each unpack and hand over a DIRECTORY, while `dist/fetch.sh` (test
#     10) hands over the TARBALL `gh` streamed — the branch that shipped the
#     whole repository until round 1 of #365. So the same three assertions run
#     at each channel's installed tree, whichever branch it lands on, and the
#     helper is shared so a fourth channel is one line.
#
#     The artifact FILE stays the size of the repository, deliberately: it
#     packs the whole tree and reimplements no install logic, so the payload
#     rule applies on the way OUT of the stub, not on the way in.
assert_payload() {  # <case-prefix> <installed tree, symlink or version dir>
  local prefix="$1" tree="$2" p shipped="" absent="" kb
  for p in .git .gitignore .github .box .ceremony AGENTS.md CONTRIBUTING.md changelog.d \
           dist drill drills postmortems protocols shared/test \
           fleet-floor/dev fleet-floor/src fleet-floor/build.sh fleet-floor/test; do
    [ -e "$tree/$p" ] && shipped="$shipped $p"
  done
  if [ -z "$shipped" ]; then
    ok "$prefix-excludes-repository-furniture"
  else
    bad "$prefix-excludes-repository-furniture (still shipped:$shipped)"
  fi
  # `shared/bin` by its FILES, not as a directory: it is the engine `crew
  # upgrade` pushes to every box, and an --exclude=./shared/bin would otherwise
  # pass every assertion here (claude-bot, round 1).
  for p in cli/crew VERSION install.sh examples/fleet.roster shared/lib/common.sh \
           shared/bin/engine-manifest.sh shared/bin/tick.sh shared/bin/duty.sh \
           fleet-floor/index.html fleet-floor/server/floor.py; do
    [ -e "$tree/$p" ] || absent="$absent $p"
  done
  if [ -z "$absent" ]; then
    ok "$prefix-keeps-what-the-tree-runs"
  else
    bad "$prefix-keeps-what-the-tree-runs (missing:$absent)"
  fi
  # -L, so a `current` symlink is measured as the tree it resolves to: a bare
  # `du -sk` there reports the link and passes on any size (#365).
  kb="$(du -skL "$tree" | cut -f1)"
  if [ "$kb" -lt 3072 ]; then
    ok "$prefix-under-3M ($kb KiB)"
  else
    bad "$prefix-under-3M (installed tree is $kb KiB)"
  fi
}
assert_payload artifact-install "$DA/share/current"

# 4. byte-identical (bar provenance) to a CREW_INSTALL_SOURCE install of the
#    same tree; provenance names the artifact, not a dead temp path.
DB="$WORK/homeB"
HOME="$DB" CREW_HOME="$DB/share" CREW_BIN="$DB/bin" CREW_INSTALL_SOURCE="$SRC" bash "$ROOT/install.sh" >/dev/null 2>&1
if diff -r --exclude=INSTALLED_FROM "$DA/share/versions/$V" "$DB/share/versions/$V" >/dev/null 2>&1; then
  ok "artifact-and-source-trees-identical"
else
  bad "artifact-and-source-trees-identical"; diff -rq --exclude=INSTALLED_FROM "$DA/share/versions/$V" "$DB/share/versions/$V" | head
fi
# Pin BOTH sides of the one excluded file, so the exclusion characterizes the
# difference rather than hiding it: the artifact names ITSELF (a dead temp path
# would be useless provenance), the source install names its source path. This
# is the #95-established INSTALLED_FROM contract — provenance is source-dependent
# by construction, which is why the trees above compare bar this file.
case "$(cat "$DA/share/versions/$V/INSTALLED_FROM" 2>/dev/null)" in
  "artifact:crew-$V.sh sha256:"*) ok "artifact-records-itself-as-provenance" ;;
  *) bad "artifact-records-itself-as-provenance (got '$(cat "$DA/share/versions/$V/INSTALLED_FROM" 2>/dev/null)')" ;;
esac
same "source-install-records-its-source-path" "local:$SRC" \
  "$(cat "$DB/share/versions/$V/INSTALLED_FROM" 2>/dev/null)"
same_done_source "artifact-done-source-matches-record" "$artifact_out" "$DA/share/versions/$V"

# 5. re-running the artifact on the already-installed version is a no-op.
before="$(readlink "$DA/share/current")"
rerun="$(HOME="$DA" CREW_HOME="$DA/share" CREW_BIN="$DA/bin" bash "$ART" 2>&1)"
same "artifact-rerun-is-noop-current" "$before" "$(readlink "$DA/share/current")"
case "$rerun" in *"already installed"*) ok "artifact-rerun-says-noop" ;; *) bad "artifact-rerun-says-noop (got '$rerun')" ;; esac

# 6. THE MUST-FAIL CASE (#98 test plan): a truncated artifact must refuse at the
#    checksum, BEFORE anything is unpacked or written — $DEST untouched. A stub
#    that unpacked before verifying would pass every happy-path test and only
#    fail here. Truncate in the PAYLOAD region (the stub logic intact) — that is
#    the damage the integrity check exists to catch, at several offsets: payload
#    entirely gone, mid-payload, and the last byte missing.
size="$(wc -c < "$ART" | tr -d ' ')"
mline="$(grep -aFxn -m1 -- '__SELF_INSTALLER_PAYLOAD__' "$ART" | cut -d: -f1)"
pstart="$(head -n "$mline" "$ART" | wc -c | tr -d ' ')"
refused_clean=1
for cut in "$pstart" $(( pstart + (size - pstart) / 2 )) $((size - 1)); do
  T="$WORK/trunc-$cut.sh"; head -c "$cut" "$ART" > "$T"; chmod +x "$T"
  DT="$WORK/dt-$cut"
  out="$(HOME="$DT" CREW_HOME="$DT/share" CREW_BIN="$DT/bin" bash "$T" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] || { bad "truncated-$cut-refuses (exit 0)"; refused_clean=0; continue; }
  case "$out" in *[Rr]e-copy*|*damaged*|*missing*) : ;; *) bad "truncated-$cut-message (got '$out')"; refused_clean=0 ;; esac
  if [ -e "$DT/share/versions" ]; then bad "truncated-$cut-touched-dest"; refused_clean=0; fi
done
[ "$refused_clean" -eq 1 ] && ok "truncated-artifacts-refuse-before-touching-dest"

# 7. a one-byte corruption in the payload is caught by the checksum.
CORR="$WORK/corrupt.sh"; cp "$ART" "$CORR"
# flip the final byte (deep in the payload, well past the marker/header)
flip_off=$((size - 1))
printf '\xff' | dd of="$CORR" bs=1 seek="$flip_off" count=1 conv=notrunc 2>/dev/null
DC="$WORK/dc"
if HOME="$DC" CREW_HOME="$DC/share" CREW_BIN="$DC/bin" bash "$CORR" >/dev/null 2>&1; then
  bad "one-byte-corruption-caught (installed anyway)"
else
  if [ ! -e "$DC/share/versions" ]; then ok "one-byte-corruption-caught"; else bad "one-byte-corruption-caught (touched dest)"; fi
fi

# 8. base64 mode also verifies and installs (the text-channel build flag).
ART64="$WORK/crew-$V.b64.sh"
bash "$MK" --name crew --version "$V" --root "$SRC" --out "$ART64" --base64 >/dev/null 2>&1
D64="$WORK/home64"
if HOME="$D64" CREW_HOME="$D64/share" CREW_BIN="$D64/bin" bash "$ART64" >/dev/null 2>&1 \
   && [ -d "$D64/share/versions/$V" ]; then
  ok "base64-artifact-installs"
else
  bad "base64-artifact-installs"
fi
# both encodings advertise the SAME payload checksum (same tree, same tarball).
sha_raw="$(bash "$ART"   --version 2>/dev/null | awk '/payload sha256:/{print $3}')"
sha_b64="$(bash "$ART64" --version 2>/dev/null | awk '/payload sha256:/{print $3}')"
same "raw-and-base64-same-checksum" "$sha_raw" "$sha_b64"

# 9. GENERIC/PROMOTABLE: build an artifact for a differently-named throwaway tree
#    with its own installer, and assert it installs it — nothing crew-specific in
#    the builder. The generated stub must carry no 'crew' string either.
WT="$WORK/widget-tree"; mkdir -p "$WT"
printf '1.2.3\n' > "$WT/VERSION"
cat > "$WT/install.sh" <<'WI'
#!/usr/bin/env bash
set -euo pipefail
: "${WIDGET_INSTALL_SOURCE:?}"
printf 'widget from %s\n' "$WIDGET_INSTALL_SOURCE" > "$WIDGET_OUT"
printf 'provenance %s\n' "${WIDGET_INSTALLED_FROM:-<none>}" >> "$WIDGET_OUT"
WI
chmod +x "$WT/install.sh"
WART="$WORK/widget-1.2.3.sh"
bash "$MK" --name widget --version 1.2.3 --root "$WT" --out "$WART" >/dev/null 2>&1
WOUT="$WORK/widget.out"
if WIDGET_OUT="$WOUT" bash "$WART" >/dev/null 2>&1 && grep -q '^widget from ' "$WOUT"; then
  ok "generic-builder-installs-throwaway-tree"
else
  bad "generic-builder-installs-throwaway-tree"
fi
case "$(sed -n '2p' "$WOUT" 2>/dev/null)" in
  "provenance artifact:widget-1.2.3.sh sha256:"*) ok "generic-provenance-var-derived-from-name" ;;
  *) bad "generic-provenance-var-derived-from-name (got '$(sed -n '2p' "$WOUT" 2>/dev/null)')" ;;
esac
# the stub half (above the marker) of a non-crew artifact carries no 'crew'.
if sed '/^__SELF_INSTALLER_PAYLOAD__$/q' "$WART" | grep -qi crew; then
  bad "widget-stub-has-no-crew-string"
else
  ok "widget-stub-has-no-crew-string"
fi

# 10. THE gh-AUTHENTICATED CHANNEL (dist/fetch.sh): against a stub `gh` that
#     resolves a tag and streams a source tarball (top dir owner-repo-<sha>/),
#     fetch.sh installs through install.sh and records the ref as provenance. No
#     anonymous URL is ever touched — the stub only answers gh api calls.
GHP="$WORK/ghsrc"; mkdir -p "$GHP/crew-ghsha"
cp -a "$SRC/." "$GHP/crew-ghsha/"
GHBIN="$WORK/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *releases/latest*) echo "0.0.0-ghtag" ;;
  *tarball/*)        tar -C "$GH_SRC_PARENT" -czf - "$GH_TOPDIR" ;;
  *) echo "gh-stub: unexpected call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$GHBIN/gh"
DG="$WORK/homeG"
SBG="$WORK/tmpboxG"; mkdir -p "$SBG"
if gh_out="$(GH_SRC_PARENT="$GHP" GH_TOPDIR="crew-ghsha" PATH="$GHBIN:$PATH" TMPDIR="$SBG" \
     HOME="$DG" CREW_HOME="$DG/share" CREW_BIN="$DG/bin" \
     bash "$ROOT/dist/fetch.sh" --repo test/crew --ref latest -- 2>&1)" \
   && [ -d "$DG/share/versions/$V" ]; then
  ok "gh-channel-installs-through-install-sh"
else
  bad "gh-channel-installs-through-install-sh"
fi
same "gh-channel-records-ref-provenance" "gh:test/crew tag:0.0.0-ghtag" \
  "$(cat "$DG/share/versions/$V/INSTALLED_FROM" 2>/dev/null)"
same_done_source "gh-channel-done-source-matches-record" "$gh_out" "$DG/share/versions/$V"
# THE TARBALL BRANCH (#365, round 1). fetch.sh hands install.sh a FILE, and
# that branch carried no payload rule until this round: this channel installed
# 52M — every path the list names — where the artifact installed 1.2M. Asserted
# here, one block below the install this channel already does, because a
# minimisation that holds on one branch of install.sh and not the other is not
# a property of the product.
assert_payload gh-channel-payload "$DG/share/versions/$V"
# fetch.sh downloaded the tarball into its own temp dir; `exec`-ing install.sh
# would drop its `trap … EXIT` and orphan that tarball. Assert the sandbox is
# empty after a clean fetch-install (round 1).
leftG="$(find "$SBG" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)"
if [ -z "$leftG" ]; then ok "gh-channel-success-cleans-temp-dir"; else bad "gh-channel-success-cleans-temp-dir (leftovers='$leftG')"; fi

# 11. THE ANONYMOUS curl CHANNEL (dist/curl-install.sh, crew#171): against a stub
#     `curl` that answers exactly two requests from canned state — the
#     /releases/latest HEAD (a redirect string, as `-w '%{redirect_url}'` would
#     print it) and the codeload tarball GET — and REFUSES everything else, so a
#     test that reaches for the network fails loudly instead of quietly working.
#     No API, no token, no network, and no tty is assumed.
CURLSH="$ROOT/dist/curl-install.sh"
CTAG=0.0.0-curltag
VDEV=0.0.0-dev
# The two trees a caller can ask for, packed the way GitHub's archive endpoint
# packs them: one top-level directory, named for the ref.
TARS="$WORK/tars"; mkdir -p "$TARS"
CPK="$WORK/curlpack"; mkdir -p "$CPK/crew-$CTAG" "$CPK/crew-main"
cp -a "$SRC/." "$CPK/crew-$CTAG/"
cp -a "$SRC/." "$CPK/crew-main/"
printf '%s\n' "$VDEV" > "$CPK/crew-main/VERSION"     # the tip carries a -dev VERSION
tar -C "$CPK" -czf "$TARS/$CTAG.tar.gz" "crew-$CTAG"
tar -C "$CPK" -czf "$TARS/main.tar.gz"  "crew-main"

CURLBIN="$WORK/curlbin"; mkdir -p "$CURLBIN"
cat > "$CURLBIN/curl" <<'CURLSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
out=""; url=""; argv=("$@"); i=0
while [ "$i" -lt "${#argv[@]}" ]; do
  case "${argv[$i]}" in
    -o)    i=$((i+1)); out="${argv[$i]}" ;;
    http*) url="${argv[$i]}" ;;
  esac
  i=$((i+1))
done
case "$url" in
  # -I -w '%{redirect_url}': the redirect target on stdout, no body.
  */releases/latest) printf '%s' "${STUB_REDIRECT:-}" ;;
  https://codeload.github.com/*/tar.gz/*)
    ref="${url##*/tar.gz/}"
    [ -f "$STUB_TARS/$ref.tar.gz" ] || { printf 'stub-curl: 404 %s\n' "$url" >&2; exit 22; }
    cat "$STUB_TARS/$ref.tar.gz" > "$out" ;;
  *) printf 'stub-curl: REFUSED unexpected url: %s\n' "$url" >&2; exit 22 ;;
esac
CURLSTUB
chmod +x "$CURLBIN/curl"

# One runner for every case below: a fresh $HOME, a fresh curl log, the stub
# first on PATH. Sets CURL_RC / CURL_OUT / CURL_HOME / CURL_LOG for the caller.
run_curl_channel() {  # <case-name> [VAR=VAL ...]
  CURL_HOME="$WORK/curl-$1"; CURL_LOG="$WORK/curl-$1.log"; shift
  : > "$CURL_LOG"
  CURL_OUT="$(env -u CREW_REF -u CREW_INSTALL_SOURCE \
    "$@" PATH="$CURLBIN:$PATH" CURL_LOG="$CURL_LOG" STUB_TARS="$TARS" \
    HOME="$CURL_HOME" CREW_HOME="$CURL_HOME/share" CREW_BIN="$CURL_HOME/bin" \
    bash "$CURLSH" 2>&1)" && CURL_RC=0 || CURL_RC=$?
}
installed_version() { readlink "$1/share/current" 2>/dev/null | sed 's|^versions/||'; }

REDIR_TAG="https://github.com/heavy-duty/crew/releases/tag/$CTAG"
REDIR_NONE="https://github.com/heavy-duty/crew/releases"

# 11a. the default: resolve the latest release off the redirect and install it.
run_curl_channel latest CREW_YES=1 STUB_REDIRECT="$REDIR_TAG"
same "curl-channel-installs-latest-release" "$V" "$(installed_version "$CURL_HOME")"
# ...and the installed crew ANSWERS, through the PATH link — the offline half of
# #171's "installs the latest release and `crew --version` answers". The other
# half (the real one-liner on a clean machine) needs this file on `main` and a
# tagged release, and belongs to the drill.
case "$( cd "$WORK" && "$CURL_HOME/bin/crew" --version 2>&1 )" in
  "crew $V ("*) ok "curl-installed-crew-answers-version" ;;
  *) bad "curl-installed-crew-answers-version (got '$( cd "$WORK" && "$CURL_HOME/bin/crew" --version 2>&1 )')" ;;
esac
# The anonymous channel was never the defect — it extracts the archive itself
# and hands install.sh the resulting TREE (`curl-channel-hands-tree-to-install-sh`
# above), so it took the directory branch and was minimised from the start.
# Asserted anyway, and pinned here rather than left implied: it is the channel
# a machine with no `gh` and no scp'd artifact reaches for, and the thing that
# makes it safe — which branch it happens to hand to — is one line in
# curl-install.sh away from changing.
assert_payload curl-channel-payload "$CURL_HOME/share/current"
same "curl-channel-records-resolved-tag-provenance" "curl:heavy-duty/crew ref:$CTAG" \
  "$(cat "$CURL_HOME/share/versions/$V/INSTALLED_FROM" 2>/dev/null)"
same_done_source "curl-channel-done-source-matches-record" "$CURL_OUT" "$CURL_HOME/share/versions/$V"
# The resolution is GitHub's own redirect, taken with a HEAD — never the API,
# never a token. Both halves matter: the API needs auth this channel must not have.
case "$(cat "$CURL_LOG")" in
  *"-fsSI"*"https://github.com/heavy-duty/crew/releases/latest"*) ok "curl-channel-resolves-by-head-redirect" ;;
  *) bad "curl-channel-resolves-by-head-redirect (log: $(tr '\n' '|' < "$CURL_LOG"))" ;;
esac
if grep -q 'api\.github\.com\|Authorization\|GITHUB_TOKEN' "$CURL_LOG"; then
  bad "curl-channel-uses-no-api-and-no-token"
else
  ok "curl-channel-uses-no-api-and-no-token"
fi
# It fetches, install.sh installs: the download is handed over as a local tree.
case "$CURL_OUT" in *"copying local tree"*) ok "curl-channel-hands-tree-to-install-sh" ;;
  *) bad "curl-channel-hands-tree-to-install-sh (got '$CURL_OUT')" ;; esac

# 11b. CREW_REF pins a tag — and does NOT resolve anything, so a pinned install
#      is one request and cannot be moved by whatever 'latest' points at today.
run_curl_channel pin CREW_YES=1 CREW_REF="$CTAG" STUB_REDIRECT="$REDIR_NONE"
same "curl-channel-pinned-tag-installs" "$V" "$(installed_version "$CURL_HOME")"
same "curl-channel-pinned-tag-provenance" "curl:heavy-duty/crew ref:$CTAG" \
  "$(cat "$CURL_HOME/share/versions/$V/INSTALLED_FROM" 2>/dev/null)"
if grep -q 'releases/latest' "$CURL_LOG"; then
  bad "curl-channel-pinned-tag-skips-resolution"
else
  ok "curl-channel-pinned-tag-skips-resolution"
fi

# 11c. CREW_REF=main takes the tip, and the tree it installs is identifiable as
#      a dev tree — the version dir IS the tip's -dev VERSION, and provenance
#      names the branch rather than a tag.
run_curl_channel main CREW_YES=1 CREW_REF=main STUB_REDIRECT="$REDIR_NONE"
same "curl-channel-main-installs-tip" "$VDEV" "$(installed_version "$CURL_HOME")"
same "curl-channel-main-provenance-names-branch" "curl:heavy-duty/crew ref:main" \
  "$(cat "$CURL_HOME/share/versions/$VDEV/INSTALLED_FROM" 2>/dev/null)"
case "$(installed_version "$CURL_HOME")" in *-dev) ok "curl-channel-main-is-identifiably-a-dev-tree" ;;
  *) bad "curl-channel-main-is-identifiably-a-dev-tree" ;; esac

# 11d. THE MUST-FAIL CASE (#171 test plan): with no release published, GitHub
#      sends /releases/latest to the releases index. Falling back to the tip here
#      would hand two operators different trees from the same command, silently.
#      It must REFUSE, say why, install nothing — and never even reach for a
#      tarball.
run_curl_channel norelease CREW_YES=1 STUB_REDIRECT="$REDIR_NONE"
if [ "$CURL_RC" -ne 0 ]; then ok "no-release-refuses-nonzero"; else bad "no-release-refuses-nonzero (exit 0)"; fi
case "$CURL_OUT" in *"no published release"*) ok "no-release-says-why" ;;
  *) bad "no-release-says-why (got '$CURL_OUT')" ;; esac
same "no-release-installs-nothing" "" "$(installed_version "$CURL_HOME")"
if grep -q 'codeload' "$CURL_LOG"; then
  bad "no-release-downloads-nothing"
else
  ok "no-release-downloads-nothing"
fi
# The same refusal for a redirect that resolves to nothing at all.
run_curl_channel noredirect CREW_YES=1 STUB_REDIRECT=""
if [ "$CURL_RC" -ne 0 ] && [ -z "$(installed_version "$CURL_HOME")" ]; then
  ok "unresolvable-redirect-refuses"
else
  bad "unresolvable-redirect-refuses (rc=$CURL_RC)"
fi

# 11e. THE OTHER MUST-FAIL: the prompt must read /dev/tty, never stdin. Under
#      `curl … | bash` the script IS stdin, so a bare `read` eats the rest of the
#      script — and passes every other way it is tested. Two assertions, because
#      neither alone is decisive:
#      structurally, no `read` in the file is left on stdin...
curl_reads="$(grep -n '^[^#]*\bread\b' "$CURLSH" | grep -v '</dev/tty' || true)"
same "curl-channel-no-read-off-stdin" "" "$curl_reads"
#      ...and behaviourally, with NO terminal and a canned "y" waiting on stdin.
#      A stdin-reading prompt consumes that "y" and installs; a /dev/tty prompt
#      has nobody to ask and must refuse. setsid detaches the controlling
#      terminal so the case is the same on a workstation as in CI.
NOTTY="$WORK/curl-notty"; NOTTY_LOG="$WORK/curl-notty.log"; : > "$NOTTY_LOG"
notty_runner=(); command -v setsid >/dev/null 2>&1 && notty_runner=(setsid)
notty_out="$(printf 'y\n' | env -u CREW_YES -u CREW_REF -u CREW_INSTALL_SOURCE \
  PATH="$CURLBIN:$PATH" CURL_LOG="$NOTTY_LOG" STUB_TARS="$TARS" STUB_REDIRECT="$REDIR_TAG" \
  HOME="$NOTTY" CREW_HOME="$NOTTY/share" CREW_BIN="$NOTTY/bin" \
  "${notty_runner[@]}" bash "$CURLSH" 2>&1)" && notty_rc=0 || notty_rc=$?
if [ "$notty_rc" -ne 0 ]; then ok "no-tty-prompt-refuses"; else bad "no-tty-prompt-refuses (exit 0 — it read the answer off stdin)"; fi
case "$notty_out" in *"no terminal to confirm on"*) ok "no-tty-prompt-says-why" ;;
  *) bad "no-tty-prompt-says-why (got '$notty_out')" ;; esac
same "no-tty-prompt-installs-nothing" "" "$(installed_version "$NOTTY")"
if grep -q 'codeload' "$NOTTY_LOG"; then bad "no-tty-prompt-downloads-nothing"; else ok "no-tty-prompt-downloads-nothing"; fi

# 11f. ...and the positive half the two above cannot show: a human ANSWERING the
#      prompt under a real piped invocation. script(1) gives the session a pty,
#      so /dev/tty exists and carries the answer while the script itself arrives
#      on stdin through a pipe — the exact shape of `curl … | bash`.
run_piped_answer() {  # <case-name> <answer>
  PIPE_HOME="$WORK/curl-pipe-$1"; PIPE_LOG="$WORK/curl-pipe-$1.log"; : > "$PIPE_LOG"
  # `sleep 1` keeps the pty's input side open past the answer: script(1) tears
  # the session down at EOF on its own stdin, which would race the install.
  PIPE_OUT="$( { printf '%s\n' "$2"; sleep 1; } | env -u CREW_YES -u CREW_REF -u CREW_INSTALL_SOURCE \
    PATH="$CURLBIN:$PATH" CURL_LOG="$PIPE_LOG" STUB_TARS="$TARS" STUB_REDIRECT="$REDIR_TAG" \
    HOME="$PIPE_HOME" CREW_HOME="$PIPE_HOME/share" CREW_BIN="$PIPE_HOME/bin" \
    script -qec "cat '$CURLSH' | bash -s" /dev/null 2>&1 )" && PIPE_RC=0 || PIPE_RC=$?
}
if command -v script >/dev/null 2>&1; then
  run_piped_answer yes y
  same "piped-prompt-answered-yes-installs" "$V" "$(installed_version "$PIPE_HOME")"
  run_piped_answer no n
  if [ "$PIPE_RC" -ne 0 ] && [ -z "$(installed_version "$PIPE_HOME")" ]; then
    ok "piped-prompt-answered-no-cancels"
  else
    bad "piped-prompt-answered-no-cancels (rc=$PIPE_RC out='$PIPE_OUT')"
  fi
  case "$PIPE_OUT" in *cancelled*"nothing was downloaded"*) ok "piped-prompt-answered-no-says-so" ;;
    *) bad "piped-prompt-answered-no-says-so (got '$PIPE_OUT')" ;; esac
elif [ -n "${CI:-}" ]; then
  bad "piped-prompt-needs-script(1) — install util-linux; a skip here reads like a pass"
else
  printf 'SKIP piped-prompt (no script(1); CI runs it — install util-linux to run it here)\n'
fi

# 11g. CREW_INSTALL_SOURCE still wins, and short-circuits the network ENTIRELY:
#      no resolution, no download, not one request. The empty curl log is the
#      assertion — this channel only ever adds a way to GET a tree.
run_curl_channel local CREW_YES=1 CREW_INSTALL_SOURCE="$SRC"
same "curl-channel-local-source-installs" "$V" "$(installed_version "$CURL_HOME")"
same "curl-channel-local-source-provenance" "local:$SRC" \
  "$(cat "$CURL_HOME/share/versions/$V/INSTALLED_FROM" 2>/dev/null)"
same_done_source "local-done-source-matches-record" "$CURL_OUT" "$CURL_HOME/share/versions/$V"
same "curl-channel-local-source-touches-no-network" "" "$(cat "$CURL_LOG")"

# 11h. the download lands in the channel's own temp dir; `exec`-ing install.sh
#      would drop its `trap … EXIT` and orphan it (the lesson dist/fetch.sh
#      already carries). Same sandbox assertion as 3b and 10.
SBC="$WORK/tmpboxC"; mkdir -p "$SBC"
run_curl_channel leak CREW_YES=1 TMPDIR="$SBC" STUB_REDIRECT="$REDIR_TAG"
leftC="$(find "$SBC" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)"
if [ -n "$(installed_version "$CURL_HOME")" ] && [ -z "$leftC" ]; then
  ok "curl-channel-success-cleans-temp-dir"
else
  bad "curl-channel-success-cleans-temp-dir (leftovers='$leftC')"
fi

# 11i. install.sh is not this channel's business: the script never writes to it,
#      and the gh channel's own installer path is untouched by construction.
if grep -qE '>[[:space:]]*"?\$?\{?[A-Za-z_]*[Ii]nstall\.sh' "$CURLSH"; then
  bad "curl-channel-never-writes-install-sh"
else
  ok "curl-channel-never-writes-install-sh"
fi

# 12. THE RELEASE HOOK'S OWN CONTRACT (#210) — what a release actually
#     publishes, exercised offline. The hook ceremony invokes at both doors is a
#     thin wrapper over `dist/release-artifact.sh`, so the script the release
#     runs is the script this file drives: the deleted `artifact` job re-typed
#     its own build, and nothing here could see that it was unreachable while
#     two releases shipped no asset at all. The contract (ceremony
#     docs/CONSUMERS.md): every file left in $RELEASE_ASSETS_DIR is uploaded,
#     and a non-zero exit aborts the release.
RA="$ROOT/dist/release-artifact.sh"
ADIR="$WORK/assets"
# --assets-dir with RELEASE_ASSETS_DIR deliberately unset: the flag is the
# offline driver, the env var is the hook's, and neither may depend on the other.
if ra_out="$(env -u RELEASE_ASSETS_DIR bash "$RA" --version "$V" --root "$SRC" --assets-dir "$ADIR" 2>&1)"; then
  ok "release-hook-builds"
else
  bad "release-hook-builds (got '$ra_out')"
fi
if [ -s "$ADIR/crew-$V.sh" ] && [ -s "$ADIR/crew-$V.sh.sha256" ]; then
  ok "release-hook-writes-artifact-and-sidecar"
else
  bad "release-hook-writes-artifact-and-sidecar (dir holds: $(ls "$ADIR" 2>/dev/null | tr '\n' ' '))"
fi
# Only those two: every file in that directory becomes a release asset, so a
# stray temp file here is a published one.
same "release-hook-leaves-no-other-assets" "crew-$V.sh crew-$V.sh.sha256" \
  "$(ls "$ADIR" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
# The sidecar names the asset ALONE — a path in it makes `sha256sum -c` fail for
# every downloader, who has the file and not the runner's directory layout.
same "release-hook-sidecar-names-the-asset-alone" "crew-$V.sh" \
  "$(awk '{print $2}' "$ADIR/crew-$V.sh.sha256" 2>/dev/null)"
if ( cd "$ADIR" && sha256sum -c "crew-$V.sh.sha256" >/dev/null 2>&1 ); then
  ok "release-hook-sidecar-verifies-the-published-file"
else
  bad "release-hook-sidecar-verifies-the-published-file"
fi
# The asset a release would publish is a working one: its own integrity check
# passes, and it identifies itself as the version that was cut.
if bash "$ADIR/crew-$V.sh" --check >/dev/null 2>&1; then
  ok "release-hook-artifact-passes-its-own-check"
else
  bad "release-hook-artifact-passes-its-own-check"
fi
case "$(bash "$ADIR/crew-$V.sh" --version 2>&1)" in *"crew $V"*) ok "release-hook-artifact-names-the-release" ;;
  *) bad "release-hook-artifact-names-the-release (got '$(bash "$ADIR/crew-$V.sh" --version 2>&1)')" ;; esac

# 12a. RELEASE_ASSETS_DIR alone, no flag — the hook passes no --assets-dir, so
#      this is the path the release itself takes.
ADIR2="$WORK/assets-env"
if RELEASE_ASSETS_DIR="$ADIR2" bash "$RA" --version "$V" --root "$SRC" >/dev/null 2>&1 \
   && [ -s "$ADIR2/crew-$V.sh" ] && [ -s "$ADIR2/crew-$V.sh.sha256" ]; then
  ok "release-hook-honours-RELEASE_ASSETS_DIR"
else
  bad "release-hook-honours-RELEASE_ASSETS_DIR"
fi

# 12b. THE MUST-FAIL CASES. Non-zero aborts the release with the tag created and
#      nothing published — sharp on purpose, and the point of the whole change:
#      a release whose primary install channel is missing should not exist. The
#      old job could only fail silently.
#      (i) a build that succeeds but produces an EMPTY artifact. Driven through a
#      scratch dist/ whose make-installer.sh is a stub, because the production
#      script takes no injection point: it resolves its builder beside itself.
FD="$WORK/fakedist"; mkdir -p "$FD"
cp "$RA" "$FD/release-artifact.sh"
cat > "$FD/make-installer.sh" <<'MKSTUB'
#!/usr/bin/env bash
# stands in for a build that reports success and writes nothing usable
out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
: > "$out"
MKSTUB
EMPTYDIR="$WORK/assets-empty"
if env -u RELEASE_ASSETS_DIR bash "$FD/release-artifact.sh" --version "$V" --root "$SRC" \
     --assets-dir "$EMPTYDIR" >/dev/null 2>&1; then
  bad "empty-build-refuses-nonzero (exit 0 — it would publish an empty asset)"
else
  ok "empty-build-refuses-nonzero"
fi
if [ -e "$EMPTYDIR/crew-$V.sh.sha256" ]; then
  bad "empty-build-publishes-no-sidecar"
else
  ok "empty-build-publishes-no-sidecar"
fi
#      (ii) a build that fails outright — a --root that is not a crew tree.
NOTATREE="$WORK/not-a-tree"; mkdir -p "$NOTATREE"
if env -u RELEASE_ASSETS_DIR bash "$RA" --version "$V" --root "$NOTATREE" \
     --assets-dir "$WORK/assets-bad" >/dev/null 2>&1; then
  bad "failed-build-refuses-nonzero (exit 0)"
else
  ok "failed-build-refuses-nonzero"
fi
#      (iii) no assets directory at all. Silently building into the checkout
#      would publish nothing and say nothing — the failure this issue is about.
noassets_out="$(env -u RELEASE_ASSETS_DIR bash "$RA" --version "$V" --root "$SRC" 2>&1)" \
  && bad "no-assets-dir-refuses-nonzero (exit 0)" || ok "no-assets-dir-refuses-nonzero"
case "$noassets_out" in *RELEASE_ASSETS_DIR*) ok "no-assets-dir-says-why" ;;
  *) bad "no-assets-dir-says-why (got '$noassets_out')" ;; esac

# 12c. THE ANTI-DRIFT ASSERTION, which is why the build is a script at all: the
#      hook must CALL it and re-type no build of its own. A composite action
#      cannot be invoked from here, so its shape is what this file can hold —
#      and it is exactly the property whose absence let the old job rot.
HOOK="$ROOT/.github/actions/release-artifact/action.yml"
if [ -f "$HOOK" ]; then ok "release-hook-action-exists"; else bad "release-hook-action-exists"; fi
if grep -q 'using: composite' "$HOOK" 2>/dev/null && grep -q '^  version:' "$HOOK" 2>/dev/null; then
  ok "release-hook-action-is-composite-taking-version"
else
  bad "release-hook-action-is-composite-taking-version"
fi
if grep -q 'dist/release-artifact\.sh' "$HOOK" 2>/dev/null; then
  ok "release-hook-action-calls-the-script"
else
  bad "release-hook-action-calls-the-script"
fi
if grep -q 'make-installer\.sh' "$HOOK" 2>/dev/null; then
  bad "release-hook-action-retypes-no-build"
else
  ok "release-hook-action-retypes-no-build"
fi
# One publisher, not two: `gh release create` attaches the assets, and a second
# upload path is how a --clobber race gets invented (#210's spec point 2).
RELYML="$ROOT/.github/workflows/release.yml"
if grep -q 'gh release upload\|gh release edit' "$RELYML" 2>/dev/null; then
  bad "release-workflow-uploads-nothing-itself"
else
  ok "release-workflow-uploads-nothing-itself"
fi

echo
echo "artifact: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
