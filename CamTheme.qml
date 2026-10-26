import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Colors for OmaCam, always taken from the active Omarchy theme so the
// cameras follow theme switches like the rest of the shell. The shell's
// Color singleton only carries foreground/background/accent/urgent, so the
// green (online) and yellow (warning) roles are read from colors.toml.
Item {
  id: root
  visible: false

  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.6)
  readonly property color faint: Qt.darker(fg, 2.4)
  readonly property color bg: Color.popups.background
  readonly property color sunken: Qt.darker(bg, 1.35)
  readonly property color raised: Qt.lighter(bg, 1.35)
  readonly property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color lineStrong: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  property color ok: "#9ece6a"
  property color warn: "#e0af68"

  readonly property string font: Style.font.family
  readonly property int radius: Style.cornerRadius

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function pick(raw, key) {
    var m = String(raw || "").match(new RegExp("^\\s*" + key + "\\s*=\\s*[\"']?(#[0-9A-Fa-f]{6})", "m"))
    return m ? m[1] : ""
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = text()
      var green = root.pick(raw, "green") || root.pick(raw, "color2")
      var yellow = root.pick(raw, "yellow") || root.pick(raw, "color3")
      if (green) root.ok = green
      if (yellow) root.warn = yellow
    }
  }
}
