-- Apps launched with omarchy agent seat run reach Hyprland through the agent
-- seat broker, which names every window "agent-<n>.<app id>". They open on the
-- agent seat's workspace (set in agent-workspaces.lua) without taking you there,
-- keep rendering while it is hidden (so agents can capture them), never take
-- the user's focus, and are outlined in the agent colour so they never read as
-- one of your own windows.
local agent_workspaces = require("default.hypr.agent-workspaces")

agent_workspaces.place("agent-seat-apps", "seat", { class = "agent-[0-9]+(\\..*)?" }, true)

o.window("agent-[0-9]+(\\..*)?", {
  render_unfocused = true,
  no_initial_focus = true,
  no_dim = true,
  border_size = 3,
  border_color = "rgba(ff8a00ff) rgba(ffc266ff) 45deg",
})
