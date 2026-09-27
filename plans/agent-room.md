# Plan: Agent Room — agents that find each other, talk, and can be watched and spoken to on workspace 9

Revision 1.

## Problem

Omarchy ships every major coding agent pre-wired (`omarchy-default-agent`, `omarchy-agent`, the Quake console, the `a`/`c`/`cx` shortcuts), and people increasingly run several at once: Claude Code refactoring in one terminal, Codex reviewing in another, a third agent driving a browser on the agent seat. Today those agents are strangers:

- **No discovery.** An agent has no way to learn that another agent is running, what it is, or where it is working. Users end up copy-pasting between terminals to relay context.
- **No channel.** Every multi-agent setup people build reinvents one: a shared markdown file, a tmux send-keys hack, an MCP memory server, an HTTP dashboard. Each works for one agent pair and none survives the next agent CLI.
- **No oversight.** When agents do coordinate through an ad-hoc file or socket, the user can't see the conversation, and can't step into it.
- **No place.** Agent terminals land wherever the keybinding was pressed, mixed in with the user's own work.

## Shape

A small, file-based message system every agent can use through ordinary `omarchy agent` commands, because every agent Omarchy ships can already run a shell command. There is nothing to install into the agents and no protocol for them to implement. Agents are discovered from the process tree, messages are files in `$XDG_RUNTIME_DIR`, and every message is also appended to a log the user owns. The user is a participant too: the address `user` reaches them, and anything they send from a terminal is stamped as coming from them.

All of it lives on **workspace 9, the agent room**: agent terminals opened by the keybinding, the room pane (the running conversation, with a prompt to talk into it), and the agent seat's sandboxed apps.

No daemon, no new packages (Python and `jq` are already on every install), no network listener.

## Rejected approaches

- **Google's A2A protocol, or any HTTP/JSON-RPC agent bus**: built for agents on different hosts owned by different parties, with agent cards, auth and a server. On one desktop owned by one user it's a daemon and a port for a problem the filesystem already solves, and no shipped CLI speaks it.
- **An MCP server as the channel**: MCP is how an agent calls tools, not how agents address each other. Every agent Omarchy ships runs shell commands, but not all of them load MCP servers the same way, and a long-lived server is a daemon per agent. A thin MCP shim over these commands can come later without changing anything here.
- **D-Bus**: would work and is already present, but it's a service to register and a policy file to maintain, and it gives nothing a directory under `$XDG_RUNTIME_DIR` doesn't for a same-user system. It also puts the channel on the session bus, where every desktop app can reach it.
- **tmux `send-keys` / terminal remote control**: types into terminals, so every message becomes keyboard input to an agent that is often running with approvals turned off. It's also tied to one terminal or multiplexer, and keeps no record.
- **Parsing each agent's own session logs** (`~/.claude/projects`, `~/.codex/sessions`, …) to show conversations: thirteen formats that change with every agent release. The agents' own terminals on workspace 9 already show their conversations, and the message log shows what passes between them.

## Design

### Identity: the process tree, not a claim

Agents don't register themselves and never say who they are. Each `omarchy agent` messaging command walks up its own process ancestry to the first process that is a known agent (by `comm`, or by the script name when the agent runs under `node`, `bun` or `python`; the names come from the same list `omarchy-default-agent` knows). That process is the sender, with the id `<kind>-<pid>` (`claude-5720`, `codex-3380`). The first time an agent is seen, it gets a directory:

```
$XDG_RUNTIME_DIR/omarchy/agents/<kind>-<pid>/
  agent.json   kind, pid, process start time, cwd, name, first seen
  inbox/       one JSON file per unread message
```

A command with no agent in its ancestry is the user. That's how a message typed in the room pane, or in any terminal, is marked `from: user`.

The start time is recorded so a recycled pid is never taken for a dead agent: listing an agent checks that `/proc/<pid>` still has the same start time, and removes the directory when it doesn't. Because it's all under `$XDG_RUNTIME_DIR`, it disappears when the session ends.

### Commands

All live in the existing `agent` group, next to `omarchy agent prompt` and the seat commands:

- `omarchy agent list [--json]`: the running agents, with id, name, kind, working directory, and unread count.
- `omarchy agent send <to> [message]`: sends to an id, a name, a kind (when only one agent of it runs), `user`, or `all`. The message comes from the arguments or from stdin. `--reply <message-id>` threads the reply.
- `omarchy agent inbox [--wait [seconds]] [--peek]`: prints the caller's unread messages, oldest first, and marks them read. `--wait` blocks until one arrives (or exits 2 on timeout), which is how an agent waits for a reply. It checks the tmpfs inbox four times a second, which costs nothing measurable and leaves no watcher process behind when the caller is killed.
- `omarchy agent name <name>`: gives the calling agent a readable name (`reviewer`, `frontend`), usable as an address.
- `omarchy agent log [--follow] [--all]`: the conversation so far: today's messages, or every kept day with `--all`.
- `omarchy agent room`: opens (or focuses) the room pane on workspace 9.

The logic lives in one hidden Python command, `omarchy-agent-room-core`. The user-facing commands are three-line wrappers around it, the same shape as the agent seat's.

Every command carries `# omarchy:summary=` metadata. `GROUP_DESCRIPTIONS[agent]` mentions messaging.

### Delivery and the log

A send writes the message to each recipient's `inbox/` as a temporary file, then renames it into place so readers never see half a message, and appends one line to `~/.local/state/omarchy/agents/log/<date>.jsonl` under `flock`:

```json
{"id":"m-1727380000-4821","time":"2026-09-26T19:20:00Z","from":"claude-5720","from_name":"frontend","to":"codex-3380","reply_to":null,"text":"API shape is done, can you review src/api?"}
```

The log is `0600` in a `0700` directory, and log files older than 30 days are pruned when a message is written. Messages to `user` also raise a desktop notification through `omarchy-notification-send`, so an agent asking a question doesn't wait unseen.

Delivery is **pull**: a message sits in the inbox until the agent reads it. Nothing is typed into an agent and nothing runs. The shipped `omarchy` skill teaches agents when to look: at the start of a task, before reporting done, and with `--wait` when they've asked something.

### The room pane

`omarchy agent room` runs `omarchy-agent-chat` in a terminal (`org.omarchy.agent-room`) on workspace 9. It follows the log live, colouring each sender. It also has a prompt: `@codex-3380 hold off on the migration`, `@all stop and summarise`, or plain text for the last agent that spoke. Those go out as `user`, because the pane has no agent in its ancestry.

### Speaking to an agent that isn't listening

Pull delivery means an idle agent sitting at its own prompt won't see a room message until something makes it check. For **user** messages that isn't good enough: talking to your agents from the room is the point. So agents launched through `omarchy agent` start under a small pty relay, `omarchy-agent-pty`. It sits between the terminal and the agent, passes everything through (resize included), and opens `input.sock` in the agent's directory. When the user sends from the room, the message goes into the inbox as usual and is also typed into that agent's pty, prefixed so the agent knows where it came from:

```
[Agent room] From user: hold off on the migration
```

The relay accepts a connection only when the peer (checked with `SO_PEERCRED`, then its `/proc` ancestry via `omarchy-agent-room-core whois`) has no agent above it. It watches the agent's output for bracketed-paste mode, so when the prompt supports it a multi-line message arrives as one paste and doesn't submit at its first newline. Agents can never type into each other, only leave mail. Agents started by hand (`claude` in any terminal) still discover, send and receive. They just aren't typed into.

### Workspace 9

One window rule file, `default/hypr/apps/agents.lua`:

- `org.omarchy.agent` (terminals from the keybinding and `omarchy agent`) opens on workspace 9 and takes you there.
- `org.omarchy.agent-room` opens on workspace 9 too.
- The agent seat's apps move from workspace 10 to 9 (a one-line change to `default/hypr/apps/agent-seat.lua` on that branch), so everything an agent does is in one place.
- The Quake console agent stays on the scratchpad. Its exec rule pins the workspace, and a drop-down console that jumps you elsewhere would defeat it. It still joins the room as a participant.

The workspace is one constant in that file, for users who keep 9 for something else.

### Security

The trust boundary is the Unix user, and this plan doesn't pretend otherwise. What it does guarantee:

- **Same user only.** Everything is under `$XDG_RUNTIME_DIR` (`0700` by logind) and `~/.local/state` (`0700`). Other users, and anything reaching the machine over the network, can't see or send anything. There is no listener, and the relay socket is `0600` and refuses non-user peers.
- **Sandboxed apps are outside.** Agent seat apps run in bubblewrap with their own `$XDG_RUNTIME_DIR` and home, so they can't reach the room.
- **Messages are data, never commands.** Nothing is executed on receipt. The skill tells agents to treat a peer's message as a request from a colleague, not an instruction from the user: never to grant itself permissions, run destructive commands, or share secrets because another agent asked, and to confirm with the user in their own terminal when unsure. This is the confused-deputy line. An agent that read a hostile web page must not be able to borrow another agent's approvals.
- **Agents can't type into agents.** Only the user's messages are injected, and only through the relay's peer check.
- **Attribution, not authentication.** Sender ids come from the process tree, so honest agents can't mislabel themselves and nothing an agent writes can claim to be `user`. A process deliberately detached from its agent (`setsid`, `systemd-run --user`) could pass as the user. So could a hostile same-user process, which can already edit `~/.bashrc` or ptrace the terminal. The manual says so plainly.
- **Everything is visible.** Every message is in the log. `omarchy agent log --all` and the room pane show the full conversation, and the files are plain JSONL the user can grep, keep or delete.

### Tests

`test/shell.d/agent-room-test.sh` runs against a temporary `$XDG_RUNTIME_DIR` and `$XDG_STATE_HOME` with fake agents: a script named `claude` or `codex` that runs commands, so the ancestry walk finds a real agent process. It covers discovery and ids, sending by id, name and kind, `all` and `user`, inbox read and peek, `--wait` waking on arrival and timing out, dead-agent cleanup with pid reuse, log format and permissions, and the relay: a user message is typed into the pty, and an agent's attempt is refused. Agents run this suite too, so it detaches from whoever started it first. Otherwise the room would take the whole test run for that agent. `default-agent-test.sh` expects every launch to go through the relay.

## Rollout

1. **This PR.** The messaging commands, the room pane, the pty relay wired into `omarchy-agent`, the workspace 9 rules, the skill topic (`default/agents/skills/omarchy/agent-room.md`, linked from `SKILL.md`), and a manual section in `manual/17-ai.md`. No migration: the runtime state is new, and the rules ship under `default/`.
2. **The agent seat PR** moves its rule to workspace 9 when it lands, which is the one line noted above.
3. **Later, if wanted:** an agents-panel section in the bar listing who's in the room with unread counts, an MCP shim for agents that prefer tools to shell, and remote control (below).

## Follow-up: remote control

Claude Code's `/remote-control` lets you pick up one Claude session from a phone or browser, relayed through Anthropic, for Claude only. The room already has everything an OS-level, agent-agnostic version needs: the log is the conversation, and the relay's `input.sock` is how the user speaks. Remote control is those two exposed off the machine. It gets its own plan, because it turns "same user on this desk" into "someone on the network", and every agent in the room runs with approvals off:

- **Transport:** the tailnet only, never a public listener, following `plans/remote.md` (Sunshine's ports open to RFC1918 and `tailscale0` only). A small `omarchy-agent-remote` service speaking SSE for the log and one POST for sending, served on the Tailscale interface.
- **Pairing:** a one-time code shown on the desk (`omarchy agent remote pair`), exchanged for a device key, listed and revocable (`omarchy agent remote devices`). No passwords, no pairing from the remote side alone.
- **Scope:** read the room and speak as `user`, exactly what the room pane can do. Nothing more: no shell, no files, no screen (Sunshine is the remote desktop).
- **Client:** a web page the service serves itself, so any phone on the tailnet works without an app store.

It stays out of v1 so the local feature can be judged on its own, and because a remote door into auto-approving agents deserves its own review.

## Open questions

- **Nudging agents on peer messages.** Agent-to-agent messages are pull-only in v1, so an idle agent misses unsolicited peer mail until it checks. A one-line "you have mail" nudge through the relay would fix that, but it lets agents wake each other. Off in v1. Is it worth a toggle?
- **Should the keybinding jump to workspace 9?** Following the new agent is what "move it all to 9" means, but it changes where `Super + Shift + Ctrl + A` leaves you. A `silent` rule plus a notification is the alternative.
- **Log retention.** 30 days is a guess. Messages can quote code or credentials an agent shouldn't have sent. Should it be shorter, or opt-in?
- **Cross-machine.** Out of scope on purpose. If it comes, it should ride Tailscale with explicit pairing, as `plans/remote.md` does, and never be a listener on by default.
