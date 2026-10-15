import QtQuick
import Quickshell
import "plugins/agents" as Agents

// The agent stats window, run as its own Quickshell process by
// omarchy-launch-agent-stats with QS_APP_ID=org.omarchy.agent-stats: an app
// window the compositor tiles, floats, moves and closes like any other, not a
// layer-shell popup of the shell. It lives here, beside shell.qml, so the
// qs.Commons and qs.Ui imports resolve against the same tree and the window
// themes itself exactly as the bar panel does.
ShellRoot {
  FloatingWindow {
    id: window
    title: "Agent stats"
    color: stats.surface
    implicitWidth: 1180
    implicitHeight: 860
    minimumSize: Qt.size(640, 480)
    visible: true

    // Closing the window ends the process; nothing else of it is on screen.
    onVisibleChanged: if (!visible) Qt.quit()

    Agents.Stats {
      id: stats
      anchors.fill: parent
      onCloseRequested: Qt.quit()
    }
  }
}
