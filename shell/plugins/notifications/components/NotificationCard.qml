// Notification card. Pure presentational — no service, Notification, or
// ListModel references. The popup container drives lifetime; the history
// panel drives static rendering. Both use the same component.

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../NotificationLogic.js" as NotificationLogic

BorderSurface {
  id: root

  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  // Nerd Font glyph rendered in the icon slot when no real icon is set.
  // Used by omarchy-notification-send so user-action toasts (`Silenced
  // notifications` etc.) show their bell/lock/etc. glyph without leaking
  // into the summary text.
  property string glyph: ""
  // NotificationUrgency: Low=0, Normal=1, Critical=2 (upstream).
  property int urgency: 1
  property double timestamp: 0
  property int cornerRadius: 0

  // System monospace font injected by the container.
  property string fontFamily: ""

  readonly property bool hovered: hoverTracker.hovered

  signal closeRequested()
  signal cardClicked()
  // Prefer per-notification media/avatar data, then fall back to the app icon.
  // The `check` flag avoids Qt's missing-texture placeholder for unknown names.
  readonly property string smallIconSource: image.length > 0 ? image : iconSource(appIcon)
  readonly property bool hasGlyph: glyph.length > 0
  readonly property bool compactGlyph: NotificationLogic.shouldRenderCompactGlyph(glyph, smallIconSource, singleLineToast)
  readonly property bool hasSmallIcon: smallIconSource.length > 0
  readonly property bool summaryStartsWithGlyph: NotificationLogic.summaryStartsWithGlyph(summary)
  readonly property bool singleLineToast: sanitizedBody.length === 0
  readonly property bool collapseRedundantIcon: singleLineToast && !hasGlyph && summaryStartsWithGlyph
  readonly property string sanitizedBody: sanitizeBody(body)
  readonly property string styledBody: NotificationLogic.styledBody(body, app, appIcon)

  readonly property color dimColor: Qt.darker(Color.notifications.text, 1.4)
  readonly property color bodyColor: Qt.darker(Color.notifications.text, 1.15)
  readonly property color accentColor: urgency === 2 ? Color.urgent : (urgency === 0 ? dimColor : Color.notifications.countdown)
  readonly property var cardBorderSpec: Border.surfaceSpec("notifications", "border", Color.notifications.border, Math.max(1, Style.space(2)))

  // Theme art for the card ([notifications] in shell.toml):
  //   caption        small line above the summary, e.g. "New message"
  //   caption-color  its colour (defaults to countdown)
  //   summary-color  the summary line (defaults to text)
  //   text-align     "center" centres caption, summary and body
  //   icon-frame     image drawn over the icon slot, icon-frame-outset px
  //                  larger than the icon on each side
  //   badge          image at the right end of the card, badge-width px
  readonly property string caption: String(Border.value("notifications", "caption"))
  readonly property color captionColor: Color.pick("notifications.caption-color", Color.notifications.countdown)
  readonly property color summaryColor: Color.pick("notifications.summary-color", Color.notifications.text)
  readonly property int textAlign: String(Border.value("notifications", "text-align")) === "center" ? Text.AlignHCenter : Text.AlignLeft
  readonly property string iconFrame: Border.image("notifications", "icon-frame")
  readonly property int iconFrameOutset: Math.round(Border.number("notifications", "icon-frame-outset", 0))
  readonly property string badge: Border.image("notifications", "badge")
  readonly property int badgeWidth: Math.round(Border.number("notifications", "badge-width", Style.space(48)))

  function sanitizeBody(s) {
    return NotificationLogic.sanitizeBody(s, app, appIcon)
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  implicitWidth: Style.space(380)
  // Add vertical border insets so mainColumn (inset by border on top/left/right)
  // doesn't push content under the bottom edge.
  implicitHeight: mainColumn.implicitHeight + borderTop + borderBottom
  radius: cornerRadius
  color: Color.notifications.background
  borderSpec: cardBorderSpec
  clip: true

  HoverHandler { id: hoverTracker }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.closeRequested()
      } else {
        root.cardClicked()
      }
    }
  }

  ColumnLayout {
    id: mainColumn
    // Inset by the card border so the content doesn't paint over the card's
    // outer border.
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.borderTop
    anchors.leftMargin: root.borderLeft
    anchors.rightMargin: root.borderRight
    spacing: 0

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      Layout.topMargin: Style.space(6)
      Layout.leftMargin: Style.space(12)
      Layout.rightMargin: Style.space(12)
      visible: root.caption.length > 0
      text: root.caption
      horizontalAlignment: Text.AlignHCenter
      color: root.captionColor
      font.family: Style.font.titleFamily
      font.pixelSize: Style.font.body
      style: Style.font.shadowStyle
      styleColor: Style.font.shadowColor
      elide: Text.ElideRight
    }

    // Text content.
    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(12)
      Layout.rightMargin: Style.space(12)
      Layout.topMargin: root.caption.length > 0 ? Style.space(2) : (root.singleLineToast ? Style.space(7) : Style.space(10))
      Layout.bottomMargin: root.singleLineToast ? Style.space(7) : Style.space(10)
      spacing: root.collapseRedundantIcon ? 0 : (root.compactGlyph ? Style.space(8) : Style.space(12))

      Item {
        id: smallIconSlot
        Layout.preferredWidth: visible ? Style.space(40) : 0
        Layout.preferredHeight: visible ? Style.space(40) : 0
        Layout.alignment: Qt.AlignVCenter
        // Hide the slot when the icon failed to resolve (themed-icon name
        // not in the user's icon theme) AND we don't have a glyph fallback
        // — prevents rendering Qt's pink broken-image placeholder.
        visible: !root.collapseRedundantIcon && !root.compactGlyph && (root.hasSmallIcon || root.hasGlyph) && (root.hasGlyph || smallIconImage.status !== Image.Error)

        Image {
          id: smallIconImage
          anchors.fill: parent
          source: root.smallIconSource
          sourceSize.width: smallIconSlot.width * Screen.devicePixelRatio
          sourceSize.height: smallIconSlot.height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          visible: !root.hasGlyph || smallIconImage.status === Image.Ready
        }

        Image {
          anchors.fill: parent
          anchors.margins: -root.iconFrameOutset
          visible: root.iconFrame !== ""
          source: visible ? root.iconFrame : ""
          fillMode: Image.Stretch
          smooth: true
          z: 1
        }

        // Glyph fallback (Nerd Font character) when no image icon is
        // available. Used by omarchy-notification-send's `-g` flag.
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: root.hasGlyph && smallIconImage.status !== Image.Ready
          text: root.glyph
          color: Color.notifications.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.alignment: Qt.AlignVCenter
        visible: root.compactGlyph
        text: root.glyph
        color: Color.notifications.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(2)

        Text {
          // The spec defines the summary as a single line of plain text, so
          // AutoText could only ever promote a hostile string to rich text.
          // The body below is StyledText on purpose — see Service.qml's
          // bodyMarkupSupported — and is stripped in NotificationLogic.
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: root.summary.length > 0
          text: root.summary
          horizontalAlignment: root.textAlign
          font.family: Style.textFamilyOr("Liberation Sans")
          color: root.summaryColor
          style: Style.font.shadowStyle
          styleColor: Style.font.shadowColor
          font.pixelSize: Style.themeTextFamily.length > 0 ? Style.font.heading : Style.font.title
          font.bold: Style.themeTextFamily.length === 0
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 2
        }

        Text {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          visible: root.sanitizedBody.length > 0
          text: root.styledBody
          textFormat: Text.StyledText
          horizontalAlignment: root.textAlign
          font.family: Style.textFamilyOr("Liberation Sans")
          color: root.bodyColor
          style: Style.font.shadowStyle
          styleColor: Style.font.shadowColor
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 3
        }
      }

      Image {
        Layout.preferredWidth: visible ? root.badgeWidth : 0
        Layout.preferredHeight: visible ? root.badgeWidth * (implicitWidth > 0 ? implicitHeight / implicitWidth : 1) : 0
        Layout.alignment: Qt.AlignVCenter
        visible: root.badge !== ""
        source: visible ? root.badge : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
      }
    }
  }

}
