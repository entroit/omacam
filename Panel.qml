import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Brands.js" as Brands
import "Config.js" as Config

// OmaCam bar widget: camera icon with an online count, a dropdown with every
// camera, an enlarged view, the add/edit form, the manage list, a fullscreen
// viewer and pinned picture-in-picture players.
//
// Streams only run while something is on screen; when everything is closed
// the widget just checks every minute which cameras answer on the network.
Panel {
  id: root
  moduleName: "entroit.omacam"
  ipcTarget: "entroit.omacam"
  manageIpc: false

  // grid · camera · form · manage
  property string view: "grid"
  property string focusId: ""
  property string formReturn: "grid"
  property var pinned: []
  property string viewerMode: ""      // "" · single · wall
  property string viewerId: ""
  property string viewerFrom: ""      // popup view to go back to, or "wall"
  // Streams keep running a while after the dropdown closes (and start when the
  // pointer rests on the bar icon) so opening it again is instant.
  property bool warm: false
  property bool hoverWarm: false
  readonly property int keepWarmSeconds: omaSettings.seconds(omaSettings.connection.keepConnectedSeconds, 180)
  readonly property bool alwaysConnected: omaSettings.connection.alwaysConnected === true

  // Everything else that's adjustable lives in ~/.config/omacam/config.json.
  readonly property alias config: omaSettings
  Settings {
    id: omaSettings
    // These two used to be in the widget's entry in shell.json.
    seed: ({ connection: { alwaysConnected: root.setting("alwaysConnected", false) === true, keepConnectedSeconds: Number(root.setting("keepWarmSeconds", 180)) } })
  }

  readonly property bool streaming: opened || warm || hoverWarm || alwaysConnected

  // A fresh JPEG from each camera arrives in well under a second, long before
  // the first live frame; views show it until the video takes over.
  SnapshotFetcher { id: snapshots }
  onStreamingChanged: if (streaming) snapshots.fetch(cameraStore.enabledCameras)
  // Cameras not live yet (e.g. just after login with "always connected").
  function fetchMissingSnapshots() {
    snapshots.fetch(cameraStore.enabledCameras.filter(function(c) {
      return streamPool.liveKeys[streamPool.keyFor(c.id, "sub")] !== true
    }))
  }
  readonly property var targetScreen: button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property real barHeight: button.QsWindow.window ? button.QsWindow.window.height : 30

  readonly property alias store: cameraStore
  readonly property alias pal: themePalette
  readonly property alias sound: soundPlayer
  readonly property alias grid: gridLoader
  readonly property alias pool: streamPool

  // Every camera connection; views borrow them, so moving between views
  // never reconnects.
  StreamPool {
    id: streamPool
    lingerMs: omaSettings.seconds(omaSettings.connection.keepFullQualitySeconds, 30) * 1000
    retrySeconds: Math.max(1, omaSettings.seconds(omaSettings.connection.retrySeconds, 15))
    lowLatency: omaSettings.connection.lowLatency !== false
  }

  // --- reachability (for the bar count) --------------------------------------
  property var reachable: ({})
  readonly property int onlineCount: {
    var n = 0
    var cams = cameraStore.enabledCameras
    for (var i = 0; i < cams.length; i++) if (reachable[cams[i].id] === true) n++
    return n
  }
  readonly property bool anyOffline: cameraStore.enabledCameras.length > 0 && onlineCount < cameraStore.enabledCameras.length && Object.keys(reachable).length > 0

  CameraStore { id: cameraStore; onCamerasChanged: reach.check() }
  CamTheme { id: themePalette }

  // --- navigation ---------------------------------------------------------------
  function openPopup() {
    if (!opened) open()
  }

  function openCamera(id, fromOutside) {
    focusId = id
    view = "camera"
    if (fromOutside) viewerMode = ""
    openPopup()
  }

  // A fresh picture of the camera being enlarged, for while its full stream
  // connects.
  onFocusIdChanged: if (view === "camera" && streaming) snapshots.fetch([cameraStore.find(focusId)].filter(Boolean), 5000)

  function step(d) {
    var cams = cameraStore.enabledCameras
    if (cams.length === 0) return
    var i = 0
    for (var k = 0; k < cams.length; k++) if (cams[k].id === focusId) i = k
    focusId = cams[(i + d + cams.length) % cams.length].id
  }

  function openForm(record, returnTo) {
    formReturn = returnTo || view
    view = "form"
    openPopup()
    Qt.callLater(function() { if (formLoader.item) formLoader.item.load(record) })
  }

  function cancelForm() {
    view = formReturn === "camera" && !cameraStore.find(focusId) ? "grid" : formReturn
  }

  function formSaved(id) {
    if (formReturn === "camera") focusId = id
    view = formReturn === "form" ? "grid" : formReturn
  }

  function keyFor(id) {
    var cams = cameraStore.enabledCameras
    for (var i = 0; i < cams.length; i++) if (cams[i].id === id) return i < 9 ? String(i + 1) : ""
    return ""
  }

  function openFullscreen(id) {
    snapshots.fetch([cameraStore.find(id)].filter(Boolean))
    viewerFrom = viewerMode === "wall" ? "wall" : (opened ? view : "")
    viewerId = id
    viewerMode = "single"
    close()
  }

  function openWall() {
    snapshots.fetch(cameraStore.enabledCameras)
    viewerFrom = opened ? view : ""
    viewerMode = "wall"
    close()
  }

  function closeViewer() {
    viewerMode = ""
  }

  function viewerBack() {
    if (viewerMode === "single" && viewerFrom === "wall") {
      viewerMode = "wall"
      viewerFrom = "grid"
      return
    }
    var target = viewerFrom
    var id = viewerId
    viewerMode = ""
    if (target === "camera" || (target === "" && id !== "")) openCamera(id)
    else if (target !== "") { view = target; openPopup() }
  }

  function editFromViewer(id) {
    viewerMode = ""
    openForm(cameraStore.find(id), "grid")
  }

  // --- sound ----------------------------------------------------------------------
  // Only the enlarged view, fullscreen and pinned players play sound, and only
  // one at a time: the view opened (or unmuted) last owns it. Keys are
  // "enlarged", "fullscreen" and "pip:<camera id>".
  property string soundOwner: ""
  property var mutedCams: ({})

  function soundOn(id, key) { return soundOwner === key && !mutedCams[id] }
  function ownerCameraId() {
    return soundOwner === "enlarged" ? focusId
         : soundOwner === "fullscreen" ? viewerId
         : soundOwner.indexOf("pip:") === 0 ? soundOwner.slice(4) : ""
  }

  SoundPlayer {
    id: soundPlayer
    camera: root.soundOwner !== "" ? cameraStore.find(root.ownerCameraId()) : null
    muted: !!root.mutedCams[root.ownerCameraId()]
    parkSeconds: omaSettings.seconds(omaSettings.sound.closeAfterMutedSeconds, 20)
  }
  function claimSound(key) { soundOwner = key }
  function releaseSound(key) {
    if (soundOwner !== key) return
    soundOwner = viewerMode === "single" ? "fullscreen"
               : pinned.length > 0 ? "pip:" + pinned[pinned.length - 1] : ""
  }
  function setMuted(id, value) {
    var m = {}
    for (var k in mutedCams) m[k] = mutedCams[k]
    if (value) m[id] = true
    else delete m[id]
    mutedCams = m
  }
  function toggleSound(id, key) {
    if (soundOwner !== key) { soundOwner = key; setMuted(id, false) }
    else setMuted(id, !mutedCams[id])
  }

  onViewerModeChanged: viewerMode === "single" ? claimSound("fullscreen") : releaseSound("fullscreen")

  // --- pins ---------------------------------------------------------------------
  function isPinned(id) { return pinned.indexOf(id) !== -1 }
  function pin(id) { if (!isPinned(id)) { snapshots.fetch([cameraStore.find(id)].filter(Boolean)); pinned = pinned.concat([id]); claimSound("pip:" + id) } }
  function unpin(id) { pinned = pinned.filter(function(p) { return p !== id }); releaseSound("pip:" + id) }
  function togglePin(id) { isPinned(id) ? unpin(id) : pin(id) }

  Timer { id: warmTimer; interval: Math.max(1, root.keepWarmSeconds) * 1000; onTriggered: root.warm = false }
  Timer { id: hoverTimer; interval: Math.max(1, omaSettings.seconds(omaSettings.connection.warmOnHoverSeconds, 15)) * 1000; onTriggered: root.hoverWarm = false }

  Connections {
    target: button
    function onTooltipHoveredChanged() {
      if (button.tooltipHovered && !root.opened && omaSettings.connection.warmOnHoverSeconds > 0) { root.hoverWarm = true; hoverTimer.restart() }
    }
  }

  onOpenedChanged: {
    hoverWarm = false
    if (!opened && keepWarmSeconds > 0) { warm = true; warmTimer.restart() }
    if (opened) {
      cameraStore.refresh()
      fetchMissingSnapshots()
      if (view === "camera" && !cameraStore.find(focusId)) view = "grid"
      gridLoader.cursor = -1
    } else if (view === "form" || view === "manage") {
      view = "grid"
    }
  }


  // `omarchy-shell omacam <method>` for keybindings, e.g.
  //   bind = SUPER, C, exec, omarchy-shell omacam toggle
  // Only the bar on the first monitor answers, so calls never double up.
  IpcHandler {
    target: "omacam"
    enabled: !!root.targetScreen && Quickshell.screens.length > 0 && root.targetScreen.name === Quickshell.screens[0].name

    function toggle(): void { root.view = "grid"; root.toggle() }
    function open(): void { root.view = "grid"; root.openPopup() }
    function close(): void { root.viewerMode = ""; root.close() }
    function wall(): void { root.openWall() }
    function manage(): void { root.view = "manage"; root.openPopup() }
    function add(): void { root.openForm(null, "grid") }
    function edit(n: string): void { var c = root.cameraAt(n); if (c) root.openForm(c, "grid") }
    function camera(n: string): void { var c = root.cameraAt(n); if (c) root.openCamera(c.id, true) }
    function fullscreen(n: string): void { var c = root.cameraAt(n); if (c) root.openFullscreen(c.id) }
    function pin(n: string): void { var c = root.cameraAt(n); if (c) root.togglePin(c.id) }
    // Toggle sound for whichever view currently owns it.
    function sound(): void {
      var id = root.ownerCameraId()
      if (id !== "") root.toggleSound(id, root.soundOwner)
    }
    function soundState(): string { return JSON.stringify({ owner: root.soundOwner, camera: root.ownerCameraId(), muted: Object.keys(root.mutedCams), playing: soundPlayer.playing, parked: soundPlayer.parked, known: soundPlayer.known }) }
  }

  // Camera by 1-based position or by name (case-insensitive).
  function cameraAt(n) {
    var cams = cameraStore.enabledCameras
    var i = Number(n)
    if (i >= 1 && i <= cams.length) return cams[i - 1]
    var key = String(n || "").toLowerCase()
    for (var k = 0; k < cams.length; k++) if (cams[k].name.toLowerCase() === key || cams[k].id === n) return cams[k]
    return null
  }

  // A key pressed in the dropdown; true when it did something.
  function handleKey(e) {
    var cams = cameraStore.enabledCameras
    var t = e.text
    if (omaSettings.keys.cameraNumbers && t >= "1" && t <= "9" && (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0) {
      var i = Number(t) - 1
      if (i < cams.length) root.openCamera(cams[i].id)
      return true
    }
    if (root.view === "camera") {
      var a = Config.action(omaSettings.keys.enlarged, e)
      if (a === "previous") root.step(-1)
      else if (a === "next") root.step(1)
      else if (a === "fullscreen") root.openFullscreen(root.focusId)
      else if (a === "sound") root.toggleSound(root.focusId, "enlarged")
      else if (a === "pin") root.togglePin(root.focusId)
      else if (a === "edit") root.openForm(cameraStore.find(root.focusId), "camera")
      else if (a === "wall") { if (cams.length > 1) root.openWall() }
      else if (a === "add") root.openForm(null, "camera")
      else if (a === "back") root.view = "grid"
      else return false
      return true
    }
    var d = Config.action(omaSettings.keys.dropdown, e)
    var cols = Math.max(1, Number(omaSettings.dropdown.columns) || 2)
    var cur = gridLoader.cursor
    if (d === "up" || d === "down" || d === "left" || d === "right") {
      if (root.view !== "grid" || cams.length === 0) return true
      var step = d === "up" ? -cols : d === "down" ? cols : d === "left" ? -1 : 1
      gridLoader.cursor = Math.max(0, Math.min(cams.length - 1, cur < 0 ? 0 : cur + step))
    }
    else if (d === "open") { if (root.view === "grid" && cur >= 0) root.openCamera(cams[cur].id) }
    else if (d === "fullscreen") { if (root.view === "grid" && cur >= 0) root.openFullscreen(cams[cur].id) }
    else if (d === "wall") { if (cams.length > 1) root.openWall() }
    else if (d === "add") root.openForm(null, root.view)
    else if (d === "manage") root.view = "manage"
    else if (d === "nextPanel") root.switchPanel(1)
    else if (d === "previousPanel") root.switchPanel(-1)
    else if (d === "close") { if (root.view === "grid") root.close(); else root.view = "grid" }
    else return false
    return true
  }

  // Click actions from config.json.
  function barAction(name) {
    var cams = cameraStore.enabledCameras
    if (name === "dropdown") { root.view = "grid"; root.toggle() }
    else if (name === "manage") { root.view = "manage"; root.openPopup() }
    else if (name === "wall") { if (cams.length > 0) root.openWall() }
    else if (name === "fullscreen") { if (cams.length > 0) root.openFullscreen(cams[0].id) }
  }
  function cameraAction(name, id) {
    if (name === "enlarge") root.openCamera(id, true)
    else if (name === "fullscreen") root.openFullscreen(id)
    else if (name === "pin") root.togglePin(id)
  }

  // Cheap TCP check of every camera's RTSP port, once a minute.
  Process {
    id: reach
    property bool pending: false
    function check() {
      if (running) { pending = true; return }
      var cams = cameraStore.enabledCameras || []
      if (cams.length === 0) { root.reachable = ({}); return }
      var args = []
      for (var i = 0; i < cams.length; i++) {
        var c = cams[i]
        var hp = c.brand === "custom" ? Brands.splitHost(c.url, /^https?:/i.test(c.url) ? 80 : 554) : Brands.splitHost(c.host, Brands.port(c))
        args.push(c.id, hp.host, String(hp.port))
      }
      command = ["bash", "-c",
        'while [ $# -ge 3 ]; do (timeout 2 bash -c ":</dev/tcp/$2/$3" 2>/dev/null && echo "$1 1" || echo "$1 0") & shift 3; done; wait',
        "omacam-reach"].concat(args)
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].trim().split(" ")
          if (parts.length === 2) map[parts[0]] = parts[1] === "1"
        }
        root.reachable = map
      }
    }
    onExited: if (pending) { pending = false; check() }
  }

  Timer {
    interval: Math.max(5, omaSettings.seconds(omaSettings.connection.statusCheckSeconds, 60)) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: reach.check()
  }

  // --- bar button -------------------------------------------------------------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened || root.viewerMode !== ""
    useActiveColor: false
    text: {
      var n = cameraStore.enabledCameras.length
      var icon = "\u{F0567}"
      if (n === 0 || !omaSettings.bar.showCount) return icon
      if (Object.keys(root.reachable).length === 0) return icon + " " + n
      return root.anyOffline ? icon + " " + root.onlineCount + "/" + n : icon + " " + n
    }
    dimmed: cameraStore.loaded && cameraStore.enabledCameras.length === 0
    tooltipText: ""
    onPressed: function(b) {
      var c = omaSettings.bar
      root.barAction(b === Qt.RightButton ? c.rightClick : b === Qt.MiddleButton ? c.middleClick : c.leftClick)
    }

    Rectangle {
      visible: root.anyOffline
      anchors { right: parent.right; top: parent.top; rightMargin: 4; topMargin: Math.round(parent.height / 2 - 8) }
      width: 5; height: 5; radius: 2.5
      color: pal.warn
    }
  }

  // --- dropdown -----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.view === "camera" ? 1180 : root.view === "manage" ? 860 : root.view === "form" ? 680 : 560)
    contentHeight: panel.fittedContentHeight(content.implicitHeight, 980)

    // Keys come from config.json (keys.dropdown in the grid and manage list,
    // keys.enlarged on one camera). The form takes its own keys.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(e) { if (root.view !== "form" && root.handleKey(e)) e.accepted = true }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Item {
          id: content
          width: flick.width
          implicitHeight: root.view === "camera" ? cameraLoader.implicitHeight
                        : root.view === "form" ? formLoader.implicitHeight
                        : root.view === "manage" ? manageLoader.implicitHeight
                        : gridLoader.implicitHeight

          // Kept alive behind the other views so its streams keep running.
          CameraGrid {
            id: gridLoader
            width: parent.width
            visible: root.view === "grid"
            ctx: root
          }

          Loader {
            id: cameraLoader
            width: parent.width
            active: root.view === "camera" && root.opened
            visible: active
            sourceComponent: EnlargedView { width: cameraLoader.width; ctx: root }
          }

          Loader {
            id: formLoader
            width: parent.width
            active: root.view === "form"
            visible: active
            sourceComponent: CameraForm { width: formLoader.width; ctx: root }
          }

          Loader {
            id: manageLoader
            width: parent.width
            active: root.view === "manage" && root.opened
            visible: active
            sourceComponent: ManageView { width: manageLoader.width; ctx: root }
          }
        }
      }
    }
  }

  // --- fullscreen + pins ----------------------------------------------------
  Viewer {
    ctx: root
    screen: root.targetScreen
  }

  Variants {
    model: root.pinned
    delegate: Component {
      PipWindow {
        required property var modelData
        ctx: root
        cameraId: modelData
        slot: root.pinned.indexOf(modelData)
        screen: root.targetScreen
      }
    }
  }
}
