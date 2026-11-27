## Try it

Two ways in. The quick look runs the seat from a clone in one terminal, with no reboot and nothing changed system-wide apart from two packages. The full path makes the clone your Omarchy until you unlink it, which takes a reboot each way, and is the only way to see the workspace rule, the orange outline, the binding and the menu rows.

### 1. Quick look

```bash
git clone --depth 1 --branch agent-seat https://github.com/KewkLW/omarchy-fork.git ~/omarchy-agent-seat
export OMARCHY_PATH=~/omarchy-agent-seat PATH=~/omarchy-agent-seat/bin:$PATH
omarchy pkg add bubblewrap wayland-protocols
```

The branch adds those two packages to `install/omarchy-base.packages` and installs them in migration `1795744236.sh`; `omarchy pkg add` asks for sudo and installs only what is missing. Then run the first session (section 3) in this terminal.

What this does not show: your session still runs the installed Omarchy, so Hyprland has none of the seat's rules. The browser opens on the workspace you are on and takes your focus, without the orange outline (so `state` also says `the user is typing here`), and `Super + Ctrl + Alt + X` and the menu rows don't exist yet. The commands themselves, and the agent's own pointer and keyboard, are the same as on the full path.

### 2. Full path

After step 1, in the same terminal, so the clone's own `omarchy dev link` runs:

```bash
omarchy dev link ~/omarchy-agent-seat
```

It asks for sudo, then offers to reboot: accept. After the reboot, run the first session in a new terminal. Now the browser opens on the focused monitor's tenth workspace with an orange outline, and your workspace and focus stay where they were. Before you stop it:

- `Super + Ctrl + Alt + X` takes you to the seat's window.
- `Super + Space` > Trigger shows **Agent Seat** and, while the seat runs, **Stop Agent Seat**. Agent Seat jumps to the seat, or first opens your default browser there when nothing is on it.

After the reboot a notification offers to run pending Omarchy migrations: those are the clone's, which your install hasn't run. Leave them, and don't run `omarchy update` while linked, as it runs them.

To go back:

```bash
omarchy dev unlink
```

Accept the reboot. Unlink points `/etc/omarchy.conf` back at `/usr/share/omarchy`; the session runs the clone until the reboot. It leaves behind the two packages, the clone, and the seat's home, `~/.local/state/omarchy/agent-seat/home`, which holds the seat browser's profile.

### 3. A first session

```bash
printf '<title>Seat test</title><input aria-label="Name" oninput="document.title=value">' >/tmp/seat-test.html
w=$(omarchy agent seat run --cdp --share-ro /tmp/seat-test.html chromium file:///tmp/seat-test.html)
omarchy agent seat ui "$w"
omarchy agent seat click-ui "$w" Name
omarchy agent seat type "$w" "hello from the agent"
omarchy agent seat state "$w"
omarchy agent seat screenshot "$w"
omarchy agent seat stop
```

- `run` opens Chromium in the sandbox, with the page shared read-only, and `$w` holds its window number.
- `ui` lists the page's controls, among them `textbox "Name" @x,y`.
- `click-ui` prints `Clicked textbox "Name" at x,y`, and `type` prints nothing. Your cursor doesn't move.
- `state`: the title now starts with "hello from the agent", and `focus:  agent acted last`.
- `screenshot` prints the path of a PNG of the window.
- `stop` closes the window and prints `Agent seat: stopped`.

On an install with Google Chrome instead of Chromium, put `google-chrome-stable` in place of `chromium` (not tried in CI).

If a step fails, send the output of:

```bash
omarchy agent seat status --json; omarchy dev status; hyprctl version | head -n 1; hyprctl configerrors
tail -n 50 "$XDG_RUNTIME_DIR"/omarchy/agent-seat/{apps,broker}.log
```
