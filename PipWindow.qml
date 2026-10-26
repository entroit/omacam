import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Shared.js" as Shared

// A camera pinned to the desktop: a small always-on-top player. Drag it
// anywhere (it snaps to screen edges), resize from any corner (keeps the
// camera's shape), double-click for fullscreen. Hover shows sound / expand /
// fullscreen / unpin.
//
// The surface covers the whole screen but is transparent, and its input
// mask is only the player, so clicks everywhere else reach your windows.
// Moving or resizing just moves the player inside the surface: nothing has
// to wait for the compositor to reposition a window, so it never jumps.
PanelWindow {
  id: root

  required property var ctx
  required property string cameraId
  property int slot: 0
  readonly property var th: ctx.pal
  readonly property var camera: ctx.store.find(cameraId)

  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real topLimit: ctx.barHeight + 8
  readonly property real gap: 12
  readonly property real minW: 240
  readonly property real maxW: Math.min(1280, screenW - 2 * gap)

  property real w: Math.max(minW, Number(ctx.config.pinned.width) || 360)
  // The camera's own shape (4:3 cameras would be cut off in a 16:9 frame).
  property real aspect: 16 / 9
  readonly property real h: Math.round(w / aspect)
  property real px: -1
  property real py: -1

  // "move", "resize" or "" while nothing is held.
  property string gesture: ""

  visible: camera !== null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; left: true; right: true; bottom: true }
  mask: Region { item: frame }
  WlrLayershell.namespace: "omacam-pip"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  Component.onCompleted: {
    // Come back where this camera was last left; otherwise stack top-right.
    var saved = Shared.pip[cameraId]
    if (saved) { w = saved.w; px = saved.px; py = saved.py; if (saved.aspect) aspect = saved.aspect }
    placeIfNeeded()
  }

  // Place once the surface knows the screen size.
  onScreenWChanged: placeIfNeeded()
  function placeIfNeeded() {
    if (screenW <= 0 || screenH <= 0) return
    if (px < 0 || py < 0) { px = screenW - w - gap; py = topLimit + slot * (h + gap) }
    clamp()
  }

  function remember() { Shared.pip[cameraId] = { px: px, py: py, w: w, aspect: aspect } }

  function clamp() {
    w = Math.max(minW, Math.min(maxW, w))
    px = Math.max(gap, Math.min(screenW - w - gap, px))
    py = Math.max(topLimit, Math.min(screenH - h - gap, py))
  }

  function snap() {
    var edge = Math.max(0, Number(ctx.config.pinned.snapDistance) || 0)
    if (px < gap + edge) px = gap
    if (px + w > screenW - gap - edge) px = screenW - w - gap
    if (py < topLimit + edge) py = topLimit
    if (py + h > screenH - gap - edge) py = screenH - h - gap
  }

  // Adopt the picture's shape once the stream reports its size, keeping the
  // player's centre where it was.
  Connections {
    target: tile.feed
    function onResolutionChanged() {
      var r = tile.feed.resolution
      if (r.width <= 0 || r.height <= 0) return
      var a = r.width / r.height
      if (Math.abs(a - root.aspect) < 0.01) return
      var cy = root.py + root.h / 2
      root.aspect = a
      root.py = cy - root.h / 2
      root.clamp()
      root.remember()
    }
  }

  // --- move -----------------------------------------------------------------
  property real grabX: 0
  property real grabY: 0

  // --- resize (any corner; the opposite corner stays put) --------------------
  property real anchorX: 0
  property real anchorY: 0
  property bool fromLeft: false
  property bool fromTop: false
  property real cornerOffX: 0
  property real cornerOffY: 0

  function beginResize(left, top, p) {
    fromLeft = left
    fromTop = top
    anchorX = left ? px + w : px
    anchorY = top ? py + h : py
    cornerOffX = p.x - (left ? px : px + w)
    cornerOffY = p.y - (top ? py : py + h)
    gesture = "resize"
  }

  function resizeTo(p) {
    var cx = p.x - cornerOffX
    var cy = p.y - cornerOffY
    // Follow whichever direction the pointer moved further, at the camera's shape.
    var nw = Math.max(Math.abs(cx - anchorX), Math.abs(cy - anchorY) * aspect)
    var roomX = fromLeft ? anchorX - gap : screenW - gap - anchorX
    var roomY = (fromTop ? anchorY - topLimit : screenH - gap - anchorY) * aspect
    w = Math.max(minW, Math.min(maxW, roomX, roomY, nw))
    px = fromLeft ? anchorX - w : anchorX
    py = fromTop ? anchorY - h : anchorY
  }

  function finish() {
    if (gesture === "") return
    gesture = ""
    snap()
    remember()
  }

  Rectangle {
    id: frame
    x: Math.round(root.px)
    y: Math.round(root.py)
    width: Math.round(root.w)
    height: root.h
    radius: Math.max(root.th.radius, 4)
    color: root.th.sunken
    clip: true
    border.width: 1
    border.color: hover.hovered || root.gesture !== "" ? root.th.tint(root.th.accent, 0.8) : root.th.lineStrong

    HoverHandler { id: hover }

    CameraTile {
      id: tile
      anchors.fill: parent
      anchors.margins: 1
      pal: root.th
      pool: root.ctx.pool
      camera: root.camera
      compact: true
      showMeta: false
      showStatus: true
      border.width: 0
      // Always the full stream: switching streams while resizing would blank
      // the picture for seconds, and one hardware-decoded stream is cheap.
      quality: "main"
      fillMode: VideoOutput.PreserveAspectFit
      active: root.visible
      // Under the fullscreen viewer the picture is better used there.
      shown: root.ctx.viewerMode === ""
    }

    // Name chip, always visible
    Rectangle {
      visible: !hover.hovered || root.gesture !== ""
      anchors { left: parent.left; bottom: parent.bottom; margins: 8 }
      width: chip.implicitWidth + 16; height: 22
      radius: root.th.radius
      color: Qt.rgba(0, 0, 0, 0.55)
      Row {
        id: chip
        anchors.centerIn: parent
        spacing: 6
        Rectangle { visible: !tile.feed.live; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: tile.feed.failed ? root.th.urgent : root.th.warn }
        Text { text: root.camera ? root.camera.name : ""; font.family: root.th.font; font.pixelSize: 11; font.weight: Font.DemiBold; color: "#ffffff" }
        Text { visible: root.ctx.soundOn(root.cameraId, "pip:" + root.cameraId) && root.ctx.sound.soundOf(root.cameraId) !== "no"; text: "\u{F057E}"; font.family: root.th.font; font.pixelSize: 12; color: "#ffffff" }
      }
    }

    // Drag anywhere on the picture
    MouseArea {
      id: dragArea
      anchors.fill: parent
      cursorShape: root.gesture === "move" ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      property real sx: 0
      property real sy: 0
      onPressed: function(m) {
        var p = mapToItem(null, m.x, m.y)
        sx = p.x; sy = p.y
        root.grabX = p.x - root.px
        root.grabY = p.y - root.py
      }
      onPositionChanged: function(m) {
        if (!pressed) return
        var p = mapToItem(null, m.x, m.y)
        if (root.gesture === "") {
          if (Math.abs(p.x - sx) + Math.abs(p.y - sy) < 5) return   // still a click
          root.gesture = "move"
        }
        root.px = p.x - root.grabX
        root.py = p.y - root.grabY
        root.clamp()
      }
      onReleased: root.finish()
      onCanceled: root.finish()
      onDoubleClicked: root.ctx.openFullscreen(root.cameraId)
    }

    // Hover header with controls
    Rectangle {
      visible: hover.hovered && root.gesture === ""
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: 40
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.75) }
        GradientStop { position: 1; color: "transparent" }
      }
      Row {
        anchors { left: parent.left; leftMargin: 30; verticalCenter: parent.verticalCenter; verticalCenterOffset: -3 }
        spacing: 8
        Text { anchors.verticalCenter: parent.verticalCenter; text: root.camera ? root.camera.name : ""; font.family: root.th.font; font.pixelSize: 12; font.weight: Font.DemiBold; color: "#ffffff" }
      }
      Row {
        anchors { right: parent.right; rightMargin: 30; verticalCenter: parent.verticalCenter; verticalCenterOffset: -3 }
        spacing: 4
        SoundButton {
          solid: true
          pal: root.th
          padX: 6; padY: 3
          showLabel: false
          sound: root.ctx.sound.soundOf(root.cameraId)
          on: root.ctx.soundOn(root.cameraId, "pip:" + root.cameraId)
          onClicked: root.ctx.toggleSound(root.cameraId, "pip:" + root.cameraId)
        }
        ActionButton { solid: true; pal: root.th; padX: 6; padY: 3; icon: "\u{F0616}"; onClicked: root.ctx.openCamera(root.cameraId, true) }     // nf-md-arrow_expand
        ActionButton { solid: true; pal: root.th; padX: 6; padY: 3; icon: "\u{F0293}"; onClicked: root.ctx.openFullscreen(root.cameraId) }
        ActionButton { solid: true; pal: root.th; padX: 6; padY: 3; icon: "\u{F0156}"; onClicked: root.ctx.unpin(root.cameraId) }
      }
    }

    // Resize grips in all four corners (the controls row leaves them free).
    Repeater {
      model: [{ left: true, top: true }, { left: false, top: true }, { left: true, top: false }, { left: false, top: false }]
      delegate: Item {
        id: grip
        required property var modelData
        width: 24; height: 24
        x: modelData.left ? 0 : frame.width - width
        y: modelData.top ? 0 : frame.height - height
        z: 2
        visible: hover.hovered || root.gesture === "resize"

        Canvas {
          anchors.fill: parent
          anchors.margins: 6
          property color ink: Qt.rgba(1, 1, 1, gripArea.containsMouse || root.gesture === "resize" ? 0.95 : 0.7)
          onInkChanged: requestPaint()
          onPaint: {
            var g = getContext("2d")
            g.clearRect(0, 0, width, height)
            g.strokeStyle = ink
            g.lineWidth = 2
            g.beginPath()
            var l = grip.modelData.left, t = grip.modelData.top
            var x0 = l ? 1 : width - 1, y0 = t ? 1 : height - 1
            g.moveTo(x0, t ? height - 2 : 2); g.lineTo(x0, y0); g.lineTo(l ? width - 2 : 2, y0)
            g.stroke()
          }
        }

        MouseArea {
          id: gripArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: grip.modelData.left === grip.modelData.top ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
          onPressed: function(m) { root.beginResize(grip.modelData.left, grip.modelData.top, mapToItem(null, m.x, m.y)) }
          onPositionChanged: function(m) { if (pressed && root.gesture === "resize") root.resizeTo(mapToItem(null, m.x, m.y)) }
          onReleased: root.finish()
          onCanceled: root.finish()
        }
      }
    }
  }
}
