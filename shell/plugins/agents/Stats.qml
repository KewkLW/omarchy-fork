import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Format.js" as Format

// The agent stats window's content: what the Agents panel leaves out. Every
// number comes from one call, `omarchy-agent-otel history --range <r>`, which
// reads the daily rollups, the limit history and the live summary; this file
// only lays them out. Costs are Claude Code's cost_usd, the API list price
// equivalent, not what a subscription bills.
FocusScope {
  id: root
  focus: true

  signal closeRequested()

  property string range: "30d"
  // What the bounty and agent views count: API-equivalent cost or tokens.
  property string metric: "costUsd"
  property string selectedAccountId: ""
  // Agents picked in the table: a click keeps one, Ctrl+click adds or drops
  // one, and the agent chart draws every picked one side by side.
  property var selectedAgents: []
  property string projectFilter: ""
  property var report: null
  property string errorText: ""
  property double nowMs: Date.now()

  // The same palette the panel draws with: theme foreground on the popup
  // surface, the panel's dim and track, urgent only for what needs a look.
  readonly property color foreground: Color.popups.text
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 1)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property color grid: alpha(foreground, 0.09)
  readonly property string fontFamily: Style.font.family

  readonly property var accounts: report && Array.isArray(report.accounts) ? report.accounts : []
  readonly property int accountIndex: {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].id === selectedAccountId) return i
    return defaultAccountIndex()
  }
  readonly property var account: accounts.length > 0 ? accounts[accountIndex] : null
  readonly property var days: report && Array.isArray(report.days) ? report.days : []

  // Series by model, ranked by cost over the range. The first three keep
  // their own shade and the rest pool into Other, so a chart never needs
  // more than four colours and a model keeps its colour across charts.
  readonly property var modelSeries: buildModelSeries(account)
  readonly property var costSeries: daySeries(account, "costUsd")
  readonly property var tokenSeries: daySeries(account, "tokens")
  readonly property var limitSeries: buildLimitSeries(account)
  readonly property var live: account && Array.isArray(account.live) ? account.live : []
  readonly property bool hasTelemetry: !!account && account.hasTelemetry === true
  readonly property var agents: account && Array.isArray(account.byAgent) ? account.byAgent : []
  readonly property var projects: account && Array.isArray(account.byProject) ? account.byProject : []
  readonly property var shownAgents: {
    var out = []
    for (var i = 0; i < agents.length; i++)
      if (projectFilter === "" || String(agents[i].project || "") === projectFilter) out.push(agents[i])
    out.sort(function(a, b) { return Number(b[metric] || 0) - Number(a[metric] || 0) })
    return out
  }
  // The chart's agents: the picked ones, or the three biggest when none is.
  readonly property var chartedAgents: {
    var out = []
    if (selectedAgents.length > 0) {
      for (var i = 0; i < agents.length; i++)
        if (selectedAgents.indexOf(String(agents[i].agent)) >= 0) out.push(agents[i])
      return out
    }
    return shownAgents.slice(0, 3)
  }
  readonly property var agentSeries: buildAgentSeries(chartedAgents, metric)

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function css(c) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + c.a.toFixed(3) + ")"
  }

  function luminance(c) {
    function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
  }

  function contrast(a, b) {
    var la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  // One hue, stepped: the theme's foreground for the biggest model, its
  // accent for the second when the theme has a distinct, readable one,
  // then lighter steps of the foreground. Theme-derived, so it flips with
  // light and dark variants, and never a rainbow.
  readonly property bool accentUsable: contrast(accent, surface) >= 2.2
    && Math.abs(luminance(accent) - luminance(foreground)) + Math.abs(accent.r - foreground.r) + Math.abs(accent.b - foreground.b) > 0.18
  function seriesColor(index) {
    if (index === 0) return foreground
    if (index === 1) return accentUsable ? accent : alpha(foreground, 0.58)
    if (index === 2) return alpha(foreground, accentUsable ? 0.5 : 0.36)
    return alpha(foreground, 0.3)
  }

  function metricIsMoney() { return metric === "costUsd" }
  function metricWord() { return metricIsMoney() ? "cost" : "tokens" }
  function formatMetric(value) { return metricIsMoney() ? formatMoney(value) : Format.formatTokenCount(Number(value || 0)) }
  function formatMetricShort(value) { return metricIsMoney() ? formatMoneyShort(value) : Format.formatTokenCount(Number(value || 0)).replace(".0", "") }
  function toggleMetric() { metric = metricIsMoney() ? "tokens" : "costUsd" }

  // Colours for agents drawn together: the two theme colours first, then
  // hues stepped around the wheel from the accent so each line stays apart.
  function agentColor(index) {
    if (index === 0) return foreground
    if (index === 1) return accentUsable ? accent : alpha(foreground, 0.6)
    var base = accentUsable ? accent : foreground
    var hue = (base.hslHue < 0 ? 0.6 : base.hslHue) + 0.17 * (index - 1)
    return Qt.hsla(hue - Math.floor(hue), 0.55, luminance(surface) > 0.5 ? 0.42 : 0.66, 1)
  }

  function buildAgentSeries(list, field) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      var perDay = Array.isArray(a.perDay) ? a.perDay : []
      var values = []
      for (var d = 0; d < perDay.length; d++) values.push(Number(perDay[d][field] || 0))
      out.push({ key: String(a.agent), name: agentTitle(a), color: agentColor(i), values: values })
    }
    return out
  }

  function agentTitle(a) {
    if (!a) return ""
    var name = String(a.name || a.agent || "")
    return a.project ? name + " · " + a.project : name
  }

  function selectAgent(key, extend) {
    key = String(key)
    var next = extend ? selectedAgents.slice() : []
    var at = next.indexOf(key)
    if (at >= 0) next.splice(at, 1)
    else if (extend || selectedAgents.indexOf(key) < 0 || selectedAgents.length > 1) next.push(key)
    selectedAgents = next
  }

  function clearAgents() { selectedAgents = [] }

  function formatMoney(value) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return "$" + amount.toFixed(2)
  }

  function formatMoneyShort(value) {
    var amount = Number(value)
    if (amount >= 1000) return "$" + (amount / 1000).toFixed(amount >= 10000 ? 0 : 1) + "K"
    if (amount >= 10 || amount === 0) return "$" + Math.round(amount)
    return "$" + amount.toFixed(amount >= 1 ? 1 : 2)
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function dayDate(day) {
    var parsed = new Date(String(day || "") + "T00:00:00")
    return isNaN(parsed.getTime()) ? null : parsed
  }

  function shortDay(day) {
    var d = dayDate(day)
    return d ? (d.getMonth() + 1) + "/" + d.getDate() : String(day || "")
  }

  function longDay(day) {
    var d = dayDate(day)
    if (!d) return String(day || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()] + " " + (d.getMonth() + 1) + "/" + d.getDate()
  }

  function rangeLabel() {
    if (range === "7d") return "7 days"
    if (range === "30d") return "30 days"
    return days.length > 0 ? "all " + days.length + " days" : "all time"
  }

  function defaultAccountIndex() {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].hasTelemetry) return i
    return 0
  }

  function selectAccount(index) {
    if (accounts.length === 0) return
    var wrapped = ((index % accounts.length) + accounts.length) % accounts.length
    selectedAccountId = accounts[wrapped].id
  }

  function setRange(value) {
    if (value === range) return
    range = value
    refresh()
  }

  // ------------------------------------------------------------- series

  function buildModelSeries(acc) {
    var names = acc && Array.isArray(acc.models) ? acc.models : []
    var out = []
    for (var i = 0; i < names.length && i < 3; i++)
      out.push({ key: names[i], name: Format.friendlyModelName(names[i]), color: seriesColor(i), others: [] })
    if (names.length > 3)
      out.push({ key: "", name: "Other", color: seriesColor(3), others: names.slice(3) })
    return out
  }

  function daySeries(acc, field) {
    var perDay = acc && Array.isArray(acc.perDay) ? acc.perDay : []
    var out = []
    for (var s = 0; s < modelSeries.length; s++) {
      var series = modelSeries[s]
      var values = []
      for (var i = 0; i < perDay.length; i++) {
        var byModel = perDay[i].byModel || {}
        var keys = series.key !== "" ? [series.key] : series.others
        var sum = 0
        for (var k = 0; k < keys.length; k++) sum += Number((byModel[keys[k]] || {})[field] || 0)
        values.push(sum)
      }
      out.push({ name: series.name, color: series.color, values: values })
    }
    return out
  }

  function buildLimitSeries(acc) {
    var points = acc && Array.isArray(acc.limits) ? acc.limits : []
    var weekly = [], session = [], models = {}, modelOrder = []
    for (var i = 0; i < points.length; i++) {
      var p = points[i]
      var t = Number(p.ts) * 1000
      if (p.weekly !== undefined) weekly.push({ t: t, v: Number(p.weekly) })
      if (p.session !== undefined) session.push({ t: t, v: Number(p.session) })
      var m = p.models || {}
      for (var name in m) {
        if (!models[name]) { models[name] = []; modelOrder.push(name) }
        models[name].push({ t: t, v: Number(m[name]) })
      }
    }
    var out = []
    if (weekly.length > 0) out.push({ name: "Weekly", color: foreground, width: 2, dash: false, points: weekly })
    for (var j = 0; j < modelOrder.length; j++)
      out.push({ name: modelOrder[j], color: accentUsable ? accent : alpha(foreground, 0.7), width: 1.5, dash: true, points: models[modelOrder[j]] })
    // The 5-hour window swings all day; drawn as a faint area behind the
    // weekly lines it gives the rhythm without drowning them.
    if (session.length > 0) out.push({ name: "Session (5-hour)", color: alpha(foreground, 0.22), width: 1, dash: false, fill: true, points: session })
    return out
  }

  function sessionTitle(s) {
    if (!s) return ""
    var who = String(s.agent || s.slot || "")
    var where = String(s.project || "")
    if (String(s.bounty || "") !== "") {
      var title = who !== "" ? who : "Session " + String(s.session || "")
      if (where !== "") title += " · " + where
      title += " · #" + s.bounty
      if (String(s.attempt || "") !== "") title += " #" + s.attempt
      return title
    }
    if (who !== "") return where !== "" ? who + " · " + where : who
    if (String(s.ticket || "") !== "") return String(s.ticket)
    return "Session " + String(s.session || "")
  }

  // ------------------------------------------------------------- loading

  property string pendingRange: ""

  function refresh() {
    if (historyProcess.running) { pendingRange = range; return }
    historyProcess.command = ["omarchy-agent-otel", "history", "--range", range]
    historyProcess.running = true
  }

  function applyReport(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      if (parsed && Array.isArray(parsed.accounts)) {
        report = parsed
        errorText = ""
        nowMs = Number(parsed.nowMs || Date.now())
        return
      }
      errorText = "omarchy-agent-otel history returned no accounts"
    } catch (e) {
      errorText = "Could not read omarchy-agent-otel history"
    }
  }

  Process {
    id: historyProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReport(text)
    }
    onExited: function(code) {
      if (code !== 0 && !root.report) root.errorText = "omarchy-agent-otel history failed (exit " + code + ")"
      if (root.pendingRange !== "") {
        root.pendingRange = ""
        Qt.callLater(root.refresh)
      }
    }
  }

  // The live list moves every few seconds; the receiver rewrites the summary
  // when it does, and the history call reads it again.
  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/agents/otel/summary.json"
    watchChanges: true
    printErrors: false
    onFileChanged: refreshSoon.restart()
  }

  Timer {
    id: refreshSoon
    interval: 1500
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    refresh()
    // The keys work from the first frame, not after a click.
    Qt.callLater(function() { root.forceActiveFocus() })
  }

  Keys.onPressed: function(event) {
    var t = event.text
    if (event.key === Qt.Key_Escape || t === "q") root.closeRequested()
    else if (event.key === Qt.Key_Left || t === "h") root.selectAccount(root.accountIndex - 1)
    else if (event.key === Qt.Key_Right || t === "l") root.selectAccount(root.accountIndex + 1)
    else if (event.key === Qt.Key_Down || t === "j") flick.contentY = clamp(flick.contentY + Style.space(80), 0, Math.max(0, flick.contentHeight - flick.height))
    else if (event.key === Qt.Key_Up || t === "k") flick.contentY = clamp(flick.contentY - Style.space(80), 0, Math.max(0, flick.contentHeight - flick.height))
    else if (t === "1") root.setRange("7d")
    else if (t === "2") root.setRange("30d")
    else if (t === "3") root.setRange("all")
    else if (t === "r") root.refresh()
    else if (t === "t") root.toggleMetric()
    else if (t === "c") root.clearAgents()
    else return
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: root.surface
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight + margin * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    readonly property real margin: Style.space(22)

    Column {
      id: column
      x: flick.margin
      y: flick.margin
      width: flick.width - flick.margin * 2
      spacing: Style.space(16)

      // ---------- Title · range ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(titleColumn.implicitHeight, rangeGroup.implicitHeight)

        Column {
          id: titleColumn
          anchors.left: parent.left
          anchors.right: metricGroup.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: "Agent stats"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "API list price equivalent, from Claude Code telemetry · not what a subscription bills"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        ButtonGroup {
          id: metricGroup
          anchors.right: rangeGroup.left
          anchors.rightMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md
          options: [
            { value: "costUsd", label: "Cost", tooltip: "Key t toggles" },
            { value: "tokens", label: "Tokens", tooltip: "Key t toggles" }
          ]
          value: root.metric
          focusable: false
          foreground: root.foreground
          background: root.surface
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onChanged: function(v) { root.metric = v }
        }

        ButtonGroup {
          id: rangeGroup
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md
          options: [
            { value: "7d", label: "7 days", tooltip: "Key 1" },
            { value: "30d", label: "30 days", tooltip: "Key 2" },
            { value: "all", label: "All", tooltip: "Key 3" }
          ]
          value: root.range
          focusable: false
          foreground: root.foreground
          background: root.surface
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onChanged: function(v) { root.setRange(v) }
        }
      }

      // ---------- Account switch, the panel's ----------
      Row {
        id: accountSwitch
        visible: root.accounts.length > 1
        width: parent.width
        spacing: Style.spacing.md
        readonly property real cellWidth: root.accounts.length > 0
          ? (width - spacing * (root.accounts.length - 1)) / root.accounts.length : 0

        Repeater {
          model: root.accounts

          Button {
            required property var modelData
            required property int index
            width: accountSwitch.cellWidth
            text: modelData.name
            selected: index === root.accountIndex
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            tooltipText: modelData.looping > 0 ? modelData.looping + " looping session" + (modelData.looping === 1 ? "" : "s") : ""
            onClicked: root.selectedAccountId = modelData.id
          }
        }
      }

      Text {
        visible: root.errorText !== "" || (!root.report && root.errorText === "")
        width: parent.width
        textFormat: Text.PlainText
        text: root.errorText !== "" ? root.errorText : "Loading…"
        color: root.errorText !== "" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // ---------- Overview tiles ----------
      Row {
        id: tiles
        visible: !!root.account
        width: parent.width
        spacing: Style.space(10)
        readonly property real tileWidth: (width - spacing * 3) / 4

        Tile {
          width: tiles.tileWidth
          label: "TODAY"
          value: root.hasTelemetry ? root.formatMoney(root.account.todayUsd) : "—"
          detail: root.hasTelemetry ? Format.formatTokenCount(root.dayTokens(0)) + " tokens · API-equivalent" : "API-equivalent"
        }
        Tile {
          width: tiles.tileWidth
          label: "LAST 7 DAYS"
          value: root.hasTelemetry ? root.formatMoney(root.account.weekUsd) : "—"
          detail: root.hasTelemetry ? Format.formatTokenCount(root.dayTokens(7)) + " tokens · " + root.formatMoney(root.account.rangeUsd) + " over " + root.rangeLabel() : "No telemetry for this account"
        }
        Tile {
          width: tiles.tileWidth
          label: "LIVE SESSIONS"
          value: String(root.live.length)
          detail: "Active in the last " + Math.round(Number((root.report && root.report.liveWindowSec) || 300) / 60) + " minutes"
        }
        Tile {
          width: tiles.tileWidth
          label: "LOOPING"
          value: String(root.account ? Number(root.account.looping || 0) : 0)
          warn: !!root.account && Number(root.account.looping || 0) > 0
          detail: warn ? "Stuck retrying; see below" : "None flagged"
        }
      }

      // ---------- Live sessions ----------
      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Column {
        id: liveSection
        width: parent.width
        spacing: Style.spacing.md

        PanelSectionHeader {
          width: parent.width
          text: "LIVE SESSIONS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.live.length === 0
          textFormat: Text.PlainText
          text: root.hasTelemetry ? "No session has reported in the last five minutes." : "Live sessions come from Claude Code telemetry; this account sends none."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        SessionHeader {
          visible: root.live.length > 0
          width: parent.width
        }

        Repeater {
          model: root.live

          SessionRow {
            required property var modelData
            width: liveSection.width
            session: modelData
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Text {
        visible: !!root.account && !root.hasTelemetry
        width: parent.width
        textFormat: Text.PlainText
        text: "Cost and token history come from Claude Code's OpenTelemetry through omarchy-agent-otel; this account sends none. Its limit history is below."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // ---------- Charts ----------
      Grid {
        id: charts
        visible: root.hasTelemetry
        width: parent.width
        columns: width >= Style.space(900) ? 2 : 1
        columnSpacing: Style.space(28)
        rowSpacing: Style.space(22)
        readonly property real cellWidth: columns === 2 ? (width - columnSpacing) / 2 : width
        readonly property real chartHeight: Style.space(190)

        ChartCard {
          width: charts.cellWidth
          title: "COST PER DAY · BY MODEL"
          summary: root.formatMoney(root.account ? root.account.rangeUsd : 0) + " over " + root.rangeLabel()
          readout: costChart.hoverIndex >= 0 ? root.dayReadout(costChart.hoverIndex, "costUsd") : ""
          legend: root.modelSeries

          BarChart {
            id: costChart
            width: parent.width
            height: charts.chartHeight
            series: root.costSeries
            labels: root.days
            unit: "USD / day"
            money: true
          }
        }

        ChartCard {
          width: charts.cellWidth
          title: "TOKENS PER DAY · BY MODEL"
          summary: Format.formatTokenCount(root.account ? root.account.rangeTokens : 0) + " tokens · "
            + (root.account ? root.account.rangeRequests : 0) + " requests"
          readout: tokenChart.hoverIndex >= 0 ? root.dayReadout(tokenChart.hoverIndex, "tokens") : ""
          legend: root.modelSeries

          BarChart {
            id: tokenChart
            width: parent.width
            height: charts.chartHeight
            series: root.tokenSeries
            labels: root.days
            unit: "tokens / day (incl. cache)"
            money: false
          }
        }

        ChartCard {
          width: charts.cellWidth
          title: (root.metricIsMoney() ? "COST" : "TOKENS") + " BY BOUNTY · TOP " + Math.min(12, root.account && root.account.byBounty ? root.account.byBounty.length : 0)
          summary: root.rangeLabel()
          legend: []

          BarList {
            width: parent.width
            rows: root.bountyRows(root.account)
            emptyText: "No requests tagged with a bounty or ticket in this range."
          }
        }

        ChartCard {
          width: charts.cellWidth
          title: (root.metricIsMoney() ? "COST" : "TOKENS") + " PER BOUNTY · BY MODEL"
          summary: "tagged " + root.metricWord() + " ÷ bounties worked"
          legend: []

          BarList {
            width: parent.width
            rows: root.perBountyRows(root.account)
            emptyText: "No tagged requests in this range."
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Every bounty a model worked counts, landed or not: telemetry does not know which landed. A bounty worked by two models counts for both."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      // ---------- Agents ----------
      PanelSeparator {
        visible: charts.visible
        width: parent.width
        foreground: root.foreground
      }

      Column {
        id: agentSection
        visible: root.hasTelemetry
        width: parent.width
        spacing: Style.spacing.md

        Item {
          width: parent.width
          implicitHeight: Math.max(agentHeader.implicitHeight, projectGroup.implicitHeight)

          PanelSectionHeader {
            id: agentHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "AGENTS · " + root.shownAgents.length + (root.projectFilter !== "" ? " ON " + root.projectFilter.toUpperCase() : " ACROSS " + root.projects.length + " PROJECT" + (root.projects.length === 1 ? "" : "S"))
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            id: projectGroup
            visible: root.projects.length > 1
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md
            options: root.projectOptions()
            value: root.projectFilter
            focusable: false
            foreground: root.foreground
            background: root.surface
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { root.projectFilter = v }
          }
        }

        Text {
          visible: root.agents.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: "No named agents in this range. Board slots carry a name in board.json; omarchy agent --project <p> --name <n> tags a session by hand."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        AgentHeader {
          visible: root.shownAgents.length > 0
          width: parent.width
        }

        Repeater {
          model: root.shownAgents

          AgentRow {
            required property var modelData
            required property int index
            width: agentSection.width
            agent: modelData
            picked: root.selectedAgents.indexOf(String(modelData.agent)) >= 0
            swatch: {
              for (var i = 0; i < root.agentSeries.length; i++)
                if (root.agentSeries[i].key === String(modelData.agent)) return root.agentSeries[i].color
              return "transparent"
            }
          }
        }

        Text {
          visible: root.shownAgents.length > 0
          width: parent.width
          textFormat: Text.PlainText
          text: "Click an agent to chart it alone · Ctrl+click adds one to compare · c clears"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ChartCard {
          visible: root.agentSeries.length > 0
          width: parent.width
          title: (root.metricIsMoney() ? "COST" : "TOKENS") + " PER DAY · " + (root.selectedAgents.length > 0 ? root.agentSeries.length + " PICKED AGENT" + (root.agentSeries.length === 1 ? "" : "S") : "TOP 3 AGENTS")
          summary: root.rangeLabel()
          readout: agentChart.hoverIndex >= 0 ? root.agentReadout(agentChart.hoverIndex) : ""
          legend: root.agentSeries

          BarChart {
            id: agentChart
            width: parent.width
            height: Style.space(210)
            series: root.agentSeries
            labels: root.days
            unit: root.metricIsMoney() ? "USD / day" : "tokens / day (incl. cache)"
            money: root.metricIsMoney()
            lines: root.agentSeries.length > 1
          }
        }
      }

      // ---------- Limits over time ----------
      PanelSeparator {
        visible: charts.visible
        width: parent.width
        foreground: root.foreground
      }

      ChartCard {
        width: parent.width
        title: "LIMITS OVER TIME"
        summary: root.limitSeries.length > 0 ? root.rangeLabel() : ""
        readout: limitChart.hoverMs > 0 ? root.limitReadout(limitChart.hoverMs) : ""
        legend: root.limitSeries

        LineChart {
          id: limitChart
          visible: root.limitSeries.length > 0
          width: parent.width
          height: Style.space(200)
          series: root.limitSeries
          startMs: root.days.length > 0 ? root.dayDate(root.days[0]).getTime() : root.nowMs - 7 * 86400000
          endMs: root.nowMs
        }

        Text {
          visible: root.limitSeries.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: "No limit history yet. Each usage refresh records the session and weekly percentages when they change."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "h / l account · 1 2 3 range · t cost / tokens · c clear agents · r refresh · Esc close"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  function dayReadout(index, field) {
    var perDay = account && account.perDay ? account.perDay : []
    var day = perDay[index]
    if (!day) return ""
    var series = field === "costUsd" ? costSeries : tokenSeries
    var parts = [longDay(day.day), field === "costUsd" ? formatMoney(day.costUsd) : Format.formatTokenCount(day.tokens) + " tokens"]
    for (var i = 0; i < series.length; i++) {
      var v = series[i].values[index]
      if (v > 0) parts.push(series[i].name + " " + (field === "costUsd" ? formatMoney(v) : Format.formatTokenCount(v)))
    }
    return parts.join(" · ")
  }

  function valueAt(points, t) {
    var v = -1
    for (var i = 0; i < points.length && points[i].t <= t; i++) v = points[i].v
    return v
  }

  function limitReadout(t) {
    var d = new Date(t)
    var parts = [longDay(d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0"))
      + " " + String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")]
    for (var i = 0; i < limitSeries.length; i++) {
      var v = valueAt(limitSeries[i].points, t)
      if (v >= 0) parts.push(limitSeries[i].name + " " + Math.round(v * 100) + "%")
    }
    return parts.join(" · ")
  }

  function dayTokens(lastDays) {
    var perDay = account && Array.isArray(account.perDay) ? account.perDay : []
    if (perDay.length === 0) return 0
    if (lastDays <= 0) return Number(perDay[perDay.length - 1].tokens || 0)
    var sum = 0
    for (var i = Math.max(0, perDay.length - lastDays); i < perDay.length; i++) sum += Number(perDay[i].tokens || 0)
    return sum
  }

  function projectOptions() {
    var out = [{ value: "", label: "All", tooltip: "Every project" }]
    for (var i = 0; i < projects.length; i++) {
      var p = projects[i]
      var name = String(p.project || "")
      out.push({ value: name, label: name === "" ? "untagged" : name,
                 tooltip: p.agents + " agent" + (p.agents === 1 ? "" : "s") + " · " + p.bounties + " bount" + (p.bounties === 1 ? "y" : "ies") + " · " + formatMoney(p.costUsd) + " · " + Format.formatTokenCount(Number(p.tokens || 0)) + " tokens" })
    }
    return out
  }

  function agentReadout(index) {
    var day = days[index]
    if (!day) return ""
    var parts = [longDay(day)]
    for (var i = 0; i < agentSeries.length; i++) {
      var v = agentSeries[i].values[index]
      parts.push(agentSeries[i].name + " " + formatMetric(v))
    }
    return parts.join(" · ")
  }

  // The bounty and per-bounty cards follow the metric switch; the tooltip
  // always carries the other number.
  function bountyRows(acc) {
    var list = acc && Array.isArray(acc.byBounty) ? acc.byBounty : []
    list = list.slice().sort(function(a, b) { return Number(b[metric] || 0) - Number(a[metric] || 0) })
    var rows = []
    for (var i = 0; i < list.length && i < 12; i++) {
      var b = list[i]
      var id = String(b.id || b.bounty)
      rows.push({
        name: b.project ? "#" + id + " · " + b.project : id,
        detail: b.model ? Format.friendlyModelName(b.model) : "",
        value: Number(b[metric] || 0),
        valueText: formatMetric(b[metric]),
        tooltip: formatMoney(b.costUsd) + " · " + Format.formatTokenCount(Number(b.tokens || 0)) + " tokens · " + Number(b.requests || 0) + " requests · "
          + Number(b.sessions || 0) + " session" + (Number(b.sessions) === 1 ? "" : "s")
      })
    }
    return rows
  }

  function perBountyRows(acc) {
    var list = acc && Array.isArray(acc.byModel) ? acc.byModel : []
    var field = metricIsMoney() ? "costPerBountyUsd" : "tokensPerBounty"
    var rows = []
    list = list.slice().sort(function(a, b) { return Number(b[field] || 0) - Number(a[field] || 0) })
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      if (!(Number(m.bounties) > 0)) continue
      rows.push({
        name: Format.friendlyModelName(m.model),
        detail: m.bounties + " bount" + (Number(m.bounties) === 1 ? "y" : "ies"),
        value: Number(m[field] || 0),
        valueText: formatMetric(m[field]),
        tooltip: formatMoney(m.costPerBountyUsd) + " and " + Format.formatTokenCount(Number(m.tokensPerBounty || 0)) + " tokens per bounty · "
          + formatMoney(m.costUsd) + " on " + Format.formatTokenCount(Number(m.tokens || 0)) + " tokens in the range, tagged or not"
      })
    }
    return rows
  }

  // ------------------------------------------------------------ components

  component Tile: BorderSurface {
    id: tile
    property string label: ""
    property string value: ""
    property string detail: ""
    property bool warn: false

    implicitHeight: tileColumn.implicitHeight + Style.space(14) * 2
    radius: Style.cornerRadius
    color: warn ? root.alpha(root.urgent, 0.10) : root.alpha(root.foreground, 0.05)
    borderSpec: warn ? Border.flat(root.alpha(root.urgent, 0.35), 1) : Border.none()

    Column {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(14)
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        text: tile.label
        color: tile.warn ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
      }
      Text {
        textFormat: Text.PlainText
        text: tile.value
        color: tile.warn ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // A header, a one-line summary on the right, a readout of whatever the
  // pointer is over, the chart, and its legend.
  component ChartCard: Column {
    id: card
    property string title: ""
    property string summary: ""
    property string readout: ""
    property var legend: []
    default property alias content: body.data

    spacing: Style.spacing.md

    Item {
      width: parent.width
      implicitHeight: Math.max(cardTitle.implicitHeight, cardSummary.implicitHeight)

      PanelSectionHeader {
        id: cardTitle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: card.title
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        id: cardSummary
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: card.summary
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Column {
      id: body
      width: parent.width
      spacing: Style.spacing.md
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(legendRow.implicitHeight, readoutText.implicitHeight)
      visible: card.legend.length > 0 || card.readout !== ""

      Flow {
        id: legendRow
        visible: card.readout === ""
        width: parent.width
        spacing: Style.space(14)

        Repeater {
          model: card.legend

          Row {
            required property var modelData
            spacing: Style.space(6)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10)
              height: modelData.points ? Math.max(2, modelData.width || 2) : Style.space(10)
              radius: modelData.points ? 0 : Style.space(2)
              color: modelData.color
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.name
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Text {
        id: readoutText
        visible: card.readout !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: card.readout
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // Stacked bars per day on a labelled value axis. Gridlines at round
  // numbers, every Nth date under the bars so the labels never collide,
  // anchored on today at the right edge.
  component BarChart: Canvas {
    id: chart
    property var series: []
    property var labels: []
    property string unit: ""
    property bool money: false
    // Lines instead of stacked bars: one line per series, for comparing
    // agents rather than adding them up.
    property bool lines: false
    property int hoverIndex: -1

    readonly property int fontPx: Style.font.caption
    property real plotLeft: 0
    property real slot: 0

    onSeriesChanged: requestPaint()
    onLabelsChanged: requestPaint()
    onLinesChanged: requestPaint()
    onMoneyChanged: requestPaint()
    onHoverIndexChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Connections {
      target: root
      function onForegroundChanged() { chart.requestPaint() }
      function onAccentChanged() { chart.requestPaint() }
    }

    function niceStep(max, count) {
      var raw = max / count
      var mag = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10))
      var norm = raw / mag
      var step = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10
      return step * mag
    }

    function axisText(v) { return chart.money ? root.formatMoneyShort(v) : Format.formatTokenCount(v).replace(".0", "") }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var n = chart.labels.length
      if (n === 0 || width <= 0 || height <= 0) return
      ctx.font = chart.fontPx + "px \"" + root.fontFamily + "\""

      var totals = []
      var max = 0
      for (var i = 0; i < n; i++) {
        var sum = 0
        for (var s = 0; s < chart.series.length; s++) {
          var one = Number(chart.series[s].values[i] || 0)
          sum += one
          if (chart.lines) max = Math.max(max, one)
        }
        totals.push(sum)
        if (!chart.lines) max = Math.max(max, sum)
      }
      if (max <= 0) max = chart.money ? 1 : 1000
      var step = niceStep(max, 4)
      var top = Math.ceil(max / step - 1e-9) * step

      var widest = 0
      for (var v = 0; v <= top + step / 2; v += step) widest = Math.max(widest, ctx.measureText(axisText(v)).width)
      var left = Math.ceil(widest) + 8
      var plotTop = chart.fontPx * 2 + 6
      var bottom = height - chart.fontPx - 8
      var plotH = bottom - plotTop
      var slotW = (width - left) / n
      chart.plotLeft = left
      chart.slot = slotW

      // Unit, top left: the value axis says what it counts.
      ctx.fillStyle = root.css(root.dim)
      ctx.textAlign = "left"
      ctx.textBaseline = "top"
      ctx.fillText(chart.unit, 0, 0)

      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      ctx.lineWidth = 1
      for (var g = 0; g <= top + step / 2; g += step) {
        var gy = Math.round(bottom - g / top * plotH) + 0.5
        ctx.strokeStyle = root.css(g === 0 ? root.alpha(root.foreground, 0.28) : root.grid)
        ctx.beginPath()
        ctx.moveTo(left, gy)
        ctx.lineTo(width, gy)
        ctx.stroke()
        ctx.fillText(axisText(g), left - 6, gy)
      }

      if (chart.hoverIndex >= 0 && chart.hoverIndex < n) {
        ctx.fillStyle = root.css(root.alpha(root.foreground, 0.06))
        ctx.fillRect(left + chart.hoverIndex * slotW, plotTop, slotW, plotH)
      }

      var barW = Math.max(1, Math.min(slotW * 0.72, 30))
      if (chart.lines) {
        // One line per series through the day centres, a dot on each day
        // that has a value, and a ring on the hovered day.
        for (var ls = chart.series.length - 1; ls >= 0; ls--) {
          var lineSeries = chart.series[ls]
          ctx.strokeStyle = root.css(lineSeries.color)
          ctx.fillStyle = root.css(lineSeries.color)
          ctx.lineWidth = 2
          ctx.beginPath()
          var started = false
          for (var ld = 0; ld < n; ld++) {
            var lv = Number(lineSeries.values[ld] || 0)
            var lx = left + ld * slotW + slotW / 2
            var ly = bottom - lv / top * plotH
            if (started) ctx.lineTo(lx, ly); else { ctx.moveTo(lx, ly); started = true }
          }
          ctx.stroke()
          for (var pd = 0; pd < n; pd++) {
            var pv = Number(lineSeries.values[pd] || 0)
            if (pv <= 0) continue
            var px = left + pd * slotW + slotW / 2
            var py = bottom - pv / top * plotH
            ctx.beginPath()
            ctx.arc(px, py, pd === chart.hoverIndex ? 4 : 2.5, 0, Math.PI * 2)
            ctx.fill()
          }
        }
      } else {
        for (var d = 0; d < n; d++) {
          var x = left + d * slotW + (slotW - barW) / 2
          var y = bottom
          for (var k = 0; k < chart.series.length; k++) {
            var value = Number(chart.series[k].values[d] || 0)
            if (value <= 0) continue
            var h = value / top * plotH
            ctx.fillStyle = root.css(chart.series[k].color)
            // A hairline of surface between stacked segments keeps two close
            // shades apart.
            var gap = h > 3 && k > 0 ? 1 : 0
            ctx.fillRect(x, y - h, barW, h - gap)
            y -= h
          }
        }
      }

      ctx.fillStyle = root.css(root.dim)
      ctx.textAlign = "center"
      ctx.textBaseline = "top"
      var labelW = ctx.measureText("10/30").width + 14
      var every = Math.max(1, Math.ceil(labelW / slotW))
      // Centred under its bar, but never past either edge of the canvas.
      for (var l = n - 1; l >= 0; l -= every) {
        var text = root.shortDay(chart.labels[l])
        var half = ctx.measureText(text).width / 2
        ctx.fillText(text, root.clamp(left + l * slotW + slotW / 2, left + half, width - half), bottom + 5)
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) {
        if (chart.slot <= 0 || mouse.x < chart.plotLeft) { chart.hoverIndex = -1; return }
        chart.hoverIndex = Math.min(chart.labels.length - 1, Math.floor((mouse.x - chart.plotLeft) / chart.slot))
      }
      onExited: chart.hoverIndex = -1
    }
  }

  // Step lines, since a limit holds its value until the next refresh says
  // otherwise. 0–100% on the value axis with the panel's 90% alarm line.
  component LineChart: Canvas {
    id: line
    property var series: []
    property double startMs: 0
    property double endMs: 0
    property double hoverMs: 0

    readonly property int fontPx: Style.font.caption
    property real plotLeft: 0

    onSeriesChanged: requestPaint()
    onStartMsChanged: requestPaint()
    onEndMsChanged: requestPaint()
    onHoverMsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Connections {
      target: root
      function onForegroundChanged() { line.requestPaint() }
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (width <= 0 || height <= 0 || !(line.endMs > line.startMs)) return
      ctx.font = line.fontPx + "px \"" + root.fontFamily + "\""
      var left = Math.ceil(ctx.measureText("100%").width) + 8
      var right = width - 4
      var plotTop = line.fontPx * 2 + 6
      var bottom = height - line.fontPx - 8
      var plotH = bottom - plotTop
      var span = line.endMs - line.startMs
      line.plotLeft = left
      function xOf(t) { return left + (root.clamp(t, line.startMs, line.endMs) - line.startMs) / span * (right - left) }
      function yOf(v) { return bottom - root.clamp(v, 0, 1) * plotH }

      ctx.fillStyle = root.css(root.dim)
      ctx.textAlign = "left"
      ctx.textBaseline = "top"
      ctx.fillText("% of limit used", 0, 0)

      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      ctx.lineWidth = 1
      for (var p = 0; p <= 100; p += 25) {
        var gy = Math.round(yOf(p / 100)) + 0.5
        ctx.strokeStyle = root.css(p === 0 ? root.alpha(root.foreground, 0.28) : root.grid)
        ctx.beginPath()
        ctx.moveTo(left, gy)
        ctx.lineTo(right, gy)
        ctx.stroke()
        ctx.fillText(p + "%", left - 6, gy)
      }

      // Day ticks along the bottom, as many as fit.
      var dayMs = 86400000
      var first = new Date(line.startMs)
      first.setHours(0, 0, 0, 0)
      var daysSpan = Math.ceil(span / dayMs)
      var labelW = ctx.measureText("10/30").width + 16
      var every = Math.max(1, Math.ceil(labelW / ((right - left) / Math.max(1, daysSpan))))
      ctx.textAlign = "center"
      ctx.textBaseline = "top"
      ctx.fillStyle = root.css(root.dim)
      var dayIndex = 0
      for (var t = first.getTime(); t <= line.endMs; t += dayMs, dayIndex++) {
        if (t < line.startMs || dayIndex % every !== 0) continue
        var tx = Math.round(xOf(t)) + 0.5
        ctx.strokeStyle = root.css(root.grid)
        ctx.beginPath()
        ctx.moveTo(tx, plotTop)
        ctx.lineTo(tx, bottom)
        ctx.stroke()
        var day = new Date(t)
        var dayText = (day.getMonth() + 1) + "/" + day.getDate()
        var halfW = ctx.measureText(dayText).width / 2
        ctx.fillText(dayText, root.clamp(tx, left + halfW, width - halfW), bottom + 5)
      }

      // The panel lights a limit at 90%.
      ctx.strokeStyle = root.css(root.alpha(root.urgent, 0.6))
      ctx.setLineDash([4, 4])
      ctx.beginPath()
      ctx.moveTo(left, Math.round(yOf(0.9)) + 0.5)
      ctx.lineTo(right, Math.round(yOf(0.9)) + 0.5)
      ctx.stroke()
      ctx.setLineDash([])

      for (var s = line.series.length - 1; s >= 0; s--) {
        var series = line.series[s]
        var pts = series.points || []
        if (pts.length === 0) continue
        ctx.strokeStyle = root.css(series.color)
        ctx.lineWidth = series.width || 1.5
        ctx.setLineDash(series.dash ? [6, 3] : [])
        ctx.beginPath()
        ctx.moveTo(xOf(pts[0].t), yOf(pts[0].v))
        for (var i = 1; i < pts.length; i++) {
          ctx.lineTo(xOf(pts[i].t), yOf(pts[i - 1].v))
          ctx.lineTo(xOf(pts[i].t), yOf(pts[i].v))
        }
        ctx.lineTo(xOf(line.endMs), yOf(pts[pts.length - 1].v))
        if (series.fill) {
          ctx.lineTo(xOf(line.endMs), bottom)
          ctx.lineTo(xOf(pts[0].t), bottom)
          ctx.closePath()
          ctx.fillStyle = root.css(root.alpha(series.color, series.color.a * 0.6))
          ctx.fill()
        } else {
          ctx.stroke()
        }
      }
      ctx.setLineDash([])

      if (line.hoverMs > 0) {
        var hx = Math.round(xOf(line.hoverMs)) + 0.5
        ctx.strokeStyle = root.css(root.alpha(root.foreground, 0.45))
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(hx, plotTop)
        ctx.lineTo(hx, bottom)
        ctx.stroke()
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) {
        if (mouse.x < line.plotLeft) { line.hoverMs = 0; return }
        line.hoverMs = line.startMs + (mouse.x - line.plotLeft) / Math.max(1, line.width - 4 - line.plotLeft) * (line.endMs - line.startMs)
      }
      onExited: line.hoverMs = 0
    }
  }

  // Ranked rows with the share bar behind the label, the panel's ModelRow
  // laid out wider: name, a dim detail, the value labelled directly.
  component BarList: Column {
    id: list
    property var rows: []
    property string emptyText: ""
    readonly property real peak: {
      var p = 0
      for (var i = 0; i < rows.length; i++) p = Math.max(p, rows[i].value)
      return Math.max(0.000001, p)
    }

    spacing: Style.space(3)

    Text {
      visible: list.rows.length === 0
      textFormat: Text.PlainText
      text: list.emptyText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: list.rows

      Item {
        id: barRow
        required property var modelData
        width: list.width
        implicitHeight: barName.implicitHeight + Style.spacing.md

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: root.alpha(root.foreground, barHover.containsMouse ? 0.07 : 0.04)
        }

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          radius: Style.cornerRadius
          width: parent.width * root.clamp(barRow.modelData.value / list.peak, 0, 1)
          color: root.alpha(root.foreground, 0.16)
        }

        Text {
          id: barName
          textFormat: Text.PlainText
          text: barRow.modelData.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, parent.width * 0.45)
        }

        Text {
          textFormat: Text.PlainText
          text: barRow.modelData.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          anchors.left: barName.right
          anchors.leftMargin: Style.space(10)
          anchors.right: barValue.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: barValue
          textFormat: Text.PlainText
          text: barRow.modelData.valueText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        MouseArea {
          id: barHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: barHover.containsMouse && barRow.modelData.tooltip !== ""
          text: barRow.modelData.tooltip
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // Columns of the agents table, as fractions of its width.
  readonly property var agentColumns: [0.22, 0.14, 0.16, 0.11, 0.11, 0.08, 0.08, 0.10]

  component AgentHeader: Row {
    id: agentHeaderRow
    readonly property var titles: ["AGENT", "PROJECT", "MODEL", "COST", "TOKENS", "REQ", "SESSIONS", "STATUS"]
    Repeater {
      model: agentHeaderRow.titles
      Text {
        required property var modelData
        required property int index
        width: agentHeaderRow.width * root.agentColumns[index]
        leftPadding: index === 0 ? Style.space(22) : 0
        textFormat: Text.PlainText
        text: modelData
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
        horizontalAlignment: index >= 3 && index <= 6 ? Text.AlignRight : Text.AlignLeft
        rightPadding: index >= 3 && index <= 6 ? Style.space(14) : 0
      }
    }
  }

  // One named agent over the range. A click charts it alone; Ctrl+click
  // adds it to, or drops it from, the agents drawn together.
  component AgentRow: BorderSurface {
    id: agentRow
    property var agent: null
    property bool picked: false
    property color swatch: "transparent"
    readonly property bool live: !!agent && agent.live === true
    readonly property var cells: {
      var a = agent || {}
      return [
        String(a.name || a.agent || ""),
        String(a.project || "") !== "" ? String(a.project) : "—",
        a.model ? Format.friendlyModelName(a.model) : "—",
        root.formatMoney(a.costUsd),
        Format.formatTokenCount(Number(a.tokens || 0)),
        String(Number(a.requests || 0)),
        String(Number(a.sessions || 0)),
        live ? "Live" : "Idle"
      ]
    }

    implicitHeight: Math.max(Style.spacing.controlHeight, agentCells.implicitHeight + Style.spacing.md * 2)
    radius: Style.cornerRadius
    color: picked ? Style.selectedFillFor(root.foreground, root.accent) : root.alpha(root.foreground, agentHover.containsMouse ? 0.07 : 0.04)
    borderSpec: picked ? Border.flat(root.alpha(root.accentUsable ? root.accent : root.foreground, 0.5), 1) : Border.none()

    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(8)
      height: width
      radius: width / 2
      color: agentRow.swatch
      visible: agentRow.swatch.a > 0
    }

    Row {
      id: agentCells
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter

      Repeater {
        model: agentRow.cells
        Text {
          required property var modelData
          required property int index
          width: agentCells.width * root.agentColumns[index]
          leftPadding: index === 0 ? Style.space(22) : 0
          rightPadding: index >= 3 && index <= 6 ? Style.space(14) : Style.space(8)
          textFormat: Text.PlainText
          text: modelData
          color: index === 0 || (index === 3 && root.metricIsMoney()) || (index === 4 && !root.metricIsMoney()) ? root.foreground
            : (index === 7 && agentRow.live ? (root.accentUsable ? root.accent : root.foreground) : root.dim)
          font.family: root.fontFamily
          font.pixelSize: index === 0 ? Style.font.bodySmall : Style.font.caption
          font.bold: (index === 3 && root.metricIsMoney()) || (index === 4 && !root.metricIsMoney())
          horizontalAlignment: index >= 3 && index <= 6 ? Text.AlignRight : Text.AlignLeft
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: agentHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      onClicked: function(mouse) { root.selectAgent(agentRow.agent.agent, (mouse.modifiers & Qt.ControlModifier) !== 0) }
    }

    PanelToolTip {
      visible: agentHover.containsMouse
      text: {
        var a = agentRow.agent || {}
        var models = []
        var byModel = a.byModel || {}
        for (var m in byModel) models.push(Format.friendlyModelName(m) + " " + root.formatMoney(byModel[m].costUsd) + " / " + Format.formatTokenCount(Number(byModel[m].tokens || 0)))
        return (models.length > 0 ? models.join(" · ") + "\n" : "") + "Click: this agent alone · Ctrl+click: add to the comparison"
      }
      fontFamily: root.fontFamily
    }
  }

  // Columns of the live table, as fractions of its width.
  readonly property var sessionColumns: [0.25, 0.13, 0.09, 0.09, 0.07, 0.09, 0.08, 0.20]

  component SessionHeader: Row {
    id: header
    readonly property var titles: ["SESSION", "MODEL", "COST", "TOKENS", "REQ", "TOOLS", "LAST", "STATUS"]
    Repeater {
      model: header.titles
      Text {
        required property var modelData
        required property int index
        width: header.width * root.sessionColumns[index]
        leftPadding: index === 0 ? Style.space(10) : 0
        textFormat: Text.PlainText
        text: modelData
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
        horizontalAlignment: index >= 2 && index <= 6 ? Text.AlignRight : Text.AlignLeft
        rightPadding: index >= 2 && index <= 6 ? Style.space(14) : 0
      }
    }
  }

  // A live session; one the receiver flags as looping takes the urgent card
  // the panel uses for a problem, with the reason spelled out.
  component SessionRow: BorderSurface {
    id: sessionRow
    property var session: null
    readonly property bool looping: !!session && session.looping === true
    readonly property var cells: {
      var s = session || {}
      var idle = root.nowMs - Number(s.lastActivityMs || 0)
      return [
        root.sessionTitle(s),
        s.model ? Format.friendlyModelName(s.model) : "—",
        root.formatMoney(s.costUsd),
        Format.formatTokenCount(Number(s.tokens || 0)),
        String(Number(s.requests || 0)),
        Number(s.toolCalls || 0) + (Number(s.toolFailures || 0) > 0 ? " (" + Number(s.toolFailures) + "✕)" : ""),
        idle < 60000 ? "now" : root.formatDuration(idle),
        looping ? "Looping · " + String(s.loopReason || "") : "Working"
      ]
    }

    implicitHeight: Math.max(Style.spacing.controlHeight, cellRow.implicitHeight + Style.spacing.md * 2)
    radius: Style.cornerRadius
    color: looping ? root.alpha(root.urgent, 0.10) : root.alpha(root.foreground, 0.04)
    borderSpec: looping ? Border.flat(root.alpha(root.urgent, 0.35), 1) : Border.none()

    Row {
      id: cellRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter

      Repeater {
        model: sessionRow.cells
        Text {
          required property var modelData
          required property int index
          width: cellRow.width * root.sessionColumns[index]
          leftPadding: index === 0 ? Style.space(10) : 0
          rightPadding: index >= 2 && index <= 6 ? Style.space(14) : Style.space(8)
          textFormat: Text.PlainText
          text: modelData
          color: sessionRow.looping && (index === 7 || index === 2) ? root.urgent : (index === 0 || index === 2 ? root.foreground : root.dim)
          font.family: root.fontFamily
          font.pixelSize: index === 0 ? Style.font.bodySmall : Style.font.caption
          font.bold: index === 2
          horizontalAlignment: index >= 2 && index <= 6 ? Text.AlignRight : Text.AlignLeft
          wrapMode: index === 7 ? Text.WordWrap : Text.NoWrap
          elide: index === 7 ? Text.ElideNone : Text.ElideRight
        }
      }
    }

    MouseArea {
      id: sessionHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: sessionHover.containsMouse
      text: "Session " + String((sessionRow.session || {}).sessionId || "") + " · last activity " + String((sessionRow.session || {}).lastActivity || "")
      fontFamily: root.fontFamily
    }
  }
}
