#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command python3
require_command jq

test_dir=$(mktemp -d)
mock="$test_dir/bin"
state="$test_dir/state"
runtime="$test_dir/runtime"
mkdir -p "$mock" "$state" "$runtime/omarchy" "$test_dir/cwd" "$test_dir/elsewhere"
trap 'rm -rf "$test_dir"' EXIT

# A fake Hyprland. Windows come from clients.json and the user's focus from
# active.json; every dispatch is logged and answered ok, and tag dispatches
# change clients.json the way Hyprland would. clients.next.json replaces
# clients.json after the next read, and active.next.json replaces active.json
# after the next batch, so a test can change the desktop mid-action.
cat >"$mock/hyprctl" <<'EOF'
#!/usr/bin/python3
import json, os, re, sys

state = os.environ["MOCK_STATE"]


def path(name):
  return os.path.join(state, name)


def log(line):
  with open(path("hyprctl.log"), "a") as file:
    file.write(line + "\n")


def advance(name):
  if os.path.exists(path(name + ".next.json")):
    os.replace(path(name + ".next.json"), path(name + ".json"))


def tag(expression):
  found = re.search(r'window\.tag\(\{ window = "address:(0x[0-9a-f]+)", tag = "([+-])([^"]+)" \}\)', expression)
  if not found:
    return
  address, operation, name = found.groups()
  with open(path("clients.json")) as file:
    windows = json.load(file)
  for window in windows:
    if window["address"] == address:
      tags = [value for value in window.get("tags", []) if value.rstrip("*") != name]
      window["tags"] = tags + [name + "*"] if operation == "+" else tags
  with open(path("clients.json"), "w") as file:
    json.dump(windows, file)


command = sys.argv[1:]
if command[:1] == ["clients"]:
  print(open(path("clients.json")).read())
  advance("clients")
elif command[:1] == ["activewindow"]:
  print(open(path("active.json")).read() if os.path.exists(path("active.json")) else "{}")
elif command[:1] == ["devices"]:
  print(json.dumps({"keyboards": [{"main": True, "rules": "", "model": "", "layout": "us", "variant": "", "options": "", "active_layout_index": 0}]}))
elif command[:1] == ["dispatch"]:
  log("dispatch " + command[1])
  tag(command[1])
  print("ok")
elif command[:1] == ["--batch"]:
  lines = command[1].split(" ; ")
  for line in lines:
    log(line)
  print("\n".join("ok" for _ in lines))
  advance("active")
else:
  sys.exit(f"mock hyprctl: unexpected {command}")
EOF

# The user's menu: logs each question and gives the answer the test set.
cat >"$mock/omarchy-menu-select" <<'EOF'
#!/bin/bash
echo "$1" >>"$MOCK_STATE/menu.log"
cat "$MOCK_STATE/menu-answer"
EOF

# The seat broker, only for its window capture: writes a stand-in PNG.
cat >"$mock/omarchy-agent-seat-broker" <<'EOF'
#!/bin/bash
echo "$*" >>"$MOCK_STATE/broker.log"
[[ $1 == "capture-identifier" ]] || exit 1
printf 'PNG' >"$3"
echo '{"width": 1, "height": 1}'
EOF
chmod +x "$mock"/*

write_policy() {
  cat >"$runtime/omarchy/agent-drive.json" <<'EOF'
{
  "agent_workspaces": [9, 10],
  "extra_workspaces": [],
  "always_allow_classes": [],
  "never_allow_classes": ["^1[Pp]assword$", "^Bitwarden$"],
  "tag": "agent-drive"
}
EOF
}

# One window on the desktop: address 0xa1, class, workspace and tags as given.
set_window() {
  local class="$1" workspace="$2" tags="${3:-[]}"

  printf '[{"address": "0xa1", "stableId": "s1", "class": "%s", "title": "notes", "workspace": {"id": %s, "name": "%s"}, "tags": %s}]\n' \
    "$class" "$workspace" "$workspace" "$tags" >"$state/clients.json"
}

# A fresh desktop and logs before each case.
reset() {
  rm -f "$state"/*
  touch "$state/hyprctl.log" "$state/menu.log" "$state/broker.log"
  echo '{"address": "0x99"}' >"$state/active.json"
  echo "Deny" >"$state/menu-answer"
  write_policy
}

drive() {
  (
    cd "$test_dir/cwd"
    env -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$runtime" PATH="$mock:/usr/bin:/bin" MOCK_STATE="$state" \
      "$ROOT/bin/omarchy-agent-desktop" "$@"
  )
}

keys_sent() {
  grep -c 'send_shortcut' "$state/hyprctl.log"
}

questions() {
  wc -l <"$state/menu.log"
}

tag_changes() {
  grep -c 'window\.tag' "$state/hyprctl.log"
}

window_tags() {
  jq -c '.[0].tags' "$state/clients.json"
}

# The policy -------------------------------------------------------------------

reset
set_window foot 10
rm "$runtime/omarchy/agent-drive.json"
if output=$(drive type 0xa1 hi 2>&1); then
  fail "a missing drive policy refuses" "$output"
fi
[[ $output == *"no drive policy"* ]] && (( $(keys_sent) == 0 )) || fail "a missing drive policy refuses" "$output"
drive list >/dev/null 2>&1 && fail "a missing drive policy refuses list"
pass "a missing drive policy refuses every command"

reset
set_window foot 10
echo '{"agent_workspaces": [9, 10], ' >"$runtime/omarchy/agent-drive.json"
drive type 0xa1 hi >/dev/null 2>&1 && fail "an unparsable drive policy refuses"
echo '{"agent_workspaces": [9, 10], "extra_workspaces": [], "always_allow_classes": [], "tag": "agent-drive"}' >"$runtime/omarchy/agent-drive.json"
drive type 0xa1 hi >/dev/null 2>&1 && fail "a policy without never_allow_classes refuses"
(( $(keys_sent) == 0 )) || fail "a broken drive policy sends nothing"
pass "an unparsable or incomplete drive policy refuses"

reset
set_window 1Password 10 '["agent-drive*"]'
echo "Allow until the window closes" >"$state/menu-answer"
for command in "type 0xa1 hi" "key 0xa1 ctrl+l" "screenshot 0xa1" "close 0xa1"; do
  # shellcheck disable=SC2086
  drive $command >/dev/null 2>&1 && fail "never_allow_classes refuses $command even with the tag"
done
(( $(keys_sent) == 0 && $(questions) == 0 )) && ! grep -q 'close' "$state/hyprctl.log" && [[ ! -s $state/broker.log ]] ||
  fail "never_allow_classes refuses without asking or acting"
pass "never_allow_classes is refused even with the tag"

# The user's focus -------------------------------------------------------------

reset
set_window foot 10
echo '{"address": "0xa1"}' >"$state/active.json"
drive type 0xa1 hi >/dev/null 2>&1 && fail "type refuses the window with the user's focus"
drive key 0xa1 ctrl+l >/dev/null 2>&1 && fail "key refuses the window with the user's focus"
(( $(keys_sent) == 0 )) || fail "nothing is typed into the window with the user's focus"
drive screenshot 0xa1 >/dev/null || fail "screenshot still works on the focused window"
pass "type and key refuse the window that has the user's keyboard focus"

reset
set_window foot 10
echo 'not json' >"$state/active.json"
drive type 0xa1 hi >/dev/null 2>&1 && fail "type refuses when the focus cannot be read"
pass "type refuses when the user's focus cannot be read"
