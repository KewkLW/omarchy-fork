#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A real GTK window on the test seat, read through its accessibility tree and
# clicked by name. It maps a window, so the runner gives it a compositor of its
# own rather than the developer's desktop.
require_compositor "the agent seat's GTK window"

# The seat commands find their sandbox supervisor under $OMARCHY_PATH.
export OMARCHY_PATH="$ROOT"

require_command python3
require_command jq
require_command bwrap
require_command dbus-daemon

if ! bwrap_works; then
  skip "bubblewrap cannot create a sandbox here; skipping the agent seat's GTK window"
  exit 0
fi

test_dir=$(mktemp -d)
runtime="$test_dir/runtime"
mkdir -p "$test_dir/bin" "$test_dir/home" "$runtime"

# The compositor as an absolute path: the test seat keeps its own runtime
# directory but draws real windows.
compositor=$WAYLAND_DISPLAY
[[ $compositor == /* ]] || compositor="$XDG_RUNTIME_DIR/$compositor"

# A home of the test's own: a launch makes the seat's home under it, and moves
# one it finds at the old place, which must never be the developer's own.
seat() {
  HOME="$test_dir/home" XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$compositor" PATH="$test_dir/bin:$ROOT/bin:$PATH" "$@"
}

cleanup() {
  seat omarchy-agent-seat-stop >/dev/null 2>&1 || true
  [[ -n ${broker_pid:-} ]] && kill "$broker_pid" 2>/dev/null || true
  rm -rf "$test_dir" || true
}
trap cleanup EXIT

# The test seat must not look the live seat's windows up in Hyprland.
printf '#!/bin/bash\necho "[]"\n' >"$test_dir/bin/hyprctl"
chmod +x "$test_dir/bin/hyprctl"

# Stands in for a missing python-gobject.
mkdir -p "$test_dir/no-gi/gi"
echo 'raise ImportError("no gi here")' >"$test_dir/no-gi/gi/__init__.py"

seat omarchy-agent-seat-broker serve 2>"$test_dir/broker.log" &
broker_pid=$!
for _ in {1..50}; do [[ -S $runtime/omarchy/agent-seat/control ]] && break; sleep 0.1; done
[[ -S $runtime/omarchy/agent-seat/control ]] || fail "test broker starts" "$(cat "$test_dir/broker.log")"

# The accessibility tree of a GTK app, and clicking by name -----------------------------

if ! python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("Atspi", "2.0")' 2>/dev/null; then
  skip "GTK 3 or AT-SPI bindings missing; skipping the GTK window"
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
    state=$(seat omarchy-agent-seat-state "$window" --json) || true
    [[ $(jq -r '.[0].drawn' <<<"$state") == "true" ]] && break
    sleep 0.1
  done
  [[ $(jq -r '.[0].title' <<<"$state") == "Seat UI Test" ]] || fail "state reports the window" "$state"
  [[ $(jq -r '.[0].drawn' <<<"$state") == "true" ]] || fail "state reports that the app has drawn" "$state"
  [[ $(jq -r '.[0].pid' <<<"$state") =~ ^[0-9]+$ && $(jq -r '.[0].scale' <<<"$state") != "null" ]] || fail "state reports the app's pid and scale" "$state"
  listing=$(seat omarchy-agent-seat-state "$window") || fail "state lists the window for people" "$listing"
  grep -q "^window $window: .*\"Seat UI Test\"" <<<"$listing" || fail "state lists the window for people" "$listing"
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

  # The button's centre, in screenshot pixels, must be on the button. The
  # button spans the window less the box's 20-unit margins, so in screenshot
  # pixels it starts 20 x scale in and is (width - 40) x scale wide, give or
  # take rounding: at scale 1 that is also its size in surface units.
  button=$(seat omarchy-agent-seat-ui "$window" --find Fill --json) || true
  jq -e --argjson state "$state" '$state[0] as $s | ($s.size | map(. * $s.scale)) as [$width, $height] | def near($want): (. - $want | fabs) <= 2; .x > .box[0] and .x < .box[0] + .box[2] and .box[0] + .box[2] <= $width and .box[1] + .box[3] <= $height and (.box[0] | near(20 * $s.scale)) and (.box[2] | near(($s.size[0] - 40) * $s.scale))' <<<"$button" >/dev/null || fail "ui positions are in screenshot pixels" "$button $state"
  pass "ui positions controls in screenshot pixels"

  seat omarchy-agent-seat-click-ui "$window" "Fill" >/dev/null || fail "click-ui clicks a button by name"
  for _ in {1..30}; do
    value=$(seat omarchy-agent-seat-ui "$window" --find text: --json | jq -r '.value') || true
    [[ $value == "clicked" ]] && break
    sleep 0.1
  done
  [[ $value == "clicked" ]] || fail "click-ui on the button changes the entry" "$value"
  pass "click-ui on a button changes the entry, and ui shows it"

  [[ $(seat omarchy-agent-seat-state "$window" --json | jq -r '.[0].focus.owner') == "agent" ]] || fail "state reports that the agent acted last"
  pass "state reports whose input the window saw last"

  partial=$(seat omarchy-agent-seat-click-ui "$window" "fill l" 2>&1) && fail "click-ui refuses a name that is only part of a control's"
  grep -q 'button "Fill later"' <<<"$partial" || fail "a partial name lists the control it is part of" "$partial"
  seat omarchy-agent-seat-click-ui "$window" "fill later" >/dev/null || fail "click-ui clicks a full name in any case"
  candidates=$(seat omarchy-agent-seat-click-ui "$window" "button:" 2>&1) && fail "click-ui refuses an ambiguous name"
  grep -q 'button "Fill later"' <<<"$candidates" || fail "an ambiguous name lists the candidates" "$candidates"
  seat omarchy-agent-seat-click-ui "$window" "Nothing here" 2>/dev/null && fail "click-ui refuses a name that matches nothing"
  pass "click-ui matches exact, then in any case, and lists partial and ambiguous candidates"

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
attached = Gtk.Menu()
for name in ("Choose First", "Choose Second", "Choose Third"):
  item = Gtk.MenuItem(label=name)
  item.connect("activate", lambda item: entry.set_text("chose " + item.get_label()))
  attached.append(item)
attached.show_all()
choose = Gtk.MenuButton(label="Choose")
choose.set_use_popover(False)
choose.set_popup(attached)
box.pack_start(choose, False, False, 0)
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
    seat omarchy-agent-seat-click-ui "$menus" "button:$side" >/dev/null || fail "click-ui opens the menu $side the window"
    for _ in {1..50}; do
      seat omarchy-agent-seat-ui "$menus" --find "$name" >/dev/null 2>&1 && break
      sleep 0.1
    done
    seat omarchy-agent-seat-screenshot "$menus" >/dev/null || fail "a screenshot shows the menu $side the window"
    item=$(seat omarchy-agent-seat-ui "$menus" --find "$name" --json) || true
    state=$(seat omarchy-agent-seat-state "$menus" --json) || true
    jq -e --arg side "$side" --argjson state "$state" '$state[0] as $s | if $side == "Below" then .box[1] >= $s.size[1] * $s.scale else $s.origin[1] < 0 and .box[1] + .box[3] <= -$s.origin[1] * $s.scale and .box[1] >= 0 end' <<<"$item" >/dev/null || fail "ui lists the items of a menu $side the window, outside it" "$item $state"
    seat omarchy-agent-seat-click-ui "$menus" "$name" >/dev/null || fail "click-ui clicks an item of a menu $side the window"
    for _ in {1..30}; do
      value=$(seat omarchy-agent-seat-ui "$menus" --find text: --json | jq -r '.value') || true
      [[ $value == "chose $name" ]] && break
      sleep 0.1
    done
    [[ $value == "chose $name" ]] || fail "click-ui on an item of a menu $side the window activates it" "$value"
  done

  seat omarchy-agent-seat-click-ui "$menus" "toggle button:Choose" >/dev/null || fail "click-ui opens a menu button's menu"
  for _ in {1..50}; do
    seat omarchy-agent-seat-ui "$menus" --find "Choose Second" >/dev/null 2>&1 && break
    sleep 0.1
  done
  sleep 0.5  # GTK ignores a click on a menu that has only just opened
  seat omarchy-agent-seat-click-ui "$menus" "Choose Second" >/dev/null || fail "click-ui clicks an item of a menu button's menu"
  for _ in {1..30}; do
    value=$(seat omarchy-agent-seat-ui "$menus" --find text: --json | jq -r '.value') || true
    [[ $value == "chose Choose Second" ]] && break
    sleep 0.1
  done
  [[ $value == "chose Choose Second" ]] || fail "click-ui on an item of a menu button's menu activates it" "$value"
  pass "click-ui clicks the items of a menu GTK lists under its button"

  seat omarchy-agent-seat-click-ui "$menus" Quit >/dev/null || true
  pass "ui lists and click-ui clicks the items of menus that open below and above the window"

  code=0
  missing=$(PYTHONPATH="$test_dir/no-gi" seat omarchy-agent-seat-ui "$window" 2>&1) || code=$?
  (( code == 2 )) && [[ $missing == "Install python-gobject and at-spi2-core to read accessibility trees" ]] || fail "ui without python-gobject says what to install and exits 2" "$missing"
  pass "ui without python-gobject says what to install and exits 2"
fi
