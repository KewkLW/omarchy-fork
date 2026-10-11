# Plan: Agent Desktop Drive — agents type into the user's own windows, within a policy, without taking the user's focus

Revision 1.

## Problem

The agent seat (`plans/agent-seat.md`) covers apps an agent launches itself. It doesn't cover the windows the user already has open: a terminal where a build is waiting for input, an editor, an app that can't run in the sandbox. For those, agents today reach for the user's own seat:

- **`wtype`, `ydotool` and the like type into whatever has focus.** The user and the agent fight over one keyboard, and the agent's keys land in the user's chat window as easily as in the terminal it meant.
- **Raw `hyprctl dispatch` works on any window,** password managers included, and nothing asks the user first.
- **There is nothing to tell an agent which windows it may touch.** Each agent guesses, and the user can't set the line in one place.

## Shape

One command, `omarchy agent desktop`, that acts on a window by address without moving the user's focus or pointer, and only within a policy the user sets next to the agent workspaces:

```bash
omarchy agent desktop list                       # windows, and what the agent may do with each
omarchy agent desktop screenshot 0x1234          # a PNG path to read
omarchy agent desktop type 0x1234 "git status"
omarchy agent desktop key 0x1234 enter
omarchy agent desktop close 0x1234
```

Windows on the agent workspaces are allowed; anything else asks the user in their own menu. Python and the tools already on every install, no new packages, no Hyprland plugin.

## Rejected approaches

- **Focus the window, type, focus back** (`wtype`, `ydotool`, a virtual keyboard): takes the user's focus for the length of the text, and any key the user presses meanwhile goes to the agent's window or the agent's keys to the user's. It's the problem the seat exists to avoid.
- **Pointer input**: Hyprland has no way to click a window except by moving the one pointer. The drive offers keys only; clicking stays on the agent seat.
- **Running the user's window on the seat**: a running app can't move to another Wayland connection.
- **Hard enforcement in userspace**: the agent runs as the user. Anything the drive reads (the policy file, Hyprland's window tags and workspaces) the agent can also write with `hyprctl`. Pretending otherwise would be worse than saying so; see Security.

## Design

### Acting without focus

Keys go through Hyprland's `send_shortcut` dispatcher with an explicit `window = "address:..."`, which delivers them to that window without focusing it. Text is resolved through the user's own keymap (the main keyboard's layout names from `hyprctl devices`, compiled with libxkbcommon over ctypes), so it types what the user's keyboard would, AltGr levels included. Every character is resolved before anything is sent, and text the layout can't type is refused whole. Keys go in batches of 200 per `hyprctl --batch`.

Screenshots run the seat broker's `capture-identifier` as a subprocess, which captures the one window by its stable id through Hyprland's window capture protocol. The drive doesn't import the broker; it keeps its own copy of the keymap lookup.

### The policy

`default/hypr/agent-workspaces.lua` writes `$XDG_RUNTIME_DIR/omarchy/agent-drive.json` whenever Hyprland loads its config: the agent workspaces, plus `extra_workspaces`, `always_allow_classes` and `never_allow_classes` from `set({ drive = { ... } })` in the user's `hyprland.lua`. Without a complete, readable file the drive refuses everything, so a missing file never drops the user's `never_allow_classes`.

For every command, in order:

1. `never_allow_classes` (password managers by default) refuses, whatever else applies.
2. `type` and `key` refuse the window that has the user's keyboard focus.
3. A window on an agent or extra workspace, or of an always-allowed class, is allowed. This is judged again on every call and never written down, so a window the user moves back to their own workspace is out of reach on the next command.
4. A window tagged `agent-drive` is allowed: the user said so until it closes.
5. Anything else asks the user in `omarchy-menu-select`: _Allow once_, _Allow until the window closes_, or _Deny_. _Allow once_ lives only in the process that asked, so a concurrent call can't use it and a killed drive can't leave it behind. _Allow until the window closes_ tags the window, which `default/hypr/apps/agent-seat.lua` outlines in orange. The drive never removes a tag.

### Checked again right before acting

The window is looked up again after the user answers the menu, and before every screenshot, close and batch of keys. The drive stops if it closed, became another app at the same address, moved workspace, lost the tag it was allowed by, or took the user's keyboard focus.

### Where it lives

- `bin/omarchy-agent-desktop`, routed as `omarchy agent desktop`.
- The policy in `default/hypr/agent-workspaces.lua`, next to the room and seat workspaces it builds on.
- `default/agents/skills/omarchy/agent-desktop.md` teaches agents to use it, never raw `hyprctl`, and what to do when it refuses.
- `manual/17-ai.md` has a "Driving your own windows" section for users.

### Security

The policy is a guard rail for an agent that follows it, not a sandbox:

- **What it does:** an agent that uses `omarchy agent desktop` touches only windows the user's policy or the user's answer allows, never a password manager, never the window the user is typing in, and never a window that changed under it.
- **What it can't do:** the agent runs as the user. The policy file is writable by that user, the `agent-drive` tag can be set with `hyprctl dispatch`, and any window can be moved to an agent workspace the same way. An agent that ignores the skill can drive any window without the drive at all, through the same `hyprctl` the drive uses. Real enforcement would need Hyprland's permission system to know which client is the agent, and an agent harness that keeps the agent away from `hyprctl` and the Hyprland socket.
- **The skill's rule is the actual line:** agents use `omarchy agent desktop` and never raw `hyprctl`. Users who need more than that rely on their harness's own sandbox or permission rules.

### Tests

`test/shell.d/agent-desktop-test.sh` runs the drive against a fake `hyprctl`, menu and broker. It covers refusing without a complete policy, `never_allow_classes` winning over the tag, refusing the focused window, automatic access without a tag and its loss when the window leaves the agent workspace, _Allow once_ leaving no tag, _Allow until the window closes_ tagging and later calls honouring it, never removing a tag, stopping when the window moves, is replaced or takes focus mid-action, screenshot paths, and resolving keys without the broker.

## Rollout

1. **This PR.** The command, the policy, the outline rule, the skill topic, the manual section and the tests. No migration: the policy file is written when Hyprland next loads its config.
2. **Later:** if Hyprland's permission system can tell clients apart, enforce the policy in the compositor rather than trusting the agent to follow it.

## Open questions

- **Duplicated keymap code.** The drive and the seat broker each carry the same XKB lookup. A shared module under `default/` would remove the copy; is that worth a library directory for two scripts?
- **Close.** `close` asks the window to close politely, so an app with unsaved work still asks the user. Should it also refuse the focused window, like `type` and `key`?
