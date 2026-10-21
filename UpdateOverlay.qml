import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
// Qt 6.12 has its own Color type; the shell palette must be qualified.
import qs.Commons as Commons
import qs.Ui

// Auto Update details: what is ready, why it needs a restart, Arch news to
// read first, and the packages in the set. Everything is read from the helper's
// state file; this overlay never touches the system itself.
Item {
  id: root
  property var shell: null
  property var manifest: null

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-auto-update")).replace(/^file:\/\//, ""))

  property bool opened: false
  property var status: ({ state: "unknown", packages: [], count: 0 })
  property bool showPackages: false

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color subtle: Commons.Color.menu.selectedBackground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int pad: Style.spacing.panelPadding

  readonly property bool busy: status.state === "checking" || status.state === "downloading" || checkProc.running
  readonly property bool ready: status.state === "ready" && !restartPending
  // Staged by bin/omarchy-auto-update-offline; installs on the next restart.
  readonly property bool restartPending: !!status.restartPending
  readonly property bool restartTier: status.tier === "restart" || status.tier === "major"

  // details → password → running → done, or applied after an update that
  // installed on restart. The work runs in bin/omarchy-auto-update-runner
  // (update now, stage for restart, finish after it); this only shows events.
  property string view: "details"
  property string runKind: "update"
  property var after: null
  // The last update installed on restart, for the "installed" view.
  property var installed: null
  // Set by the note's Open; any other opening or closing cancels it.
  property bool installedWanted: false
  // Going back to the restore point taken before that update: whether it can
  // (rollback-info), the try this boot is part of (snapshot-state), and the
  // view to return to from the confirmation.
  property var rollback: null
  property var trying: null
  property string beforeConfirm: "installed"
  property string rollbackError: ""
  readonly property string runner: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-auto-update-runner")).replace(/^file:\/\//, ""))
  property bool awaitingPassword: false
  // Typed before the runner finished re-checking the set; sent when it asks.
  property bool passwordQueued: false
  // Sent and being checked; nothing more to type until the runner asks again.
  property bool passwordSent: false
  property bool passwordRetry: false
  property string phaseLabel: ""
  property int stepDone: 0
  property int stepTotal: 0
  property string stepLabel: ""
  property var logLines: []
  property bool showLog: false
  property var result: null
  property string eventsPath: ""

  function open(payloadJson) {
    root.opened = true
    root.showPackages = false
    // A finished run stays on screen until dismissed; an idle overlay starts fresh.
    if (!runProc.running && !tailProc.running && root.view !== "done" && root.view !== "applied" && root.view !== "trying") root.view = "details"
    // From the note after an update installed on restart: what it changed.
    var payload = null
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { }
    // In a restore point we restarted into, opening is how the user decides.
    if (root.trying && root.view === "details") root.view = "trying"
    else if (root.view === "details" && !rollbackProc.running) rollbackProc.running = true
    root.installedWanted = !!payload && typeof payload === "object" && payload.view === "installed" && root.view === "details"
    if (root.installedWanted && !installedProc.running) installedProc.running = true
    root.reload()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() { root.opened = false; root.installedWanted = false }

  function dismiss() {
    root.opened = false
    root.installedWanted = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.ai-dico.auto-update")
  }

  function toggle() { root.opened ? root.dismiss() : root.open("{}") }

  function reload() { if (!statusProc.running) statusProc.running = true }

  function checkNow() {
    if (checkProc.running) return
    root.status = Object.assign({}, root.status, { state: "checking", message: "Checking for updates" })
    checkProc.running = true
  }

  function updateNow() { root.startRun("update", [root.runner, root.fingerprint(root.status)]) }

  // Installs on the next restart: the password is asked now, while the user is here.
  function restartToUpdate() { root.startRun("stage", [root.runner, "--stage", root.fingerprint(root.status)]) }

  function startRun(kind, command) {
    if (runProc.running) { root.view = root.runKind === "stage" ? "password" : "running"; return }
    root.runKind = kind
    root.view = "password"
    root.awaitingPassword = false
    root.passwordQueued = false
    root.passwordSent = false
    root.passwordRetry = false
    root.phaseLabel = ""
    root.stepDone = 0
    root.stepTotal = 0
    root.stepLabel = ""
    root.logLines = []
    root.showLog = false
    root.result = null
    passwordField.text = ""
    // The runner re-plans and installs only if this exact set is still pending.
    runProc.command = command
    runProc.running = true
    Qt.callLater(function() { passwordField.forceActiveFocus() })
  }

  function submitPassword() {
    if (passwordField.text === "") return
    if (!root.awaitingPassword) { root.passwordQueued = true; return }
    root.passwordQueued = false
    root.passwordSent = true
    root.awaitingPassword = false
    runProc.write(passwordField.text + "\n")
    passwordField.text = ""
  }

  // Written by the helper with the set; the runner installs only if unchanged.
  function fingerprint(st) { return String(st.fingerprint || "") }

  function cancelUpdate() {
    passwordField.text = ""
    root.passwordQueued = false
    root.passwordSent = false
    if (runProc.running && root.view === "password") runProc.running = false
    root.view = "details"
  }

  function finishRun() {
    tailProc.running = false
    Quickshell.execDetached([root.helper, "ack-run"])
    // A finish that failed is offered again at the next login.
    if (root.runKind === "finish" && root.result && root.result.ok) Quickshell.execDetached([root.helper, "ack-applied"])
    root.view = "details"
    root.result = null
    root.runKind = "update"
    root.checkNow()
  }

  // First login after an update installed on restart: check the session, then
  // finish Omarchy's own steps. Opens only when something needs the user.
  function afterRestart(info) {
    root.after = info
    var applied = root.status.applied
    if (!applied || !info.id) return
    if (!applied.ok || !info.ok || (applied.warnings || []).length > 0) {
      root.view = "applied"
      root.open("{}")
      return
    }
    root.finishUpdate(info.needsPassword)
  }

  function finishUpdate(needsPassword) {
    if (needsPassword) {
      root.startRun("finish", [root.runner, "--finish", "--password"])
      root.open("{}")
    } else {
      root.runKind = "finish"
      root.result = null
      runProc.command = [root.runner, "--finish"]
      runProc.running = true
    }
  }

  function keepUsing() {
    var info = root.after || {}
    if (root.status.applied && root.status.applied.ok) {
      root.view = "details"
      root.finishUpdate(!!info.needsPassword)
      if (!info.needsPassword) root.dismiss()
    } else {
      Quickshell.execDetached([root.helper, "ack-applied"])
      root.view = "details"
      root.dismiss()
      root.checkNow()
    }
  }

  function snapshotDate() {
    var a = root.status.applied
    return a && a.at ? new Date(a.at * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat) : ""
  }

  // Follows the event file of an update that runs on its own (it survives
  // shell restarts, and Omarchy's updater restarts the shell near the end).
  function follow(path) {
    if (!path) return
    root.eventsPath = path
    root.view = "running"
    root.logLines = []
    tailProc.running = false
    tailProc.command = ["tail", "-n", "+1", "-F", path]
    tailProc.running = true
  }

  function onRunnerEvent(line) {
    var e
    try { e = JSON.parse(line) } catch (err) { return }
    if (e.type === "detached") {
      // A finish that needs nothing from the user runs out of sight.
      if (root.runKind === "finish" && root.view !== "password") {
        root.eventsPath = e.events
        tailProc.command = ["tail", "-n", "+1", "-F", e.events]
        tailProc.running = true
        return
      }
      root.follow(e.events)
    } else if (e.type === "changed") {
      root.passwordQueued = false
      passwordField.text = ""
      root.view = "details"
      root.reload()
      root.status = Object.assign({}, root.status, { message: "The updates changed since you looked. Please review them again." })
    } else if (e.type === "password") {
      root.awaitingPassword = true
      root.passwordSent = false
      root.passwordRetry = !!e.retry
      root.view = "password"
      if (root.passwordQueued && !e.retry) { root.submitPassword(); return }
      root.passwordQueued = false
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    } else if (e.type === "phase") {
      root.view = "running"
      root.phaseLabel = e.label
      if (e.id !== "install") { root.stepTotal = 0; root.stepLabel = "" }
    } else if (e.type === "progress") {
      root.stepDone = e.done
      root.stepTotal = e.total
      root.stepLabel = e.label
    } else if (e.type === "log") {
      var l = root.logLines.slice(-199)
      l.push(e.line)
      root.logLines = l
    } else if (e.type === "done") {
      root.result = e
      root.awaitingPassword = false
      root.passwordQueued = false
      root.passwordSent = false
      passwordField.text = ""
      tailProc.running = false
      if (e.finished && e.needsPassword) {
        root.finishUpdate(true)
        return
      }
      if (e.finished && !e.ok && !root.opened) {
        // Offered again at the next login; nothing to show now.
        tailProc.running = false
        Quickshell.execDetached([root.helper, "ack-run"])
        root.runKind = "update"
        return
      }
      if (e.finished && e.ok && !root.opened) {
        // Nothing left to say beyond a short note.
        var a = root.status.applied || {}
        root.finishRun()
        var n = a.count || 0
        var body = "Installed while restarting."
        if (a.bootMenu)
          body += " A restore point was saved. If something seems wrong, pick it under Snapshots in the boot menu."
        // notify-send waits for a click on its own; a click opens this overlay.
        Quickshell.execDetached(["bash", "-c",
          '[[ $(notify-send -a "Auto Update" -t 15000 -A default=Open -- "$1" "$2") == default ]] && ' +
          'omarchy-shell shell summon io.github.ai-dico.auto-update \'{"view":"installed"}\'',
          "notify", (n === 1 ? "1 update installed" : n + " updates installed"), body])
        return
      }
      root.view = e.cancelled ? "details" : "done"
      if (e.staged && e.ok) root.reload()
    }
  }

  // "Bar icon" setting. The helper saves it; the bar picks it up on reload.
  readonly property string iconMode: status.iconMode === "shown" ? "updates" : (status.iconMode || "updates")

  function setIconMode(mode) {
    if (mode === root.iconMode || configProc.running) return
    root.status = Object.assign({}, root.status, { iconMode: mode })
    configProc.command = [root.helper, "config", "set", "icon-mode", mode]
    configProc.running = true
  }

  function readNews() {
    var link = root.status.news ? String(root.status.news.link || "") : ""
    if (link.indexOf("https://archlinux.org/news/") !== 0) return
    Quickshell.execDetached(["xdg-open", link])
  }

  function ackNews() {
    Quickshell.execDetached([root.helper, "ack-news"])
    var s = Object.assign({}, root.status)
    delete s.news
    root.status = s
  }

  function mb(bytes) {
    if (!bytes) return ""
    var v = bytes / 1048576
    return v >= 1024 ? (v / 1024).toFixed(1) + " GB" : Math.max(1, Math.round(v)) + " MB"
  }

  function ago(epoch) {
    if (!epoch) return ""
    var d = Math.floor(Date.now() / 1000) - epoch
    if (d < 60) return "just now"
    if (d < 3600) return Math.floor(d / 60) + " min ago"
    if (d < 86400) return Math.floor(d / 3600) + " h ago"
    return Math.floor(d / 86400) + " days ago"
  }

  function title() {
    if (restartPending) {
      var n = status.restartPending.count || 0
      return (n === 1 ? "1 update" : n + " updates") + " will install when you restart"
    }
    switch (status.state) {
      case "checking": return "Checking for updates…"
      case "downloading": return "Downloading updates…"
      case "uptodate": return "Omarchy is up to date"
      case "waiting": return "Updates found"
      case "attention": return "Updates need your attention"
      case "error": return "Couldn't prepare updates"
      case "ready":
        if (status.tier === "major") return "A new version of Omarchy is ready"
        return status.count === 1 ? "1 update is ready" : status.count + " updates are ready"
    }
    return "Auto Update"
  }

  function subtitle() {
    if (restartPending) return "Your computer saves a restore point, installs them and starts again."
    if (status.state === "ready") {
      var parts = []
      parts.push(status.verified ? "Downloaded and verified" : status.downloaded ? "Downloaded" : "Found")
      if (status.downloadBytes) parts.push(mb(status.downloadBytes))
      return parts.join(" · ")
    }
    // The helper often sends the title itself as the message ("Omarchy is up to date").
    var m = status.message || ""
    return m === title() ? "" : m
  }

  // Plain-language reason for the tier, with the packages that caused it.
  function tierText() {
    if (status.tier === "major" && status.omarchy)
      return "Omarchy " + status.omarchy.from.split("-")[0] + " → " + status.omarchy.to.split("-")[0] + ". Finishes with a restart."
    if (status.tier === "restart") {
      var names = (status.restartReasons || []).slice(0, 4).join(", ")
      var more = (status.restartReasons || []).length > 4 ? " and more" : ""
      return "Includes core parts of the system (" + names + more + "). Finishes with a restart."
    }
    return "Small update. No restart needed."
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { return }
        var p = Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-auto-update/run.jsonl"
        if (root.status.run && !tailProc.running && !runProc.running) root.follow(p)
      }
    }
  }

  Process {
    id: checkProc
    command: [root.helper, "run", "--force"]
    stdout: StdioCollector {
      // `run` prints only the check; `status` adds what waits for a restart.
      onStreamFinished: { try { root.status = JSON.parse(text) } catch (e) { } root.reload() }
    }
    onExited: Quickshell.execDetached(["omarchy-shell", "io.github.ai-dico.auto-update.bar", "reload"])
  }

  Process {
    id: configProc
    // Read back what was saved (a failed write shows the old choice again),
    // then tell the bar so the icon follows right away.
    onExited: {
      root.reload()
      Quickshell.execDetached(["omarchy-shell", "io.github.ai-dico.auto-update.bar", "reload"])
    }
  }

  Process {
    id: runProc
    command: [root.runner]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onRunnerEvent(line) } }
    // Exiting without handing over to a background run means it never started.
    onExited: function(code) {
      root.awaitingPassword = false
      root.passwordQueued = false
      root.passwordSent = false
      passwordField.text = ""
      if (root.view === "password" && code !== 0 && !root.result) root.view = "details"
    }
  }

  Process {
    id: tailProc
    stdout: SplitParser { onRead: function(line) { root.onRunnerEvent(line) } }
  }

  function appliedTitle() {
    var a = root.status.applied || {}
    if (a.state === "partial") return "The update didn't finish"
    if (!a.ok) return a.state === "skipped" ? "The updates weren't installed" : "The updates couldn't be installed"
    if (root.after && !root.after.ok) return "Something didn't start right after the update"
    return "The update finished with warnings"
  }

  function installedTitle() {
    var n = (root.installed && root.installed.count) || 0
    if (root.installed && root.installed.state === "partial") return "The update didn't finish"
    return n === 1 ? "1 update installed" : n + " updates installed"
  }

  function installedText() {
    var a = root.installed || {}
    var when = a.at ? new Date(a.at * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat) : ""
    if (a.state === "partial")
      return (a.message ? a.message + " " : "") + "Started while restarting" + (when ? " on " + when : "") + "."
    return "Installed while restarting" + (when ? " on " + when : "") + "."
  }

  function installedRestore() {
    var a = root.installed || {}
    if (!a.bootMenu) return "No restore point was saved for this update."
    if (root.rollback && root.rollback.available)
      return "If something seems wrong since then, choose Go back to try how it was before, without changing anything for good."
    return "If something seems wrong since then, you can go back: restart, choose Snapshots in the boot menu "
      + "and pick the latest one. When it has started, choose Restore."
  }

  function rollbackDate() {
    var at = (root.rollback && root.rollback.at) || (root.trying && root.trying.at) || 0
    return at ? new Date(at * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat) : ""
  }

  function confirmRollback() {
    root.beforeConfirm = root.view
    root.rollbackError = ""
    root.view = "rollback-confirm"
  }

  function confirmText() {
    var n = (root.rollback && root.rollback.count) || 0
    return "Your computer restarts into how it was on " + root.rollbackDate() + ", before "
      + (n === 1 ? "this update" : "these " + n + " updates") + ". Your files and settings stay as they are. "
      + "Nothing is changed for good: from there you can come back to the updated version. "
      + "Choosing the restore point asks for your password once."
  }

  function tryingText() {
    if (root.trying && root.trying.phase === "returning")
      return "Your computer started this restore point again. Choose Back once more: this time it asks for your password to pick the updated version."
    var n = (root.trying && root.trying.count) || 0
    return "Nothing has changed for good yet. This is your computer as it was on " + root.rollbackDate() + ", before "
      + (n === 1 ? "the update" : "the " + n + " updates") + ", and your files and settings are as you left them. "
      + "Use it as long as you like. Return to the updated version, or undo the update only if this one works better."
  }

  function appliedText() {
    var a = root.status.applied || {}
    var restore = a.snapshots && Object.keys(a.snapshots).length > 0
    if (!a.ok && a.state !== "partial")
      return (a.message || "") + (restore && a.state !== "skipped" ? " A restore point was saved first." : "")
    var lead = a.state === "partial" ? (a.message || "") + " "
      : (root.after && !root.after.ok) ? ""
      : "Some finishing steps reported errors, so the computer may not start next time. "
    if (!restore || !a.bootMenu)
      return lead + "No restore point is available for this update. If something keeps failing, run Omarchy's updater."
    return lead + "To go back to how it was before " + root.snapshotDate() + ", restart, choose Snapshots in the boot menu and pick the latest one. "
      + "When it has started, choose Restore."
  }

  Process {
    id: installedProc
    command: [root.helper, "last-applied"]
    stdout: StdioCollector {
      onStreamFinished: {
        var a = null
        try { a = JSON.parse(text) } catch (e) { }
        if (!a || !(a.ok || a.state === "partial") || !root.installedWanted) return
        root.installedWanted = false
        root.installed = a
        if (root.view === "details") root.view = "installed"
      }
    }
  }

  Process {
    id: afterProc
    command: [root.helper, "after-restart"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.afterRestart(JSON.parse(text)) } catch (e) { } }
    }
  }

  // Wait for the session to settle before judging it.
  Timer {
    id: afterTimer
    interval: 45000
    running: true
    onTriggered: if (root.status.applied && !afterProc.running) afterProc.running = true
  }

  Component.onCompleted: root.reload()

  // A restore point we restarted into: say so, a little after login.
  Timer {
    interval: 3000
    running: true
    onTriggered: snapshotProc.running = true
  }
  Process {
    id: snapshotProc
    command: [root.helper, "snapshot-state"]
    stdout: StdioCollector {
      onStreamFinished: {
        var st = null
        try { st = JSON.parse(text) } catch (e) { return }
        if (st.inSnapshot && st.ours) {
          // No pop-up: deciding takes using it for a while. A note says so;
          // the bar icon opens the decision whenever the user is ready.
          root.trying = st
          if (root.opened) root.view = "trying"
          else Quickshell.execDetached(["bash", "-c",
            '[[ $(notify-send -a "Auto Update" -t 20000 -A default=Open -- "$1" "$2") == default ]] && ' +
            'omarchy-shell shell summon io.github.ai-dico.auto-update "{}"', "notify",
            "Trying the version from before the update",
            "Use it as long as you like. When you've decided, click the update icon in the bar to keep it or return to the updated version."])
        } else if (st.missed) {
          Quickshell.execDetached(["notify-send", "-a", "Auto Update", "-t", "15000",
            "Couldn't open the restore point",
            "Your computer started normally, with the updates. You can still go back from the boot menu: choose Snapshots and pick the latest one."])
        }
      }
    }
  }
  Process {
    id: rollbackProc
    command: [root.helper, "rollback-info"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.rollback = JSON.parse(text) } catch (e) { root.rollback = null } }
    }
  }
  // What can be tried is read whenever a view that offers it opens.
  onViewChanged: if ((root.view === "installed" || root.view === "applied") && !rollbackProc.running) rollbackProc.running = true
  Process {
    id: tryProc
    command: [root.helper, "try-restore"]
    stderr: StdioCollector { id: tryErr }
    onExited: function(code) {
      // On success the computer is already restarting.
      if (code !== 0) root.rollbackError = "Couldn't restart into the restore point: "
        + (tryErr.text.replace(/^omarchy-auto-update: /, "").trim() || "unknown error") + "."
    }
  }
  Process {
    id: returnProc
    command: [root.helper, "return-updated"]
    stderr: StdioCollector { id: returnErr }
    onExited: function(code) {
      if (code !== 0) root.rollbackError = returnErr.text.replace(/^omarchy-auto-update: /, "").trim()
        || "Couldn't restart into the updated version. Restart and pick it in the boot menu."
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-auto-update"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(panel.width - Style.gapsOut * 4, Style.space(560))
      height: Math.min(panel.height - Style.gapsOut * 4,
        (root.view === "details" ? content.implicitHeight : runView.implicitHeight) + card.contentTopInset + card.contentBottomInset)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.pad

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.view === "password") root.cancelUpdate()
            else root.dismiss()
            event.accepted = true
          }
          else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.ready && root.view === "details") {
            root.restartTier ? root.restartToUpdate() : root.updateNow()
            event.accepted = true
          }
        }
      }

      Column {
        id: content
        visible: root.view === "details"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.xxl

        // Header
        Row {
          width: parent.width
          spacing: Style.spacing.xl
          Text {
            id: icon
            anchors.verticalCenter: parent.verticalCenter
            text: root.status.state === "uptodate" ? "󰄴"
                : (root.status.state === "attention" || root.status.state === "error") ? "󰀦"
                : root.busy ? "󰑐" : root.restartPending ? "󰜉" : "󰇚"
            color: (root.status.state === "attention" || root.status.state === "error") ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            RotationAnimation on rotation {
              running: root.busy && root.opened
              from: 0; to: 360; duration: 1200; loops: Animation.Infinite
              onRunningChanged: if (!running) icon.rotation = 0
            }
          }
          Column {
            width: parent.width - icon.width - Style.spacing.xl
            spacing: Style.spacing.xs
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.title()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.Wrap
            }
            Text {
              width: parent.width
              visible: text !== ""
              textFormat: Text.PlainText
              text: root.subtitle()
              color: root.foreground
              opacity: 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
          }
        }

        // Why it needs a restart (or not)
        Rectangle {
          visible: root.ready
          width: parent.width
          height: tierLabel.implicitHeight + Style.spacing.xl * 2
          radius: root.cornerRadius
          color: root.subtle
          Text {
            id: tierLabel
            anchors.fill: parent
            anchors.margins: Style.spacing.xl
            textFormat: Text.PlainText
            text: root.tierText()
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            verticalAlignment: Text.AlignVCenter
          }
        }

        // Arch news to read first
        Rectangle {
          visible: !!root.status.news
          width: parent.width
          height: newsCol.implicitHeight + Style.spacing.xl * 2
          radius: root.cornerRadius
          color: "transparent"
          border.width: Math.max(1, Style.space(1))
          border.color: root.urgent
          Column {
            id: newsCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.xl
            spacing: Style.spacing.md
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Arch news to read before updating"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.status.news ? root.status.news.title : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
            Row {
              spacing: Style.spacing.md
              Button { text: "Read"; bordered: true; onClicked: root.readNews() }
              Button { text: "I've read it"; onClicked: root.ackNews() }
            }
          }
        }

        // Package list, collapsed by default
        Column {
          visible: root.ready && (root.status.packages || []).length > 0
          width: parent.width
          spacing: Style.spacing.sm
          Button {
            text: (root.showPackages ? "Hide" : "Show") + " what's included"
            iconText: root.showPackages ? "󰅀" : "󰅂"
            onClicked: root.showPackages = !root.showPackages
          }
          ListView {
            visible: root.showPackages
            width: parent.width
            height: Math.min(contentHeight, Style.space(220))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.status.packages || []
            delegate: Item {
              required property var modelData
              width: ListView.view.width
              height: Style.space(24)
              readonly property bool core: (root.status.restartReasons || []).indexOf(modelData.name) >= 0
              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.5
                textFormat: Text.PlainText
                text: (core ? "● " : "  ") + modelData.name
                color: core ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.5
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: (modelData.from ? modelData.from + " → " : "new ") + modelData.to
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideLeft
              }
            }
          }
        }

        // Settings
        Column {
          width: parent.width
          spacing: Style.spacing.sm
          // Four choices don't fit beside the label, so they sit under it.
          Column {
            id: iconModeBox
            width: parent.width
            spacing: Style.spacing.sm
            Text {
              textFormat: Text.PlainText
              text: "Bar icon"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            // One row when the four fit the card; otherwise two rows of two, so a
            // narrow screen or a large font never pushes them past the edge.
            readonly property var iconModes: [
              { value: "always", label: "Always", tooltip: "Keep the icon on the bar, even when Omarchy is up to date" },
              { value: "updates", label: "With updates", tooltip: "Show the icon whenever there is something to say" },
              { value: "important", label: "Important only", tooltip: "Hide it while updates just wait to be installed" },
              { value: "hidden", label: "Hidden", tooltip: "Never show the icon" }
            ]
            readonly property bool oneRow: iconModeGroup.implicitWidth <= width
            ButtonGroup {
              id: iconModeGroup
              visible: iconModeBox.oneRow
              options: iconModeBox.iconModes
              value: root.iconMode
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onChanged: function(v) { root.setIconMode(v) }
            }
            Repeater {
              model: iconModeBox.oneRow ? [] : [iconModeBox.iconModes.slice(0, 2), iconModeBox.iconModes.slice(2)]
              ButtonGroup {
                required property var modelData
                options: modelData
                value: root.iconMode
                foreground: root.foreground
                background: root.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onChanged: function(v) { root.setIconMode(v) }
              }
            }
          }
          Text {
            visible: root.iconMode === "important" || root.iconMode === "hidden"
            width: parent.width
            textFormat: Text.PlainText
            text: "When the icon is hidden, a notification tells you about new updates. "
              + "You can always open Auto Update from the Omarchy menu under Update."
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
        }

        // The last update installed on restart, while its restore point is
        // there to go back to: the way to the installed view after the note.
        Item {
          visible: !!root.rollback && root.rollback.available
          width: parent.width
          height: lastShow.implicitHeight
          Text {
            anchors.left: parent.left
            anchors.right: lastShow.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: {
              var n = (root.rollback && root.rollback.count) || 0
              return "Last update: " + (n === 1 ? "1 package" : n + " packages") + " on " + root.rollbackDate()
            }
            color: root.foreground
            opacity: 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Button {
            id: lastShow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Show"
            onClicked: { root.installedWanted = true; if (!installedProc.running) installedProc.running = true }
          }
        }

        // Actions
        Item {
          width: parent.width
          height: actions.implicitHeight
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.status.checkedAt ? "Checked " + root.ago(root.status.checkedAt) : ""
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Row {
            id: actions
            anchors.right: parent.right
            spacing: Style.spacing.md
            Button {
              text: "Check now"
              enabled: !root.busy
              onClicked: root.checkNow()
            }
            Button {
              visible: (root.ready && !root.restartTier) || (root.status.state === "attention" && !root.restartPending)
              text: "Update now"
              iconText: "󰇚"
              bordered: true
              selected: true
              onClicked: root.updateNow()
            }
            Button {
              visible: root.ready && root.restartTier
              text: "Restart to update"
              iconText: "󰜉"
              bordered: true
              selected: true
              onClicked: root.restartToUpdate()
            }
            Button {
              visible: root.restartPending
              text: "Restart now"
              iconText: "󰜉"
              bordered: true
              selected: true
              onClicked: Quickshell.execDetached(["systemctl", "reboot"])
            }
            Button {
              text: "Close"
              onClicked: root.dismiss()
            }
          }
        }
      }
      // Password, progress and result of a running update.
      Column {
        id: runView
        visible: root.view !== "details"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.xxl

        Row {
          width: parent.width
          spacing: Style.spacing.xl
          Text {
            id: runIcon
            anchors.verticalCenter: parent.verticalCenter
            text: (root.view === "rollback-confirm" || root.view === "trying") ? "󰜉"
                : root.view === "installed" ? "\udb80\udd34"
                : (root.view === "password" && !root.passwordSent) ? "\udb80\udf3e"
                : root.view === "password" ? "\udb81\udc50"
                : root.view === "running" ? "\udb81\udc50"
                : (root.result && root.result.ok) ? "\udb80\udd34" : "\udb80\udc26"
            color: (root.view === "done" && root.result && !root.result.ok) ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            RotationAnimation on rotation {
              running: (root.view === "running" || (root.view === "password" && root.passwordSent)) && root.opened
              from: 0; to: 360; duration: 1200; loops: Animation.Infinite
              onRunningChanged: if (!running) runIcon.rotation = 0
            }
          }
          Column {
            width: parent.width - runIcon.width - Style.spacing.xl
            spacing: Style.spacing.xs
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.view === "applied" ? root.appliedTitle()
                  : root.view === "installed" ? root.installedTitle()
                  : root.view === "rollback-confirm" ? "Go back to before this update?"
                  : root.view === "trying" ? "You're trying the version from before the update"
                  : (root.view === "password" && root.passwordSent) ? (root.runKind === "stage" ? "Getting ready for the restart…" : "Checking your password…")
                  : root.view === "password" ? (root.runKind === "stage" ? "Enter your password to install updates when you restart"
                      : root.runKind === "finish" ? "One more step to finish the update"
                      : "Enter your password to install updates")
                  : root.view === "running" ? (root.phaseLabel || "Starting…")
                  : (root.result && root.result.ok && root.result.staged) ? "Ready to install when you restart"
                  : (root.result && root.result.ok && root.result.finished) ? "Update complete"
                  : (root.result && root.result.ok) ? (root.result.restart ? "Updated. Restart to finish" : "Update complete")
                  : "The update didn't finish"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.Wrap
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.view === "applied" ? root.appliedText()
                  : root.view === "installed" ? root.installedText()
                  : root.view === "rollback-confirm" ? (root.rollbackError || root.confirmText())
                  : root.view === "trying" ? (root.rollbackError || root.tryingText())
                  : (root.view === "password" && root.passwordSent) ? "This takes a few seconds."
                  : root.view === "password" ? (root.passwordQueued ? "Checking the updates once more…"
                      : root.passwordRetry ? "That password didn't work. Try again."
                      : root.runKind === "finish" ? "Omarchy needs to update some settings. This is the password you use to log in."
                      : "This is the password you use to log in.")
                  : root.view === "running" ? "You can keep working. Please don't turn off your computer."
                  : (root.result && root.result.ok && root.result.staged) ? "Your computer saves a restore point, installs the updates and starts again. You can restart now or later."
                  : (root.result && root.result.ok) ? (root.result.restart ? "Some parts of the system were updated. They take effect after a restart." : "Everything is up to date.")
                  : ((root.result && root.result.error) || "")
                    + ((root.result && root.result.snapshot) ? " A restore point was saved before the update." : "")
              color: (root.view === "password" && root.passwordRetry) ? root.urgent : root.foreground
              opacity: (root.view === "password" && root.passwordRetry) ? 1 : 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
          }
        }

        TextField {
          id: passwordField
          visible: root.view === "password" && !root.passwordSent
          width: parent.width
          password: true
          placeholderText: "Password"
          // Open from the start: the runner re-checks the set first, and
          // what is typed meanwhile is sent once it asks.
          enabled: !root.passwordQueued && !root.passwordSent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          onAccepted: root.submitPassword()
          Keys.onEscapePressed: root.cancelUpdate()
        }

        // What the last update installed on restart changed, and how to go back
        Text {
          // Results from before this list was recorded have none.
          visible: root.view === "installed" && text !== ""
          width: parent.width
          textFormat: Text.PlainText
          // The first dozen; the card does not scroll.
          text: {
            var pkgs = (root.installed && root.installed.packages) || []
            var lines = pkgs.slice(0, 12).map(function(p) {
              return p.name + "  " + (p.from ? p.from + " → " : "") + p.to
            })
            if (pkgs.length > 12) lines.push("and " + (pkgs.length - 12) + " more")
            return lines.join("\n")
          }
          color: root.foreground
          opacity: 0.75
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
        Text {
          visible: root.view === "installed"
          width: parent.width
          textFormat: Text.PlainText
          text: root.installedRestore()
          color: root.foreground
          opacity: 0.65
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        // What the restore point being tried doesn't have
        Text {
          visible: root.view === "trying" && text !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: {
            var pkgs = (root.trying && root.trying.packages) || []
            if (pkgs.length === 0) return ""
            var lines = pkgs.slice(0, 12).map(function(p) {
              return p.name + "  " + (p.from ? p.from + " here, " : "not here, ") + p.to + " after the update"
            })
            if (pkgs.length > 12) lines.push("and " + (pkgs.length - 12) + " more")
            return "Not in this version:\n" + lines.join("\n")
          }
          color: root.foreground
          opacity: 0.75
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // What didn't come up after the restart
        Text {
          visible: root.view === "applied" && text !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.after ? (root.after.failed || []).concat((root.status.applied && root.status.applied.warnings) || []).join("\n") : ""
          color: root.urgent
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // Progress through the package step
        Column {
          visible: root.view === "running" && root.stepTotal > 0
          width: parent.width
          spacing: Style.spacing.sm
          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: root.subtle
            Rectangle {
              width: parent.width * Math.min(1, root.stepDone / Math.max(1, root.stepTotal))
              height: parent.height
              radius: parent.radius
              color: root.accent
              Behavior on width { NumberAnimation { duration: 250 } }
            }
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.stepLabel + "  ·  " + root.stepDone + " of " + root.stepTotal
            color: root.foreground
            opacity: 0.65
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        // Raw output, only on request
        Column {
          visible: root.view === "running" || root.view === "done"
          width: parent.width
          spacing: Style.spacing.sm
          Button {
            text: (root.showLog ? "Hide" : "Show") + " details"
            iconText: root.showLog ? "\udb80\udd40" : "\udb80\udd42"
            onClicked: root.showLog = !root.showLog
          }
          Rectangle {
            visible: root.showLog
            width: parent.width
            height: Style.space(200)
            radius: root.cornerRadius
            color: root.subtle
            ListView {
              id: logView
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              clip: true
              model: root.logLines
              onCountChanged: positionViewAtEnd()
              delegate: Text {
                required property var modelData
                width: ListView.view.width
                textFormat: Text.PlainText
                text: modelData
                color: root.foreground
                opacity: 0.75
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }

        Row {
          anchors.right: parent.right
          spacing: Style.spacing.md
          Button {
            visible: root.view === "password" && !root.passwordSent
            text: "Cancel"
            onClicked: root.cancelUpdate()
          }
          Button {
            visible: root.view === "password" && !root.passwordSent
            text: root.runKind === "stage" ? "Continue" : root.runKind === "finish" ? "Finish" : "Install"
            bordered: true
            selected: true
            enabled: !root.passwordQueued && !root.passwordSent && passwordField.text !== ""
            onClicked: root.submitPassword()
          }
          Button {
            visible: (root.view === "installed" || root.view === "applied") && !!root.rollback && root.rollback.available
            text: "Go back…"
            onClicked: root.confirmRollback()
          }
          Button {
            visible: root.view === "installed"
            text: "Close"
            bordered: true
            selected: true
            onClicked: { root.view = "details"; root.dismiss() }
          }
          Button {
            visible: root.view === "rollback-confirm"
            text: "Cancel"
            onClicked: root.view = root.beforeConfirm
          }
          Button {
            visible: root.view === "rollback-confirm"
            text: "Restart and go back"
            iconText: "󰜉"
            bordered: true
            selected: true
            enabled: !tryProc.running
            onClicked: { root.rollbackError = ""; tryProc.running = true }
          }
          Button {
            visible: root.view === "trying"
            text: "Undo the update for good…"
            // Omarchy's own restore: it asks for the password in a terminal.
            onClicked: Quickshell.execDetached(["limine-snapper-restore"])
          }
          Button {
            visible: root.view === "trying"
            text: "Return to the updated version"
            iconText: "󰜉"
            bordered: true
            selected: true
            enabled: !returnProc.running
            onClicked: returnProc.running = true
          }
          Button {
            visible: root.view === "running"
            text: "Hide"
            onClicked: root.dismiss()
          }
          Button {
            visible: root.view === "applied"
            text: (root.status.applied && root.status.applied.ok) ? "Keep using it" : "OK"
            onClicked: root.keepUsing()
          }
          Button {
            visible: root.view === "applied" && !!root.status.applied && root.status.applied.ok
            text: "Restart"
            bordered: true
            selected: true
            onClicked: Quickshell.execDetached(["systemctl", "reboot"])
          }
          Button {
            visible: root.view === "done" && root.result && root.result.ok && (root.result.restart || root.result.staged)
            text: "Later"
            onClicked: { root.finishRun(); root.dismiss() }
          }
          Button {
            visible: root.view === "done" && root.result && root.result.ok && (root.result.restart || root.result.staged)
            text: "Restart now"
            bordered: true
            selected: true
            onClicked: Quickshell.execDetached(["systemctl", "reboot"])
          }
          Button {
            visible: root.view === "done" && !(root.result && root.result.ok && (root.result.restart || root.result.staged))
            text: "Done"
            bordered: true
            onClicked: { root.finishRun(); root.dismiss() }
          }
        }
      }
    }
  }
}
