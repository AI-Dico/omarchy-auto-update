import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// Bar icon: a rocket climbing at an angle, drawn on a 24-unit grid. The rocket
// is scaled so its turned outline fills the icon box like other bar icons; the
// warning triangle uses the plain 24-unit grid, and the restart badge and the
// progress ring sit at the lower right, reaching past the box into the slot's
// margin. `look` picks how it tells the update state (design C):
//
//   uptodate     no flame, faded
//   checking     flame in the bar colour, flickering, a little faded
//   downloading  yellow flame, flickering
//   ready        yellow flame
//   restart      yellow flame and an accent badge with ↑ at the lower right
//   running      flickering yellow flame and a turning progress ring
//   attention    yellow warning triangle (needs a look, or Arch news)
//   error        red warning triangle
//
// Flicker is 1 s, the ring turns once in 1.4 s. Both stop when the shell asks
// for less motion, and while the icon is not shown.
Item {
  id: root

  property string look: "ready"
  property real iconSize: Math.min(width, height) > 0 ? Math.min(width, height) : Style.bar.iconCanvas
  property color color: Commons.Color.foreground
  // Ink drawn on top of coloured shapes (the ↑, the !) and the badge's outline.
  property color ink: Commons.Color.background
  property color accent: Commons.Color.accent
  property color yellow: themeYellow !== "" ? themeYellow : Commons.Color.accent
  property color red: themeRed !== "" ? themeRed : Commons.Color.urgent
  // Omarchy 4.0.6 has no such switch yet; this follows it once Style grows one.
  property bool animate: Style.reduceMotion !== true

  // Commons.Color has no yellow (and only `urgent` for red), so read both from
  // the theme's palette.
  property string themeYellow: ""
  property string themeRed: ""

  readonly property bool warning: look === "attention" || look === "error"
  readonly property bool flickers: look === "checking" || look === "downloading" || look === "running"
  readonly property bool moving: animate && root.visible

  implicitWidth: iconSize
  implicitHeight: iconSize

  // The 24-unit grid, centred in the icon box.
  Item {
    id: grid
    readonly property real unit: root.iconSize / 24
    // How far badge and ring move out past the lower right corner.
    readonly property real corner: root.iconSize * 0.1
    width: root.iconSize
    height: root.iconSize
    anchors.centerIn: parent

    // Body and legs, then the flame; turned 45° about the centre. Once turned
    // the rocket spans about 4.3–19.7 of the grid, so the grid is drawn 1.5×
    // the box and that 16-unit middle fills it.
    Item {
      id: craft
      readonly property real unit: root.iconSize / 16
      width: unit * 24
      height: unit * 24
      anchors.centerIn: parent
      visible: !root.warning
      rotation: 45
      opacity: root.look === "uptodate" ? 0.45 : root.look === "checking" ? 0.7 : root.look === "downloading" ? 0.85 : 1

      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: root.color
          strokeWidth: -1
          scale: Qt.size(craft.unit, craft.unit)
          PathSvg {
            path: "M10.2 16.2 V8 Q10.2 3.8 12 1.6 Q13.8 3.8 13.8 8 V16.2 Z "
              + "M10.2 15.8 L7.8 17.8 V13.2 L10.2 11 Z "
              + "M13.8 15.8 L16.2 17.8 V13.2 L13.8 11 Z"
          }
        }
      }

      Shape {
        id: flame
        anchors.fill: parent
        visible: root.look !== "uptodate"
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: root.look === "checking" ? root.color : root.yellow
          strokeWidth: -1
          scale: Qt.size(craft.unit, craft.unit)
          PathSvg { path: "M10.7 17.4 Q12 22.8 13.3 17.4 Z" }
        }
        SequentialAnimation on opacity {
          running: root.flickers && root.moving
          loops: Animation.Infinite
          NumberAnimation { from: 1; to: 0.25; duration: 500; easing.type: Easing.InOutSine }
          NumberAnimation { from: 0.25; to: 1; duration: 500; easing.type: Easing.InOutSine }
          onRunningChanged: if (!running) flame.opacity = 1
        }
      }
    }

    // Warning triangle with a "!" cut in the ink colour.
    Shape {
      anchors.fill: parent
      visible: root.warning
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: root.look === "error" ? root.red : root.yellow
        strokeWidth: -1
        scale: Qt.size(grid.unit, grid.unit)
        PathSvg { path: "M12 2.5 L22 20.5 H2 Z" }
      }
      ShapePath {
        fillColor: root.ink
        strokeWidth: -1
        scale: Qt.size(grid.unit, grid.unit)
        PathSvg {
          path: "M11 9.5 A1 1 0 0 1 13 9.5 V14 A1 1 0 0 1 11 14 Z "
            + "M10.8 17.6 A1.2 1.2 0 1 0 13.2 17.6 A1.2 1.2 0 1 0 10.8 17.6 Z"
        }
      }
    }

    // Restart: accent badge with ↑, outlined in the ink colour to stand off the
    // rocket. Badge and ring keep the design's size and move a little past the
    // box's lower right corner, where the rocket leaves room.
    Shape {
      anchors.fill: parent
      anchors.leftMargin: grid.corner; anchors.topMargin: grid.corner
      anchors.rightMargin: -grid.corner; anchors.bottomMargin: -grid.corner
      visible: root.look === "restart"
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: root.accent
        strokeColor: root.ink
        strokeWidth: 1.6 * grid.unit
        PathSvg {
          path: "M" + 13.8 * grid.unit + " " + 19 * grid.unit
            + " A" + 5.2 * grid.unit + " " + 5.2 * grid.unit + " 0 1 0 " + 24.2 * grid.unit + " " + 19 * grid.unit
            + " A" + 5.2 * grid.unit + " " + 5.2 * grid.unit + " 0 1 0 " + 13.8 * grid.unit + " " + 19 * grid.unit + " Z"
        }
      }
      ShapePath {
        fillColor: "transparent"
        strokeColor: root.ink
        strokeWidth: 1.5 * grid.unit
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathSvg {
          path: "M" + 19 * grid.unit + " " + 16.2 * grid.unit + " V" + 21.6 * grid.unit
            + " M" + 16.8 * grid.unit + " " + 18.4 * grid.unit + " L" + 19 * grid.unit + " " + 16.2 * grid.unit
            + " L" + 21.2 * grid.unit + " " + 18.4 * grid.unit
        }
      }
    }

    // Running: a faint full ring and an accent quarter that turns.
    Item {
      anchors.fill: parent
      anchors.leftMargin: grid.corner; anchors.topMargin: grid.corner
      anchors.rightMargin: -grid.corner; anchors.bottomMargin: -grid.corner
      visible: root.look === "running"
      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillColor: "transparent"
          strokeColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.3)
          strokeWidth: 1.8 * grid.unit
          PathAngleArc {
            centerX: 19 * grid.unit; centerY: 19 * grid.unit
            radiusX: 4.6 * grid.unit; radiusY: 4.6 * grid.unit
            startAngle: 0; sweepAngle: 360
          }
        }
      }
      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        transform: Rotation {
          id: spin
          origin.x: 19 * grid.unit
          origin.y: 19 * grid.unit
          NumberAnimation on angle {
            running: root.look === "running" && root.moving
            from: 0; to: 360; duration: 1400; loops: Animation.Infinite
            onRunningChanged: if (!running) spin.angle = 0
          }
        }
        ShapePath {
          fillColor: "transparent"
          strokeColor: root.accent
          strokeWidth: 1.8 * grid.unit
          capStyle: ShapePath.RoundCap
          // From 12 o'clock to 3 o'clock, as in the design.
          PathAngleArc {
            centerX: 19 * grid.unit; centerY: 19 * grid.unit
            radiusX: 4.6 * grid.unit; radiusY: 4.6 * grid.unit
            startAngle: -90; sweepAngle: 90
          }
        }
      }
    }
  }

  function readPalette(raw) {
    var lines = String(raw || "").split("\n")
    var c = {}
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) c[m[1]] = m[2]
    }
    root.themeYellow = c.yellow || c.color3 || ""
    root.themeRed = c.red || c.color1 || ""
  }

  FileView {
    id: palette
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.readPalette(text())
    onLoadFailed: { root.themeYellow = ""; root.themeRed = "" }
  }

  // A theme switch reaches the shell as new palette colours; re-read then.
  Connections {
    target: Commons.Color
    function onForegroundChanged() { palette.reload() }
    function onAccentChanged() { palette.reload() }
  }
}
