# Plan: Agent Seat — agents get their own pointer and keyboard, in sandboxed apps, next to yours

Revision 1.

## Problem

Omarchy ships every major coding agent, and agents increasingly need graphical apps: clicking through a web page, filling a form, checking how a UI renders, driving a desktop app that has no CLI. Today there is exactly one way for an agent to do that on Omarchy, and it's the wrong one:

- **Hyprland has one seat.** One pointer, one keyboard focus. An agent that clicks with `ydotool` or types with `wtype` moves the user's cursor and types into whatever the user has focused. The user and the agent can't both work.
- **There is no boundary.** Any process running as the user can reach Hyprland's virtual input, screencopy, the clipboard, window lists and layer-shell overlays (`ecosystem:enforce_permissions` is off), plus `hyprctl` and the keyring. An agent driving a browser that reads a hostile page is one prompt injection away from all of it.
- **Nothing upstream will change this soon.** Real multi-seat in Hyprland is "by design" out of scope (hyprwm/Hyprland#1731, discussion #10336), and the attempts at it stalled. Omarchy discussion #10688 asks for exactly this feature.

## Shape

A seat of the agent's own, made in userspace. Apps an agent needs run sandboxed and connect to a small Wayland proxy, the broker, instead of to Hyprland. The broker passes their windows through untouched, so they are real windows in the user's session, pinned to workspace 10 with an orange border. It owns their input: the agent gets its own pointer and keyboard through a private control socket, the user's own mouse and keyboard still work on the same windows, and each app's focus follows whoever acted last. It shows the apps only an allowlist of Wayland protocols, so nothing in the sandbox can inject input, capture the screen, list windows or draw overlays.

Agents use it through ordinary commands:

```bash
window=$(omarchy agent seat run chromium https://omarchy.org)
omarchy agent seat screenshot "$window"          # a PNG path to read
omarchy agent seat pointer "$window" click 640 360
omarchy agent seat type "$window" "hello" --key enter
omarchy agent seat stop
```

Python and bash only, no Hyprland plugin, no Hyprland changes, and no new packages: `bubblewrap`, Python and libxkbcommon are already on every install.

## Rejected approaches

- **Injecting into the user's seat** (`ydotool`, `wtype`, a virtual pointer; `hypruse` does this): the agent and the user fight over one cursor and one focus, and the agent's keys land wherever the user is. It's the problem, not a fix.
- **A second real `wl_seat` in a Hyprland plugin** (`hyprland-computer-use`): only apps that bind every seat get independent input. Chromium, Electron and Kitty bind the first seat and fall back to borrowing focus. Plugins also break on every Hyprland ABI change, and Omarchy ships stock `extra/hyprland`.
- **Multi-seat in Hyprland itself**: out of scope upstream by the maintainer's choice, and Hyprland's contribution policy rules out an AI-written PR.
- **A nested Hyprland in a window** (built first as the "agent desk"): it works, but it's a box. Agents can only use apps launched inside it, the user can't use those apps from their own session, and it's a second compositor to theme and keep running.
- **A VM or a VNC/RDP session**: a second desktop to maintain, heavy, and far from the apps and files the agent is working on.

## Design

### The broker: one seat per app, two owners

`bin/omarchy-agent-seat-broker` is a Wayland proxy in pure Python. It parses the protocol XMLs under `/usr/share/wayland*` at startup, so it understands whatever Hyprland speaks without generated code. Every agent app connects to the broker's socket as its only display, and the broker opens one upstream connection to Hyprland per app.

- **Drawing passes through.** Surfaces, buffers and xdg-shell go straight to Hyprland, so agent windows are real windows: tiled, focusable and themed like any other.
- **Each app sees one ordinary seat**, renamed `agent`. That's why apps that only listen to the first seat work. The broker delivers the agent's pointer and keyboard events itself and passes the user's through from Hyprland, moving each app's focus to whoever acted last with the leave and enter events a real seat would send. The user can type into one agent window while the agent types into another.
- **Serials.** Agent events carry serials from `0x40000000` up. Requests that need an input serial (`set_cursor`, popup `grab`, `move`, `resize`, `show_window_menu`) are forwarded only with a recent serial from the user's seat. Popups work without a grab.
- **Window names.** Every toplevel's app id is rewritten to `agent-<n>.<app id>` before the app can set its own, so Hyprland rules can single them out and nothing can pose as a user window.
- **Rendering while hidden.** `xdg_toplevel.configure` always carries `activated` and never `suspended`, together with the Hyprland rule `render_unfocused`, so apps keep drawing on the hidden workspace for the agent to see.

### The allowlist

Agent apps see about 20 globals: compositor, subcompositor, shm, output, seat, data device manager, xdg-shell and dialogs, decorations, viewporter, fractional scale, presentation, fifo, commit timing, content type, alpha modifier, single-pixel buffers and color management. Everything else is hidden, including virtual pointer and keyboard, screencopy and image capture, toplevel export and lists, data-control (clipboard snooping), layer-shell, input method, shortcut inhibitors, global shortcuts, input capture, session lock, gamma and DRM leases. Binding a hidden global by guessing its number disconnects the app.

GPU buffers are hidden too, by default. Apps then draw into shared memory the broker can read, which is what makes its screenshots possible, and keeps the GPU out of the sandbox.

### The clipboard is the user's

An app reads the clipboard only while the user's keyboard is in it and the user acted last: the user can paste, but the agent's Ctrl+V gets nothing. An app sets the clipboard, or starts a drag, only from the user's own input serial, so the agent can't overwrite what the user copied. Primary selection and data-control stay hidden.

### Screenshots and coordinates

`omarchy agent seat screenshot` asks the broker, which keeps a duplicate of each app's shm pools and composes the window, its subsurfaces and its popups into a PNG (about 70 ms). It works while workspace 10 is hidden, and it includes menus that open outside the window, which Hyprland's per-window capture misses. The agent then points in pixels of that screenshot. The broker converts them with the screenshot's origin and scale, then hit-tests surfaces, subsurfaces and popups, respecting input regions.

### Keyboard

The broker compiles Hyprland's own keymap (sent to the user's seat) with libxkbcommon over ctypes, and types text by reverse lookup, so the agent types in the user's layout. `--key` takes combos like `ctrl+l` and `ctrl+shift+t`. Text the layout can't type is refused rather than mangled.

### The sandbox

`bin/omarchy-agent-seat-run` starts each app in bubblewrap: `--unshare-all --share-net --new-session --clearenv`, read-only `/usr`, `/etc` and `/sys`, its own `/proc`, a minimal `/dev` with no uinput and no GPU, a tmpfs `/tmp` (so no X11 sockets), and its own `$XDG_RUNTIME_DIR` holding only the broker socket as `wayland-0`. Its home is `~/.local/share/omarchy/agent-seat/home`, with the user's fonts, icons and fontconfig read-only. There is no D-Bus, so no keyring and no portals. Apps installed outside `/usr` get their own directory mounted read-only.

- **Files** reach the sandbox only when the agent shares them: `--share <path>` read-write, `--share-ro <path>` read-only, each at the same path. The seat adds no prompt of its own; sharing is part of the agent's command, so the agent's own permission rules decide it.
- **The GPU** is the exception that asks. `--gpu` pops a menu in the user's session, which agent input can't reach, offering Allow once, Allow for this session, or Deny. It fails closed if the menu can't show. An allowed app connects through a socket of its own that also offers GPU buffers, with the GPU devices bound in. Its screenshots then come from Hyprland's toplevel capture, which may miss outside-the-window menus.
- **Stopping** (`omarchy agent seat stop`, or _Trigger > Stop Agent Seat_ in the menu while the seat runs) ends the broker and every process in every sandbox. Each sandbox keeps a lifecycle record with process start times, so a recycled pid is never killed.

### Where it lives

- `default/hypr/apps/agent-seat.lua`: class `agent-[0-9]+(\..*)?` goes to `10 silent`, with `render_unfocused`, `no_initial_focus`, `no_dim` and a 3px orange border. `config/hypr/hyprland.lua` shows how to move it to another workspace.
- Commands under `omarchy agent seat`: `run`, `windows`, `pointer`, `type`, `screenshot`, `status` and `stop`, with the broker and the sandbox supervisor hidden. `GROUP_DESCRIPTIONS[agent]` mentions the seat.
- `default/agents/skills/omarchy/agent-seat.md` teaches agents to use the seat and never the user's desktop, and when to hand over to the user (logins, captchas, two-factor).
- `manual/17-ai.md` has a section for users.

### Security

The trust boundary is the sandbox plus the allowlist, and the seat is honest about what it covers:

- **Agent input reaches only agent apps.** The control socket is `0600` and checks the peer's uid with `SO_PEERCRED`. Every action names an agent window, and the broker only delivers events to its own apps.
- **Agent apps reach only what the allowlist allows.** No input injection, screen capture, window lists, overlays or clipboard snooping, and a guessed global disconnects them.
- **The sandbox holds the rest back**: no user files unless shared, no keyring, no D-Bus, no GPU unless the user says so, and no other processes.
- **What it doesn't cover:** the agent process itself runs as the user. The seat keeps the apps it drives in a box; it doesn't box the agent. That's the agent harness's job, through its own permission rules.

### Tests

`test/shell.d/agent-seat-test.sh` runs the broker against a fake compositor and fake apps speaking the wire format. It covers the private control socket, the allowlist and the disconnect on a hidden bind, the renamed seat and the user's keymap, window naming, the user's keys and the agent's reaching the same app with focus correct, the clipboard (the user pastes and copies, the agent can't read or set it), the GPU prompt (once, session, deny, failing closed) and its own socket, bad keys refused, file sharing, and stop ending every sandboxed process without touching a recycled pid.

## Rollout

1. **This PR.** The broker, the commands, the sandbox, the window rule, the menu entry, the skill topic, the manual section and the tests. No migration: the seat starts on first use, and its rule ships under `default/`.
2. **Together with the agent room** (`plans/agent-room.md`): agents talk in terminals on workspace 9 and use apps on the seat on workspace 10. The two are independent, and seat apps can't reach the room.
3. **Later:** a visible agent cursor while workspace 10 is shown, and connecting upstream through `wp_security_context_v1` so Hyprland also knows agent apps are sandboxed.

## Open questions

- **Size.** The broker is about 1,450 lines of Python. The screenshot composer and the debug tracing could be split out or trimmed. Is that the right size for Omarchy to own?
- **The workspace.** 10 is a default, overridable in the user's `hyprland.lua`. Should it be a setting instead?
- **PIDs across the sandbox.** An app that writes its own pid into a shared file writes a pid from the sandbox's namespace. Unreal's hot-reload tripped on this. Sharing `/proc` would fix it but loosens the sandbox.
- **Unicode typing.** Characters outside the user's layout are refused. An input-method fallback would type anything, but it means advertising one more protocol.
