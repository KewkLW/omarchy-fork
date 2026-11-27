-- Where agent seat windows go. Apps agents drive with their own pointer and
-- keyboard open on the seat's workspace: workspace 10 of the monitor you're
-- working on, the one Super + 0 goes to there. Each monitor has workspaces
-- 1-10 of its own (see monitor-workspaces.lua), so on a second monitor that is
-- workspace 20, and so on.
--
-- Use another of the ten in ~/.config/hypr/hyprland.lua:
--
--   require("default.hypr.agent-workspaces").set({ seat = 8 })

local monitor_workspaces = require("default.hypr.monitor-workspaces")

local M = {}

M.settings = {
  seat = 10,
}

-- Rules are named so rewriting one replaces it rather than stacking another,
-- which is how the workspace follows the monitor you're on.
local placements = {}

-- The seat's workspace on a monitor, the focused one unless given. Only a real
-- monitor is looked up: finding its block writes the block assignments, and the
-- keybindings menu loads this config with a stand-in hl and no monitors at all,
-- which would blank every monitor's connector in that file.
function M.workspace(monitor)
  monitor = monitor or hl.get_active_monitor()
  if monitor and type(monitor.name) == "string" then
    return monitor_workspaces.workspace_id(monitor, M.settings.seat)
  end
  return M.settings.seat
end

local function apply()
  local workspace = tostring(M.workspace())
  for name, placement in pairs(placements) do
    hl.window_rule({
      name = name,
      match = placement.match,
      workspace = placement.silent and workspace .. " silent" or workspace,
    })
  end
end

-- Sends windows matching `match` to the seat's workspace on the monitor they
-- open on. A silent placement leaves you where you are; otherwise the window
-- takes you there.
function M.place(name, match, silent)
  placements[name] = { match = match, silent = silent }
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
