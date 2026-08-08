#!/usr/bin/env bash
# drill/rehearsal-app-surfaces.sh — the seven 0.1.2 operator surfaces the app
# rehearsal reads, as functions over the inputs they assert about (#420).
#
# SOURCED, never run. rehearsal-app.sh sources it after defining ok/fail/skip/t
# and jqf; shared/test/run.sh sources it with those four stubbed and stages a
# wrong answer into each input to prove the assertion that owns it goes red.
# That is the same shape run.sh already uses for drill/rehearsal-safety.sh (a
# stubbed `bx()`, then source) and drill/rehearsal-fixtures.sh.
#
# The split is deliberate and it is the whole reason this file exists: an
# assertion welded into the role block can only be exercised by owning a drill
# host, and an assertion nobody can red is an assertion nobody has checked —
# which is #50's defect. Everything here therefore takes its subject as an
# ARGUMENT: a payload file, a command's captured output, a fingerprint pair.
# What is left in rehearsal-app.sh is the part that genuinely needs the host —
# starting the collector, shelling into a box, running the CLI.
#
# Contract with the caller, all of it required before the first call:
#   ok / fail / skip / t   the leg's reporters
#   jqf <expr>             python one-liner over stdin JSON, `d` is the payload
#   roster_rows            the roster's non-comment lines, one per box
#   box_integrity <box>    the box's own engine-manifest.sh --state, or empty
# shellcheck shell=bash

# The PAGE-side halves of the 0.1.2 surfaces, skipped BY NAME wherever the walk
# cannot run — no browser, no module, --no-browser. An API-only pass would be
# the wrong verdict: the payload can carry a version and a verdict the page
# drops. A precondition that silently retires an assertion instead of naming it
# is how this leg once reported `0 failed` while asserting nothing (#50).
app_surface_page_skips() {
  skip "page: the header renders the serving host's version (#347)" "$1"
  skip "page: the engine tile renders its integrity verdict (#190)" "$1"
  skip "page: the state filter separates disarmed from silent (#312)" "$1"
  skip "page: the unit tile counts the declared roster and the hired tile the consoles (#204)" "$1"
}

# --- #347: the header names the version of the crew that is SERVING the page -
# app_surface_version <fleet.json> <crew --version> <VERSION file's first line>
app_surface_version() {
  local fleet="$1" host_version="$2" version_file="$3" api_version
  api_version="$(jqf "d.get('version') or ''" < "$fleet")"
  if [ -z "$version_file" ]; then
    fail "floor: the API names the serving host's own crew version" \
         "no readable VERSION — the drill cannot say what the header should name"
  elif [ "$api_version" = "$host_version" ] \
       && [ "${api_version#*"$version_file"}" != "$api_version" ]; then
    # Both halves, and the second is the load-bearing one: the string is what
    # the launcher passed AND it contains this tree's own VERSION. A server that
    # dropped the value serves "version unavailable", which fails the first; a
    # launcher naming a stale or hardcoded release fails the second.
    ok "floor: the API names the serving host's own crew version ($version_file)"
  else
    fail "floor: the API names the serving host's own crew version ($version_file)" \
         "VERSION says '$version_file', crew --version says '$host_version', the API serves '$api_version'"
  fi
}

# --- #190: the integrity verdict is the box's own, not a word the floor made -
# probe.sh runs engine-manifest.sh --state inside the guest and passes the word
# through; this asks the same box the same question over its own transport and
# requires the two to agree. The vocabulary is engine-manifest.sh's:
# current | modified | unverified, and `absent` for a box with no engine, which
# is why only boxes reporting an engine are compared.
# app_surface_integrity <fleet.json>
app_surface_integrity() {
  local fleet="$1" name api_integ own_integ
  local integ_n=0 integ_bad="" integ_vocab=""
  while read -r name _ _ _; do
    [ -z "$name" ] && continue
    [ -n "$(jqf "([u.get('engine') or '' for u in d['units'] if u['box']=='$name'] or [''])[0]" < "$fleet")" ] || continue
    api_integ="$(jqf "([u.get('integrity') or '' for u in d['units'] if u['box']=='$name'] or [''])[0]" < "$fleet")"
    own_integ="$(box_integrity "$name")"
    if [ -z "$own_integ" ]; then
      # Not a pass and not a failure of the floor: the box would not answer the
      # second reader, so there is nothing to compare. Named, so it cannot be
      # mistaken for agreement.
      skip "integrity: $name" "the box did not answer engine-manifest.sh --state"
      continue
    fi
    integ_n=$((integ_n + 1))
    case "$own_integ" in
      current|modified|unverified) ;;
      *) integ_vocab="${integ_vocab:+$integ_vocab, }$name said '$own_integ'" ;;
    esac
    [ "$api_integ" = "$own_integ" ] \
      || integ_bad="${integ_bad:+$integ_bad, }$name: floor '$api_integ' vs box '$own_integ'"
  done < <(roster_rows)
  if [ "$integ_n" -eq 0 ]; then
    skip "floor: every hired box's integrity verdict is the box's own answer" \
         "no hired box on this fleet answered engine-manifest.sh --state"
    return 0
  fi
  t "floor: every hired box's integrity verdict is the box's own answer ($integ_n boxes)" \
    "" "$integ_bad"
  # The words are engine-manifest.sh's contract, and the page renders them as
  # current / MODIFIED / unverified. A fourth word reaching the tile is a
  # rendering the operator has never been taught to read.
  t "floor: every integrity verdict is one of the three words the tile renders" \
    "" "$integ_vocab"
}

# --- #204: a roster box that is not deployed is COUNTED and not DRAWN -------
# The count is the DECLARED roster, so an operator never loses a box by not
# having created it; the console is what absence closes. Asserted by
# construction, never by luck: where this fleet has no such box the case is
# skipped by name, and the drill never creates or destroys a fleet member to
# manufacture one.
# `hired` is a three-valued verdict the collector publishes so the page never
# re-derives it from silence, and only ONE of the three hides a console:
#   no       measured absence — never created, or answered and has no engine
#   unknown  could not be measured (stopped, unreachable, inventory unreadable)
#            and therefore KEEPS its console: that is the hired-and-gone-dark
#            box this page exists to show
#   yes      an engine answered
# So "drawn" is everything that is not a measured `no`, which is the same
# partition the page's own walk makes (`u.hired !== 'no'`). Counting only `yes`
# as drawn would call every stopped box hidden and red a correct page.
#
# app_surface_not_deployed <fleet.json> <roster count>
# Publishes SURF_NOT_DEPLOYED and SURF_DRAWN for the page half, which asserts
# the same two numbers as they are rendered.
app_surface_not_deployed() {
  local fleet="$1" roster_n="$2" unreadable_inv nd note nd_bad="" nd_n
  SURF_NOT_DEPLOYED="$(jqf "' '.join(u['box'] for u in d['units'] if u.get('hired')=='no')" < "$fleet")"
  SURF_DRAWN="$(jqf "sum(1 for u in d['units'] if u.get('hired')!='no')" < "$fleet")"
  unreadable_inv="$(jqf "' '.join(u['box'] for u in d['units'] if (u.get('note') or '').startswith('box inventory unreadable'))" < "$fleet")"
  if [ -n "$unreadable_inv" ]; then
    # `box list` did not answer, so absence was never MEASURED for these boxes —
    # and #204's filter is precisely a claim about measured absence. Asserting
    # through a failed inventory is the inference the verdict exists to refuse.
    skip "floor: a roster box that is not deployed is counted and not drawn" \
         "the box inventory did not answer for: $unreadable_inv"
    return 0
  fi
  if [ -z "$SURF_NOT_DEPLOYED" ]; then
    skip "floor: a roster box that is not deployed is counted and not drawn" \
         "every one of the $roster_n roster boxes is deployed — nothing on this fleet exercises the grid filter"
    return 0
  fi
  for nd in $SURF_NOT_DEPLOYED; do
    note="$(jqf "([u.get('note') or '' for u in d['units'] if u['box']=='$nd'] or [''])[0]" < "$fleet")"
    # Counted: it is IN the payload at all, which is what keeps the unit tile at
    # the declared size. And it names the way out — the repair verb is the whole
    # point of drawing a box nobody can open a console on.
    case "$note" in
      *"crew new $nd"*|*"crew hire $nd"*) ;;
      *) nd_bad="${nd_bad:+$nd_bad, }$nd: note '$note' names no repair verb" ;;
    esac
  done
  t "floor: a roster box that is not deployed is counted and names its repair verb" \
    "" "$nd_bad"
  # ...and it is not drawn: the consoles are the deployed boxes, while the
  # count stays the declared roster. Both numbers pinned, so a filter applied
  # one layer too high fails here rather than shrinking the fleet silently.
  nd_n="$(printf '%s\n' "$SURF_NOT_DEPLOYED" | wc -w | tr -d ' ')"
  t "floor: the not-deployed boxes are counted but not drawn ($nd_n of $roster_n)" \
    "$((roster_n - nd_n))" "$SURF_DRAWN"
}

# --- #218: `crew up --dry-run` says what it WOULD do and touches nothing -----
# The last clause is the point of the flag, so it is asserted against the FLEET
# rather than against the command's own output: the roster it read, the boxes
# that exist, and every roster box's crontab, before and after. A dry run that
# creates or arms anything moves one of the three.
#
# app_surface_dry_run <dry-run output> <before fingerprint> <after fingerprint> <rc>
app_surface_dry_run() {
  local out="$1" before="$2" after="$3" rc="$4" name dry_silent=""
  if [ "$rc" -eq 0 ]; then
    ok "crew up --dry-run exits 0"
  else
    fail "crew up --dry-run exits 0" "rc=$rc — $(tail -3 "$out" | tr '\n' ' ')"
  fi
  # One planned action per roster box, named for the box. Every branch of the
  # dry run prints `<name>: WOULD ...` — create, start, hire, or SKIP with the
  # reason the real verb would refuse — so a box with no line at all is a box
  # the operator was not told about.
  while read -r name _ _ _; do
    [ -z "$name" ] && continue
    grep -qE "^$name: WOULD " "$out" || dry_silent="${dry_silent:+$dry_silent, }$name"
  done < <(roster_rows)
  t "crew up --dry-run names a planned action for every roster box" "" "$dry_silent"
  if grep -qE '^up --dry-run: [0-9]+ would be created, [0-9]+ started, [0-9]+ hired$' "$out"; then
    ok "crew up --dry-run summarises what it would do"
  else
    fail "crew up --dry-run summarises what it would do" \
         "no 'up --dry-run: N would be created, N started, N hired' line — got: $(tail -1 "$out")"
  fi
  if grep -q '^boxes UNREADABLE$' "$before"; then
    # Half the fingerprint could not be taken, so "unchanged" is not a claim
    # this run may make. The other two thirds still are, and saying so is the
    # honest split rather than a pass on a comparison that compared less than
    # it says.
    skip "crew up --dry-run left the box list unchanged" "box list --json did not answer"
  fi
  if diff -q "$before" "$after" >/dev/null 2>&1; then
    ok "crew up --dry-run changed nothing: same roster, same boxes, same crontabs"
  else
    fail "crew up --dry-run changed nothing: same roster, same boxes, same crontabs" \
         "$(diff "$before" "$after" | head -4 | tr '\n' ' ')"
  fi
}

# --- #308: a box that does not ANSWER is unknown, never never-hired ---------
# The box is chosen read-only, from the floor's own note: `stopped` and
# `unreachable` are boxes the inventory KNOWS about and the probe could not
# reach. A `not created` box is a different case — `crew status <box>` refuses
# it outright — and is deliberately not used here.
# app_surface_silent_box <fleet.json>  →  a box name on stdout, or nothing
app_surface_silent_box() {
  jqf "([u['box'] for u in d['units'] if (u.get('note') or '').startswith(('stopped','unreachable'))] or [''])[0]" < "$1"
}

# The distinction an operator acts on: `not hired (no engine)` says run `crew
# hire`, `unknown — the box did not answer` says find out why the box is not
# talking. Inferring the first from silence sends them to the wrong repair.
# app_surface_status_unknown <box> <crew status output> <rc>
app_surface_status_unknown() {
  local box="$1" out="$2" rc="$3" engine_line
  engine_line="$(grep -m1 '^engine: ' "$out" || true)"
  case "$engine_line" in
    *"unknown"*"did not answer"*)
      ok "crew status $box: an unanswered probe reads unknown, not never-hired" ;;
    *"not hired"*)
      fail "crew status $box: an unanswered probe reads unknown, not never-hired" \
           "the box exists and did not answer, and the CLI inferred it was never hired: '$engine_line'" ;;
    *)
      fail "crew status $box: an unanswered probe reads unknown, not never-hired" \
           "rc=$rc, engine line: '${engine_line:-none printed}'" ;;
  esac
}

# --- #345: `no build duty` names a cause and a count -----------------------
# The bare line was indistinguishable from the burial bug #264 exists to
# prevent: an operator read `build duty (ready unclaimed=8)`, then `no build
# duty` ten minutes later, and it cost an hour of ledger reads to learn the slot
# was held. The parenthetical is the whole repair, so the assertion is that
# every one of these lines carries one — and that it is one of the causes
# _no_build_duty_reason can actually produce, not any prose at all.
# app_surface_no_build_duty <collected lines>
app_surface_no_build_duty() {
  local lines="$1" n cause bad
  n="$(grep -c . "$lines" || true)"
  if [ "${n:-0}" -eq 0 ]; then
    skip "duty.log: no build duty names a cause and a count" \
         "no box on this fleet has logged a no-build-duty tick yet"
    return 0
  fi
  # A cause the reason function can produce. `board empty` and `board unread`
  # carry no count on purpose — there is nothing to count — so requiring digits
  # of every line would red a correct log.
  cause='no build duty \((slot held by .+; board holds [0-9]+ ready|[0-9]+ ready, [0-9]+ round\(s\) held by seen-ledger|[0-9]+ ready held by seen-ledger|[0-9]+ round\(s\) held by seen-ledger|board empty|board unread)\)'
  bad="$(grep -vE "$cause" "$lines" | head -3 | tr '\n' ' ' || true)"
  t "duty.log: every no build duty line names a cause ($n lines)" "" "$bad"
}

# --- the page halves --------------------------------------------------------
# What is read is the NAMED ok line, not the walk's exit status. A walk that
# exits 0 having never reached a check proves nothing about that check —
# exactly the shape of #50 — and the version and integrity assertions are both
# conditional on the page having flipped LIVE.
# app_surface_walk_asserted <our label> <the walk's label> <walk output>
app_surface_walk_asserted() {
  if grep -qxF "  ok   $2" "$3"; then
    ok "$1"
  elif grep -qF "  FAIL $2" "$3"; then
    fail "$1" "the walk reached it and it failed — see the walk output above"
  else
    fail "$1" "the walk never reached '$2', so nothing asserted it"
  fi
}

# --- #312: deliberately stopped is not the same alarm as silent -------------
# The split is what an operator triages by: a disarmed box is a decision
# somebody made, a silent one is a box that stopped answering. Compared against
# `crew status`, box by box, in the agreement block's shape — the two readers
# answer "is this box armed?" from one set of crontab patterns since #189, so a
# disagreement here means one of them is lying to an operator.
# app_surface_filter <page-read.json> <crew status output>
app_surface_filter() {
  local page="$1" status="$2" disarmed silent both b line bad=""
  disarmed="$(jqf "' '.join(d['disarmed'])" < "$page")"
  silent="$(jqf "' '.join(d['silent'])" < "$page")"
  if [ -z "$disarmed" ] && [ -z "$silent" ]; then
    skip "page: the state filter separates disarmed from silent (#312)" \
         "no box on this fleet is disarmed or silent — neither group has a member to classify"
    return 0
  fi
  for b in $disarmed; do
    line="$(grep -E "^$b " "$status" | head -1 || true)"
    case "$line" in
      *disarmed*|*"paused by operator"*|*paused*) ;;
      "") bad="${bad:+$bad, }$b: grouped Disarmed, crew status printed no row" ;;
      *)  bad="${bad:+$bad, }$b: grouped Disarmed, crew status says '$line'" ;;
    esac
  done
  for b in $silent; do
    # The load-bearing direction: a box the operator deliberately stopped must
    # not be counted in the alarm group. #312 exists because it was.
    line="$(grep -E "^$b " "$status" | head -1 || true)"
    case "$line" in
      *disarmed*|*"paused by operator"*)
        bad="${bad:+$bad, }$b: grouped Silent while crew status says it is deliberately stopped — '$line'" ;;
    esac
  done
  both="$(jqf "' '.join(sorted(set(d['disarmed']) & set(d['silent'])))" < "$page")"
  [ -z "$both" ] || bad="${bad:+$bad, }in both groups at once: $both"
  t "page: the state filter separates disarmed from silent (#312)" "" "$bad"
}

# --- #204 on the page: the count is the roster, the consoles the deployed ----
# Both numbers pinned. The unit tile must stay the DECLARED size or the page and
# `crew status` stop agreeing about how big the fleet is, and the hired tile
# appears only when the two differ — a permanent "N hired" beside "N units" is
# furniture.
# app_surface_tiles <page-read.json> <roster count> <not-deployed names> <drawn>
app_surface_tiles() {
  local page="$1" roster_n="$2" not_deployed="$3" drawn="$4" tiles units hired
  tiles="$(jqf "d['tiles']" < "$page")"
  units="$(printf '%s' "$tiles" | sed -n 's/.*[^0-9]\([0-9]\+\)units.*/\1/p;s/^\([0-9]\+\)units.*/\1/p' | head -1)"
  hired="$(printf '%s' "$tiles" | sed -n 's/.*[^0-9]\([0-9]\+\)hired.*/\1/p;s/^\([0-9]\+\)hired.*/\1/p' | head -1)"
  if [ -z "$not_deployed" ]; then
    # Nothing is hidden, so #204's own case is absent — but the count half still
    # holds and is asserted, and the missing half is named rather than dropped.
    if [ "$units" = "$roster_n" ] && [ -z "$hired" ]; then
      ok "page: the unit tile counts the declared roster, and no hired tile on a fully deployed fleet (#204)"
    else
      fail "page: the unit tile counts the declared roster, and no hired tile on a fully deployed fleet (#204)" \
           "roster $roster_n, tile says '${units:-none}' units and '${hired:-no}' hired"
    fi
  elif [ "$units" = "$roster_n" ] && [ "$hired" = "$drawn" ]; then
    ok "page: the unit tile counts the declared roster and the hired tile the consoles (#204)"
  else
    fail "page: the unit tile counts the declared roster and the hired tile the consoles (#204)" \
         "roster $roster_n with $drawn deployed; tile says '${units:-none}' units, '${hired:-none}' hired"
  fi
}

# The two page halves that need the page to have flipped LIVE, gated on it once.
# app_surface_page_groups <page-read.json> <crew status output> <roster count>
#                         <not-deployed names> <drawn>
app_surface_page_groups() {
  local page="$1"
  if [ "$(jqf "str(d['live'])" < "$page")" != "True" ]; then
    # The page never flipped LIVE, so every group below describes the bundled
    # demo fleet. Nothing about this host can be read off it.
    skip "page: the state filter separates disarmed from silent (#312)" \
         "the page did not flip LIVE within 12s — it is rendering the demo payload"
    skip "page: the unit tile counts the declared roster and the hired tile the consoles (#204)" \
         "the page did not flip LIVE within 12s"
    return 0
  fi
  app_surface_filter "$page" "$2"
  app_surface_tiles "$page" "$3" "$4" "$5"
}
