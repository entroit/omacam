import QtQuick
import QtMultimedia
import "Brands.js" as Brands
import "Shared.js" as Shared

// Plays the sound of one camera, with no video. Pictures come from the video
// tiles; sound runs in this separate audio-only player because Qt drops the
// audio of some low-res streams while it also renders their video. Only one
// camera is ever audible, so there is at most one audio stream open.
Item {
  id: root
  visible: false

  property var camera: null
  property bool muted: false
  // Camera id -> true / false once checked whether it really sends sound.
  property var known: ({})

  readonly property string cameraId: camera && camera.id ? camera.id : ""
  readonly property string url: camera ? Brands.streamUrl(camera, Shared.subBroken[cameraId] ? "main" : "sub") : ""
  readonly property bool playing: player.playbackState === MediaPlayer.PlayingState

  function soundOf(id) {
    return known[id] === true ? "yes" : known[id] === false ? "no" : "unknown"
  }

  function remember(id, hasSound) {
    var k = {}
    for (var key in known) k[key] = known[key]
    k[id] = hasSound
    known = k
    Shared.sound[id] = hasSound
  }

  // Muting is instant; after staying muted a while the stream is closed.
  property bool parked: false
  property real parkSeconds: 20
  onMutedChanged: { if (muted) parkTimer.restart(); else { parkTimer.stop(); parked = false } }
  Timer { id: parkTimer; interval: Math.max(1, root.parkSeconds) * 1000; onTriggered: root.parked = true }

  // Nothing to play for cameras whose audio track turned out to be empty.
  readonly property bool wanted: url !== "" && known[cameraId] !== false && !parked

  function restart() {
    player.stop()
    player.source = ""
    if (!wanted) return
    player.source = url
    player.play()
    if (known[cameraId] === undefined && !check.running) { check.forId = cameraId; check.check(Brands.streamUrl(camera, "main")) }
  }

  onUrlChanged: startDelay.restart()
  onWantedChanged: startDelay.restart()
  Timer { id: startDelay; interval: 30; onTriggered: root.restart() }

  MediaPlayer {
    id: player
    audioOutput: AudioOutput { muted: root.muted }
    playbackOptions.playbackIntent: PlaybackOptions.PlaybackIntent.LowLatencyStreaming
    // Reconnect if the stream drops or fails while it should be playing.
    onMediaStatusChanged: if ((mediaStatus === MediaPlayer.EndOfMedia || mediaStatus === MediaPlayer.InvalidMedia) && root.wanted) retry.restart()
    onErrorOccurred: if (root.wanted) retry.restart()
  }

  Timer { id: retry; interval: 5000; onTriggered: if (root.wanted) root.restart() }

  SoundCheck {
    id: check
    property string forId: ""
    onFinished: function(hasSound) { if (forId !== "") root.remember(forId, hasSound) }
  }

  Component.onCompleted: {
    // Results from earlier in this session (e.g. from another monitor's bar).
    var k = {}
    for (var id in Shared.sound) k[id] = Shared.sound[id]
    known = k
  }
}
