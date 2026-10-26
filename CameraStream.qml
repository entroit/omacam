import QtQuick
import QtMultimedia
import "Brands.js" as Brands
import "Shared.js" as Shared

// One connection to a camera (its low-res or full stream), owned by the
// StreamPool rather than by any view. Views showing this camera "hold" it;
// the picture goes to one of them at a time, preferring one on screen, so
// moving between the dropdown, the enlarged view, fullscreen and the wall
// just hands the running stream over. It reconnects and retries on its own
// and reports a simple status:
//   idle · connecting · live · offline · auth · path · error
Item {
  id: root
  visible: false

  required property var pool
  required property string key
  required property string quality     // "sub" or "main"
  property var camera: null
  readonly property int retrySeconds: pool.retrySeconds

  readonly property bool personal: key.split("|").length > 2
  readonly property string cameraId: camera && camera.id ? camera.id : ""
  readonly property string configUrl: camera ? Brands.streamUrl(camera, quality) : ""
  readonly property bool enabled_: !!camera && camera.enabled !== false

  // [{ display, role }]: role "primary" for views that asked for this stream,
  // "fallback" for views showing it only until their own stream is live.
  property var holders: []
  property var current: null
  // Never left without an output: Qt drops the video decoder when a player
  // loses its output, and the next view would then wait seconds for the
  // camera's next full picture. Unwatched streams play into `parking`.
  property var output: null
  readonly property bool held: holders.length > 0

  property string status: "idle"
  property string message: ""
  property int retryIn: 0
  readonly property bool live: status === "live"
  readonly property bool failed: status === "offline" || status === "auth" || status === "path" || status === "error"
  readonly property size resolution: {
    var r = player.metaData.value(MediaMetaData.Resolution)
    return r ? r : Qt.size(0, 0)
  }
  onResolutionChanged: if (quality === "main" && cameraId !== "" && resolution.width > 0) Shared.mainResolution[cameraId] = resolution.width + "×" + resolution.height
  onLiveChanged: pool.setLive(key, live)

  // --- holders --------------------------------------------------------------
  function add(display, role) {
    var hs = holders.filter(function(h) { return !(h.display === display && h.role === role) })
    hs.push({ display: display, role: role })
    holders = hs
    pick()
  }

  function remove(display, role) {
    // pick() hands the picture straight to the next holder (or parks it).
    holders = holders.filter(function(h) { return !(h.display === display && h.role === role) })
    pick()
  }

  function isShowing(h) { return h.display.showing }

  // Who gets the picture: whoever has it keeps it while on screen; otherwise
  // the latest holder on screen, then the latest holder at all.
  function pick() {
    var hs = holders
    if (current && hs.indexOf(current) !== -1 && isShowing(current)) { checkClash(); return }
    var best = null
    var order = [
      function(h) { return isShowing(h) && h.role === "primary" },
      function(h) { return isShowing(h) },
      function(h) { return h.role === "primary" },
      function(h) { return true }
    ]
    for (var o = 0; o < order.length && !best; o++)
      for (var i = hs.length - 1; i >= 0; i--) if (order[o](hs[i])) { best = hs[i]; break }
    if (best !== current) {
      current = best
      output = best ? best.display.videoFor(best.role) : parking
    }
    checkClash()
  }

  // Two views on screen in different windows can't share one picture (the
  // dropdown's enlarged view and a pinned player of the same camera): if
  // that lasts, the one without it opens its own connection.
  function clashing() {
    return holders.filter(function(h) { return h !== root.current && h.role === "primary" && root.isShowing(h) })
  }
  function checkClash() { if (clashing().length > 0) clashTimer.restart() }
  Timer {
    id: clashTimer
    interval: 400
    onTriggered: {
      var c = root.clashing()
      for (var i = 0; i < c.length; i++) c[i].display.goPersonal()
    }
  }

  // Nobody holds it any more: keep a live stream a little while, since
  // views come and go (back, forward, fullscreen and out again).
  onHeldChanged: {
    if (held) {
      linger.stop()
      if (status === "idle") requestStart()
    } else {
      linger.interval = live && !personal ? pool.lingerMs : 1500
      linger.restart()
    }
  }
  Timer { id: linger; onTriggered: root.pool.dispose(root) }

  // --- connection -----------------------------------------------------------
  // True while a connection attempt is in flight; failed cameras keep their
  // status (offline, wrong password…) during retries instead of flashing
  // back to "connecting".
  property bool attempting: false
  property bool loaded: false        // connection open, waiting for the first picture
  property bool probing: false
  property string url: ""

  function start() {
    retryTimer.stop()
    reconnect.stop()
    retryIn = 0
    url = configUrl
    if (!enabled_ || url === "") {
      stop()
      return
    }
    if (!failed) status = "connecting"
    attempting = true
    loaded = false
    player.stop()
    player.source = url
    player.play()
  }

  function stop() {
    retryTimer.stop()
    reconnect.stop()
    probe.cancel()
    probing = false
    attempting = false
    loaded = false
    player.stop()
    player.source = ""
    status = "idle"
  }

  function retry() {
    status = "connecting"
    start()
  }

  // Playback failed or stalled: stop, then ask ffprobe why.
  function fail() {
    if (probing) return
    // The low-res stream doesn't work for some cameras: their views move to
    // the full one.
    if (quality === "sub" && cameraId !== "" && !Shared.subBroken[cameraId]) {
      attempting = false
      player.stop()
      player.source = ""
      pool.markSubBroken(cameraId)
      return
    }
    probing = true
    attempting = false
    player.stop()
    player.source = ""
    probe.probe(url)
  }

  function markLive() {
    if (!attempting) return
    attempting = false
    loaded = false
    status = "live"
    message = ""
  }

  // Creation and the camera address arriving ask for a start within the same
  // moment; merge them so the player starts once.
  function requestStart() { startDelay.restart() }
  Timer { id: startDelay; interval: 30; onTriggered: if (root.held || root.live) root.start() }

  onConfigUrlChanged: if (held && status !== "idle") { status = "connecting"; requestStart() }
  onEnabled_Changed: if (!enabled_) stop()
  Component.onCompleted: { if (!output) output = parking; requestStart() }
  Component.onDestruction: { pool.setLive(key, false); player.stop() }

  MediaPlayer {
    id: player
    videoOutput: root.output
    playbackOptions.playbackIntent: root.pool.lowLatency ? PlaybackOptions.PlaybackIntent.LowLatencyStreaming : PlaybackOptions.PlaybackIntent.Playback
    onMediaStatusChanged: {
      if (!root.attempting && root.status !== "live") return
      if (mediaStatus === MediaPlayer.BufferedMedia || mediaStatus === MediaPlayer.LoadedMedia) {
        if (root.attempting) root.loaded = true
      } else if (mediaStatus === MediaPlayer.EndOfMedia && root.status === "live") {
        // Stream dropped mid-way: reconnect quietly.
        root.status = "connecting"
        reconnect.restart()
      } else if (mediaStatus === MediaPlayer.InvalidMedia) {
        root.fail()
      }
    }
    onErrorOccurred: function(error, errorString) {
      if (root.attempting) root.fail()
    }
  }

  Timer {
    id: reconnect
    interval: 1000
    onTriggered: root.start()
  }

  // FFmpeg waits minutes for an unreachable host; give up sooner and let the
  // probe say why. Once connected, allow time for the first full picture:
  // cameras send one only every few seconds.
  Timer {
    interval: root.loaded ? 20000 : 10000
    running: root.attempting
    onTriggered: if (root.attempting) root.fail()
  }

  // Live means a picture arrived, not just that the connection opened.
  Connections {
    target: root.output ? root.output.videoSink : null
    // Deferred: going live hands pictures around, which mustn't happen
    // while the output is still being switched.
    function onVideoFrameChanged() { if (root.attempting) Qt.callLater(root.markLive) }
  }

  VideoOutput { id: parking; width: 1; height: 1; visible: false }

  Probe {
    id: probe
    onFinished: function(r) {
      root.probing = false
      if (!root.held) return
      if (r.ok) {
        // ffprobe can read it, so playback hiccupped: try again soon.
        reconnect.restart()
        return
      }
      root.status = r.kind
      root.message = r.message
      root.retryIn = root.retrySeconds
      retryTimer.restart()
    }
  }

  Timer {
    id: retryTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.retryIn -= 1
      if (root.retryIn <= 0) root.start()
    }
  }
}
