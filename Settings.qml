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

  // Settings from a share: cleaned up (Config.sanitize, with the settings in
  // use as the fallback) and written, unless the file has an error.
  function replace(obj) {
    raw = Config.sanitize(obj, values)
    if (error === "") write(raw)
  }

  // replace(), after config.json is copied to config.json.bak (nothing is
  // replaced when that copy fails). The copy and the replacement finish by
  // themselves, whether or not the share view that asked is still open;
  // `replaced(ok)` tells a view that is. Settings aren't secret, so there is no
  // reason to drop them on the floor if the view closes in the meantime.
  signal replaced(bool ok)
  property var pendingReplace: null

  function replaceWithBackup(obj) {
    if (error !== "") { replaced(false); return }
    pendingReplace = obj
    backup.running = true
  }

  Process {
    id: backup
    command: ["sh", "-c", 'if [ -e "$1" ]; then cp -p -- "$1" "$1.bak"; fi', "omacam-backup", root.path]
    onExited: function(code) {
      var obj = root.pendingReplace
      root.pendingReplace = null
      var ok = code === 0 && obj !== null && root.error === ""
      if (ok) root.replace(obj)
      root.replaced(ok)
    }
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
