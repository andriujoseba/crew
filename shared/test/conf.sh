#!/usr/bin/env bash
# shared/test/conf.sh — standalone conf subject suite.
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
# Shared installer fixture used by the configuration and profile cases below.
ISHIM="$TMP/install-bin"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM"
for cmd in awk bash basename cat chmod cp date dirname env find grep head mkdir mktemp mv readlink rm sed sha256sum sort tail tr wc xargs; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
# shellcheck disable=SC2016  # expanded when the fixture shim runs
printf '#!/usr/bin/env bash\n[ "${FIXTURE_GITLESS:-0}" != 1 ] || exit 1\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
chmod +x "$ISHIM/gh" "$ISHIM/git"

# --- agent profiles and rehearsal selection -----------------------------
for profile in "$SHARED"/conf/agents/*.conf; do
  agent="$(basename "$profile" .conf)"
  if bash -c '. "$1"; type bot_cli_probe >/dev/null; test -n "$AGENT_LOGIN_HINT"' _ "$profile"; then
    r1=sourceable
  else
    r1=broken
  fi
  t "agent-conf-$agent-standalone" sourceable "$r1"
  profile_login_hints="$(sed -n '/^AGENT_LOGIN_HINT=.*${/p' "$profile")"
  if grep -q . <<<"$profile_login_hints"; then
    r1=deferred
  else
    r1=literal
  fi
  t "agent-conf-$agent-login-hint-literal" literal "$r1"
done

# --- each agent profile reads its OWN credential store, locally -------------
# Driven against the real conf files with a fabricated HOME, because the whole
# claim of bot_cli_present is that it needs nothing but local disk.

CREDH="$TMP/credhome"; mkdir -p "$CREDH"
cred_rc() {  # cred_rc <agent> <home> [KIMI_CODE_HOME] -> rc of bot_cli_present
  local rc=0
  # Every vendor env override is cleared, not just the one under test: these
  # are read by the sourced profile, and inheriting the RUNNER's credentials
  # would make the result depend on whose machine ran the suite. KIMI_CODE_HOME
  # is the one a caller may set back, in $3, because kimi's home resolver gives
  # it precedence over both probed homes and that precedence is under test.
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$2" KIMI_CODE_HOME="${3:-}" CODEX_HOME="" GROK_HOME="" \
    ANTHROPIC_API_KEY="" XAI_API_KEY=""
    # shellcheck disable=SC1090
    source "$SHARED/conf/agents/$1.conf"; bot_cli_present ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
# base64url with the padding stripped, the way a JWT actually arrives.
b64url() { base64 -w0 | tr '/+' '_-' | tr -d '='; }

# -- claude: refreshTokenExpiresAt, in MILLISECONDS
CH="$CREDH/claude"; mkdir -p "$CH/.claude"
CLAUDE_EXP_MS=$(( ($(date +%s) + 20 * 86400) * 1000 ))
jq -n --argjson r "$CLAUDE_EXP_MS" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-present 0 "$(cred_rc claude "$CH")"

# THE trap, and the reason this profile reads refreshTokenExpiresAt: an access
# token that lapsed hours ago while the refresh token is still good is the
# ordinary steady state, refreshed silently on next use. A profile testing
# `expiresAt` would call a perfectly healthy box logged out three times a day.
jq -n --argjson r "$CLAUDE_EXP_MS" --argjson a "$(( ($(date +%s) - 3600) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:$a,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-stale-access-token-is-fine 0 "$(cred_rc claude "$CH")"

# An expired REFRESH token is the real logout: nothing can renew it but a human.
jq -n --argjson r "$(( ($(date +%s) - 86400) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-expired-refresh 1 "$(cred_rc claude "$CH")"
t cred-claude-no-file 1 "$(cred_rc claude "$CREDH/nothing")"

# -- kimi: the refresh token is a JWT; its exp claim is the relogin deadline
KH="$CREDH/kimi"; mkdir -p "$KH/.kimi-code/credentials"
KIMI_EXP=$(( $(date +%s) + 30 * 86400 ))
# A payload sized so base64url PADDING is required — the case a naive decoder
# silently fails on.
KJWT="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code","sub":"u"}' "$KIMI_EXP" | b64url).sig"
jq -n --arg rt "$KJWT" \
  '{access_token:"a",refresh_token:$rt,expires_at:1,token_type:"Bearer"}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-present 0 "$(cred_rc kimi "$KH")"
t cred-kimi-no-file 1 "$(cred_rc kimi "$CREDH/nothing")"
# An expired refresh JWT is a logout, not merely "cannot tell".
KJWT_OLD="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code"}' "$(( $(date +%s) - 86400 ))" | b64url).sig"
jq -n --arg rt "$KJWT_OLD" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-expired-refresh 1 "$(cred_rc kimi "$KH")"
# Garbage in the JWT slot must be "cannot tell" (2), never a confident logout.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-unparseable-is-unknown 2 "$(cred_rc kimi "$KH")"

# -- kimi, the second home. The shipped CLI keeps the same credential at
# ~/.kimi, not ~/.kimi-code, so the profile resolves the home instead of
# assuming it (#240): the fleet's kimi box reported a dead vendor credential
# on every tick while being perfectly logged in. cred_rc clears
# KIMI_CODE_HOME by design, so these four are the unset case.
KH2="$CREDH/kimialt"; mkdir -p "$KH2/.kimi/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-present 0 "$(cred_rc kimi "$KH2")"
# A wider search must reach the SAME parser, not a second, dumber one.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-unparseable-is-unknown 2 "$(cred_rc kimi "$KH2")"
# Neither home holds anything: still a CONFIDENT logout. A resolver that fell
# back to a path it never checked would answer 2 here and silence a real one.
KH0="$CREDH/kiminone"; mkdir -p "$KH0/.kimi/credentials" "$KH0/.kimi-code/credentials"
t cred-kimi-neither-home 1 "$(cred_rc kimi "$KH0")"

# KIMI_CODE_HOME is explicit operator intent and outranks both probes. Proven
# by pointing it at a home with NO credential while BOTH known homes hold a
# good one: a resolver that probed first would answer 0. cred_rc's third
# argument is the only vendor override it does not clear, for exactly this.
KHO="$CREDH/kimiover"; mkdir -p "$KHO/.kimi/credentials" "$KHO/.kimi-code/credentials" "$KHO/elsewhere/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/.kimi/credentials/kimi-code.json"
cp "$KHO/.kimi/credentials/kimi-code.json" "$KHO/.kimi-code/credentials/kimi-code.json"
t cred-kimi-override-outranks-probe 1 "$(cred_rc kimi "$KHO" "$KHO/elsewhere")"
# ...and it reaches a credential neither probe would ever find.
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/elsewhere/credentials/kimi-code.json"
t cred-kimi-override-reaches-elsewhere 0 "$(cred_rc kimi "$KH0" "$KHO/elsewhere")"

# -- the SAME resolution drives PATH, and until now nothing asserted that half
# of #240's D2: BOT_PATH_PREPEND is an assignment evaluated when the profile is
# sourced, so reading it back also proves the resolver is defined ABOVE it.
# The resolved home's bin comes first, then every other known home's — a
# non-existent PATH entry costs nothing, which is why the fallbacks are cheaper
# than guessing right. Only PRESENCE of the credential picks the home here, not
# whether its JWT parses, so the fixtures above are reused exactly as they lie.
path_prepend() {  # path_prepend <home> [KIMI_CODE_HOME] -> BOT_PATH_PREPEND
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$1" KIMI_CODE_HOME="${2:-}"
    # shellcheck disable=SC1091
    source "$SHARED/conf/agents/kimi.conf"; printf '%s' "$BOT_PATH_PREPEND" ) 2>/dev/null
}
t path-kimi-alt-home-first "$KH2/.kimi/bin:$KH2/.kimi-code/bin" "$(path_prepend "$KH2")"
t path-kimi-old-home-first "$KH/.kimi-code/bin:$KH/.kimi/bin" "$(path_prepend "$KH")"
# No credential anywhere: the ~/.kimi-code fallback leads, and the other home
# is still on PATH — the CLI may be installed where the credential is not.
t path-kimi-neither-home-falls-back "$KH0/.kimi-code/bin:$KH0/.kimi/bin" "$(path_prepend "$KH0")"
# Explicit operator intent leads here too, even though both probes would hit.
t path-kimi-override-first "$KHO/elsewhere/bin:$KHO/.kimi/bin:$KHO/.kimi-code/bin" \
  "$(path_prepend "$KHO" "$KHO/elsewhere")"

# -- codex: file-backed vs keyring-backed, and NO expiry at all
DH="$CREDH/codex"; mkdir -p "$DH/.codex"
jq -n '{auth_mode:"chatgpt",tokens:{access_token:"a.b.c",refresh_token:"opaque"}}' > "$DH/.codex/auth.json"
t cred-codex-present 0 "$(cred_rc codex "$DH")"
t cred-codex-no-file-is-logout 1 "$(cred_rc codex "$CREDH/nothing")"
# ...unless the box keeps its credential in the desktop keyring, where a
# missing auth.json is normal and must not be reported as a logout.
KB="$CREDH/codexkeyring"; mkdir -p "$KB/.codex"
echo 'cli_auth_credentials_store = "keyring"' > "$KB/.codex/config.toml"
t cred-codex-keyring-is-unknown 2 "$(cred_rc codex "$KB")"

# -- grok: its probe was already a local file test, so it is authoritative
# -- grok: a MAP of "<issuer>::<client_id>" slots, refresh token opaque
GH_="$CREDH/grok"; mkdir -p "$GH_/.grok"
jq -n '{"https://auth.x.ai::abc":{key:"j.w.t",refresh_token:"opaque",expires_at:"2026-07-27T19:54:18Z"}}' \
  > "$GH_/.grok/auth.json"
t cred-grok-present 0 "$(cred_rc grok "$GH_")"
t cred-grok-no-file 1 "$(cred_rc grok "$CREDH/nothing")"
# An empty map is a non-empty FILE. The old `[ -s ]` test called this logged
# in; it is a failed login, and the honest answer is "cannot tell".
echo '{}' > "$GH_/.grok/auth.json"
t cred-grok-empty-map-is-unknown 2 "$(cred_rc grok "$GH_")"

# No profile may define bot_cli_expiry: the floor tracks no expiry dates, and
# a profile still exporting one would be dead code drifting out of sync.
for agent in claude codex grok kimi; do
  r1=absent
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$agent.conf"; command -v bot_cli_expiry >/dev/null ) 2>/dev/null && r1=DEFINED
  t "cred-$agent-defines-no-expiry" absent "$r1"
done

# --- install.sh: the operator agent-profile transport contract (#75) --------
# The ordering is the whole difficulty (codex Blocking 4 on #73): install.sh
# refuses an unknown agent BEFORE it creates conf/agents, so a profile that
# arrived only with the conf copy would fail its own validation — a vendor
# that lists in `crew profiles` and dies at `crew hire`. The host stages
# operator profiles into ~/duty/.crew-seed-agents ahead of the run; these
# fixtures assert every clause: a seeded profile passes validation, the
# operator copy is what conf/agents carries (same-name wins where load_conf
# reads), the seed is consumed on success AND failure, and an unseeded
# unknown agent still dies.
PHOME="$TMP/profile-home"
PDUTY="$PHOME/duty"
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/vendorx.conf" <<'EOF'
# vendorx — operator-supplied fixture vendor (never shipped)
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="vendorx"
AGENT_LOGIN_HINT="vendorx auth login"
bot_cli_probe() { return 0; }
bot_cli_present() { command -v vendorx >/dev/null 2>&1; }
EOF
profile_install() {
  env HOME="$PHOME" DUTY_DIR="$PDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
if profile_install --agent vendorx --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-validates-before-conf-exists 0 "$r1"
[ -f "$PDUTY/conf/agents/vendorx.conf" ] && r1=installed || r1=missing
t operator-profile-lands-in-conf-agents installed "$r1"
if grep -q 'operator-supplied fixture vendor' "$PDUTY/conf/agents/vendorx.conf" 2>/dev/null; then
  r1=operator
else
  r1=other
fi
t operator-profile-is-the-operator-copy operator "$r1"
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed consumed "$r1"
# The shipped set still installs whole beside the operator's addition.
[ -f "$PDUTY/conf/agents/claude.conf" ] && r1=present || r1=missing
t operator-profile-shipped-set-intact present "$r1"

# Same-name precedence: an operator claude.conf beats the shipped one — and
# the win must hold at RUNTIME, where load_conf sources whatever
# conf/agents carries (common.sh:34); settled in the copy, not by a reader.
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/claude.conf" <<'EOF'
# claude — operator override fixture
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="claude"
AGENT_LOGIN_HINT="operator override wins"
bot_cli_probe() { return 0; }
bot_cli_present() { return 0; }
EOF
profile_install --agent claude --role reviewer >/dev/null 2>&1
if grep -q 'operator override fixture' "$PDUTY/conf/agents/claude.conf" 2>/dev/null; then
  r1=operator
else
  r1=shipped
fi
t operator-profile-same-name-wins operator "$r1"
# shellcheck disable=SC2016  # $DUTY_DIR and $AGENT_LOGIN_HINT expand in the child shell
runtime_hint="$(env DUTY_DIR="$PDUTY" HOME="$PHOME" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_conf; printf %s "$AGENT_LOGIN_HINT"')"
t operator-profile-wins-at-load_conf "operator override wins" "$runtime_hint"

# The gap the contract closes, inverted: an agent nobody transported and
# nobody ships must still die at validation, not at first duty tick.
if profile_install --agent vendory --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-unknown-still-refused 1 "$r1"

# A one-install transport on FAILURE too: a failing install (here: a role
# that does not exist, checked after the agent) must not leave seeds behind
# for a later bare run to resurrect.
mkdir -p "$PDUTY/.crew-seed-agents"
printf '# vendorz — fixture\n' >"$PDUTY/.crew-seed-agents/vendorz.conf"
profile_install --agent vendorz --role nosuchrole >/dev/null 2>&1 || true
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed-on-failure consumed "$r1"


# --- bot_session_acted: the idle detector on the two -p profiles (#467) -----
#
# THE FIXTURES BELOW ARE VERBATIM CAPTURED SESSION LOGS, byte for byte, from
# the 1064 `claude -p` transcripts this engine wrote on a real builder box.
# Nothing here was composed to be detected. That is the point of #467's
# acceptance criteria: a detector tested only against strings someone imagined
# is a detector that fails on the first real session, and the two corrections
# this suite pins hardest — the sub-action claim and the quota banner — were
# both invisible until the whole corpus was run through it.
#
# Each fixture names the log it came from, so the claim is checkable.

ALOG="$TMP/acted"; mkdir -p "$ALOG"

acted_rc() {  # acted_rc <agent> <log> -> raw rc of the profile hook
  local rc=0
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; bot_session_acted "$2" ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
acted_prose() {  # acted_prose <agent> <log> -> what the detector actually reads
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; "_${1}_reply_prose" "$2" ) 2>/dev/null
}
acted_word() {  # acted_word <agent> <log> -> the field as duty.log spells it
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$1.conf"; session_acted "$2" )
}

# an `attention` session that posted two comments and removed a label
# captured: ~/duty/logs/20260802T130504Z-attention-heavy-duty_crew_286.log
cat >"$ALOG/push.log" <<'ACTED_EOF'
Done. The demand on #286 was a single recovery act, and it's complete.

**What the thread demanded:** my 12:48:59Z signal named `d664faf3`, then I pushed `4a8a86e3` (triage's amended must-fail item) *after* it. The head therefore carried no signal, `_request_panel` was correctly holding, and the PR would have held forever — #241's shape, with the recovery duty not deployed to the boxes.

**What I did:**
- Posted `📌 picked up` on #286 and removed the `attention` label ([comment](https://github.com/heavy-duty/crew/issues/286#issuecomment-5158076189)).
- Verified head `4a8a86e378fe990092097fdc283a02f0b70ee712` is green — rollup `SUCCESS`, all four checks (`check`, `guards`, `labels / scope`, `labels / trigger`) completed successful, nothing queued, cancelled, or stale. Worktree clean at that exact SHA, nothing unpushed.
- Confirmed the round is answered whole: every worklog checkbox and acceptance criterion in the PR body is checked, and no reviews are outstanding at any head.
- Posted the signal on [#292](https://github.com/heavy-duty/crew/pull/292#issuecomment-5158080889): `📣 round answered at head 4a8a86e378fe990092097fdc283a02f0b70ee712`, with the green table, the two judgement calls flagged for the panel (task 3 scoped to `CHANGES_REQUESTED`; `answered-head.jq` serving both callers with stranded detection reading no time), and an explicit acknowledgement that the post-signal push was mine to re-signal regardless of why the head moved.

No exception was argued — the head is genuinely green. The engine now requests the panel; that is not mine to do.
ACTED_EOF

# a `resume` session that read the whole PR thread and wrote nothing
# captured: ~/duty/logs/20260806T053009Z-resume-heavy-duty_crew.log
cat >"$ALOG/read.log" <<'ACTED_EOF'
**PR #376 needs no action — it is already fully converged. I posted nothing.**

The resume wake named it, but the REST thread shows the work is complete:

| check | state |
|---|---|
| head | `019db9b4c85485910ee1c4b6adc429650dcd924e` |
| round-answered signal at that head | posted 01:01:31Z |
| panel verdicts at that head | kimi ✅ 01:10, codex ✅ 01:13, claude ✅ 01:19 — all three, full bench minus me |
| handoff | `🤝 handed off at head 019db9b…` posted 01:21:50Z |
| label | `state:needs-human` |
| checks at head | ci-shell SUCCESS, guards SUCCESS, labels/scope SUCCESS (+ SKIPPED reruns), labels/trigger SUCCESS — green |
| worktree `build-168-wip-refs` | clean, HEAD == `fork` branch tip, nothing stranded |

This is the known false positive: the 12-tick counter runs from the *push* (23:59Z), and round 3's reply→signal gap ran to 01:01Z, so the counter tripped on a PR that had in fact answered its round, been approved by the whole panel, and been handed to the human. Per BUILDER.md — "a resumption that finds nothing changed posts nothing" — re-posting a signal or a ⟲ marker here would be pure flood on a PR that is already at `state:needs-human` and waiting only on a human merge.

No draft PRs and no orphaned claimed issues were outstanding, so the duty is discharged with no writes to GitHub.
ACTED_EOF

# a `resume` session that opens with TWO no-op claims and then writes a memory file
# captured: ~/duty/logs/20260806T010509Z-resume-heavy-duty_crew.log
cat >"$ALOG/trap.log" <<'ACTED_EOF'
Nothing to do on PR 376, and I posted nothing to it. The standing record is correct: signalled at the current head, green, panel requested, one reviewer mid-round. Per BUILDER.md's Claiming rule — *"a resumption that finds nothing changed posts nothing"* — silence here is the compliant act, and a duplicate marker would have been the `#145`/`#311` flood.

I updated my memory of the resume wake: the cause it recorded (`#360`'s comment-blindness) merged yesterday, but the wake tripped anyway for a different reason worth carrying forward — the twelve-tick counter runs from the push, not from the whole-round reply, so a long gap between posting the reply and posting the `📣` signal burns the budget on its own. The fix is on my side: close that gap.
ACTED_EOF

# a session that is only waiting on a verdict
# captured: ~/duty/logs/20260824T220003Z-attention-heavy-duty_ceremony_499.log
cat >"$ALOG/wait.log" <<'ACTED_EOF'
Round 2's third verdict hasn't landed yet. I'll pick this back up the moment it does — the poll wakes me either on the verdict or in ~13 minutes, whichever comes first, so a long wait produces a worklog update on the PR rather than silence.
ACTED_EOF

# a session cut off mid-flight, one clause short of saying whether it posted
# captured: ~/duty/logs/20260809T022011Z-build-heavy-duty_crew.log
cat >"$ALOG/ambi.log" <<'ACTED_EOF'
No tests drive the log helpers directly, so claude's NB#3 is cheap to take. Posting the plan of record now, before touching code.
API Error: Server error mid-response. The response above may be incomplete.
ACTED_EOF


# A `review` session reporting its own verdict.
#
# There is no captured `review` transcript in this box's 1065 logs — 577
# resume, 312 build, 131 attention, 36 ci-red, and not one review — and that
# absence is itself the defect this fixture exists for: the first cut of this
# detector was tuned on that corpus, so it could not see the review duty's
# acts and booked 25 reviewer sessions that had written a verdict to GitHub as
# idle. The text below is claude-bot's minimal reproduction, verbatim from its
# review of PR #522 at head `d98ccd41`, where it was run against 1260 captured
# review logs. It is quoted rather than invented, and where it came from is
# said here rather than left to be assumed.
cat >"$ALOG/verdict.log" <<'ACTED_EOF'
**heavy-duty/crew#999 — approved** at head `abc1234`.

The announce for this head was already present, so I posted nothing new.
Reviewed in a detached worktree; the full suite is still running on the
follow-up branch. Verdict submitted via the wrapper (exit 0), verified landed.
ACTED_EOF

# The same duty in its passive voice, which is the half a verb list cannot
# reach: no first-person subject anywhere near any of the three acts.
#
# The no-op claim at the end is load-bearing, not decoration. Without one the
# reply never reaches the residue path at all — it returns `yes` on D3's
# default, and the case would pass just as well with the verdict pattern
# deleted. It did, in the first cut of this file, and the mutation is what
# said so.
cat >"$ALOG/passive.log" <<'ACTED_EOF'
Both PRs reviewed and approved. Announcements posted once each.
Both verdicts submitted and the worktrees are cleaned up; I pushed nothing and I made no comments.
ACTED_EOF

# THE OTHER HALF OF THAT TRAP, and the reason the verdict pattern anchors to
# position rather than to a head SHA. This is a `resume` session that did
# nothing and says so — while quoting a whole panel's approvals, its own
# signal marker from a PREVIOUS session, and a handoff. An earlier draft of
# the review-duty widening accepted `approved at <sha>` and flipped 45 corpus
# sessions of exactly this shape to `yes`; every one was false.
# captured: ~/duty/logs/20260806T055009Z-resume-heavy-duty_crew.log
cat >"$ALOG/quoted.log" <<'ACTED_EOF'
No action taken, and nothing posted — correctly so.

**PR #376 is finished, not stranded.** The resume wake named it, but the thread shows the round is complete and handed off:

- Head `019db9b` (last commit 2026-08-05T23:57:23Z, unchanged since)
- My `📣 round answered at head 019db9b4c85485910ee1c4b6adc429650dcd924e` posted at 01:01:31Z
- All three panelists — claude-bot, codex-bot, kimi-bot — APPROVED **at that exact head** (01:10Z / 01:13Z / 01:19Z)
- `🤝 handed off at head 019db9b…` posted 01:21:50Z, `state:needs-human` set, `requested_reviewers` now just `danmt`
- Rollup green at head: `guards` success, `ci-shell` success, `labels / scope` success, `labels / trigger` success

Re-signalling here would re-request an already-unanimous panel on a PR the human now owns — the exact marker flood #145/#311 forbid.

No other work was outstanding: no draft PRs, no orphaned claimed issues. Session exits silent.
ACTED_EOF

# D4's THIRD state — "a transcript the profile does not recognise" — on the
# only log in 1065 that is one. Fifty-eight bytes of a session cut off after a
# probe result: it names nothing this engine does, so whether it acted is not
# ambiguous, it is absent. D3 governs ambiguity; this is not that.
# captured: ~/duty/logs/20260815T080517Z-build-heavy-duty_ceremony.log
cat >"$ALOG/frag.log" <<'ACTED_EOF'
Probe 4 passed (tags 1→1, releases 1→1). Four remain.
ACTED_EOF

# And a transcript from a different runtime altogether, which is the same
# state arriving the other way: prose, first-person, and about nothing this
# profile reads. It is the fixture `shared/test/common/session.sh` used to
# assert `unknown` with, kept here now that the stub it relied on is gone.
printf 'Claude Code\nfinal answer: I need more information.\n' >"$ALOG/foreign.log"

# `Execution error` is what the CLI prints when it dies before the model
# speaks: fifteen bytes and NO trailing newline. All 26 in the corpus.
printf 'Execution error' >"$ALOG/fault.log"
# The vendor's refusal banners. A session that hit the weekly cap or a dead
# login never reached the model at all — 40 of the 1064 are one of these.
printf "You've hit your session limit \xc2\xb7 resets 1:20am (UTC)\n" >"$ALOG/quota.log"
printf "Not logged in \xc2\xb7 Please run /login\n" >"$ALOG/nologin.log"
: >"$ALOG/empty.log"

# The contract, on BOTH profiles, case for case. grok.conf carries the same
# detector as a second copy because a profile is transported one file at a
# time; this loop is what stops the copies drifting, and it is the only reason
# the duplication is safe.
for agent in claude grok; do
  # A session that wrote something: two comments posted and a label removed.
  t "acted-$agent-wrote-is-yes"        0 "$(acted_rc "$agent" "$ALOG/push.log")"
  # A session that only read: it says so, and nothing else in it says otherwise.
  t "acted-$agent-read-only-is-no"     1 "$(acted_rc "$agent" "$ALOG/read.log")"
  # D4, both halves, and neither folded into `no`.
  t "acted-$agent-empty-is-unknown"    2 "$(acted_rc "$agent" "$ALOG/empty.log")"
  t "acted-$agent-fault-is-unknown"    2 "$(acted_rc "$agent" "$ALOG/fault.log")"
  # A cap or a dead login is a session that never spoke, NOT one that did
  # nothing. Reading it as idle would have booked 40 of this box's sessions as
  # waste that no duty ever incurred.
  t "acted-$agent-quota-is-unknown"    2 "$(acted_rc "$agent" "$ALOG/quota.log")"
  t "acted-$agent-nologin-is-unknown"  2 "$(acted_rc "$agent" "$ALOG/nologin.log")"
  # D3, pinned by a real borderline transcript rather than by a paragraph: the
  # session was cut off one clause short of saying whether it posted. That is
  # the ambiguity the bias exists for, and it answers ACTED.
  t "acted-$agent-ambiguous-is-yes"    0 "$(acted_rc "$agent" "$ALOG/ambi.log")"
  # THE TRAP. This reply opens "Nothing to do on PR 376, and I posted nothing
  # to it" — and then updates a memory file. A no-op claim is about one
  # sub-action until the rest of the reply is read, so the claim is deleted
  # from the text BEFORE the evidence is looked for. A detector that stopped
  # at the first phrase books this session as idle; it was not.
  t "acted-$agent-subaction-claim-is-yes" 0 "$(acted_rc "$agent" "$ALOG/trap.log")"
  # Waiting on someone else's verdict is doing nothing, and says so.
  t "acted-$agent-waiting-only-is-no"  1 "$(acted_rc "$agent" "$ALOG/wait.log")"
  # THE REVIEW DUTY. Both of these open with a no-op claim and both acted: one
  # in the engine's marker shape, one in the passive voice with no subject
  # anywhere near the verb. A detector tuned on builder transcripts alone
  # answers `no` to both, which is what it did to 25 real reviewer sessions.
  t "acted-$agent-review-verdict-is-yes"   0 "$(acted_rc "$agent" "$ALOG/verdict.log")"
  t "acted-$agent-subjectless-verdict-is-yes" 0 "$(acted_rc "$agent" "$ALOG/passive.log")"
  # ...and the guard that stops that widening eating the idle column: a
  # resumption QUOTING a panel's approvals, its own earlier signal and a
  # handoff, having done nothing. Position, not proximity to a SHA.
  t "acted-$agent-quoted-verdict-is-no"    1 "$(acted_rc "$agent" "$ALOG/quoted.log")"
  # D4's third clause, both doors: a fragment that names nothing this engine
  # does, and a transcript from another runtime. Neither is `no` — the
  # session's acts are not undecided here, they are unstated — and neither is
  # `yes`, which is where an un-gated D3 default put them.
  t "acted-$agent-fragment-is-unknown"     2 "$(acted_rc "$agent" "$ALOG/frag.log")"
  t "acted-$agent-foreign-log-is-unknown"  2 "$(acted_rc "$agent" "$ALOG/foreign.log")"
  # The banner filter is asserted on the PROSE, not on the verdict, because
  # the verdict no longer distinguishes it: the recognition gate answers
  # `unknown` for a banner-only log with the filter removed, and does so
  # identically on all 1065 captured logs. Its remaining guarantee is the
  # narrower one — that a vendor banner never enters the text the patterns
  # read, however loose those patterns grow — so that is where it is pinned.
  # A case on the rc here would be a case no mutation can kill.
  t "acted-$agent-banner-leaves-no-prose" "" "$(acted_prose "$agent" "$ALOG/quota.log")"
done

# The three states survive session_acted's mapping and reach duty.log as the
# words the operator's aggregate greps for. `unknown` is the one that must
# still be reachable: before this change it was the ONLY reachable value.
t acted-word-yes     yes     "$(acted_word claude "$ALOG/push.log")"
t acted-word-no      no      "$(acted_word claude "$ALOG/read.log")"
t acted-word-unknown unknown "$(acted_word claude "$ALOG/empty.log")"

# codex and kimi are out of scope (#467 D6) and stay byte-identical. Pinned by
# content rather than by `git diff`, which would assert nothing the moment this
# branch merges: these two lines ARE the two detectors, and a suite that reds
# when they move is the durable form of "unchanged".
t acted-codex-detector-untouched \
  "grep -Eq '(^|[[:space:]])(exec|apply_patch)([[:space:]]|\$)|^tool (call|result)' \"\$1\"" \
  "$(sed -n '/^bot_session_acted()/,/^}/p' "$SHARED/conf/agents/codex.conf" | sed -n '2p' | sed 's/^  //')"
t acted-kimi-detector-untouched \
  "grep -Eq '(^|[^[:alpha:]])(Using|Used) Shell[[:space:]]*\\(' \"\$1\"" \
  "$(sed -n '/^bot_session_acted()/,/^}/p' "$SHARED/conf/agents/kimi.conf" | sed -n '2p' | sed 's/^  //')"

# D5: this issue makes an existing field truthful and gates nothing on it. The
# tempting one-liner is a dispatch gate keyed on the PREVIOUS session's
# `acted`, and it is a separate decision — so the absence is asserted, not
# promised. run_session must reach the CLI whatever the last session reported.
printf '%s SESSION END kind=mention key=r/x rc=0 dur=9s outcome=ok acted=no reply_tail=\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$TMP/duty-prior.log"
AWORK="$TMP/acted-work"; mkdir -p "$AWORK"
BOT_CLI_CMD=(bash -c 'printf "I posted nothing.\n"')
DUTY_LOG="$TMP/duty-prior.log" run_session mention r/x "$AWORK" 5 p >"$TMP/acted-gate.out" 2>&1
grep -q 'SESSION START' "$TMP/acted-gate.out" && r1=dispatched || r1=GATED
t acted-no-dispatch-gate-on-prior-acted dispatched "$r1"
unset BOT_CLI_CMD

# --- the operator's own aggregate, end to end (#467) ------------------------
#
# The criterion is stated as the command @danmt ran, not as a call into the
# library: real transcripts -> run_session -> duty.log -> awk. Every SESSION
# END line below is written by the engine, from a fixture the CLI actually
# emitted, so nothing between the detector and the `idle` column is stubbed.
AGG="$TMP/acted-duty.log"; : >"$AGG"
# The profile is sourced for real here, in a subshell so the suite's own scope
# stays as the cases above found it. Sourcing it is not a detail: session_acted
# resolves the hook through `declare -F`, so a box whose profile defines none
# answers `unknown` for every session it ever runs — which is grok's half of
# this bug, and running the aggregate without the source would reproduce
# `idle=0` here for exactly that reason.
(
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  for f in push read trap wait ambi verdict quoted empty fault quota; do
    # The stub IS the CLI: it replays one captured transcript verbatim. $0 is
    # the fixture because run_session appends the prompt as the final argument.
    # shellcheck disable=SC2016  # $0 is the shim's own argument, not this shell's
    BOT_CLI_CMD=(bash -c 'cat -- "$0"' "$ALOG/$f.log")
    run_session mention "r/$f" "$AWORK" 10 p >>"$AGG" 2>/dev/null
  done
)

# The aggregate, as it was run: sessions, minutes, and idle by duty.
agg_idle() { awk '/SESSION END/ {
    for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
    if (f["acted"] == "no") idle[f["kind"]]++
    n[f["kind"]]++
  } END { for (k in n) printf "%s sessions=%d idle=%d\n", k, n[k], idle[k] + 0 }' "$1"
}
agg="$(agg_idle "$AGG")"
t acted-aggregate-counts-every-session "sessions=10" \
  "$(printf '%s\n' "$agg" | sed -n 's/.*\(sessions=[0-9]*\).*/\1/p')"
# The whole point. `idle=0` across 4150 sessions was a disabled detector; an
# `idle` equal to the session count would be a detector stuck the other way.
idle_n="$(printf '%s\n' "$agg" | sed -n 's/.*idle=\([0-9]*\).*/\1/p')"
[ "${idle_n:-0}" -gt 0 ] && [ "${idle_n:-10}" -lt 10 ] && r1=non-degenerate || r1="degenerate(idle=$idle_n)"
t acted-aggregate-idle-is-non-degenerate non-degenerate "$r1"


suite_finish
