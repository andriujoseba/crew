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

n() { awk 'NF{c++} END{print c+0}'; }
BMOD="$SHARED/lib/duty-builder.sh"

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


# --- rehearsal notify leg: the watch-set union, both halves (#423) ---------
# shellcheck source=drill/rehearsal-notify.sh
source "$ROOT/drill/rehearsal-notify.sh"

NOTIFY_WORK=owner/crew-drill-reviewer
NOTIFY_EXTRA=owner/crew-drill-reviewer-notify
NOTIFY_WORK_PR=31
NOTIFY_EXTRA_PR=7
NOTIFY_WORK_LINE="2026-08-08T12:00:01Z $NOTIFY_WORK#$NOTIFY_WORK_PR: notified needs-human at abc1234 (msg 5501)"
NOTIFY_EXTRA_LINE="2026-08-08T12:00:02Z $NOTIFY_EXTRA#$NOTIFY_EXTRA_PR: notified needs-human at def5678 (msg 5502)"
NOTIFY_RUN_LOG="2026-08-08T12:00:00Z notify run start
$NOTIFY_WORK_LINE
$NOTIFY_EXTRA_LINE
2026-08-08T12:00:03Z sweep done — 2 repos, 2 flagged, 2 pending
2026-08-08T12:00:03Z notify run end"

notify_union() {
  rehearsal_notify_union_from_log \
    "$NOTIFY_WORK" "$NOTIFY_WORK_PR" "$NOTIFY_EXTRA" "$NOTIFY_EXTRA_PR" "$1"
}

notify_out="$(notify_union "$NOTIFY_RUN_LOG" 2>&1)"
notify_rc=$?
t notify-union-both-halves-on-one-run-rc 0 "$notify_rc"
t notify-union-both-halves-say-nothing "" "$notify_out"

# THE required mutation: the pre-#316 shadowing behaviour, staged against the
# input the assertion reads. notify-repos.txt used to REPLACE repos.txt, so
# the half that disappears is the work registry's — and a leg asserting only
# the notify half would pass the bug unchanged.
NOTIFY_SHADOW_LOG="${NOTIFY_RUN_LOG/"$NOTIFY_WORK_LINE"$'\n'/}"
notify_out="$(notify_union "$NOTIFY_SHADOW_LOG" 2>&1)"
notify_rc=$?
t notify-union-pre-316-shadow-mutation-reds 5 "$notify_rc"
case "$notify_out" in
  *"$NOTIFY_WORK#$NOTIFY_WORK_PR (repos.txt half)"*) r1=named ;;
  *) r1=missing ;;
esac
t notify-union-shadow-failure-names-the-missing-repo named "$r1"

NOTIFY_EXTRA_DROPPED_LOG="${NOTIFY_RUN_LOG/"$NOTIFY_EXTRA_LINE"$'\n'/}"
notify_out="$(notify_union "$NOTIFY_EXTRA_DROPPED_LOG" 2>&1)"
notify_rc=$?
t notify-union-notify-half-dropped-reds 6 "$notify_rc"
case "$notify_out" in
  *"$NOTIFY_EXTRA#$NOTIFY_EXTRA_PR (notify-repos.txt half)"*) r1=named ;;
  *) r1=missing ;;
esac
t notify-union-notify-half-failure-names-the-missing-repo named "$r1"

notify_rc=0
notify_union "2026-08-08T12:00:00Z notify run start
2026-08-08T12:00:03Z sweep done — 2 repos, 0 flagged, 0 pending
2026-08-08T12:00:03Z notify run end" >/dev/null 2>&1 || notify_rc=$?
t notify-union-neither-half-reds 7 "$notify_rc"

# "On the same tick" is the assertion, not "eventually both". Two runs a tick
# apart satisfy every per-repo grep and are exactly what a shadowing notifier
# alternating its watch set would produce.
NOTIFY_TWO_RUN_LOG="2026-08-08T12:00:00Z notify run start
$NOTIFY_WORK_LINE
2026-08-08T12:00:03Z sweep done — 1 repos, 1 flagged, 1 pending
2026-08-08T12:00:03Z notify run end
2026-08-08T12:05:00Z notify run start
$NOTIFY_EXTRA_LINE
2026-08-08T12:05:03Z sweep done — 1 repos, 1 flagged, 2 pending
2026-08-08T12:05:03Z notify run end"
notify_out="$(notify_union "$NOTIFY_TWO_RUN_LOG" 2>&1)"
notify_rc=$?
t notify-union-split-across-two-ticks-reds 5 "$notify_rc"

# A send that failed still writes the sweep's line, with no message id. The
# criterion is that the notification REACHED the operator.
notify_rc=0
notify_union "${NOTIFY_RUN_LOG/(msg 5501)/(msg none)}" >/dev/null 2>&1 || notify_rc=$?
t notify-union-unsent-message-is-not-a-delivery 5 "$notify_rc"

notify_rc=0
notify_union "2026-08-08T12:00:00Z notify run start
$NOTIFY_WORK_LINE
$NOTIFY_EXTRA_LINE" >/dev/null 2>&1 || notify_rc=$?
t notify-union-unterminated-run-is-no-run 7 "$notify_rc"

t notify-last-run-is-the-last-complete-one "$NOTIFY_EXTRA_LINE" \
  "$(rehearsal_notify_last_run_from_log "$NOTIFY_TWO_RUN_LOG" | sed -n '2p')"

# Containment, read off the notifier's own count of what it swept: a fleet
# repository surviving in notify-repos.txt shows up here and nowhere else.
if rehearsal_notify_watch_set_is_from_log 2 "$NOTIFY_RUN_LOG"; then r1=contained; else r1=WRONG; fi
t notify-watch-set-is-the-two-sandboxes contained "$r1"
if rehearsal_notify_watch_set_is_from_log 2 \
    "${NOTIFY_RUN_LOG/sweep done — 2 repos,/sweep done — 7 repos,}"; then
  r1=WRONG
else
  r1=refused
fi
t notify-watch-set-fleet-leak-mutation-reds refused "$r1"

# The interlock, re-asserted: the union widens the watch set and never the
# work set.
if rehearsal_notify_work_registry_intact "$NOTIFY_WORK" "$NOTIFY_WORK" "$NOTIFY_WORK"; then
  r1=intact
else
  r1=WRONG
fi
t notify-work-registry-intact intact "$r1"
notify_rc=0
rehearsal_notify_work_registry_intact "$NOTIFY_WORK" "$NOTIFY_WORK" \
  "$NOTIFY_WORK
heavy-duty/crew" >/dev/null 2>&1 || notify_rc=$?
t notify-work-registry-moved-reds 5 "$notify_rc"
notify_rc=0
rehearsal_notify_work_registry_intact "$NOTIFY_WORK" \
  "$NOTIFY_WORK
heavy-duty/crew" "$NOTIFY_WORK
heavy-duty/crew" >/dev/null 2>&1 || notify_rc=$?
t notify-work-registry-already-wide-reds 6 "$notify_rc"

# The interlock's rule applied to the second file.
NOTIFY_PRE_DRILL="heavy-duty/crew
heavy-duty/ceremony"
if rehearsal_notify_candidate_is_safe "$NOTIFY_EXTRA" "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL"; then
  r1=safe
else
  r1=WRONG
fi
t notify-candidate-minted-sandbox-is-safe safe "$r1"
notify_rc=0
rehearsal_notify_candidate_is_safe not-a-slug "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL" >/dev/null 2>&1 || notify_rc=$?
t notify-candidate-malformed-refused 5 "$notify_rc"
notify_rc=0
rehearsal_notify_candidate_is_safe "$NOTIFY_WORK" "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL" >/dev/null 2>&1 || notify_rc=$?
t notify-candidate-work-sandbox-refused 6 "$notify_rc"
notify_out="$(rehearsal_notify_candidate_is_safe heavy-duty/ceremony "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL" 2>&1)"
notify_rc=$?
t notify-candidate-pre-drill-registry-refused 7 "$notify_rc"
case "$notify_out" in
  *"heavy-duty/ceremony is named in this host's pre-drill registry"*) r1=named ;;
  *) r1=missing ;;
esac
t notify-candidate-refusal-names-the-repo named "$r1"

# --- the leg, driven under a stubbed bx() ---------------------------------
NOTIFY_BX_CALLS="$TMP/rehearsal-notify-bx-calls"
NOTIFY_READS="$TMP/rehearsal-notify-work-reads"
NOTIFY_NOTIFY_READS="$TMP/rehearsal-notify-watch-reads"
# Box-side paths: these tildes are expanded by the BOX's login shell inside
# bx(), which is the whole reason the drill stores them unexpanded.
# shellcheck disable=SC2088
NOTIFY_BACKUP_PATH='~/duty/notify-repos.txt.pre-drill-99'
# shellcheck disable=SC2088
NOTIFY_WORK_BACKUP_PATH='~/duty/repos.txt.pre-drill-99'
notify_snap_reply() {  # $1 present|absent|<anything else = the box did not answer>, $2 contents
  case "$1" in
    present) printf 'present\n'; [ -n "$2" ] && printf '%s\n' "$2"; return 0 ;;
    absent)  printf 'absent\n'; return 0 ;;
    *)       return 255 ;;
  esac
}
notify_stub_bx() {  # $1 the box command, $2 how the second repos.txt read answers
  local n
  printf '%s\n' "$1" >>"$NOTIFY_BX_CALLS"
  case "$1" in
    *getMe*)               printf 'ok\n' ;;
    *fleet.defaults.conf*) printf 'state:needs-human\n' ;;
    # The interlock's backup of the work registry, read through the same
    # three-state snapshot as everything else — this is the read the notify
    # half's safety check is made of. Matched BEFORE the plain repos.txt read
    # below, whose pattern the snapshot's own `cat ~/duty/repos.txt.pre-drill-99`
    # would otherwise match first.
    *"-e ~/duty/repos.txt.pre-drill"*)
      notify_snap_reply "$NOTIFY_WORK_BACKUP_STATE" "$NOTIFY_WORK_BACKUP_TEXT" ;;
    *"cat ~/duty/repos.txt"*)
      n="$(( $(cat "$NOTIFY_READS") + 1 ))"
      printf '%s\n' "$n" >"$NOTIFY_READS"
      if [ "$n" -le 1 ] || [ "$NOTIFY_SECOND_READ" = same ]; then
        printf '%s\n' "$NOTIFY_WORK"
      else
        printf '%s\nheavy-duty/crew\n' "$NOTIFY_WORK"
      fi ;;
    # The three-state read of notify-repos.txt, answered as a real box would:
    # `present` with the contents, `present` alone for a file that exists and
    # is empty, `absent`, or a box that does not answer at all.
    #
    # Counted, because the leg reads this file on both sides of its own write:
    # reads 1 (the pre-drill capture) and 2 (the writer's absence probe) are
    # the pre-drill box, and the read-back in the restore check is the box
    # AFTER teardown. The stub restores nothing, so the default post state is a
    # file that is present and empty — which is exactly what the old
    # `cat … || true` read-back reported on every path, and what the two
    # capture cases below are asserting against.
    *"-e ~/duty/notify-repos.txt"*)
      n="$(( $(cat "$NOTIFY_NOTIFY_READS") + 1 ))"
      printf '%s\n' "$n" >"$NOTIFY_NOTIFY_READS"
      if [ "$n" -le 2 ]; then
        notify_snap_reply "$NOTIFY_PRE_STATE" "$NOTIFY_PRE_TEXT"
      else
        notify_snap_reply "$NOTIFY_POST_STATE" "$NOTIFY_POST_TEXT"
      fi ;;
    *) : ;;
  esac
}
notify_run_leg() {  # $1 how the post-write repos.txt read answers
  NOTIFY_SECOND_READ="$1"
  NOTIFY_PRE_STATE="${2:-present}"
  NOTIFY_PRE_TEXT="${3:-}"
  NOTIFY_WORK_BACKUP_STATE="${4:-present}"
  NOTIFY_WORK_BACKUP_TEXT="$NOTIFY_PRE_DRILL"
  NOTIFY_POST_STATE="${5:-present}"
  NOTIFY_POST_TEXT=""
  : >"$NOTIFY_BX_CALLS"
  printf '0\n' >"$NOTIFY_READS"
  printf '0\n' >"$NOTIFY_NOTIFY_READS"
  REHEARSAL_NOTIFY_BACKUP=""
  REHEARSAL_NOTIFY_ABSENT=0
  (
    REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    bx() { notify_stub_bx "$1"; }
    gh() { case "$1 $2" in "repo view") return 0 ;; *) return 2 ;; esac; }
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
    printf 'rc=%s\n' "$?"
  )
}

# Must fail: a leg that widened repos.txt reds and ABORTS — the interlock
# outranks the coverage, so the round never reaches the union it came for.
notify_out="$(notify_run_leg widened)"
t notify-widened-work-registry-aborts-the-round "rc=2" "$(tail -n 1 <<<"$notify_out")"
t notify-widened-work-registry-reds-by-name 1 \
  "$(grep -cF 'FAIL notify: repos.txt unchanged' <<<"$notify_out")"
t notify-widened-work-registry-never-reaches-the-union 0 \
  "$(grep -cF 'notify: both halves of the union' <<<"$notify_out")"
t notify-widened-work-registry-runs-no-notify-tick 0 \
  "$(grep -cF 'tick.sh notify' "$NOTIFY_BX_CALLS")"

# The same leg with a stable registry gets past the interlock and restores
# both files on the way out.
notify_out="$(notify_run_leg same)"
t notify-stable-work-registry-passes-the-interlock 1 \
  "$(grep -cF 'ok   notify: repos.txt unchanged' <<<"$notify_out")"
t notify-stable-work-registry-restores-both 1 \
  "$(grep -cF 'ok   notify: teardown restored both registries' <<<"$notify_out")"
t notify-write-replaces-the-fleet-notify-list 1 \
  "$(grep -cF "printf '%s\\n' '$NOTIFY_WORK-notify' > ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"

# A box that shipped a real notify-repos.txt is captured as those bytes, not
# as the empty string a `cat … || true` used to hand back. Proven where it
# matters: the leg's own restore comparison, whose stub puts nothing back, now
# NOTICES — under the old capture it compared "" against "" and passed.
notify_out="$(notify_run_leg same present 'heavy-duty/ceremony')"
t notify-pre-drill-capture-keeps-the-fleet-bytes 1 \
  "$(grep -cF 'FAIL notify: teardown restored both registries' <<<"$notify_out")"
notify_out="$(notify_run_leg same present)"
t notify-pre-drill-capture-empty-file-is-not-a-mismatch 1 \
  "$(grep -cF 'ok   notify: teardown restored both registries' <<<"$notify_out")"

# Must fail: the box stops answering when the leg reads notify-repos.txt back
# after its own restore. The pre-drill file here was present and EMPTY, which
# is the one shape the old `cat … || true` read-back could not tell from
# silence — "" compared equal to "" and the leg reported both registries
# restored, on a box nobody had heard from. The authoritative comparison is
# rehearsal_cleanup's, but this one runs where the leg can still report and it
# should not be the weaker read of the two (claude-bot, round 3).
notify_out="$(notify_run_leg same present '' present unanswerable)"
t notify-in-leg-restore-unanswerable-read-is-not-empty-bytes 1 \
  "$(grep -cF 'FAIL notify: teardown restored both registries' <<<"$notify_out")"
t notify-in-leg-restore-unanswerable-read-is-never-a-pass 0 \
  "$(grep -cF 'ok   notify: teardown restored both registries' <<<"$notify_out")"

# Must fail: the box does not answer when asked what notify-repos.txt held.
# The old read was `cat … 2>/dev/null || true`, so this arrived as empty bytes
# with CAPTURED=1 — and teardown then compared the restored fleet registry
# against "" and passed. Nothing may be written on this path: the absence
# branch of the probe is what licenses teardown's `rm -f`.
notify_out="$(notify_run_leg same unanswerable)"
t notify-unreadable-pre-drill-registry-reds 1 \
  "$(grep -cF 'FAIL notify: the box could not be asked what notify-repos.txt held before the drill' <<<"$notify_out")"
t notify-unreadable-pre-drill-registry-emits-no-ok-union 0 \
  "$(grep -cF 'notify: both halves of the union' <<<"$notify_out")"
t notify-unreadable-pre-drill-registry-writes-nothing 0 \
  "$(grep -cF "> ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"
t notify-unreadable-pre-drill-registry-runs-no-notify-tick 0 \
  "$(grep -cF 'tick.sh notify' "$NOTIFY_BX_CALLS")"

# Must fail: the guard that refuses fleet repositories cannot read the half of
# the host's watch set that the interlock put aside. The read was
# `cat $REPOS_BACKUP ~/duty/notify-repos.txt 2>/dev/null || true` with a caller
# that took the output and no status, so a missing or unreadable backup handed
# the check a SHORTER list at rc 0 — and a check that silently narrows to what
# it can still read is not the refusal the criterion asks for. Nothing may be
# written on this path: the refusal has to land before the registry write.
for notify_backup_state in unanswerable absent; do
  notify_out="$(notify_run_leg same present '' "$notify_backup_state")"
  t "notify-unvouched-work-backup-$notify_backup_state-reds" 1 \
    "$(grep -cF "FAIL notify: the host's pre-drill registries can be read before the notify half is chosen" <<<"$notify_out")"
  t "notify-unvouched-work-backup-$notify_backup_state-writes-nothing" 0 \
    "$(grep -cF "> ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"
  t "notify-unvouched-work-backup-$notify_backup_state-runs-no-notify-tick" 0 \
    "$(grep -cF 'tick.sh notify' "$NOTIFY_BX_CALLS")"
  t "notify-unvouched-work-backup-$notify_backup_state-emits-no-ok-union" 0 \
    "$(grep -cF 'notify: both halves of the union' <<<"$notify_out")"
  t "notify-unvouched-work-backup-$notify_backup_state-mints-no-second-sandbox-write" 0 \
    "$(grep -cF "printf '%s\\n' '$NOTIFY_WORK-notify' > ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"
done
# The round says which, in the verdict block below where the leg's own verdicts
# are read: notify-verdict-unvouched-work-backup-is-a-fail.

# The list the guard reads is really BOTH halves. A repository named only in
# the pre-drill repos.txt backup is refused as the notify candidate, which is
# the half a partial read used to drop.
notify_pre_drill_probe() {  # $1 candidate, $2 backup state, $3 handle: set|unset
  local cand="$1" state="$2" handle="${3:-set}" notify_pre
  (
    NOTIFY_PROBE_STATE="$state"
    REPOS_BACKUP=""
    [ "$handle" = set ] && REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    bx() {
      case "$1" in
        *"-e ~/duty/repos.txt.pre-drill"*) notify_snap_reply "$NOTIFY_PROBE_STATE" 'heavy-duty/rig' ;;
        *) return 255 ;;
      esac
    }
    if ! notify_pre="$(rehearsal_notify_pre_drill_registry 'heavy-duty/ceremony' 2>/dev/null)"; then
      printf 'refused\n'
      exit 0
    fi
    rehearsal_notify_candidate_is_safe "$cand" "$NOTIFY_WORK" "$notify_pre" >/dev/null 2>&1
    printf 'rc=%s\n' "$?"
  )
}
t notify-pre-drill-union-refuses-the-work-half "rc=7" \
  "$(notify_pre_drill_probe heavy-duty/rig present)"
t notify-pre-drill-union-refuses-the-notify-half "rc=7" \
  "$(notify_pre_drill_probe heavy-duty/ceremony present)"
t notify-pre-drill-union-passes-a-minted-sandbox "rc=0" \
  "$(notify_pre_drill_probe "$NOTIFY_EXTRA" present)"
t notify-pre-drill-union-refuses-to-answer-unvouched refused \
  "$(notify_pre_drill_probe heavy-duty/rig unanswerable)"
t notify-pre-drill-union-refuses-to-answer-when-the-backup-is-gone refused \
  "$(notify_pre_drill_probe heavy-duty/rig absent)"
t notify-pre-drill-union-refuses-to-answer-with-no-handle refused \
  "$(notify_pre_drill_probe heavy-duty/rig present unset)"
unset -f notify_pre_drill_probe

# The same refusal at the level of the writer itself, which is where the
# `rm -f` is decided: an unanswerable probe leaves no backup path behind, so
# teardown has nothing to restore and nothing to delete.
(
  bx() { return 255; }
  REHEARSAL_NOTIFY_ABSENT=0
  rehearsal_notify_write_registry "$NOTIFY_EXTRA" >/dev/null 2>&1
  printf 'rc=%s absent=%s backup=[%s]\n' \
    "$?" "$REHEARSAL_NOTIFY_ABSENT" "$REHEARSAL_NOTIFY_BACKUP"
) >"$TMP/notify-write-unanswerable"
t notify-write-unanswerable-probe-refuses 'rc=1 absent=0 backup=[]' \
  "$(cat "$TMP/notify-write-unanswerable")"

# --- the operator-channel preflight, against a stubbed Telegram -----------
#
# The preflight has two halves and they fail apart. `getMe` answers "is this
# token a bot"; what the leg needs is that the bot can reach the chat the
# engine actually sends to (`CHAT="$(cat "$HOME/.tg_chat_id")"`,
# shared/bin/notify.sh:64). Probing only the first meant a valid token on a
# missing, wrong, or inaccessible chat returned `ok`, staged both fixtures,
# and had its `(msg none)` deliveries graded as a LEG FAILURE — where #423
# says an unreachable operator channel is a named skip and nothing else
# (codex-bot, round 4).
#
# Driven by EXECUTING the box-side script under a fake HOME with `curl`
# shimmed, not by grepping its text: the question is which requests it makes
# and what it concludes from each answer. Still no network — the shim is on
# PATH ahead of the real binary and every reply is local.
NOTIFY_CHAN_HOME="$TMP/notify-channel-home"
NOTIFY_CHAN_SHIM="$TMP/notify-channel-shim"
NOTIFY_CHAN_CURL="$TMP/notify-channel-curl-calls"
mkdir -p "$NOTIFY_CHAN_HOME" "$NOTIFY_CHAN_SHIM"
cat >"$NOTIFY_CHAN_SHIM/curl" <<'NOTIFY_CURL_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NOTIFY_CHAN_CURL"
url=""
for arg in "$@"; do case "$arg" in https://*) url="$arg" ;; esac; done
case "$url" in
  *getMe*)   state="$NOTIFY_CHAN_GETME" ;;
  *getChat*) state="$NOTIFY_CHAN_GETCHAT" ;;
  *)         state=ok ;;
esac
case "$state" in
  transport) exit 7 ;;
  refused)   printf '{"ok":false,"description":"stub refusal"}\n' ;;
  *)         printf '{"ok":true,"result":{"id":-100200}}\n' ;;
esac
NOTIFY_CURL_STUB
chmod +x "$NOTIFY_CHAN_SHIM/curl"
export NOTIFY_CHAN_CURL
NOTIFY_CHAN_ID='-1002003004'
notify_channel_probe() {  # $1 token bytes|missing, $2 chat bytes|missing, $3 getMe, $4 getChat
  if [ "$1" = missing ]; then rm -f "$NOTIFY_CHAN_HOME/.tg_bot_token"
  else printf '%s' "$1" >"$NOTIFY_CHAN_HOME/.tg_bot_token"; fi
  if [ "$2" = missing ]; then rm -f "$NOTIFY_CHAN_HOME/.tg_chat_id"
  else printf '%s' "$2" >"$NOTIFY_CHAN_HOME/.tg_chat_id"; fi
  : >"$NOTIFY_CHAN_CURL"
  (
    export NOTIFY_CHAN_GETME="${3:-ok}" NOTIFY_CHAN_GETCHAT="${4:-ok}"
    bx() { HOME="$NOTIFY_CHAN_HOME" PATH="$NOTIFY_CHAN_SHIM:$PATH" bash -c "$1"; }
    rehearsal_notify_channel_status
  )
}

notify_chan="$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" ok ok)"
t notify-channel-token-and-chat-both-good ok "$notify_chan"
t notify-channel-probes-the-configured-chat 1 \
  "$(grep -cF "chat_id=$NOTIFY_CHAN_ID" "$NOTIFY_CHAN_CURL")"
t notify-channel-chat-probe-is-a-read 0 \
  "$(grep -cF sendMessage "$NOTIFY_CHAN_CURL")"

# The case the whole point turns on: the token is unimpeachable and the chat
# is not. `getMe` alone cannot tell this from a healthy channel.
notify_chan="$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" ok refused)"
t notify-channel-valid-token-unreachable-chat-is-not-ok chat-unreachable "$notify_chan"
t notify-channel-valid-token-unreachable-chat-asked-both 2 \
  "$(grep -c . "$NOTIFY_CHAN_CURL")"

# …and its converse, so the two reasons keep distinct subjects: a refused
# token is `rejected`, and the chat is never probed with a token already known
# to be bad.
notify_chan="$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" refused ok)"
t notify-channel-refused-token-is-rejected rejected "$notify_chan"
t notify-channel-refused-token-never-probes-the-chat 0 \
  "$(grep -cF getChat "$NOTIFY_CHAN_CURL")"

t notify-channel-transport-failure-is-unreachable unreachable \
  "$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" transport ok)"
t notify-channel-chat-transport-failure-is-unreachable unreachable \
  "$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" ok transport)"
t notify-channel-missing-token-is-no-credentials no-credentials \
  "$(notify_channel_probe missing "$NOTIFY_CHAN_ID" ok ok)"
t notify-channel-missing-chat-id-is-no-credentials no-credentials \
  "$(notify_channel_probe tok-abc missing ok ok)"

# A readable file holding nothing is not a credential: carried into the
# request it would have asked Telegram about the empty chat id and read the
# refusal as `chat-unreachable`, which names the wrong fault.
notify_chan="$(notify_channel_probe tok-abc "" ok ok)"
t notify-channel-empty-chat-id-is-no-credentials no-credentials "$notify_chan"
t notify-channel-empty-chat-id-asks-nothing 0 "$(grep -c . "$NOTIFY_CHAN_CURL")"
notify_chan="$(notify_channel_probe "" "$NOTIFY_CHAN_ID" ok ok)"
t notify-channel-empty-token-is-no-credentials no-credentials "$notify_chan"
t notify-channel-empty-token-asks-nothing 0 "$(grep -c . "$NOTIFY_CHAN_CURL")"
unset -f notify_channel_probe

# The new reason travels the same road as the old ones: a skip naming it, no
# ok row anywhere in the leg, and no tick.
notify_out="$(
  bx() { printf 'chat-unreachable\n'; }
  ok()   { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
  printf 'rc=%s\n' "$?"
)"
t notify-unreachable-chat-rc "rc=0" "$(tail -n 1 <<<"$notify_out")"
t notify-unreachable-chat-skips-with-its-reason 1 \
  "$(grep -cF 'skip notify: union over repos.txt and notify-repos.txt (operator channel unreachable on this host: chat-unreachable)' <<<"$notify_out")"
t notify-unreachable-chat-is-never-a-pass 0 "$(grep -c '^ok   ' <<<"$notify_out")"

# Must fail (recorded, not hidden): an unreachable channel is a visible skip
# naming the reason, and never an ok.
notify_out="$(
  bx() { printf 'no-credentials\n'; }
  ok()   { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
  printf 'rc=%s\n' "$?"
)"
t notify-unreachable-channel-rc "rc=0" "$(tail -n 1 <<<"$notify_out")"
t notify-unreachable-channel-skips-with-its-reason 1 \
  "$(grep -cF 'skip notify: union over repos.txt and notify-repos.txt (operator channel unreachable on this host: no-credentials)' <<<"$notify_out")"
t notify-unreachable-channel-is-never-a-pass 0 "$(grep -c '^ok   ' <<<"$notify_out")"

notify_out="$(
  bx() { printf 'ok\n'; }
  skip() { printf 'skip %s\n' "$1"; }
  REHEARSAL_NOTIFY_DRILL=0 rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
)"
t notify-opt-out-skips-the-leg 1 \
  "$(grep -cF 'skip notify: union over repos.txt and notify-repos.txt (--no-notify-drill)' <<<"$notify_out")"

# Restore is by pre-drill STATE, not by rewriting a default: a file the leg
# created is removed, one it replaced is moved back.
: >"$NOTIFY_BX_CALLS"
REHEARSAL_NOTIFY_BACKUP="$NOTIFY_BACKUP_PATH"
REHEARSAL_NOTIFY_ABSENT=1
bx() { printf '%s\n' "$1" >>"$NOTIFY_BX_CALLS"; }
rehearsal_notify_restore_registry
t notify-restore-removes-a-file-the-leg-created 1 \
  "$(grep -cF 'rm -f ~/duty/notify-repos.txt' "$NOTIFY_BX_CALLS")"
t notify-restore-clears-its-backup-handle "" "$REHEARSAL_NOTIFY_BACKUP"
: >"$NOTIFY_BX_CALLS"
REHEARSAL_NOTIFY_BACKUP="$NOTIFY_BACKUP_PATH"
REHEARSAL_NOTIFY_ABSENT=0
rehearsal_notify_restore_registry
t notify-restore-moves-the-pre-drill-file-back 1 \
  "$(grep -cF 'mv ~/duty/notify-repos.txt.pre-drill-99 ~/duty/notify-repos.txt' "$NOTIFY_BX_CALLS")"
: >"$NOTIFY_BX_CALLS"
REHEARSAL_NOTIFY_BACKUP=""
rehearsal_notify_restore_registry
t notify-restore-is-a-noop-when-the-leg-never-wrote 0 \
  "$(wc -l <"$NOTIFY_BX_CALLS" | tr -d ' ')"

# A handoff fixture is recorded by the CALLER, because the stager is read
# through a command substitution and a subshell's list would be lost exactly
# where a killed run needs it. Left open, these occupy the builder slot on a
# host whose gh identity is also the box's.
REHEARSAL_NOTIFY_FIXTURES=""
rehearsal_notify_record_fixture "$NOTIFY_WORK" "$NOTIFY_WORK_PR"
rehearsal_notify_record_fixture "$NOTIFY_EXTRA" "$NOTIFY_EXTRA_PR"
: >"$NOTIFY_BX_CALLS"
gh() { case "$1 $2" in "api -X") printf '%s\n' "$*" >>"$NOTIFY_BX_CALLS" ;; *) return 2 ;; esac; }
rehearsal_notify_close_fixtures
t notify-fixture-teardown-closes-both 2 "$(wc -l <"$NOTIFY_BX_CALLS" | tr -d ' ')"
t notify-fixture-teardown-closes-the-work-half 1 \
  "$(grep -cF "repos/$NOTIFY_WORK/pulls/$NOTIFY_WORK_PR" "$NOTIFY_BX_CALLS")"
t notify-fixture-teardown-closes-the-notify-half 1 \
  "$(grep -cF "repos/$NOTIFY_EXTRA/pulls/$NOTIFY_EXTRA_PR" "$NOTIFY_BX_CALLS")"
t notify-fixture-teardown-clears-the-list "" "$REHEARSAL_NOTIFY_FIXTURES"
: >"$NOTIFY_BX_CALLS"
rehearsal_notify_close_fixtures
t notify-fixture-teardown-is-idempotent 0 "$(wc -l <"$NOTIFY_BX_CALLS" | tr -d ' ')"
unset -f gh

# --- a fixture that exists survives whatever failed after it ---------------
#
# Two ways the round-4 review found an open handoff PR escaping the list that
# exists to close it (codex-bot):
#
#   1. the stager printed its number only after the label steps, so a label
#      application that failed returned empty — the caller recorded nothing
#      and the PR created a moment earlier was open with nobody holding it;
#   2. close_fixtures cleared the WHOLE list even when a PATCH failed, so the
#      EXIT pass inherited an empty list and retried nothing.
#
# Both are driven here with a gh stub that fails exactly one step.
NOTIFY_GH_CALLS="$TMP/notify-gh-calls"
NOTIFY_GH_PR_SEQ="$TMP/notify-gh-pr-seq"
NOTIFY_GH_FAIL_AT=""
NOTIFY_GH_CLOSE_FAIL=""
printf '0\n' >"$NOTIFY_GH_PR_SEQ"
notify_gh_stub() {
  local n
  printf '%s\n' "$*" >>"$NOTIFY_GH_CALLS"
  case "$*" in
    "repo view "*|"repo create "*) return 0 ;;
    *" -X PATCH "*)
      if [ -n "$NOTIFY_GH_CLOSE_FAIL" ]; then
        case "$*" in *"$NOTIFY_GH_CLOSE_FAIL"*) return 1 ;; esac
      fi
      return 0 ;;
    *git/ref/heads/main*) printf 'deadbeefdeadbeefdeadbeef\n'; return 0 ;;
    # Matched before the repository-level label creation below, whose pattern
    # is a prefix of this one.
    *issues/*/labels*)
      [ "$NOTIFY_GH_FAIL_AT" = label ] && return 1
      return 0 ;;
    *"/pulls -f title="*)
      n="$(( $(cat "$NOTIFY_GH_PR_SEQ") + 1 ))"
      printf '%s\n' "$n" >"$NOTIFY_GH_PR_SEQ"
      [ "$NOTIFY_GH_FAIL_AT" = create ] && return 1
      printf '%s\n' "$n"
      return 0 ;;
    *) return 0 ;;
  esac
}

# The stager itself: a number the caller can act on, and a status that still
# says the fixture is not usable as a notifiable event.
(
  NOTIFY_GH_FAIL_AT=label
  : >"$NOTIFY_GH_CALLS"
  printf '0\n' >"$NOTIFY_GH_PR_SEQ"
  gh() { notify_gh_stub "$@"; }
  notify_staged="$(rehearsal_notify_stage_handoff_pr owner/sandbox slug state:needs-human)"
  printf 'rc=%s pr=[%s]\n' "$?" "$notify_staged"
) >"$TMP/notify-stage-label-failure" 2>&1
t notify-stage-label-failure-still-yields-the-number 'rc=1 pr=[1]' \
  "$(cat "$TMP/notify-stage-label-failure")"
(
  NOTIFY_GH_FAIL_AT=create
  : >"$NOTIFY_GH_CALLS"
  printf '0\n' >"$NOTIFY_GH_PR_SEQ"
  gh() { notify_gh_stub "$@"; }
  notify_staged="$(rehearsal_notify_stage_handoff_pr owner/sandbox slug state:needs-human)"
  printf 'rc=%s pr=[%s]\n' "$?" "$notify_staged"
) >"$TMP/notify-stage-create-failure" 2>&1
t notify-stage-create-failure-has-nothing-to-track 'rc=1 pr=[]' \
  "$(cat "$TMP/notify-stage-create-failure")"

# The leg around it: a labelling failure grades the staging red AND closes the
# PR it created. Under the round-4 code the PATCH below never happened.
notify_stage_run() {  # $1 the gh step that fails, $2 the close that fails
  NOTIFY_SECOND_READ=same
  NOTIFY_PRE_STATE=present
  NOTIFY_PRE_TEXT=""
  NOTIFY_WORK_BACKUP_STATE=present
  NOTIFY_WORK_BACKUP_TEXT="$NOTIFY_PRE_DRILL"
  NOTIFY_POST_STATE=present
  NOTIFY_POST_TEXT=""
  : >"$NOTIFY_BX_CALLS"
  : >"$NOTIFY_GH_CALLS"
  printf '0\n' >"$NOTIFY_READS"
  printf '0\n' >"$NOTIFY_NOTIFY_READS"
  printf '0\n' >"$NOTIFY_GH_PR_SEQ"
  REHEARSAL_NOTIFY_BACKUP=""
  REHEARSAL_NOTIFY_ABSENT=0
  REHEARSAL_NOTIFY_FIXTURES=""
  (
    REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    NOTIFY_GH_FAIL_AT="${1:-}"
    NOTIFY_GH_CLOSE_FAIL="${2:-}"
    bx() { notify_stub_bx "$1"; }
    gh() { notify_gh_stub "$@"; }
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
    printf 'fixture-rows=%s\n' "$(grep -c . <<<"$REHEARSAL_NOTIFY_FIXTURES")"
    printf 'fixtures=[%s]\n' \
      "$(grep . <<<"$REHEARSAL_NOTIFY_FIXTURES" | paste -sd';' -)"
  )
}

notify_out="$(notify_stage_run label)"
t notify-fixture-unlabelled-pr-is-closed-by-the-leg 1 \
  "$(grep -cF "api -X PATCH repos/$NOTIFY_WORK/pulls/1 -f state=closed" "$NOTIFY_GH_CALLS")"
t notify-fixture-unlabelled-pr-in-the-notify-half-is-closed-too 1 \
  "$(grep -cF "api -X PATCH repos/$NOTIFY_EXTRA/pulls/2 -f state=closed" "$NOTIFY_GH_CALLS")"
t notify-fixture-unlabelled-pr-leaves-nothing-open 'fixture-rows=0' \
  "$(grep -F 'fixture-rows=' <<<"$notify_out")"

# A PR that was never created is not tracked and not closed: the list holds
# objects that exist, and nothing else.
notify_out="$(notify_stage_run create)"
t notify-fixture-uncreated-pr-is-never-closed 0 \
  "$(grep -cF 'api -X PATCH' "$NOTIFY_GH_CALLS")"
t notify-fixture-uncreated-pr-is-not-tracked 'fixture-rows=0' \
  "$(grep -F 'fixture-rows=' <<<"$notify_out")"

# A close that failed leaves its row behind for the EXIT pass, which is the
# only thing that can still retry it.
notify_out="$(notify_stage_run "" "pulls/2")"
t notify-fixture-failed-close-survives-the-leg 'fixture-rows=1' \
  "$(grep -F 'fixture-rows=' <<<"$notify_out")"
t notify-fixture-failed-close-survives-by-name "fixtures=[$NOTIFY_EXTRA 2]" \
  "$(grep -F 'fixtures=' <<<"$notify_out")"

# …and the retry itself, at the level of the closer: the row that failed is
# re-attempted and the rows that closed are not re-closed.
REHEARSAL_NOTIFY_FIXTURES=""
rehearsal_notify_record_fixture "$NOTIFY_WORK" "$NOTIFY_WORK_PR"
rehearsal_notify_record_fixture "$NOTIFY_EXTRA" "$NOTIFY_EXTRA_PR"
: >"$NOTIFY_GH_CALLS"
NOTIFY_GH_CLOSE_FAIL="pulls/$NOTIFY_EXTRA_PR"
gh() { notify_gh_stub "$@"; }
rehearsal_notify_close_fixtures 2>/dev/null
notify_close_rc=$?
t notify-fixture-failed-close-is-reported 1 "$notify_close_rc"
t notify-fixture-failed-close-stays-on-the-list "$NOTIFY_EXTRA $NOTIFY_EXTRA_PR" \
  "$(grep . <<<"$REHEARSAL_NOTIFY_FIXTURES")"
: >"$NOTIFY_GH_CALLS"
NOTIFY_GH_CLOSE_FAIL=""
rehearsal_notify_close_fixtures 2>/dev/null
t notify-fixture-failed-close-is-retried 1 \
  "$(grep -cF "repos/$NOTIFY_EXTRA/pulls/$NOTIFY_EXTRA_PR" "$NOTIFY_GH_CALLS")"
t notify-fixture-retry-does-not-reclose-the-closed-half 0 \
  "$(grep -cF "repos/$NOTIFY_WORK/pulls/$NOTIFY_WORK_PR" "$NOTIFY_GH_CALLS")"
t notify-fixture-retry-empties-the-list "" "$REHEARSAL_NOTIFY_FIXTURES"
unset -f gh notify_stage_run

# Both registries in ONE step: rehearsal_cleanup restores the notify half too,
# so an abnormal exit cannot leave a box watching a torn-down sandbox.
: >"$NOTIFY_BX_CALLS"
(
  # shellcheck source=drill/rehearsal-safety.sh
  source "$ROOT/drill/rehearsal-safety.sh"
  BOX_NAME=crew-drill-reviewer
  REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
  REHEARSAL_NOTIFY_BACKUP="$NOTIFY_BACKUP_PATH"
  REHEARSAL_NOTIFY_ABSENT=0
  bx() { printf '%s\n' "$1" >>"$NOTIFY_BX_CALLS"; }
  rehearsal_cleanup 0
) >/dev/null 2>&1
t notify-cleanup-restores-the-notify-registry 1 \
  "$(grep -cF 'mv ~/duty/notify-repos.txt.pre-drill-99 ~/duty/notify-repos.txt' "$NOTIFY_BX_CALLS")"
t notify-cleanup-still-restores-the-work-registry 1 \
  "$(grep -cF 'mv ~/duty/repos.txt.pre-drill-99 ~/duty/repos.txt' "$NOTIFY_BX_CALLS")"
# The leg writes its OWN verdict where the round summary reads it — the first
# review round found the summary reading the ROLE's exit code, which is 0 both
# for a union asserted and for a channel-unreachable skip (#423).
NOTIFY_STATUS_FILE="$TMP/notify-verdicts"
REHEARSAL_NOTIFY_STATUS="$NOTIFY_STATUS_FILE"
notify_leg_verdicts() {  # $1 how the post-write repos.txt read answers
  NOTIFY_SECOND_READ="$1"
  NOTIFY_PRE_STATE="${2:-present}"
  NOTIFY_PRE_TEXT="${3:-}"
  NOTIFY_WORK_BACKUP_STATE="${4:-present}"
  NOTIFY_WORK_BACKUP_TEXT="$NOTIFY_PRE_DRILL"
  NOTIFY_POST_STATE=present
  NOTIFY_POST_TEXT=""
  : >"$NOTIFY_BX_CALLS"
  : >"$NOTIFY_STATUS_FILE"
  printf '0\n' >"$NOTIFY_READS"
  printf '0\n' >"$NOTIFY_NOTIFY_READS"
  REHEARSAL_NOTIFY_BACKUP=""
  REHEARSAL_NOTIFY_ABSENT=0
  REHEARSAL_NOTIFY_CAPTURED=0
  (
    ROLE=reviewer
    REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    bx() { notify_stub_bx "$1"; }
    gh() { case "$1 $2" in "repo view") return 0 ;; *) return 2 ;; esac; }
    ok() { :; }; fail() { :; }; skip() { :; }
    rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
  )
  cat "$NOTIFY_STATUS_FILE"
}
notify_out="$(notify_leg_verdicts widened)"
t notify-verdict-widened-registry-is-a-fail 1 \
  "$(grep -cF 'reviewer fail repos.txt widened while the union was being staged' <<<"$notify_out")"
t notify-verdict-widened-registry-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"
notify_out="$(notify_leg_verdicts same)"
t notify-verdict-unstageable-fixture-is-a-fail 1 \
  "$(grep -cF "reviewer fail the repos.txt half's handoff fixture could not be staged" <<<"$notify_out")"
t notify-verdict-unstageable-fixture-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"
# A box that will not say what its notify-repos.txt held is a fail, not a
# silent empty capture that teardown then vouches for.
notify_out="$(notify_leg_verdicts same unanswerable)"
t notify-verdict-unreadable-pre-drill-registry-is-a-fail 1 \
  "$(grep -cF 'reviewer fail the pre-drill notify-repos.txt could not be read' <<<"$notify_out")"
t notify-verdict-unreadable-pre-drill-registry-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"
# ...and so is a box that will not say what the interlock put aside: the guard
# on the notify half cannot run, so the leg stops and the round says why rather
# than reporting a leg that simply passed.
notify_out="$(notify_leg_verdicts same present '' unanswerable)"
t notify-verdict-unvouched-work-backup-is-a-fail 1 \
  "$(grep -cF "reviewer fail the host's pre-drill work registry could not be read; the notify half was never written" <<<"$notify_out")"
t notify-verdict-unvouched-work-backup-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"

unset -f bx notify_stub_bx notify_run_leg notify_union notify_leg_verdicts

# --- wiring: where the leg runs, and what clears up after it --------------
# shellcheck disable=SC2016  # match the literal source line in rehearsal.sh
if grep -Fq '. "$ROOT/drill/rehearsal-notify.sh"' "$ROOT/drill/rehearsal.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-helper-sourced-in-rehearsal wired "$notify_wiring"
# Positional, because "after the safety interlock and before the role blocks"
# is the criterion: the call has to sit between the interlock's last ok and
# the first thing phase 2 does with a tick.
# shellcheck disable=SC2016  # match the literal call in rehearsal.sh
notify_interlock_block="$(sed -n '/ok "safety interlock: no attention demand parked outside the sandbox"/,/-- attention wake --/p' \
    "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match the literal call in rehearsal.sh
if grep -Fq 'rehearsal_notify_drill "$SANDBOX"' <<<"$notify_interlock_block"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-leg-called-after-the-interlock wired "$notify_wiring"
# shellcheck disable=SC2016  # match the literal call site in rehearsal.sh
notify_call_block="$(sed -n '/rehearsal_notify_drill "\$SANDBOX"/,/^  fi$/p' "$ROOT/drill/rehearsal.sh")"
if grep -Fq 'exit 1' <<<"$notify_call_block"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-abort-return-stops-the-round wired "$notify_wiring"
if grep -Fq -- '--no-notify-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'notify  (repos.txt + notify-repos.txt union)' "$ROOT/drill/rehearsal-all.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-all-opt-out-and-summary-wired wired "$notify_wiring"
# shellcheck disable=SC2016  # match teardown.sh's literal role-expansion text
if grep -Fq 'crew-drill-%s-notify' "$ROOT/drill/teardown.sh" \
    && grep -Fq 'crew-drill-$role-notify' "$ROOT/drill/teardown.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-second-sandbox-torn-down wired "$notify_wiring"
# shellcheck disable=SC2016  # match the literal guard in rehearsal.sh
if grep -Fq 'rehearsal_notify_close_fixtures' "$ROOT/drill/rehearsal.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-fixtures-closed-on-every-exit-path wired "$notify_wiring"
# The handoff label is the engine's, never retyped in the drill.
t notify-handoff-label-not-retyped-in-drill 0 \
  "$(grep -R -F 'state:needs-human' "$ROOT/drill" | wc -l | tr -d ' ')"

# --- the leg's own verdict, and the round summary that reads it (#423) -----
#
# The first review round found that rehearsal-all.sh read the leg's outcome
# off rehearsal.sh's exit code, which is 0 for a union asserted AND for a
# channel-unreachable skip — so a round that asserted nothing reported
# `ok notify`, and a role that failed elsewhere reported `FAIL notify`. The
# leg now writes its own verdict; these drive both halves.
: >"$NOTIFY_STATUS_FILE"

# The pure fold, first: worst wins across the roles that wrote a line.
t notify-verdict-fold-ok "ok both halves on one tick" \
  "$(rehearsal_notify_worst_verdict 'reviewer ok both halves on one tick')"
t notify-verdict-fold-skip-outranks-ok "skip operator channel unreachable: no-credentials" \
  "$(rehearsal_notify_worst_verdict 'triage ok both halves on one tick
reviewer skip operator channel unreachable: no-credentials')"
t notify-verdict-fold-fail-outranks-skip "fail the union was not delivered on one tick" \
  "$(rehearsal_notify_worst_verdict 'triage skip operator channel unreachable: no-credentials
reviewer fail the union was not delivered on one tick')"
t notify-verdict-fold-fail-outranks-a-later-ok "fail the union was not delivered on one tick" \
  "$(rehearsal_notify_worst_verdict 'triage fail the union was not delivered on one tick
reviewer ok both halves on one tick')"
# No line at all is not a verdict: the summary must not be able to read one.
if rehearsal_notify_worst_verdict '' >/dev/null 2>&1; then fold_out='a verdict'; else fold_out=none; fi
t notify-verdict-fold-empty-is-no-verdict none "$fold_out"
# A token the summary cannot classify grades as fail, never as a pass.
t notify-verdict-fold-unreadable-token-is-a-fail "fail wat" \
  "$(rehearsal_notify_worst_verdict 'reviewer sideways wat')"

# The two the round summary turns on: an unreachable channel, and the opt-out.
: >"$NOTIFY_STATUS_FILE"
(
  ROLE=reviewer
  bx() { printf 'no-credentials\n'; }
  ok() { :; }; fail() { :; }; skip() { :; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
)
t notify-verdict-unreachable-channel-is-a-skip-naming-it \
  "reviewer skip operator channel unreachable: no-credentials" \
  "$(cat "$NOTIFY_STATUS_FILE")"
: >"$NOTIFY_STATUS_FILE"
(
  REHEARSAL_NOTIFY_DRILL=0
  ROLE=reviewer
  bx() { :; }
  ok() { :; }; fail() { :; }; skip() { :; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
)
t notify-verdict-opt-out-is-an-announced-skip "reviewer skip --no-notify-drill" \
  "$(cat "$NOTIFY_STATUS_FILE")"

# The aggregation, executable: a real rehearsal-all.sh with stubbed siblings.
AGG="$TMP/notify-agg"
mkdir -p "$AGG"
cp "$ROOT/drill/rehearsal-all.sh" "$ROOT/drill/rehearsal-notify.sh" \
  "$ROOT/drill/rehearsal-verdict.sh" \
  "$ROOT/drill/rehearsal-hygiene.sh" "$ROOT/drill/rehearsal-breaker.sh" "$AGG/"
cat >"$AGG/rehearsal.sh" <<'AGGSH'
#!/usr/bin/env bash
# Stub role drill: writes the verdict the case asked for — the way the leg
# does, into REHEARSAL_NOTIFY_STATUS — and exits with the case's rc. The two
# are independent on purpose: that independence is what is under test.
role=""
while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) shift ;; esac; done
v="$(cat "$AGG_DIR/$role.verdict" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_NOTIFY_STATUS"
v="$(cat "$AGG_DIR/$role.resume" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_RESUME_STATUS"
exit "$(cat "$AGG_DIR/$role.rc" 2>/dev/null || echo 0)"
AGGSH
printf '#!/usr/bin/env bash\nexit 0\n' >"$AGG/teardown.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$AGG/rehearsal-app.sh"
chmod +x "$AGG/rehearsal.sh" "$AGG/teardown.sh" "$AGG/rehearsal-app.sh"
agg_case() {  # $1 role, $2 notify verdict, $3 rc, $4 resume verdict
  printf '%s' "$2" >"$AGG/$1.verdict"
  printf '%s\n' "$3" >"$AGG/$1.rc"
  printf '%s' "${4:-}" >"$AGG/$1.resume"
}
agg_run() {  # $1 roles, then extra flags
  local roles="$1"; shift
  # Every sibling leg the notify fold is not under test with is switched off,
  # --no-hygiene-drill (#422), --no-breaker-drill (#424),
  # --no-attention-drill (#440) and --no-attention-audit-drill (#441)
  # included: these
  # cases assert what the NOTIFY
  # verdict does to `overall`, and a neighbour's row moving it would red them
  # for a reason that is not theirs. The composition of the two folds gets its
  # own case below, with the hygiene leg deliberately left on.
  AGG_DIR="$AGG" bash "$AGG/rehearsal-all.sh" --roles "$roles" \
    --no-app --no-config-drill --no-install-drill --no-resume-drill \
    --no-attention-drill --no-attention-audit-drill \
    --no-hygiene-drill --no-breaker-drill ${1+"$@"} 2>&1
}

# The breaker has its own enabled/incomplete partition: an enabled leg that no
# role reached is INCOMPLETE and cannot leave a green exit status, while the
# operator's explicit opt-out remains an announced green skip.
agg_breaker_run() {
  AGG_DIR="$AGG" bash "$AGG/rehearsal-all.sh" --roles '' \
    --no-app --no-config-drill --no-install-drill --no-resume-drill \
    --no-attention-drill --no-attention-audit-drill \
    --no-hygiene-drill --no-notify-drill ${1+"$@"} 2>&1
}
if agg_out="$(agg_breaker_run)"; then agg_rc=0; else agg_rc=$?; fi
t breaker-agg-enabled-no-role-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE breaker  (no role reached a box)' <<<"$agg_out")"
t breaker-agg-enabled-no-role-rc 2 "$agg_rc"
if agg_out="$(agg_breaker_run --no-breaker-drill)"; then agg_rc=0; else agg_rc=$?; fi
t breaker-agg-opt-out-is-an-announced-skip 1 \
  "$(grep -cF 'skip       breaker  (--no-breaker-drill)' <<<"$agg_out")"
t breaker-agg-opt-out-rc 0 "$agg_rc"

# The criterion: an unreachable operator channel produces a skip naming it and
# NEVER a pass — in the round summary too, which is where a round's verdict is
# actually read. The role exits 0, exactly as it did when this reported `ok`.
agg_case reviewer 'skip operator channel unreachable: no-credentials' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-unreachable-channel-emits-no-ok-row 0 \
  "$(grep -c 'ok         notify' <<<"$agg_out")"
t notify-agg-unreachable-channel-names-the-reason 1 \
  "$(grep -cF 'INCOMPLETE notify  (leg skipped: operator channel unreachable: no-credentials — union UNPROVEN)' <<<"$agg_out")"
t notify-agg-unreachable-channel-is-not-a-green-round 2 "$agg_rc"

# The union actually asserted is the one thing that prints `ok notify`.
agg_case reviewer 'ok both halves on one tick' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-asserted-union-is-a-pass 1 \
  "$(grep -cF 'ok         notify  (repos.txt + notify-repos.txt union)' <<<"$agg_out")"
t notify-agg-asserted-union-rc 0 "$agg_rc"

# The inverse conflation: a role that failed for its own reasons must not be
# able to red the notify row, and must not hide the leg's own pass.
agg_case triage '' 1
agg_case reviewer 'ok both halves on one tick' 0
if agg_out="$(agg_run "triage reviewer")"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-unrelated-role-failure-is-not-a-notify-fail 0 \
  "$(grep -c 'FAIL       notify' <<<"$agg_out")"
t notify-agg-unrelated-role-failure-keeps-the-leg-pass 1 \
  "$(grep -c 'ok         notify' <<<"$agg_out")"
t notify-agg-unrelated-role-failure-still-reds-its-role 1 \
  "$(grep -c 'FAIL       triage' <<<"$agg_out")"
t notify-agg-unrelated-role-failure-rc 1 "$agg_rc"

# And the other direction: the leg's own failure reds the round even where
# every role exited 0 — under the old wiring this printed `ok notify`.
agg_case triage '' 0
agg_case reviewer 'fail the union was not delivered on one tick (rc 5)' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-leg-failure-reds-the-round 1 \
  "$(grep -cF 'FAIL       notify  (the union was not delivered on one tick (rc 5))' <<<"$agg_out")"
t notify-agg-leg-failure-rc 1 "$agg_rc"

# No verdict at all is phase 2 never reaching the leg: INCOMPLETE, never ok.
agg_case reviewer '' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-no-verdict-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE notify  (phase 2 never reached the leg — union UNPROVEN)' <<<"$agg_out")"
t notify-agg-no-verdict-emits-no-ok-row 0 "$(grep -c 'ok         notify' <<<"$agg_out")"
t notify-agg-no-verdict-rc 2 "$agg_rc"
agg_case reviewer '' 1
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-no-box-reached-says-so 1 \
  "$(grep -cF 'INCOMPLETE notify  (no role reached a box — union UNPROVEN)' <<<"$agg_out")"

# The announced omission stays a skip and keeps the round green: an operator
# who says their host has no channel gets a clean round; nobody else does.
agg_case reviewer '' 0
if agg_out="$(agg_run reviewer --no-notify-drill)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-opt-out-is-an-announced-skip 1 \
  "$(grep -cF 'skip       notify  (--no-notify-drill)' <<<"$agg_out")"
t notify-agg-opt-out-rc 0 "$agg_rc"

# ...but the flag switches off the notify VERDICT, not the round. With the
# leg's verdict as its only escalation route, a teardown that left the wrong
# bytes disappeared under --no-notify-drill; the role's own rc has to carry
# it, which is what cleanup_all's `exit "$rc"` restores.
agg_case reviewer '' 1
if agg_out="$(agg_run reviewer --no-notify-drill)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-opt-out-still-reds-a-failed-role 1 "$(grep -c '^## *FAIL *reviewer' <<<"$agg_out")"
t notify-agg-opt-out-failed-role-rc 1 "$agg_rc"

# The resume fold uses the same executable aggregator, with the other legs
# opted out so every mutation below grades the resume row alone.
resume_agg_run() {  # $1 roles, then extra flags
  local roles="$1"; shift
  AGG_DIR="$AGG" bash "$AGG/rehearsal-all.sh" --roles "$roles" \
    --no-app --no-config-drill --no-install-drill --no-hygiene-drill \
    --no-attention-drill --no-attention-audit-drill \
    --no-breaker-drill --no-notify-drill ${1+"$@"} 2>&1
}

# Reported defect: the builder leg skipped while the role exited 0. The row
# must name the omission and the round must be incomplete, never `ok resume`.
agg_case builder '' 0 'skip builder fixture PR unavailable'
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-unavailable-fixture-emits-no-ok-row 0 \
  "$(grep -c 'ok         resume' <<<"$agg_out")"
t resume-agg-unavailable-fixture-names-row 1 \
  "$(grep -cF 'INCOMPLETE resume  (leg skipped: builder fixture PR unavailable)' <<<"$agg_out")"
t resume-agg-unavailable-fixture-rc 2 "$agg_rc"

# The inverse: an unrelated builder assertion can red its role without
# rewriting a successful resume verdict as `FAIL resume`.
agg_case builder '' 1 'ok wake + zero-action stop'
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-unrelated-builder-failure-emits-no-resume-fail 0 \
  "$(grep -c 'FAIL       resume' <<<"$agg_out")"
t resume-agg-unrelated-builder-failure-keeps-resume-ok 1 \
  "$(grep -cF 'ok         resume  (wake + zero-action stop)' <<<"$agg_out")"
t resume-agg-unrelated-builder-failure-still-reds-round 1 "$agg_rc"

# Missing, malformed, and omitted verdicts cover the remaining enabled rows.
agg_case builder '' 0
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-no-verdict-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE resume  (builder phase 2 never reached the leg)' <<<"$agg_out")"
t resume-agg-no-verdict-rc 2 "$agg_rc"
agg_case builder '' 0 'sideways unreadable'
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-unreadable-token-is-fail 1 \
  "$(grep -cF 'FAIL       resume  (unreadable)' <<<"$agg_out")"
t resume-agg-unreadable-token-rc 1 "$agg_rc"
agg_case triage '' 0
if agg_out="$(resume_agg_run triage)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-builder-omitted-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE resume  (builder role omitted)' <<<"$agg_out")"
t resume-agg-builder-omitted-rc 2 "$agg_rc"
agg_case builder '' 0
if agg_out="$(resume_agg_run builder --no-resume-drill)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-opt-out-is-the-only-skip-row 1 \
  "$(grep -cF 'skip       resume  (--no-resume-drill)' <<<"$agg_out")"
t resume-agg-opt-out-rc 0 "$agg_rc"

# --- the two legs' folds compose, they do not overwrite each other (#422) --
#
# #422's hygiene leg and this one both fold a verdict into the same `overall`,
# in that order. Both are worst-wins, so neither may talk the other's failure
# back down to a pass — an `ok notify` beside a red hygiene round must still
# exit 1, and a red notify leg beside a hygiene round that says nothing must
# still exit 1. `agg_run` above switches the sibling off precisely so this is
# the one place the interaction is asserted rather than assumed.
agg_hygiene_run() {  # $1 roles, $2 the hygiene result the role box records
  local roles="$1" hyg="$2"
  AGG_DIR="$AGG" AGG_HYGIENE="$hyg" bash "$AGG/rehearsal-all.sh" --roles "$roles" \
    --no-app --no-config-drill --no-install-drill --no-resume-drill \
    --no-attention-drill --no-attention-audit-drill --no-breaker-drill 2>&1
}
# The stub writes the hygiene result the way the live leg does — into the file
# rehearsal-all.sh hands it, per role — on top of the notify verdict it already
# writes. The two channels stay independent, which is the property under test.
cat >"$AGG/rehearsal.sh" <<'AGGSH'
#!/usr/bin/env bash
role=""
while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) shift ;; esac; done
v="$(cat "$AGG_DIR/$role.verdict" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_NOTIFY_STATUS"
[ -z "${AGG_HYGIENE:-}" ] || printf '%s\n' "$AGG_HYGIENE" >"$REHEARSAL_HYGIENE_RESULT_FILE"
exit "$(cat "$AGG_DIR/$role.rc" 2>/dev/null || echo 0)"
AGGSH
chmod +x "$AGG/rehearsal.sh"

agg_case reviewer 'ok both halves on one tick' 0
if agg_out="$(agg_hygiene_run reviewer 1)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-hygiene-failure-does-not-clear-the-round 1 "$agg_rc"
t notify-agg-hygiene-failure-keeps-the-notify-pass 1 \
  "$(grep -c 'ok         notify' <<<"$agg_out")"

agg_case reviewer 'fail the notify-repos.txt half never arrived' 0
if agg_out="$(agg_hygiene_run reviewer 0)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-hygiene-pass-does-not-clear-the-notify-failure 1 "$agg_rc"
t notify-agg-hygiene-pass-keeps-the-notify-fail-row 1 \
  "$(grep -c 'FAIL       notify' <<<"$agg_out")"

# Both legs mint a temp file per round and bash keeps exactly ONE EXIT handler,
# so a second `trap … EXIT` here would silently replace the first and leak the
# losing leg's file every round. One handler; it removes both.
t notify-all-installs-one-exit-trap 1 \
  "$(grep -c '^trap .* EXIT$' "$ROOT/drill/rehearsal-all.sh")"
# shellcheck disable=SC2016  # the handler line is deliberately literal
if grep -Fq 'rm -f -- "$NOTIFY_STATUS"' "$ROOT/drill/rehearsal-all.sh"; then
  r1=removed
else
  r1=LEAKED
fi
t notify-status-file-removed-by-the-one-exit-handler removed "$r1"
AGG_TRAP_MUTATED="$TMP/rehearsal-all-two-traps.sh"
# shellcheck disable=SC2016  # deliberate literal mutation of the handler body
sed '/rm -f -- "\$NOTIFY_STATUS"/d' "$ROOT/drill/rehearsal-all.sh" >"$AGG_TRAP_MUTATED"
# shellcheck disable=SC2016  # the removed line is deliberately literal
if grep -Fq 'rm -f -- "$NOTIFY_STATUS"' "$AGG_TRAP_MUTATED"; then
  r1=FALSE_PASS
else
  r1=red
fi
t notify-status-left-unremoved-reds red "$r1"

# Restore the plain stub for anything downstream that drives it.
cat >"$AGG/rehearsal.sh" <<'AGGSH'
#!/usr/bin/env bash
role=""
while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) shift ;; esac; done
v="$(cat "$AGG_DIR/$role.verdict" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_NOTIFY_STATUS"
exit "$(cat "$AGG_DIR/$role.rc" 2>/dev/null || echo 0)"
AGGSH
chmod +x "$AGG/rehearsal.sh"

# --- teardown compares BOTH registries against their pre-drill bytes ------
#
# A restore that exits 0 having moved the wrong bytes leaves the box working
# or watching a set nobody chose, while the round reports a clean teardown.
# So the comparison is after both restores, and it controls the verdict.
# Driven in its own process rather than a (..) group: rehearsal_cleanup reads
# BOX_NAME and REPOS_BACKUP from the round's scope, and a fixture that shadows
# them in a subshell makes every one of those reads a subshell read.
CLEANUP_DRIVER="$TMP/notify-cleanup-driver.sh"
#
# The stub answers as a box does, in three states and not two: `present` with
# the contents, `absent`, or nothing at all because the box has gone away. The
# last one is what round 2 was about — it used to read as "there was no
# backup", and the comparison then returned success having compared nothing.
cat >"$CLEANUP_DRIVER" <<'CLEANSH'
#!/usr/bin/env bash
set -uo pipefail
. "$ROOT/drill/rehearsal-notify.sh"
. "$ROOT/drill/rehearsal-safety.sh"
BOX_NAME=fixture
REPOS_BACKUP='~/duty/repos.txt.pre-drill-99'
# Whether this round's `cp` actually ran. The handle above is set BEFORE that
# copy in rehearsal_begin_isolation, so it is not the same fact and the case
# chooses it separately.
REHEARSAL_BACKUP_TAKEN="$CLEAN_BACKUP_TAKEN"
REHEARSAL_NOTIFY_BACKUP="$CLEAN_NOTIFY_BACKUP"
# After the sources: sourcing rehearsal-notify.sh resets these to their
# start-of-round defaults, which is the state the case is choosing.
REHEARSAL_NOTIFY_CAPTURED="$CLEAN_CAPTURED"
REHEARSAL_NOTIFY_ABSENT="$CLEAN_ABSENT"
REHEARSAL_NOTIFY_PRE_TEXT="$CLEAN_NOTIFY_PRE"
rehearsal_disarm_cron() { return 0; }
snap_reply() {  # $1 present|absent|unanswerable, $2 the contents
  case "$1" in
    present) printf 'present\n'; [ -n "$2" ] && printf '%s\n' "$2"; return 0 ;;
    absent)  printf 'absent\n'; return 0 ;;
    *)       return 255 ;;
  esac
}
bx() {
  case "$1" in
    # The restores, matched before the probes: their command names the same
    # paths, and what a case is choosing there is whether the mv/rm worked.
    *"mv ~/duty/repos.txt.pre-drill"*)        return "$CLEAN_REPOS_RESTORE_RC" ;;
    *"mv ~/duty/notify-repos.txt.pre-drill"*) return "$CLEAN_NOTIFY_RESTORE_RC" ;;
    *"rm -f ~/duty/notify-repos.txt"*)        return "$CLEAN_NOTIFY_RESTORE_RC" ;;
    *"-e ~/duty/repos.txt.pre-drill"*) snap_reply "$CLEAN_BACKUP_STATE" "$CLEAN_REPOS_PRE" ;;
    *"-e ~/duty/notify-repos.txt"*)    snap_reply "$CLEAN_NOTIFY_STATE" "$CLEAN_NOTIFY_AFTER" ;;
    *"-e ~/duty/repos.txt"*)           snap_reply "$CLEAN_REPOS_STATE" "$CLEAN_REPOS_AFTER" ;;
    *) return 0 ;;
  esac
}
rehearsal_cleanup "$1"
printf 'rc=%s\n' "$?"
CLEANSH
export ROOT CLEAN_BACKUP_STATE CLEAN_REPOS_PRE CLEAN_REPOS_STATE CLEAN_REPOS_AFTER
export CLEAN_NOTIFY_STATE CLEAN_NOTIFY_AFTER CLEAN_CAPTURED CLEAN_ABSENT CLEAN_NOTIFY_PRE
export CLEAN_REPOS_RESTORE_RC CLEAN_NOTIFY_RESTORE_RC CLEAN_NOTIFY_BACKUP
export REHEARSAL_NOTIFY_STATUS CLEAN_BACKUP_TAKEN
CLEANUP_VERDICTS="$TMP/notify-cleanup-verdicts"
cleanup_run() {  # $1 rc handed in
  REHEARSAL_NOTIFY_STATUS="$CLEANUP_VERDICTS"
  : >"$CLEANUP_VERDICTS"
  bash "$CLEANUP_DRIVER" "$1" 2>&1
}
CLEAN_BACKUP_STATE=present
CLEAN_BACKUP_TAKEN=1
CLEAN_REPOS_PRE='owner/one
owner/two'
CLEAN_REPOS_STATE=present
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"
CLEAN_REPOS_RESTORE_RC=0
CLEAN_NOTIFY_STATE=present
CLEAN_NOTIFY_AFTER='owner/watched'
CLEAN_NOTIFY_RESTORE_RC=0
CLEAN_NOTIFY_BACKUP=''
CLEAN_CAPTURED=1
CLEAN_ABSENT=0
CLEAN_NOTIFY_PRE='owner/watched'
clean_out="$(cleanup_run 0)"
t notify-cleanup-matching-registries-pass "rc=0" "$(tail -n 1 <<<"$clean_out")"
# Only ever worsens: an rc it was handed survives a clean comparison.
t notify-cleanup-passes-the-handed-rc-through "rc=2" "$(tail -n 1 <<<"$(cleanup_run 2)")"

# Must fail: the work registry restored with the wrong bytes.
CLEAN_REPOS_AFTER='owner/one'
clean_out="$(cleanup_run 0)"
t notify-cleanup-wrong-work-registry-bytes-red "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-wrong-work-registry-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt differs from its pre-drill contents' <<<"$clean_out")"
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"

# Must fail: the notify registry restored with the wrong bytes.
CLEAN_NOTIFY_AFTER='heavy-duty/ceremony'
clean_out="$(cleanup_run 0)"
t notify-cleanup-wrong-notify-registry-bytes-red "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-wrong-notify-registry-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt differs from its pre-drill contents' <<<"$clean_out")"
CLEAN_NOTIFY_AFTER='owner/watched'

# Absent before the drill means absent after it — both ways round.
CLEAN_ABSENT=1
CLEAN_NOTIFY_STATE=absent
t notify-cleanup-absent-before-and-gone-after-passes "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_NOTIFY_STATE=present
clean_out="$(cleanup_run 0)"
t notify-cleanup-file-left-behind-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-file-left-behind-says-there-was-none 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt is still in place; the box had none before the drill' <<<"$clean_out")"
CLEAN_ABSENT=0

# A leg that never captured has nothing to vouch for: the notify half is not
# asserted, and the work half still is.
CLEAN_CAPTURED=0
CLEAN_NOTIFY_AFTER='heavy-duty/ceremony'
t notify-cleanup-uncaptured-leg-asserts-nothing "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_REPOS_AFTER='owner/one'
t notify-cleanup-uncaptured-leg-still-checks-the-work-registry "rc=1" \
  "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"
# Nothing backed up is nothing to vouch for either — but only when the box
# SAID so, AND this round never made a copy. See the unanswerable-probe cases
# below for the first difference and the deleted-backup case for the second.
CLEAN_BACKUP_STATE=absent
CLEAN_BACKUP_TAKEN=0
CLEAN_REPOS_AFTER='whatever the box has'
t notify-cleanup-backup-never-taken-asserts-nothing "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"

# Must fail: the copy WAS made — so ~/duty/repos.txt was truncated and the only
# pre-drill bytes on the box were in that backup — and the box now says the
# backup is not there. This is a positively MEASURED loss, and it used to take
# the same branch as "there was nothing to back up": rc 0, comparing nothing,
# with the box left holding whatever the drill wrote (#423, round 3).
CLEAN_BACKUP_TAKEN=1
clean_out="$(cleanup_run 0)"
t notify-cleanup-deleted-backup-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-deleted-backup-says-so 1 \
  "$(grep -cF 'TEARDOWN: the pre-drill repos.txt backup this round made is gone' <<<"$clean_out")"
t notify-cleanup-deleted-backup-verdict-names-the-state 1 \
  "$(grep -cF 'fail teardown could not find the pre-drill repos.txt backup this round made' "$CLEANUP_VERDICTS")"
# ...and it is not confused with the box that would not answer at all, which
# has its own reason string.
t notify-cleanup-deleted-backup-is-not-the-unanswerable-reason 0 \
  "$(grep -cF 'the box did not say whether the pre-drill repos.txt backup was there' <<<"$clean_out")"
CLEAN_BACKUP_STATE=present
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"
CLEAN_CAPTURED=1
CLEAN_NOTIFY_AFTER='owner/watched'

# --- the box that stops answering, and the restore that does not run ------
#
# Every case below passed before round 2: each one ends in a `cat … || true`
# or a `test -f` whose failure was indistinguishable from an absent file, so
# teardown vouched for a registry nobody had looked at.

# Must fail: the backup probe is unanswerable. "The box did not say" is not
# "there was no backup", and the second reading is the one that returns 0.
CLEAN_BACKUP_STATE=unanswerable
clean_out="$(cleanup_run 0)"
t notify-cleanup-unanswerable-backup-probe-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-unanswerable-backup-probe-says-so 1 \
  "$(grep -cF 'TEARDOWN: the box did not say whether the pre-drill repos.txt backup was there' <<<"$clean_out")"
t notify-cleanup-unanswerable-backup-probe-verdict-names-the-state 1 \
  "$(grep -cF 'fail teardown could not read the pre-drill repos.txt backup' "$CLEANUP_VERDICTS")"
CLEAN_BACKUP_STATE=present

# Must fail: the restore itself did not run. It used to print a warning and
# leave the comparison to a probe that had already decided there was nothing
# to compare.
CLEAN_REPOS_RESTORE_RC=255
clean_out="$(cleanup_run 0)"
t notify-cleanup-failed-work-restore-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-failed-work-restore-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt could not be restored' <<<"$clean_out")"
t notify-cleanup-failed-work-restore-verdict-says-restore 1 \
  "$(grep -cF 'fail teardown could not restore repos.txt' "$CLEANUP_VERDICTS")"
CLEAN_REPOS_RESTORE_RC=0

# Must fail: the read-back after the restore is unanswerable. The pre-drill
# bytes here are EMPTY, which is the exact shape the old `cat … || true` let
# through — an unreadable file came back as "" and compared equal.
CLEAN_REPOS_PRE=''
CLEAN_REPOS_STATE=unanswerable
clean_out="$(cleanup_run 0)"
t notify-cleanup-unreadable-work-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-unreadable-work-registry-is-not-empty-bytes 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt could not be read back after the restore' <<<"$clean_out")"
# ...and a box that really did have an empty repos.txt still passes.
CLEAN_REPOS_STATE=present
CLEAN_REPOS_AFTER=''
t notify-cleanup-empty-work-registry-restored-passes "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
# ...while one the restore left missing entirely does not.
CLEAN_REPOS_STATE=absent
clean_out="$(cleanup_run 0)"
t notify-cleanup-missing-work-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-missing-work-registry-says-so 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt is not there after the restore' <<<"$clean_out")"
CLEAN_REPOS_STATE=present
CLEAN_REPOS_PRE='owner/one
owner/two'
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"

# The same three, on the notify half. A backup path is set so the restore is
# actually attempted — that is the call whose failure is under test.
# shellcheck disable=SC2088  # a box-side path: the tilde expands in the box
CLEAN_NOTIFY_BACKUP='~/duty/notify-repos.txt.pre-drill-99'
CLEAN_NOTIFY_RESTORE_RC=255
clean_out="$(cleanup_run 0)"
t notify-cleanup-failed-notify-restore-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-failed-notify-restore-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt could not be restored' <<<"$clean_out")"
t notify-cleanup-failed-notify-restore-verdict-says-restore 1 \
  "$(grep -cF 'fail teardown could not restore notify-repos.txt' "$CLEANUP_VERDICTS")"
CLEAN_NOTIFY_RESTORE_RC=0
CLEAN_NOTIFY_BACKUP=''

CLEAN_NOTIFY_PRE=''
CLEAN_NOTIFY_STATE=unanswerable
clean_out="$(cleanup_run 0)"
t notify-cleanup-unreadable-notify-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-unreadable-notify-registry-is-not-empty-bytes 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt could not be read back after the restore' <<<"$clean_out")"
CLEAN_NOTIFY_STATE=present
CLEAN_NOTIFY_AFTER=''
t notify-cleanup-empty-notify-registry-restored-passes "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_NOTIFY_STATE=absent
clean_out="$(cleanup_run 0)"
t notify-cleanup-missing-notify-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-missing-notify-registry-says-so 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt is not there after the restore' <<<"$clean_out")"
# An unanswerable read is not the absence the ABSENT branch asserts either:
# the box that shipped no notify-repos.txt must still be READ to say so.
CLEAN_ABSENT=1
CLEAN_NOTIFY_STATE=unanswerable
t notify-cleanup-unanswerable-read-is-not-the-absence-asserted "rc=1" \
  "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_ABSENT=0
CLEAN_NOTIFY_STATE=present
CLEAN_NOTIFY_PRE='owner/watched'
CLEAN_NOTIFY_AFTER='owner/watched'

# --- the verdict has to reach the EXIT trap's exit status -----------------
#
# It did not. drill/rehearsal.sh runs under `set -uo pipefail` with no -e, and
# a `return` from an EXIT-trap function does not change the shell's exit
# status — so the comparison above was computed, printed, and discarded, and a
# standalone `--role X` round exited 0 on a registry left holding the wrong
# bytes. This case used to grep for the wiring line, which is exactly why it
# passed while the property did not hold; it now runs rehearsal.sh's REAL
# cleanup_all, extracted from the file, and reads the status.
CLEANUP_ALL_SRC="$TMP/notify-cleanup-all.sh"
awk '/^cleanup_all\(\) \{$/,/^\}$/' "$ROOT/drill/rehearsal.sh" >"$CLEANUP_ALL_SRC"
t notify-cleanup-all-extracted-from-the-real-file 1 \
  "$(grep -c '^cleanup_all() {$' "$CLEANUP_ALL_SRC")"
CLEANUP_ALL_DRIVER="$TMP/notify-cleanup-all-driver.sh"
cat >"$CLEANUP_ALL_DRIVER" <<'EXITSH'
#!/usr/bin/env bash
set -uo pipefail
CLEANUP_RETURNS="$1"   # what the case makes the teardown comparison say
BOX_TOUCHED=1
BOX_NAME=""
ACQUIRE_TMP=""
REHEARSAL_NOTIFY_FIXTURES=""
BUILDER_CLEANUP_REPO=""; BUILDER_CLEANUP_AUTHOR=""
TRIAGE_CLEANUP_REPO=""; TRIAGE_CLEANUP_ISSUES=""
bx() { return 0; }
rehearsal_cleanup() { return "$CLEANUP_RETURNS"; }
. "$CLEANUP_ALL_SRC"
trap cleanup_all EXIT
exit 0
EXITSH
export CLEANUP_ALL_SRC
bash "$CLEANUP_ALL_DRIVER" 1 >/dev/null 2>&1
t notify-cleanup-verdict-reaches-the-exit-status 1 "$?"
bash "$CLEANUP_ALL_DRIVER" 0 >/dev/null 2>&1
t notify-cleanup-clean-teardown-keeps-the-exit-status 0 "$?"

suite_finish
