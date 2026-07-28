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
HOME="$DA" CREW_HOME="$DA/share" CREW_BIN="$DA/bin" bash "$ART" >/dev/null 2>&1
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
if GH_SRC_PARENT="$GHP" GH_TOPDIR="crew-ghsha" PATH="$GHBIN:$PATH" TMPDIR="$SBG" \
     HOME="$DG" CREW_HOME="$DG/share" CREW_BIN="$DG/bin" \
     bash "$ROOT/dist/fetch.sh" --repo test/crew --ref latest -- >/dev/null 2>&1 \
   && [ -d "$DG/share/versions/$V" ]; then
  ok "gh-channel-installs-through-install-sh"
else
  bad "gh-channel-installs-through-install-sh"
fi
same "gh-channel-records-ref-provenance" "gh:test/crew tag:0.0.0-ghtag" \
  "$(cat "$DG/share/versions/$V/INSTALLED_FROM" 2>/dev/null)"
# fetch.sh downloaded the tarball into its own temp dir; `exec`-ing install.sh
# would drop its `trap … EXIT` and orphan that tarball. Assert the sandbox is
# empty after a clean fetch-install (round 1).
leftG="$(find "$SBG" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)"
if [ -z "$leftG" ]; then ok "gh-channel-success-cleans-temp-dir"; else bad "gh-channel-success-cleans-temp-dir (leftovers='$leftG')"; fi

echo
echo "artifact: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
