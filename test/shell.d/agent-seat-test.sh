#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command python3
require_command jq
require_command xkbcli

test_dir=$(mktemp -d)
mkdir -p "$test_dir/bin" "$test_dir/runtime"

cleanup() {
  # The broker runs under a subshell of run_broker, so end it by parent too.
  [[ -n ${broker_pid:-} ]] && pkill -P "$broker_pid" 2>/dev/null && kill "$broker_pid" 2>/dev/null
  [[ -n ${compositor_pid:-} ]] && kill "$compositor_pid" 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

# The broker asks Hyprland where agent windows are; there is no Hyprland here.
printf '#!/bin/bash\necho "[]"\n' >"$test_dir/bin/hyprctl"
chmod +x "$test_dir/bin/hyprctl"

# The user's menu: logs each question and gives the answer the test set.
printf '#!/bin/bash\necho "$1" >>"%s/menu.log"\ncat "%s/menu-answer"\n' "$test_dir" "$test_dir" >"$test_dir/bin/omarchy-menu-select"
chmod +x "$test_dir/bin/omarchy-menu-select"
touch "$test_dir/menu.log"

cat >"$test_dir/wire.py" <<'EOF'
import array, socket, struct

def string(text):
    data = text.encode() + b"\0"
    return struct.pack("<I", len(data)) + data + b"\0" * (-len(data) % 4)

def message(object_id, opcode, body=b""):
    return struct.pack("<II", object_id, (8 + len(body)) << 16 | opcode) + body

def read_string(body, offset=0):
    length = struct.unpack_from("<I", body, offset)[0]
    return body[offset + 4 : offset + 3 + length].decode()

class Connection:
    def __init__(self, sock):
        self.sock, self.buffer, self.fds = sock, b"", []

    def send(self, data):
        self.sock.sendall(data)

    def read(self, timeout=2):
        """Next message as (object id, opcode, body), or None when the peer hangs up."""
        self.sock.settimeout(timeout)
        while len(self.buffer) < 8 or len(self.buffer) < struct.unpack_from("<II", self.buffer)[1] >> 16:
            data, ancillary, _, _ = self.sock.recvmsg(65536, socket.CMSG_SPACE(4 * 28))
            if not data:
                return None
            for _, _, payload in ancillary:
                fds = array.array("i")
                fds.frombytes(payload[: len(payload) - len(payload) % 4])
                self.fds.extend(fds)
            self.buffer += data
        object_id, word = struct.unpack_from("<II", self.buffer)
        size = word >> 16
        body, self.buffer = self.buffer[8:size], self.buffer[size:]
        return object_id, word & 0xFFFF, body
EOF

# A fake Hyprland: advertises a seat, a compositor, xdg_wm_base, the data
# device manager, a virtual pointer manager and GPU buffers, answers wl_display.sync,
# plays a user pointer entering every surface it can, and logs what reaches it.
cat >"$test_dir/compositor.py" <<'EOF'
import array, os, socket, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from wire import Connection, message, string, read_string

path, log = sys.argv[1], open(sys.argv[2], "a", buffering=1)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(4)

GLOBALS = {1: ("wl_seat", 7), 2: ("wl_compositor", 6), 3: ("xdg_wm_base", 6), 4: ("wl_data_device_manager", 3), 5: ("zwlr_virtual_pointer_manager_v1", 2), 6: ("zwp_linux_dmabuf_v1", 5)}

while True:
    conn = Connection(server.accept()[0])
    objects = {1: "wl_display"}
    while (msg := conn.read(timeout=None)) is not None:
        object_id, opcode, body = msg
        kind = objects.get(object_id, "?")
        if kind == "wl_display" and opcode == 1:
            registry = struct.unpack("<I", body)[0]
            objects[registry] = "wl_registry"
            for name, (interface, version) in GLOBALS.items():
                conn.send(message(registry, 0, struct.pack("<I", name) + string(interface) + struct.pack("<I", version)))
        elif kind == "wl_display" and opcode == 0:
            callback = struct.unpack("<I", body)[0]
            log.write(f"sync {callback}\n")
            conn.send(message(callback, 0, struct.pack("<I", 0)) + message(1, 1, struct.pack("<I", callback)))
        elif kind == "wl_registry":
            name = struct.unpack_from("<I", body)[0]
            interface = read_string(body, 4)
            new_id = struct.unpack_from("<I", body, len(body) - 4)[0]
            objects[new_id] = interface
            log.write(f"bind {interface}\n")
            if interface == "wl_seat":
                conn.send(message(new_id, 0, struct.pack("<I", 7)) + message(new_id, 1, string("seat0")))
        elif kind == "wl_seat" and opcode == 0:
            pointer = struct.unpack("<I", body)[0]
            objects[pointer] = "wl_pointer"
            # The user's pointer arrives: this must never reach an agent app.
            conn.send(message(pointer, 2, struct.pack("<Iii", 0, 256, 256)))
        elif kind == "wl_seat" and opcode == 1:
            keyboard = struct.unpack("<I", body)[0]
            objects[keyboard] = "wl_keyboard"
            keymap = subprocess.run(["xkbcli", "compile-keymap", "--layout", "us"], capture_output=True).stdout + b"\0"
            fd = os.memfd_create("keymap")
            os.write(fd, keymap)
            conn.sock.sendmsg([message(keyboard, 0, struct.pack("<II", 1, len(keymap)))], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
            os.close(fd)
        elif kind == "wl_compositor" and opcode == 0:
            surface = struct.unpack("<I", body)[0]
            objects[surface] = "wl_surface"
        elif kind == "xdg_wm_base" and opcode == 2:
            objects[struct.unpack_from("<I", body)[0]] = "xdg_surface"
        elif kind == "xdg_surface" and opcode == 1:
            objects[struct.unpack("<I", body)[0]] = "xdg_toplevel"
        elif kind == "xdg_toplevel" and opcode == 3:
            app_id = read_string(body)
            log.write(f"app_id {app_id}\n")
            if "." in app_id:
                # The user clicks into the agent window and presses a key.
                conn.send(message(keyboard, 1, struct.pack("<II", 900, surface) + struct.pack("<I", 0)))
                conn.send(message(keyboard, 3, struct.pack("<IIII", 901, 0, 30, 1)) + message(keyboard, 3, struct.pack("<IIII", 902, 0, 30, 0)))
        elif kind == "wl_data_device_manager" and opcode == 1:
            log.write("get_data_device\n")
EOF

# The agent app: connects through the broker and reports what it sees.
cat >"$test_dir/app.py" <<'EOF'
import os, socket, struct, sys
sys.path.insert(0, os.path.dirname(__file__))
from wire import Connection, message, string, read_string

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
conn = Connection(sock)
step = sys.argv[2]

def roundtrip(callback):
    conn.send(message(1, 0, struct.pack("<I", callback)))
    events = []
    while (msg := conn.read()) is not None and msg[0] != callback:
        events.append(msg)
    return events

conn.send(message(1, 1, struct.pack("<I", 2)))
globals_ = {}
for object_id, opcode, body in roundtrip(3):
    if object_id == 2 and opcode == 0:
        globals_[read_string(body, 4)] = struct.unpack_from("<I", body)[0]

def bind(interface, version, new_id):
    conn.send(message(2, 0, struct.pack("<I", globals_[interface]) + string(interface) + struct.pack("<II", version, new_id)))

if step == "globals":
    print(" ".join(sorted(globals_)))

elif step == "hidden":
    hidden = next(name for name in range(1, 50) if name not in globals_.values())
    conn.send(message(2, 0, struct.pack("<I", hidden) + string("zwlr_virtual_pointer_manager_v1") + struct.pack("<II", 1, 4)))
    try:
        while conn.read() is not None:
            pass
        print("disconnected")
    except ConnectionResetError:
        print("disconnected")
    except socket.timeout:
        print("connected")

elif step == "seat":
    bind("wl_seat", 7, 4)
    for object_id, opcode, body in roundtrip(5):
        if object_id == 4 and opcode == 0:
            print("capabilities", struct.unpack("<I", body)[0])
        if object_id == 4 and opcode == 1:
            print("name", read_string(body))
    conn.send(message(4, 1, struct.pack("<I", 7)))
    for object_id, opcode, body in roundtrip(8):
        if object_id == 7 and opcode == 0:
            print("keymap with fd" if conn.fds else "keymap without fd")

elif step == "window":
    bind("wl_seat", 7, 4)
    bind("wl_compositor", 6, 5)
    bind("xdg_wm_base", 6, 6)
    bind("wl_data_device_manager", 3, 7)
    conn.send(message(4, 1, struct.pack("<I", 8)))  # keyboard
    conn.send(message(5, 0, struct.pack("<I", 9)))  # surface
    conn.send(message(6, 2, struct.pack("<II", 10, 9)))  # xdg_surface
    conn.send(message(10, 1, struct.pack("<I", 11)))  # toplevel
    conn.send(message(11, 3, string("foot")))  # set_app_id
    conn.send(message(7, 1, struct.pack("<II", 12, 4)))  # data device
    early = roundtrip(13)
    print("ready", flush=True)
    focused, keys = False, []

    def events():
        yield from early
        while (msg := conn.read(timeout=5)) is not None:
            yield msg

    for object_id, opcode, body in events():
        if object_id == 8 and opcode == 1:
            focused = True
        elif object_id == 8 and opcode == 2:
            focused = False
        elif object_id == 8 and opcode == 3:
            serial, _, key, state = struct.unpack("<IIII", body)
            keys.append((serial < 0x40000000, key, state, focused))
            if len(keys) in (2, 4):
                print(" ".join(f"{'user' if user else 'agent'}:{key}:{state}:{'focused' if focus else 'unfocused'}" for user, key, state, focus in keys[-2:]), flush=True)
EOF

run_broker() {
  XDG_RUNTIME_DIR="$test_dir/runtime" WAYLAND_DISPLAY=compositor PATH="$test_dir/bin:$ROOT/bin:$PATH" "$@"
}

python3 "$test_dir/compositor.py" "$test_dir/runtime/compositor" "$test_dir/compositor.log" &
compositor_pid=$!
for _ in {1..50}; do [[ -S $test_dir/runtime/compositor ]] && break; sleep 0.1; done

run_broker omarchy-agent-seat-broker serve 2>"$test_dir/broker.log" &
broker_pid=$!
socket="$test_dir/runtime/omarchy/agent-seat/wayland-0"
for _ in {1..50}; do [[ -S $socket ]] && break; sleep 0.1; done
[[ -S $socket ]] || fail "broker listens for agent apps" "$(cat "$test_dir/broker.log")"

[[ $(stat -c %a "$test_dir/runtime/omarchy/agent-seat/control") == "600" ]] || fail "control socket is private to the user"
pass "control socket is private to the user"

globals=$(python3 "$test_dir/app.py" "$socket" globals)
[[ $globals == "wl_compositor wl_data_device_manager wl_seat xdg_wm_base" ]] || fail "only allowlisted globals are advertised" "$globals"
pass "only allowlisted globals are advertised"

hidden=$(python3 "$test_dir/app.py" "$socket" hidden 2>&1)
[[ $hidden == "disconnected" ]] || fail "binding a hidden global disconnects the app" "$hidden $(cat "$test_dir/broker.log")"
pass "binding a hidden global disconnects the app"

seat=$(python3 "$test_dir/app.py" "$socket" seat)
grep -q "capabilities 3" <<<"$seat" || fail "seat offers the agent's pointer and keyboard" "$seat"
grep -q "name agent" <<<"$seat" || fail "seat is named agent" "$seat"
pass "seat is the agent's"
grep -q "keymap with fd" <<<"$seat" || fail "agent apps get the user's keymap" "$seat"
pass "agent apps get the user's keymap"

gpu_request() {
  run_broker omarchy-agent-seat-broker call '{"command":"gpu","args":{"app":"vkcube"}}'
}

questions() {
  wc -l <"$test_dir/menu.log"
}

echo "Deny" >"$test_dir/menu-answer"
gpu_request 2>"$test_dir/gpu.err" && fail "a declined GPU request fails"
grep -q "did not allow" "$test_dir/gpu.err" || fail "a declined GPU request says why" "$(cat "$test_dir/gpu.err")"
grep -qx "Let the agent's vkcube use the GPU?" "$test_dir/menu.log" || fail "the user is asked before an app gets the GPU" "$(cat "$test_dir/menu.log")"
pass "the user is asked before an app gets the GPU, and can decline"

echo "Allow once" >"$test_dir/menu-answer"
grant=$(gpu_request) || fail "the user can allow the GPU once" "$(cat "$test_dir/broker.log")"
gpu_socket=$(jq -r '.socket' <<<"$grant")
[[ $(jq -r '.scope' <<<"$grant") == "once" && -S $gpu_socket ]] || fail "an allowed launch gets a socket of its own" "$grant"
[[ $(stat -c %a "$gpu_socket") == "600" ]] || fail "the GPU socket is private to the user"
globals=$(python3 "$test_dir/app.py" "$gpu_socket" globals)
[[ $globals == "wl_compositor wl_data_device_manager wl_seat xdg_wm_base zwp_linux_dmabuf_v1" ]] || fail "an allowed app gets GPU buffers" "$globals"
globals=$(python3 "$test_dir/app.py" "$socket" globals)
[[ $globals == "wl_compositor wl_data_device_manager wl_seat xdg_wm_base" ]] || fail "other apps still get no GPU buffers" "$globals"
pass "an allowed app gets GPU buffers on a socket of its own, other apps do not"

gpu_request >/dev/null 2>&1
(( $(questions) == 3 )) || fail "allowing once asks again next launch" "$(cat "$test_dir/menu.log")"
pass "allowing once asks again next launch"

echo "Allow for this session" >"$test_dir/menu-answer"
gpu_request >/dev/null || fail "the user can allow the GPU for the session"
echo "Deny" >"$test_dir/menu-answer"
grant=$(gpu_request) || fail "a session grant covers later launches"
(( $(questions) == 4 )) || fail "a session grant asks only once" "$(cat "$test_dir/menu.log")"
[[ $(jq -r '.scope' <<<"$grant") == "session" ]] || fail "later launches get the session grant" "$grant"
[[ $(run_broker omarchy-agent-seat-status --json | jq -r '.gpu') == "session" ]] || fail "status shows the session grant"
pass "allowing for the session asks only once"

coproc APP { python3 "$test_dir/app.py" "$socket" window; }
read -r -t 5 ready <&"${APP[0]}"
[[ $ready == "ready" ]] || fail "agent app maps a window"

grep -q "app_id agent-1.foot" "$test_dir/compositor.log" || fail "agent windows are named for Hyprland rules" "$(cat "$test_dir/compositor.log")"
pass "agent windows are named for Hyprland rules"

grep -q "get_data_device" "$test_dir/compositor.log" && fail "agent apps never get the user's clipboard"
grep -q "sync 12" "$test_dir/compositor.log" || fail "the data device is stood in upstream" "$(cat "$test_dir/compositor.log")"
pass "agent apps never get the user's clipboard"

windows=$(run_broker omarchy-agent-seat-windows)
[[ $(jq -r '.[0].app_id' <<<"$windows") == "foot" ]] || fail "windows lists the agent window" "$windows"
pass "windows lists the agent window"

read -r -t 5 typed <&"${APP[0]}"
[[ $typed == "user:30:1:focused user:30:0:focused" ]] || fail "the user's keys reach agent apps" "$typed"
pass "the user's keys reach agent apps"

run_broker omarchy-agent-seat-type 1 "x" || fail "agent can type into its window"
read -r -t 5 typed <&"${APP[0]}"
[[ $typed == "agent:45:1:focused agent:45:0:focused" ]] || fail "agent keystrokes reach the app alongside the user's" "$typed"
pass "agent keystrokes reach the app alongside the user's"

run_broker omarchy-agent-seat-type 1 "é" 2>/dev/null && fail "untypeable text is refused"
run_broker omarchy-agent-seat-type 1 --key hyper+x 2>/dev/null && fail "unknown modifiers are refused"
pass "bad keys are refused"

run_broker omarchy-agent-seat-stop >/dev/null
for _ in {1..50}; do kill -0 "$broker_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$broker_pid" 2>/dev/null && fail "stop ends the broker"
compgen -G "$test_dir/runtime/omarchy/agent-seat/gpu-*" >/dev/null && fail "stop closes the GPU sockets"

run_broker omarchy-agent-seat-run --share "$test_dir/missing" foot 2>/dev/null && fail "sharing a missing path is refused"
pass "sharing a missing path is refused"
[[ $(run_broker omarchy-agent-seat-status) == "Agent seat: stopped" ]] || fail "status reports a stopped seat"
pass "stop ends the broker"
