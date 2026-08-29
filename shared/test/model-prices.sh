#!/usr/bin/env bash
# shared/test/model-prices.sh — standalone model-price subject suite (#572).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
RATE_CONF="$SHARED/conf/model-prices.conf"
SESSION_MOD="$SHARED/lib/common/session.sh"
# shellcheck source=shared/conf/model-prices.conf
source "$RATE_CONF"

cost() { model_token_cost_usd "$@"; }
matches_reported() { model_token_cost_matches_reported "$@"; }
record_value() {
  local name="$1" record="$2" field
  for field in $record; do
    [ "${field%%=*}" = "$name" ] || continue
    printf '%s' "${field#*=}"
    return 0
  done
  return 1
}
outcome() {
  local out rc
  out="$(cost "$@")"; rc=$?
  printf '%s|%s' "$rc" "$out"
}

# The data file is a sourceable operator surface, not an executable side
# effect. Every shipped row carries the citation and the date at its source.
t model-prices-source-is-silent '' "$(bash -c '. "$1"' _ "$RATE_CONF" 2>&1)"
t model-prices-declares-reader function "$(type -t model_token_cost_usd)"
t model-prices-citation-is-official 1 \
  "$(grep -c '^  # https://platform.claude.com/docs/en/about-claude/pricing$' "$RATE_CONF")"
t model-prices-citation-has-read-date 1 "$(grep -c '^  # Anthropic, read 2026-08-29:$' "$RATE_CONF")"
t model-prices-session-end-has-no-computed-cost-field 0 \
  "$(grep -c 'computed_cost_usd=' "$SESSION_MOD" || true)"

record='input_tokens=120 output_tokens=34 cache_creation_input_tokens=5 cache_read_input_tokens=77'
t model-prices-known-model-computes 0.00091185 \
  "$(cost claude claude-sonnet-4-6 "$record")"
t model-prices-unknown-model-is-no-figure '1|' \
  "$(outcome claude claude-does-not-exist "$record")"
t model-prices-explicit-unknown-is-no-figure '1|' \
  "$(outcome claude unknown "$record")"
t model-prices-zero-is-a-real-measurement '0|0' \
  "$(outcome claude claude-sonnet-4-6 'input_tokens=0 output_tokens=0')"
t model-prices-malformed-token-is-no-figure '1|' \
  "$(outcome claude claude-sonnet-4-6 'input_tokens=many output_tokens=2')"
t model-prices-missing-required-token-is-no-figure '1|' \
  "$(outcome claude claude-sonnet-4-6 'input_tokens=2')"

# A vendor may price ordinary input/output without defining either cache class.
# Missing cache fields are absent facts and price normally; a present field,
# including a measured zero, requires that class to have a declared rate.
MODEL_TOKEN_RATES+=('fixture|partial-model|2|8|-|-')
t model-prices-partial-model-prices-declared-classes 0.000018 \
  "$(cost fixture partial-model 'input_tokens=5 output_tokens=1')"
t model-prices-partial-model-rejects-unpriced-cache '1|' \
  "$(outcome fixture partial-model 'input_tokens=5 output_tokens=1 cache_read_input_tokens=2')"
t model-prices-partial-model-rejects-explicit-zero-unpriced-cache '1|' \
  "$(outcome fixture partial-model 'input_tokens=5 output_tokens=1 cache_creation_input_tokens=0')"

# Required input/output classes are exercised even when their measured count
# is zero. An operator edit that leaves any exercised rate unusable must never
# be coerced by awk into a successful zero or partial figure.
MODEL_TOKEN_RATES+=(
  'fixture|no-input|-|8|1|0.1'
  'fixture|no-output|2|-|1|0.1'
  'fixture|malformed-input|abc|8|1|0.1'
  'fixture|empty-input||8|1|0.1'
  'fixture|malformed-cache|2|8|abc|0.1'
)
t model-prices-unpriced-input-is-no-figure '1|' \
  "$(outcome fixture no-input 'input_tokens=5 output_tokens=1')"
t model-prices-unpriced-output-is-no-figure '1|' \
  "$(outcome fixture no-output 'input_tokens=5 output_tokens=1')"
t model-prices-zero-input-still-requires-rate '1|' \
  "$(outcome fixture no-input 'input_tokens=0 output_tokens=1')"
t model-prices-zero-output-still-requires-rate '1|' \
  "$(outcome fixture no-output 'input_tokens=5 output_tokens=0')"
t model-prices-malformed-input-rate-is-no-figure '1|' \
  "$(outcome fixture malformed-input 'input_tokens=5 output_tokens=1')"
t model-prices-empty-input-rate-is-no-figure '1|' \
  "$(outcome fixture empty-input 'input_tokens=5 output_tokens=1')"
t model-prices-malformed-cache-rate-is-no-figure '1|' \
  "$(outcome fixture malformed-cache 'input_tokens=5 output_tokens=1 cache_creation_input_tokens=2')"

# This rate-derived envelope proves that Claude's SESSION END field mapping and
# the comparison harness agree; it deliberately does not prove the shipped
# rate. #585 checks the rate against a real billed session. One nanodollar is
# the tolerance because the reader emits USD to nine decimal places: it absorbs
# only that display precision, not a materially different reported figure.
claude_record='input_tokens=120 output_tokens=34 cache_creation_input_tokens=5 cache_read_input_tokens=77 cost_usd=0.00091185 session_id=session%2Fone model=claude-sonnet-4-6'
claude_model="$(record_value model "$claude_record")"
claude_reported="$(record_value cost_usd "$claude_record")"
t model-prices-rate-derived-envelope-is-within-tolerance 0 \
  "$(matches_reported claude "$claude_model" "$claude_record" "$claude_reported" 0.000000001; printf '%s' "$?")"
t model-prices-out-of-band-envelope-fails 1 \
  "$(matches_reported claude "$claude_model" "$claude_record" 0.000911852 0.000000001; printf '%s' "$?")"

# Prices are a current view over an immutable record: changing only operator
# data must re-price the same already-captured token facts.
before="$(cost claude claude-haiku-4-5 'input_tokens=1000000 output_tokens=0')"
MODEL_TOKEN_RATES[1]='claude|claude-haiku-4-5|2|5|1.25|0.10'
after="$(cost claude claude-haiku-4-5 'input_tokens=1000000 output_tokens=0')"
t model-prices-history-reprices '1|2' "$before|$after"

suite_finish
