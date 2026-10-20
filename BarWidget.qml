import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon for Auto Update. It runs the background check on a timer and only
// shows itself when there is something to say: updates ready, or something
// that needs the user. A click opens the overlay with the details.
//
// The "Bar icon" setting (status.iconMode) can hide the icon for plain "ready"
// sets or always. Hiding only turns `visible` off: this widget keeps running the
// checks, and asks the helper to notify about what the icon can't show.
BarWidget {
  id: root
  moduleName: "io.github.ai-dico.auto-update"

  readonly property string pluginId: "io.github.ai-dico.auto-update"
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-auto-update")).replace(/^file:\/\//, ""))
  property var status: ({ state: "unknown", count: 0 })

  readonly property bool hasNews: !!(status && status.news)
  readonly property bool running: !!(status && status.run)
  readonly property bool restartPending: !!(status && status.restartPending)
  readonly property bool showIcon: running || restartPending || status.state === "ready" || status.state === "attention" || hasNews
  // What still shows in "Only when important": everything but a set that is just ready.
  readonly property bool importantIcon: running || restartPending || status.state === "attention" || hasNews
  readonly property string iconMode: (status && status.iconMode) || "shown"
  readonly property bool iconVisible: iconMode === "hidden" ? false : iconMode === "important" ? importantIcon : showIcon
  // Warnings keep the warning glyph; everything else about updates is the rocket.
  readonly property bool warning: !running && !restartPending && (status.state === "attention" || hasNews)
  // Keep in step with SHOWS_JQ in bin/omarchy-auto-update.
  readonly property string notifyKey: (status && status.notifyKey) || ""
  property string notifiedKey: ""

  function refresh() {
    if (!checkProc.running) checkProc.running = true
  }

  function reload() {
    if (!statusProc.running) statusProc.running = true
  }

  // The helper decides from its saved keys whether this is new and whether the
  // icon already shows it, so a reload or a shell restart never repeats it.
  // While the icon is hidden it is asked again on every reload: a notification
  // that couldn't be delivered is not remembered there, and goes out next time.
  function maybeNotify() {
    if (root.notifyKey === "") return
    if (root.notifyKey === root.notifiedKey && root.iconVisible) return
    root.notifiedKey = root.notifyKey
    Quickshell.execDetached([root.helper, "notify"])
  }
  function openDetails() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, "{}"])
  }

  // Only warnings use a font glyph now; every other state draws RocketIcon.
  readonly property string warningGlyph: "󰀦"   // alert circle

  function tooltip() {
    if (running) return "Updating… click to see progress"
    if (restartPending) return "Updates will install when you restart"
    if (hasNews && status.state !== "ready") return "Arch news to read before updating"
    if (status.state === "attention") return status.message || "Updates need your attention"
    var n = status.count || 0
    var what = n === 1 ? "1 update" : n + " updates"
    if (status.tier === "major") return "A new version of Omarchy is ready"
    if (status.tier === "restart") return what + " ready · restart to finish"
    return what + " ready"
  }

  visible: iconVisible
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
      // `run` prints only the check; `status` adds what waits for a restart.
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { }
        root.reload()
      }
    }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { return }
        root.maybeNotify()
      }
    }
  }

  // Adds Update › Auto Update to the Omarchy menu, the way in when the icon is
  // hidden. Runs at every start so plugin installs and updates both get it; the
  // helper writes nothing when the entry is current or the user took it out.
  Process {
    id: menuProc
    command: [root.helper, "menu-install", "--auto"]
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("omarchy-auto-update menu-install:", text.trim())
    }
  }
  // Show what the last run found right away, then check a few minutes after
  // login (so it never competes with startup) and every six hours after that.
  Component.onCompleted: {
    root.reload()
    menuProc.running = true
  }

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
    text: root.warning ? root.warningGlyph : ""
    iconComponent: root.warning ? null : rocket
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip()
    onPressed: root.openDetails()
  }
  Component {
    id: rocket
    RocketIcon { color: button.foreground }
  }
}
