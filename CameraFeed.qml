import QtQuick
import QtMultimedia
import qs.Commons
import "Shared.js" as Shared

// One camera picture on screen. The connection itself lives in the
// StreamPool: this asks for the camera's stream and shows it, so the same
// stream moves between views without reconnecting. When the asked-for
// quality isn't live yet but the other one is (the dropdown's low-res stream
// while the full one connects), that one is shown meanwhile.
// Status, for the surrounding UI:
//   idle · connecting · live · offline · auth · path · error
Item {
  id: root

  property var pool: null
  property var camera: null
  property string quality: "sub"
  property bool active: true
  // Whether the view is on screen right now; views that stay alive while
  // hidden (the dropdown grid) say so, so their stream can go elsewhere.
  property bool shown: true
  property int fillMode: VideoOutput.PreserveAspectCrop
  property bool showStatus: true
  // A connection of its own, never shared (the add/edit form's preview,
  // whose address and password aren't saved yet).
  property string privateTag: ""

  readonly property string cameraId: camera && camera.id ? camera.id : (camera && privateTag !== "" ? "draft" : "")
  readonly property bool enabled_: !!camera && camera.enabled !== false
  readonly property bool wanted: active && !!pool && enabled_ && cameraId !== ""
  readonly property bool showing: wanted && shown && visible

  // Set when another window already shows this stream: then this view opens
  // its own connection. Kept until the view stops playing.
  property string ownTag: ""
  onWantedChanged: if (!wanted) ownTag = ""
  function goPersonal() { if (wanted && ownTag === "") ownTag = pool.nextTag() }

  readonly property string primaryKey: wanted ? pool.keyFor(cameraId, quality, privateTag || ownTag, pool.revision) : ""
  readonly property string otherKey: wanted ? pool.keyFor(cameraId, quality === "main" ? "sub" : "main", "", pool.revision) : ""
  property var primary: null
  property var fallback: null

  // A stream counts as showing here only once a new picture reached this
  // view's output: until then the output still holds whatever it showed last
  // (another camera, or this one minutes ago).
  readonly property bool primaryLive: primaryFresh && primaryPlaying
  readonly property bool fallbackLive: fallbackFresh && fallbackPlaying
  readonly property bool primaryPlaying: !!primary && primary.live && primary.output === primaryVideo
  readonly property bool fallbackPlaying: !!fallback && fallback.live && fallback.output === fallbackVideo
  property bool primaryFresh: false
  property bool fallbackFresh: false
  onPrimaryChanged: primaryFresh = false
  onFallbackChanged: fallbackFresh = false
  onPrimaryPlayingChanged: if (!primaryPlaying) primaryFresh = false
  onFallbackPlayingChanged: if (!fallbackPlaying) fallbackFresh = false
  Connections {
    target: primaryVideo.videoSink
    function onVideoFrameChanged() { if (root.primaryPlaying) root.primaryFresh = true }
  }
  Connections {
    target: fallbackVideo.videoSink
    function onVideoFrameChanged() { if (root.fallbackPlaying) root.fallbackFresh = true }
  }
  readonly property string fallbackKey: wanted && privateTag === "" && !primaryLive && otherKey !== primaryKey && pool.liveKeys[otherKey] === true ? otherKey : ""

  readonly property bool live: primaryLive || fallbackLive
  readonly property string status: live ? "live" : primary ? primary.status : "idle"
  readonly property string message: primary ? primary.message : ""
  readonly property int retryIn: primary ? primary.retryIn : 0
  readonly property bool failed: status === "offline" || status === "auth" || status === "path" || status === "error"
  readonly property size resolution: primaryLive ? primary.resolution : fallbackLive ? fallback.resolution : Qt.size(0, 0)
  property string snapshot: ""

  function retry() { if (primary) primary.retry() }
  function videoFor(role) { return role === "primary" ? primaryVideo : fallbackVideo }

  // --- holding streams ---------------------------------------------------------
  property string _primaryKey: ""
  property string _fallbackKey: ""

  function bindPrimary() {
    if (_primaryKey === primaryKey) return
    if (_primaryKey !== "") pool.detach(_primaryKey, root, "primary")
    _primaryKey = primaryKey
    primary = _primaryKey !== "" ? pool.attach(_primaryKey, root, "primary", camera) : null
  }
  function bindFallback() {
    if (_fallbackKey === fallbackKey) return
    if (_fallbackKey !== "") pool.detach(_fallbackKey, root, "fallback")
    _fallbackKey = fallbackKey
    fallback = _fallbackKey !== "" ? pool.attach(_fallbackKey, root, "fallback", camera) : null
  }

  onPrimaryKeyChanged: bindPrimary()
  onFallbackKeyChanged: bindFallback()
  onShowingChanged: { if (primary) primary.pick(); if (fallback) fallback.pick() }
  // An edited camera (new address or password) restarts its stream.
  onCameraChanged: if (primary && camera) primary.camera = camera
  Component.onCompleted: { bindPrimary(); bindFallback() }
  Component.onDestruction: {
    if (!pool) return
    if (_primaryKey !== "") pool.detach(_primaryKey, root, "primary")
    if (_fallbackKey !== "") pool.detach(_fallbackKey, root, "fallback")
  }

  // Latest still picture while (re)connecting.
  Timer {
    interval: 250
    repeat: true
    running: root.showing && !root.live
    triggeredOnStart: true
    onTriggered: {
      var u = Shared.snapshotUrl(root.cameraId)
      if (u !== root.snapshot) root.snapshot = u
    }
  }

  readonly property color fg: Color.foreground
  readonly property color dim: Qt.darker(Color.foreground, 1.6)

  Rectangle {
    anchors.fill: parent
    color: Qt.darker(Color.background, 1.25)
  }

  Image {
    anchors.fill: parent
    visible: !root.live && source != ""
    source: root.snapshot
    fillMode: root.fillMode === VideoOutput.PreserveAspectFit ? Image.PreserveAspectFit : Image.PreserveAspectCrop
    // A picture is enough while connecting; dim it only when the camera failed.
    opacity: root.failed ? 0.35 : 0.9
    cache: false
    asynchronous: true
  }

  VideoOutput {
    id: fallbackVideo
    anchors.fill: parent
    fillMode: root.fillMode
    visible: root.fallbackLive && !root.primaryLive
  }

  VideoOutput {
    id: primaryVideo
    anchors.fill: parent
    fillMode: root.fillMode
    visible: root.primaryLive
  }

  // --- status overlay -------------------------------------------------------

  Column {
    anchors.centerIn: parent
    width: parent.width - 24
    spacing: Math.max(4, Math.round(root.height * 0.025))
    // While connecting over a picture, the tile's badge says so; keep the
    // picture clear.
    visible: root.showStatus && !root.live && root.camera !== null && !(root.status === "connecting" && root.snapshot !== "")

    Text {
      id: statusIcon
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.status === "connecting" ? "\u{F0450}"     // nf-md-refresh
          : root.status === "auth"       ? "\u{F033E}"     // nf-md-lock
          : root.enabled_                ? "\u{F0BDB}"     // nf-md-video_off_outline
          : "\u{F0209}"                                    // nf-md-eye_off
      font.family: Style.font.family
      font.pixelSize: Math.max(16, Math.min(40, root.height * 0.14))
      color: root.status === "auth" || root.status === "path" ? Color.urgent : root.dim
      RotationAnimation on rotation {
        running: root.status === "connecting" && statusIcon.visible
        loops: Animation.Infinite
        from: 0; to: 360; duration: 1100
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: !root.enabled_ ? "Hidden"
          : root.status === "connecting" ? "Connecting…"
          : root.status === "auth" ? "Wrong password"
          : root.status === "path" ? "Wrong stream address"
          : root.status === "offline" ? "Camera offline"
          : root.status === "error" ? "Can't play stream"
          : ""
      font.family: Style.font.family
      font.pixelSize: Math.max(11, Math.min(18, root.height * 0.07))
      font.weight: Font.DemiBold
      color: root.status === "auth" || root.status === "path" ? Color.urgent : root.fg
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: root.height > 110 && text !== ""
      text: root.retryIn > 0 ? "retrying in " + root.retryIn + "s" : (root.failed && root.primary && (root.primary.attempting || root.primary.probing) ? "retrying…" : "")
      font.family: Style.font.family
      font.pixelSize: Math.max(10, Math.min(13, root.height * 0.05))
      color: root.dim
      elide: Text.ElideRight
    }
  }

  onStatusChanged: if (status !== "connecting") statusIcon.rotation = 0
}
