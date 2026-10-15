#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3
require_command curl
require_command ss

# Two steps on purpose: in one assignment the XDG values expand against the
# real HOME, and the receiver would write into the live state directory.
export HOME=$(mktemp -d)
export XDG_CONFIG_HOME=$HOME/.config XDG_STATE_HOME=$HOME/.local/state XDG_DATA_HOME=$HOME/.local/share XDG_CACHE_HOME=$HOME/.cache
unset CLAUDE_CONFIG_DIR

SERVER_PID=""
cleanup() {
  if [[ -n $SERVER_PID ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$HOME"
}
trap cleanup EXIT

otel_dir="$XDG_STATE_HOME/omarchy/agents/otel"
summary="$otel_dir/summary.json"
fixture="$SHELL_TEST_DIR/fixtures/agent-otel/logs.json"

main_uuid=11111111-1111-4111-8111-111111111111
extra_uuid=22222222-2222-4222-8222-222222222222

# The default account and one extra, the way omarchy-agent-usage-claude
# finds them, so the uuid -> record id mapping is exercised.
mkdir -p "$XDG_CONFIG_HOME/omarchy/agents" "$HOME/.claude-extra"
printf '{"oauthAccount":{"accountUuid":"%s"}}\n' "$main_uuid" >"$HOME/.claude.json"
printf '{"oauthAccount":{"accountUuid":"%s"}}\n' "$extra_uuid" >"$HOME/.claude-extra/.claude.json"
printf '[{"id":"extra","name":"Claude Extra","dir":"~/.claude-extra"}]\n' >"$XDG_CONFIG_HOME/omarchy/agents/claude-accounts.json"

# Port 0: the kernel picks a free one, so a real receiver on 4318 is never in
# the way and never hit.
log="$HOME/serve.log"
"$ROOT/bin/omarchy-agent-otel" serve --port 0 --rollup-interval 0.3 >"$log" 2>&1 &
SERVER_PID=$!

port=""
for _ in $(seq 1 50); do
  port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$log")
  [[ -n $port ]] && break
  sleep 0.1
done
[[ -n $port && $port != 4318 ]] || fail "receiver starts on an ephemeral port" "$(cat "$log")"
pass "receiver starts on an ephemeral port"

[[ $(ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}') == "127.0.0.1:$port" ]] ||
  fail "receiver listens on loopback only" "$(ss -ltn "sport = :$port" 2>&1)"
pass "receiver listens on loopback only"

# Build one export from the captured records, stamped now so the sessions are
# live and the costs land today:
#   session A (main, bounty B-101 slot s2): two API requests and then twelve
#     failed Bash calls in a row -> looping
#   session B (main, ticket T-7 only): one request and one good Read
#   session C (extra account, bounty B-202): one request
#   session D (main): 41 good tool calls and no API cost -> looping (burst)
payload="$HOME/payload.json"
python3 - "$fixture" "$payload" "$main_uuid" "$extra_uuid" <<'PY'
import copy, json, sys, time
fixture, out, main_uuid, extra_uuid = sys.argv[1:5]
template = json.load(open(fixture))
resource_logs = template["resourceLogs"][0]
by_name = {r["body"]["stringValue"]: r for r in resource_logs["scopeLogs"][0]["logRecords"]}
now_ns = time.time_ns()

def record(name, ns, overrides):
  r = copy.deepcopy(by_name[name])
  r["timeUnixNano"] = r["observedTimeUnixNano"] = str(ns)
  keep = []
  for a in r["attributes"]:
    if a["key"] in overrides:
      if overrides[a["key"]] is None:
        continue
      a["value"] = overrides[a["key"]]
    keep.append(a)
  for key, value in overrides.items():
    if value is not None and key not in {a["key"] for a in keep}:
      keep.append({"key": key, "value": value})
  r["attributes"] = keep
  return r

s = lambda v: {"stringValue": v}
tags_a = {"bounty.id": s("B-101"), "bounty.slot": s("s2"), "bounty.attempt": s("3"), "ticket": None}
tags_b = {"bounty.id": None, "bounty.slot": None, "bounty.attempt": None, "ticket": s("T-7")}
tags_c = {"bounty.id": s("B-202"), "bounty.slot": s("s1"), "bounty.attempt": s("1"), "ticket": None}

def ident(session, uuid, tags):
  return dict(tags, **{"session.id": s(session), "user.account_uuid": s(uuid)})

records = []
t = now_ns - 30 * 10**9
a = ident("aaaaaaaa-0000-4000-8000-00000000000a", main_uuid, tags_a)
records.append(record("claude_code.user_prompt", t, a))
records.append(record("claude_code.api_request", t + 1, dict(a, cost_usd={"doubleValue": 0.5}, model=s("claude-opus-4-8"), input_tokens={"intValue": "100"}, output_tokens={"intValue": 50})))
records.append(record("claude_code.api_request", t + 2, dict(a, cost_usd={"doubleValue": 0.25}, model=s("claude-opus-4-8"))))
for i in range(12):
  records.append(record("claude_code.tool_result", t + 10 + i, dict(a, tool_name=s("Bash"), success=s("false"))))

b = ident("bbbbbbbb-0000-4000-8000-00000000000b", main_uuid, tags_b)
records.append(record("claude_code.api_request", t + 100, dict(b, cost_usd={"doubleValue": 0.1}, model=s("claude-haiku-4-5-20251001"))))
records.append(record("claude_code.tool_result", t + 101, dict(b, tool_name=s("Read"), success={"boolValue": True})))

d = ident("dddddddd-0000-4000-8000-00000000000d", main_uuid, tags_b)
for i in range(41):
  records.append(record("claude_code.tool_result", t + 300 + i, dict(d, tool_name=s(["Read", "Grep", "Glob"][i % 3]), success=s("true"))))

c = ident("cccccccc-0000-4000-8000-00000000000c", extra_uuid, tags_c)
records.append(record("claude_code.api_request", t + 200, dict(c, cost_usd={"doubleValue": 2.0}, model=s("claude-sonnet-5"))))

# The resource carries no tags of its own here, so attribution has to come
# from the record attributes; session B must not inherit A's bounty.
resource_logs["resource"]["attributes"] = [x for x in resource_logs["resource"]["attributes"] if x["key"] not in ("bounty.id", "bounty.slot", "bounty.attempt", "ticket")]
resource_logs["scopeLogs"][0]["logRecords"] = records
json.dump(template, open(out, "w"))
PY

code=$(curl -s -o "$HOME/reply.json" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary @"$payload" "http://127.0.0.1:$port/v1/logs")
[[ $code == 200 ]] || fail "receiver accepts an OTLP JSON logs export" "HTTP $code: $(cat "$HOME/reply.json")"
pass "receiver accepts an OTLP JSON logs export"

for path in /v1/metrics /v1/traces; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary '{"resourceMetrics":[]}' "http://127.0.0.1:$port$path")
  [[ $code == 200 ]] || fail "receiver acknowledges $path" "HTTP $code"
done
pass "receiver acknowledges metrics and traces"

code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/x-protobuf' \
  --data-binary 'x' "http://127.0.0.1:$port/v1/logs")
[[ $code == 415 ]] || fail "receiver refuses protobuf logs it cannot read" "HTTP $code"
pass "receiver refuses protobuf logs it cannot read"

for _ in $(seq 1 50); do
  [[ -f $summary ]] && jq -e '.accounts.claude.live | length == 3' "$summary" >/dev/null 2>&1 && break
  sleep 0.1
done
[[ -f $summary ]] || fail "receiver writes summary.json" "$(cat "$log")"
pass "receiver writes summary.json"

check() {
  local description="$1" filter="$2"
  jq -e "$filter" "$summary" >/dev/null || fail "$description" "$(jq . "$summary")"
  pass "$description"
}

check "summary labels costs as API list price equivalent" '.costBasis == "API list price equivalent"'
check "accounts map to the panel's record ids" '(.accounts | keys) == ["claude", "claude-extra"]'
check "today's cost totals every account" '(.todayCostUsd * 1000 | round) == 2850'
check "today's cost per account" '(.accounts.claude.today.costUsd * 1000 | round) == 850 and .accounts.claude.today.requests == 3'
check "cost is attributed to the bounty id" '.accounts.claude.byBounty[0] | .bounty == "B-101" and (.costUsd * 100 | round) == 75 and .sessions == 1'
check "a ticket stands in for a missing bounty id" '[.accounts.claude.byBounty[] | select(.bounty == "T-7")] | length == 1'
check "the extra account keeps its own bounty" '.accounts["claude-extra"].byBounty | length == 1 and .[0].bounty == "B-202" and .[0].costUsd == 2'
check "cost by model is split per model" '[.accounts.claude.byModel[].model] == ["claude-opus-4-8", "claude-haiku-4-5-20251001"]'
check "string token counts are read as numbers" '[.accounts.claude.live[] | select(.session == "aaaaaaaa")][0].tokens >= 150'
check "a session failing the same tool over and over is flagged looping" \
  '[.accounts.claude.live[] | select(.session == "aaaaaaaa")][0] | .looping == true and .toolCalls == 12 and .toolFailures == 12 and .bounty == "B-101" and .slot == "s2" and .attempt == "3"'
check "a burst of tool calls with no API cost is flagged looping" \
  '[.accounts.claude.live[] | select(.session == "dddddddd")][0] | .looping == true and (.loopReason | test("41 tool calls"))'
check "looping sessions sort first" '[.accounts.claude.live[].looping] == [true, true, false]'
check "a healthy session is not flagged" \
  '[.accounts.claude.live[] | select(.session == "bbbbbbbb")][0] | .looping == false and .ticket == "T-7" and (has("bounty") | not) and .toolCalls == 1'

events_file=$(ls "$otel_dir"/events-*.jsonl | head -1)
[[ -n $events_file ]] || fail "events are appended to a dated jsonl file"
pass "events are appended to a dated jsonl file"

if grep -rq -e 'SECRET-PROMPT-TEXT' -e 'example.com' -e 'user_0000' -e '00000000-0000-4000-8000-000000000000' "$otel_dir"; then
  fail "prompt text, email and organization ids are never stored" "$(grep -r -e SECRET -e example.com "$otel_dir")"
fi
pass "prompt text, email and organization ids are never stored"

[[ $(jq -s 'map(.kind) | unique' "$events_file" | jq -c .) == '["api","tool"]' ]] ||
  fail "only api_request and tool_result events are kept" "$(cat "$events_file")"
pass "only api_request and tool_result events are kept"

# An old event file falls out of the 14-day retention when the receiver starts.
touch "$otel_dir/events-2000-01-01.jsonl"
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

rm -f "$summary"
"$ROOT/bin/omarchy-agent-otel" rollup
[[ ! -e $otel_dir/events-2000-01-01.jsonl ]] || fail "event files older than 14 days are pruned"
pass "event files older than 14 days are pruned"
check "rollup rebuilds the summary from the event files" '.accounts.claude.live[0].looping == true and (.todayCostUsd * 1000 | round) == 2850'

"$ROOT/bin/omarchy-agent-otel" status | jq -e '.accounts.claude' >/dev/null ||
  fail "status prints the summary"
pass "status prints the summary"
