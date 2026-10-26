import QtQuick
import Quickshell
import Quickshell.Io
import "Config.js" as Config

// ~/.config/omacam/config.json: keys, timings, layout and click actions (see
// Config.js for every option). Created with all defaults on first run, and
// read again whenever it changes, so edits apply at once. A file that isn't
// valid JSON is left alone and the last good settings stay in use.
Item {
  id: root
  visible: false

  readonly property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omacam/config.json"

  // Settings from before config.json existed, written into it when it's created.
  property var seed: ({})

  // What the file holds, and the full settings (defaults with the file on top).
  property var raw: ({})
  readonly property var values: Config.merge(Config.DEFAULTS, raw)
  property string error: ""
  property bool missing: false

  readonly property var connection: values.connection
  readonly property var sound: values.sound
  readonly property var bar: values.bar
  readonly property var dropdown: values.dropdown
  readonly property var fullscreen: values.fullscreen
  readonly property var wall: values.wall
  readonly property var pinned: values.pinned
  readonly property var keys: values.keys

  function seconds(v, fallback) { var n = Number(v); return isFinite(n) && n >= 0 ? n : fallback }

  // set("connection.alwaysConnected", true). Applies at once; not written
  // while the file has an error, so a half-edited file is never overwritten.
  function set(key, value) {
    raw = Config.withValue(raw, key, value)
    if (error === "") write(raw)
  }

  function write(obj) {
    ensureDir.text = Config.format(obj)
    ensureDir.running = true
  }

  Process {
    id: ensureDir
    property string text: ""
    command: ["mkdir", "-p", root.path.replace(/\/[^\/]*$/, "")]
    onExited: file.setText(text)
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.missing = false
      try {
        var data = JSON.parse(String(text() || "{}"))
        if (!Config.isObject(data)) throw new Error("expected { … } at the top")
        root.raw = data
        root.error = ""
      } catch (e) {
        root.error = String(e.message || e)
        console.warn("omacam", root.path + ":", root.error, "(keeping the last good settings)")
      }
    }
    onLoadFailed: {
      if (root.missing) return
      root.missing = true
      root.raw = Config.merge(Config.DEFAULTS, root.seed)
      root.write(root.raw)
    }
  }
}
