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

local M = {}

M.settings = {
  room = 9,
  seat = 10,
  per_monitor = 0,
  monitors = {},
}

-- Rules are named so rewriting one replaces it rather than stacking another,
-- which is how the workspace follows the monitor you're on.
local placements = {}

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
    M.settings[key] = value
  end
  apply()
end

hl.on("monitor.focused", apply)
hl.on("monitor.added", apply)
hl.on("monitor.removed", apply)

return M
