# Driving the User's Own Windows

Prefer the agent seat ([`agent-seat.md`](agent-seat.md)) for anything graphical. Use `omarchy agent desktop` only when the task needs a window the user already has open outside the seat: a terminal, an editor, an app that cannot run sandboxed. It sends keys straight to that window and takes window screenshots without moving the user's pointer or focus.

Never drive the user's desktop any other way: no raw `hyprctl` (`dispatch`, `keyword`, tags, moving windows between workspaces), `ydotool`, `wtype` or `grim`. `omarchy agent desktop` is the one path, and it asks the user where the policy says to.

## Workflow

```bash
omarchy agent desktop list                         # JSON: address, class, title, workspace, access
omarchy agent desktop screenshot 0x1234            # prints {"path": ...}; read the PNG
omarchy agent desktop type 0x1234 "git status"     # text, typed in the user's keyboard layout
omarchy agent desktop key 0x1234 enter             # one combo: ctrl+l, ctrl+shift+t, esc, tab
omarchy agent desktop close 0x1234
```

- `access` in `list` says what happens: `automatic` (on an agent workspace or an always-allowed class), `allowed` (the user allowed it until it closes), `ask` (the user gets a menu), `never` (refused, don't ask the user to change that).
- A screenshot goes to `$XDG_RUNTIME_DIR/omarchy` by default. A path you give must be under that directory or your current directory, in a directory that already exists.
- There is no pointer: no clicks, scrolling or dragging. If the task needs them, use an app on the agent seat instead, or ask the user.

## When it refuses

- **The user's menu.** On `ask`, the command waits for the user's answer: _Allow once_ (this one command), _Allow until the window closes_, or _Deny_. Ask for one window at a time and say why first. If they deny it, don't retry; ask them what they want instead.
- **The user's focus.** `type` and `key` refuse the window the user is typing in, and stop mid-text if they switch to it. Ask them to switch away when they're ready, then go on; never wait them out in a loop.
- **The window changed.** Every command checks the window again right before acting and stops if it closed, moved workspace or became another app. Run `list` again and take a fresh screenshot before retrying.
- **No policy.** Without `$XDG_RUNTIME_DIR/omarchy/agent-drive.json`, written when Hyprland loads its config, everything is refused. Tell the user; don't write that file yourself.

The policy is a guard rail the user trusts you to stay inside, not a wall: the policy file, the window tag and the workspaces are all things you could change, and doing so is exactly what you must not do.
