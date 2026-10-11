#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua

# Upstream's per-monitor workspaces keep their block assignments in a state
# file, which these runs must never write in the developer's own home.
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

# Runs the placement module against a fake Hyprland, with upstream's
# per-monitor workspaces loaded as omarchy.lua loads them. Two monitors: a
# laptop panel, eDP-1, on the right, and DP-1 on its left, which Hyprland lists
# first. The panel owns workspaces 1-10 and DP-1 11-20, so left to right is not
# the order of their blocks. Prints the workspace each named rule sends its
# windows to, after the Lua given on stdin, and super0 prints where Super + 0
# goes on the focused monitor.
placements() {
  rm -rf "$home/state"
  HOME="$home" XDG_STATE_HOME="$home/state" OMARCHY_PATH="$ROOT" lua - <<LUA
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local rules, handlers = {}, {}
local monitors = {
  { id = 0, name = "DP-1", description = "Dell U2720Q", x = 0, y = 0 },
  { id = 1, name = "eDP-1", description = "BOE 0x095F", x = 2560, y = 0 },
}
local active = monitors[1]

o = { bind_expressions = {}, shell_quote = function(value) return "'" .. value .. "'" end }
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

local function super0(label)
  print(label .. " super0 " .. o.workspaces.workspace_id(active, 10))
end

require("default.hypr.monitor-workspaces")
local agent_workspaces = require("default.hypr.agent-workspaces")
agent_workspaces.place("seat", { class = "seat" }, true)
agent_workspaces.place("loud", { class = "loud" })

$(cat)
LUA
}

output=$(placements <<<'show("default") super0("default")')
[[ $output == $'default loud 20\ndefault seat 20 silent\ndefault super0 20' ]] || fail "the seat is the workspace Super + 0 goes to on the focused monitor" "$output"
pass "the seat is the workspace Super + 0 goes to on the focused monitor, silently where asked"

output=$(placements <<<'focus("eDP-1") show("panel") super0("panel") focus("DP-1") show("back")')
expected=$'panel loud 10\npanel seat 10 silent\npanel super0 10\nback loud 20\nback seat 20 silent'
[[ $output == "$expected" ]] || fail "the seat follows the focused monitor" "$output"
pass "the seat follows the focused monitor to its own workspaces"

output=$(placements <<<'agent_workspaces.set({ seat = 8 }) show("moved") focus("eDP-1") show("panel")')
expected=$'moved loud 18\nmoved seat 18 silent\npanel loud 8\npanel seat 8 silent'
[[ $output == "$expected" ]] || fail "the user can move the seat to another of the ten" "$output"
pass "the user can move the seat to another of the ten"

# The keybindings menu reads the user's config with a stand-in hl that has no
# monitors. Placing the seat then must not write upstream's block assignments,
# which the bar reads to find its monitor's workspaces.
mkdir -p "$home/.config/hypr" "$home/.local/state/omarchy/monitors"
cp "$ROOT"/config/hypr/*.lua "$home/.config/hypr/"
cat >>"$home/.config/hypr/hyprland.lua" <<'LUA'
require("default.hypr.agent-workspaces").set({ seat = 8 })
print("scanned")
LUA
blocks="$home/.local/state/omarchy/monitors/workspaces"
printf '0\teDP-1\tBOE 0x095F\n1\tDP-1\tDell U2720Q\n' >"$blocks"
before=$(<"$blocks")
awk '/lua -E - <<.LUA./ { scan = 1; next } /^LUA$/ { scan = 0 } scan' "$ROOT/bin/omarchy-menu-keybindings" >"$home/scan.lua"
output=$(ulimit -v 1000000; HOME=$home XDG_CONFIG_HOME=$home/.config XDG_STATE_HOME=$home/.local/state OMARCHY_PATH=$ROOT DEBUG=1 timeout 10 lua -E "$home/scan.lua" 2>&1)
[[ $output == *scanned* ]] || fail "the keybindings menu's scan gets through the seat's placement" "$output"
[[ $(<"$blocks") == "$before" ]] || fail "the keybindings menu's scan leaves the block assignments alone" "$(<"$blocks")"
pass "the keybindings menu's scan gets through the seat's placement and writes no block assignments"
