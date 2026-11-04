// Pure helpers for the window frames overlay. Inputs are the objects
// Hyprland returns for `j/clients` and `j/monitors`; nothing here touches QML.

function geometryKey(client) {
  var at = client && client.at ? client.at : [0, 0]
  var size = client && client.size ? client.size : [0, 0]
  return at[0] + "," + at[1] + "," + size[0] + "," + size[1]
}

// Remembers when each window last changed geometry. A window whose geometry
// changed less than settleMs ago is moving (dragged, resized or animating),
// and its frame stays hidden until it holds still.
function trackMotion(previous, clients, now, settleMs) {
  var state = {}
  var moving = {}
  var anyMoving = false
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i]
    if (!c || !c.address) continue
    var key = geometryKey(c)
    var before = previous ? previous[c.address] : null
    var changedAt = before && before.key === key ? before.changedAt : now
    state[c.address] = { key: key, changedAt: changedAt }
    if (now - changedAt < settleMs) {
      moving[c.address] = true
      anyMoving = true
    }
  }
  return { state: state, moving: moving, anyMoving: anyMoving }
}

// Windows that never get a frame: untitled floating windows (X11 menus,
// tooltips, splash screens) and any window tagged no-window-frame, e.g.
//   hl.window_rule({ match = { class = "^steam$" }, tag = "+no-window-frame" })
function skipsFrame(client) {
  if (client.floating && String(client.title || "").length === 0) return true
  var tags = client.tags || []
  for (var i = 0; i < tags.length; i++)
    if (String(tags[i]).replace(/\*$/, "") === "no-window-frame") return true
  return false
}

function workspaceId(value) {
  return value && value.id !== undefined ? Number(value.id) : 0
}

// Stacking rank: tiled below floating below pinned, the special workspace
// above all of those, and within a rank the most recently focused on top.
function stackRank(client, specialId) {
  var rank = client.floating ? 1 : 0
  if (client.pinned) rank = 2
  if (specialId !== 0 && workspaceId(client.workspace) === specialId) rank += 3
  return rank
}

function intersects(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// Frames to draw on one monitor, in paint order (bottom first). Each frame has
// the window rect in monitor-local coordinates and the rects of the windows
// stacked above it that overlap its frame box, so the overlay can cut the
// frame out where a higher window covers it.
//   options.reach    how far the frame box extends past the window, per side
//   options.moving   addresses whose frame stays hidden for now
function framesForMonitor(clients, monitor, options) {
  if (!monitor) return []
  var reach = options && options.reach ? options.reach : { left: 0, top: 0, right: 0, bottom: 0 }
  var moving = options && options.moving ? options.moving : {}
  var activeId = workspaceId(monitor.activeWorkspace)
  var specialId = workspaceId(monitor.specialWorkspace)
  var monitorId = Number(monitor.id)

  var onMonitor = []
  var fullscreenWorkspaces = {}
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i]
    // Inactive tabs of a group share the active tab's geometry; Hyprland
    // marks them visible: false.
    if (!c || !c.mapped || c.hidden || c.visible === false || Number(c.monitor) !== monitorId) continue
    var ws = workspaceId(c.workspace)
    var shown = specialId !== 0 ? ws === specialId : (ws === activeId || c.pinned)
    if (!shown) continue
    if (Number(c.fullscreen || 0) > 0) fullscreenWorkspaces[ws] = true
    onMonitor.push(c)
  }

  onMonitor.sort(function(a, b) {
    var ra = stackRank(a, specialId)
    var rb = stackRank(b, specialId)
    if (ra !== rb) return ra - rb
    return Number(b.focusHistoryID || 0) - Number(a.focusHistoryID || 0)
  })

  var rects = onMonitor.map(function(c) {
    return {
      x: c.at[0] - monitor.x,
      y: c.at[1] - monitor.y,
      w: c.size[0],
      h: c.size[1],
    }
  })

  var frames = []
  for (var j = 0; j < onMonitor.length; j++) {
    var client = onMonitor[j]
    if (fullscreenWorkspaces[workspaceId(client.workspace)] || moving[client.address] || skipsFrame(client)) continue
    var rect = rects[j]
    if (rect.w <= 0 || rect.h <= 0) continue
    var box = {
      x: rect.x - reach.left,
      y: rect.y - reach.top,
      w: rect.w + reach.left + reach.right,
      h: rect.h + reach.top + reach.bottom,
    }
    var occluders = []
    for (var k = j + 1; k < rects.length; k++) {
      if (intersects(box, rects[k]))
        occluders.push({ x: rects[k].x - box.x, y: rects[k].y - box.y, w: rects[k].w, h: rects[k].h })
    }
    frames.push({
      address: client.address,
      title: String(client.title || ""),
      active: Number(client.focusHistoryID) === 0,
      x: rect.x,
      y: rect.y,
      w: rect.w,
      h: rect.h,
      z: j,
      occluders: occluders,
    })
  }
  return frames
}

if (typeof module !== "undefined") {
  module.exports = {
    geometryKey: geometryKey,
    trackMotion: trackMotion,
    stackRank: stackRank,
    framesForMonitor: framesForMonitor,
    skipsFrame: skipsFrame,
  }
}
