#!/bin/bash
source "$(dirname "$0")/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const model = requireFromRoot('shell/plugins/window-frames/WindowFramesModel.js')

function client(address, overrides) {
  return Object.assign({
    address: address,
    title: address,
    mapped: true,
    hidden: false,
    visible: true,
    at: [0, 0],
    size: [100, 100],
    workspace: { id: 1 },
    floating: false,
    pinned: false,
    fullscreen: 0,
    monitor: 0,
    focusHistoryID: 0,
    tags: [],
  }, overrides || {})
}

const monitor = { id: 0, name: 'DP-1', x: 1000, y: 0, activeWorkspace: { id: 1 }, specialWorkspace: { id: 0 } }
const reach = { left: 10, top: 30, right: 10, bottom: 10 }

function addresses(frames) {
  return frames.map(frame => frame.address)
}

// Visibility
{
  const clients = [
    client('a', { at: [1020, 40] }),
    client('b', { workspace: { id: 2 } }),
    client('c', { monitor: 1 }),
    client('d', { hidden: true }),
    client('e', { visible: false }),
    client('f', { mapped: false }),
    client('g', { workspace: { id: 2 }, pinned: true, floating: true }),
  ]
  const frames = model.framesForMonitor(clients, monitor, { reach: reach })
  assertDeepEqual(addresses(frames), ['a', 'g'], 'frames only windows shown on the monitor, including pinned ones')
  assertEqual(frames[0].x, 20, 'frame x is relative to the monitor')
  assertEqual(frames[0].y, 40, 'frame y is relative to the monitor')
}

// Special workspace replaces the regular one on its monitor
{
  const special = Object.assign({}, monitor, { specialWorkspace: { id: -98 } })
  const clients = [client('a'), client('s', { workspace: { id: -98 } })]
  assertDeepEqual(addresses(model.framesForMonitor(clients, special, { reach: reach })), ['s'], 'an open special workspace frames only its own windows')
}

// Fullscreen hides every frame on that workspace
{
  const clients = [client('a', { fullscreen: 2 }), client('b'), client('c', { workspace: { id: 2 }, pinned: true })]
  assertDeepEqual(addresses(model.framesForMonitor(clients, monitor, { reach: reach })), ['c'], 'a fullscreen window hides the frames on its workspace')
  const maximized = [client('a', { fullscreen: 1 }), client('b')]
  assertDeepEqual(addresses(model.framesForMonitor(maximized, monitor, { reach: reach })), [], 'a maximized window hides them too')
}

// Stacking order and occluders
{
  const clients = [
    client('float-old', { floating: true, at: [1050, 50], size: [100, 100], focusHistoryID: 2 }),
    client('tiled', { at: [1000, 0], size: [300, 300], focusHistoryID: 0 }),
    client('float-new', { floating: true, at: [1100, 100], size: [100, 100], focusHistoryID: 1 }),
  ]
  const frames = model.framesForMonitor(clients, monitor, { reach: reach })
  assertDeepEqual(addresses(frames), ['tiled', 'float-old', 'float-new'], 'tiled below floating, most recently focused floating on top')
  assertEqual(frames[0].occluders.length, 2, 'both floating windows cut into the tiled frame')
  assertDeepEqual(frames[0].occluders[0], { x: 60, y: 80, w: 100, h: 100 }, 'occluders are in frame-box coordinates')
  assertEqual(frames[2].occluders.length, 0, 'nothing covers the top window')
  assertDeepEqual(frames.map(frame => frame.active), [true, false, false], 'the focused window is marked active')
}

// Moving windows and skipped windows lose their frame
{
  const clients = [
    client('a'),
    client('b', { tags: ['no-window-frame*'] }),
    client('menu', { floating: true, title: '' }),
    client('untitled-tiled', { title: '' }),
  ]
  const frames = model.framesForMonitor(clients, monitor, { reach: reach, moving: { a: true } })
  assertDeepEqual(addresses(frames), ['untitled-tiled'], 'moving, opted-out and untitled floating windows get no frame')
}

// Motion tracking
{
  const first = model.trackMotion({}, [client('a')], 1000, 450)
  assert(first.moving.a, 'a newly seen window waits for its open animation')
  const still = model.trackMotion(first.state, [client('a')], 1500, 450)
  assert(!still.anyMoving, 'a window that held still for the settle time is settled')
  const moved = model.trackMotion(still.state, [client('a', { at: [5, 0] })], 1600, 450)
  assert(moved.moving.a && moved.anyMoving, 'a geometry change marks the window as moving')
  const settled = model.trackMotion(moved.state, [client('a', { at: [5, 0] })], 2100, 450)
  assert(!settled.anyMoving, 'it settles once the new geometry holds')
  assertDeepEqual(Object.keys(model.trackMotion(settled.state, [], 2200, 450).state), [], 'closed windows are forgotten')
}

// No theme token, no surfaces
{
  const qml = fs.readFileSync(path.join(root, 'shell/plugins/window-frames/WindowFrames.qml'), 'utf8')
  assert(qml.includes('model: root.enabled ? Quickshell.screens : []'), 'surfaces exist only when the theme sets [windows] frame')
  assert(qml.includes('mask: Region {}'), 'the overlay takes no input')
  assert(qml.includes('WlrKeyboardFocus.None'), 'the overlay takes no keyboard focus')
}
JS
