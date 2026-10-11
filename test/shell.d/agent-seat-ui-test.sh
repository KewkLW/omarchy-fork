#!/bin/bash

source "$(dirname "$0")/base-test.sh"

# The seat commands find their sandbox supervisor and init under $OMARCHY_PATH.
export OMARCHY_PATH="$ROOT"

require_command python3
require_command jq
require_command bwrap
require_command dbus-daemon
require_command busctl

test_dir=$(mktemp -d)
runtime="$test_dir/runtime"
mkdir -p "$test_dir/bin" "$test_dir/share" "$runtime"

# The live session's compositor, if there is one, as an absolute path: the
# test seat keeps its own runtime directory but draws real windows.
compositor=""
if compositor_reachable; then
  compositor=$WAYLAND_DISPLAY
  [[ $compositor == /* ]] || compositor="$XDG_RUNTIME_DIR/$compositor"
fi

seat() {
  XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="${compositor:-$test_dir/no-compositor}" PATH="$test_dir/bin:$ROOT/bin:$PATH" "$@"
}

cleanup() {
  seat omarchy-agent-seat-stop >/dev/null 2>&1 || true
  [[ -n ${broker_pid:-} ]] && kill "$broker_pid" 2>/dev/null
  [[ -n ${cdp_pid:-} ]] && kill "$cdp_pid" 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

# The test seat must not look the live seat's windows up in Hyprland.
printf '#!/bin/bash\necho "[]"\n' >"$test_dir/bin/hyprctl"
chmod +x "$test_dir/bin/hyprctl"

seat omarchy-agent-seat-broker serve 2>"$test_dir/broker.log" &
broker_pid=$!
for _ in {1..50}; do [[ -S $runtime/omarchy/agent-seat/control ]] && break; sleep 0.1; done
[[ -S $runtime/omarchy/agent-seat/control ]] || fail "test broker starts" "$(cat "$test_dir/broker.log")"

# The private bus ------------------------------------------------------------------

seat omarchy-agent-seat-run --no-wait --share "$test_dir/share" /usr/bin/bash -c '
  report="$1/report"
  echo "address $DBUS_SESSION_BUS_ADDRESS" >"$report.tmp"
  echo "a11y $AT_SPI_BUS_ADDRESS" >>"$report.tmp"
  [[ -e /run/user/'"$UID"'/bus ]] && echo "host bus visible" >>"$report.tmp"
  busctl --user list --no-pager --no-legend 2>&1 | cut -d" " -f1 | sed "s/^/name /" >>"$report.tmp"
  dbus-send --session --print-reply --dest=org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 && echo "keyring reachable" >>"$report.tmp"
  dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 && echo "portal reachable" >>"$report.tmp"
  mv "$report.tmp" "$report"
  sleep 300' bus-check "$test_dir/share" || fail "a sandbox with a private bus starts"

for _ in {1..100}; do [[ -e $test_dir/share/report ]] && break; sleep 0.05; done
report=$(cat "$test_dir/share/report" 2>/dev/null)
grep -q "^address unix:path=$runtime/agent-bus/bus$" <<<"$report" || fail "the sandbox gets a private session bus" "$report"
grep -q "^a11y unix:path=$runtime/agent-bus/bus$" <<<"$report" || fail "the private bus is also the accessibility bus" "$report"
grep -qx "name org.a11y.atspi.Registry" <<<"$report" || fail "the accessibility registry runs on the private bus" "$report"
pass "a sandbox gets a private session bus with the accessibility registry on it"

grep -q "host bus visible\|keyring reachable\|portal reachable" <<<"$report" && fail "the user's bus, keyring and portals stay unreachable" "$report"
pass "the user's session bus, keyring and portals stay unreachable from the sandbox"

bus_dirs=("$runtime"/omarchy/agent-seat/sandboxes/*.d)
bus_socket="${bus_dirs[0]}/bus/bus"
[[ -S $bus_socket ]] || fail "the seat reaches the private bus from outside" "$(ls -laR "$runtime/omarchy/agent-seat/sandboxes")"
[[ $(stat -c %a "${bus_dirs[0]}") == "700" && $(stat -c %a "${bus_dirs[0]}/bus") == "700" ]] || fail "the private bus is the user's alone"
private_id=$(busctl --address="unix:path=$bus_socket" call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId 2>&1) || fail "the seat reaches the private bus from outside" "$private_id"
host_id=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId 2>/dev/null || true)
[[ $private_id != "$host_id" ]] || fail "the private bus is not the user's bus"
pass "the seat reaches the private bus from outside, and it is not the user's bus"

# The accessibility tree of a GTK app, and clicking by name -----------------------------

if [[ -z $compositor ]] || ! python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("Atspi", "2.0")' 2>/dev/null; then
  pass "no Wayland compositor or GTK 3; skipping the GTK window"
else
  program='
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
window = Gtk.Window(title="Seat UI Test")
window.set_default_size(400, 200)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=20)
entry = Gtk.Entry()
button = Gtk.Button(label="Fill")
button.connect("clicked", lambda _: entry.set_text("clicked"))
other = Gtk.Button(label="Fill later")
box.pack_start(entry, False, False, 0)
box.pack_start(button, False, False, 0)
box.pack_start(other, False, False, 0)
window.add(box)
window.connect("destroy", Gtk.main_quit)
window.show_all()
Gtk.main()
'
  window=$(seat omarchy-agent-seat-run /usr/bin/python3 -c "$program") || fail "a GTK app opens on the test seat" "$(cat "$runtime/omarchy/agent-seat/apps.log")"

  for _ in {1..50}; do
    state=$(seat omarchy-agent-seat-state "$window" --json)
    [[ $(jq -r '.[0].drawn' <<<"$state") == "true" ]] && break
    sleep 0.1
  done
  [[ $(jq -r '.[0].title' <<<"$state") == "Seat UI Test" ]] || fail "state reports the window" "$state"
  [[ $(jq -r '.[0].drawn' <<<"$state") == "true" ]] || fail "state reports that the app has drawn" "$state"
  [[ $(jq -r '.[0].pid' <<<"$state") =~ ^[0-9]+$ && $(jq -r '.[0].scale' <<<"$state") != "null" ]] || fail "state reports the app's pid and scale" "$state"
  seat omarchy-agent-seat-state "$window" | grep -q "^window $window: .*\"Seat UI Test\"" || fail "state lists the window for people"
  pass "state reports the window, its scale, and that it has drawn"

  for _ in {1..50}; do
    tree=$(seat omarchy-agent-seat-ui "$window" 2>&1) && grep -q 'button "Fill"' <<<"$tree" && break
    sleep 0.1
  done
  grep -q '^frame "Seat UI Test"' <<<"$tree" || fail "ui lists the window" "$tree"
  grep -q '^  button "Fill" @[0-9]*,[0-9]*' <<<"$tree" || fail "ui lists the button with its position" "$tree"
  grep -q '^  text "" @[0-9]*,[0-9]* \[.*editable' <<<"$tree" || fail "ui lists the entry" "$tree"
  [[ $(seat omarchy-agent-seat-ui "$window" --json | jq -r '.source') == "atspi" ]] || fail "a GTK window is read over AT-SPI"
  pass "ui reads a GTK window's accessibility tree over the private bus"

  # The button's centre, in screenshot pixels, must be on the button.
  button=$(seat omarchy-agent-seat-ui "$window" --find Fill --json)
  jq -e --argjson state "$state" '($state[0].size | map(. * $state[0].scale)) as [$width, $height] | .x > .box[0] and .x < .box[0] + .box[2] and .box[0] + .box[2] <= $width and .box[1] + .box[3] <= $height and .box[2] > $state[0].size[0]' <<<"$button" >/dev/null || fail "ui positions are in screenshot pixels" "$button $state"
  pass "ui positions controls in screenshot pixels"

  seat omarchy-agent-seat-click-ui "$window" "Fill" >/dev/null || fail "click-ui clicks a button by name"
  for _ in {1..30}; do
    value=$(seat omarchy-agent-seat-ui "$window" --find text: --json | jq -r '.value')
    [[ $value == "clicked" ]] && break
    sleep 0.1
  done
  [[ $value == "clicked" ]] || fail "click-ui on the button changes the entry" "$value"
  pass "click-ui on a button changes the entry, and ui shows it"

  [[ $(seat omarchy-agent-seat-state "$window" --json | jq -r '.[0].focus.owner') == "agent" ]] || fail "state reports that the agent acted last"
  pass "state reports whose input the window saw last"

  seat omarchy-agent-seat-click-ui "$window" "fill l" >/dev/null || fail "click-ui falls back to a unique substring"
  candidates=$(seat omarchy-agent-seat-click-ui "$window" "button:" 2>&1) && fail "click-ui refuses an ambiguous name"
  grep -q 'button "Fill later"' <<<"$candidates" || fail "an ambiguous name lists the candidates" "$candidates"
  seat omarchy-agent-seat-click-ui "$window" "Nothing here" 2>/dev/null && fail "click-ui refuses a name that matches nothing"
  pass "click-ui matches exact, then by substring, and lists ambiguous candidates"
fi

# The DevTools route, against a fake DevTools endpoint ------------------------------------

cat >"$test_dir/cdp.py" <<'EOF'
import base64, hashlib, json, socket, struct, sys

server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(4)
port = server.getsockname()[1]
print(port, flush=True)

NODES = [
  {"nodeId": "1", "ignored": False, "role": {"value": "RootWebArea"}, "name": {"value": "Fake page"}, "childIds": ["2", "3", "5"], "backendDOMNodeId": 1},
  {"nodeId": "2", "parentId": "1", "ignored": False, "role": {"value": "button"}, "name": {"value": "Send"}, "childIds": ["4"], "backendDOMNodeId": 2},
  {"nodeId": "4", "parentId": "2", "ignored": False, "role": {"value": "StaticText"}, "name": {"value": "Send"}, "childIds": [], "backendDOMNodeId": 4},
  {"nodeId": "3", "parentId": "1", "ignored": False, "role": {"value": "textbox"}, "name": {"value": "Message"}, "value": {"value": "hi"}, "properties": [{"name": "focused", "value": {"value": True}}], "childIds": [], "backendDOMNodeId": 3},
  {"nodeId": "5", "parentId": "1", "ignored": False, "role": {"value": "link"}, "name": {"value": "Far away"}, "childIds": [], "backendDOMNodeId": 5},
]
BOXES = {1: [0, 0, 800, 600], 2: [10, 20, 100, 40], 3: [200, 20, 300, 40], 4: [20, 25, 80, 30], 5: [10, 5000, 100, 20]}

def frame(sock, text):
    data = text.encode()
    header = bytes([0x81]) + (bytes([len(data)]) if len(data) < 126 else bytes([126]) + struct.pack(">H", len(data)) if len(data) < 65536 else bytes([127]) + struct.pack(">Q", len(data)))
    sock.sendall(header + data)

def read(sock, buffer, count):
    while len(buffer) < count:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError
        buffer += chunk
    return buffer[:count], buffer[count:]

while True:
    conn, _ = server.accept()
    request = b""
    while b"\r\n\r\n" not in request:
        request += conn.recv(65536)
    head, rest = request.split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    if lines[0].startswith("GET /json/list"):
        body = json.dumps([{"type": "page", "title": "Fake page", "url": "https://example.org", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/1"}]).encode()
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        conn.close()
        continue
    key = next(line.split(":", 1)[1].strip() for line in lines if line.lower().startswith("sec-websocket-key"))
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
    buffer = rest
    try:
        while True:
            header, buffer = read(conn, buffer, 2)
            length = header[1] & 0x7F
            if length == 126:
                raw, buffer = read(conn, buffer, 2)
                length = struct.unpack(">H", raw)[0]
            elif length == 127:
                raw, buffer = read(conn, buffer, 8)
                length = struct.unpack(">Q", raw)[0]
            mask, buffer = read(conn, buffer, 4)
            payload, buffer = read(conn, buffer, length)
            message = json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
            method, params = message["method"], message.get("params", {})
            if method == "Runtime.evaluate":
                result = {"result": {"type": "string", "value": json.dumps([800, 600, float(sys.argv[1])])}}
            elif method == "Accessibility.getFullAXTree":
                result = {"nodes": NODES}
            elif method == "DOM.getBoxModel":
                x, y, w, h = BOXES[params["backendNodeId"]]
                result = {"model": {"border": [x, y, x + w, y, x + w, y + h, x, y + h]}}
            else:
                result = {}
            frame(conn, json.dumps({"id": message["id"], "result": result}))
    except (ConnectionError, OSError):
        conn.close()
EOF

coproc CDP { exec python3 "$test_dir/cdp.py" 1.5 2>/dev/null; }
cdp_pid=$CDP_PID
read -r -t 5 cdp_port <&"${CDP[0]}" || fail "the fake DevTools endpoint starts"

# An 800x600 page filling a window at scale 1.5, whose last screenshot started
# at its corner: CSS pixels map to screenshot pixels 1.5 times over.
cdp=$(python3 - "$ROOT/bin/omarchy-agent-seat-ui" "$cdp_port" <<'EOF'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("seat_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("seat_ui", loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)
state = {"title": "Fake page - Chromium", "geometry": [0, 0, 800, 600], "origin": [0, 0, 1.5], "scale": 1.5}
nodes = ui.cdp_tree(state, int(sys.argv[2]), False)
print(json.dumps({"nodes": nodes, "send": ui.find(nodes, "send"), "box": ui.find(nodes, "textbox:"), "listing": [ui.describe(n) for n in nodes]}))
EOF
) || fail "ui reads a page over DevTools" "$cdp"

[[ $(jq -r '.nodes | map(.role) | join(" ")' <<<"$cdp") == "RootWebArea button textbox" ]] || fail "the DevTools route lists the page's controls, skipping repeated text and what is scrolled away" "$cdp"
pass "the DevTools route lists the page's controls, skipping repeated text and what is scrolled away"
[[ $(jq -c '.send[0] | [.x, .y, .box]' <<<"$cdp") == "[90,60,[15,30,150,60]]" ]] || fail "the DevTools route positions controls in screenshot pixels" "$cdp"
pass "the DevTools route positions controls in screenshot pixels"
[[ $(jq -r '.box[0].value' <<<"$cdp") == "hi" && $(jq -r '.box[0].states[0]' <<<"$cdp") == "focused" ]] || fail "the DevTools route reports values and focus" "$cdp"
jq -r '.listing[]' <<<"$cdp" | grep -qx 'textbox "Message" = "hi" @525,60 \[focused\]' || fail "the DevTools route lists controls for people" "$cdp"
pass "the DevTools route reports values and focus"

# Stopping ----------------------------------------------------------------------------

seat omarchy-agent-seat-stop >/dev/null
for _ in {1..50}; do kill -0 "$broker_pid" 2>/dev/null || break; sleep 0.1; done
compgen -G "$runtime/omarchy/agent-seat/sandboxes/*.d" >/dev/null && fail "stop removes the private buses" "$(ls -la "$runtime/omarchy/agent-seat/sandboxes")"
pgrep -f "dbus-daemon --config-file=$runtime/agent-bus/bus.conf" >/dev/null && fail "stop ends the private bus daemons"
pass "stop ends the private buses with their sandboxes"
