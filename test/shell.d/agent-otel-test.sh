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
tags_a = {"project": s("alpha"), "agent.name": s("Mercury"), "bounty.id": s("B-101"), "bounty.slot": s("s2"), "bounty.attempt": s("3"), "ticket": None}
tags_b = {"project": None, "agent.name": None, "bounty.id": None, "bounty.slot": None, "bounty.attempt": None, "ticket": s("T-7")}
tags_c = {"project": s("beta"), "agent.name": s("Azoth"), "bounty.id": s("B-202"), "bounty.slot": s("s1"), "bounty.attempt": s("1"), "ticket": None}

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
resource_logs["resource"]["attributes"] = [x for x in resource_logs["resource"]["attributes"] if x["key"] not in ("project", "agent.name", "bounty.id", "bounty.slot", "bounty.attempt", "ticket")]
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
check "cost is attributed to the bounty id under its project" '.accounts.claude.byBounty[0] | .bounty == "alpha/B-101" and (.costUsd * 100 | round) == 75 and .sessions == 1'
check "cost and tokens are attributed to the named agent under its project" \
  '.accounts.claude.byAgent[0] | .agent == "alpha/Mercury" and .project == "alpha" and .name == "Mercury" and (.costUsd * 100 | round) == 75 and .tokens >= 150 and .sessions == 1 and .live == true and .model == "claude-opus-4-8"'
check "a live session carries its project and agent name" '[.accounts.claude.live[] | select(.session == "aaaaaaaa")][0] | .project == "alpha" and .agent == "Mercury"'
check "a ticket stands in for a missing bounty id" '[.accounts.claude.byBounty[] | select(.bounty == "T-7")] | length == 1'
check "the extra account keeps its own bounty" '.accounts["claude-extra"].byBounty | length == 1 and .[0].bounty == "beta/B-202" and .[0].costUsd == 2'
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

# ------------------------------------------------------------------ history

history_dir="$otel_dir/history"
limits_history="$XDG_STATE_HOME/omarchy/agents/history"
today=$(date +%F)
yday=$(date -d yesterday +%F)
old=$(date -d '20 days ago' +%F)

# Yesterday's raw events: two requests on bounty B-9, one per model, and one
# untagged request.
noon=$(date -d "$yday 12:00" +%s)
{
  printf '{"kind":"api","ts":%s,"session":"s-9","account":"%s","project":"alpha","agent":"Mercury","bounty":"B-9","slot":"s2","model":"claude-opus-4-8","cost":1.25,"in":10,"out":20,"cacheRead":0,"cacheWrite":0}\n' "$noon" "$main_uuid"
  printf '{"kind":"api","ts":%s,"session":"s-9","account":"%s","project":"alpha","agent":"Mercury","bounty":"B-9","slot":"s2","model":"claude-haiku-4-5","cost":0.25,"in":1,"out":2,"cacheRead":3,"cacheWrite":4}\n' "$((noon + 60))" "$main_uuid"
  printf '{"kind":"api","ts":%s,"session":"s-0","account":"%s","model":"claude-opus-4-8","cost":0.5,"in":1,"out":1,"cacheRead":0,"cacheWrite":0}\n' "$((noon + 120))" "$main_uuid"
  # Session s-9 again, this time without its tags: it was tagged above, so the
  # receiver attributes this one to the same project and agent.
  printf '{"kind":"api","ts":%s,"session":"s-9","account":"%s","bounty":"B-9","slot":"s2","model":"claude-opus-4-8","cost":0.5,"in":5,"out":5,"cacheRead":0,"cacheWrite":0}\n' "$((noon + 125))" "$main_uuid"
  printf '{"kind":"tool","ts":%s,"session":"s-9","account":"%s","tool":"Bash","ok":true,"ms":5}\n' "$((noon + 130))" "$main_uuid"
} >"$otel_dir/events-$yday.jsonl"

# A day whose event file is long gone, as an earlier receiver left it.
old_line() {
  mkdir -p "$history_dir"
  printf '{"account":"claude","accountUuid":"%s","byBounty":{"B-old":{"byModel":{"claude-opus-4-8":7},"costUsd":7,"requests":1,"sessions":1,"tokens":70}},"byModel":{"claude-opus-4-8":{"costUsd":7,"requests":1,"tokens":70}},"costUsd":7,"day":"%s","requests":1,"tokens":70}\n' \
    "$main_uuid" "$old" >>"$history_dir/${old:0:7}.jsonl"
}
old_line

"$ROOT/bin/omarchy-agent-otel" rollup

hline() {
  jq -c --arg day "$1" --arg account "$2" 'select(.day == $day and .account == $account)' "$history_dir/${1:0:7}.jsonl"
}

[[ -n $(hline "$yday" claude) ]] || fail "rollup backfills yesterday from its event file" "$(cat "$history_dir"/*.jsonl)"
pass "rollup backfills yesterday from its event file"

hline "$yday" claude | jq -e '(.costUsd * 100 | round) == 250 and .requests == 4 and .tokens == 52' >/dev/null ||
  fail "a day's rollup totals its requests" "$(hline "$yday" claude)"
pass "a day's rollup totals its requests"

hline "$yday" claude | jq -e '.byBounty["alpha/B-9"] | (.costUsd * 100 | round) == 200 and .sessions == 1 and .byModel["claude-opus-4-8"].costUsd == 1.75 and .byModel["claude-opus-4-8"].tokens == 40 and .byModel["claude-haiku-4-5"].costUsd == 0.25' >/dev/null ||
  fail "a day's rollup splits each bounty by model, cost and tokens" "$(hline "$yday" claude)"
pass "a day's rollup splits each bounty by model, cost and tokens"

hline "$yday" claude | jq -e '.byAgent["alpha/Mercury"] | (.costUsd * 100 | round) == 200 and .tokens == 50 and .requests == 3 and .sessions == 1 and .byModel["claude-opus-4-8"].tokens == 40' >/dev/null ||
  fail "a day's rollup totals each named agent under its project, untagged events of a known session included" "$(hline "$yday" claude)"
pass "a day's rollup totals each named agent under its project, untagged events of a known session included"

hline "$yday" claude | jq -e '.byModel | keys == ["claude-haiku-4-5", "claude-opus-4-8"]' >/dev/null ||
  fail "a day's rollup splits cost by model" "$(hline "$yday" claude)"
pass "a day's rollup splits cost by model"

[[ -n $(hline "$today" claude) && -n $(hline "$today" claude-extra) ]] ||
  fail "today's rollup has a line per account" "$(cat "$history_dir"/*.jsonl)"
pass "today's rollup has a line per account"

hline "$old" claude | jq -e '.costUsd == 7' >/dev/null ||
  fail "days older than the raw events are kept as they were" "$(cat "$history_dir/${old:0:7}.jsonl")"
pass "days older than the raw events are kept as they were"

before=$(cat "$history_dir"/*.jsonl | sha256sum)
stamp=$(stat -c %Y.%N "$history_dir/${yday:0:7}.jsonl")
"$ROOT/bin/omarchy-agent-otel" rollup
[[ $(cat "$history_dir"/*.jsonl | sha256sum) == "$before" && $(stat -c %Y.%N "$history_dir/${yday:0:7}.jsonl") == "$stamp" ]] ||
  fail "an unchanged rollup leaves the history files alone"
pass "an unchanged rollup leaves the history files alone"

# The receiver backfills on start, too.
rm -rf "$history_dir"
"$ROOT/bin/omarchy-agent-otel" serve --port 0 --rollup-interval 0.3 >"$log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  [[ -n $(hline "$yday" claude 2>/dev/null) ]] && break
  sleep 0.1
done
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
[[ -n $(hline "$yday" claude 2>/dev/null) ]] || fail "the receiver backfills the history when it starts" "$(cat "$log")"
pass "the receiver backfills the history when it starts"
old_line

# ------------------------------------------------------------ limit history

record="$HOME/claude-record.json"
write_record() {
  printf '{"id":"claude","limits":[{"label":"Session (5-hour)","percent":%s},{"label":"Weekly (7-day)","percent":%s},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.5}]}\n' "$1" "$2" >"$record"
}
limit_lines() { cat "$limits_history"/limits-*.jsonl 2>/dev/null | jq -c "select(.agent == \"$1\")" | wc -l; }

write_record 0.1 0.4
"$ROOT/bin/omarchy-agent-limits-history" claude "$record"
"$ROOT/bin/omarchy-agent-limits-history" claude "$record"
[[ $(limit_lines claude) == 1 ]] || fail "unchanged limits are recorded once" "$(cat "$limits_history"/limits-*.jsonl)"
pass "unchanged limits are recorded once"

cat "$limits_history"/limits-*.jsonl | jq -e 'select(.agent == "claude") | .session == 0.1 and .weekly == 0.4 and .models["Fable Weekly"] == 0.5 and (.ts | type) == "number"' >/dev/null ||
  fail "a limit line carries session, weekly and model-scoped percentages" "$(cat "$limits_history"/limits-*.jsonl)"
pass "a limit line carries session, weekly and model-scoped percentages"

write_record 0.1 0.45
"$ROOT/bin/omarchy-agent-limits-history" claude "$record"
[[ $(limit_lines claude) == 2 ]] || fail "a changed limit appends a line" "$(cat "$limits_history"/limits-*.jsonl)"
pass "a changed limit appends a line"

printf '{"id":"claude","limits":[]}\n' >"$record"
"$ROOT/bin/omarchy-agent-limits-history" claude "$record"
[[ $(limit_lines claude) == 2 ]] || fail "a refresh without limits records nothing"
pass "a refresh without limits records nothing"

# omarchy-agent-usage-update records every record it writes.
fake="$HOME/fake-omarchy"
mkdir -p "$fake/bin"
printf '#!/bin/bash\necho %s\n' "'{\"id\":\"codex\",\"limits\":[{\"label\":\"Weekly (7-day)\",\"percent\":0.2}]}'" >"$fake/bin/omarchy-agent-usage-codex"
chmod +x "$fake/bin/omarchy-agent-usage-codex"
ln -s "$ROOT/bin/omarchy-agent-limits-history" "$fake/bin/omarchy-agent-limits-history"
OMARCHY_PATH="$fake" "$ROOT/bin/omarchy-agent-usage-update" codex
[[ $(limit_lines codex) == 1 ]] || fail "usage-update records the limits of each record it writes"
pass "usage-update records the limits of each record it writes"

# ------------------------------------------------------------ history read

report="$HOME/history.json"
"$ROOT/bin/omarchy-agent-otel" history --range 30d >"$report"
hcheck() {
  jq -e "$2" "$report" >/dev/null || fail "$1" "$(jq -c . "$report" | head -c 3000)"
  pass "$1"
}
hcheck "history covers the range day by day up to today" \
  ".range == \"30d\" and (.days | length) == 30 and .days[-1] == \"$today\""
hcheck "history reads each day's cost from the rollup" \
  "[.accounts[] | select(.id == \"claude\") | .perDay[] | select(.day == \"$yday\")][0] | (.costUsd * 100 | round) == 250"
hcheck "history keeps days older than the raw events" \
  "[.accounts[] | select(.id == \"claude\") | .perDay[] | select(.day == \"$old\")][0].costUsd == 7"
hcheck "history ranks bounties over the range, old rows with bare costs included" \
  '[.accounts[] | select(.id == "claude")][0].byBounty | map(.bounty) | index("alpha/B-9") != null and index("B-old") != null'
hcheck "history splits a bounty's project from its id" \
  '[.accounts[] | select(.id == "claude")][0].byBounty | map(select(.bounty == "alpha/B-9"))[0] | .project == "alpha" and .id == "B-9" and .byModel["claude-opus-4-8"].tokens == 40'
hcheck "history lists each named agent with a day series over the whole range" \
  "[.accounts[] | select(.id == \"claude\")][0].byAgent | map(select(.agent == \"alpha/Mercury\"))[0] | .project == \"alpha\" and .name == \"Mercury\" and (.perDay | length) == 30 and ([.perDay[] | select(.day == \"$yday\")][0].tokens == 50) and ([.perDay[] | select(.day == \"$today\")][0].costUsd > 0) and .live == true"
hcheck "history totals each project" \
  '[.accounts[] | select(.id == "claude")][0].byProject | map(select(.project == "alpha"))[0] | .agents == 1 and .bounties == 2 and .costUsd > 2'
hcheck "history derives tokens per bounty by model" \
  '[.accounts[] | select(.id == "claude")][0].byModel | map(select(.model == "claude-haiku-4-5"))[0] | .tokensPerBounty == 10'
hcheck "history derives cost per bounty by model" \
  '[.accounts[] | select(.id == "claude")][0].byModel | map(select(.model == "claude-haiku-4-5"))[0] | .bounties == 1 and .costPerBountyUsd == 0.25'
hcheck "history carries the limit history per account" \
  '[.accounts[] | select(.id == "claude")][0].limits | length == 2 and .[1].weekly == 0.45'
hcheck "history lists accounts that only have limits" \
  '[.accounts[] | select(.id == "codex")][0] | .hasTelemetry == false and (.limits | length) == 1'

"$ROOT/bin/omarchy-agent-otel" history --range 7d | jq -e '(.days | length) == 7 and ([.accounts[] | select(.id == "claude")][0].perDay | map(.day) | index("'"$old"'")) == null' >/dev/null ||
  fail "a 7-day history stops at a week"
pass "a 7-day history stops at a week"

"$ROOT/bin/omarchy-agent-otel" history --range all | jq -e ".days[0] <= \"$old\"" >/dev/null ||
  fail "an all-time history starts at the oldest rollup"
pass "an all-time history starts at the oldest rollup"
