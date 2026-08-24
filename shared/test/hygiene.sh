#!/usr/bin/env bash
# shared/test/hygiene.sh — standalone hygiene subject suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"
# shellcheck source=shared/lib/duty-builder.sh
source "$SHARED/lib/duty-builder.sh"

# --- #167: the dirty-worktree WARN, once per (worktree, dirt state) ----------
# Leaving a dirty worktree alone is right; saying so every five minutes for a
# week is not — that is how a WARN becomes wallpaper. Driven against a REAL
# linked worktree, because the fingerprint is `git status --porcelain` read
# inside one, and a fixture that only feeds text would not prove that.
WTBASE="$TMP/wt-base"
mkdir -p "$WTBASE"
git -C "$WTBASE" init -q
printf 'engine\n' >"$WTBASE/README.md"
git -C "$WTBASE" add README.md
git -C "$WTBASE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
WTDIR="$TMP/wt-build-9"
git -C "$WTBASE" worktree add "$WTDIR" -b build/9-x >/dev/null 2>&1
printf 'scratch\n' >"$WTDIR/untracked.txt"
WTLG="$TMP/seen-wt-dirty"

# The two assertions are each other's must-fail. A fix that keeps warning every
# tick fails the second; a fix that goes permanently silent after the first
# emission fails wt-dirty-new-dirt-rewarns below — and silence is the worse of
# the two, which is why both directions are pinned here.
W1="$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
W2="$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
t wt-dirty-first-pass-warns 1 "$(printf '%s\n' "$W1" | grep -c 'WARN')"
t wt-dirty-second-pass-silent "" "$W2"
# The message names the branch and the price, not just the state: the worktree
# holds its branch, and the failure lands later, on somebody else's build.
case "$W1" in *"build/9-x"*)             r1=named ;; *) r1=MISSING ;; esac
t wt-dirty-warn-names-branch named "$r1"
case "$W1" in *"already checked out"*)   r1=named ;; *) r1=MISSING ;; esac
t wt-dirty-warn-names-consequence named "$r1"
case "$W1" in *"0 modified, 1 untracked"*) r1=counted ;; *) r1=MISSING ;; esac
t wt-dirty-warn-names-the-dirt counted "$r1"

# Dirty in a NEW way is a new condition and is reported again.
printf 'more\n' >"$WTDIR/second.txt"
W3="$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
t wt-dirty-new-dirt-rewarns 1 "$(printf '%s\n' "$W3" | grep -c 'WARN')"
t wt-dirty-new-dirt-then-silent "" "$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
# One worktree's silence is not another's: branch and repo are both in the key,
# so a second stale worktree is not swallowed by the first one's report.
t wt-dirty-other-branch-still-warns 1 \
  "$(_wt_hygiene_report "$WTLG" o/r build/10-y "$WTDIR" | grep -c 'WARN')"
t wt-dirty-other-repo-still-warns 1 \
  "$(_wt_hygiene_report "$WTLG" o/other build/9-x "$WTDIR" | grep -c 'WARN')"

# The id carries the dirt and the value is a fixed sentinel — the ci-red scheme
# (#17), for the same reason. This is the negative control for the scheme NOT
# used: keyed the ordinary way, a new dirt state whose fingerprint sorts below
# the old one is suppressed, losing the report exactly when the condition
# changed.
WTNAIVE="$TMP/wt-naive"
printf 'o/r:build/9-x 999-77\n' | ledger_commit "$WTNAIVE"
t wt-dirt-naive-value-loses-new-dirt 0 \
  "$(printf 'o/r:build/9-x 111-88\n' | ledger_filter "$WTNAIVE" | n)"
t wt-dirt-id-distinguishes-dirt-shapes 2 \
  "$(printf '%s\n%s\n' "$(_wt_dirt_id o/r build/9-x 'M  a.txt')" \
                       "$(_wt_dirt_id o/r build/9-x '?? b.txt')" | sort -u | n)"
t wt-dirt-id-stable-for-the-same-dirt 1 \
  "$(printf '%s\n%s\n' "$(_wt_dirt_id o/r build/9-x 'M  a.txt')" \
                       "$(_wt_dirt_id o/r build/9-x 'M  a.txt')" | sort -u | n)"

# Wiring: the hygiene block reports through the ledger rather than warning flat,
# now by way of _wt_release, which owns the whole clean/preserve/force order.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '_wt_hygiene_report "$ledger" "$repo" "$branch" "$path"' "$BMOD"; then
  r1=ledgered
else
  r1=UNGUARDED
fi
t wt-dirty-warn-is-ledgered-in-module ledgered "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '_wt_release "$dir" "$R" "$wt_branch" "$wt_path" "$pr_num" "$DUTY_DIR/.seen-wt-dirty"' "$BMOD"; then
  r1=wired
else
  r1=UNWIRED
fi
t wt-hygiene-block-calls-release wired "$r1"
# The PR the record goes on comes from the lookup that decided the branch was
# done — one query, so the record can never name a different PR than the removal
# was decided on, and the rare refusal path costs no second API call.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq -- '--state all --json state,number' "$BMOD"; then r1=joined; else r1=SPLIT; fi
t wt-hygiene-lookup-carries-the-pr-number joined "$r1"
# #167's must-fail, in the amended form #168 gives it: not "no --force" but
# "no --force except as the confirmed consequence of a successful preservation
# push". One occurrence, and the ordering assertions below pin it to that one
# place. Comments are stripped first: the block above SAYS why the force is
# earned rather than reached for, and counting raw occurrences counts that
# sentence — a detector tripping on its own documentation, which this repo has
# now managed four separate times.
t wt-hygiene-force-removes-exactly-once 1 \
  "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c -- '--force')"
# ...and the clean path is untouched: removed, branch deleted, no warning.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq 'git -C "$dir" branch -D "$branch"' "$BMOD"; then r1=intact; else r1=MISSING; fi
t wt-clean-removal-path-intact intact "$r1"

# --- #168: preserve before removing ------------------------------------------
# Driven against real repositories — a real bare remote, a real clone, a real
# linked worktree — because every claim here is about what git actually did:
# what the pushed tree contains, whether the ref reached the REMOTE, and
# whether the worktree survived a push that failed. A text fixture proves none
# of that, and the defect this issue exists to prevent (a --force reached
# before the push confirms) is invisible to one.
P168="$TMP/p168"
mkdir -p "$P168"
P_BARE="" P_CLONE="" P_WT=""

_p168_fixture() { # $1=name -> a bare remote, a clone with origin, a worktree
  local name="$1"
  P_BARE="$P168/$name.git"; P_CLONE="$P168/$name"; P_WT="$P168/$name-wt"
  git init -q --bare "$P_BARE"
  git init -q "$P_CLONE"
  printf 'engine\n' >"$P_CLONE/README.md"
  printf 'ignored/\n' >"$P_CLONE/.gitignore"
  git -C "$P_CLONE" add -A
  git -C "$P_CLONE" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm fixture
  git -C "$P_CLONE" remote add origin "$P_BARE"
  git -C "$P_CLONE" worktree add "$P_WT" -b "build/$name" >/dev/null 2>&1
}

_p168_wip_refs() { git -C "$1" for-each-ref --format='%(refname)' refs/heads/wip | n; }

# The record's transport is post-once.sh, so the suite stubs it where the engine
# looks: BIN_DIR, pointed at this block's own bin and restored at the end. The
# stub records the (repo, number) it was called with and the exact body, which
# is what the dedup assertion below reads — post-once.sh's own idempotence is
# tested at post-once.sh; what is this module's to prove is that it hands over a
# body that does not change when nothing changed.
P168_BIN="$P168/bin"; mkdir -p "$P168_BIN"
export P168_PO_CALLS="$P168/po-calls" P168_PO_BODY="$P168/po-body" P168_PO_RC=0
: >"$P168_PO_CALLS"; : >"$P168_PO_BODY"
cat >"$P168_BIN/post-once.sh" <<'P168PO'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >>"$P168_PO_CALLS"
printf '%s' "$3" >"$P168_PO_BODY"
exit "${P168_PO_RC:-0}"
P168PO
chmod +x "$P168_BIN/post-once.sh"
P168_BIN_SAVED="$BIN_DIR"
BIN_DIR="$P168_BIN"

# The remote a preservation goes to. `fork` where the clone has one — the bot
# cannot write to upstream, and a push that is always refused earns no force
# and preserves nothing — else `origin`, the single-remote case, which the
# amended spec still describes ("a remote the pushing identity can actually
# write to"). Triage ruled the preference in on 2026-08-05: `origin` on a fleet
# box is unwritable, so the criterion as first written was unsatisfiable.
_p168_fixture remote-choice
t p168-remote-origin-when-alone origin "$(_wt_preserve_remote "$P_CLONE")"
git -C "$P_CLONE" remote add fork "$P168/fork.git"
t p168-remote-prefers-fork fork "$(_wt_preserve_remote "$P_CLONE")"
git -C "$P_CLONE" remote remove fork
git -C "$P_CLONE" remote remove origin
if _wt_preserve_remote "$P_CLONE" >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-remote-none-refuses refused "$r1"

# 1. Real uncommitted work: modified tracked AND untracked, ignored dirt left
# out. Asserted from the BARE repo throughout — the must-fail is a
# preservation that lands only locally, and reading the clone's own objects
# would pass while the remote holds nothing.
_p168_fixture dirty
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
P_STATUS_BEFORE="$(git -C "$P_WT" status --porcelain | sort)"
if P_OUT="$(_wt_preserve "$P_WT" build/dirty)"; then r1=pushed; else r1=REFUSED; fi
t p168-dirty-preserved pushed "$r1"
t p168-ref-is-on-the-remote 1 "$(_p168_wip_refs "$P_BARE")"
P_REMOTE_TREE="$(git -C "$P_BARE" ls-tree -r --name-only refs/heads/wip/build/dirty | sort)"
case "$P_REMOTE_TREE" in *untracked.txt*) r1=carried ;; *) r1=DROPPED ;; esac
t p168-ref-carries-untracked carried "$r1"
t p168-ref-carries-modified changed \
  "$(git -C "$P_BARE" show refs/heads/wip/build/dirty:README.md)"
case "$P_REMOTE_TREE" in *ignored/x*) r1=LEAKED ;; *) r1=excluded ;; esac
t p168-ref-excludes-ignored excluded "$r1"
# The capture is built in a scratch index, so the worktree it captured is
# byte-identical afterwards: nothing staged, nothing stashed, nothing checked
# out. A push that fails must leave the tree exactly as it was found, and this
# is the property that makes that true.
t p168-capture-leaves-worktree-untouched "$P_STATUS_BEFORE" \
  "$(git -C "$P_WT" status --porcelain | sort)"
t p168-capture-leaves-content-untouched 'rescue me' "$(cat "$P_WT/untracked.txt")"

# Idempotence: the same dirt preserved twice is one ref at one sha. The second
# pass reads the remote, finds its own tree already there, and treats that as
# the confirmation it is — never a second commit, and never the
# non-fast-forward such a commit would be refused as.
if P_OUT2="$(_wt_preserve "$P_WT" build/dirty)"; then r1=confirmed; else r1=REFUSED; fi
t p168-rerun-still-confirms confirmed "$r1"
t p168-rerun-pushes-nothing-new "$P_OUT" "$P_OUT2"
t p168-rerun-leaves-one-ref 1 "$(_p168_wip_refs "$P_BARE")"

# Dirt that CHANGED between passes is new work, and the ref moves to it — the
# new commit is parented on what the remote already holds, so the push is a
# fast-forward rather than a rejection that would strand the worktree.
printf 'later\n' >"$P_WT/second.txt"
if P_OUT3="$(_wt_preserve "$P_WT" build/dirty)"; then r1=pushed; else r1=REFUSED; fi
t p168-new-dirt-preserved pushed "$r1"
case "$P_OUT3" in "$P_OUT") r1=STALE ;; *) r1=advanced ;; esac
t p168-new-dirt-advances-the-ref advanced "$r1"
case "$(git -C "$P_BARE" ls-tree -r --name-only refs/heads/wip/build/dirty)" in
  *second.txt*) r1=carried ;; *) r1=DROPPED ;;
esac
t p168-new-dirt-carries-the-new-file carried "$r1"

# The capture's own refusal, reached directly. `_wt_preserve` refuses when what
# it captured is HEAD's own tree — nothing was at risk — and that path is
# otherwise only reachable when a removal refuses for a reason that leaves the
# tree unchanged (a locked worktree), so it is exercised here rather than left
# to the one shape that happens to reach it. The refusal is what denies the
# caller its force, and a refusal that pushed anyway would earn a force it
# cannot explain: both halves are asserted.
_p168_fixture nothing-at-risk
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
if _wt_preserve "$P_WT" build/nothing-at-risk >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-ignored-only-capture-refuses refused "$r1"
t p168-ignored-only-capture-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
rm -rf "$P_WT/ignored"
if _wt_preserve "$P_WT" build/nothing-at-risk >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-clean-capture-refuses refused "$r1"
t p168-clean-capture-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"

# --- the index is uncommitted work too (@codex-bot-andresmgsl, #376) ----------
#
# A capture built from the working tree alone answers the wrong question. For a
# partially staged path the index holds ONE version and the working tree
# ANOTHER, and both are uncommitted: preserving the second and forcing the
# worktree away destroys the first, which is this issue's own failure mode
# reached through its own fix. Driven end to end through `_wt_release` because
# that is the level that decides a `--force`, and read from the BARE remote
# after the worktree is gone, because "still retrievable" is the claim.
#
# THE ASSERTIONS GO PAST THE TIP. A suite that checks only
# `refs/heads/wip/<branch>:<file>` passes on the defective capture — the tip is
# the half that survives it. The staged version's own assertion is what bites.
_p168_fixture partial-stage
printf 'carefully-staged\n' >"$P_WT/README.md"
git -C "$P_WT" add README.md
printf 'later-working-edit\n' >"$P_WT/README.md"
t p168-partial-stage-is-partially-staged 'MM README.md' \
  "$(git -C "$P_WT" status --porcelain --untracked-files=all)"
# The chain is idempotent as the single commit was: a second pass finds its own
# tip AND its own parent already on the remote and confirms rather than minting
# a duplicate pair.
P_PS1="$(_wt_preserve "$P_WT" build/partial-stage)"
P_PS2="$(_wt_preserve "$P_WT" build/partial-stage)"
t p168-partial-stage-rerun-confirms-the-chain "$P_PS1" "$P_PS2"
t p168-partial-stage-rerun-leaves-one-ref 1 "$(_p168_wip_refs "$P_BARE")"
P_LG="$P168/ledger-partial"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/partial-stage "$P_WT" 50 "$P_LG")"; then
  r1=released
else
  r1=KEPT
fi
t p168-partial-stage-released released "$r1"
t p168-partial-stage-worktree-gone gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
# The tip is the working tree, which is what `checkout FETCH_HEAD` should land
# somebody on...
t p168-partial-stage-tip-is-the-working-tree later-working-edit \
  "$(git -C "$P_BARE" show refs/heads/wip/build/partial-stage:README.md)"
# ...and the staged bytes are the commit below it, on the remote, after the only
# copy that was ever local has been forced away.
t p168-partial-stage-parent-is-the-index carefully-staged \
  "$(git -C "$P_BARE" show 'refs/heads/wip/build/partial-stage^:README.md')"
P_PS_SEEN="$(for P_PS_C in refs/heads/wip/build/partial-stage \
  'refs/heads/wip/build/partial-stage^'; do
  git -C "$P_BARE" show "$P_PS_C:README.md"
done | sort -u | tr '\n' ' ')"
t p168-partial-stage-both-versions-survive 'carefully-staged later-working-edit ' \
  "$P_PS_SEEN"
# The record is the durable half, so it names the half nobody would think to
# look for — the sha, and the ref-relative way to reach it.
P_REC="$(cat "$P168_PO_BODY")"
P_PS_STAGED="$(git -C "$P_BARE" rev-parse 'refs/heads/wip/build/partial-stage^')"
case "$P_REC" in *"$P_PS_STAGED"*) r1=named ;; *) r1=MISSING ;; esac
t p168-record-names-the-staged-snapshot named "$r1"
case "$P_REC" in *'FETCH_HEAD^'*) r1=reachable ;; *) r1=MISSING ;; esac
t p168-record-carries-the-staged-recovery reachable "$r1"
case "$P_OUT" in *'FETCH_HEAD^'*) r1=named ;; *) r1=MISSING ;; esac
t p168-log-names-the-staged-snapshot named "$r1"

# The shape the working-tree capture cannot see AT ALL: content staged and then
# put back in the tree. `git status` calls it dirty (`MM`), so the removal
# refuses — and the capture equalled HEAD's tree, so the preservation refused
# too, and the worktree was stuck on every five-minute tick for the life of the
# box with nothing preserved and nothing said. The refusal now reads "neither
# half holds anything", which is what releases this one.
_p168_fixture staged-only
printf 'staged-then-reverted\n' >"$P_WT/README.md"
git -C "$P_WT" add README.md
printf 'engine\n' >"$P_WT/README.md"
t p168-staged-only-worktree-matches-head "" \
  "$(git -C "$P_WT" diff HEAD --name-only)"
P_LG="$P168/ledger-staged-only"
if _wt_release "$P_CLONE" o/r build/staged-only "$P_WT" 51 "$P_LG" >/dev/null; then
  r1=released
else
  r1=KEPT
fi
t p168-staged-only-released released "$r1"
t p168-staged-only-worktree-gone gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
t p168-staged-only-pushes-a-ref 1 "$(_p168_wip_refs "$P_BARE")"
t p168-staged-only-preserves-the-staged-bytes staged-then-reverted \
  "$(git -C "$P_BARE" show 'refs/heads/wip/build/staged-only^:README.md')"

# A ref already on the remote from a pass that knew nothing about indexes — the
# upgrade case, and the must-fail for checking the chain rather than the tip.
# The tip matches what this pass captured (the working tree did not change), so
# a confirmation on the tip alone would return "already preserved" and force the
# worktree away with the staged bytes on no remote at all.
_p168_fixture stage-after-preserve
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_SAP1="$(_wt_preserve "$P_WT" build/stage-after-preserve)"
read -r _ _ _ _ P_SAP_STAGED1 <<<"$P_SAP1"
t p168-plain-dirt-has-no-staged-snapshot - "$P_SAP_STAGED1"
t p168-plain-dirt-is-one-commit 1 \
  "$(git -C "$P_BARE" rev-list --count refs/heads/wip/build/stage-after-preserve \
    ^"$(git -C "$P_WT" rev-parse HEAD)")"
P_SAP_TIP1="$(git -C "$P_BARE" rev-parse refs/heads/wip/build/stage-after-preserve)"
printf 'now-staged\n' >"$P_WT/README.md"
git -C "$P_WT" add README.md
printf 'engine\n' >"$P_WT/README.md"
if _wt_preserve "$P_WT" build/stage-after-preserve >/dev/null; then
  r1=pushed
else
  r1=REFUSED
fi
t p168-stage-after-preserve-pushes pushed "$r1"
# Measured on the REMOTE, never on what the function printed: a tip-only
# confirmation returns a different line (it now has a parent to name) while the
# ref stands still, which is the false pass this assertion exists to refuse.
case "$(git -C "$P_BARE" rev-parse refs/heads/wip/build/stage-after-preserve)" in
  "$P_SAP_TIP1") r1=CONFIRMED_STALE ;; *) r1=advanced ;;
esac
t p168-stage-after-preserve-advances-the-ref advanced "$r1"
t p168-stage-after-preserve-carries-the-index now-staged \
  "$(git -C "$P_BARE" show 'refs/heads/wip/build/stage-after-preserve^:README.md')"

# An index that cannot be read is not an empty one. Corrupted here because that
# is deterministic wherever this runs (a chmod proves nothing under root), and
# the shape is the same either way: what is staged is unknown, and unknown must
# not be summarised as nothing on the way to a `--force`. No capture, no push,
# no removal — every byte still on disk.
_p168_fixture unreadable-index
printf 'rescue me\n' >"$P_WT/untracked.txt"
printf 'not-an-index-at-all' >"$(git -C "$P_WT" rev-parse --git-path index)"
if _wt_index_tree "$P_WT" >/dev/null 2>&1; then r1=CLAIMED; else r1=refused; fi
t p168-index-read-fails-closed refused "$r1"
if _wt_preserve "$P_WT" build/unreadable-index >/dev/null 2>&1; then
  r1=CLAIMED
else
  r1=refused
fi
t p168-unreadable-index-capture-refuses refused "$r1"
t p168-unreadable-index-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
t p168-unreadable-index-keeps-the-work 'rescue me' \
  "$(cat "$P_WT/untracked.txt" 2>/dev/null)"

# 2. Only-ignored dirt: removed, and nothing pushed. Nothing was at risk, so
# there is no ref to explain and no force to earn — the clean removal already
# succeeds, which is why the preservation path is reached only by a refusal.
_p168_fixture ignored-only
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
P_LG="$P168/ledger-ignored"
if _wt_release "$P_CLONE" o/r build/ignored-only "$P_WT" 41 "$P_LG" >/dev/null; then
  r1=released
else
  r1=KEPT
fi
t p168-ignored-only-released released "$r1"
t p168-ignored-only-worktree-gone gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
t p168-ignored-only-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
# ...and nothing was recorded either: there is no ref to point a reader at.
t p168-ignored-only-records-nothing 0 "$(grep -c 'o/r#41' "$P168_PO_CALLS")"
# ...and a second sweep has nothing left to re-remove: the released worktree is
# out of `worktree list`, which is what the hygiene block enumerates.
t p168-released-worktree-off-the-list 0 \
  "$(git -C "$P_CLONE" worktree list --porcelain | grep -c "$P_WT\$")"

# 3. A failed push is a hard stop. No preservation, no removal — today's
# behaviour, including #167's once-per-dirt WARN, and the worktree still
# holding every byte of the work.
_p168_fixture push-fails
printf 'rescue me\n' >"$P_WT/untracked.txt"
git -C "$P_CLONE" remote set-url origin "$P168/nowhere-at-all.git"
git -C "$P_WT" remote set-url origin "$P168/nowhere-at-all.git"
P_LG="$P168/ledger-nopush"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/push-fails "$P_WT" 42 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
t p168-failed-push-refuses-release kept "$r1"
t p168-failed-push-keeps-worktree present \
  "$([ -d "$P_WT" ] && echo present || echo GONE)"
t p168-failed-push-keeps-the-work 'rescue me' "$(cat "$P_WT/untracked.txt" 2>/dev/null)"
t p168-failed-push-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
t p168-failed-push-then-silent "" "$(_wt_release "$P_CLONE" o/r build/push-fails "$P_WT" 42 "$P_LG")"
# Nothing landed, so nothing is recorded: a comment naming a ref that does not
# exist is worse than no comment, because the reader stops looking.
t p168-failed-push-records-nothing 0 "$(grep -c 'o/r#42' "$P168_PO_CALLS")"

# 4. The whole order, end to end: a worktree holding real work is released
# only because the push landed, and the work is retrievable from the remote
# afterwards. This is the acceptance criterion as data — and the must-fail it
# carries is the reordering that would look harmless, a --force reached before
# the confirmation.
_p168_fixture released
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_LG="$P168/ledger-released"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/released "$P_WT" 43 "$P_LG")"; then
  r1=released
else
  r1=KEPT
fi
t p168-release-succeeds released "$r1"
t p168-release-removed-the-worktree gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
t p168-release-left-the-work-on-the-remote 'rescue me' \
  "$(git -C "$P_BARE" show refs/heads/wip/build/released:untracked.txt)"
# The log line is the whole recovery instruction: whoever reads it a week later
# is not holding this box, and the worktree it names no longer exists.
case "$P_OUT" in *"wip/build/released"*) r1=named ;; *) r1=MISSING ;; esac
t p168-log-names-the-ref named "$r1"
case "$P_OUT" in *"git fetch $P168/released.git wip/build/released"*) r1=recoverable ;; *) r1=MISSING ;; esac
t p168-log-carries-the-recovery-command recoverable "$r1"
# A released branch is deleted the same way the clean path deletes it — the two
# removals differ in what they preserved first, not in what they leave behind.
t p168-release-deletes-the-branch 0 \
  "$(git -C "$P_CLONE" branch --list build/released | n)"

# 5. The record, which is the half that survives losing the other one. It goes
# on the PR the worktree belonged to, and it names the remote, the ref, what it
# holds and how to get it back — enough to decide the work is worthless without
# fetching it, and enough to fetch it where it is not.
t p168-record-goes-to-the-pr 'o/r#43' "$(tail -1 "$P168_PO_CALLS")"
P_REC="$(cat "$P168_PO_BODY")"
case "$P_REC" in *'wip/build/released'*) r1=named ;; *) r1=MISSING ;; esac
t p168-record-names-the-ref named "$r1"
# shellcheck disable=SC2016  # the markdown the record contains, not an expansion
case "$P_REC" in *'`origin`'*) r1=named ;; *) r1=MISSING ;; esac
t p168-record-names-the-remote named "$r1"
# What it holds, in the counts the criterion asks for: one modified tracked
# file (README.md) and one untracked (untracked.txt).
case "$P_REC" in *'1 modified, 1 untracked'*) r1=counted ;; *) r1=MISSING ;; esac
t p168-record-carries-the-counts counted "$r1"
case "$P_REC" in
  *"git fetch $P168/released.git wip/build/released"*) r1=recoverable ;;
  *) r1=MISSING ;;
esac
t p168-record-carries-the-recovery-command recoverable "$r1"
# The sha ties the record to what was actually pushed — and is what makes the
# body stable, which is the property post-once.sh's exact-body dedup runs on.
P_REC_SHA="$(git -C "$P_BARE" rev-parse refs/heads/wip/build/released)"
case "$P_REC" in *"$P_REC_SHA"*) r1=pinned ;; *) r1=MISSING ;; esac
t p168-record-names-the-sha pinned "$r1"

# Dedup, from this module's side: the same preservation asked for twice hands
# post-once.sh a byte-identical body, so its exact-body match suppresses the
# second. A body carrying a timestamp or a run id would pass every assertion
# above and post a fresh comment every tick — which is the shape #167 exists to
# prevent, moved upstream where it is louder.
_p168_fixture record-stable
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_PRES="$(_wt_preserve "$P_WT" build/record-stable)"
read -r P_RM P_RF P_RS P_RU <<<"$P_PRES"
_wt_record o/r 44 build/record-stable "$P_WT" "$P_RM" "$P_RF" "$P_RS" "$P_RU"
P_REC1="$(cat "$P168_PO_BODY")"
_wt_record o/r 44 build/record-stable "$P_WT" "$P_RM" "$P_RF" "$P_RS" "$P_RU"
t p168-record-body-is-stable "$P_REC1" "$(cat "$P168_PO_BODY")"

# The counts describe the REF, and the shape that made them lie is the common
# one: an untracked DIRECTORY. `git status --porcelain` with its default
# untracked mode collapses `newdir/a` and `newdir/b` into a single `?? newdir/`
# row, so the record said "1 untracked" over a ref holding two files — and a
# whole uncommitted `bin/` or `test/`, which is exactly what #168 exists to
# save, is the case that reads as one stray file to whoever decides not to
# fetch it. Asserted against the ref's own file count rather than a literal, so
# the record is checked against the payload and not against itself. Every
# earlier fixture puts its untracked file at the root, where the defect is
# invisible.
_p168_fixture nested-untracked
printf 'changed\n' >"$P_WT/README.md"
mkdir -p "$P_WT/newdir"
printf 'a\n' >"$P_WT/newdir/a"
printf 'b\n' >"$P_WT/newdir/b"
P_LG="$P168/ledger-nested"
_wt_release "$P_CLONE" o/r build/nested-untracked "$P_WT" 49 "$P_LG" >/dev/null
P_NESTED_N="$(git -C "$P_BARE" ls-tree -r --name-only \
  refs/heads/wip/build/nested-untracked -- newdir | n)"
t p168-nested-ref-carries-both-files 2 "$P_NESTED_N"
P_REC="$(cat "$P168_PO_BODY")"
case "$P_REC" in
  *"1 modified, $P_NESTED_N untracked"*) r1=counted ;;
  *) r1="MISCOUNTED: $P_REC" ;;
esac
t p168-record-counts-nested-untracked counted "$r1"

# The same read, failing. Two shapes, because they arrive differently: the
# worktree's directory gone out from under the sweep, and a git that cannot
# answer where the directory is still there.
#
# The failure has to be LOUD, and the reason is the `if !` it is called inside:
# `set -e` is disarmed over the whole condition, so a swallowed exit status is
# not caught anywhere downstream. A status that returned nothing summarises as
# "0 modified, 0 untracked" — a record that reads like a triviality over content
# nobody has seen, and a `--force` earned on it. The must-fail is a `_wt_record`
# that returns 0 here.
if _wt_record o/r 48 build/vanished "$P168/vanished" origin wip/build/vanished \
  deadbeef "$P_BARE" >/dev/null 2>&1; then r1=CLAIMED; else r1=refused; fi
t p168-record-refuses-unreadable-status refused "$r1"
t p168-record-refuses-before-posting 0 "$(grep -c 'o/r#48' "$P168_PO_CALLS")"

# 6. A record that does not land is a hard stop on the removal, exactly as a
# failed push is. The payload is the deletable half and the comment the durable
# one (#168, amended 2026-08-05), so a worktree forced away with the ref pushed
# and nothing upstream saying where it went ships the gap the amendment closes.
# Self-healing by construction: the worktree stays, and the next pass
# re-preserves to the same sha and retries the record.
_p168_fixture record-fails
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_LG="$P168/ledger-norecord"
P168_PO_RC=1
if P_OUT="$(_wt_release "$P_CLONE" o/r build/record-fails "$P_WT" 45 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
t p168-failed-record-refuses-release kept "$r1"
t p168-failed-record-keeps-worktree present \
  "$([ -d "$P_WT" ] && echo present || echo GONE)"
t p168-failed-record-keeps-the-work 'rescue me' "$(cat "$P_WT/untracked.txt" 2>/dev/null)"
t p168-failed-record-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
t p168-failed-record-then-silent 0 \
  "$(_wt_release "$P_CLONE" o/r build/record-fails "$P_WT" 45 "$P_LG" | grep -c 'WARN')"
# The payload is still on the remote — the stop is about the pointer, never
# about the work, and the second pass mints no second ref for it.
t p168-failed-record-keeps-the-ref 1 "$(_p168_wip_refs "$P_BARE")"
# ...and once the record does land, the same worktree releases.
P168_PO_RC=0
if _wt_release "$P_CLONE" o/r build/record-fails "$P_WT" 45 "$P_LG" >/dev/null; then
  r1=released
else
  r1=KEPT
fi
t p168-record-recovered-releases released "$r1"
t p168-record-recovered-removed-the-worktree gone \
  "$([ -d "$P_WT" ] && echo THERE || echo gone)"

# ...and the same refusal reached through `_wt_release`, which is where it has
# to hold: a `git` on PATH that fails only `status` (73, so nothing can mistake
# it for a clean exit) and passes everything else through to the real one. The
# push still lands — `_wt_preserve` never reads a status — so this pins the
# exact division the amendment draws: the payload is safe, the pointer is not,
# and it is the pointer that gates the force.
_p168_fixture status-unreadable
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_LG="$P168/ledger-nostatus"
P168_REAL_GIT="$(command -v git)"
export P168_REAL_GIT
cat >"$P168_BIN/git" <<'P168GIT'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = status ] && exit 73; done
exec "$P168_REAL_GIT" "$@"
P168GIT
chmod +x "$P168_BIN/git"
P_PATH_SAVED="$PATH"
PATH="$P168_BIN:$PATH"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/status-unreadable "$P_WT" 47 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
PATH="$P_PATH_SAVED"
rm -f "$P168_BIN/git"
t p168-unreadable-status-refuses-release kept "$r1"
t p168-unreadable-status-keeps-worktree present \
  "$([ -d "$P_WT" ] && echo present || echo GONE)"
t p168-unreadable-status-keeps-the-work 'rescue me' \
  "$(cat "$P_WT/untracked.txt" 2>/dev/null)"
t p168-unreadable-status-records-nothing 0 "$(grep -c 'o/r#47' "$P168_PO_CALLS")"
t p168-unreadable-status-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
# The payload landed before the record was ever attempted, and it stays: the
# stop is about the pointer, never about the work.
t p168-unreadable-status-keeps-the-ref 1 "$(_p168_wip_refs "$P_BARE")"

# One read, in one place, listing every file. Both properties are structural
# because both are invisible to a suite whose fixtures happen to have flat
# untracked files and a working git — which is what the fixtures above were
# until this round. Comment lines are stripped first: the helper DOCUMENTS the
# bare form it exists to replace, and a detector that counts its own
# explanation is a mistake this repo has now made five separate times.
P_STATUS_READS="$(grep -v '^[[:space:]]*#' "$BMOD" | grep 'status --porcelain')"
t p168-one-status-read 1 "$(printf '%s\n' "$P_STATUS_READS" | n)"
t p168-status-lists-every-file 0 \
  "$(printf '%s\n' "$P_STATUS_READS" | grep -vc -- '--untracked-files=all')"
# ...and it fails closed rather than returning an empty listing that summarises
# as "0 modified, 0 untracked".
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_DIRTFN="$(awk '/^_wt_dirt\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
case "$P_DIRTFN" in *'|| return 1'*) r1=closed ;; *) r1=OPEN ;; esac
t p168-dirt-read-fails-closed closed "$r1"

# 7. A worktree that survives the forced removal is reported ONCE, not on every
# tick: the same discipline #167 bought for the dirty-worktree warning, on the
# path that bypassed it. A lock is the reachable way to make `remove --force`
# refuse; the engine never locks a worktree itself, so this needs a human lock
# or a filesystem refusal in the wild — which is exactly why it repeated
# unnoticed on a five-minute unattended loop.
_p168_fixture force-survives
printf 'rescue me\n' >"$P_WT/untracked.txt"
git -C "$P_CLONE" worktree lock "$P_WT"
P_LG="$P168/ledger-locked"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/force-survives "$P_WT" 46 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
t p168-locked-force-refuses-release kept "$r1"
t p168-locked-force-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
t p168-locked-force-then-silent 0 \
  "$(_wt_release "$P_CLONE" o/r build/force-survives "$P_WT" 46 "$P_LG" | grep -c 'WARN')"
# Silence is not amnesia: the work is still on the remote, still one ref, still
# one commit, however many ticks pass over it.
t p168-locked-force-keeps-one-ref 1 "$(_p168_wip_refs "$P_BARE")"
t p168-locked-force-keeps-the-work 'rescue me' \
  "$(git -C "$P_BARE" show refs/heads/wip/build/force-survives:untracked.txt)"
# New dirt is new news, and says so once again: the ledger id carries the
# preserved sha, so a changed worktree is never swallowed by the last one's
# silence. Must-fail: key it on the worktree alone and this goes quiet.
printf 'later\n' >"$P_WT/second.txt"
t p168-locked-force-rewarns-on-new-dirt 1 \
  "$(_wt_release "$P_CLONE" o/r build/force-survives "$P_WT" 46 "$P_LG" | grep -c 'WARN')"
git -C "$P_CLONE" worktree unlock "$P_WT"

# The ordering, read as an ordering. Every one of these is a real defect that
# passes a behavioural suite on a good day: a force before the push confirms
# discards work only when the remote is down, and a `git stash` capture drops
# untracked files only when there are some.
P_REL="$(awk '/^_wt_release\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_CLEAN_LN="$(printf '%s\n' "$P_REL" | grep -n 'worktree remove "\$path"' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_PRES_LN="$(printf '%s\n' "$P_REL" | grep -n '_wt_preserve "\$path"' | head -1 | cut -d: -f1)"
P_FORCE_LN="$(printf '%s\n' "$P_REL" | grep -n -- '--force' | head -1 | cut -d: -f1)"
t p168-clean-attempt-precedes-capture yes \
  "$([ -n "$P_CLEAN_LN" ] && [ -n "$P_PRES_LN" ] && [ "$P_CLEAN_LN" -lt "$P_PRES_LN" ] && echo yes || echo NO)"
t p168-capture-precedes-force yes \
  "$([ -n "$P_PRES_LN" ] && [ -n "$P_FORCE_LN" ] && [ "$P_PRES_LN" -lt "$P_FORCE_LN" ] && echo yes || echo NO)"
# The record is between them, and reads the worktree while there still is one:
# the counts it carries come from `git status` on a path the force is about to
# take away, so a record moved below the force names nothing at all.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_RECORD_LN="$(printf '%s\n' "$P_REL" | grep -n '_wt_record "\$repo"' | head -1 | cut -d: -f1)"
t p168-capture-precedes-record yes \
  "$([ -n "$P_PRES_LN" ] && [ -n "$P_RECORD_LN" ] && [ "$P_PRES_LN" -lt "$P_RECORD_LN" ] && echo yes || echo NO)"
t p168-record-precedes-force yes \
  "$([ -n "$P_RECORD_LN" ] && [ -n "$P_FORCE_LN" ] && [ "$P_RECORD_LN" -lt "$P_FORCE_LN" ] && echo yes || echo NO)"
# The force is inside the branch the preservation's success opens, not beside
# it: the guard is `if preserved=...`, so a force outside it cannot exist.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
case "$P_REL" in *'if preserved="$(_wt_preserve'*) r1=guarded ;; *) r1=UNGUARDED ;; esac
t p168-force-is-inside-the-push-guard guarded "$r1"
# The capture never goes through `git stash`: without --include-untracked it
# silently drops exactly the files this issue was filed over, and with it, it
# mutates the worktree it is supposed to leave alone.
t p168-capture-never-stashes 0 "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c 'git stash\|stash push\|stash create')"
# ...it writes a scratch index instead, which is what leaves the tree untouched.
# All three index-touching commands are under it — read-tree, add, write-tree —
# and the one that got left out would be the one that stages the build's work
# into the real index on its way past.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
t p168-capture-uses-a-scratch-index 3 \
  "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c 'GIT_INDEX_FILE="\$idx"')"
# The REAL index is read the same way: through a copy, never in place. This is
# not fussiness — `git write-tree` rewrites the cache-tree extension into
# whichever index it is handed, so a read that pointed GIT_INDEX_FILE at the
# worktree's own index would modify the worktree this module promises to leave
# byte-identical. The copy is the only thing standing between those two, and it
# is one line somebody would delete as redundant.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_IDXFN="$(awk '/^_wt_index_tree\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
case "$P_IDXFN" in *'cp "$real" "$copy"'*) r1=copied ;; *) r1=IN_PLACE ;; esac
t p168-index-read-through-a-copy copied "$r1"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
t p168-index-read-never-in-place 0 \
  "$(printf '%s\n' "$P_IDXFN" | grep -v '^[[:space:]]*#' | grep -c 'GIT_INDEX_FILE="\$real"')"
# ...and it fails closed, exactly as the status read does: an index that cannot
# be written to a tree is unknown content, and unknown is not empty.
case "$P_IDXFN" in *'|| return 1'*) r1=closed ;; *) r1=OPEN ;; esac
t p168-index-fn-fails-closed closed "$r1"
# The staged snapshot is the tip's PARENT, never the tip: whoever runs the
# recovery command lands on the working tree, which is what they were told they
# would get. Read as an ordering, since both commits are built the same way and
# the swap would pass every "both versions survive" assertion.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_PRESFN="$(awk '/^_wt_preserve\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_STAGED_LN="$(printf '%s\n' "$P_PRESFN" | grep -n 'staged_commit="\$(_wt_commit' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_TIP_LN="$(printf '%s\n' "$P_PRESFN" | grep -n 'commit="\$(_wt_commit "\$path" "\$tree"' | head -1 | cut -d: -f1)"
t p168-staged-commit-precedes-the-tip yes \
  "$([ -n "$P_STAGED_LN" ] && [ -n "$P_TIP_LN" ] && [ "$P_STAGED_LN" -lt "$P_TIP_LN" ] && echo yes || echo NO)"
# The record goes through post-once.sh rather than a bare POST: its dedup is an
# exact body match against the comments endpoint, so a tick that dies between
# the push and the removal re-records nothing. A local ledger cannot promise
# that — it dies with the box, and this whole issue is about a box dying.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_RECFN="$(awk '/^_wt_record\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
case "$P_RECFN" in *'"$BIN_DIR/post-once.sh"'*) r1=post_once ;; *) r1=RAW ;; esac
t p168-record-uses-post-once post_once "$r1"
t p168-record-never-posts-raw 0 \
  "$(printf '%s\n' "$P_RECFN" | grep -v '^[[:space:]]*#' | grep -c 'issues/.*comments')"

BIN_DIR="$P168_BIN_SAVED"


suite_finish
