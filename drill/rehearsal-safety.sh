#!/usr/bin/env bash
# Safety interlocks for drill/rehearsal.sh. The caller supplies bx(), BOX_NAME,
# and REPOS_BACKUP — and, for the attention census's two halves at the bottom,
# ok() and fail() as well, the shape drill/rehearsal-attention-audit.sh already
# uses. Keeping these functions separate makes failure cleanup and the census
# fixture-testable without a box or credentials.
# shellcheck disable=SC2088  # stored tildes expand inside the box via bx()

# A newline, named so the snapshot patterns below read as patterns.
REHEARSAL_NL=$'\n'
# Why the teardown comparison said no, in the words the round summary carries.
# Set beside each refusal so the notify verdict reports the actual state — a
# box that never answered is not a box that restored the wrong bytes.
REHEARSAL_TEARDOWN_REASON=""
# 1 once the pre-drill ~/duty/repos.txt has actually been copied aside. This is
# NOT the same fact as "REPOS_BACKUP is set": the handle is assigned before the
# copy runs, so a round whose `cp` failed carries one too. Teardown needs the
# copy, not the handle — a backup that was made and is then missing is a
# teardown failure, while a backup that was never made is nothing to vouch for,
# and only this flag tells those two apart (#423, round 3).
REHEARSAL_BACKUP_TAKEN=0

# The attention census, carried between its two halves: taken before the first
# authenticated tick, asserted after it (#714).
REHEARSAL_ATTENTION_OUTSIDE=""
REHEARSAL_ATTENTION_OUTSIDE_N=0
REHEARSAL_ATTENTION_LABEL=""
REHEARSAL_ATTENTION_MARK=""
REHEARSAL_ATTENTION_LOG_BASE=0
# Which generation of duty.log the line count above was measured against, as
# `<inode>:<checksum of the counted lines>`, or `none` when the box had no
# duty.log at all. tick.sh rotates that file out from under the count (#714,
# round 5), so the count alone does not name a place in the log — and the inode
# alone does not name a file, because the kernel re-issues it the moment the
# generation is unlinked.
REHEARSAL_ATTENTION_LOG_GEN=none
REHEARSAL_ATTENTION_PICKUPS_BEFORE=""
# Why the census half said no, in the words the caller's refusal prints.
REHEARSAL_ATTENTION_REASON=""

rehearsal_disarm_cron() {
  bx "if command -v crontab >/dev/null 2>&1; then
        tmp=\$(mktemp)
        crontab -l 2>/dev/null | grep -vF ~/duty/bin/tick.sh >\"\$tmp\" || true
        crontab \"\$tmp\"; rc=\$?
        rm -f \"\$tmp\"
        exit \"\$rc\"
      fi"
}

# The copy and the truncate are two box calls, not one `cp && : >`, so the
# round can record that the copy succeeded BEFORE anything overwrites the file
# it copied. Nothing truncates ~/duty/repos.txt until REHEARSAL_BACKUP_TAKEN is
# 1, which is the invariant rehearsal_cleanup reads.
rehearsal_begin_isolation() {
  REPOS_BACKUP="~/duty/repos.txt.pre-drill-$$"
  REHEARSAL_BACKUP_TAKEN=0
  bx "cp ~/duty/repos.txt $REPOS_BACKUP" || return 1
  REHEARSAL_BACKUP_TAKEN=1
  bx ": > ~/duty/repos.txt" &&
    bx "test ! -s ~/duty/repos.txt"
}

rehearsal_narrow_to_sandbox() {
  local sandbox="$1"
  bx "printf '%s\n' '$sandbox' > ~/duty/repos.txt" &&
    bx "[ \"\$(wc -l < ~/duty/repos.txt)\" -eq 1 ] && grep -qxF '$sandbox' ~/duty/repos.txt"
}

# rehearsal_attention_census SANDBOX LABEL — print "<repo> <number>" for every
# parked attention demand this box's identity carries OUTSIDE the sandbox.
# Empty output means the identity carries none. Returns non-zero when the box
# would not answer at all.
#
# LABEL is the box's OWN effective LABEL_ATTENTION, read in _take below and
# passed in rather than spelled here (#714, round 5). duty_attention fetches
# `labels=$LABEL_ATTENTION` (shared/lib/duty-attention.sh:115), and that name
# is NOT one of the six wire marks load_fleet_conf restores over fleet.conf
# (shared/lib/common/conf.sh:14-24) — so an operator file genuinely moves it,
# and a census keyed on the literal `attention` would fetch a different set
# from the one the engine fetched. That is the same defect as the --paginate
# window and the page boundary, in its third disguise: the census's window is
# the engine's window, and every input to it is read off the box.
#
# Narrowing repos.txt scopes review, build, triage and hygiene — every module
# that reads REPOS_FILE. It does NOT scope ATTENTION, which runs first and for
# every role: duty-attention.sh reads the authenticated-user issues endpoint on
# purpose ("cross-repo, no search index, reaches repos not in repos.txt"), so
# an open issue assigned to this box's identity and carrying the `attention`
# label is a demand it will see wherever it lives. The drill box borrows a
# fleet identity, so a real parked demand for that identity is exactly the
# thing this surface is about.
#
# So the interlock asserting "repos.txt contains only the sandbox" is TRUE and,
# for this surface, not sufficient — which is the worst combination, because it
# reads like coverage (#52).
#
# THIS USED TO RETURN A VERDICT, AND THE CALLER REFUSED THE ROUND ON IT (#714).
# The refusal made Gate A unrunnable on the operator's own host: an identity
# with parked work anywhere else — a real account's normal state — never
# reached a phase 2 tick, so every role loop stayed UNPROVEN. Its argument was
# that a regression of crew#66's registry filter costs a real session on a real
# repo, and that argument is answered by READING the evidence rather than by
# refusing to produce it. The engine writes, on the very tick the leg is about
# to run, which demands it saw outside the registry and that it suppressed
# them; the predicates below read exactly that. So this is a CENSUS now, and it
# carries the issue number because the assertion is per demand.
#
# A read that fails is NOT an empty census. It is the third state this file
# already spells out for the registry snapshot (#423, round 2): "the box did
# not say" is not "there was nothing there", and an absence is established by
# reading the source, never by failing to. The `|| true` that used to swallow
# it turned an unanswerable box into a clean bill of health.
#
# NO `--paginate`, DELIBERATELY, AND THE WINDOW IS THE POINT (#714, round 2).
# This is not an independent enumeration of what the identity carries; it is a
# MIRROR of the window the engine itself fetched, because the other half then
# asserts, per row recorded here, that the engine has a suppressed record for
# it. duty_attention's own read is this endpoint with this per_page and no
# --paginate (shared/lib/duty-attention.sh:115), and its partition, its
# .suppressed-attention-scope file and its alert are all derived from that one
# page. A census that read WIDER would record demands the engine never
# fetched, for which no record can exist, and red the leg on a CORRECT engine
# — re-creating one tick later exactly the false refusal this issue removes.
# rehearsal-attention.sh:334-353 reads the same assigned index the same way
# for the same reason, and says the same thing about a correct engine.
#
# So the two reads in this file differ on purpose: pickup_counts below DOES
# paginate, because an appended pickup comment is precisely what lives past
# page one of a surface the engine does not bound. Widening THIS one is an
# engine-side question (`duty_attention` sees 100 assigned demands and no
# more), and D5 fences it out of this issue: nothing under shared/ moves here.
rehearsal_attention_census() {
  local sandbox="$1" label="$2" out
  out="$(bx "gh api '/issues?filter=assigned&state=open&labels=$label&per_page=100' \
          --jq '.[] | select(.repository.full_name != \"$sandbox\") | \"\(.repository.full_name) \(.number)\"'")" \
    || return 1
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | sort -u
  return 0
}

# --- the census's other half: what the engine did with those demands (#714) --
#
# Each predicate prints WHAT IT READ on stdout and returns non-zero when the
# fact does not hold, so the live row quotes the offender rather than a
# transcript. None of them touches a box, so CI drives every branch.

# rehearsal_attention_demand_suppressed ID SCOPE LOG — the engine saw this
# out-of-registry demand and left it alone. ID is "<repo>#<num>".
#
#   SCOPE — ~/duty/.suppressed-attention-scope, as the engine left it
#   LOG   — the duty.log lines written since the census was taken
#
# TWO records are accepted and the state file is the primary one, which is the
# opposite of what the leg's first reading suggests. duty.log carries the
# `attention: outside repos.txt` line through report_suppressed, and that
# writes only on a CHANGE of the suppressed set (#59's rule): the first tick
# that sees a standing demand logs it and every tick after is silent. Every
# `--reuse` pass, and every box whose cron struck before phase 2, would then
# read a missing line as a missing suppression. The state file the same call
# leaves behind is re-derived on every tick from that tick's own partition —
# rewritten when the set changes, REMOVED when it empties — so it is the live
# record, and a demand that regressed INTO the registry disappears from it.
#
# The freshness that matters is not "this tick" but "the last tick whose fetch
# succeeded", and the leg's own positive case establishes that: the pickup
# comment and the label removal it waits for can only come from a tick that
# fetched, partitioned, and found the sandbox demand INSIDE — the same call,
# above the same partition, that wrote this file.
rehearsal_attention_demand_suppressed() {
  local id="$1" scope="$2" log="$3" line
  if [ -n "$scope" ] \
    && awk -v id="$id" '$1 == id { found = 1 } END { exit !found }' <<<"$scope"; then
    printf 'suppressed-attention-scope names %s\n' "$id"
    return 0
  fi
  line="$(grep -F 'attention: outside repos.txt' <<<"$log" | grep -F "$id(" | tail -1)"
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  printf 'neither ~/duty/.suppressed-attention-scope nor an "attention: outside repos.txt" line names %s\n' "$id"
  return 1
}

# rehearsal_attention_no_outside_session SANDBOX LOG — no attention session was
# launched for any repository but the sandbox. The key on the session record is
# "<repo>#<num>" (session.sh's `SESSION START kind=... key=...`), so the repo
# half is what this compares; the census's own rows are not needed, because the
# fact is stronger without them — a dispatch to ANY outside repo is the failure,
# including one nothing parked before the round began.
rehearsal_attention_no_outside_session() {
  local sandbox="$1" log="$2" stray
  stray="$(awk -v s="$sandbox" '
    /SESSION START kind=attention / {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^key=/) {
          k = substr($i, 5); sub(/#[0-9]+$/, "", k)
          if (k != s) print
          next
        }
    }' <<<"$log")"
  [ -z "$stray" ] || { printf '%s\n' "$stray"; return 1; }
  printf 'no SESSION START kind=attention outside %s\n' "$sandbox"
  return 0
}

# rehearsal_attention_no_pickup ID BEFORE AFTER MARK — the round's ticks posted
# no pickup comment on this demand. BEFORE and AFTER are the counts of comments
# carrying MARK, read either side of the tick; anything that is not a number is
# a read nobody could make and reds, for the same reason the census does.
#
# A DELTA, not an absolute count and not a timestamp window. Counting on the
# author separates nothing: on the host this issue exists for, the box identity
# IS the operator, and the operator's own commentary on their own parked issues
# is not a pickup. Counting absolutely reds a correct round, because a demand
# some box legitimately picked up in an earlier life carries the mark forever.
# And a `created_at >` window would hang the verdict on agreement between the
# drill host's clock and GitHub's. Two reads bracketing the tick need neither.
#
# This one row is fleet-wide where the other two are per box, and that is worth
# naming: a comment from a DIFFERENT box sharing the identity is indiscernible
# from this box's, since the author is the same login. What excludes it is the
# rehearsal's own standing precondition — never borrow a live identity until
# the other box holding it is DISARMED (shared/docs/rehearsal.md, phase 2) — and
# the session row above, which reads only this box's duty.log and is therefore
# the precise one. Keeping both is the point: one is exact about which box
# acted, the other is exact about whether the demand was touched at all.
rehearsal_attention_no_pickup() {
  local id="$1" before="$2" after="$3" mark="$4"
  case "${before:-x}${after:-x}" in
    *[!0-9]*)
      printf 'could not read the "%s" comment count of %s (before: %s, after: %s)\n' \
        "$mark" "$id" "${before:-<nothing>}" "${after:-<nothing>}"
      return 1
      ;;
  esac
  if [ "$after" -gt "$before" ]; then
    printf '%s drew %s new "%s" comment(s) across the tick (%s -> %s)\n' \
      "$id" "$((after - before))" "$mark" "$before" "$after"
    return 1
  fi
  printf '%s drew no new "%s" comment (%s -> %s)\n' "$id" "$mark" "$before" "$after"
  return 0
}

# --- reading THIS ROUND'S duty.log lines, across a rotation (#714, round 5) --
#
# The negative session assertion above is an ABSENCE, and an absence read out
# of the wrong slice of a log is the failure this whole leg exists to stop —
# established by failing to read rather than by reading, one file down from the
# demands the census makes the same point about.
#
# shared/bin/tick.sh:31-34 moves duty.log to duty.log.1 when it passes 5 MiB,
# BEFORE opening the append redirect for that tick's run, deliberately and for
# a reason its own comment gives. A drill box is reused between passes and its
# cron has been striking since install, so that threshold is reachable on the
# ordinary `--reuse` invocation. A line count taken before the tick therefore
# does not name a place in the log: the tick can move the file, write this
# round's records near line 1 of a fresh one, and leave `tail -n +<count+1>`
# returning NOTHING — every D2 row green over an outside session that really
# did happen.
#
# So the census records WHICH GENERATION it counted, and the slice is resolved
# against that, in one box read, in the four states it can be in.
#
# That mark is NOT the inode alone. An inode is a slot, not an identity: the
# kernel hands it straight back on the next create, so a box that rotates twice
# or is rebuilt under the round gets a brand-new duty.log wearing the counted
# generation's number, `tail -n +<count+1>` runs off the end of it, and every
# D2 row greens over an absence nobody observed — the exact failure this slice
# exists to stop, one level down. It is not hypothetical: it is what ci-shell
# graded red on an ext4 runner while tmpfs handed the drill a fresh inode and
# hid it (#714, this round). Truncation in place is the same hole, from the
# other side: `>` keeps the inode and drops everything the count named.
#
# The mark is therefore the inode AND a checksum of the first <count> lines —
# precisely the region the offset names. A match then asserts what the slice
# actually needs: this is the file the count was taken from, and it still
# carries the lines that were counted. Anything else is `lost`, and the caller
# stops rather than reading an absence out of a file it cannot place.

# rehearsal_attention_log_slice_cmd BASE GEN — the command that reads this
# round's duty.log lines out of the box. Composed here rather than spelled at
# the call site so a fixture can drive the real text against a real two-
# generation log; every branch runs IN the box, in one read, because a
# generation check and a read that are two calls can straddle the rotation
# they are there to detect.
#
#   the counted generation is still duty.log  — its tail, as before
#   it is now duty.log.1                      — that tail, THEN all of duty.log
#   there was no duty.log at the census       — all of duty.log
#   it is neither                             — `lost`, and the caller stops
#
# The rotated branch is the whole point: the round's lines are split across two
# files and both halves are this round's. The base offset still applies to the
# rotated generation, because that is the file the count was taken against.
# shellcheck disable=SC2016  # every one of these expands inside the box, not here
rehearsal_attention_log_slice_cmd() {
  local base="$1" gen="$2"
  printf '%s\n' \
    'log="$HOME/duty/duty.log"' \
    'cur=none rot=none' \
    "[ ! -e \"\$log\" ] || cur=\"\$(stat -c %i \"\$log\"):\$(head -n $base \"\$log\" | cksum | cut -d' ' -f1)\"" \
    "[ ! -e \"\$log.1\" ] || rot=\"\$(stat -c %i \"\$log.1\"):\$(head -n $base \"\$log.1\" | cksum | cut -d' ' -f1)\"" \
    "if [ '$gen' = none ]; then" \
    "  echo 'slice: fresh'; cat \"\$log\" 2>/dev/null || true" \
    "elif [ \"\$cur\" = '$gen' ]; then" \
    "  echo 'slice: current'; tail -n +$((base + 1)) \"\$log\" 2>/dev/null || true" \
    "elif [ \"\$rot\" = '$gen' ]; then" \
    "  echo 'slice: rotated'" \
    "  tail -n +$((base + 1)) \"\$log.1\" 2>/dev/null || true" \
    '  cat "$log" 2>/dev/null || true' \
    'else' \
    "  echo 'slice: lost'" \
    'fi'
}

# rehearsal_attention_log_slice_readable RAW — the header the read above put on
# the front, graded. `lost` is the generation the census measured being on
# neither file: two rotations, or a box rebuilt under the round. Nothing can be
# concluded from what is left, so this reds and the caller stops rather than
# grading an absence it did not observe.
rehearsal_attention_log_slice_readable() {
  local header="${1%%"$REHEARSAL_NL"*}"
  case "$header" in
    'slice: current')
      printf 'duty.log did not rotate since the census; the slice is its tail\n' ;;
    'slice: rotated')
      printf 'duty.log rotated since the census; the slice spans duty.log.1 and duty.log\n' ;;
    'slice: fresh')
      printf 'the box had no duty.log when the census was taken; the slice is the whole file\n' ;;
    'slice: lost')
      printf 'the duty.log generation the census counted is now neither duty.log nor duty.log.1, so the lines this round wrote cannot be bounded\n'
      return 1 ;;
    *)
      printf 'the box did not answer the duty.log slice read (it said: %s)\n' "${header:-<nothing>}"
      return 1 ;;
  esac
  return 0
}

# rehearsal_attention_log_slice RAW — the lines, with that header removed.
rehearsal_attention_log_slice() {
  [ "${1#*"$REHEARSAL_NL"}" != "$1" ] || return 0
  printf '%s\n' "${1#*"$REHEARSAL_NL"}"
}

# --- the census's two live halves ------------------------------------------
#
# Both emit rows through the caller's ok()/fail(), and both take every box read
# through the caller's bx(), so a fixture drives either one whole.

# rehearsal_attention_pickup_counts ROWS MARK — "<repo>#<num> <count>" per
# census row, counting the comments that carry MARK. Read from INSIDE the box:
# the demands sit on boards the drill HOST may not be able to see at all, and
# the identity the demand is parked for is the box's.
#
# The pages are summed rather than tailed. `--paginate` with `--jq` runs the
# filter per page and prints one number each, so reading the last line counts
# the last page; and dropping `--paginate` would read the first hundred
# comments only, which is exactly where an appended pickup is not.
#
# THE STDIN GUARDS ARE LOAD-BEARING, and they are two different guards against
# the same drain running in two directions. `bx` here is the caller's, and
# rehearsal.sh's is `box exec … bash -lc "$1"` with no redirect of its own —
# `box exec` DRAINS the stdin it inherits, which is how drill/rehearsal-app.sh
# (`:540-550`) once read one roster box while claiming the fleet.
#
#   `</dev/null` on the read  — so this call consumes NOBODY's stdin: not the
#   loop below, and not the loop of some future caller that drives this
#   function per row. It holds whatever bx() the caller hands us.
#
#   the rows on fd 3          — so the loop's own input is not on stdin at all,
#   and the next per-demand box read added inside it cannot silently truncate
#   the census to its first row. rehearsal-app-surfaces.sh:77 fixes the same
#   shape the same way, for the same reason: the reader is caller-supplied.
#
# One demand cannot tell a loop that ran once from a loop that ran, so the
# fixture that pins this carries THREE.
rehearsal_attention_pickup_counts() {
  local rows="$1" mark="$2" repo num raw count
  [ -n "$rows" ] || return 0
  while read -r repo num <&3; do
    [ -n "${num:-}" ] || continue
    if raw="$(bx "gh api 'repos/$repo/issues/$num/comments?per_page=100' --paginate \
        --jq '[.[] | select(.body | contains(\"$mark\"))] | length'" </dev/null)"; then
      count="$(printf '%s\n' "$raw" | tr -d ' \r' | awk 'NF{s+=$1} END{print s+0}')"
    else
      count=unreadable
    fi
    printf '%s#%s %s\n' "$repo" "$num" "$count"
  done 3<<<"$rows"
}

# rehearsal_attention_graded NAME PREDICATE... — run the predicate, print what
# it read indented under a failure, grade the row. A red names what it read —
# the state file, the log line, the comment counts — never a transcript.
#
# This leg's own copy, for the same reason rehearsal-attention-audit.sh keeps
# one: the alternative is sourcing a builder-block leg into a role-independent
# interlock for a six-line function, and that source line then has to be
# discounted by every reader of both.
rehearsal_attention_graded() {
  local name="$1"; shift
  local read_back rc=0 line
  read_back="$("$@")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$name"
    return 0
  fi
  if [ -n "$read_back" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "  read: $line"
    done <<<"$read_back"
  fi
  fail "$name"
  return 1
}

# rehearsal_attention_census_take SANDBOX — the first half (D1). Record every
# demand parked outside the sandbox, the pickup-comment counts they arrive
# with, the mark those counts are keyed on, and duty.log's length, then emit
# the census row. NEVER a verdict on the demands themselves.
#
# Returns non-zero only when the census could not be TAKEN, with the reason in
# REHEARSAL_ATTENTION_REASON; the caller refuses on that, because every
# assertion the other half makes reads against what is recorded here, and a
# leg that establishes an absence by failing to read establishes nothing.
rehearsal_attention_census_take() {
  local sandbox="$1" conf mark
  REHEARSAL_ATTENTION_REASON=""
  # The two configuration values this leg is keyed on, read from the box's OWN
  # installed configuration rather than spelled here, in ONE call — and
  # resolved the two DIFFERENT ways load_fleet_conf resolves them, which is the
  # whole reason they are read together (shared/lib/common/conf.sh:10-25):
  #
  #   LABEL_ATTENTION — defaults, then fleet.conf OVER them. It is not one of
  #   the six wire marks the loader restores, so an operator file moves it and
  #   duty_attention then fetches that label (duty-attention.sh:115). The
  #   census must ask the endpoint the same question the engine asked.
  #
  #   MARK_PICKUP — defaults ALONE, because the loader restores it over
  #   fleet.conf: the board marks "are a wire protocol and cannot be changed by
  #   an operator file". Keying the pickup delta on an operator override would
  #   key it on a mark the engine never writes with, so an override is read and
  #   then deliberately discarded here exactly as the loader discards it.
  #
  # An absence established against a needle nothing writes, or over a set
  # nothing fetched, is green on every board.
  # shellcheck disable=SC2016  # both names expand inside the box
  conf="$(bx 'set -a
              . ~/duty/conf/fleet.defaults.conf
              wire_pickup="$MARK_PICKUP"
              [ ! -f ~/duty/conf/fleet.conf ] || . ~/duty/conf/fleet.conf
              printf "%s\n%s\n" "$LABEL_ATTENTION" "$wire_pickup"' | tr -d '\r')"
  REHEARSAL_ATTENTION_LABEL="${conf%%"$REHEARSAL_NL"*}"
  mark="${conf#*"$REHEARSAL_NL"}"
  REHEARSAL_ATTENTION_MARK="${mark%%"$REHEARSAL_NL"*}"
  if [ -z "$REHEARSAL_ATTENTION_LABEL" ] || [ -z "$REHEARSAL_ATTENTION_MARK" ] \
    || [ "$mark" = "$conf" ]; then
    # shellcheck disable=SC2034  # printed by rehearsal.sh's refusal, like REPOS_BACKUP
    REHEARSAL_ATTENTION_REASON="the box's installed configuration resolved no LABEL_ATTENTION and MARK_PICKUP"
    return 1
  fi
  if ! REHEARSAL_ATTENTION_OUTSIDE="$(rehearsal_attention_census "$sandbox" "$REHEARSAL_ATTENTION_LABEL")"; then
    REHEARSAL_ATTENTION_OUTSIDE=""
    REHEARSAL_ATTENTION_REASON="the box would not list this identity's parked attention demands"
    return 1
  fi
  REHEARSAL_ATTENTION_OUTSIDE_N="$(printf '%s' "$REHEARSAL_ATTENTION_OUTSIDE" | grep -c . || true)"
  # duty.log's length BEFORE the first phase-2 tick, so the negative assertion
  # reads only the lines this round's ticks wrote. A drill box is reused
  # between passes and its cron has been striking since install; a whole-file
  # read carries a previous pass's records into this pass's verdict.
  #
  # The length AND the generation it was measured against, in ONE read: the
  # file can rotate between two of them (see the slice command above), and a
  # count taken against one generation and checked against another names no
  # place in either.
  #
  # The generation is marked by its inode AND a checksum of the very lines the
  # count just took, for the reason the slice command gives at length: an inode
  # on its own is re-issued to the next file created, so the mark would be
  # forgeable by any box that rotated twice or was rebuilt under the round.
  #
  # `n` is NOT re-sanitised in here before it bounds that checksum, and that is
  # deliberate. It is already whatever `wc -l` printed or the literal `0`, so a
  # non-numeric value is unreachable — but were one to arrive, coercing it to 0
  # in here would make the mark agree with the base the host records below and
  # the slice would resolve `current` over the WHOLE file. Left alone, the two
  # disagree, the generation reads `lost`, and the round stops. The degenerate
  # case should fail closed, so the sanitisation stays host-side, where it
  # bounds the offset and not the region the mark covers.
  # shellcheck disable=SC2016  # the command substitutions run inside the box
  conf="$(bx 'n=$(wc -l < ~/duty/duty.log 2>/dev/null || echo 0)
              n=$(printf %s "$n" | tr -d " ")
              if [ -e ~/duty/duty.log ]; then
                g="$(stat -c %i ~/duty/duty.log):$(head -n "$n" ~/duty/duty.log | cksum | cut -d" " -f1)"
              else g=none; fi
              printf "%s %s\n" "$n" "$g"' | tr -d '\r')"
  REHEARSAL_ATTENTION_LOG_BASE="${conf%% *}"
  REHEARSAL_ATTENTION_LOG_GEN="${conf##* }"
  case "$REHEARSAL_ATTENTION_LOG_BASE" in
    '' | *[!0-9]*) REHEARSAL_ATTENTION_LOG_BASE=0 ;;
  esac
  # A generation nobody read is not a generation that is not there: the box
  # answering neither a mark nor `none` is the same third state the census
  # itself refuses on, and the slice below would be resolved against an empty
  # string for every tick of the round.
  if [ -z "$REHEARSAL_ATTENTION_LOG_GEN" ] || [ "$REHEARSAL_ATTENTION_LOG_GEN" = "$conf" ]; then
    # shellcheck disable=SC2034  # printed by rehearsal.sh's refusal, like REPOS_BACKUP
    REHEARSAL_ATTENTION_REASON="the box would not say which generation of duty.log it counted"
    return 1
  fi
  if [ "$REHEARSAL_ATTENTION_OUTSIDE_N" -eq 0 ]; then
    REHEARSAL_ATTENTION_PICKUPS_BEFORE=""
    ok "attention census: 0 demand(s) parked outside $sandbox"
    return 0
  fi
  REHEARSAL_ATTENTION_PICKUPS_BEFORE="$(rehearsal_attention_pickup_counts \
    "$REHEARSAL_ATTENTION_OUTSIDE" "$REHEARSAL_ATTENTION_MARK")"
  ok "attention census: $REHEARSAL_ATTENTION_OUTSIDE_N demand(s) parked outside $sandbox — the tick below must suppress every one"
  local repo num
  # On fd 3 for the reason pickup_counts' comment gives at length: the rows are
  # the loop's input and stdin belongs to whatever the caller put there, so the
  # next per-demand box read added inside either of these loops cannot truncate
  # the census to its first row. Nothing here reads a box today, and neither
  # loop's redirect has a behavioural kill for that reason — the guard's whole
  # job is the read somebody adds NEXT.
  while read -r repo num <&3; do
    [ -n "${num:-}" ] && echo "  census: $repo#$num"
  done 3<<<"$REHEARSAL_ATTENTION_OUTSIDE"
  return 0
}

# rehearsal_attention_census_assert SANDBOX — the second half (D2/D3), run
# after the phase-2 attention tick has proved the wake works. One row per
# recorded demand plus the negative session row; non-zero if any of them
# failed, and the caller stops the box's ticks there.
#
# An identity carrying nothing outside the sandbox asserts nothing and says so
# through the census row alone (D4) — the positive case is the whole leg, as
# it was before this issue.
rehearsal_attention_census_assert() {
  local sandbox="$1" scope raw log pickups_after rc=0 repo num id before after
  [ "$REHEARSAL_ATTENTION_OUTSIDE_N" -gt 0 ] || return 0
  scope="$(bx 'cat ~/duty/.suppressed-attention-scope 2>/dev/null || true' | tr -d '\r')"
  raw="$(bx "$(rehearsal_attention_log_slice_cmd \
    "$REHEARSAL_ATTENTION_LOG_BASE" "$REHEARSAL_ATTENTION_LOG_GEN")" | tr -d '\r')"
  # GRADED, AND THE ONLY ROW THAT RETURNS EARLY. Every row below reads either
  # this slice or the demands recorded against it, so a slice nobody could
  # bound is not a leg with one red row in it — it is a leg with nothing to
  # say, and the rows it would still print are exactly the vacuous greens this
  # row exists to prevent. The round stops here (D3), for the same reason the
  # take half refuses on a census it could not read.
  rehearsal_attention_graded \
    "attention census: this round's duty.log lines are bounded" \
    rehearsal_attention_log_slice_readable "$raw" || return 1
  log="$(rehearsal_attention_log_slice "$raw")"
  pickups_after="$(rehearsal_attention_pickup_counts \
    "$REHEARSAL_ATTENTION_OUTSIDE" "$REHEARSAL_ATTENTION_MARK")"
  rehearsal_attention_graded \
    "attention census: no attention session launched outside $sandbox" \
    rehearsal_attention_no_outside_session "$sandbox" "$log" || rc=1
  # fd 3, as in _take above and for the same forward-looking reason: every
  # predicate this loop calls is pure today and pickups_after is read before
  # it, so the shape is harmless right now and the guard is for the next read.
  while read -r repo num <&3; do
    [ -n "${num:-}" ] || continue
    id="$repo#$num"
    rehearsal_attention_graded "attention census: $id seen and suppressed" \
      rehearsal_attention_demand_suppressed "$id" "$scope" "$log" || rc=1
    before="$(awk -v id="$id" '$1 == id { print $2; exit }' <<<"$REHEARSAL_ATTENTION_PICKUPS_BEFORE")"
    after="$(awk -v id="$id" '$1 == id { print $2; exit }' <<<"$pickups_after")"
    rehearsal_attention_graded "attention census: $id drew no pickup" \
      rehearsal_attention_no_pickup "$id" "$before" "$after" "$REHEARSAL_ATTENTION_MARK" || rc=1
  done 3<<<"$REHEARSAL_ATTENTION_OUTSIDE"
  return "$rc"
}

# --- reading a registry off the box, in the three states it can be in ------

# rehearsal_registry_snapshot PATH — read a file on the box and say which of
# the three things is true, because telling them apart is teardown's whole job:
#
#   prints `absent`               — the box says the file is not there
#   prints `present` + contents   — the box read it
#   returns non-zero              — the box did not answer at all
#
# The third state is why this exists. `bx "test -f X"` is a two-state read of
# a three-state world: a box that has gone away returns non-zero exactly like
# a box reporting an absent file, and the caller then takes the absent branch
# and vouches for a registry nobody looked at. Likewise `cat X || true` turns
# an unreadable file into the empty string, which compares equal to an empty
# pre-drill file. "The box did not say" is not "the file was not there", and
# neither of them is "read, and it was empty" (#423, round 2).
rehearsal_registry_snapshot() {
  local path="$1" out
  out="$(bx "if [ -e $path ]; then printf 'present\n'; cat $path; else printf 'absent\n'; fi")" \
    || return 1
  case "$out" in
    absent | present | present"$REHEARSAL_NL"*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# The two readers for a snapshot. A file that exists and is empty snapshots as
# exactly `present`, so the text is taken by stripping the marker line and
# never by anything that reads an empty remainder as a failure.
rehearsal_snapshot_present() { [ "${1%%"$REHEARSAL_NL"*}" = present ]; }
rehearsal_snapshot_text() {
  case "$1" in
    present"$REHEARSAL_NL"*) printf '%s' "${1#present"$REHEARSAL_NL"}" ;;
  esac
}

# rehearsal_work_registry_matches_pre_drill STATE PRE_TEXT RESTORE_FAILED —
# repos.txt on the box, after the restore, against the bytes the backup held
# before it was moved. Nothing was backed up ⇒ nothing to vouch for; anything
# the box would not answer ⇒ NOT a pass, because the criterion is a comparison
# and a comparison nobody could make is not one. A backup this round MADE and
# cannot now find is the third thing again: the box was left holding whatever
# the drill put there, and no pre-drill bytes survive to compare it with.
rehearsal_work_registry_matches_pre_drill() {
  local state="$1" expected="$2" restore_failed="${3:-0}" snap
  REHEARSAL_TEARDOWN_REASON=""
  case "$state" in
    none) return 0 ;;
    absent)
      [ "$restore_failed" -eq 0 ] && return 0
      REHEARSAL_TEARDOWN_REASON="teardown could not restore repos.txt"
      echo "TEARDOWN: ~/duty/repos.txt could not be restored" >&2
      return 1
      ;;
    lost)
      REHEARSAL_TEARDOWN_REASON="teardown could not find the pre-drill repos.txt backup this round made"
      echo "TEARDOWN: the pre-drill repos.txt backup this round made is gone; ~/duty/repos.txt is unvouched for" >&2
      return 1
      ;;
    unanswerable)
      REHEARSAL_TEARDOWN_REASON="teardown could not read the pre-drill repos.txt backup"
      echo "TEARDOWN: the box did not say whether the pre-drill repos.txt backup was there; ~/duty/repos.txt is unvouched for" >&2
      return 1
      ;;
  esac
  if [ "$restore_failed" -ne 0 ]; then
    REHEARSAL_TEARDOWN_REASON="teardown could not restore repos.txt"
    echo "TEARDOWN: ~/duty/repos.txt could not be restored" >&2
    return 1
  fi
  if ! snap="$(rehearsal_registry_snapshot "~/duty/repos.txt")"; then
    REHEARSAL_TEARDOWN_REASON="teardown could not read repos.txt back"
    echo "TEARDOWN: ~/duty/repos.txt could not be read back after the restore" >&2
    return 1
  fi
  if ! rehearsal_snapshot_present "$snap"; then
    REHEARSAL_TEARDOWN_REASON="teardown left no repos.txt at all"
    echo "TEARDOWN: ~/duty/repos.txt is not there after the restore" >&2
    return 1
  fi
  [ "$(rehearsal_snapshot_text "$snap")" = "$expected" ] && return 0
  REHEARSAL_TEARDOWN_REASON="teardown left repos.txt unlike its pre-drill contents"
  echo "TEARDOWN: ~/duty/repos.txt differs from its pre-drill contents" >&2
  return 1
}

rehearsal_cleanup() {
  local rc="${1:-$?}"
  local repos_state=none repos_pre="" snap
  local repos_restore_failed=0 notify_restore_failed=0
  # The pre-drill bytes, read BEFORE the restore moves the backup away. The
  # restore is then asserted by COMPARISON and never by having exited 0: a
  # command that succeeds against the wrong bytes leaves the box working or
  # watching a set nobody chose, while the round reports a clean teardown.
  #
  # Three states, not two. This probe used to be `bx "test -f $REPOS_BACKUP"`,
  # so a box that stopped answering mid-teardown read as "there was no backup"
  # and the comparison below returned success having compared nothing.
  #
  # And the `absent` answer is itself two facts, told apart by whether the copy
  # was ever taken. A round that copied the fleet registry aside and truncated
  # the original has a backup by construction; the box answering "not there"
  # then measures a LOSS, and vouching for repos.txt on that answer is the same
  # fail-open in a state the box positively reported (#423, round 3).
  if [ -n "${REPOS_BACKUP:-}" ]; then
    if snap="$(rehearsal_registry_snapshot "$REPOS_BACKUP")"; then
      if rehearsal_snapshot_present "$snap"; then
        repos_state=present
        repos_pre="$(rehearsal_snapshot_text "$snap")"
      elif [ "${REHEARSAL_BACKUP_TAKEN:-0}" -eq 1 ]; then
        repos_state=lost
      else
        repos_state=absent
      fi
    else
      repos_state=unanswerable
    fi
  fi
  # Both registries, one step. The notifier half is restored FIRST because a
  # box left watching a sandbox that teardown then deletes is the same class
  # of leftover as a box left working one — and the pairing is why #423 put
  # the restore here rather than in a leg that only runs when it runs.
  #
  # A failed restore is recorded, not merely printed: it is the strongest
  # evidence there is that the registry is NOT back, and the comparison below
  # takes it as an input. A warning on stderr reaches nobody.
  if declare -F rehearsal_notify_restore_registry >/dev/null 2>&1; then
    rehearsal_notify_restore_registry || {
      notify_restore_failed=1
      echo "WARNING: could not restore the pre-drill notify-repos.txt; stop the box: box down $BOX_NAME" >&2
    }
  fi
  if [ -n "${REPOS_BACKUP:-}" ]; then
    bx "if [ -f $REPOS_BACKUP ]; then mv $REPOS_BACKUP ~/duty/repos.txt; fi" || {
      repos_restore_failed=1
      echo "WARNING: could not restore the pre-drill repos.txt; stop the box: box down $BOX_NAME" >&2
    }
  fi
  # Both compared, after both restores have run, absent-before ⇒ absent-after
  # included. A mismatch controls the drill's verdict: cleanup_all takes this
  # return into the EXIT trap's exit status, so a box left holding the wrong
  # registry reds the round instead of being a warning nobody reads.
  if ! rehearsal_work_registry_matches_pre_drill \
      "$repos_state" "$repos_pre" "$repos_restore_failed"; then
    rc=1
    declare -F rehearsal_notify_verdict >/dev/null 2>&1 \
      && rehearsal_notify_verdict fail "${REHEARSAL_TEARDOWN_REASON:-teardown left repos.txt unlike its pre-drill contents}"
  fi
  if declare -F rehearsal_notify_registry_matches_pre_drill >/dev/null 2>&1 \
      && ! rehearsal_notify_registry_matches_pre_drill "$notify_restore_failed"; then
    rc=1
    rehearsal_notify_verdict fail "${REHEARSAL_TEARDOWN_REASON:-teardown left notify-repos.txt unlike its pre-drill contents}"
  fi
  rehearsal_disarm_cron \
    || echo "WARNING: could not disarm the drill cron; stop the box: box down $BOX_NAME" >&2
  return "$rc"
}
