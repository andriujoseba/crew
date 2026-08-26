# common/identity.sh — note_auth_failure, clear_auth_failure, gh_identity,
# check_vendor_credential, git_identity_login, git_identity_ok,
# converge_git_identity, git_identity_failure_message — the box's own
# account, and every carrier of it.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash

# --------------------------------------------------------------------------
# Credential state, REPORTED BY THE FLOW rather than polled.
#
# The floor used to answer "is this box authenticated?" by running `gh auth
# status` and the agent's bot_cli_probe inside every box on every 60s poll.
# Both touch the network — `gh auth status` is a real api.github.com
# round-trip — so the fleet spent ~7,000 requests a day re-deriving a fact
# that changes when a token expires, i.e. about monthly, and the probe's
# latency became a function of GitHub's.
#
# Nothing needs to ask. The engine already talks to GitHub every tick and is
# therefore the first thing to find out, for free, when a credential stops
# working. These helpers record what it learns; probe.sh only reads the files.
#
# One file PER SERVICE, never one shared file matched by substring: a gh
# failure whose message happens to contain the word "vendor" would otherwise
# condemn the vendor CLI too, and the operator would go re-login the wrong
# thing.
#   .auth-fail.<svc>       "<iso8601> <reason>"  — present only while broken
#
# One file, one boolean: present means broken, absent means working. No expiry
# date is recorded — see gh_identity for why a countdown was dropped.
# --------------------------------------------------------------------------

# note_auth_failure SVC REASON — record that SVC rejected us, once. Rewriting
# the file every tick would reset its mtime and make a credential that broke
# three days ago look like it broke just now, which is the one thing an
# operator reads a marker file for. First failure wins until it is cleared.
note_auth_failure() {
  # Two `local`s, not one: in `local a=$1 b=${a}` the b assignment runs before
  # a is in scope, so every service would have shared one `.auth-fail.` file.
  local svc="$1" reason="$2"
  local f="$DUTY_DIR/.auth-fail.$svc"
  [ -s "$f" ] && return 0
  # Newlines would turn one record into several and break the ::key contract
  # probe.sh emits it under; gh's errors are routinely multi-line. Flattened
  # ONCE and reused, so the log line and the Telegram alert cannot disagree
  # with the file about what went wrong.
  local flat
  flat="$(printf '%s' "$reason" | tr '\n\r' '  ' | cut -c1-200)"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$flat" >"$f"
  warn "auth: $svc rejected us — $flat"
  # An operator who is not watching the floor still needs to know: a box with
  # a dead credential does no work at all, and says so nowhere else until
  # someone looks. alert() is best-effort and never fails a tick.
  alert "🔑 $(hostname): $svc auth failed — $flat"
  return 0
}

# clear_auth_failure SVC — the credential works again. Logged, because a
# marker vanishing silently is indistinguishable from one never written.
clear_auth_failure() {
  local svc="$1"
  local f="$DUTY_DIR/.auth-fail.$svc"
  [ -f "$f" ] || return 0
  rm -f "$f"
  log "auth: $svc is working again"
  alert "✅ $(hostname): $svc auth restored"
  return 0
}

# gh_identity — the box's own login, and whether gh still works. Echoes the
# login, or nothing if the credential was rejected.
#
# This REPLACES a bare `gh api user`: same single call the tick was already
# making to resolve $ME, but its failure is now recorded rather than swallowed
# by `|| true`. That is the whole credential signal — a rejection at the
# moment a real request is rejected, which is a stronger claim than
# `gh auth status`, since that only proves the token authenticates against
# `GET /` and a token with the wrong scopes passes it happily.
#
# No expiry DATE is tracked, here or anywhere. Every provider expresses it
# differently — epoch millis, a JWT claim, an ISO string, or not at all — and
# two of the four agent CLIs cannot answer locally, so a countdown was the
# flaky part of an otherwise stable idea. Whether the credential works right
# now is the boolean that matters, and it is the one every provider agrees on.
gh_identity() {
  local login rc=0 err
  err="$(mktemp)"
  login="$(gh api user --jq .login 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$login" ]; then
    note_auth_failure gh "$(grep -iE 'message|401|403|error' "$err" | head -1 || printf 'gh api user exited %s' "$rc")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  clear_auth_failure gh
  printf '%s' "$login"
}

# check_vendor_credential — the agent CLI's login state, WITHOUT a network
# call, once per tick.
#
# The agent profile's bot_cli_present reads its own vendor's credential store
# and answers one boolean: usable, or not. Where a vendor records the expiry
# of the credential a HUMAN must renew (claude, kimi) the profile compares it
# against now; where the refresh token is opaque (codex, grok) presence is the
# best local answer and the profile says so by returning 2.
#
# bot_cli_probe (which may hit the network) is deliberately NOT called here.
# It stays for `crew hire` and the boot gate, where paying for certainty once
# is right; a per-tick check must be free.
check_vendor_credential() {
  if ! command -v bot_cli_present >/dev/null 2>&1; then
    return 0        # an older agent profile: report nothing, claim nothing
  fi
  # Three outcomes, not two. `|| rc=$?` rather than an if: the whole point is
  # the exact code, and under `set -e` a bare call returning 1 would kill the
  # tick. 2 means the profile cannot tell from local state — it must change
  # nothing, so a box whose vendor layout is unknown neither alerts falsely
  # nor has a stale failure silently cleared out from under it.
  local rc=0
  bot_cli_present || rc=$?
  case "$rc" in
    0) clear_auth_failure vendor ;;
    1) note_auth_failure vendor "${AGENT_LOGIN_HINT:-the agent CLI is not logged in}" ;;
    *) : ;;
  esac
  return 0
}

# --------------------------------------------------------------------------
# Git identity — the SECOND carrier of the box's login (#294).
#
# The builder-identity split rotated the gh credential on each box and touched
# nothing else that carries identity. git kept the pre-split account, so every
# commit a split box pushed was authored by another droid and GitHub bylined
# that droid on the builder's own PR. On 2026-08-02 that read as a two-box race
# on PR #292 when one box had done everything; the record's own operator could
# not tell the difference, and the investigation nearly filed the wrong bug.
#
# So identity has ONE source of truth — the gh credential — and every other
# carrier is DERIVED from it, never set beside it. That is the same rule #285
# found on the panel copy; this is the git copy.
#
# The address written is GitHub's ID-prefixed noreply form,
# `<id>+<login>@users.noreply.github.com`, because that is the form GitHub
# guarantees links a commit to an account for every account minted since
# 2017-07-18 — which is every account this fleet has. The bare
# `<login>@users.noreply.github.com` form is ACCEPTED and never WRITTEN: it
# bylines correctly for older accounts, and accepting it is what stops this
# code from rewriting a hand-swept box on every upgrade forever.
# --------------------------------------------------------------------------

# git_identity_login EMAIL — the GitHub login a noreply author address names,
# or nothing if the address is not one. Case-folded, because logins are
# case-insensitive and `git config` stores whatever was typed.
#
# Anything that is NOT a github noreply address names nobody here, on purpose.
# A box could in principle commit under a verified account email and byline
# correctly, but the fleet provisions noreply addresses only, so an address
# outside that shape is one nothing in this engine wrote — which is exactly
# the state #294 is about, and guessing at it would re-open the hole.
git_identity_login() {
  local email id
  email="${1:-}"
  # Trim the EDGES, never the middle. A value's leading/trailing space is a
  # shape a hand-edited config can still present, so trimming it reads the
  # address that was meant; whitespace INSIDE the address is a different
  # animal, and deleting it INVENTS an identity — `cnd grr@users.noreply.
  # github.com`, which GitHub attributes to nobody, would collapse into a
  # valid-looking `cndgrr` and green a box that bylines no account at all.
  # That is this file's own bug class one layer down, so an interior space
  # names nobody rather than being helpfully removed.
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  case "$email" in
    *[[:space:]]*) return 0 ;;
  esac
  email="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')"
  case "$email" in
    ?*@users.noreply.github.com) : ;;
    *) return 0 ;;
  esac
  email="${email%@users.noreply.github.com}"
  # Split at the FIRST '+': a GitHub login cannot contain one, so what precedes
  # it is the numeric account id and must look like one. A local part with a
  # non-numeric prefix is not an address GitHub issued, so it names nobody
  # rather than half-parsing into a login it does not carry.
  case "$email" in
    *+*)
      id="${email%%+*}"
      case "$id" in
        ''|*[!0-9]*) return 0 ;;
      esac
      email="${email#*+}"
      ;;
  esac
  [ -n "$email" ] || return 0
  printf '%s' "$email"
}

# git_identity_ok LOGIN — does git's configured author address resolve to
# LOGIN? The EMAIL decides and `user.name` does not: the address is what
# GitHub matches a commit to an account by, and the name is a display string
# that can attribute nothing. The name is still written on convergence, so the
# two halves of the byline agree for a human reading `git log`.
#
# `--global` is read DELIBERATELY, not by oversight. git resolves an author
# address from `GIT_AUTHOR_EMAIL`, then a repo-local `user.email`, then the
# global one — so this checks the last of three carriers. It is the only one
# the fleet has: nothing in shared/, cli/ or drill/ writes either of the other
# two (#294's audit, surface 3), and the global file is what convergence
# writes. Reading the EFFECTIVE identity instead would mean resolving it
# inside some repository, and converge_git_identity runs where there may not
# be one — trading a stated assumption for an unstated failure. If anything
# here ever starts exporting GIT_AUTHOR_EMAIL or writing a repo-local
# user.email, this check stops being the whole answer and must widen with it.
git_identity_ok() {
  local want have
  want="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ -n "$want" ] || return 1
  have="$(git_identity_login "$(git config --global user.email 2>/dev/null || true)")"
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# converge_git_identity [LOGIN] — make git's author identity name this box's
# own account. Returns 0 when git will byline this box, 1 when it would byline
# somebody else and that could not be repaired.
#
# CONVERGENCE, not a bare refusal, and the difference is load-bearing. #294
# proposed an assert that refuses on mismatch; a refusal alone is the
# stronger-sounding half of the fix and the weaker one in practice, because
# the gh credential arrives BY HAND after `crew hire` (`box shell <box>` →
# `gh auth login`). At provisioning time there is frequently no truth yet to
# copy, so a box that only refused would refuse every tick forever with
# nobody left to fix it — a fleet-wide brick shipped as a safety feature.
# Writing the copy at the first moment the source exists is what makes the
# invariant hold with no hand at all. The refusal is still here: it is what a
# non-zero return means, and duty.sh spends no session on one.
#
# The fast path is one local `git config` read and NO network — which is what
# every tick after the first pays. `gh api user` is called only when the copy
# is actually wrong, so the steady state costs nothing and the repair costs
# one request, once.
converge_git_identity() {
  local want="${1:-}" expect="${1:-}" pair id email had_email had_name
  local err rc=0 reason
  GIT_IDENTITY_FAILURE_KIND=""
  GIT_IDENTITY_FAILURE_EVIDENCE=""
  if [ -n "$want" ] && git_identity_ok "$want"; then
    return 0
  fi
  # One call for both halves: the login names the account and the id builds the
  # address GitHub attributes by. Asking twice could straddle a credential
  # rotation and write a login with another account's id.
  err="$(mktemp)"
  pair="$(gh api user --jq '[.login, .id] | @tsv' 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(grep -iE 'message|401|403|error' "$err" | head -1 || true)"
    reason="${reason:-gh api user exited $rc}"
    rm -f "$err"
    GIT_IDENTITY_FAILURE_KIND="credential"
    GIT_IDENTITY_FAILURE_EVIDENCE="$reason"
    return 1
  fi
  rm -f "$err"
  pair="$(printf '%s\n' "$pair" | head -1)"
  # Split in the shell rather than with `cut`. install.sh's fixture runs this
  # under a curated PATH that is the box's whole world, and every external
  # this reaches for is one more way a real install degrades into a diagnostic
  # nobody reads. A pair with no tab leaves id == want, which is not numeric
  # and is refused below — the malformed case needs no separate branch.
  want="${pair%%$'\t'*}"
  id="${pair#*$'\t'}"
  case "$id" in
    ''|*[!0-9]*) id="" ;;
  esac
  if [ -z "$want" ] || [ -z "$id" ]; then
    GIT_IDENTITY_FAILURE_KIND="identity"
    GIT_IDENTITY_FAILURE_EVIDENCE="gh api user returned an incomplete login/id response"
    warn "git identity: $GIT_IDENTITY_FAILURE_EVIDENCE — git config left untouched"
    return 1
  fi
  # The caller named a login; gh must still name the SAME one. duty.sh resolved
  # $ME from its own `gh api user` moments ago, and if the credential rotated
  # between that call and this one, converging on the login gh reports NOW
  # would write the new account, return 0, and hand the tick to a session
  # still running as the old $ME — sessions acting as one identity while
  # commits byline another, which is #294 restated one call later. So a
  # rotation refuses: write nothing, spend no session, and let the next tick
  # resolve both halves from a single consistent reading.
  if [ -n "$expect" ] &&
     [ "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" != \
       "$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "git identity: the gh credential now names '$want', but this tick is running as '$expect' — the credential rotated mid-tick; git config left untouched"
    GIT_IDENTITY_FAILURE_KIND="identity"
    GIT_IDENTITY_FAILURE_EVIDENCE="gh api user names '$want' while this tick names '$expect'"
    return 1
  fi
  # Re-checked against the login gh just reported rather than the caller's:
  # this is the no-argument call (install.sh, which has no $ME) and the case
  # where a hand sweep already wrote the bare-login form. Both are already
  # converged and owe no write and no announcement.
  if git_identity_ok "$want"; then
    return 0
  fi
  email="$id+$want@users.noreply.github.com"
  had_email="$(git config --global user.email 2>/dev/null || true)"
  had_name="$(git config --global user.name 2>/dev/null || true)"
  if ! git config --global user.email "$email" || ! git config --global user.name "$want"; then
    GIT_IDENTITY_FAILURE_KIND="identity"
    GIT_IDENTITY_FAILURE_EVIDENCE="git config could not replace '${had_email:-unset}' with '$email'"
    warn "git identity: could not write git config — this box would commit as '${had_email:-nobody}'"
    return 1
  fi
  # Read back rather than trust the write. A `git config` that exits 0 against
  # a file some other setting shadows leaves the byline wrong while reporting
  # success, and a silent false green here is the whole bug a second time.
  if ! git_identity_ok "$want"; then
    GIT_IDENTITY_FAILURE_KIND="identity"
    GIT_IDENTITY_FAILURE_EVIDENCE="git still reads '$(git config --global user.email 2>/dev/null || true)' after writing '$email'"
    warn "git identity: wrote $email, but git still reads '$(git config --global user.email 2>/dev/null || true)'"
    return 1
  fi
  log "git identity: converged to $want <$email> (was ${had_name:-unset} <${had_email:-unset}>)"
  # Once, by construction: the fast path above takes every later tick. An
  # operator learns that a box was committing under the wrong name at the
  # moment it stops, which is the only moment the fact is actionable.
  alert "🪪 $(hostname): git identity was <${had_email:-unset}> — now <$email> ($want)"
  return 0
}

# git_identity_failure_message LOGIN — turn converge_git_identity's result
# into the operator-facing refusal. The helper reports the identity observed
# at the failing call: a rejected credential is not guessed into a login,
# while a git mismatch names both the configured author and the login the
# successful API call returned. It performs no probe of its own.
git_identity_failure_message() {
  local login="$1" email
  if [ "${GIT_IDENTITY_FAILURE_KIND:-identity}" = "credential" ]; then
    printf 'GitHub credential used by gh api user failed — %s' \
      "${GIT_IDENTITY_FAILURE_EVIDENCE:-API rejection unavailable}"
    return 0
  fi
  email="$(git config --global user.email 2>/dev/null || true)"
  printf "git identity '%s' does not name GitHub login '%s' — %s" \
    "${email:-unset}" "$login" \
    "${GIT_IDENTITY_FAILURE_EVIDENCE:-git identity could not be repaired}"
}
