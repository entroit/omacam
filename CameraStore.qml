import QtQuick
import Quickshell
import Quickshell.Io

// Camera list persisted to ~/.config/omacam/cameras.json (mode 600, since it
// holds camera passwords). Every bar instance (one per monitor) owns a store;
// they stay in sync through the file watcher.
Item {
  id: root
  visible: false

  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omacam"
  readonly property string path: configDir + "/cameras.json"

  property var cameras: []
  property bool loaded: false
  readonly property var enabledCameras: cameras.filter(function(c) { return c.enabled !== false })

  function find(id) {
    for (var i = 0; i < cameras.length; i++) if (cameras[i].id === id) return cameras[i]
    return null
  }

  function indexOf(id) {
    for (var i = 0; i < cameras.length; i++) if (cameras[i].id === id) return i
    return -1
  }

  function newId() {
    return "cam-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36)
  }

  function clean(camera) {
    return {
      id: camera.id || newId(),
      name: String(camera.name || "Camera").trim(),
      brand: String(camera.brand || "hikvision"),
      host: String(camera.host || "").trim(),
      url: String(camera.url || "").trim(),
      user: String(camera.user || ""),
      password: String(camera.password || ""),
      variant: Number(camera.variant) || 0,
      enabled: camera.enabled !== false
    }
  }

  function add(camera) {
    var record = clean(camera)
    cameras = cameras.concat([record])
    save()
    return record.id
  }

  function update(id, camera) {
    var i = indexOf(id)
    if (i < 0) return add(camera)
    var next = cameras.slice()
    var merged = clean(camera)
    merged.id = id
    next[i] = merged
    cameras = next
    save()
    return id
  }

  function remove(id) {
    cameras = cameras.filter(function(c) { return c.id !== id })
    save()
  }

  function setEnabled(id, enabled) {
    var i = indexOf(id)
    if (i < 0) return
    var next = cameras.slice()
    var record = clean(next[i])
    record.enabled = enabled
    next[i] = record
    cameras = next
    save()
  }

  function move(fromIndex, toIndex) {
    if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0 || fromIndex >= cameras.length || toIndex >= cameras.length) return
    var next = cameras.slice()
    var item = next.splice(fromIndex, 1)[0]
    next.splice(toIndex, 0, item)
    cameras = next
    save()
  }

  function parse(content) {
    try {
      var data = JSON.parse(String(content || "{}"))
      var list = data instanceof Array ? data : (data.cameras || [])
      root.cameras = list.map(clean)
    } catch (e) {
      console.warn("omacam", "Ignoring unreadable", root.path, e)
    }
    root.loaded = true
  }

  function save() {
    ensureDir.running = true
  }

  Process {
    id: ensureDir
    command: ["sh", "-c", "mkdir -p \"$1\" && chmod 700 \"$1\"", "sh", root.configDir]
    onExited: file.setText(JSON.stringify({ version: 1, cameras: root.cameras }, null, 2) + "\n")
  }

  // After the write has landed: a saved file is a new file, made with the
  // default permissions. Also run on load, for files written by hand.
  Process {
    id: lockDown
    command: ["chmod", "600", root.path]
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.missing = false; root.parse(text()); lockDown.running = true }
    onSaved: lockDown.running = true
    onLoadFailed: { root.missing = true; root.cameras = []; root.loaded = true }
  }

  // A file that doesn't exist yet can't be watched; look again now and then
  // so a cameras.json created by hand (or by another monitor's bar) shows up.
  property bool missing: false
  function refresh() { file.reload() }
  Timer {
    interval: 5000
    repeat: true
    running: root.missing
    onTriggered: file.reload()
  }
}
