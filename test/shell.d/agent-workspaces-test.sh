#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Runs the placement module against a fake Hyprland: two monitors, DP-2 on the
# right and listed first, as Hyprland lists them. Prints the workspace each
# named rule sends its windows to, after the Lua given on stdin.
placements() {
  OMARCHY_PATH="$ROOT" lua - <<LUA
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local rules, handlers, moves = {}, {}, {}
viewing = 2
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
  get_active_workspace = function()
    return { id = viewing }
  end,
  dispatch = function(action)
    table.insert(moves, action)
  end,
  dsp = {
    window = {
      move = function(args)
        return args
      end,
    },
    focus = function(args)
      return { focus = args.workspace }
    end,
  },
}

-- A window opening on the workspace you're on, unless a rule sent it elsewhere.
local function open(pid, terminal, workspace)
  moves = {}
  handlers["window.open_early"]({
    pid = tonumber(pid),
    address = "0xa",
    class = terminal and "foot" or "chromium",
    tags = terminal and { "terminal*" } or {},
    workspace = { id = workspace or 2 },
  })
  local move = moves[1]
  print(move and (move.workspace .. (move.follow == false and " silent" or "")) or "stays")
end

-- The window maps and Hyprland focuses it, taking the view along to the
-- workspace given; prints where the view is sent back to, if anywhere.
local function mapped(pid, now_viewing)
  moves = {}
  viewing = now_viewing
  handlers["window.open"]({ pid = tonumber(pid), address = "0xa" })
  local focus = moves[1]
  print(focus and ("back to " .. focus.focus) or "no return")
  viewing = 2
end

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

# Real processes stand in for windows: one carrying an agent's marker, one
# plain, and one whose parent is an agent. Agents run this suite, so the plain
# ones are started clear of their markers and detached from them.
test_dir=$(mktemp -d)
spawned=()
cleanup() {
  ((${#spawned[@]})) && kill "${spawned[@]}" 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

clean_env=(env -u OMARCHY_AGENT_ROOM_OUTBOX -u AI_AGENT -u CLAUDECODE -u CODEX_THREAD_ID -u CODEX_SESSION_ID)
printf '#!/bin/bash\nsleep 300\n' >"$test_dir/codex"
chmod +x "$test_dir/codex"

setsid -f "${clean_env[@]}" CLAUDECODE=1 sleep 301 &
setsid -f "${clean_env[@]}" sleep 302 &
setsid -f "${clean_env[@]}" "$test_dir/codex" &
for _ in {1..50}; do
  marked=$(pgrep -fx "sleep 301") plain=$(pgrep -fx "sleep 302") agent=$(pgrep -f "^/bin/bash $test_dir/codex")
  [[ -n $marked && -n $plain && -n $agent ]] && break
  sleep 0.1
done
child=$(pgrep -P "$agent" -x sleep)
spawned=($marked $plain $agent $child)
[[ -n $marked && -n $plain && -n $child ]] || fail "test processes start"

export MARKED=$marked PLAIN=$plain CHILD=$child

output=$(placements <<<'open(os.getenv("MARKED"), true) open(os.getenv("MARKED"), false) open(os.getenv("PLAIN"), true) open(os.getenv("CHILD"), false)')
[[ $output == $'9 silent\n10 silent\nstays\n10 silent' ]] || fail "windows an AI opens go to the agent workspaces" "$output"
pass "windows an AI opens go to the agent workspaces, terminals to 9 and the rest to 10, and yours stay"

output=$(placements <<<'open(os.getenv("MARKED"), true, 11)')
[[ $output == "stays" ]] || fail "a window a rule placed keeps its place" "$output"
pass "a window a rule already placed keeps its place"

output=$(placements <<<'agent_workspaces.set({ per_monitor = 10 }) focus("DP-2") open(os.getenv("MARKED"), true) open(os.getenv("MARKED"), false)')
[[ $output == $'19 silent\n20 silent' ]] || fail "spawned windows go to the agent workspaces of the monitor you're on" "$output"
pass "spawned windows go to the agent workspaces of the monitor you're on"

output=$(placements <<<'agent_workspaces.set({ route_spawned = false }) open(os.getenv("MARKED"), true)')
[[ $output == "stays" ]] || fail "routing spawned windows can be turned off" "$output"
pass "routing spawned windows can be turned off"

output=$(placements <<<'open(os.getenv("MARKED"), true) mapped(os.getenv("MARKED"), 9) open(os.getenv("PLAIN"), true) mapped(os.getenv("PLAIN"), 2)')
[[ $output == $'9 silent\nback to 2\nstays\nno return' ]] || fail "the view goes back to where you were after an AI's window opens" "$output"
pass "the view goes back to where you were after an AI's window opens, and yours are left alone"
