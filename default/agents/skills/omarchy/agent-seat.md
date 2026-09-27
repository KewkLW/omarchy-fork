# The Agent Seat

Use the agent seat whenever a task needs a graphical app: clicking through a web page, filling a form, checking how a UI renders, reading what is on screen. Never drive the user's desktop with `ydotool`, `wtype`, `hyprctl dispatch` or `grim` on their session; those move the user's cursor, type into whatever the user has focused, and capture their private windows.

Apps started on the agent seat are real windows on workspace 10, outlined in orange. You drive them with your own pointer and keyboard, which reach nothing else, while the user keeps working. The user can also use these windows with their own mouse and keyboard at the same time. The apps are sandboxed: their own home, no access to the user's windows, screen, keyring or files. The user's clipboard reaches an app only when the user pastes into it themselves; your own paste gets nothing, and your copies never reach the user's clipboard.

## Workflow

```bash
window=$(omarchy agent seat run chromium https://omarchy.org)   # prints the agent window number
omarchy agent seat screenshot "$window"                          # prints a PNG path; read it
omarchy agent seat pointer "$window" click 640 360               # pixels of that screenshot
omarchy agent seat type "$window" "hello" --key enter
omarchy agent seat windows                                       # JSON: window, app_id, title, size, popups
```

- Screenshot before acting and again after, and read the image. Coordinates are pixels of the window's latest screenshot, so what you see is where you point.
- Screenshots include menus and popups, even ones that open outside the window, and work while workspace 10 is hidden. Take a fresh one after anything that opens or moves a popup, since the coordinates follow the last screenshot.
- `pointer` actions: `move <x> <y>`, `click <x> <y> [--button left|right|middle] [--double]`, `drag <x1> <y1> <x2> <y2>`, `scroll <x> <y> <dy> [<dx>]` (positive `dy` scrolls down, in wheel notches).
- `type` takes text and `--key` combos in any order: `--key ctrl+l`, `--key enter`, `--key esc`, `--key tab`, `--key ctrl+shift+t`. Text is limited to what the user's keyboard layout can type.
- Each app gets a fresh profile, so websites start logged out. Apps under `~/.local/opt` and similar are fine: `omarchy agent seat run ~/.local/bin/chatgpt`.

## When you need the user

Logins, captchas, two-factor prompts and anything else that needs the user's own hands: ask them to switch to workspace 10 (`Super + 0`) and do it in the agent window, then wait for them to say they're done. Don't act in the same window while they work in it: an app has one focus, so whoever acts last takes it. Other agent windows are fine.

## The GPU

Apps get no GPU by default. For one that needs it (a game engine, a 3D tool, a Vulkan app), launch it with `--gpu`: `omarchy agent seat run --gpu vkcube`. The user is asked in their own menu, which your pointer and keyboard cannot reach, and can allow it once or for the rest of the session, or decline. Launch waits for the answer and fails if they decline; don't retry, ask the user what they want instead.

Screenshots of a GPU app come from Hyprland rather than the app's own buffers, so menus that open outside its window may be missing from them.

## Your files

The sandbox sees none of the user's files unless you share them: `--share <path>` read-write, `--share-ro <path>` read-only, repeatable, each at the same path inside. `omarchy agent seat run --gpu --share ~/Projects/game ~/Projects/game/Editor`. The seat asks nothing about this itself; sharing is part of your command, so your own permission rules decide it, the same as for files you touch directly. Share only what the app needs.

## Limits

- No clipboard of your own, file pickers or audio inside the sandbox, and no GPU without `--gpu` and the user's yes.
- Without `--share`, the sandbox cannot see the user's files. Anything the app downloads lands under `~/.local/share/omarchy/agent-seat/home`.
- `omarchy agent seat stop` closes every app on the seat; `omarchy agent seat status` shows whether it is running.
