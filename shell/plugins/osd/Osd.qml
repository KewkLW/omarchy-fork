import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "OsdModel.js" as OsdModel

Item {
  id: root

  property bool opened: false
  property string icon: ""
  property string message: ""
  property string iconKey: ""
  property int value: 0
  property int maxValue: 100
  property bool hasProgress: true
  property int duration: 1200

  readonly property bool mediaOsd: iconKey.indexOf("media") === 0 || iconKey.indexOf("player") === 0

  // The card is built out of measured columns instead of fixed widths, so it
  // keeps exactly `pad` between border and content on every side whatever
  // glyph or message it carries. Messages grow with their text up to
  // `maxMessageWidth` and elide beyond it.
  readonly property int pad: Style.space(16)
  readonly property int gap: Style.space(16)
  // A glyph next to a message reads airier than it measures: the icon outline
  // and the letterforms both fall away from their ink extremes, so the space
  // between them opens up well past the nominal gap. Text takes two thirds of
  // it; the progress bar's hard edge keeps the full gap.
  readonly property int messageGap: Math.round(root.gap * 2 / 3)
  // [osd] in shell.toml styles this card on its own; a theme without the
  // section keeps the [popups] look. The progress bar can be theme art:
  //   progress-fill    image stretched over the filled part (else accent)
  //   progress-track   colour of the empty part (+ progress-track-alpha)
  //   progress-spark   image drawn at the fill edge
  //   progress-frame   image frame around the bar; takes the usual frame
  //                    keys (progress-frame-slice, -width, -inset, -mode)
  //   progress-width / progress-height   bar size in px
  //   label-on-bar     true draws the readout centred on the bar
  readonly property string section: Object.keys(Color.shellValues).some(function(k) { return k.indexOf("osd.") === 0 }) ? "osd" : "popups"
  readonly property bool themedSection: root.section === "osd"
  readonly property color cardColor: root.themedSection
    ? Color.composed("osd.background", "osd.background-alpha", Color.background, 0.97)
    : Util.alpha(Color.background, 0.97)
  readonly property color textColor: Color.pick(root.section + ".text", Color.popups.text)
  readonly property string fillImage: Border.image("osd", "progress-fill")
  readonly property string sparkImage: Border.image("osd", "progress-spark")
  readonly property var barFrameSpec: Border.frameOnlySpec("osd", "progress-frame")
  readonly property bool labelOnBar: Style.boolToken(Border.value("osd", "label-on-bar"), false)
  readonly property int barHeight: Math.round(Border.number("osd", "progress-height", Math.max(Style.space(6), Style.spacing.sm)))
  readonly property int barWidth: Math.round(Border.number("osd", "progress-width", Style.space(142)))
  readonly property int barBoxWidth: root.barWidth + Border.left(root.barFrameSpec) + Border.right(root.barFrameSpec)
  readonly property int barBoxHeight: root.barHeight + Border.top(root.barFrameSpec) + Border.bottom(root.barFrameSpec)
  readonly property int maxMessageWidth: root.mediaOsd ? Style.space(325) : Style.space(190)

  // Nerd Font glyphs draw well outside their monospace cell, so the icon
  // column is measured by ink rather than by advance width. Progress OSDs pin
  // it to the widest glyph the model can return, so the bar doesn't shift when
  // volume crosses an icon threshold.
  readonly property int iconInkWidth: Math.ceil(iconMetrics.tightBoundingRect.width)
  readonly property int iconWidth: root.hasProgress
    ? Math.max(root.iconInkWidth, Math.ceil(widestIconMetrics.tightBoundingRect.width))
    : root.iconInkWidth
  // Same idea for the readout: it is as wide as the longest percentage so the
  // digits don't jitter between 9% and 100%.
  readonly property int valueWidth: Math.ceil(Math.max(valueMetrics.advanceWidth, messageMetrics.advanceWidth))
  readonly property int messageWidth: Math.min(Math.ceil(messageMetrics.advanceWidth), root.maxMessageWidth)
  readonly property int contentWidth: root.hasProgress
    ? root.iconWidth + root.gap + root.barBoxWidth + (root.labelOnBar ? 0 : root.gap + root.valueWidth)
    : (root.message === "" ? root.iconWidth : root.iconWidth + root.messageGap + root.messageWidth)

  function iconFor(name, percent) {
    return OsdModel.iconFor(name, percent)
  }

  function show(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration) {
    var next = OsdModel.stateForShow(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration)
    // Update before opening so a fresh OSD starts at its new value; only
    // subsequent updates while it remains open animate the progress bar.
    iconKey = next.iconKey
    maxValue = next.maxValue
    hasProgress = next.hasProgress
    value = next.value
    message = next.message
    icon = next.icon
    duration = next.duration
    opened = true
    if (duration > 0) hideTimer.restart()
    else hideTimer.stop()
  }

  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      show(p.icon || "", p.message || "", p.value === undefined ? "" : String(p.value), p.max === undefined ? "100" : String(p.max), p.progressText || "", p.duration === undefined ? "1200" : String(p.duration))
    } catch (e) {}
  }

  function close() { opened = false }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: root.opened = false
  }

  TextMetrics {
    id: messageMetrics
    font.family: Style.font.textFamily
    font.bold: true
    font.pixelSize: Style.font.title
    text: root.message
  }

  TextMetrics {
    id: valueMetrics
    font: messageMetrics.font
    text: "100%"
  }

  TextMetrics {
    id: iconMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.displayLarge
    text: root.icon
  }

  TextMetrics {
    id: widestIconMetrics
    font: iconMetrics.font
    text: OsdModel.widestIcon
  }

  IpcHandler {
    target: "osd"
    function show(payloadJson: string): string {
      root.open(payloadJson)
      return "ok"
    }
    function close(): string { root.close(); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Visual-only surface: keep the layer-shell input region empty so the OSD
    // never blocks clicks to the desktop below it.
    mask: Region {}

    BorderSurface {
      id: card
      width: card.borderLeft + root.pad + root.contentWidth + root.pad + card.borderRight
      height: card.borderTop + root.pad + Math.max(Style.font.displayLarge, root.hasProgress ? root.barBoxHeight : 0) + root.pad + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: root.cardColor
      borderSpec: Border.surfaceSpec(root.section, "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0

      Row {
        anchors.fill: parent
        anchors.topMargin: card.borderTop + root.pad
        anchors.rightMargin: card.borderRight + root.pad
        anchors.bottomMargin: card.borderBottom + root.pad
        anchors.leftMargin: card.borderLeft + root.pad
        spacing: root.hasProgress ? root.gap : root.messageGap
        Item {
          width: root.iconWidth
          height: parent.height
          Text {
            textFormat: Text.PlainText
            // Sit the glyph's ink flush in the column, centered when the
            // column is wider than this particular glyph.
            x: Math.round((root.iconWidth - root.iconInkWidth) / 2 - iconMetrics.tightBoundingRect.x)
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            font: iconMetrics.font
            color: root.textColor
            style: Style.font.shadowStyle
            styleColor: Style.font.shadowColor
          }
        }
        BorderSurface {
          id: barBox
          visible: root.hasProgress
          width: root.barBoxWidth
          height: root.barBoxHeight
          anchors.verticalCenter: parent.verticalCenter
          color: "transparent"
          borderSpec: root.barFrameSpec || Border.none()

          Rectangle {
            id: track
            x: barBox.borderLeft
            y: barBox.borderTop
            width: root.barWidth
            height: root.barHeight
            color: Color.composed("osd.progress-track", "osd.progress-track-alpha", root.textColor, 0.45)

            Item {
              id: fill
              height: parent.height
              width: parent.width * (root.hasProgress ? Math.max(0, Math.min(1, root.value / root.maxValue)) : 0)
              clip: true

              Rectangle {
                anchors.fill: parent
                visible: root.fillImage === ""
                color: Color.accent
              }

              Image {
                width: track.width
                height: track.height
                visible: root.fillImage !== ""
                source: visible ? root.fillImage : ""
                fillMode: Image.Stretch
                smooth: true
              }

              Behavior on width {
                enabled: root.opened
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
              }
            }

            Image {
              visible: root.sparkImage !== "" && fill.width > 0 && fill.width < track.width
              source: visible ? root.sparkImage : ""
              height: track.height * 2.2
              width: height * 0.6
              x: fill.width - width / 2
              anchors.verticalCenter: parent.verticalCenter
              smooth: true
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.labelOnBar && root.message !== ""
            anchors.centerIn: track
            width: track.width - Style.space(8)
            horizontalAlignment: Text.AlignHCenter
            text: root.message
            font: messageMetrics.font
            color: root.textColor
            style: Style.font.shadowStyle
            styleColor: Style.font.shadowColor
            elide: Text.ElideRight
          }
        }
        Text {
          textFormat: Text.PlainText
          visible: root.message !== "" && !(root.hasProgress && root.labelOnBar)
          width: root.hasProgress ? root.valueWidth : root.messageWidth
          // The readout hugs the card edge so a short percentage doesn't leave
          // a hole in the padding; the slack lands in the gap after the bar.
          horizontalAlignment: root.hasProgress ? Text.AlignRight : Text.AlignLeft
          anchors.verticalCenter: parent.verticalCenter
          text: root.message
          font: messageMetrics.font
          color: root.textColor
          style: Style.font.shadowStyle
          styleColor: Style.font.shadowColor
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }
}
