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
  readonly property bool ready: status.state === "ready"

  // details → password → running → done. The update itself runs in
  // bin/omarchy-auto-update-runner; this only shows its events.
  property string view: "details"
  readonly property string runner: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-auto-update-runner")).replace(/^file:\/\//, ""))
  property bool awaitingPassword: false
  property bool passwordRetry: false
  property string phaseLabel: ""
  property int stepDone: 0
  property int stepTotal: 0
  property string stepLabel: ""
  property var logLines: []
  property bool showLog: false
  property var result: null

  function open(payloadJson) {
    root.opened = true
    root.showPackages = false
    // A finished run stays on screen until dismissed; an idle overlay starts fresh.
    if (!runProc.running && root.view !== "done") root.view = "details"
    root.reload()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
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

  function updateNow() {
    if (runProc.running) { root.view = "running"; return }
    root.view = "password"
    root.awaitingPassword = false
    root.passwordRetry = false
    root.phaseLabel = ""
    root.stepDone = 0
    root.stepTotal = 0
    root.stepLabel = ""
    root.logLines = []
    root.showLog = false
    root.result = null
    passwordField.text = ""
    runProc.running = true
    Qt.callLater(function() { passwordField.forceActiveFocus() })
  }

  function submitPassword() {
    if (!root.awaitingPassword || passwordField.text === "") return
    root.awaitingPassword = false
    runProc.write(passwordField.text + "\n")
    passwordField.text = ""
  }

  function cancelUpdate() {
    if (runProc.running && root.view === "password") runProc.running = false
    root.view = "details"
  }

  function finishRun() {
    root.view = "details"
    root.result = null
    root.checkNow()
  }

  function onRunnerEvent(line) {
    var e
    try { e = JSON.parse(line) } catch (err) { return }
    if (e.type === "password") {
      root.awaitingPassword = true
      root.passwordRetry = !!e.retry
      root.view = "password"
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
      root.view = e.cancelled ? "details" : "done"
      root.awaitingPassword = false
    }
  }

  function readNews() {
    if (!root.status.news) return
    Quickshell.execDetached(["xdg-open", root.status.news.link])
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
    if (status.state === "ready") {
      var parts = []
      parts.push(status.downloaded ? "Downloaded and verified" : "Verified")
      if (status.downloadBytes) parts.push(mb(status.downloadBytes))
      return parts.join(" · ")
    }
    return status.message || ""
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
      onStreamFinished: { try { root.status = JSON.parse(text) } catch (e) { } }
    }
  }

  Process {
    id: checkProc
    command: [root.helper, "run", "--force"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.status = JSON.parse(text) } catch (e) { root.reload() } }
    }
    onExited: Quickshell.execDetached(["omarchy-shell", "io.github.ai-dico.auto-update.bar", "reload"])
  }

  Process {
    id: runProc
    command: [root.runner]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onRunnerEvent(line) } }
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
          else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.ready) { root.updateNow(); event.accepted = true }
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
                : root.busy ? "󰑐" : "󰇚"
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
              visible: root.ready || root.status.state === "attention"
              text: "Update now"
              iconText: "󰇚"
              bordered: true
              selected: true
              onClicked: root.updateNow()
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
            text: root.view === "password" ? "\udb80\udf3e"
                : root.view === "running" ? "\udb81\udc50"
                : (root.result && root.result.ok) ? "\udb80\udd34" : "\udb80\udc26"
            color: (root.view === "done" && root.result && !root.result.ok) ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            RotationAnimation on rotation {
              running: root.view === "running" && root.opened
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
              text: root.view === "password" ? "Enter your password to install updates"
                  : root.view === "running" ? (root.phaseLabel || "Starting…")
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
              text: root.view === "password" ? (root.passwordRetry ? "That password didn't work. Try again." : "This is the password you use to log in.")
                  : root.view === "running" ? "You can keep working. Please don't turn off your computer."
                  : (root.result && root.result.ok) ? (root.result.restart ? "Some parts of the system were updated. They take effect after a restart." : "Everything is up to date.")
                  : ((root.result && root.result.error) || "") + " A restore point was saved before the update."
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
          visible: root.view === "password"
          width: parent.width
          password: true
          placeholderText: root.awaitingPassword ? "Password" : "Getting ready…"
          enabled: root.awaitingPassword
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          onAccepted: root.submitPassword()
          Keys.onEscapePressed: root.cancelUpdate()
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
          visible: root.view !== "password"
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
            visible: root.view === "password"
            text: "Cancel"
            onClicked: root.cancelUpdate()
          }
          Button {
            visible: root.view === "password"
            text: "Install"
            bordered: true
            selected: true
            enabled: root.awaitingPassword && passwordField.text !== ""
            onClicked: root.submitPassword()
          }
          Button {
            visible: root.view === "running"
            text: "Hide"
            onClicked: root.dismiss()
          }
          Button {
            visible: root.view === "done" && root.result && root.result.ok && root.result.restart
            text: "Later"
            onClicked: { root.finishRun(); root.dismiss() }
          }
          Button {
            visible: root.view === "done" && root.result && root.result.ok && root.result.restart
            text: "Restart now"
            bordered: true
            selected: true
            onClicked: Quickshell.execDetached(["systemctl", "reboot"])
          }
          Button {
            visible: root.view === "done" && !(root.result && root.result.ok && root.result.restart)
            text: "Done"
            bordered: true
            onClicked: { root.finishRun(); root.dismiss() }
          }
        }
      }
    }
  }
}
