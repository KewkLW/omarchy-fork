#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

TEST_HOME=$(mktemp -d)
EMPTY_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$EMPTY_HOME"' EXIT

# Every run names its own data, cache and state roots, so nothing reads or
# writes the real home.
collect() {
  local home="$1"
  shift
  HOME="$home" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" XDG_STATE_HOME="$home/.local/state" \
    "$ROOT/bin/omarchy-agent-usage-opencode" "$@"
}

seed() {
  python3 - "$TEST_HOME/.local/share/opencode/opencode.db" "$@" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

db = Path(sys.argv[1])
mode = sys.argv[2]
db.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db)
now_ms = int(time.time() * 1000)
old_ms = now_ms - 3 * 24 * 60 * 60 * 1000

def message(id, session, provider, model, role="assistant", created=now_ms, input=0, output=0, reasoning=0, read=0, write=0):
  return (id, session, created, created, json.dumps({
    "role": role,
    "providerID": provider,
    "modelID": model,
    "tokens": {"input": input, "output": output, "reasoning": reasoning, "cache": {"read": read, "write": write}},
    "time": {"created": created},
  }))

if mode == "initial":
  conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
  conn.executemany("INSERT INTO message VALUES (?, ?, ?, ?, ?)", [
    message("msg_1", "ses_1", "openrouter", "~deepseek/deepseek-pro-latest", input=80, output=40, reasoning=5, read=30),
    message("msg_2", "ses_1", "openrouter", "~deepseek/deepseek-pro-latest", input=10, output=5, write=2),
    message("msg_3", "ses_2", "opencode", "deepseek-v4.1-flash-free", created=old_ms, input=7, output=3),
    # The Claude and Codex collectors own these two providers.
    message("msg_4", "ses_3", "anthropic", "claude-opus-5-5", input=999, output=999),
    message("msg_5", "ses_3", "openai", "gpt-5.6-sol", input=999, output=999),
    # A gateway whose id merely starts like a claimed one is not claimed.
    message("msg_6", "ses_4", "openai-local", "qwen", input=1, output=1),
    message("msg_7", "ses_1", "openrouter", "~deepseek/deepseek-pro-latest", role="user", input=999),
    message("msg_8", "ses_1", "openrouter", "~deepseek/deepseek-pro-latest"),
  ])
  conn.execute("INSERT INTO message VALUES ('msg_9', 'ses_1', ?, ?, '[\"not\",\"an\",\"object\"]')", (now_ms, now_ms))
  conn.execute("INSERT INTO message VALUES ('msg_10', 'ses_1', ?, ?, '{\"role\": \"assistant\", broken')", (now_ms, now_ms))
else:
  conn.execute("INSERT INTO message VALUES (?, ?, ?, ?, ?)", message("msg_new", "ses_5", "openrouter", "moonshotai/kimi-k3", input=1000))
conn.commit()
conn.close()
PY
}

seed initial
result=$(collect "$TEST_HOME")

[[ $(jq -r '[.id, .name, .cli, (.limits | length)] | join(" ")' <<<"$result") == "opencode OpenCode opencode 0" ]] ||
  fail "OpenCode collector prints a record the panel can show and launch" "$result"
pass "OpenCode collector prints a record the panel can show and launch"

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "174" ]] ||
  fail "OpenCode collector counts today's tokens, reasoning and cache included" "$result"
pass "OpenCode collector counts today's tokens, reasoning and cache included"

[[ $(jq -c '.modelUsage' <<<"$result") == '{"deepseek-pro-latest":{"inputTokens":90,"outputTokens":50,"cacheReadInputTokens":30,"cacheCreationInputTokens":2},"deepseek-v4.1-flash-free":{"inputTokens":7,"outputTokens":3,"cacheReadInputTokens":0,"cacheCreationInputTokens":0},"qwen":{"inputTokens":1,"outputTokens":1,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}}' ]] ||
  fail "OpenCode collector leaves Anthropic and OpenAI to their collectors and skips user, empty and malformed rows" "$result"
pass "OpenCode collector leaves Anthropic and OpenAI to their collectors and skips user, empty and malformed rows"

[[ $(jq -r '[.todayPrompts, .todaySessions, .totalPrompts, .totalSessions, .activeDays] | join(" ")' <<<"$result") == "3 2 4 3 2" ]] ||
  fail "OpenCode collector counts prompts, sessions and active days" "$result"
pass "OpenCode collector counts prompts, sessions and active days"

[[ $(jq -r '.recentDays | length' <<<"$result") == "7" && $(jq -r '.recentDays[3].messageCount' <<<"$result") == "10" && $(jq -r '.recentDays[6].messageCount' <<<"$result") == "174" ]] ||
  fail "OpenCode collector files each message under its own day" "$result"
pass "OpenCode collector files each message under its own day"

[[ $(jq -r '.tierLabel' <<<"$result") == "OpenRouter · OpenCode Zen · +1" ]] ||
  fail "OpenCode collector names the heaviest providers on the plan line" "$result"
pass "OpenCode collector names the heaviest providers on the plan line"

# A --limits-only run reuses the recent scan; --force walks the database again.
seed more
[[ $(collect "$TEST_HOME" --limits-only | jq -r '.todayTotalTokens') == "174" ]] ||
  fail "OpenCode collector reuses a recent scan for --limits-only"
pass "OpenCode collector reuses a recent scan for --limits-only"

[[ $(collect "$TEST_HOME" --force | jq -r '.todayTotalTokens') == "1174" ]] ||
  fail "OpenCode collector rescans with --force"
pass "OpenCode collector rescans with --force"

# A machine that never ran opencode still gets a valid, empty record, which
# the panel hides.
result=$(collect "$EMPTY_HOME")
[[ $(jq -r '[.id, .totalPrompts, .todayTotalTokens, (.recentDays | length)] | join(" ")' <<<"$result") == "opencode 0 0 7" ]] ||
  fail "OpenCode collector prints an empty record without a database" "$result"
pass "OpenCode collector prints an empty record without a database"
