#!/usr/bin/env bash
# shared/test/model-prices.sh — standalone model-price subject suite (#572).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
RATE_CONF="$SHARED/conf/model-prices.conf"
# shellcheck source=shared/conf/model-prices.conf
source "$RATE_CONF"

cost() { model_token_cost_usd "$@"; }
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

# Prices are a current view over an immutable record: changing only operator
# data must re-price the same already-captured token facts.
before="$(cost claude claude-haiku-4-5 'input_tokens=1000000 output_tokens=0')"
MODEL_TOKEN_RATES[1]='claude|claude-haiku-4-5|2|5|1.25|0.10'
after="$(cost claude claude-haiku-4-5 'input_tokens=1000000 output_tokens=0')"
t model-prices-history-reprices '1|2' "$before|$after"

suite_finish
