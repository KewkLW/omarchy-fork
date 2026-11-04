import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "WindowFramesModel.js" as Model

// Theme image frames around Hyprland windows. A theme opts in with a
// [windows] section in shell.toml:
//   frame              = "frames/dialog.png"  9-slice drawn around each window
//   frame-active       = "frames/gold.png"    optional frame for the focused window
//   frame-slice        = 32                   source px cut from each edge
//   frame-width        = 32                   rendered edge thickness
//   frame-inset        = 14                   px the frame reaches outside the window
//   title-image        = "frames/title.png"   optional plate above the window
//   title-image-slice  = 24                   source px kept unstretched at each end
//   title-image-height = 30
//   title-overlap      = 0                    px the plate reaches down over the window
//   title-padding      = 20                   text padding inside the plate
//   title-text         = "#ffd100"
//   title-size         = 13
// Without frame the overlay creates no surfaces. Frames sit outside the
// window, on a click-through layer above windows, and are cut out wherever a
// window stacked higher covers them. Hyprland reports no event for drags and
// resizes, so geometry is polled; a window that moved hides its frame until
// it holds still.
Item {
  id: root

  property var shell: null

  readonly property var frameSpec: Border.frameSpec("windows")
  readonly property bool enabled: frameSpec !== null
  readonly property real frameScale: enabled && frameSpec.slice > 0 ? frameSpec.width / frameSpec.slice : 1
  readonly property int inset: enabled ? Border.number("windows", "frame-inset", frameSpec.width) : 0
  readonly property string activeSource: Border.themeFile(Border.value("windows", "frame-active"))

  readonly property string plateSource: Border.themeFile(Border.value("windows", "title-image"))
  readonly property bool hasPlate: enabled && plateSource.length > 0
  readonly property int plateSlice: Border.number("windows", "title-image-slice", 16)
  readonly property int plateHeight: Border.number("windows", "title-image-height", 28)
  readonly property int plateOverlap: Border.number("windows", "title-overlap", 0)
  readonly property int platePadding: Border.number("windows", "title-padding", 20)
  readonly property color titleColor: Color.flatColor(Border.value("windows", "title-text"), Color.foreground)
  readonly property int titleSize: Border.number("windows", "title-size", Style.font.body)

  readonly property var reach: ({
    left: inset,
    right: inset,
    bottom: inset,
    top: Math.max(inset, hasPlate ? plateHeight - plateOverlap : 0),
  })

  // Window geometry settles this long after its last change before the frame
  // returns. Covers Omarchy's window animations (~380 ms).
  readonly property int settleMs: 450
  readonly property int idlePollMs: 1000
  readonly property int movingPollMs: 80
  // Drags and resizes almost always move the focused window, so it alone is
  // probed often; that answer is a fraction of the full client list.
  readonly property int activeProbeMs: 100

  property string activeKey: ""
  property string probeBuffer: ""

  property var motion: ({})
  property bool anyMoving: false
  property var framesByMonitor: ({})
  property string framesKey: ""

  function refresh() {
    if (!enabled) return
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
  }

  function clients() {
    var list = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject
      if (ipc && ipc.address) list.push(ipc)
    }
    return list
  }

  function recompute() {
    if (!enabled) {
      framesByMonitor = ({})
      framesKey = ""
      return
    }
    var list = clients()
    var tracked = Model.trackMotion(motion, list, Date.now(), settleMs)
    motion = tracked.state
    anyMoving = tracked.anyMoving

    var byMonitor = {}
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      var mon = monitors[i].lastIpcObject
      if (!mon || mon.name === undefined) continue
      byMonitor[mon.name] = Model.framesForMonitor(list, mon, { reach: reach, moving: tracked.moving })
    }
    var key = JSON.stringify(byMonitor)
    if (key === framesKey) return
    framesKey = key
    framesByMonitor = byMonitor
  }

  function probeAnswered(text) {
    var address = text.match(/"address":\s*"([^"]*)"/)
    var at = text.match(/"at":\s*\[\s*(-?\d+),\s*(-?\d+)\s*\]/)
    var size = text.match(/"size":\s*\[\s*(-?\d+),\s*(-?\d+)\s*\]/)
    if (!address || !at || !size) return
    var key = address[1] + " " + at[1] + "," + at[2] + "," + size[1] + "," + size[2]
    var before = activeKey
    activeKey = key
    if (before.length > 0 && key !== before && before.split(" ")[0] === address[1]) refresh()
  }

  function framesFor(monitorName) {
    return framesByMonitor[monitorName] || []
  }

  onEnabledChanged: {
    motion = ({})
    refresh()
    recompute()
  }
  onReachChanged: recompute()

  Component.onCompleted: refresh()

  Connections {
    target: Hyprland
    enabled: root.enabled
    function onRawEvent(event) { refreshDebounce.restart() }
  }

  // Coalesces bursts of Hyprland events into one refresh.
  Timer {
    id: refreshDebounce
    interval: 30
    onTriggered: root.refresh()
  }

  Timer {
    running: root.enabled
    repeat: true
    interval: root.anyMoving ? root.movingPollMs : root.idlePollMs
    onTriggered: {
      root.refresh()
      // A settled window has nothing new to report, so re-check the clock.
      if (root.anyMoving) Qt.callLater(root.recompute)
    }
  }

  Timer {
    running: root.enabled && !root.anyMoving
    repeat: true
    interval: root.activeProbeMs
    onTriggered: if (!activeProbe.connected) activeProbe.connected = true
  }

  Socket {
    id: activeProbe
    path: Hyprland.requestSocketPath
    parser: SplitParser {
      onRead: data => {
        root.probeBuffer += data + "\n"
        // The line closing the object ends the part we want; the submap
        // answer (a bare quoted string) ends any other reply. Hang up before
        // Hyprland does: a peer close is logged as a socket error.
        if (data === "}" || data === "{}" || /^"[^"]*"$/.test(data)) {
          activeProbe.connected = false
          root.probeAnswered(root.probeBuffer)
        }
      }
    }
    onConnectedChanged: {
      if (!connected) return
      root.probeBuffer = ""
      // Batched so the reply ends its object with a newline.
      write("[[BATCH]]j/activewindow;j/submap")
      flush()
    }
  }

  // Each refresh updates lastIpcObject on every toplevel and monitor;
  // callLater folds those into one recompute.
  Instantiator {
    model: root.enabled ? Hyprland.toplevels : null
    delegate: Connections {
      required property var modelData
      target: modelData
      function onLastIpcObjectChanged() { Qt.callLater(root.recompute) }
    }
  }

  Instantiator {
    model: root.enabled ? Hyprland.monitors : null
    delegate: Connections {
      required property var modelData
      target: modelData
      function onLastIpcObjectChanged() { Qt.callLater(root.recompute) }
    }
  }

  Variants {
    model: root.enabled ? Quickshell.screens : []

    PanelWindow {
      id: panel
      required property var modelData

      readonly property string monitorName: modelData ? modelData.name : ""
      readonly property var frames: root.framesFor(monitorName)

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      WlrLayershell.namespace: "omarchy-window-frames"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }

      Repeater {
        model: ScriptModel {
          values: panel.frames.map(function(frame) { return frame.address })
        }

        delegate: Item {
          id: frameItem
          required property string modelData

          readonly property var frame: {
            var list = panel.frames
            for (var i = 0; i < list.length; i++)
              if (list[i].address === modelData) return list[i]
            return null
          }
          readonly property var occluders: frame ? frame.occluders : []

          visible: frame !== null
          x: frame ? frame.x - root.reach.left : 0
          y: frame ? frame.y - root.reach.top : 0
          z: frame ? frame.z : 0
          width: frame ? frame.w + root.reach.left + root.reach.right : 0
          height: frame ? frame.h + root.reach.top + root.reach.bottom : 0
          opacity: 0

          Component.onCompleted: fadeIn.start()
          NumberAnimation on opacity {
            id: fadeIn
            running: false
            to: 1
            duration: 140
            easing.type: Easing.OutCubic
          }

          // Cut the frame out where a higher window covers it.
          layer.enabled: occluders.length > 0
          layer.effect: MultiEffect {
            maskEnabled: true
            maskInverted: true
            maskSource: occluderMask
          }

          Item {
            id: occluderMask
            anchors.fill: parent
            visible: false
            layer.enabled: frameItem.occluders.length > 0

            Repeater {
              model: frameItem.occluders
              delegate: Rectangle {
                required property var modelData
                x: modelData.x
                y: modelData.y
                width: modelData.w
                height: modelData.h
                color: "white"
              }
            }
          }

          // The 9-slice ring, drawn at source size and scaled so its edges
          // render frame-width px thick.
          BorderImage {
            x: root.reach.left - root.inset
            y: root.reach.top - root.inset
            width: (frameItem.width - root.reach.left - root.reach.right + 2 * root.inset) / root.frameScale
            height: (frameItem.height - root.reach.top - root.reach.bottom + 2 * root.inset) / root.frameScale
            scale: root.frameScale
            transformOrigin: Item.TopLeft
            source: !root.frameSpec ? "" : (frameItem.frame && frameItem.frame.active && root.activeSource.length > 0 ? root.activeSource : root.frameSpec.source)
            border.left: root.frameSpec ? root.frameSpec.slice : 0
            border.right: root.frameSpec ? root.frameSpec.slice : 0
            border.top: root.frameSpec ? root.frameSpec.slice : 0
            border.bottom: root.frameSpec ? root.frameSpec.slice : 0
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
            smooth: true
            cache: true
          }

          Item {
            id: plate
            readonly property real windowWidth: frameItem.width - root.reach.left - root.reach.right
            readonly property real plateScale: plateImage.sourceSize.height > 0 ? root.plateHeight / plateImage.sourceSize.height : 1
            readonly property real wanted: Math.ceil(titleText.implicitWidth) + 2 + 2 * root.platePadding + 2 * root.plateSlice * plateScale

            visible: root.hasPlate && frameItem.frame !== null && frameItem.frame.title.length > 0 && windowWidth > 4 * root.plateSlice * plateScale
            width: Math.min(wanted, windowWidth - 2 * root.inset)
            height: root.plateHeight
            x: root.reach.left + (windowWidth - width) / 2
            y: root.reach.top + root.plateOverlap - height

            BorderImage {
              id: plateImage
              width: plate.width / plate.plateScale
              height: sourceSize.height
              scale: plate.plateScale
              transformOrigin: Item.TopLeft
              source: root.hasPlate ? root.plateSource : ""
              border.left: root.plateSlice
              border.right: root.plateSlice
              horizontalTileMode: BorderImage.Stretch
              verticalTileMode: BorderImage.Stretch
              smooth: true
              cache: true
            }

            Text {
              id: titleText
              anchors.centerIn: parent
              width: Math.min(implicitWidth, plate.width - 2 * root.platePadding - 2 * root.plateSlice * plate.plateScale)
              text: frameItem.frame ? frameItem.frame.title : ""
              color: root.titleColor
              font.family: Style.font.titleFamily
              font.pixelSize: root.titleSize
              style: Style.font.shadowStyle
              styleColor: Style.font.shadowColor
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
