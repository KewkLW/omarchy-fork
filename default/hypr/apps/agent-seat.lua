-- Apps launched with omarchy agent seat run reach Hyprland through the agent
-- seat broker, which names every window "agent-<n>.<app id>". They live on
-- workspace 10, keep rendering while it is hidden (so agents can capture
-- them), never take the user's focus, and are outlined in the agent colour so
-- they never read as one of your own windows.
o.window("agent-[0-9]+(\\..*)?", {
  workspace = "10 silent",
  render_unfocused = true,
  no_initial_focus = true,
  no_dim = true,
  border_size = 3,
  border_color = "rgba(ff8a00ff) rgba(ffc266ff) 45deg",
})
