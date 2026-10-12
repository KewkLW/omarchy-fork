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

# Without python-gobject or the Atspi typelib, the reader says what to install
# instead of failing with a traceback.
mkdir -p "$test_dir/no-gi/gi"
echo 'raise ImportError("no gi here")' >"$test_dir/no-gi/gi/__init__.py"
missing=$(PYTHONPATH="$test_dir/no-gi" "$ROOT/bin/omarchy-agent-seat-ui" --atspi-dump "unix:path=$test_dir/no-bus" 2>&1)
(( $? == 3 )) && [[ -z $missing ]] || fail "the AT-SPI reader reports a missing gi quietly" "$missing"
pass "the AT-SPI reader reports a missing python-gobject without a traceback"

# A menu is a window of its own, here 120x200 at scale 2, and may open outside
# the 400x200 window: its items show within its own bounds, in the pixels of a
# screenshot that starts at the menu when it opens above or left of the window.
popups=$(python3 - "$ROOT/bin/omarchy-agent-seat-ui" <<'EOF'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("seat_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("seat_ui", loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)

def widget(role, name, extents, children=()):
  return {"role": role, "name": name, "value": None, "states": [], "extents": extents, "children": list(children)}

main = widget("frame", "Popup Test", [0, 0, 400, 200], [widget("push button", "Open", [10, 150, 80, 30]), widget("push button", "Away", [500, 10, 50, 20])])
menu = widget("window", "", [0, 0, 120, 200], [widget("menu", "", [0, 0, 120, 200], [widget("menu item", "First", [4, 4, 112, 30]), widget("menu item", "Second", [4, 140, 112, 30])])])
apps = [{"name": "test", "windows": [main, menu]}]

def read(position, origin):
  state = {"title": "Popup Test", "geometry": [0, 0, 400, 200], "surface": [400, 200], "scale": 2, "origin": origin, "popups": [{"position": position, "size": [120, 200]}]}
  return {item["name"] or item["role"]: [item["x"], item["y"]] for item in ui.atspi_tree(state, apps, True)}

print(json.dumps({"beside": read([400, 100], [0, 0, 2]), "above": read([-130, -50], [-130, -50, 2])}))
EOF
) || fail "ui reads a fake tree with a menu" "$popups"

[[ $(jq -c '.beside' <<<"$popups") == '{"Popup Test":[400,200],"Open":[100,330],"window":[920,400],"First":[920,238],"Second":[920,510]}' ]] || fail "ui lists the items of a menu beside the window where they are" "$popups"
pass "ui lists the items of a menu beside the window where they are"
[[ $(jq -c '.above' <<<"$popups") == '{"Popup Test":[660,300],"Open":[360,430],"window":[120,200],"First":[120,38],"Second":[120,310]}' ]] || fail "ui places a window's controls and its menu above it in the screenshot's pixels" "$popups"
pass "ui places a window's controls and its menu above it in the screenshot's pixels"

if ! bwrap_works; then
  skip "bubblewrap cannot create a sandbox here; skipping the agent seat UI"
  exit 0
fi

# The sandbox's init starts the app even where its bus daemons are missing,
# masked here by /dev/null, which is not executable. Its own PID namespace ends
# a daemon it did start when the app exits.
init_without() {
  local masks=() daemon
  for daemon in "$@"; do
    masks+=(--ro-bind /dev/null "$daemon")
  done
  rm -rf "$test_dir/init-bus"
  mkdir -p "$test_dir/init-bus"
  bwrap --dev-bind / / --unshare-pid --die-with-parent "${masks[@]}" \
    --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$test_dir/init-bus/bus" \
    "$ROOT/bin/omarchy-agent-seat-init" /usr/bin/echo started 2>&1
}
started=$(init_without /usr/bin/dbus-daemon /usr/lib/at-spi2-registryd)
[[ $started == "started" && ! -e $test_dir/init-bus/bus ]] || fail "init starts the app without dbus-daemon" "$started"
started=$(init_without /usr/lib/at-spi2-registryd)
[[ $started == "started" && -S $test_dir/init-bus/bus ]] || fail "init starts the app on its bus without at-spi2-registryd" "$started"
pass "init starts the app without dbus-daemon or at-spi2-registryd"

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
  skip "no Wayland compositor or GTK 3; skipping the GTK window"
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

  # Menus that open outside the window, below and above it, where the screenshot
  # then starts.
  program='
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk
window = Gtk.Window(title="Seat Menu Test")
window.set_default_size(400, 200)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
entry = Gtk.Entry()
quit_button = Gtk.Button(label="Quit")
quit_button.connect("clicked", lambda _: Gtk.main_quit())
def menu_button(label, widget_anchor, menu_anchor):
  button = Gtk.Button(label=label)
  menu = Gtk.Menu()
  for name in ("First", "Second", "Third"):
    item = Gtk.MenuItem(label=label + " " + name)
    item.connect("activate", lambda item: entry.set_text("chose " + item.get_label()))
    menu.append(item)
  menu.show_all()
  menu.set_property("anchor-hints", 0)
  button.connect("clicked", lambda _: menu.popup_at_widget(button, widget_anchor, menu_anchor, None))
  return button
box.pack_start(menu_button("Above", Gdk.Gravity.NORTH_WEST, Gdk.Gravity.SOUTH_WEST), False, False, 0)
box.pack_start(entry, False, False, 0)
box.pack_start(quit_button, False, False, 0)
box.pack_end(menu_button("Below", Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST), False, False, 0)
window.add(box)
window.connect("destroy", Gtk.main_quit)
window.show_all()
Gtk.main()
'
  menus=$(seat omarchy-agent-seat-run /usr/bin/python3 -c "$program") || fail "a GTK app with menus opens on the test seat" "$(cat "$runtime/omarchy/agent-seat/apps.log")"
  for _ in {1..50}; do
    seat omarchy-agent-seat-ui "$menus" --find Below >/dev/null 2>&1 && break
    sleep 0.1
  done
  for side in Below Above; do
    # The item furthest from the window, which a screenshot shows past its edge.
    [[ $side == "Below" ]] && name="Below Third" || name="Above First"
    seat omarchy-agent-seat-click-ui "$menus" "$side" >/dev/null || fail "click-ui opens the menu $side the window"
    for _ in {1..50}; do
      seat omarchy-agent-seat-ui "$menus" --find "$name" >/dev/null 2>&1 && break
      sleep 0.1
    done
    seat omarchy-agent-seat-screenshot "$menus" >/dev/null || fail "a screenshot shows the menu $side the window"
    item=$(seat omarchy-agent-seat-ui "$menus" --find "$name" --json)
    state=$(seat omarchy-agent-seat-state "$menus" --json)
    jq -e --arg side "$side" --argjson state "$state" '$state[0] as $s | if $side == "Below" then .box[1] >= $s.size[1] * $s.scale else $s.origin[1] < 0 and .box[1] + .box[3] <= -$s.origin[1] * $s.scale and .box[1] >= 0 end' <<<"$item" >/dev/null || fail "ui lists the items of a menu $side the window, outside it" "$item $state"
    seat omarchy-agent-seat-click-ui "$menus" "$name" >/dev/null || fail "click-ui clicks an item of a menu $side the window"
    for _ in {1..30}; do
      value=$(seat omarchy-agent-seat-ui "$menus" --find text: --json | jq -r '.value')
      [[ $value == "chose $name" ]] && break
      sleep 0.1
    done
    [[ $value == "chose $name" ]] || fail "click-ui on an item of a menu $side the window activates it" "$value"
  done
  seat omarchy-agent-seat-click-ui "$menus" Quit >/dev/null
  pass "ui lists and click-ui clicks the items of menus that open below and above the window"

  missing=$(PYTHONPATH="$test_dir/no-gi" seat omarchy-agent-seat-ui "$window" 2>&1)
  (( $? == 2 )) && [[ $missing == "Install python-gobject and at-spi2-core to read accessibility trees" ]] || fail "ui without python-gobject says what to install and exits 2" "$missing"
  pass "ui without python-gobject says what to install and exits 2"
fi

# The DevTools route, against a fake DevTools endpoint ------------------------------------

cat >"$test_dir/cdp.py" <<'EOF'
import base64, hashlib, html, json, socket, struct, sys

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
    # The pages, each in a browser window of some size and shown or not, are
    # the test's to change between requests.
    with open(sys.argv[2]) as pages_file:
        PAGES = json.load(pages_file)
    if lines[0].startswith("GET /json/list") or lines[0].startswith("GET /json/version"):
        if lines[0].startswith("GET /json/list"):
            body = [{"type": "page", "id": page["id"], "title": page["title"], "url": f"https://example.com/{page['id']}", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/{page['id']}"} for page in PAGES]
        else:
            body = {"webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/browser/fake"}
        body = json.dumps(body).encode()
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        conn.close()
        continue
    page = next((page for page in PAGES if lines[0].split()[1] == f"/devtools/page/{page['id']}"), None)
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
            if method == "Runtime.evaluate" and "visibilityState" in params["expression"]:
                # The page's own title is plain.
                result = {"result": {"type": "string", "value": json.dumps(["visible" if page["visible"] else "hidden", html.unescape(page["title"])])}}
            elif method == "Runtime.evaluate":
                result = {"result": {"type": "string", "value": json.dumps([800, 600, float(sys.argv[1])])}}
            elif method == "Browser.getWindowForTarget":
                width, height = next(page["window"] for page in PAGES if page["id"] == params["targetId"])
                result = {"windowId": width, "bounds": {"left": 0, "top": 0, "width": width, "height": height}}
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

# DevTools escapes titles as HTML; the window's title is plain.
cat >"$test_dir/pages.json" <<'EOF'
[
  {"id": "2", "title": "Fun &amp; games", "visible": true, "window": [800, 600]},
  {"id": "1", "title": "Fake page", "visible": true, "window": [800, 600]}
]
EOF

coproc CDP { exec python3 "$test_dir/cdp.py" 1.5 "$test_dir/pages.json" 2>/dev/null; }
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
nodes = ui.cdp_tree(state, int(sys.argv[2]))
escaped = ui.cdp_target(int(sys.argv[2]), "Fun & games - Chromium") or {}
print(json.dumps({"nodes": nodes, "send": ui.find(nodes, "send"), "box": ui.find(nodes, "textbox:"), "listing": [ui.describe(n) for n in nodes], "escaped": escaped.get("webSocketDebuggerUrl", "")}))
EOF
) || fail "ui reads a page over DevTools" "$cdp"

[[ $(jq -r '.nodes | map(.role) | join(" ")' <<<"$cdp") == "RootWebArea button textbox" ]] || fail "the DevTools route lists the page's controls, skipping repeated text and what is scrolled away" "$cdp"
pass "the DevTools route lists the page's controls, skipping repeated text and what is scrolled away"
[[ $(jq -c '.send[0] | [.x, .y, .box]' <<<"$cdp") == "[90,60,[15,30,150,60]]" ]] || fail "the DevTools route positions controls in screenshot pixels" "$cdp"
pass "the DevTools route positions controls in screenshot pixels"
[[ $(jq -r '.box[0].value' <<<"$cdp") == "hi" && $(jq -r '.box[0].states[0]' <<<"$cdp") == "focused" ]] || fail "the DevTools route reports values and focus" "$cdp"
jq -r '.listing[]' <<<"$cdp" | grep -qx 'textbox "Message" = "hi" @525,60 \[focused\]' || fail "the DevTools route lists controls for people" "$cdp"
pass "the DevTools route reports values and focus"
[[ $(jq -r '.escaped' <<<"$cdp") == */devtools/page/2 ]] || fail "the DevTools route finds a tab whose title DevTools escapes" "$cdp"
pass "the DevTools route finds a tab whose title DevTools escapes"

# Tabs and windows alike can share a title: a page is the window's only when it
# is the tab the window shows, in a window of the window's size, and never just
# the first page DevTools lists.
twins=$(python3 - "$ROOT/bin/omarchy-agent-seat-ui" "$cdp_port" "$test_dir/pages.json" <<'EOF'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("seat_ui", sys.argv[1])
spec = importlib.util.spec_from_loader("seat_ui", loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)

def pick(pages, size):
  with open(sys.argv[3], "w") as pages_file:
    json.dump(pages, pages_file)
  try:
    return (ui.cdp_target(int(sys.argv[2]), "Twin - Chromium", size) or {}).get("webSocketDebuggerUrl", "none")
  except Exception as error:
    return f"refused: {error}"

print(json.dumps({
  "tabs": pick([{"id": "3", "title": "Twin", "visible": False, "window": [800, 600]}, {"id": "4", "title": "Twin", "visible": True, "window": [800, 600]}], [800, 600]),
  "windows": pick([{"id": "3", "title": "Twin", "visible": True, "window": [800, 600]}, {"id": "4", "title": "Twin", "visible": True, "window": [800, 600]}], [800, 600]),
  "sized": pick([{"id": "3", "title": "Twin", "visible": True, "window": [400, 600]}, {"id": "4", "title": "Twin", "visible": True, "window": [800, 600]}], [800, 600]),
  "hidden": pick([{"id": "3", "title": "Other", "visible": True, "window": [800, 600]}, {"id": "4", "title": "Twin", "visible": False, "window": [800, 600]}], [800, 600]),
}))
EOF
) || fail "ui picks between pages of the same title" "$twins"

[[ $(jq -r '.tabs' <<<"$twins") == */devtools/page/4 ]] || fail "the DevTools route reads the shown tab of several with the window's title" "$twins"
[[ $(jq -r '.sized' <<<"$twins") == */devtools/page/4 ]] || fail "the DevTools route tells shown pages apart by their window's size" "$twins"
[[ $(jq -r '.hidden' <<<"$twins") == "none" ]] || fail "the DevTools route reads no page when none with the window's title is shown" "$twins"
pass "the DevTools route reads the page the window shows, among others of the same title"
[[ $(jq -r '.windows' <<<"$twins") == "refused: 2 pages are shown in windows titled 'Twin - Chromium'"* ]] || fail "the DevTools route refuses to guess between windows showing the same title" "$twins"
jq -r '.windows' <<<"$twins" | grep -q "https://example.com/3" || fail "a refusal lists the pages it could not tell apart" "$twins"
pass "the DevTools route refuses to guess between windows showing the same title, and lists them"

# Stopping ----------------------------------------------------------------------------

seat omarchy-agent-seat-stop >/dev/null
for _ in {1..50}; do kill -0 "$broker_pid" 2>/dev/null || break; sleep 0.1; done
compgen -G "$runtime/omarchy/agent-seat/sandboxes/*.d" >/dev/null && fail "stop removes the private buses" "$(ls -la "$runtime/omarchy/agent-seat/sandboxes")"
pgrep -f "dbus-daemon --config-file=$runtime/agent-bus/bus.conf" >/dev/null && fail "stop ends the private bus daemons"
pass "stop ends the private buses with their sandboxes"
