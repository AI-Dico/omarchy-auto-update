import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// Bar icon: a rocket climbing at an angle. Drawn on a 24-unit grid and turned
// 45° about its centre. The body takes the bar's colour, the flame the theme's
// yellow. Sized to fill the BarIconButton icon canvas it is loaded into.
Item {
  id: root

  property real iconSize: Math.min(width, height) > 0 ? Math.min(width, height) : Style.bar.iconCanvas
  property color color: Commons.Color.foreground
  property color flameColor: themeYellow !== "" ? themeYellow : Commons.Color.accent

  // Commons.Color has no yellow, so read it from the theme's palette.
  property string themeYellow: ""

  implicitWidth: iconSize
  implicitHeight: iconSize

  // Once turned, the rocket spans about 4.3–19.7 of the 24-unit grid. Drawing
  // the grid 1.5× the icon size lets that 16-unit middle fill the icon.
  Shape {
    id: shape
    readonly property real unit: root.iconSize / 16
    width: unit * 24
    height: unit * 24
    anchors.centerIn: parent
    rotation: 45
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    ShapePath {
      fillColor: root.color
      strokeWidth: -1
      scale: Qt.size(shape.unit, shape.unit)
      PathSvg {
        path: "M10.2 16.2 V8 Q10.2 3.8 12 1.6 Q13.8 3.8 13.8 8 V16.2 Z "
          + "M10.2 15.8 L7.8 17.8 V13.2 L10.2 11 Z "
          + "M13.8 15.8 L16.2 17.8 V13.2 L13.8 11 Z"
      }
    }
    ShapePath {
      fillColor: root.flameColor
      strokeWidth: -1
      scale: Qt.size(shape.unit, shape.unit)
      PathSvg { path: "M10.7 17.4 Q12 22.8 13.3 17.4 Z" }
    }
  }

  function readYellow(raw) {
    var lines = String(raw || "").split("\n")
    var yellow = "", color3 = ""
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!m) continue
      if (m[1] === "yellow") yellow = m[2]
      else if (m[1] === "color3") color3 = m[2]
    }
    root.themeYellow = yellow || color3
  }

  FileView {
    id: palette
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.readYellow(text())
    onLoadFailed: root.themeYellow = ""
  }

  // A theme switch reaches the shell as new palette colours; re-read then.
  Connections {
    target: Commons.Color
    function onForegroundChanged() { palette.reload() }
    function onAccentChanged() { palette.reload() }
  }
}
