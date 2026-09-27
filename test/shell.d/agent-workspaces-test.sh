#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Runs the placement module against a fake Hyprland: two monitors, DP-2 on the
# right and listed first, as Hyprland lists them. Prints the workspace each
# named rule sends its windows to, after the Lua given on stdin.
placements() {
  OMARCHY_PATH="$ROOT" lua - <<LUA
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local rules, handlers = {}, {}
local monitors = {
  { name = "DP-2", x = 2560, y = 0 },
  { name = "DP-3", x = 0, y = 0 },
}
local active = monitors[2]

hl = {
  window_rule = function(rule)
    rules[rule.name] = rule.workspace
  end,
  get_monitors = function()
    return monitors
  end,
  get_active_monitor = function()
    return active
  end,
  on = function(event, handler)
    handlers[event] = handler
  end,
}

local function focus(name)
  for _, monitor in ipairs(monitors) do
    if monitor.name == name then
      active = monitor
    end
  end
  handlers["monitor.focused"]()
end

local function show(label)
  local names = {}
  for name in pairs(rules) do
    table.insert(names, name)
  end
  table.sort(names)
  for _, name in ipairs(names) do
    print(label .. " " .. name .. " " .. rules[name])
  end
end

local agent_workspaces = require("default.hypr.agent-workspaces")
agent_workspaces.place("room", "room", { class = "room" })
agent_workspaces.place("seat", "seat", { class = "seat" }, true)

$(cat)
LUA
}

output=$(placements <<<'show("default")')
[[ $output == $'default room 9\ndefault seat 10 silent' ]] || fail "agents get 9 and 10 by default" "$output"
pass "agents get workspaces 9 and 10 by default, the seat silently"

output=$(placements <<<'agent_workspaces.set({ room = 7, seat = 8 }) show("moved")')
[[ $output == $'moved room 7\nmoved seat 8 silent' ]] || fail "the user can move the agent workspaces" "$output"
pass "the user can move the agent workspaces"

output=$(placements <<<'focus("DP-2") show("shared")')
[[ $output == $'shared room 9\nshared seat 10 silent' ]] || fail "one pair is shared by every monitor by default" "$output"
pass "one pair is shared by every monitor by default"

output=$(placements <<<'agent_workspaces.set({ per_monitor = 10 }) show("left") focus("DP-2") show("right") focus("DP-3") show("back")')
expected=$'left room 9\nleft seat 10 silent\nright room 19\nright seat 20 silent\nback room 9\nback seat 10 silent'
[[ $output == "$expected" ]] || fail "each monitor gets its own pair, counted from the left" "$output"
pass "each monitor gets its own pair, counted from the left, following focus"

output=$(placements <<<'agent_workspaces.set({ per_monitor = 10, monitors = { "DP-2" } }) show("listed") focus("DP-2") show("first")')
expected=$'listed room 19\nlisted seat 20 silent\nfirst room 9\nfirst seat 10 silent'
[[ $output == "$expected" ]] || fail "listed monitors are counted first" "$output"
pass "listed monitors are counted first"
