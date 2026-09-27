#!/bin/bash

source "$(dirname "$0")/base-test.sh"

# The room takes any command with an agent above it for that agent, and agents
# run this suite too. So the suite detaches from whoever started it, the way a
# terminal opened from the desktop has no agent above it, and reports back.
if [[ -z ${OMARCHY_AGENT_ROOM_TEST_RESULTS:-} ]]; then
  results=$(mktemp -d)
  OMARCHY_AGENT_ROOM_TEST_RESULTS=$results setsid -f bash -c 'bash "$0" >"$1/out" 2>&1; echo $? >"$1/status"' "$0" "$results" </dev/null
  until [[ -f $results/status ]]; do sleep 0.2; done
  cat "$results/out"
  status=$(<"$results/status")
  rm -rf "$results"
  exit "$status"
fi

require_command python3
require_command jq
require_command socat

test_dir=$(mktemp -d)
mkdir -p "$test_dir/bin" "$test_dir/run" "$test_dir/state"
chmod 700 "$test_dir/run"

agent_pids=()
cleanup() {
  ((${#agent_pids[@]})) && kill "${agent_pids[@]}" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$test_dir/run"
export XDG_STATE_HOME="$test_dir/state"
export PATH="$test_dir/bin:$ROOT/bin:$PATH"
export OMARCHY_TEST_NOTIFICATIONS="$test_dir/notifications"

room="$test_dir/run/omarchy/agents"

cat >"$test_dir/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_NOTIFICATIONS"
SH

# A fake agent is a script named like one, so its process is called claude or
# codex, running a shell command the way an agent's tool call does.
for kind in claude codex; do
  printf '#!/bin/bash\nbash -c "$1"\n' >"$test_dir/bin/$kind"
done
chmod +x "$test_dir/bin"/*

wait_for() {
  local description=$1
  shift
  for _ in {1..40}; do
    "$@" && return 0
    sleep 0.1
  done
  fail "$description"
}

agent_named() {
  omarchy-agent-list --json | jq -e --arg name "$1" 'any(.[]; .name == $name)' >/dev/null
}

agent_id() {
  omarchy-agent-list --json | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

[[ $(omarchy-agent-room-core whoami) == "user" ]] || fail "a command with no agent above it is the user"
pass "a command with no agent above it is the user"

id=$(claude 'omarchy-agent-room-core whoami')
[[ $id =~ ^claude-[0-9]+$ ]] || fail "an agent is identified by its process tree" "got: $id"
[[ -f $room/$id/agent.json ]] || fail "an agent gets a room directory the first time it is seen"
pass "an agent is identified by its process tree and gets a room directory"

omarchy-agent-list >/dev/null
[[ ! -d $room/$id ]] || fail "a finished agent is cleared from the room"
pass "a finished agent is cleared from the room"

codex 'omarchy-agent-name reviewer >/dev/null && omarchy-agent-inbox --wait 10 >"'"$test_dir"'/reviewer.out"; sleep 30' &
agent_pids+=($!)
wait_for "an agent can name itself" agent_named reviewer
pass "an agent can name itself"

sent=$(claude 'omarchy-agent-send reviewer "Please review src/api"')
wait_for "a message wakes an agent waiting on its inbox" grep -q "Please review src/api" "$test_dir/reviewer.out"
grep -q "from claude-" "$test_dir/reviewer.out" || fail "a message carries its sender" "$(cat "$test_dir/reviewer.out")"
grep -q "\[$sent\]" "$test_dir/reviewer.out" || fail "a message carries the id it was sent under"
pass "agents message each other by name, and the sender is stamped from the process tree"

codex 'omarchy-agent-name frontend >/dev/null && sleep 30' &
agent_pids+=($!)
wait_for "a second agent joins" agent_named frontend
omarchy-agent-send frontend "first" >/dev/null
omarchy-agent-send "$(agent_id frontend)" "second" >/dev/null
[[ $(omarchy-agent-list --json | jq '.[] | select(.name == "frontend") | .unread') == 2 ]] ||
  fail "agents are addressed by name or id"
pass "agents are addressed by name or id"

if omarchy-agent-send codex "ambiguous" 2>"$test_dir/err"; then
  fail "a kind with two agents running is refused as an address"
fi
grep -q "More than one codex" "$test_dir/err" || fail "an ambiguous address explains itself" "$(cat "$test_dir/err")"
pass "a kind with two agents running is refused as an address"

if claude 'omarchy-agent-name user' 2>/dev/null; then
  fail "an agent can't take the name user"
fi
pass "an agent can't take the name user"

claude 'omarchy-agent-send user "Can I delete the old migrations?"' >/dev/null
grep -q "Can I delete the old migrations" "$OMARCHY_TEST_NOTIFICATIONS" || fail "a message to the user raises a notification"
inbox=$(omarchy-agent-inbox)
[[ $inbox == *"Can I delete the old migrations"* ]] || fail "the user reads their own inbox" "$inbox"
[[ -z $(omarchy-agent-inbox) ]] || fail "read messages leave the inbox"
pass "agents reach the user through a notification and the user's inbox"

omarchy-agent-inbox --wait 0.3 >/dev/null
(($? == 2)) || fail "waiting on an empty inbox times out with status 2"
pass "waiting on an empty inbox times out with status 2"

frontend=$(agent_id frontend)
omarchy-agent-send all "Stop and summarise" >/dev/null
ls "$room/$frontend/inbox" | xargs -I{} cat "$room/$frontend/inbox/{}" | grep -q "Stop and summarise" ||
  fail "a message to all reaches every agent"
pass "a message to all reaches every agent"

log=$(ls "$test_dir/state/omarchy/agents/log"/*.jsonl)
[[ $(stat -c %a "$test_dir/state/omarchy/agents/log") == 700 && $(stat -c %a "$log") == 600 ]] ||
  fail "the message log is private to the user"
jq -e 'select(.text == "Please review src/api") | .from | startswith("claude-")' "$log" >/dev/null ||
  fail "the log records who said what"
[[ $(omarchy-agent-log | grep -c .) == $(grep -c . "$log") ]] || fail "omarchy agent log shows every message"
pass "every message is kept in a private log the user can read back"

# A pid recycled by another program must not inherit a dead agent's inbox.
mkdir -p "$room/claude-$$/inbox"
printf '{"id":"claude-%s","kind":"claude","pid":%s,"start":1,"name":null}\n' $$ $$ >"$room/claude-$$/agent.json"
omarchy-agent-list >/dev/null
[[ ! -d $room/claude-$$ ]] || fail "an agent whose pid was reused is cleared from the room"
pass "an agent whose pid was reused is cleared from the room"

# The relay types the user's messages into the agent it runs, and nobody else's.
omarchy-agent-pty claude bash -c 'read -r -t 10 line && printf "%s\n" "$line" >"$0"' "$test_dir/typed" >/dev/null &
agent_pids+=($!)
relayed() {
  omarchy-agent-list --json | jq -e 'any(.[]; .relay)' >/dev/null
}
wait_for "the relay registers its agent" relayed
relay_id=$(omarchy-agent-list --json | jq -r '.[] | select(.relay) | .id')
[[ -S $room/$relay_id/input.sock && $(stat -c %a "$room/$relay_id/input.sock") == 600 ]] ||
  fail "the relay listens on a private socket"

codex "printf 'rm -rf ~\n' | socat - UNIX-CONNECT:$room/$relay_id/input.sock" 2>/dev/null
sleep 0.5
[[ ! -e $test_dir/typed ]] || fail "an agent can't type into another agent" "$(cat "$test_dir/typed")"
pass "an agent can't type into another agent"

omarchy-agent-send "$relay_id" "hold off on the migration" >/dev/null
wait_for "the user's message is typed into the agent" test -s "$test_dir/typed"
[[ $(<"$test_dir/typed") == "[Agent room] From user: hold off on the migration" ]] ||
  fail "the typed message says it came from the user" "$(cat "$test_dir/typed")"
[[ -n $(ls "$room/$relay_id/inbox") ]] || fail "a typed message is also left in the inbox"
pass "the user speaks to an agent through its relay"
