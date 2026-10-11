#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command python3
require_command jq
require_command xkbcli

test_dir=$(mktemp -d)
mkdir -p "$test_dir/bin" "$test_dir/runtime"

cleanup() {
  XDG_RUNTIME_DIR="$test_dir/runtime" PATH="$test_dir/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-agent-seat-stop" >/dev/null 2>&1 || true
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

# A fake Hyprland: advertises a seat, a compositor, shared memory, subsurfaces,
# xdg_wm_base, the data device manager, a virtual pointer manager and GPU
# buffers, answers wl_display.sync, plays a user pointer entering every surface
# it can, and logs what reaches it. Each connection gets its own thread, so apps
# can stay connected side by side.
cat >"$test_dir/compositor.py" <<'EOF'
import array, os, socket, struct, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
from wire import Connection, message, string, read_string

path, log = sys.argv[1], open(sys.argv[2], "a", buffering=1)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(64)

GLOBALS = {1: ("wl_seat", 7), 2: ("wl_compositor", 6), 3: ("xdg_wm_base", 6), 4: ("wl_data_device_manager", 3), 5: ("zwlr_virtual_pointer_manager_v1", 2), 6: ("zwp_linux_dmabuf_v1", 5), 7: ("wl_shm", 1), 8: ("wl_subcompositor", 1)}
SLOW_SYNC = 999  # a sync with this callback is answered late, for tests that need an event in flight
POPUP = (30, 25, 20, 10)  # where every popup opens, relative to its parent

def serve(conn):
    objects = {1: "wl_display"}
    keyboard = surface = None
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
            if callback == SLOW_SYNC:
                time.sleep(0.5)
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
        elif kind in ("wl_surface", "wl_subsurface") and opcode == 0:
            conn.send(message(1, 1, struct.pack("<I", object_id)))  # destroyed: the id is free again
        elif kind == "wl_shm" and opcode == 0:
            objects[struct.unpack_from("<I", body)[0]] = "wl_shm_pool"
            os.close(conn.fds.pop(0))
        elif kind == "wl_subcompositor" and opcode == 1:
            objects[struct.unpack_from("<I", body)[0]] = "wl_subsurface"
        elif kind == "xdg_wm_base" and opcode == 2:
            objects[struct.unpack_from("<I", body)[0]] = "xdg_surface"
        elif kind == "xdg_surface" and opcode == 1:
            objects[struct.unpack("<I", body)[0]] = "xdg_toplevel"
        elif kind == "xdg_surface" and opcode == 2:
            popup = struct.unpack_from("<I", body)[0]
            objects[popup] = "xdg_popup"
            conn.send(message(popup, 0, struct.pack("<iiii", *POPUP)))
        elif kind == "xdg_toplevel" and opcode == 3:
            app_id = read_string(body)
            log.write(f"app_id {app_id}\n")
            if "." in app_id and keyboard:
                # The user clicks into the agent window and presses a key.
                conn.send(message(keyboard, 1, struct.pack("<II", 900, surface) + struct.pack("<I", 0)))
                conn.send(message(keyboard, 3, struct.pack("<IIII", 901, 0, 30, 1)) + message(keyboard, 3, struct.pack("<IIII", 902, 0, 30, 0)))
        elif kind == "wl_data_device_manager" and opcode == 0:
            objects[struct.unpack("<I", body)[0]] = "wl_data_source"
        elif kind == "wl_data_device_manager" and opcode == 1:
            device = struct.unpack_from("<I", body)[0]
            objects[device] = "wl_data_device"
            log.write("get_data_device\n")
            # The user has something copied: offer it to the focused app.
            objects[0xFF000001] = "wl_data_offer"
            conn.send(message(device, 0, struct.pack("<I", 0xFF000001)) + message(0xFF000001, 0, string("text/plain")) + message(device, 5, struct.pack("<I", 0xFF000001)))
        elif kind == "wl_data_offer" and opcode == 1:
            log.write("receive\n")
            fd = conn.fds.pop(0)
            os.write(fd, b"clipboard-text")
            os.close(fd)
        elif kind == "wl_data_device" and opcode == 1:
            log.write(f"set_selection {struct.unpack_from('<I', body, 4)[0]}\n")

def run(sock):
    conn = Connection(sock)
    try:
        serve(conn)
    except OSError:
        pass  # the broker dropped this app
    for fd in conn.fds:
        os.close(fd)
    sock.close()

while True:
    threading.Thread(target=run, args=(server.accept()[0],), daemon=True).start()
EOF

# The agent app: connects through the broker and reports what it sees.
cat >"$test_dir/app.py" <<'EOF'
import array, os, select, socket, struct, sys
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

elif step == "vanish":
    # Hang up while Hyprland's answer to this app is on its way, so the broker
    # finds both of the app's sockets ready at once.
    import signal, time
    broker = int(sys.argv[3])
    conn.send(message(1, 0, struct.pack("<I", 999)))  # answered late
    time.sleep(0.2)
    os.kill(broker, signal.SIGSTOP)
    try:
        time.sleep(0.8)
        sock.close()
    finally:
        os.kill(broker, signal.SIGCONT)

elif step in ("fdflood", "poolflood"):
    # Fill the broker's descriptor table: one message with as many
    # descriptors as the kernel allows, or more pools than an app needs.
    try:
        if step == "fdflood":
            fds = [os.open("/dev/null", os.O_RDONLY) for _ in range(253)]
            conn.sock.sendmsg([message(1, 0, struct.pack("<I", 4))], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            bind("wl_shm", 1, 4)
            memory = os.memfd_create("pool")
            os.ftruncate(memory, 4096)
            for start in range(100, 400, 28):
                data = b"".join(message(4, 0, struct.pack("<Ii", pool, 4096)) for pool in range(start, start + 28))
                conn.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [memory] * 28))])
        conn.send(message(1, 0, struct.pack("<I", 5)))
        while (msg := conn.read()) is not None and msg[0] != 5:
            pass
        print("disconnected" if msg is None else "connected")
    except OSError:
        print("disconnected")

elif step == "syncflood":
    # Ask for replies as fast as possible and never read one.
    import time
    conn.sock.settimeout(0.5)
    sent, callback = 0, 3
    try:
        while sent < 16 << 20:
            syncs = b"".join(message(1, 0, struct.pack("<I", callback + i)) for i in range(1000))
            conn.sock.sendall(syncs)
            sent, callback = sent + len(syncs), callback + 1000
        print("never blocked", flush=True)
    except socket.timeout:
        print("blocked", flush=True)
    time.sleep(0.5)

elif step == "thief":
    # Set the clipboard with serials of the user's input to another app.
    bind("wl_seat", 7, 4)
    bind("wl_data_device_manager", 3, 5)
    conn.send(message(5, 1, struct.pack("<II", 6, 4)))  # data device
    conn.send(message(5, 0, struct.pack("<I", 7)))  # data source
    for serial in (900, 901, 902):
        conn.send(message(6, 1, struct.pack("<II", 7, serial)))
    roundtrip(8)

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
    conn.send(message(7, 0, struct.pack("<I", 20)))  # data source, for copying
    early = roundtrip(13)
    print("ready", flush=True)
    focused, keys, offer, pending = False, [], None, []

    # Pastes the offered clipboard and copies, as the app would on the last
    # key it saw, and reports what came back.
    def paste_and_copy(serial):
        read, write = os.pipe()
        conn.sock.sendmsg([message(offer, 1, string("text/plain"))], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [write]))])
        os.close(write)
        data = os.read(read, 100) if select.select([read], [], [], 2)[0] else b"timeout"
        os.close(read)
        conn.send(message(12, 1, struct.pack("<II", 20, serial)))
        print(f"pasted:{data.decode()}", flush=True)

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
                pending.append(serial)
        elif object_id == 12 and opcode == 5:
            offer = struct.unpack("<I", body)[0]
        while pending and offer:
            paste_and_copy(pending.pop(0))
EOF

# An agent app that draws: a window with a subsurface and a popup in shared
# memory, or one large window whose pool keeps shrinking and growing under the
# broker. It prints the agent pointer's events and takes commands on stdin.
cat >"$test_dir/draw.py" <<'EOF'
import array, os, select, socket, struct, sys, threading
sys.path.insert(0, os.path.dirname(__file__))
from wire import Connection, message, string, read_string

SEAT, COMPOSITOR, SHM, WM, SUBCOMPOSITOR, POINTER, POOL = 4, 5, 6, 7, 8, 9, 10
ROOT, CHILD, POPUP_SURFACE, XDG, TOPLEVEL, SUBSURFACE, REGION, POSITIONER, POPUP_XDG, POPUP = 20, 21, 22, 23, 24, 25, 26, 27, 28, 29
RED, GREEN, BLUE = b"\x00\x00\xff\xff", b"\x00\xff\x00\xff", b"\xff\x00\x00\xff"  # XRGB8888, little endian

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
conn = Connection(sock)
scene = sys.argv[2]
callbacks = iter(range(1000, 1 << 30))
reporting = False  # until the window is up: the user's pointer passing by is not the agent's

def out(text):
    print(text, flush=True)

def fixed(body, offset):
    return f"{struct.unpack_from('<i', body, offset)[0] / 256:g}"

def report(object_id, opcode, body):
    if object_id != POINTER or not reporting:
        return
    if opcode == 0:
        out(f"enter {struct.unpack_from('<I', body, 4)[0]} {fixed(body, 8)} {fixed(body, 12)}")
    elif opcode == 1:
        out(f"leave {struct.unpack_from('<I', body, 4)[0]}")
    elif opcode == 2:
        out(f"motion {fixed(body, 4)} {fixed(body, 8)}")
    elif opcode == 3:
        out("button {2} {3}".format(*struct.unpack("<IIII", body)))
    elif opcode == 4:
        out(f"axis {struct.unpack_from('<I', body, 4)[0]} {fixed(body, 8)}")
    elif opcode == 5:
        out("frame")
    elif opcode == 8:
        out("discrete {} {}".format(*struct.unpack("<Ii", body)))

def roundtrip():
    callback = next(callbacks)
    conn.send(message(1, 0, struct.pack("<I", callback)))
    while (msg := conn.read()) is not None and msg[0] != callback:
        report(*msg)

def send_fd(data, fd):
    conn.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])

conn.send(message(1, 1, struct.pack("<I", 2)))
globals_ = {}
callback = next(callbacks)
conn.send(message(1, 0, struct.pack("<I", callback)))
while (msg := conn.read())[0] != callback:
    if msg[0] == 2 and msg[1] == 0:
        globals_[read_string(msg[2], 4)] = struct.unpack_from("<I", msg[2])[0]

def bind(interface, version, new_id):
    conn.send(message(2, 0, struct.pack("<I", globals_[interface]) + string(interface) + struct.pack("<II", version, new_id)))

bind("wl_seat", 7, SEAT)
bind("wl_compositor", 6, COMPOSITOR)
bind("wl_shm", 1, SHM)
bind("xdg_wm_base", 6, WM)
bind("wl_subcompositor", 1, SUBCOMPOSITOR)
conn.send(message(SEAT, 0, struct.pack("<I", POINTER)))
roundtrip()

def surface(surface_id, buffer_id, offset, width, height):
    conn.send(message(POOL, 0, struct.pack("<IiiiiI", buffer_id, offset, width, height, width * 4, 1)))
    conn.send(message(COMPOSITOR, 0, struct.pack("<I", surface_id)))
    conn.send(message(surface_id, 1, struct.pack("<Iii", buffer_id, 0, 0)))

def toplevel():
    conn.send(message(WM, 2, struct.pack("<II", XDG, ROOT)))
    conn.send(message(XDG, 1, struct.pack("<I", TOPLEVEL)))
    conn.send(message(TOPLEVEL, 3, string(scene)))

if scene == "scene":
    # A red 40x30 window taking input on its left half, a green 10x10
    # subsurface at (5, 5) and a blue 20x10 popup the compositor puts at (30, 25).
    pixels = RED * 40 * 30 + GREEN * 10 * 10 + BLUE * 20 * 10
    memory = os.memfd_create("draw")
    os.write(memory, pixels)
    send_fd(message(SHM, 0, struct.pack("<Ii", POOL, len(pixels))), memory)
    surface(ROOT, 11, 0, 40, 30)
    surface(CHILD, 12, 4800, 10, 10)
    surface(POPUP_SURFACE, 13, 5200, 20, 10)
    toplevel()
    conn.send(message(SUBCOMPOSITOR, 1, struct.pack("<III", SUBSURFACE, CHILD, ROOT)))
    conn.send(message(SUBSURFACE, 1, struct.pack("<ii", 5, 5)))
    conn.send(message(COMPOSITOR, 1, struct.pack("<I", REGION)))
    conn.send(message(REGION, 1, struct.pack("<iiii", 0, 0, 20, 30)))
    conn.send(message(ROOT, 5, struct.pack("<I", REGION)))
    conn.send(message(WM, 1, struct.pack("<I", POSITIONER)))
    conn.send(message(WM, 2, struct.pack("<II", POPUP_XDG, POPUP_SURFACE)))
    conn.send(message(POPUP_XDG, 2, struct.pack("<III", POPUP, XDG, POSITIONER)))
    for surface_id in (CHILD, POPUP_SURFACE, ROOT):
        conn.send(message(surface_id, 6))
else:
    # A large window whose pool keeps shrinking and growing again.
    width, height = 2000, 1500
    memory = os.memfd_create("draw")
    os.ftruncate(memory, width * height * 4)
    send_fd(message(SHM, 0, struct.pack("<Ii", POOL, width * height * 4)), memory)
    surface(ROOT, 11, 0, width, height)
    toplevel()
    conn.send(message(ROOT, 6))

    def flicker():
        while True:
            os.ftruncate(memory, 4096)
            os.ftruncate(memory, width * height * 4)

    threading.Thread(target=flicker, daemon=True).start()

roundtrip()
reporting = True
out("ready")

while True:
    ready = select.select([sys.stdin, conn.sock], [], [])[0]
    if conn.sock in ready:
        msg = conn.read()
        if msg is None:
            out("disconnected")
            break
        report(*msg)
        while len(conn.buffer) >= 8 and len(conn.buffer) >= struct.unpack_from("<II", conn.buffer)[1] >> 16:
            report(*conn.read())
    if sys.stdin in ready:
        command = sys.stdin.readline().strip()
        if command in ("", "quit"):
            break
        if command == "geometry":
            # A window geometry far larger than anything the window draws.
            conn.send(message(XDG, 3, struct.pack("<iiii", 0, 0, 4000, 4000)))
            conn.send(message(ROOT, 6))
        roundtrip()
        out("done")
EOF

# Reads pixels of a PNG the broker wrote: its size, then each x,y as rrggbb.
cat >"$test_dir/pixels.py" <<'EOF'
import struct, sys, zlib

data = open(sys.argv[1], "rb").read()
offset, idat = 8, b""
while offset < len(data):
    length, kind = struct.unpack_from(">I4s", data, offset)
    if kind == b"IHDR":
        width, height = struct.unpack_from(">II", data, offset + 8)
    elif kind == b"IDAT":
        idat += data[offset + 8 : offset + 8 + length]
    offset += 12 + length
rows = zlib.decompress(idat)
print(f"{width}x{height}", end="")
for point in sys.argv[2:]:
    x, y = map(int, point.split(","))
    start = y * (width * 3 + 1) + 1 + x * 3
    print(" " + rows[start : start + 3].hex(), end="")
print()
EOF

# Starts draw.py with a scene; commands go to fd draw_in, its output comes
# from fd draw_out.
start_draw() {
  rm -f "$test_dir/draw.in" "$test_dir/draw.out"
  mkfifo "$test_dir/draw.in" "$test_dir/draw.out"
  exec {draw_in}<>"$test_dir/draw.in" {draw_out}<>"$test_dir/draw.out"
  python3 "$test_dir/draw.py" "$socket" "$1" <"$test_dir/draw.in" >"$test_dir/draw.out" 2>>"$test_dir/draw.err" &
  draw_pid=$!
  local line
  read -r -t 5 line <&"$draw_out"
  [[ $line == "ready" ]] || fail "a drawing agent app maps its window" "$line $(cat "$test_dir/draw.err")"
}

stop_draw() {
  echo quit >&"$draw_in"
  wait "$draw_pid" 2>/dev/null
  exec {draw_in}>&- {draw_out}>&-
}

draw_command() {
  local line
  echo "$1" >&"$draw_in"
  while read -r -t 5 line <&"$draw_out" && [[ $line != "done" ]]; do :; done
  [[ $line == "done" ]] || fail "the drawing app runs $1" "$line"
}

# The agent pointer's events the drawing app saw, up to the given number of
# frames, joined with semicolons.
pointer_events() {
  local frames=0 line events=() IFS=";"
  while (( frames < $1 )) && read -r -t 5 line <&"$draw_out"; do
    events+=("$line")
    [[ $line == "frame" ]] && (( frames++ ))
  done
  echo "${events[*]}"
}

window_of() {
  run_broker omarchy-agent-seat-windows | jq -r --arg app "$1" '[.[] | select(.app_id == $app)][-1].window'
}

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
[[ $globals == "wl_compositor wl_data_device_manager wl_seat wl_shm wl_subcompositor xdg_wm_base" ]] || fail "only allowlisted globals are advertised" "$globals"
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
[[ $globals == "wl_compositor wl_data_device_manager wl_seat wl_shm wl_subcompositor xdg_wm_base zwp_linux_dmabuf_v1" ]] || fail "an allowed app gets GPU buffers" "$globals"
globals=$(python3 "$test_dir/app.py" "$socket" globals)
[[ $globals == "wl_compositor wl_data_device_manager wl_seat wl_shm wl_subcompositor xdg_wm_base" ]] || fail "other apps still get no GPU buffers" "$globals"
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


windows=$(run_broker omarchy-agent-seat-windows)
[[ $(jq -r '.[0].app_id' <<<"$windows") == "foot" ]] || fail "windows lists the agent window" "$windows"
pass "windows lists the agent window"

read -r -t 5 typed <&"${APP[0]}"
[[ $typed == "user:30:1:focused user:30:0:focused" ]] || fail "the user's keys reach agent apps" "$typed"
pass "the user's keys reach agent apps"

read -r -t 5 pasted <&"${APP[0]}"
[[ $pasted == "pasted:clipboard-text" ]] || fail "the user can paste into an agent app" "$pasted"
grep -q "^set_selection 902$" "$test_dir/compositor.log" || fail "the user can copy out of an agent app" "$(cat "$test_dir/compositor.log")"
pass "the user can paste into and copy out of an agent app"

run_broker omarchy-agent-seat-type 1 "x" || fail "agent can type into its window"
read -r -t 5 typed <&"${APP[0]}"
[[ $typed == "agent:45:1:focused agent:45:0:focused" ]] || fail "agent keystrokes reach the app alongside the user's" "$typed"
pass "agent keystrokes reach the app alongside the user's"

read -r -t 5 pasted <&"${APP[0]}"
[[ $pasted == "pasted:" ]] || fail "the agent can't paste the user's clipboard" "$pasted"
(( $(grep -c "^receive$" "$test_dir/compositor.log") == 1 )) || fail "the agent's paste never reaches Hyprland"
(( $(grep -c "^set_selection" "$test_dir/compositor.log") == 1 )) || fail "the agent can't set the user's clipboard" "$(cat "$test_dir/compositor.log")"
pass "the agent can't read or set the user's clipboard"

python3 "$test_dir/app.py" "$socket" thief
(( $(grep -c "^set_selection" "$test_dir/compositor.log") == 1 )) || fail "an app can't set the clipboard with serials of the user's input to another app" "$(cat "$test_dir/compositor.log")"
pass "an app can't set the clipboard with serials of the user's input to another app"

run_broker omarchy-agent-seat-type 1 "é" 2>/dev/null && fail "untypeable text is refused"
run_broker omarchy-agent-seat-type 1 --key hyper+x 2>/dev/null && fail "unknown modifiers are refused"
pass "bad keys are refused"

broker=$(run_broker omarchy-agent-seat-status --json | jq -r '.pid')

python3 "$test_dir/app.py" "$socket" vanish "$broker"
sleep 0.2
kill -0 "$broker" 2>/dev/null || fail "an app hanging up with an event in flight leaves the broker running" "$(cat "$test_dir/broker.log")"
[[ $(python3 "$test_dir/app.py" "$socket" globals) == *wl_seat* ]] || fail "the broker still serves apps after one hangs up mid-event"
pass "an app hanging up with an event in flight leaves the broker running"

start_draw flicker
window=$(window_of flicker)
for _ in {1..5}; do
  shot=$(run_broker omarchy-agent-seat-screenshot "$window" 2>&1)
  kill -0 "$broker" 2>/dev/null || fail "an app shrinking its pool under a screenshot leaves the broker running" "$(tail -5 "$test_dir/broker.log")"
  [[ $(python3 "$test_dir/pixels.py" "$shot") == "2000x1500" ]] || fail "a window whose pool shrinks still gets a screenshot" "$shot"
done
stop_draw
pass "an app shrinking its pool under a screenshot leaves the broker running"

# The scene: a red 40x30 window (surface 20) taking input on its left half,
# a green 10x10 subsurface (21) at 5,5 and a blue 20x10 popup (22) at 30,25.
start_draw scene
window=$(window_of scene)

pointer() {
  run_broker omarchy-agent-seat-pointer "$window" "$@"
}

pointer move 2 2 || fail "the agent pointer moves onto a window"
[[ $(pointer_events 1) == "enter 20 2 2;frame" ]] || fail "the agent pointer moves onto a window" "$(pointer_events 1)"
pointer move 10 10 || fail "the agent pointer moves onto a subsurface"
[[ $(pointer_events 1) == "leave 20;enter 21 5 5;frame" ]] || fail "the agent pointer moves onto a subsurface"
pass "the agent pointer moves between a window and its subsurface"

pointer click 35 27 || fail "the agent clicks in a popup"
events=$(pointer_events 3)
[[ $events == "leave 21;enter 22 5 2;frame;button 272 1;frame;button 272 0;frame" ]] || fail "the agent clicks in a popup" "$events"
pass "the agent clicks in a popup"

pointer drag 2 2 18 2 || fail "the agent drags"
events=$(pointer_events 15)
[[ $events == "leave 22;enter 20 2 2;frame;button 272 1;frame;"*";motion 18 2;frame;button 272 0;frame" ]] || fail "the agent drags" "$events"
pass "the agent drags"

pointer scroll 2 2 3 || fail "the agent scrolls"
events=$(pointer_events 2)
[[ $events == "motion 2 2;frame;discrete 0 3;axis 0 45;frame" ]] || fail "the agent scrolls" "$events"
pass "the agent scrolls"

pointer move 30 10 2>/dev/null && fail "the agent pointer can't point outside a surface's input region"
pass "the agent pointer can't point outside a surface's input region"

draw_command geometry
shot=$(run_broker omarchy-agent-seat-screenshot "$window") || fail "a window declaring a huge geometry still gets a screenshot"
[[ $(python3 "$test_dir/pixels.py" "$shot") == "50x35" ]] || fail "a screenshot is only as large as what the window draws" "$(python3 "$test_dir/pixels.py" "$shot")"
pass "a screenshot is only as large as what the window draws"

mkdir -p "$test_dir/work/sub"
ln -s "$test_dir/elsewhere.png" "$test_dir/work/link.png"
(
  cd "$test_dir/work/sub" || exit 1
  [[ $(run_broker omarchy-agent-seat-screenshot "$window" --output shot.png) == "$test_dir/work/sub/shot.png" && -f shot.png ]] || fail "a screenshot can go under the current directory"
  for output in ../../outside.png /tmp/agent-seat-test-$$.png shot.txt ../link.png missing/shot.png; do
    run_broker omarchy-agent-seat-screenshot "$window" --output "$output" 2>/dev/null && fail "a screenshot can't go to $output"
  done
  exit 0
) || exit 1
[[ ! -e $test_dir/outside.png && ! -e /tmp/agent-seat-test-$$.png && ! -e $test_dir/elsewhere.png && ! -e $test_dir/work/sub/missing ]] || fail "refused screenshots write nothing"
pass "a screenshot only goes under the current directory or the seat's own"
stop_draw

descriptors() {
  local fds=(/proc/"$broker"/fd/*)
  echo "${#fds[@]}"
}

before=$(descriptors)
[[ $(python3 "$test_dir/app.py" "$socket" fdflood) == "disconnected" ]] || fail "an app sending more descriptors than libwayland would is dropped"
[[ $(python3 "$test_dir/app.py" "$socket" poolflood) == "disconnected" ]] || fail "an app making hundreds of pools is dropped"
sleep 0.2
(( $(descriptors) <= before )) || fail "a dropped app leaves no descriptors behind" "$before -> $(descriptors)"
[[ $(python3 "$test_dir/app.py" "$socket" globals) == *wl_seat* ]] || fail "the broker serves apps after a descriptor flood"
pass "apps flooding the broker with descriptors are dropped without a leak"

python3 "$test_dir/app.py" "$socket" syncflood >"$test_dir/flood.out" &
flood_pid=$!
for _ in {1..100}; do [[ -s $test_dir/flood.out ]] && break; sleep 0.1; done
[[ $(<"$test_dir/flood.out") == "blocked" ]] || fail "an app that never reads is held back instead of buffered" "$(<"$test_dir/flood.out") $(tail -3 "$test_dir/broker.log")"
rss=$(awk '/^VmRSS/ { print $2 }' "/proc/$broker/status")
(( rss < 120000 )) || fail "an app that never reads does not grow the broker" "${rss} kB"
run_broker omarchy-agent-seat-status >/dev/null || fail "the broker answers while an app floods it"
wait "$flood_pid"
pass "an app that never reads is held back instead of buffered"

sandbox_marker="agent-seat-test-$$"
run_broker omarchy-agent-seat-run --no-wait /usr/bin/bash -c '/usr/bin/sleep 300 & /usr/bin/sleep 300' "$sandbox_marker" || fail "a headless sandbox starts"
records=("$test_dir/runtime/omarchy/agent-seat/sandboxes"/sandbox.*)
(( ${#records[@]} == 1 )) || fail "a sandbox has one lifecycle record" "${records[*]}"
for _ in {1..50}; do
  read -r supervisor_pid _ _ bwrap_pid _ <"${records[0]}" || true
  [[ ${bwrap_pid:-0} != 0 ]] && break
  sleep 0.01
done
[[ ${supervisor_pid:-} =~ ^[0-9]+$ && ${bwrap_pid:-0} != 0 ]] || fail "a sandbox records its supervisor and bwrap processes" "$(cat "${records[0]}")"
sandbox_pids=("$supervisor_pid" "$bwrap_pid")
for _ in {1..50}; do
  known=${#sandbox_pids[@]}
  for pid in "${sandbox_pids[@]}"; do
    while read -r child; do
      [[ " ${sandbox_pids[*]} " == *" $child "* ]] || sandbox_pids+=("$child")
    done < <(pgrep -P "$pid" || true)
  done
  (( ${#sandbox_pids[@]} >= 5 )) && break
  (( known == ${#sandbox_pids[@]} )) && sleep 0.01
done
(( ${#sandbox_pids[@]} >= 5 )) || fail "a headless sandbox starts helper processes" "${sandbox_pids[*]}"
pass "a headless sandbox and its helpers are tracked"

/usr/bin/sleep 300 &
unrelated_pid=$!
unrelated_stat=$(<"/proc/$unrelated_pid/stat")
unrelated_stat=${unrelated_stat##*) }
read -ra unrelated_fields <<<"$unrelated_stat"
printf '%s %s stale-marker 0 0\n' "$unrelated_pid" "${unrelated_fields[19]}" >"$test_dir/runtime/omarchy/agent-seat/sandboxes/sandbox.stale"

run_broker omarchy-agent-seat-stop >/dev/null
for _ in {1..50}; do kill -0 "$broker_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$broker_pid" 2>/dev/null && fail "stop ends the broker"
compgen -G "$test_dir/runtime/omarchy/agent-seat/gpu-*" >/dev/null && fail "stop closes the GPU sockets"
for pid in "${sandbox_pids[@]}"; do
  [[ ! -e /proc/$pid ]] || fail "stop ends every process in a sandbox" "${sandbox_pids[*]}"
done
pass "stop ends every process in a sandbox"
kill -0 "$unrelated_pid" 2>/dev/null || fail "a stale lifecycle record does not kill an unrelated process"
kill "$unrelated_pid"
wait "$unrelated_pid" 2>/dev/null || true
pass "stale lifecycle records do not kill unrelated processes"

run_broker omarchy-agent-seat-run --share "$test_dir/missing" foot 2>/dev/null && fail "sharing a missing path is refused"
pass "sharing a missing path is refused"
[[ $(run_broker omarchy-agent-seat-status) == "Agent seat: stopped" ]] || fail "status reports a stopped seat"
pass "stop ends the broker"
