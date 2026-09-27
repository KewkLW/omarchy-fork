-- The agent room: a workspace of terminals only, for watching agents work.
-- Agents launched with omarchy agent (the keybinding, the menu, a prompt) open
-- there alongside the room pane, where the conversation between them and you
-- runs, and subagent terminals join them. Nothing else belongs on it; the agent
-- seat's GUI apps keep their own workspace so they don't crowd the terminals.
-- The Quake console agent keeps to the scratchpad: its exec rule pins it there,
-- and it joins the room from wherever it drops down. Which workspace the room
-- is, and whether each monitor gets one, is set in agent-workspaces.lua.
local agent_workspaces = require("default.hypr.agent-workspaces")

agent_workspaces.place("agent-room-agents", "room", { class = "org.omarchy.agent" })
agent_workspaces.place("agent-room-pane", "room", { class = "org.omarchy.agent-room" })

-- Subagent terminals open on their own whenever a subagent starts, so they
-- arrive quietly rather than pulling you over to the agent workspace.
agent_workspaces.place("agent-room-subagents", "room", { class = "org.omarchy.agent-watch" }, true)
