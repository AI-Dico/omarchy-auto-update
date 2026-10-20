import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon for Auto Update. It runs the background check on a timer and only
// shows itself when there is something to say: updates ready, or something
// that needs the user. A click opens the overlay with the details.
BarWidget {
  id: root
  moduleName: "io.github.ai-dico.auto-update"

  readonly property string pluginId: "io.github.ai-dico.auto-update"
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-auto-update")).replace(/^file:\/\//, ""))
  property var status: ({ state: "unknown", count: 0 })

  readonly property bool hasNews: !!(status && status.news)
  readonly property bool running: !!(status && status.run)
  readonly property bool showIcon: running || status.state === "ready" || status.state === "attention" || hasNews

  function refresh() {
    if (!checkProc.running) checkProc.running = true
  }

  function reload() {
    if (!statusProc.running) statusProc.running = true
  }

  function openDetails() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, "{}"])
  }

  function glyph() {
    if (running) return "\udb81\udc50"                                   // updating
    if (status.state === "attention" || hasNews) return "󰀦"   // alert circle
    if (status.tier === "restart" || status.tier === "major") return "󰜉" // restart
    return "󰇚"                                                 // download
  }

  function tooltip() {
    if (running) return "Updating… click to see progress"
    if (hasNews && status.state !== "ready") return "Arch news to read before updating"
    if (status.state === "attention") return status.message || "Updates need your attention"
    var n = status.count || 0
    var what = n === 1 ? "1 update" : n + " updates"
    if (status.tier === "major") return "A new version of Omarchy is ready"
    if (status.tier === "restart") return what + " ready · restart to finish"
    return what + " ready"
  }

  visible: showIcon
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.ai-dico.auto-update.bar"
    function refresh(): void { root.broadcast("refresh") }
    function reload(): void { root.broadcast("reload") }
  }

  Process {
    id: checkProc
    command: [root.helper, "run"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { root.reload() }
      }
    }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { }
      }
    }
  }

  // Show what the last run found right away, then check a few minutes after
  // login (so it never competes with startup) and every six hours after that.
  Component.onCompleted: root.reload()

  Timer {
    interval: 180000
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 21600000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // The overlay and the helper write the same state file; pick up its changes.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.reload()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph()
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip()
    onPressed: root.openDetails()
  }
}
