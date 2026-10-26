import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Brands.js" as Brands
import "Config.js" as Config

// Fullscreen surface: one camera ("single") or every camera ("wall").
// Back returns to where you came from, Esc closes everything.
PanelWindow {
  id: root

  required property var ctx
  readonly property var th: ctx.pal
  readonly property var cams: ctx.store.enabledCameras
  readonly property bool shown: ctx.viewerMode !== ""
  readonly property bool wall: ctx.viewerMode === "wall"
  readonly property int index: {
    for (var i = 0; i < cams.length; i++) if (cams[i].id === ctx.viewerId) return i
    return -1
  }
  readonly property var camera: index >= 0 ? cams[index] : null
  readonly property var cfg: ctx.config
  property bool stripHidden: !cfg.fullscreen.showStrip
  property int wallCursor: -1

  visible: shown
  color: "black"
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }
  WlrLayershell.namespace: "omacam-viewer"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  onShownChanged: if (shown) { wallCursor = -1; Qt.callLater(function() { keys.forceActiveFocus() }) }

  // Hint label for a key from config.json, e.g. key("wall", "close") -> "esc".
  function key(where, action) { return Config.label(cfg.keys[where][action]) }
  function hints(list) { return list.filter(function(h) { return h[0] !== "" }) }
  readonly property string numbers: cfg.keys.cameraNumbers ? "1-" + Math.min(9, cams.length) : ""

  function wallClick(i) {
    var a = cfg.wall.click
    if (a === "fullscreen") jump(i + 1)
    else if (a !== "none") ctx.cameraAction(a, cams[i].id)
  }

  function jump(n) {
    if (n < 1 || n > cams.length) return
    ctx.viewerId = cams[n - 1].id
    ctx.viewerMode = "single"
  }

  function step(d) {
    if (cams.length === 0) return
    var i = index < 0 ? 0 : (index + d + cams.length) % cams.length
    ctx.viewerId = cams[i].id
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onPressed: function(e) {
      var t = e.text
      if (root.cfg.keys.cameraNumbers && t >= "1" && t <= "9" && (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0) { root.jump(Number(t)); e.accepted = true; return }
      if (root.wall) {
        var cols = wallGrid.cols
        var n = root.cams.length
        var w = Config.action(root.cfg.keys.wall, e)
        if (w === "close") root.ctx.closeViewer()
        else if (w === "back") root.ctx.viewerBack()
        else if (w === "right") root.wallCursor = Math.min(n - 1, root.wallCursor + 1)
        else if (w === "left") root.wallCursor = Math.max(0, root.wallCursor - 1)
        else if (w === "down") root.wallCursor = Math.min(n - 1, root.wallCursor < 0 ? 0 : root.wallCursor + cols)
        else if (w === "up") root.wallCursor = Math.max(0, root.wallCursor - cols)
        else if (w === "open") { if (root.wallCursor >= 0) root.jump(root.wallCursor + 1) }
        else if (w === "pin") { if (root.wallCursor >= 0) root.ctx.togglePin(root.cams[root.wallCursor].id) }
        else return
      } else {
        var a = Config.action(root.cfg.keys.fullscreen, e)
        if (a === "close") root.ctx.closeViewer()
        else if (a === "back") root.ctx.viewerBack()
        else if (a === "next") root.step(1)
        else if (a === "previous") root.step(-1)
        else if (a === "toggleStrip") root.stripHidden = !root.stripHidden
        else if (a === "pin") root.ctx.togglePin(root.ctx.viewerId)
        else if (a === "sound") root.ctx.toggleSound(root.ctx.viewerId, "fullscreen")
        else if (a === "wall") root.ctx.viewerMode = "wall"
        else return
      }
      e.accepted = true
    }
  }

  // ===========================================================================
  // Single camera
  // ===========================================================================
  Item {
    anchors.fill: parent
    visible: !root.wall

    CameraFeed {
      id: big
      anchors.fill: parent
      pool: root.ctx.pool
      camera: root.camera
      quality: "main"
      active: root.shown && !root.wall
      fillMode: root.cfg.fullscreen.fill ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
    }

    HoverHandler { id: idle }

    // Top bar
    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: 110
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.7) }
        GradientStop { position: 1; color: "transparent" }
      }
    }

    Row {
      anchors { left: parent.left; top: parent.top; margins: 24 }
      spacing: 16
      ActionButton { solid: true; pal: root.th; icon: "\u{F0141}"; text: "Back"; hint: root.key("fullscreen", "back"); onClicked: root.ctx.viewerBack() }
      Text { anchors.verticalCenter: parent.verticalCenter; text: root.camera ? root.camera.name : ""; font.family: root.th.font; font.pixelSize: Style.font.display; font.weight: Font.Bold; color: "#ffffff" }
    }

    Row {
      anchors { right: parent.right; top: parent.top; margins: 24 }
      spacing: 8
      SoundButton {
        solid: true
        pal: root.th
        sound: root.ctx.sound.soundOf(root.ctx.viewerId)
        on: root.ctx.soundOn(root.ctx.viewerId, "fullscreen")
        key: root.key("fullscreen", "sound")
        onClicked: root.ctx.toggleSound(root.ctx.viewerId, "fullscreen")
      }
      ActionButton { solid: true; pal: root.th; icon: "\u{F0294}"; onClicked: root.ctx.viewerBack() }   // nf-md-fullscreen_exit
      ActionButton {
        solid: true
        pal: root.th
        icon: "\u{F0403}"
        text: root.ctx.isPinned(root.ctx.viewerId) ? "Pinned" : "Pin"
        hint: root.key("fullscreen", "pin")
        selected: root.ctx.isPinned(root.ctx.viewerId)
        onClicked: root.ctx.togglePin(root.ctx.viewerId)
      }
      ActionButton { solid: true; pal: root.th; variant: "primary"; icon: "\u{F0156}"; text: "Close"; hint: root.key("fullscreen", "close"); onClicked: root.ctx.closeViewer() }
    }

    // Side arrows
    ActionButton {
      visible: root.cams.length > 1
      anchors { left: parent.left; leftMargin: 24; verticalCenter: parent.verticalCenter }
      pal: root.th; icon: "\u{F0141}"; padX: 12; padY: 16
      onClicked: root.step(-1)
    }
    ActionButton {
      visible: root.cams.length > 1
      anchors { right: parent.right; rightMargin: 24; verticalCenter: parent.verticalCenter }
      pal: root.th; icon: "\u{F0142}"; padX: 12; padY: 16
      onClicked: root.step(1)
    }

    // Retry / edit when the camera is down
    Row {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: 110
      spacing: 8
      visible: !big.live && big.status !== "connecting" && big.status !== "idle"
      ActionButton { solid: true; pal: root.th; text: "Retry"; onClicked: big.retry() }
      ActionButton { solid: true; pal: root.th; icon: "\u{F03EB}"; text: "Edit camera"; onClicked: root.ctx.editFromViewer(root.ctx.viewerId) }
    }

    // Bottom strip
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: root.stripHidden ? 80 : 190
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.75) }
      }
    }

    Column {
      anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 18 }
      spacing: 10

      ActionButton {
        anchors.right: strip.right
        visible: root.cams.length > 1
        pal: root.th
        fontSize: Style.font.caption + 1
        padY: 3
        icon: root.stripHidden ? "\u{F0143}" : "\u{F0140}"   // chevron_up / chevron_down
        text: root.stripHidden ? "show strip" : "hide strip"
        hint: root.key("fullscreen", "toggleStrip")
        onClicked: root.stripHidden = !root.stripHidden
      }

      Rectangle {
        id: strip
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !root.stripHidden && root.cams.length > 1
        width: stripRow.implicitWidth + 24
        height: stripRow.implicitHeight + 24
        radius: Math.max(root.th.radius, 4)
        color: Qt.rgba(0, 0, 0, 0.45)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.1)

        Row {
          id: stripRow
          anchors.centerIn: parent
          spacing: 8
          Repeater {
            model: root.cams
            delegate: CameraTile {
              required property var modelData
              required property int index
              width: 140; height: 78
              pal: root.th
              pool: root.ctx.pool
              camera: modelData
              number: index + 1
              compact: true
              showNumber: root.cfg.keys.cameraNumbers && index < 9
              selected: modelData.id === root.ctx.viewerId
              active: root.shown && !root.wall && !root.stripHidden && modelData.id !== root.ctx.viewerId
              onClicked: root.ctx.viewerId = modelData.id
            }
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 6
        Repeater {
          model: root.hints([[root.numbers, "jump"], [Config.pairLabel(root.cfg.keys.fullscreen.previous, root.cfg.keys.fullscreen.next), "switch"], [root.key("fullscreen", "toggleStrip"), root.stripHidden ? "show strip" : "hide strip"], [root.key("fullscreen", "sound"), "sound"], [root.key("fullscreen", "pin"), "pin"], [root.key("fullscreen", "close"), "close"]])
          delegate: KeyHint { required property var modelData; pal: root.th; keys: modelData[0]; label: modelData[1] }
        }
      }
    }
  }

  // ===========================================================================
  // Wall
  // ===========================================================================
  Rectangle {
    anchors.fill: parent
    visible: root.wall
    color: root.th.bg

    Item {
      id: wallHeader
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
      height: 36
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 16
        ActionButton { solid: true; pal: root.th; icon: "\u{F0141}"; text: "Back"; hint: root.key("wall", "back"); onClicked: root.ctx.viewerBack() }
        Text { anchors.verticalCenter: parent.verticalCenter; text: "All cameras"; font.family: root.th.font; font.pixelSize: Style.font.heading + 2; font.weight: Font.Bold; color: root.th.fg }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          visible: wallGrid.liveCount < root.cams.length
          width: onlineText.implicitWidth + 24; height: 22
          radius: root.th.radius
          color: root.th.tint(root.th.fg, 0.06)
          Rectangle { x: 9; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: root.th.warn }
          Text { id: onlineText; x: 19; anchors.verticalCenter: parent.verticalCenter; text: wallGrid.liveCount + "/" + root.cams.length + " live"; font.family: root.th.font; font.pixelSize: Style.font.caption + 1; color: root.th.fg }
        }
      }
      Row {
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: 16
        Text { anchors.verticalCenter: parent.verticalCenter; text: ({ fullscreen: "click: fullscreen", enlarge: "click: enlarge", pin: "click: pin" })[root.cfg.wall.click] || ""; font.family: root.th.font; font.pixelSize: Style.font.caption + 1; color: root.th.dim }
        ActionButton { solid: true; pal: root.th; variant: "primary"; icon: "\u{F0156}"; text: "Close"; hint: root.key("wall", "close"); onClicked: root.ctx.closeViewer() }
      }
    }

    Item {
      id: wallGrid
      anchors { left: parent.left; right: parent.right; top: wallHeader.bottom; bottom: wallFooter.top; margins: 20; topMargin: 16; bottomMargin: 12 }
      readonly property int n: root.cams.length
      readonly property int cols: root.cfg.wall.columns > 0 ? Math.round(root.cfg.wall.columns) : n <= 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4
      readonly property int rows: Math.max(1, Math.ceil(n / cols))
      readonly property real gap: 12
      readonly property real cellW: (width - gap * (cols - 1)) / cols
      readonly property real cellH: (height - gap * (rows - 1)) / rows
      property int liveCount: 0

      Timer {
        interval: 1000; repeat: true; running: root.wall && root.shown
        onTriggered: {
          var c = 0
          for (var i = 0; i < wallTiles.count; i++) { var t = wallTiles.itemAt(i); if (t && t.feed.live) c++ }
          wallGrid.liveCount = c
        }
      }

      Repeater {
        id: wallTiles
        model: root.cams
        delegate: CameraTile {
          id: wt
          required property var modelData
          required property int index
          x: (index % wallGrid.cols) * (wallGrid.cellW + wallGrid.gap)
          y: Math.floor(index / wallGrid.cols) * (wallGrid.cellH + wallGrid.gap)
          width: wallGrid.cellW
          height: wallGrid.cellH
          pal: root.th
          pool: root.ctx.pool
          camera: modelData
          number: index + 1
          showNumber: root.cfg.keys.cameraNumbers && index < 9
          quality: wallGrid.n > 4 ? "sub" : "main"
          fillMode: root.cfg.wall.fill ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
          active: root.shown && root.wall
          selected: root.wallCursor === index
          onClicked: root.wallClick(index)

          Row {
            anchors { right: parent.right; top: parent.top; margins: 10 }
            spacing: 6
            visible: wt.hot || wt.selected
            ActionButton { solid: true; pal: root.th; variant: "primary"; icon: "\u{F0293}"; text: "Enlarge"; onClicked: root.jump(wt.index + 1) }
            ActionButton {
              pal: root.th
              icon: "\u{F0403}"
              selected: root.ctx.isPinned(wt.modelData.id)
              onClicked: root.ctx.togglePin(wt.modelData.id)
            }
          }

          Row {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: Math.min(84, wt.height * 0.26)
            spacing: 8
            visible: !wt.feed.live && wt.feed.status !== "connecting" && wt.feed.status !== "idle" && wt.height > 160
            ActionButton { solid: true; pal: root.th; text: "Retry"; onClicked: wt.feed.retry() }
            ActionButton { solid: true; pal: root.th; text: "Edit camera"; onClicked: root.ctx.editFromViewer(wt.modelData.id) }
          }
        }
      }
    }

    Row {
      id: wallFooter
      anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 16 }
      spacing: 6
      Repeater {
        model: root.hints([[root.key("wall", "left") + root.key("wall", "up") + root.key("wall", "down") + root.key("wall", "right"), "move"], [root.numbers, "jump"], [root.key("wall", "open"), "enlarge"], [root.key("wall", "pin"), "pin"], [root.key("wall", "back"), "back"], [root.key("wall", "close"), "close"]])
        delegate: KeyHint { required property var modelData; pal: root.th; keys: modelData[0]; label: modelData[1] }
      }
    }
  }
}
