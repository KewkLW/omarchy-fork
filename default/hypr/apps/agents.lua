-- The agent room. Agents launched with omarchy agent (the keybinding, the menu,
-- a prompt) open on the agent workspace alongside the room pane, where the
-- conversation between them and you runs, so agent work stays in one place and
-- out of yours. The Quake console agent keeps to the scratchpad: its exec rule
-- pins it there, and it joins the room from wherever it drops down.
local AGENT_WORKSPACE = "9"

o.window("org.omarchy.agent", { workspace = AGENT_WORKSPACE })
o.window("org.omarchy.agent-room", { workspace = AGENT_WORKSPACE })
