#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

export XDG_STATE_HOME="$TEST_HOME/state" XDG_CONFIG_HOME="$TEST_HOME/config"
value_dir="$XDG_STATE_HOME/omarchy/agents/value"
usage_dir="$XDG_STATE_HOME/omarchy/agents/usage"
mkdir -p "$value_dir" "$usage_dir" "$XDG_CONFIG_HOME/omarchy/agents"

# Max 20x is $200/mo = $46.15/week. 10% of the week is $4.615.
cat >"$value_dir/claude.jsonl" <<'LOG'
{"t":"2026-09-01T10:00:00-07:00","plan":"Max 20x","limits":{"Weekly (7-day)":0.10},"models":{"claude-opus-5-5":[0,0,0,0]}}
{"t":"2026-09-01T12:00:00-07:00","plan":"Max 20x","limits":{"Weekly (7-day)":0.20},"models":{"claude-opus-5-5":[0,1000000,0,461500000]}}
{"t":"2026-09-01T13:00:00-07:00","plan":"Max 20x","limits":{"Weekly (7-day)":0.21},"models":{"claude-opus-5-5":[0,1000000,0,400000000]}}
{"t":"2026-09-02T09:00:00-07:00","plan":"Max 20x","limits":{"Weekly (7-day)":0.01},"models":{"claude-opus-5-5":[0,1000000,0,999000000]}}
LOG

"$ROOT/bin/omarchy-agent-value" build || fail "value build runs"
summary="$value_dir/claude.json"

[[ $(jq -r '.weeklyPrice' "$summary") == "46.15" ]] ||
  fail "value prices the week from the plan" "$(cat "$summary")"
pass "value prices the week from the plan"

[[ $(jq -r '.points | length' "$summary") == 1 && $(jq -r '.points[0].date' "$summary") == "2026-09-01" ]] ||
  fail "value skips the interval across a weekly reset" "$(cat "$summary")"
pass "value skips the interval across a weekly reset"

# 462.5M tokens over 11% ($5.08) = ~91M per dollar; the shrinking cache count
# (deleted transcripts) adds nothing rather than going negative.
[[ $(jq -r '.points[0].tokens' "$summary") == "462500000" ]] ||
  fail "value ignores shrinking token totals" "$(cat "$summary")"
pass "value ignores shrinking token totals"

per_dollar=$(jq -r '.points[0].tokensPerDollar' "$summary")
(( per_dollar > 90000000 && per_dollar < 92000000 )) ||
  fail "value divides tokens by the dollars the week meter moved" "$per_dollar"
pass "value divides tokens by the dollars the week meter moved"

# 1M output at $20 + 461.5M cache reads at $0.20 = $112.30 over $5.08.
api=$(jq -r '.points[0].apiValuePerDollar' "$summary")
[[ $api == "22.12" ]] || fail "value prices Claude usage at API rates" "$api"
pass "value prices Claude usage at API rates"

echo '{"monthlyPrice":100}' >"$XDG_CONFIG_HOME/omarchy/agents/claude.json"
"$ROOT/bin/omarchy-agent-value" build
[[ $(jq -r '.priceSource + " " + (.monthlyPrice|tostring)' "$summary") == "config 100" ]] ||
  fail "value prefers the configured monthly price" "$(cat "$summary")"
pass "value prefers the configured monthly price"

cat >"$usage_dir/claude.json" <<'JSON'
{"id":"claude","tierLabel":"Max 20x","limits":[{"label":"Weekly (7-day)","percent":0.05},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.5}],"modelUsage":{"claude-opus-5-5":{"inputTokens":1,"outputTokens":2,"cacheCreationInputTokens":3,"cacheReadInputTokens":4}}}
JSON
lines_before=$(wc -l <"$value_dir/claude.jsonl")
"$ROOT/bin/omarchy-agent-value" record
"$ROOT/bin/omarchy-agent-value" record
lines_after=$(wc -l <"$value_dir/claude.jsonl")
(( lines_after == lines_before + 1 )) || fail "record appends one snapshot per change" "$lines_before -> $lines_after"
pass "record appends one snapshot per change"

tail -1 "$value_dir/claude.jsonl" | jq -e '.limits == {"Weekly (7-day)":0.05} and .models["claude-opus-5-5"] == [1,2,3,4]' >/dev/null ||
  fail "record keeps account-wide windows and per-model token counts" "$(tail -1 "$value_dir/claude.jsonl")"
pass "record keeps account-wide windows and per-model token counts"

echo '{"id":"fireworks","limits":[],"modelUsage":{}}' >"$usage_dir/fireworks.json"
"$ROOT/bin/omarchy-agent-value" record
[[ ! -e $value_dir/fireworks.jsonl ]] || fail "record skips agents without a weekly allowance"
pass "record skips agents without a weekly allowance"

# Two accounts: Main (Max 20x, $46.15/week) moves 10% and Work (Pro, $4.62/week)
# moves 20% then 10% more, so the day cost $4.615 + $0.923 + $0.462. Token
# counts are shared.
rm -f "$XDG_CONFIG_HOME/omarchy/agents/claude.json" "$value_dir"/claude.*
cat >"$value_dir/claude.jsonl" <<'LOG'
{"t":"2026-09-03T10:00:00-07:00","plan":"Max 20x","limits":{"Weekly (7-day)":0.10},"accounts":{"main":{"plan":"Max 20x","limits":{"Weekly (7-day)":0.10}},"work":{"plan":"Pro","limits":{"Weekly (7-day)":0.30}}},"models":{"claude-opus-5-5":[0,0,0,0]}}
{"t":"2026-09-03T12:00:00-07:00","plan":"Pro","limits":{"Weekly (7-day)":0.50},"accounts":{"main":{"plan":"Max 20x","limits":{"Weekly (7-day)":0.20}},"work":{"plan":"Pro","limits":{"Weekly (7-day)":0.50}}},"models":{"claude-opus-5-5":[0,0,0,553800000]}}
{"t":"2026-09-03T13:00:00-07:00","plan":"Pro","limits":{"Weekly (7-day)":0.60},"accounts":{"main":{"plan":"Max 20x","limits":{"Weekly (7-day)":0.20}},"work":{"plan":"Pro","limits":{"Weekly (7-day)":0.60}}},"models":{"claude-opus-5-5":[0,0,0,553800000]}}
{"t":"2026-09-03T14:00:00-07:00","plan":"Pro","limits":{"Weekly (7-day)":0.70},"accounts":{"work":{"plan":"Pro","limits":{"Weekly (7-day)":0.70}}},"models":{"claude-opus-5-5":[0,0,0,999000000]}}
LOG
"$ROOT/bin/omarchy-agent-value" build
dollars=$(jq -r '.points[0].dollars' "$summary")
[[ $dollars == "6.0" ]] || fail "value sums each account's share of its own plan" "$(cat "$summary")"
pass "value sums each account's share of its own plan"

[[ $(jq -r '.points[0].tokens' "$summary") == "553800000" ]] ||
  fail "value skips an interval whose accounts changed" "$(cat "$summary")"
pass "value skips an interval whose accounts changed"

cat >"$usage_dir/claude.json" <<'JSON'
{"id":"claude","tierLabel":"Pro","limits":[{"label":"Weekly (7-day)","percent":0.7}],"accounts":[{"id":"main","plan":"Max 20x","limits":[{"label":"Weekly (7-day)","percent":0.2},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.9}]},{"id":"work","plan":"Pro","active":true,"limits":[{"label":"Weekly (7-day)","percent":0.7}]}],"modelUsage":{"claude-opus-5-5":{"inputTokens":1,"outputTokens":2,"cacheCreationInputTokens":3,"cacheReadInputTokens":4}}}
JSON
"$ROOT/bin/omarchy-agent-value" record claude
tail -1 "$value_dir/claude.jsonl" | jq -e '.accounts == {"main":{"limits":{"Weekly (7-day)":0.2},"plan":"Max 20x"},"work":{"limits":{"Weekly (7-day)":0.7},"plan":"Pro"}}' >/dev/null ||
  fail "record keeps every account's weekly meter and plan" "$(tail -1 "$value_dir/claude.jsonl")"
pass "record keeps every account's weekly meter and plan"
