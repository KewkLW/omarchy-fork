#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command bwrap
if ! bwrap_works; then
  skip "bubblewrap cannot create a sandbox here; skipping the agent seat sandbox"
  exit 0
fi
require_command jq
require_command python3

# The seat commands find their sandbox supervisor under $OMARCHY_PATH.
export OMARCHY_PATH="$ROOT"

real_home=$HOME
real_runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
test_dir=$(mktemp -d)
home="$test_dir/home"
runtime="$test_dir/runtime"
seat="$runtime/omarchy/agent-seat"
mkdir -p "$test_dir/bin" "$test_dir/out" "$test_dir/scratch" "$runtime" "$home/vault/ssh" \
  "$home/.gnupg" "$home/.config/app" "$home/.local/share/keyrings"
# A private directory kept elsewhere and linked into place.
ln -s vault/ssh "$home/.ssh"
echo "canary" >"$home/canary"
echo "scratch" >"$test_dir/scratch/file"
echo "secret" >"$test_dir/secret"

cleanup() {
  local record pid

  # Only the sandboxes this test started: their records live in its own runtime.
  for record in "$seat"/sandboxes/sandbox.*; do
    [[ -e $record ]] || continue
    read -r pid _ <"$record" || continue
    [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
  done
  [[ -n ${launcher_pid:-} ]] && kill "$launcher_pid" 2>/dev/null
  [[ -n ${broker_pid:-} ]] && kill "$broker_pid" 2>/dev/null
  [[ -n ${compositor_pid:-} ]] && kill "$compositor_pid" 2>/dev/null
  # A broker a launch started; the shim execs it, so its pid is the broker's.
  [[ -s $test_dir/slow-broker/pid ]] && kill "$(<"$test_dir/slow-broker/pid")" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

# The broker asks Hyprland where agent windows are; there is no Hyprland here.
printf '#!/bin/bash\necho "[]"\n' >"$test_dir/bin/hyprctl"
chmod +x "$test_dir/bin/hyprctl"

# A fake Hyprland for the broker to forward windows to: it advertises a
# compositor and xdg_wm_base and answers wl_display.sync, nothing more.
cat >"$test_dir/compositor.py" <<'EOF'
import socket, struct, sys, threading

def string(text):
    data = text.encode() + b"\0"
    return struct.pack("<I", len(data)) + data + b"\0" * (-len(data) % 4)

def message(object_id, opcode, body=b""):
    return struct.pack("<II", object_id, (8 + len(body)) << 16 | opcode) + body

def serve(sock):
    buffer = b""
    try:
        while data := sock.recv(65536):
            buffer += data
            while len(buffer) >= 8 and len(buffer) >= struct.unpack_from("<II", buffer)[1] >> 16:
                object_id, word = struct.unpack_from("<II", buffer)
                body, buffer = buffer[8 : word >> 16], buffer[word >> 16 :]
                if object_id == 1 and word & 0xFFFF == 1:
                    registry = struct.unpack("<I", body)[0]
                    for name, interface, version in ((1, "wl_compositor", 4), (2, "xdg_wm_base", 2)):
                        sock.sendall(message(registry, 0, struct.pack("<I", name) + string(interface) + struct.pack("<I", version)))
                elif object_id == 1 and word & 0xFFFF == 0:
                    callback = struct.unpack("<I", body)[0]
                    sock.sendall(message(callback, 0, struct.pack("<I", 0)) + message(1, 1, struct.pack("<I", callback)))
    except OSError:
        pass  # the broker dropped this app
    sock.close()

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(16)
while True:
    threading.Thread(target=serve, args=(server.accept()[0],), daemon=True).start()
EOF
python3 "$test_dir/compositor.py" "$runtime/compositor" 2>"$test_dir/compositor.log" &
compositor_pid=$!
for _ in {1..50}; do [[ -S $runtime/compositor ]] && break; sleep 0.1; done
[[ -S $runtime/compositor ]] || fail "the fake compositor starts" "$(cat "$test_dir/compositor.log")"

# env execs the command, so a background launch's $! is the command itself.
on_seat=(env HOME="$home" XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=compositor PATH="$test_dir/bin:$ROOT/bin:$PATH")

# A share that slipped through must not start a broker this test can't end,
# so these launches find a broker that refuses to serve.
mkdir -p "$test_dir/no-broker"
printf '#!/bin/bash\nexit 1\n' >"$test_dir/no-broker/omarchy-agent-seat-broker"
chmod +x "$test_dir/no-broker/omarchy-agent-seat-broker"

refused() {
  local output

  output=$("${on_seat[@]}" PATH="$test_dir/no-broker:$ROOT/bin:$PATH" omarchy-agent-seat-run "$@" /usr/bin/true 2>&1) && return 1
  [[ $output == "Refusing "* ]]
}

for path in / "$home" /tmp "$runtime" "$real_runtime" "$home/.ssh" "$home/.gnupg" "$home/.config/app" "$home/.local/share/keyrings" "$home/.local" /proc/self /dev; do
  refused --share "$path" || fail "sharing $path is refused"
  refused --share-ro "$path" || fail "sharing $path read-only is refused"
done
[[ ! -e $seat ]] || fail "a refused share starts nothing"
pass "shares of the root, home, /tmp, runtime directories, /proc, /dev and private config are refused"

for path in "$home/.ssh" "$home/.ssh/" "$home/vault/ssh" "$home/vault"; do
  refused --share "$path" || fail "a linked private directory is refused: $path"
  refused --share-ro "$path" || fail "a linked private directory is refused read-only: $path"
done
pass "a linked private directory is refused by its link, its target and the directory holding it"

printf '#!/bin/bash\n' >"$home/.config/app/tool"
chmod +x "$home/.config/app/tool"
output=$("${on_seat[@]}" PATH="$test_dir/no-broker:$ROOT/bin:$PATH" omarchy-agent-seat-run "$home/.config/app/tool" 2>&1) && fail "a program inside ~/.config is refused"
[[ $output == "Refusing "* ]] || fail "a program inside ~/.config is refused" "$output"
pass "a program inside ~/.config is refused"

output=$("${on_seat[@]}" omarchy-agent-seat-windows 2>/dev/null) && fail "windows fails while no broker runs" "$output"
[[ -z $output ]] || fail "windows prints nothing while no broker runs" "$output"
pass "windows fails while no broker runs"

"${on_seat[@]}" omarchy-agent-seat-broker serve 2>"$test_dir/broker.log" &
broker_pid=$!
for _ in {1..50}; do [[ -S $seat/wayland-0 ]] && break; sleep 0.1; done
[[ -S $seat/wayland-0 ]] || fail "the broker starts" "$(cat "$test_dir/broker.log")"

output=$("${on_seat[@]}" omarchy-agent-seat-windows) || fail "windows succeeds on a seat with no apps" "$output"
[[ $(jq -c . <<<"$output") == "[]" ]] || fail "windows lists no windows on a seat with no apps" "$output"
pass "windows lists no windows on a seat with no apps"

# Runs a headless command on the seat and waits for its sandbox to end.
run_headless() {
  "${on_seat[@]}" omarchy-agent-seat-run --no-wait "$@" || return 1
  for _ in {1..100}; do
    compgen -G "$seat/sandboxes/sandbox.*" >/dev/null || return 0
    sleep 0.05
  done
  return 1
}

# Lives in the test directory under /tmp, beside the fake home and runtime, so
# binding its directory would hand all of that to the sandbox.
cat >"$test_dir/probe" <<'EOF'
#!/bin/bash
out=$1 scratch=$2 test_dir=$3 real_home=$4 real_runtime=$5 signature=$6
{
  [[ -e $HOME/canary || -e $test_dir/home/canary ]] && echo "home visible"
  [[ -e $real_home ]] && echo "user home visible"
  [[ -e /run/user ]] && echo "/run/user visible"
  [[ -e $real_runtime ]] && echo "real runtime visible"
  [[ -e /tmp/.X11-unix ]] && echo "X11 visible"
  [[ -e $XDG_RUNTIME_DIR/hypr || -e $real_runtime/hypr ]] && echo "hypr visible"
  [[ -e $XDG_RUNTIME_DIR/bus || -e $real_runtime/bus ]] && echo "D-Bus visible"
  [[ -e $XDG_RUNTIME_DIR/keyring || -e $real_runtime/keyring/control ]] && echo "keyring visible"
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && echo "Hyprland signature set"
  if [[ -n $signature ]] && HYPRLAND_INSTANCE_SIGNATURE=$signature XDG_RUNTIME_DIR=$real_runtime hyprctl -j monitors >/dev/null 2>&1; then
    echo "hyprctl reaches Hyprland"
  fi
  echo "runtime: $(ls -A "$XDG_RUNTIME_DIR" | tr '\n' ' ')"
  [[ -e $(dirname "$0")/secret ]] && echo "probe directory visible"
  echo "scratch: $(cat "$scratch/file")"
  touch "$scratch/new" 2>/dev/null && echo "scratch writable"
  echo "done"
} >"$out/result" 2>&1
EOF
chmod +x "$test_dir/probe"

run_headless --share "$test_dir/out" --share-ro "$test_dir/scratch" "$test_dir/probe" \
  "$test_dir/out" "$test_dir/scratch" "$test_dir" "$real_home" "$real_runtime" "${HYPRLAND_INSTANCE_SIGNATURE:-}" ||
  fail "a headless probe runs in the sandbox" "$(cat "$seat/apps.log" 2>/dev/null)"
result=$(cat "$test_dir/out/result" 2>/dev/null)
[[ $result == *"done"* ]] || fail "the probe reports back through a shared directory" "$result $(cat "$seat/apps.log" 2>/dev/null)"
pass "a shared directory is writable from the sandbox"

for leak in "home visible" "user home visible" "/run/user visible" "real runtime visible" "X11 visible" \
  "hypr visible" "D-Bus visible" "keyring visible" "Hyprland signature set" "hyprctl reaches Hyprland"; do
  [[ $result != *"$leak"* ]] || fail "the sandbox hides the user's session: $leak" "$result"
done
grep -qx "runtime: agent-bus wayland-0 " <<<"$result" || fail "the sandbox's runtime directory holds only the broker socket and its private bus" "$result"
pass "the sandbox sees no home, X11, Hyprland, D-Bus or keyring, and only the broker socket and its private bus"

[[ $result != *"probe directory visible"* ]] || fail "a program outside /usr gets only its own file" "$result"
pass "a program outside /usr gets only its own file, not its directory"

grep -qx "scratch: scratch" <<<"$result" || fail "a read-only share is readable" "$result"
[[ $result != *"scratch writable"* && ! -e $test_dir/scratch/new ]] || fail "a read-only share is not writable" "$result"
pass "a read-only share of a scratch directory is readable and not writable"

# An app bundle keeps its libraries and resources beside the executable.
mkdir -p "$test_dir/opt/app/lib" "$test_dir/opt/tool"
printf '#!/bin/bash\nls -A "$(dirname "$0")" >"%s/bundle"\n' "$test_dir/out" >"$test_dir/opt/app/app"
cp "$test_dir/opt/app/app" "$test_dir/opt/tool/tool"
sed -i 's|/bundle"|/plain"|' "$test_dir/opt/tool/tool"
touch "$test_dir/opt/tool/data"
chmod +x "$test_dir/opt/app/app" "$test_dir/opt/tool/tool"
run_headless --share "$test_dir/out" "$test_dir/opt/app/app" || fail "a bundled app runs"
run_headless --share "$test_dir/out" "$test_dir/opt/tool/tool" || fail "a lone program runs"
[[ $(tr '\n' ' ' <"$test_dir/out/bundle") == "app lib " ]] || fail "an app bundle gets its directory" "$(cat "$test_dir/out/bundle")"
[[ $(tr '\n' ' ' <"$test_dir/out/plain") == "tool " ]] || fail "a directory that is no bundle stays hidden" "$(cat "$test_dir/out/plain")"
pass "an app bundle gets its directory, other programs only their file"

# A launch that waits for its window keeps other launches from diffing the
# window list until it has one, without holding up stop.
"${on_seat[@]}" omarchy-agent-seat-run /usr/bin/sleep 30 >/dev/null 2>&1 &
launcher_pid=$!
for _ in {1..50}; do
  compgen -G "$seat/sandboxes/sandbox.*" >/dev/null && break
  sleep 0.05
done
sleep 0.2
flock -n "$seat/launch.lock" true && fail "a waiting launch holds the launch lock"
flock -n "$seat/sandboxes.lock" true || fail "a waiting launch does not hold up stop"
"${on_seat[@]}" omarchy-agent-seat-run --no-wait /usr/bin/true &
second_pid=$!
sleep 0.5
kill -0 "$second_pid" 2>/dev/null || fail "a second launch waits for the first to find its window"
kill "$launcher_pid"
wait "$launcher_pid" 2>/dev/null
launcher_pid=
for _ in {1..50}; do kill -0 "$second_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$second_pid" 2>/dev/null && fail "the second launch goes ahead once the first is done"
wait "$second_pid" || fail "the second launch succeeds"
pass "launches find their windows one at a time, and stop is not held up"

# An app with one window: it connects, reports <name>-ready in a shared
# directory, opens its window once <name>-go appears there, reports
# <name>-mapped and stays until the broker hangs up. Self-contained, since the
# sandbox gets only this file.
cat >"$test_dir/toplevel" <<'EOF'
#!/usr/bin/python3
import os, socket, struct, sys, time

name, shared = sys.argv[1:3]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(os.environ["XDG_RUNTIME_DIR"] + "/wayland-0")
buffer = b""

def send(object_id, opcode, body=b""):
    sock.sendall(struct.pack("<II", object_id, (8 + len(body)) << 16 | opcode) + body)

def string(text):
    data = text.encode() + b"\0"
    return struct.pack("<I", len(data)) + data + b"\0" * (-len(data) % 4)

def read():
    global buffer
    while len(buffer) < 8 or len(buffer) < struct.unpack_from("<II", buffer)[1] >> 16:
        data = sock.recv(65536)
        if not data:
            sys.exit(0)
        buffer += data
    object_id, word = struct.unpack_from("<II", buffer)
    body, buffer = buffer[8 : word >> 16], buffer[word >> 16 :]
    return object_id, word & 0xFFFF, body

def roundtrip(callback):
    send(1, 0, struct.pack("<I", callback))
    events = []
    while (event := read())[0] != callback:
        events.append(event)
    return events

def report(state):
    open(f"{shared}/{name}-{state}", "w").close()

send(1, 1, struct.pack("<I", 2))
names = {}
for object_id, opcode, body in roundtrip(3):
    if object_id == 2 and opcode == 0:
        length = struct.unpack_from("<I", body, 4)[0]
        names[body[8 : 7 + length].decode()] = struct.unpack_from("<I", body)[0]
for interface, new_id in (("wl_compositor", 4), ("xdg_wm_base", 5)):
    send(2, 0, struct.pack("<I", names[interface]) + string(interface) + struct.pack("<II", 1, new_id))
roundtrip(6)
report("ready")

while not os.path.exists(f"{shared}/{name}-go"):
    time.sleep(0.02)
send(4, 0, struct.pack("<I", 7))      # wl_compositor.create_surface
send(5, 2, struct.pack("<II", 8, 7))  # xdg_wm_base.get_xdg_surface
send(8, 1, struct.pack("<I", 9))      # xdg_surface.get_toplevel
send(9, 3, string(name))              # xdg_toplevel.set_app_id
send(7, 6)                            # wl_surface.commit
roundtrip(10)
report("mapped")

while read():
    pass
EOF
chmod +x "$test_dir/toplevel"

# Waits for an app on the seat to report a state through the shared directory.
reported() {
  for _ in {1..100}; do
    [[ -e $test_dir/out/$1 ]] && return 0
    sleep 0.05
  done
  return 1
}

# Another seat app's window (a dialog, say) that opens while a launch waits for
# its own is not the launch's window.
"${on_seat[@]}" omarchy-agent-seat-run --no-wait --share "$test_dir/out" "$test_dir/toplevel" first "$test_dir/out" ||
  fail "a first windowed app starts" "$(cat "$seat/apps.log" 2>/dev/null)"
reported first-ready || fail "the first windowed app connects" "$(cat "$seat/apps.log" 2>/dev/null)"
# Its sandbox starts only after the launch has listed the windows before it.
"${on_seat[@]}" omarchy-agent-seat-run --share "$test_dir/out" "$test_dir/toplevel" second "$test_dir/out" >"$test_dir/second-window" 2>&1 &
second_pid=$!
reported second-ready || fail "the second windowed app connects" "$(cat "$seat/apps.log" 2>/dev/null)"
touch "$test_dir/out/first-go"
reported first-mapped || fail "the first app opens its window" "$(cat "$seat/apps.log" 2>/dev/null)"
# Give the waiting launch time to see the first app's window on its own.
sleep 0.5
touch "$test_dir/out/second-go"
wait "$second_pid" || fail "the launch of the second app finds a window" "$(cat "$test_dir/second-window")"
second_window=$(<"$test_dir/second-window")
app=$("${on_seat[@]}" omarchy-agent-seat-windows | jq -r --arg window "$second_window" '.[] | select((.window | tostring) == $window) | .app_id')
[[ $app == "second" ]] || fail "a launch returns its own app's window, not another app's" "window $second_window is ${app:-unknown}: $("${on_seat[@]}" omarchy-agent-seat-windows)"
pass "a launch returns its own app's window, not one another app opens meanwhile"

# Reports whether the sandbox's wayland-0 has a broker behind it.
cat >"$test_dir/connect" <<'EOF_CONNECT'
#!/bin/bash
if python3 -c 'import os, socket; socket.socket(socket.AF_UNIX).connect(os.environ["XDG_RUNTIME_DIR"] + "/wayland-0")' 2>/dev/null; then
  echo "connected" >"$1"
else
  echo "refused" >"$1"
fi
EOF_CONNECT
chmod +x "$test_dir/connect"

# A broker that dies leaves its sockets behind.
kill -KILL "$broker_pid"
wait "$broker_pid" 2>/dev/null
broker_pid=
[[ -S $seat/control && -S $seat/wayland-0 ]] || fail "a killed broker leaves its sockets behind"

output=$("${on_seat[@]}" PATH="$test_dir/no-broker:$ROOT/bin:$PATH" omarchy-agent-seat-run --no-wait --share "$test_dir/out" "$test_dir/connect" "$test_dir/out/dead" 2>&1) &&
  fail "a launch over a dead broker's sockets fails while no broker answers" "$output"
[[ $output == "The agent seat broker did not start within 10 seconds"* ]] || fail "a launch with no broker says so" "$output"
sleep 0.5
[[ ! -e $test_dir/out/dead ]] || fail "no app starts over a dead broker's sockets" "$(cat "$test_dir/out/dead")"
pass "a launch over a dead broker's sockets fails clearly while no broker answers"

# The launch starts a broker over the dead one's sockets and hands the app the
# new wayland-0, not the dead one, even when that broker is slow to start.
mkdir -p "$test_dir/slow-broker"
printf '#!/bin/bash\nif [[ $1 == "serve" ]]; then\n  echo $$ >"%s/slow-broker/pid"\n  sleep 1\nfi\nexec "%s/bin/omarchy-agent-seat-broker" "$@"\n' "$test_dir" "$ROOT" >"$test_dir/slow-broker/omarchy-agent-seat-broker"
chmod +x "$test_dir/slow-broker/omarchy-agent-seat-broker"
"${on_seat[@]}" PATH="$test_dir/slow-broker:$test_dir/bin:$ROOT/bin:$PATH" omarchy-agent-seat-run --no-wait --share "$test_dir/out" "$test_dir/connect" "$test_dir/out/restarted" ||
  fail "a launch over a dead broker's sockets starts a new broker" "$(cat "$seat/broker.log" 2>/dev/null)"
for _ in {1..50}; do [[ -s $test_dir/out/restarted ]] && break; sleep 0.1; done
[[ $(cat "$test_dir/out/restarted" 2>/dev/null) == "connected" ]] ||
  fail "an app launched over a dead broker's sockets reaches the new broker" "$(cat "$test_dir/out/restarted" 2>/dev/null) $(cat "$seat/apps.log" 2>/dev/null)"
"${on_seat[@]}" omarchy-agent-seat-stop >/dev/null || fail "stop ends the restarted broker"
rm -f "$test_dir/slow-broker/pid"
pass "a launch over a dead broker's sockets starts a new broker and reaches it"
