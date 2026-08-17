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
  property bool clearArmed: false
  property bool cursorActive: false
  property int selectedIndex: 0
  property double nowMs: Date.now()

  readonly property var incidents: filteredIncidents()
  readonly property var activeIncident: state && state.activeIncident && state.activeIncident.id ? state.activeIncident : null
  readonly property var displayRows: activeIncident ? [activeIncident].concat(incidents) : incidents
  readonly property int recentCount: countSince(24 * 3600 * 1000)
  readonly property bool hasActiveIncident: activeIncident !== null

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
      selectedIndex = Math.max(0, Math.min(selectedIndex, displayRows.length - 1))
      if (clearArmed && parsed.incidents.length === 0) clearArmed = false
    } catch (error) {
      console.warn("perfwatch", "Ignoring malformed state", error)
    }
  }

  function setFilter(days) {
    filterDays = days
    selectedIndex = 0
  }

  function select(delta) {
    if (displayRows.length === 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(displayRows.length - 1, selectedIndex + delta))
    var target = incidentRepeater.itemAt(selectedIndex)
    if (target) panelScroll.contentY = Math.max(0, Math.min(target.y, panelScroll.contentHeight - panelScroll.height))
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

  function isActive(row) {
    return activeIncident !== null && String(row && row.id || "") === String(activeIncident.id || "")
  }

  function causeText(row) {
    var causes = row && row.causes && typeof row.causes.length === "number" ? row.causes : []
    var peak = row && row.peak ? row.peak : {}
    var hasMemory = causes.indexOf("memory") !== -1
    var hasSwap = causes.indexOf("swap") !== -1
    var hasCpu = causes.indexOf("cpu") !== -1
    var hasIo = causes.indexOf("io") !== -1
    var text = "The system was under resource pressure."
    if (hasMemory && hasSwap) text = "The system ran low on readily available memory and started swapping, which caused the slowdown."
    else if (hasMemory) text = "Applications were waiting for memory, which caused the slowdown."
    else if (hasCpu) text = "The processor was fully occupied, so applications had to wait for CPU time."
    else if (hasIo && hasSwap) text = "Heavy swapping made storage a bottleneck and caused the slowdown."
    else if (hasIo) text = "Applications were waiting on storage, which caused the slowdown."
    var available = Number(peak.memoryAvailableMiB || 0)
    if ((hasMemory || hasSwap) && available > 0) text += " About " + Math.round(available) + " MiB was readily available at the worst point."
    return text
  }

  function memoryContributors(row) {
    var stored = row && row.memoryOffenders
    if (stored && typeof stored.length === "number") return stored
    var raw = row && row.offenders && row.offenders.preEvent && typeof row.offenders.preEvent.length === "number" ? row.offenders.preEvent : []
    var seen = {}
    var result = []
    for (var i = 0; i < raw.length; i++) {
      var item = raw[i]
      var key = String(item.name || "Unknown")
      if (seen[key] === undefined) {
        seen[key] = result.length
        result.push({
          name: key === "node" ? "Node development task" : key,
          processCount: Number(item.processCount || 1),
          rssMiB: Number(item.rssMiB || 0),
        })
      } else {
        var existing = result[seen[key]]
        existing.rssMiB += Number(item.rssMiB || 0)
        existing.processCount += Number(item.processCount || 1)
      }
    }
    result.sort(function(left, right) { return right.rssMiB - left.rssMiB })
    return result.slice(0, 3)
  }

  function memoryUsage(row) {
    var memory = Number(row.rssMiB || 0)
    var amount = memory >= 1024 ? (memory / 1024).toFixed(1) + " GiB" : Math.round(memory) + " MiB"
    var count = Number(row.processCount || 1)
    return amount + (count > 1 ? " across " + count + " processes" : "")
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
    active: root.hasActiveIncident
    tooltipText: root.hasActiveIncident ? "Performance pressure active: " + String(root.activeIncident.likelyCause || "Resource pressure") : (root.recentCount > 0 ? root.recentCount + " recovered incident" + (root.recentCount === 1 ? "" : "s") + " in 24 hours" : "No active performance pressure")
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
      onActivateRequested: function() {}
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
            meta: root.hasActiveIncident ? "PRESSURE ACTIVE NOW" : (root.recentCount > 0 ? root.recentCount + " recovered in the last 24 hours" : "No incidents in the last 24 hours")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰓅"
                color: root.hasActiveIncident ? root.urgent : root.foreground
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
            visible: root.displayRows.length === 0
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
            model: root.displayRows

            BorderSurface {
              id: incidentRow
              required property var modelData
              required property int index
              width: panelColumn.width
              implicitHeight: incidentContent.implicitHeight + Style.space(20)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
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
                    anchors.rightMargin: Style.space(8)
                    text: root.isActive(incidentRow.modelData) ? "Happening now" : root.formatWhen(incidentRow.modelData.startTime)
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
                  text: (root.isActive(incidentRow.modelData) ? "LIVE  ·  " : "") + String(incidentRow.modelData.severity || "moderate").toUpperCase() + (root.isActive(incidentRow.modelData) ? "" : "  ·  Recovered")
                  color: root.isActive(incidentRow.modelData) ? root.urgent : root.severityColor(incidentRow.modelData)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  topPadding: Style.space(5)
                  text: "CAUSE"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: root.causeText(incidentRow.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Column {
                  width: parent.width
                  visible: root.memoryContributors(incidentRow.modelData).length > 0
                  spacing: Style.space(6)

                  Text {
                    width: parent.width
                    topPadding: Style.space(6)
                    text: "BIGGEST MEMORY USERS"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Repeater {
                    model: root.memoryContributors(incidentRow.modelData)

                    Item {
                      required property var modelData
                      width: incidentContent.width
                      implicitHeight: Math.max(contributorName.implicitHeight, contributorUsage.implicitHeight)

                      Text {
                        id: contributorName
                        anchors.left: parent.left
                        anchors.right: contributorUsage.left
                        anchors.rightMargin: Style.space(8)
                        text: String(modelData.name || "Unknown")
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      Text {
                        id: contributorUsage
                        anchors.right: parent.right
                        text: root.memoryUsage(modelData)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
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
