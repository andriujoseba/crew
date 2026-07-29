#!/usr/bin/env bash
# engine-manifest.sh — what is ACTUALLY installed on this box, hashed.
#
#   engine-manifest.sh                     print the manifest of the installed tree
#   engine-manifest.sh --record            write it to $DUTY_DIR/.engine-manifest
#   engine-manifest.sh --report [--paths]  state, stamp and divergence, for the host
#   engine-manifest.sh --paths             the differing paths alone; exit 1 if any
#
# ~/duty/VERSION is a CLAIM, not evidence: install.sh writes the version it
# shipped and nothing since has ever looked at the files. Hand-edit
# ~/duty/bin/duty.sh and the stamp does not move — `crew status` reports the box
# as current while the fleet runs two engines, and the next `crew upgrade`
# deletes the edit without a word. Both halves were live on 2026-07-29, when two
# defect reports and a 20-assertion test suite existed only on a box (#159).
#
# This hashes the shipped tree so the claim can be checked, and so the installer
# can refuse to overwrite an edit nobody recorded. It is an INSTRUMENT, not a
# security boundary: it lives inside the tree it measures, so an operator who
# means to defeat it can. The failure it exists to catch is the honest one — a
# hotfix somebody forgot to tell the fleet about.
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
RECORD="$DUTY_DIR/.engine-manifest"
# The header carries the format version because the algorithm ships WITH the
# engine: a record written by a future shape must read as unverified, never as
# modified. An instrument that cries wolf across an upgrade gets ignored.
FORMAT="crew-engine-manifest v1"

# The engine surface: exactly what install.sh puts, and nothing else.
#
# NOT all of ~/duty — logs, clones, work/, trees/ and the tick state change on
# every tick, and a manifest over those reports every live box as modified
# within five minutes.
#
# NOT the per-box configuration either, and each exclusion is load-bearing:
# conf/instance.conf is machine-derived and appended to by the drill itself
# (drill/rehearsal.sh's AUTO_APPROVE_REREQUEST fixture), conf/fleet.conf is
# transported from the host on every install, and repos.txt / notify-repos.txt
# already carry their own divergence provenance in install.sh's apply_registry —
# reporting them twice, in two vocabularies, teaches an operator to trust
# neither.
#
# What is left is the code, the prompts and the profiles a version ships: the
# things that are supposed to be byte-identical on every box at that version,
# and the things a hotfix lands in.
MANIFEST_ROOTS="bin lib prompts conf/roles conf/agents"
MANIFEST_FILES="conf/fleet.defaults.conf"

die() { echo "engine-manifest: $*" >&2; exit 1; }

command -v sha256sum >/dev/null || die "sha256sum not found — content stamping requires it"

# manifest_body — one `<sha256>  <relpath>` line per engine file, sorted by
# path, relative to DUTY_DIR so a manifest survives a restored gold image.
#
# Content, never mtime: `touch` on a clean box must not read modified, and a
# same-size edit must not read clean. Names as well as content, because the
# hashes alone cannot tell an added file from a deleted one — and both are
# somebody's hand on the box.
#
# EVERY non-directory entry, not only `-type f`: `find` does not follow
# symlinks, so a symlink is neither `f` nor `d` and a `-type f` sweep walks
# straight past it. One `ln -s /anything ~/duty/bin/hotfix.sh` was invisible
# here and to install.sh's sweep alike — an executable path that read `current`,
# was never named, and survived every upgrade certified clean. A fifo or a
# device node under bin/ is not executable code, but it is equally a hand on a
# box the record calls untouched, so the rule is the simple one: under an engine
# root, anything that is not a directory is engine surface.

# entry_kind — what a non-regular entry IS, in one word.
entry_kind() {
  if   [ -L "$1" ]; then echo symlink
  elif [ -p "$1" ]; then echo fifo
  elif [ -S "$1" ]; then echo socket
  elif [ -b "$1" ]; then echo block
  elif [ -c "$1" ]; then echo chardev
  else echo unknown
  fi
}

# entry_digest — the hash of a non-regular entry, standing in for the content
# hash a regular file gets.
#
# A symlink hashes its TARGET STRING, never the referent's bytes, and both
# halves of that are load-bearing. `sha256sum` on a symlink silently hashes what
# it points at, so a shipped bin/duty.sh replaced by a link to a byte-identical
# copy elsewhere would read `current` — the file the engine executes would not
# be the file the record measured. And a *dangling* link makes sha256sum fail,
# which under `pipefail` would take `state()` down with it: the instrument would
# go silent on exactly the box that needs it.
entry_digest() { # RELPATH
  local kind desc
  kind="$(entry_kind "$1")"
  if [ "$kind" = symlink ]; then
    desc="$kind $(readlink -- "$1" 2>/dev/null || true)"
  else
    desc="$kind"
  fi
  printf '%s' "$desc" | sha256sum | awk '{print $1}'
}

# manifest_line — sha256sum's own line shape, escaping included, so a manifest
# is one format whichever half of manifest_body wrote the line.
manifest_line() { # DIGEST RELPATH
  local digest="$1" p="$2"
  case "$p" in
    *\\*|*$'\n'*)
      p="${p//\\/\\\\}"; p="${p//$'\n'/\\n}"
      printf '\\%s  %s\n' "$digest" "$p" ;;
    *) printf '%s  %s\n' "$digest" "$p" ;;
  esac
}

manifest_body() (
  # A subshell, so the cd cannot leak into a caller that hashes and then keeps
  # working from relative paths.
  local roots=() r
  cd "$DUTY_DIR" 2>/dev/null || return 0
  for r in $MANIFEST_ROOTS; do
    [ -d "$r" ] || continue
    # The trailing slash is what makes find descend a root that is itself a
    # symlink; without it `find bin` on a redirected bin/ prints the link and
    # stops, and every file the engine actually executes goes unmeasured. The
    # bare name goes in too when the root IS a link, so the redirect is named
    # rather than merely walked through. For an ordinary directory the two
    # spellings produce exactly the paths the bare name always did.
    roots+=("$r/")
    if [ -L "$r" ]; then roots+=("$r"); fi
  done
  # -e OR -L: a dangling symlink at a manifest file's path is present and wrong,
  # not absent, and dropping the root would report it as `removed`.
  for r in $MANIFEST_FILES; do if [ -e "$r" ] || [ -L "$r" ]; then roots+=("$r"); fi; done
  [ "${#roots[@]}" -gt 0 ] || return 0
  {
    # Regular files stay one batched exec: the per-box cost of the whole
    # instrument is what makes it affordable to run on every status.
    find "${roots[@]}" -type f -print0 2>/dev/null | xargs -0 -r sha256sum --
    # Everything else that is not a directory, one at a time — there are
    # normally none of these at all, so the loop costs a clean box nothing.
    while IFS= read -r -d '' r; do
      manifest_line "$(entry_digest "$r")" "$r"
    done < <(find "${roots[@]}" ! -type d ! -type f -print0 2>/dev/null)
  } | LC_ALL=C sort -k2
)

stamp() { head -1 "$DUTY_DIR/VERSION" 2>/dev/null | tr -d '\r\n'; }

manifest() {
  printf '# %s %s\n' "$FORMAT" "$(stamp)"
  manifest_body
}

recorded_body() { tail -n +2 "$RECORD" 2>/dev/null; }
recorded_stamp() { sed -n "1s/^# $FORMAT //p" "$RECORD" 2>/dev/null | head -1; }

record_is_readable() {
  [ -f "$RECORD" ] || return 1
  head -1 "$RECORD" 2>/dev/null | grep -q "^# $FORMAT" || return 1
}

# state — the whole point, in one word.
#
#   absent      no engine here at all
#   unverified  an engine, but no record this shape can read: either it was
#               installed before content stamping, or by a different format.
#               NEVER modified — a fleet that reads modified everywhere on the
#               day this lands has learned that the word means nothing.
#   current     the files are what the recorded install shipped
#   modified    they are not
state() {
  [ -s "$DUTY_DIR/VERSION" ] || { echo absent; return 0; }
  record_is_readable || { echo unverified; return 0; }
  if [ "$(recorded_body)" = "$(manifest_body)" ]; then echo current; else echo modified; fi
}

# divergence — `<status> <relpath>` per differing file, sorted, for a human who
# is about to lose one of them.
divergence() {
  record_is_readable || return 0
  LC_ALL=C awk '
    function parse(line, arr,   off, h, p) {
      # sha256sum escapes a filename containing a backslash or newline by
      # prefixing the LINE with one; shift past it so the fields still line up.
      off = (substr(line, 1, 1) == "\\") ? 1 : 0
      h = substr(line, 1 + off, 64)
      p = substr(line, 67 + off)
      if (p != "") arr[p] = h
    }
    NR == FNR { parse($0, rec); next }
    { parse($0, cur) }
    END {
      for (p in cur) {
        if (!(p in rec)) print "added " p
        else if (cur[p] != rec[p]) print "modified " p
      }
      for (p in rec) if (!(p in cur)) print "removed " p
    }
  ' <(recorded_body) <(manifest_body) | LC_ALL=C sort -k2,2 -k1,1
}

# The host reads this over `box exec`, so it is key=value lines rather than one
# delimited record: a TAB-joined line read with `read -r a b c` collapses an
# empty field into the next one, and the empty field here — `recorded=` on an
# unverified box — is the common case on the day this ships.
report() { # $1 = "paths" to append the divergence
  local st
  st="$(state)"
  printf 'state=%s\n' "$st"
  printf 'stamp=%s\n' "$(stamp)"
  printf 'recorded=%s\n' "$(recorded_stamp)"
  if [ "${1:-}" = paths ] && [ "$st" = modified ]; then
    divergence | sed 's/^/path=/'
  fi
}

record() {
  local tmp
  mkdir -p "$DUTY_DIR"
  tmp="$(mktemp "$DUTY_DIR/.engine-manifest.XXXXXX")"
  manifest >"$tmp"
  mv "$tmp" "$RECORD"
}

MODE=print WANT_PATHS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --record) MODE=record; shift ;;
    --report) MODE=report; shift ;;
    --paths)  [ "$MODE" = report ] || MODE=paths; WANT_PATHS=1; shift ;;
    --state)  MODE=state; shift ;;
    *) die "unknown argument '$1' (usage: engine-manifest.sh [--record | --report [--paths] | --paths | --state])" ;;
  esac
done

case "$MODE" in
  print)  manifest ;;
  record) record ;;
  state)  state ;;
  report) if [ "$WANT_PATHS" -eq 1 ]; then report paths; else report; fi ;;
  paths)
    out="$(divergence | sed 's/^/path=/')"
    [ -z "$out" ] || printf '%s\n' "$out"
    [ -z "$out" ]
    ;;
esac
