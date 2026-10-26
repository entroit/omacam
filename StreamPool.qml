import QtQuick
import "Shared.js" as Shared

// Every camera connection, shared by all views. A view asks for a camera's
// low-res or full stream and gets the one already running if there is one,
// so opening the enlarged view, fullscreen or the wall continues the
// dropdown's streams instead of reconnecting.
Item {
  id: root
  visible: false

  // How long a stream nobody shows stays connected, for going back and forth.
  property int lingerMs: 30000
  // Wait between attempts for a camera that failed.
  property int retrySeconds: 15
  // Smallest delay; off buffers a little for unsteady networks.
  property bool lowLatency: true
  // Bumped when a camera's low-res stream turns out not to work, so views
  // re-ask for the full one.
  property int revision: 0
  // Stream key -> true while it shows pictures.
  property var liveKeys: ({})

  property var streams: ({})
  property int serial: 0

  // "<camera id>|<sub|main>", plus "|<tag>" for a view's own connection.
  function keyFor(cameraId, quality, tag) {
    if (!cameraId) return ""
    var q = quality === "sub" && Shared.subBroken[cameraId] ? "main" : quality
    return cameraId + "|" + q + (tag ? "|" + tag : "")
  }

  function nextTag() { serial += 1; return "own" + serial }

  Component { id: streamComponent; CameraStream {} }

  function attach(key, display, role, camera) {
    var s = streams[key]
    if (!s) {
      s = streamComponent.createObject(root, { pool: root, key: key, quality: key.split("|")[1], camera: camera })
      streams[key] = s
    } else if (camera && s.camera !== camera) {
      s.camera = camera
    }
    s.add(display, role)
    return s
  }

  function detach(key, display, role) {
    var s = streams[key]
    if (s) s.remove(display, role)
  }

  function dispose(stream) {
    if (streams[stream.key] === stream) delete streams[stream.key]
    stream.destroy()
  }

  function setLive(key, live) {
    if ((liveKeys[key] === true) === live) return
    var k = {}
    for (var x in liveKeys) k[x] = liveKeys[x]
    if (live) k[key] = true
    else delete k[key]
    liveKeys = k
  }

  function markSubBroken(cameraId) {
    Shared.subBroken[cameraId] = true
    revision += 1
  }
}
