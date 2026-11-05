#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

test_tmp=$(mktemp -d)
brokers=()
cleanup() {
  local pid
  for pid in "${brokers[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$test_tmp"
}
trap cleanup EXIT

# A scratch home and runtime directory, so nothing reaches the live seat. Set
# one at a time: XDG paths derived from HOME in the same export would be taken
# from the old one.
export HOME="$test_tmp/home"
export XDG_RUNTIME_DIR="$test_tmp/runtime"
export PATH="$ROOT/bin:$PATH"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

# lane [NAME=value...] [flag]: the lane command with only the given variables.
lane() {
  local -a vars=() flags=()
  local arg
  for arg in "$@"; do
    if [[ $arg == *=* ]]; then vars+=("$arg"); else flags+=("$arg"); fi
  done
  env -u OMARCHY_AGENT_NAME -u OMARCHY_AGENT_SEAT "${vars[@]}" omarchy-agent-seat-lane "${flags[@]}"
}

# Names become lanes: lower case, one dash for anything else, at most 32.
[[ $(lane) == "default" ]] || fail "an agent with no name uses the default lane"
[[ $(lane OMARCHY_AGENT_NAME=Murloc) == "murloc" ]] || fail "an agent's lane is its name"
[[ $(lane "OMARCHY_AGENT_NAME=Kewky Opus 1") == "kewky-opus-1" ]] || fail "a lane name keeps letters, digits and single dashes"
[[ $(lane "OMARCHY_AGENT_NAME=--Ünïcode__ok--") == "n-code-ok" ]] || fail "a lane name drops leading and trailing dashes"
[[ $(lane OMARCHY_AGENT_NAME=Murloc OMARCHY_AGENT_SEAT=scribe) == "scribe" ]] || fail "OMARCHY_AGENT_SEAT picks the lane over the name"
[[ $(lane OMARCHY_AGENT_NAME=Murloc OMARCHY_AGENT_SEAT=) == "default" ]] || fail "an empty OMARCHY_AGENT_SEAT picks the default lane"
[[ $(lane OMARCHY_AGENT_NAME=Default) == "default" ]] || fail "an agent named default shares the default lane"
long=$(lane OMARCHY_AGENT_NAME=abcdefghijklmnopqrstuvwxyz0123456789)
[[ $long == "abcdefghijklmnopqrstuvwxyz012345" ]] || fail "a lane name is cut to 32 characters" "$long"
pass "agent names become lane names"

[[ $(lane --runtime) == "$XDG_RUNTIME_DIR/omarchy/agent-seat" ]] || fail "the default lane keeps the seat's runtime directory"
[[ $(lane --home) == "$HOME/.local/state/omarchy/agent-seat/home" ]] || fail "the default lane keeps the seat's home"
[[ $(lane --class) == "agent-" ]] || fail "the default lane keeps the seat's window classes"
[[ $(lane OMARCHY_AGENT_NAME=Murloc --runtime) == "$XDG_RUNTIME_DIR/omarchy/agent-seat@murloc" ]] || fail "a lane has a runtime directory of its own"
[[ $(lane OMARCHY_AGENT_NAME=Murloc --home) == "$HOME/.local/state/omarchy/agent-seat@murloc/home" ]] || fail "a lane has a home of its own"
[[ $(lane OMARCHY_AGENT_NAME=Murloc --class) == "agent-murloc-" ]] || fail "a lane's windows carry its name"
pass "each lane has its own runtime directory, home and window classes"

# The broker and the ui reader resolve the lane the same way.
names=("" "Murloc" "Kewky Opus 1" "--Ünïcode__ok--" "Default" "abcdefghijklmnopqrstuvwxyz0123456789" "a--b" "-")
for script in omarchy-agent-seat-broker omarchy-agent-seat-ui; do
  for name in "${names[@]}"; do
    expected=$(lane "OMARCHY_AGENT_NAME=$name")
    actual=$(python3 - "$ROOT/bin/$script" "$name" <<'EOF'
import ast, re, os, sys
tree = ast.parse(open(sys.argv[1]).read())
function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "seat_lane")
scope = {"re": re, "os": os}
exec(compile(ast.Module([function], []), sys.argv[1], "exec"), scope)
print(scope["seat_lane"]({"OMARCHY_AGENT_NAME": sys.argv[2]}) or "default")
EOF
)
    [[ $actual == "$expected" ]] || fail "$script names the lane of \"$name\" as omarchy-agent-seat-lane does" "$actual != $expected"
  done
done
pass "the broker, the ui reader and the lane command agree on lane names"

start_broker() {
  OMARCHY_AGENT_SEAT=$1 WAYLAND_DISPLAY=none omarchy-agent-seat-broker serve 2>>"$test_tmp/broker-$1.log" &
  brokers+=($!)
  local control
  control="$(lane "OMARCHY_AGENT_SEAT=$1" --runtime)/control"
  for _ in {1..50}; do [[ -S $control ]] && break; sleep 0.1; done
  [[ -S $control ]] || fail "the $1 lane's broker starts" "$(cat "$test_tmp/broker-$1.log")"
}

start_broker default
start_broker murloc
start_broker scribe

[[ $(omarchy-agent-seat-lane --list | sort | paste -sd,) == "default,murloc,scribe" ]] || fail "lane --list lists every lane"
status=$(omarchy-agent-seat-status --all --json) || fail "status --all reports a running seat" "$status"
[[ $(jq -r '.lanes | sort | join(",")' <<<"$status") == "default,murloc,scribe" ]] || fail "status --all names every running lane" "$status"
OMARCHY_AGENT_SEAT=murloc omarchy-agent-seat-status >/dev/null || fail "status reports the agent's own lane"
pass "status --all covers every lane"

# Stop with a lane stops that lane alone.
OMARCHY_AGENT_SEAT=murloc omarchy-agent-seat-stop >/dev/null || fail "stop stops the agent's own lane"
OMARCHY_AGENT_SEAT=murloc omarchy-agent-seat-status >/dev/null && fail "a stopped lane reports stopped"
omarchy-agent-seat-status >/dev/null || fail "stopping one lane leaves the default lane running"
OMARCHY_AGENT_SEAT=scribe omarchy-agent-seat-status >/dev/null || fail "stopping one lane leaves other lanes running"
status=$(omarchy-agent-seat-status --all --json)
[[ $(jq -r '.lanes | sort | join(",")' <<<"$status") == "default,scribe" ]] || fail "status --all leaves out a stopped lane" "$status"
pass "stop ends only the calling agent's lane"

output=$(omarchy-agent-seat-stop --all) || fail "stop --all stops every lane" "$output"
[[ $output == "Agent seat: stopped" ]] || fail "stop --all reports the seat stopped" "$output"
output=$(omarchy-agent-seat-status --all) && fail "status --all reports a stopped seat after stop --all" "$output"
[[ $output == "Agent seat: stopped" ]] || fail "status --all reports the seat stopped" "$output"
pass "stop --all stops every lane"

# A lane's broker with nothing to serve exits; the default lane's stays.
idle() {
  OMARCHY_AGENT_SEAT=$1 WAYLAND_DISPLAY=none timeout 20 python3 - "$ROOT/bin/omarchy-agent-seat-broker" <<'EOF'
import importlib.machinery, importlib.util, sys, threading, time
loader = importlib.machinery.SourceFileLoader("broker", sys.argv[1])
broker = importlib.util.module_from_spec(importlib.util.spec_from_loader("broker", loader))
loader.exec_module(broker)
broker.IDLE_EXIT_SECONDS = 1
threading.Thread(target=lambda: (time.sleep(8), print("still running", flush=True), __import__("os")._exit(0)), daemon=True).start()
try:
  broker.Broker().serve()
except SystemExit:
  print("exited", flush=True)
EOF
}
idle murloc >"$test_tmp/idle-lane" 2>/dev/null &
idle_lane=$!
idle default >"$test_tmp/idle-default" 2>/dev/null &
idle_default=$!
wait "$idle_lane" "$idle_default" || true
[[ $(<"$test_tmp/idle-lane") == "exited" ]] || fail "an idle lane's broker exits" "$(cat "$test_tmp/idle-lane")"
[[ $(<"$test_tmp/idle-default") == "still running" ]] || fail "the default lane's broker stays when idle" "$(cat "$test_tmp/idle-default")"
[[ ! -S $(lane OMARCHY_AGENT_SEAT=murloc --runtime)/control ]] || fail "an idle lane's broker removes its sockets"
pass "an idle lane's broker exits, the default lane's stays"
