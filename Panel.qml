import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "swheel33.perfwatch"
  ipcTarget: "swheel33.perfwatch"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/perfwatch/state.json"
  readonly property string collectorPath: decodeURIComponent(Qt.resolvedUrl("collector.py").toString().replace(/^file:\/\//, ""))

  property var state: ({ incidents: [] })
  property int stateRevision: 0
  property int filterDays: 1
  property string expandedId: ""
  property bool clearArmed: false
  property bool cursorActive: false
  property int selectedIndex: 0
  property double nowMs: Date.now()

  readonly property var incidents: filteredIncidents()
  readonly property int recentCount: countSince(24 * 3600 * 1000)
  readonly property bool hasSignal: recentCount > 0

  function filteredIncidents() {
    var revision = stateRevision
    var rows = state && Array.isArray(state.incidents) ? state.incidents : []
    var cutoff = nowMs - filterDays * 86400000
    return rows.filter(function(row) {
      var time = new Date(String(row.startTime || "")).getTime()
      return isFinite(time) && time >= cutoff
    })
  }

  function countSince(span) {
    var revision = stateRevision
    var rows = state && Array.isArray(state.incidents) ? state.incidents : []
    var cutoff = nowMs - span
    var count = 0
    for (var i = 0; i < rows.length; i++) {
      var time = new Date(String(rows[i].startTime || "")).getTime()
      if (isFinite(time) && time >= cutoff) count++
    }
    return count
  }

  function parseState(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (!parsed || parsed.schemaVersion !== 1 || !Array.isArray(parsed.incidents)) return
      state = parsed
      stateRevision++
      selectedIndex = Math.max(0, Math.min(selectedIndex, filteredIncidents().length - 1))
      if (clearArmed && parsed.incidents.length === 0) clearArmed = false
    } catch (error) {
      console.warn("perfwatch", "Ignoring malformed state", error)
    }
  }

  function setFilter(days) {
    filterDays = days
    selectedIndex = 0
    expandedId = ""
  }

  function select(delta) {
    if (incidents.length === 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(incidents.length - 1, selectedIndex + delta))
    var target = incidentRepeater.itemAt(selectedIndex)
    if (target) panelScroll.contentY = Math.max(0, Math.min(target.y, panelScroll.contentHeight - panelScroll.height))
  }

  function toggleSelected() {
    if (incidents.length === 0) return
    var id = String(incidents[selectedIndex].id || "")
    expandedId = expandedId === id ? "" : id
  }

  function requestClear() {
    if (!clearArmed) {
      clearArmed = true
      clearReset.restart()
      return
    }
    clearReset.stop()
    if (!clearProcess.running) clearProcess.running = true
  }

  function formatWhen(value) {
    var date = new Date(String(value || ""))
    if (isNaN(date.getTime())) return "Unknown time"
    var today = new Date(nowMs)
    var sameDay = date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth() && date.getDate() === today.getDate()
    return (sameDay ? "Today " : Qt.formatDate(date, "MMM d ")) + Qt.formatTime(date, "h:mm AP")
  }

  function formatDuration(seconds) {
    var value = Math.max(0, Number(seconds || 0))
    if (value < 60) return Math.round(value) + "s"
    if (value < 3600) return Math.round(value / 60) + "m"
    return Math.floor(value / 3600) + "h " + Math.round((value % 3600) / 60) + "m"
  }

  function severityColor(row) {
    return Number(row && row.severityLevel || 0) >= 2 ? urgent : foreground
  }

  function detailText(row) {
    var peak = row && row.peak ? row.peak : {}
    var recovery = row && row.recovery ? row.recovery : {}
    var parts = []
    if (Number(peak.cpuPercent || 0) > 0) parts.push("CPU " + Math.round(peak.cpuPercent) + "%")
    if (Number(peak.memoryPsi || 0) > 0) parts.push("memory PSI " + Number(peak.memoryPsi).toFixed(1) + "%")
    if (Number(peak.ioPsi || 0) > 0) parts.push("I/O PSI " + Number(peak.ioPsi).toFixed(1) + "%")
    if (Number(peak.swapPagesPerSecond || 0) > 0) parts.push("swap " + Number(peak.swapPagesPerSecond).toFixed(1) + " pages/s")
    if (Number(peak.memoryAvailableMiB || 0) > 0) parts.push(Math.round(peak.memoryAvailableMiB) + " MiB available")
    var text = parts.join("  ·  ")
    var reason = String(recovery.reason || "")
    if (reason === "recovered") text += (text ? "\n" : "") + String(recovery.summary || "Pressure returned below the recovery threshold")
    else if (reason === "suspend_gap") text += (text ? "\n" : "") + "Ended across a suspend or sampling gap"
    else if (reason === "collector_restart") text += (text ? "\n" : "") + "Collector restarted before recovery was observed"
    return text
  }

  function offenderRows(row) {
    return row && row.offenders && Array.isArray(row.offenders.peak) ? row.offenders.peak : []
  }

  function offenderUsage(row) {
    var parts = []
    if (Number(row.rssMiB || 0) > 0) parts.push(Number(row.rssMiB).toFixed(0) + " MiB")
    if (Number(row.cpuPercent || 0) >= 0.1) parts.push(Number(row.cpuPercent).toFixed(1) + "% CPU")
    if (Number(row.ioMiBPerSecond || 0) >= 0.01) parts.push(Number(row.ioMiBPerSecond).toFixed(2) + " MiB/s I/O")
    return parts.join("  ·  ")
  }

  visible: true
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    cursorActive = false
    clearArmed = false
    stateFile.reload()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: collectorProcess
    command: ["python3", root.collectorPath]
    running: true
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("perfwatch", "Collector exited", exitCode)
      collectorRestart.restart()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("perfwatch", text.trim())
    }
  }

  Timer {
    id: collectorRestart
    interval: 5000
    onTriggered: if (!collectorProcess.running) collectorProcess.running = true
  }

  Process {
    id: clearProcess
    command: ["python3", root.collectorPath, "--clear"]
    onExited: stateFile.reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseState(text())
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: stateFile.reload()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: clearReset
    interval: 5000
    onTriggered: root.clearArmed = false
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: "󰓅"
    active: root.hasSignal
    tooltipText: root.recentCount > 0 ? root.recentCount + " incident" + (root.recentCount === 1 ? "" : "s") + " in 24 hours" : "No recent performance incidents"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.setFilter(dx < 0 ? (root.filterDays === 30 ? 7 : 1) : (root.filterDays === 1 ? 7 : 30))
        if (dy !== 0) root.select(dy)
      }
      onActivateRequested: root.toggleSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "1") root.setFilter(1)
        else if (text === "7") root.setFilter(7)
        else if (text === "3") root.setFilter(30)
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: panelColumn
          width: panelScroll.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Performance history"
            meta: root.recentCount > 0 ? root.recentCount + " in the last 24 hours" : "No incidents in the last 24 hours"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰓅"
                color: root.hasSignal ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Row {
            id: filterRow
            width: parent.width
            spacing: Style.spacing.md
            readonly property real cellWidth: (width - spacing * 2) / 3

            Repeater {
              model: [{ label: "24 hours", days: 1 }, { label: "7 days", days: 7 }, { label: "30 days", days: 30 }]
              Button {
                required property var modelData
                width: filterRow.cellWidth
                text: modelData.label
                selected: root.filterDays === modelData.days
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.setFilter(modelData.days)
              }
            }
          }

          Text {
            visible: root.incidents.length === 0
            width: parent.width
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)
            text: "No performance issues in this time period."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            id: incidentRepeater
            model: root.incidents

            BorderSurface {
              id: incidentRow
              required property var modelData
              required property int index
              width: panelColumn.width
              implicitHeight: incidentContent.implicitHeight + Style.space(20)
              color: root.expandedId === String(modelData.id || "") ? Style.selectedFillFor(root.foreground, Color.accent) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
              borderSpec: Border.flat(root.cursorActive && root.selectedIndex === index ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16), 1)
              radius: Style.cornerRadius

              Column {
                id: incidentContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(10)
                spacing: Style.space(5)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(whenText.implicitHeight, durationText.implicitHeight)
                  Text {
                    id: whenText
                    anchors.left: parent.left
                    anchors.right: durationText.left
                    text: root.formatWhen(incidentRow.modelData.startTime)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    id: durationText
                    anchors.right: parent.right
                    text: root.formatDuration(incidentRow.modelData.durationSeconds)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  width: parent.width
                  text: String(incidentRow.modelData.severity || "low").toUpperCase() + "  ·  " + String(incidentRow.modelData.likelyCause || "Resource pressure")
                  color: root.severityColor(incidentRow.modelData)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Text {
                  visible: root.expandedId === String(incidentRow.modelData.id || "")
                  width: parent.width
                  topPadding: Style.space(5)
                  text: root.detailText(incidentRow.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: root.expandedId === String(incidentRow.modelData.id || "") && root.offenderRows(incidentRow.modelData).length > 0
                  width: parent.width
                  topPadding: Style.space(6)
                  text: "TOP OFFENDERS"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  model: root.expandedId === String(incidentRow.modelData.id || "") ? root.offenderRows(incidentRow.modelData) : []

                  Item {
                    required property var modelData
                    width: incidentContent.width
                    implicitHeight: Math.max(offenderName.implicitHeight, offenderUsage.implicitHeight)

                    Text {
                      id: offenderName
                      anchors.left: parent.left
                      anchors.right: offenderUsage.left
                      anchors.rightMargin: Style.space(8)
                      text: String(modelData.name || "Unknown") + "  ·  PID " + Number(modelData.pid || 0)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Text {
                      id: offenderUsage
                      anchors.right: parent.right
                      text: root.offenderUsage(modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: { root.cursorActive = true; root.selectedIndex = incidentRow.index }
                onClicked: {
                  root.selectedIndex = incidentRow.index
                  var id = String(incidentRow.modelData.id || "")
                  root.expandedId = root.expandedId === id ? "" : id
                }
              }
            }
          }

          PanelSeparator {
            visible: root.incidents.length > 0
            foreground: root.foreground
          }

          Button {
            width: parent.width
            text: root.clearArmed ? "Click again to clear all history" : "Clear history"
            bordered: true
            foreground: root.clearArmed ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.requestClear()
          }
        }
      }
    }
  }
}
