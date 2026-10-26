import QtQuick
import Quickshell.Io
import "Brands.js" as Brands

// Finds a camera's stream. Reads the camera's web page to guess the brand,
// then tries the stream addresses of that brand, the brand picked in the
// form, and finally every other brand, until one answers with video. Stops
// early on a wrong password (that won't change with the path) and skips ports
// that refused or timed out.
//
// result: { ok, kind, brand, variant, width, height, fps, codec, message }
//   kind: ok · auth · notfound · offline
Item {
  id: root
  visible: false

  property bool running: false
  property var result: null
  property int step: 0
  property int total: 0
  property string tryingBrand: ""
  property string detectedBrand: ""

  property var _camera: null
  property var _queue: []
  property var _current: null
  property var _deadPorts: ({})
  property var _seen: ({})
  property var _kinds: ({})

  signal finished(var result)

  function find(camera) {
    cancel()
    _camera = camera
    result = null
    running = true
    step = 0
    total = 0
    tryingBrand = ""
    detectedBrand = ""
    _deadPorts = ({})
    _kinds = ({})
    if (camera.brand === "custom") {
      _queue = [{ brand: "custom", variant: 0 }]
      total = 1
      next()
      return
    }
    var hp = Brands.splitHost(camera.host, 80)
    detect.command = ["curl", "-s", "-i", "-L", "-k", "--max-redirs", "3", "-m", "4", "--max-filesize", "400000", "http://" + hp.host + "/"]
    detect.running = true
  }

  function cancel() {
    detect.running = false
    probe.cancel()
    running = false
  }

  function buildQueue(first) {
    var order = []
    var add = function(id) { if (id && id !== "custom" && order.indexOf(id) === -1) order.push(id) }
    add(first)
    add(_camera.brand)
    for (var i = 0; i < Brands.presets.length; i++) add(Brands.presets[i].id)
    var queue = []
    var seen = {}
    for (var b = 0; b < order.length; b++) {
      var n = Brands.variantCount(order[b])
      for (var v = 0; v < n; v++) {
        var key = Brands.streamUrl({ brand: order[b], host: _camera.host, variant: v }, "main")
        if (seen[key]) continue
        seen[key] = true
        queue.push({ brand: order[b], variant: v })
      }
    }
    _queue = queue
    total = queue.length
  }

  function candidate(c) {
    var cam = {}
    for (var k in _camera) cam[k] = _camera[k]
    cam.brand = c.brand
    cam.variant = c.variant
    return cam
  }

  function next() {
    while (_queue.length > 0) {
      var c = _queue.shift()
      step += 1
      var cam = candidate(c)
      if (c.brand !== "custom" && _deadPorts[Brands.port(cam)]) continue
      _current = c
      tryingBrand = Brands.label(c.brand)
      probe.probe(Brands.streamUrl(cam, "main"))
      return
    }
    // Nothing worked: report the most useful reason.
    var r
    if (_kinds.auth) r = { ok: false, kind: "auth", message: "Wrong username or password" }
    else if (_kinds.path || _kinds.error) r = { ok: false, kind: "notfound", message: "Couldn't find the video stream" }
    else r = { ok: false, kind: "offline", message: "No response from the camera" }
    done(r)
  }

  function done(r) {
    running = false
    result = r
    finished(r)
  }

  Process {
    id: detect
    property string out: ""
    stdout: StdioCollector { id: page; waitForEnd: true; onStreamFinished: detect.out = text }
    onExited: {
      if (!root.running) return
      root.detectedBrand = Brands.detectBrand(page.text || detect.out)
      root.buildQueue(root.detectedBrand)
      root.next()
    }
  }

  Probe {
    id: probe
    onFinished: function(r) {
      if (!root.running) return
      var c = root._current
      if (r.ok) {
        root.done({ ok: true, kind: "ok", brand: c.brand, variant: c.variant, width: r.width, height: r.height, fps: r.fps, codec: r.codec, message: "" })
        return
      }
      var kinds = root._kinds
      kinds[r.kind] = true
      root._kinds = kinds
      if (r.kind === "auth") { root.done(r); return }
      if (r.kind === "offline" && c.brand !== "custom") {
        var dead = root._deadPorts
        dead[Brands.port(root.candidate(c))] = true
        root._deadPorts = dead
      }
      root.next()
    }
  }
}
