-- Where agent windows go. Agents get two workspaces: the room, a workspace of
-- terminals for watching agents work and talking to them, and the seat, where
-- the apps agents drive with their own pointer and keyboard live. Both default
-- to 9 and 10, one pair for the whole desktop.
--
-- Change them in ~/.config/hypr/hyprland.lua:
--
--   require("default.hypr.agent-workspaces").set({ room = 7, seat = 8 })
--
-- If you give each monitor its own bank of workspaces (1-10 on one, 11-20 on
-- the next), give agents a pair on every monitor too, so an agent window opens
-- on the monitor you're working on:
--
--   require("default.hypr.agent-workspaces").set({ per_monitor = 10 })
--
-- Monitors are counted from the left, so the leftmost uses 9 and 10, the next
-- 19 and 20, and so on. List output names to count them in another order:
--
--   require("default.hypr.agent-workspaces").set({ per_monitor = 10, monitors = { "DP-3", "DP-2" } })
--
-- Windows an AI opens go there too, whichever agent opened them and however:
-- terminals to the room, everything else to the seat's workspace. Agents you
-- start yourself stay where you started them. To leave spawned windows where
-- they open:
--
--   require("default.hypr.agent-workspaces").set({ route_spawned = false })
--
-- Agents may drive desktop windows freely on their own workspaces and ask
-- before driving one anywhere else. Extend or narrow that policy here:
--
--   require("default.hypr.agent-workspaces").set({
--     drive = {
--       extra_workspaces = { 7 },
--       always_allow_classes = { "^org\\.example\\.Editor$" },
--       never_allow_classes = { "^1[Pp]assword$", "^Bitwarden$" },
--     },
--   })

local M = {}

M.settings = {
  room = 9,
  seat = 10,
  per_monitor = 0,
  monitors = {},
  route_spawned = true,
  drive = {
    extra_workspaces = {},
    always_allow_classes = {},
    never_allow_classes = { "^1[Pp]assword$", "^Bitwarden$" },
  },
}

-- An agent's children inherit its environment, and Omarchy's launchers pass the
-- environment on even where they detach from the process tree, so these mark a
-- window an AI opened: Omarchy's relay sets the first for every agent it runs,
-- and Claude Code and Codex set the rest for their commands. The user's own
-- terminal is the agent's parent, not its child, so it never carries them.
local SPAWN_MARKERS = { "OMARCHY_AGENT_ROOM_OUTBOX", "AI_AGENT", "CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SESSION_ID" }

-- Where the environment was cleared, an agent above the window still gives it
-- away. The names are the agents omarchy-default-agent knows.
local AGENTS = {
  agy = true, claude = true, codex = true, copilot = true, crush = true, ["cursor-agent"] = true, grok = true,
  hermes = true, muse = true, omp = true, opencode = true, openclaw = true, ori = true, pi = true,
}

-- Rules are named so rewriting one replaces it rather than stacking another,
-- which is how the workspace follows the monitor you're on.
local placements = {}

local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("a")
  file:close()
  return data
end

local JSON_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function json_string(value)
  return '"' .. tostring(value):gsub('[%c"\\]', function(char)
    return JSON_ESCAPES[char] or string.format("\\u%04x", char:byte())
  end) .. '"'
end

-- Hyprland reports workspace ids as integers, so the policy holds integers;
-- an entry that is no workspace number could never match and is left out.
local function json_workspace(value)
  local number = math.tointeger(tonumber(value))
  return number and tostring(number)
end

local function json_array(values, encode)
  local items = {}
  for _, value in ipairs(values or {}) do
    local item = encode(value)
    if item then
      table.insert(items, item)
    end
  end
  return "[" .. table.concat(items, ", ") .. "]"
end

local function agent_workspaces()
  local values = {}
  local count = M.settings.per_monitor == 0 and 1 or math.max(#(hl.get_monitors() or {}), 1)
  for index = 0, count - 1 do
    for _, kind in ipairs({ "room", "seat" }) do
      table.insert(values, M.settings[kind] + index * M.settings.per_monitor)
    end
  end
  return values
end

local function drive_policy()
  local drive = M.settings.drive or {}
  return table.concat({
    "{",
    '  "agent_workspaces": ' .. json_array(agent_workspaces(), json_workspace) .. ",",
    '  "extra_workspaces": ' .. json_array(drive.extra_workspaces, json_workspace) .. ",",
    '  "always_allow_classes": ' .. json_array(drive.always_allow_classes, json_string) .. ",",
    '  "never_allow_classes": ' .. json_array(drive.never_allow_classes, json_string) .. ",",
    '  "tag": "agent-drive"',
    "}",
    "",
  }, "\n")
end

-- What the policy file holds, so focusing another monitor rewrites it only
-- when the policy it gives actually changes.
local written_policy

local function write_drive_policy()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if not runtime or runtime == "" then
    return
  end
  local directory = runtime .. "/omarchy"
  local path = directory .. "/agent-drive.json"
  local policy = drive_policy()
  written_policy = written_policy or read(path)
  if policy == written_policy then
    return
  end

  local temporary = path .. ".tmp"
  local file = io.open(temporary, "wb")
  if not file then
    -- Plain Lua can't make a directory, so this one shell runs only when the
    -- directory is missing, normally once per session.
    os.execute("mkdir -p -- '" .. directory:gsub("'", "'\\''") .. "'")
    file = io.open(temporary, "wb")
    if not file then
      return
    end
  end
  file:write(policy)
  file:close()
  if os.rename(temporary, path) then
    written_policy = policy
  end
end

local function monitor_index(active)
  if M.settings.per_monitor == 0 or not active then
    return 0
  end

  for index, name in ipairs(M.settings.monitors) do
    if name == active.name then
      return index - 1
    end
  end

  -- Unlisted monitors follow the listed ones, counted from the left.
  local listed = {}
  for _, name in ipairs(M.settings.monitors) do
    listed[name] = true
  end
  local rest = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if not listed[monitor.name] then
      table.insert(rest, monitor)
    end
  end
  table.sort(rest, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    return a.y < b.y
  end)
  for index, monitor in ipairs(rest) do
    if monitor.name == active.name then
      return #M.settings.monitors + index - 1
    end
  end
  return 0
end

function M.workspace(kind, monitor)
  return M.settings[kind] + monitor_index(monitor or hl.get_active_monitor()) * M.settings.per_monitor
end

local function apply()
  local monitor = hl.get_active_monitor()
  for name, placement in pairs(placements) do
    local workspace = tostring(M.workspace(placement.kind, monitor))
    hl.window_rule({
      name = name,
      match = placement.match,
      workspace = placement.silent and workspace .. " silent" or workspace,
    })
  end
  write_drive_policy()
end

local function spawned_by_agent(pid)
  local environment = read("/proc/" .. pid .. "/environ")
  if environment then
    environment = "\0" .. environment
    for _, name in ipairs(SPAWN_MARKERS) do
      if environment:find("\0" .. name .. "=", 1, true) then
        return true
      end
    end
  end

  -- The window's own process is left out: an agent that opens a window of its
  -- own was started by someone else, and that someone decides where it goes.
  local stat = read("/proc/" .. pid .. "/stat")
  local parent = stat and tonumber(stat:match("%) %S+ (%d+)"))
  for _ = 1, 64 do
    if not parent or parent <= 1 then
      return false
    end
    stat = read("/proc/" .. parent .. "/stat")
    if not stat then
      return false
    end
    if AGENTS[stat:match("%((.*)%)")] then
      return true
    end
    parent = tonumber(stat:match("%) %S+ (%d+)"))
  end
  return false
end

local function is_terminal(window)
  for _, tag in ipairs(window.tags or {}) do
    if tag:gsub("%*$", "") == "terminal" then
      return true
    end
  end
  return false
end

-- Sends windows matching `match` to the agent workspace of `kind` ("room" or
-- "seat") on the monitor they open on. A silent placement leaves you where you
-- are; otherwise the window takes you there.
function M.place(name, kind, match, silent)
  placements[name] = { kind = kind, match = match, silent = silent }
  apply()
end

function M.set(settings)
  for key, value in pairs(settings) do
    if key == "drive" then
      for drive_key, drive_value in pairs(value) do
        M.settings.drive[drive_key] = drive_value
      end
    else
      M.settings[key] = value
    end
  end
  apply()
end

local function is_agent_workspace(id)
  for _, workspace in ipairs(agent_workspaces()) do
    if id == workspace then
      return true
    end
  end
  return false
end

-- A window an AI opens is sent to the agent workspaces without taking you
-- along. Windows your own rules send somewhere else (a game to its workspace,
-- the Quake console to the scratchpad) keep their place. Hyprland focuses a new
-- window as it maps whatever is set on it first, so focus goes back to where
-- you were once it has; the view is on the agent workspace for well under a
-- frame.
--
-- A rule that isn't silent switches the view before the window opens, so where
-- you were is the workspace from just before a switch that landed on the
-- window's workspace a moment earlier.
local RULE_SWITCH_SECONDS = 0.05
local view = { current = nil, previous = nil, at = 0 }
local returns = {}

local function now()
  local uptime = read("/proc/uptime")
  return uptime and tonumber(uptime:match("^(%S+)")) or 0
end

hl.on("workspace.active", function(workspace)
  local id = workspace and workspace.id
  if id and id ~= view.current then
    view.previous, view.current, view.at = view.current, id, now()
  end
end)

hl.on("window.open_early", function(window)
  if not M.settings.route_spawned or not window or not window.pid or not window.workspace then
    return
  end
  local active = hl.get_active_workspace()
  if not active then
    return
  end
  local landed = window.workspace.id
  local origin = active.id
  if view.current == landed and view.previous and now() - view.at <= RULE_SWITCH_SECONDS then
    origin = view.previous
  end
  if landed ~= origin and not is_agent_workspace(landed) then
    return
  end
  if not spawned_by_agent(window.pid) then
    return
  end

  returns[window.address] = origin
  local target = M.workspace(is_terminal(window) and "room" or "seat")
  if landed ~= target then
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(target), follow = false, window = "address:" .. window.address }))
  end
end)

hl.on("window.open", function(window)
  local origin = window and returns[window.address]
  if not origin then
    return
  end
  returns[window.address] = nil
  local active = hl.get_active_workspace()
  if active and active.id ~= origin then
    hl.dispatch(hl.dsp.focus({ workspace = tostring(origin) }))
  end
end)

hl.on("monitor.focused", apply)
hl.on("monitor.added", apply)
hl.on("monitor.removed", apply)

return M
