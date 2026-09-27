-- The agent room: a workspace of terminals only, for watching agents work.
-- Agents launched with omarchy agent (the keybinding, the menu, a prompt) open
-- there alongside the room pane, where the conversation between them and you
-- runs. Nothing else belongs on it; the agent seat's GUI apps keep their own
-- workspace so they don't crowd the terminals. The Quake console agent keeps to the scratchpad: its exec rule
-- pins it there, and it joins the room from wherever it drops down.
local AGENT_WORKSPACE = "9"

o.window("org.omarchy.agent", { workspace = AGENT_WORKSPACE })
o.window("org.omarchy.agent-room", { workspace = AGENT_WORKSPACE })
