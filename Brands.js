.pragma library

// Stream address presets for common IP camera brands. Each preset lists one
// or more stream layouts (scheme, port, main + sub path on channel 1); some
// brands use different addresses per model, so "Test connection" tries them
// in order and the camera remembers the one that answered (`variant`). The sub
// stream feeds the small tiles so six cameras don't decode six full-resolution
// streams at once.
//
// To support another brand, add one entry here.
function rtsp(main, sub, port) { return { scheme: "rtsp", port: port || 554, main: main, sub: sub } }
function http(main, sub, port) { return { scheme: "http", port: port || 80, main: main, sub: sub || main } }

var presets = [
  { id: "hikvision", label: "Hikvision",       streams: [rtsp("/Streaming/Channels/101", "/Streaming/Channels/102"), rtsp("/h264/ch1/main/av_stream", "/h264/ch1/sub/av_stream")] },
  { id: "dahua",     label: "Dahua / Amcrest", streams: [rtsp("/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1")] },
  { id: "reolink",   label: "Reolink",         streams: [rtsp("/h264Preview_01_main", "/h264Preview_01_sub"), rtsp("/Preview_01_main", "/Preview_01_sub")] },
  { id: "tapo",      label: "TP-Link Tapo",    streams: [rtsp("/stream1", "/stream2")] },
  { id: "dlink",     label: "D-Link",          streams: [rtsp("/live1.sdp", "/live2.sdp"), rtsp("/play1.sdp", "/play2.sdp"), http("/video/mjpg.cgi"), http("/mjpeg.cgi")] },
  { id: "ezviz",     label: "EZVIZ",           streams: [rtsp("/h264/ch1/main/av_stream", "/h264/ch1/sub/av_stream")] },
  { id: "axis",      label: "Axis",            streams: [rtsp("/axis-media/media.amp", "/axis-media/media.amp?resolution=640x360")] },
  { id: "uniview",   label: "Uniview",         streams: [rtsp("/unicast/c1/s0/live", "/unicast/c1/s1/live")] },
  { id: "foscam",    label: "Foscam",          streams: [rtsp("/videoMain", "/videoSub", 88)] },
  { id: "custom",    label: "Other / Custom URL", streams: [] }
]

function preset(id) {
  for (var i = 0; i < presets.length; i++) {
    if (presets[i].id === id) return presets[i]
  }
  return presets[0]
}

function label(id) {
  return preset(id).label
}

function options() {
  var result = []
  for (var i = 0; i < presets.length; i++) result.push({ value: presets[i].id, label: presets[i].label })
  return result
}

// "192.168.1.42" or "192.168.1.42:8554" -> { host, port }
function splitHost(value, fallbackPort) {
  var text = String(value || "").trim().replace(/^[a-z]+:\/\//i, "").replace(/\/.*$/, "")
  var match = text.match(/^\[?([^\]]+?)\]?(?::(\d+))?$/)
  if (!match) return { host: text, port: fallbackPort }
  return { host: match[1], port: match[2] ? Number(match[2]) : fallbackPort }
}

function credentials(user, password) {
  if (!user) return ""
  return encodeURIComponent(user) + (password ? ":" + encodeURIComponent(password) : "") + "@"
}

// Insert user:password into a custom URL unless it already carries them.
function withCredentials(url, user, password) {
  var text = String(url || "").trim()
  if (text === "" || !user) return text
  var match = text.match(/^([a-z][a-z0-9+.-]*:\/\/)(.*)$/i)
  if (!match) return text
  if (match[2].split("/")[0].indexOf("@") !== -1) return text
  return match[1] + credentials(user, password) + match[2]
}

// Stream layout a camera uses: its preset's `variant`-th entry.
function layout(camera) {
  var streams = preset(camera.brand).streams
  if (streams.length === 0) return null
  var v = Number(camera.variant) || 0
  return streams[v >= 0 && v < streams.length ? v : 0]
}

function variantCount(brand) {
  return preset(brand).streams.length
}

// Port a camera's stream is reached on: the layout's default unless the
// address carries its own (192.168.1.42:8554).
function port(camera) {
  var l = layout(camera)
  return splitHost(camera.host, l ? l.port : 554).port
}

// Full stream URL for a camera record. quality is "main" or "sub".
function streamUrl(camera, quality) {
  if (!camera) return ""
  if (camera.brand === "custom") {
    var custom = quality === "sub" && camera.subUrl ? camera.subUrl : camera.url
    return withCredentials(custom, camera.user, camera.password)
  }
  var l = layout(camera)
  var hp = splitHost(camera.host, l.port)
  if (!hp.host) return ""
  var path = quality === "sub" && l.sub ? l.sub : l.main
  return l.scheme + "://" + credentials(camera.user, camera.password) + hp.host + ":" + hp.port + path
}

// Same URL with the password masked, for display.
function displayUrl(camera) {
  if (!camera) return ""
  var masked = {}
  for (var key in camera) masked[key] = camera[key]
  if (masked.password) masked.password = "•••"
  return decodeURIComponent(streamUrl(masked, "main"))
}

function hostLabel(camera) {
  if (!camera) return ""
  if (camera.brand === "custom") return String(camera.url || "").replace(/^[a-z]+:\/\/([^@/]*@)?/i, "").split("/")[0]
  return splitHost(camera.host, port(camera)).host
}

// Guess the brand from a camera's web page (headers + HTML). Returns a
// preset id, or "" when nothing matches.
var signatures = [
  { id: "reolink",   re: /reolink/i },
  { id: "hikvision", re: /hikvision|dnvrs-webs|app-webs|\/doc\/page\/login\.asp/i },
  { id: "dahua",     re: /dahua|amcrest|lorex/i },
  { id: "tapo",      re: /tp-link|tapo/i },
  { id: "ezviz",     re: /ezviz/i },
  { id: "dlink",     re: /d-link|dlink|\bdcs-\d/i },
  { id: "axis",      re: /axis communications|\baxis\b/i },
  { id: "uniview",   re: /uniview/i },
  { id: "foscam",    re: /foscam/i }
]

function detectBrand(page) {
  var text = String(page || "")
  for (var i = 0; i < signatures.length; i++) if (signatures[i].re.test(text)) return signatures[i].id
  return ""
}

// Single-picture (JPEG) address per brand, used to show a fresh picture the
// moment a view opens while the live stream is still connecting. "query"
// brands take the login in the address; the others use HTTP basic/digest.
var snapshots = {
  reolink:   { path: "/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=omacam&user={user}&password={password}", auth: "query" },
  hikvision: { path: "/ISAPI/Streaming/channels/101/picture", auth: "http" },
  ezviz:     { path: "/ISAPI/Streaming/channels/101/picture", auth: "http" },
  dahua:     { path: "/cgi-bin/snapshot.cgi?channel=1", auth: "http" },
  dlink:     { path: "/image/jpeg.cgi", auth: "http" },
  axis:      { path: "/axis-cgi/jpg/image.cgi", auth: "http" },
  foscam:    { path: "/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr={user}&pwd={password}", auth: "query", port: 88 }
}

// { url, user, password } for curl, or null when the brand has no snapshot.
function snapshotRequest(camera) {
  if (!camera || camera.brand === "custom") return null
  var s = snapshots[camera.brand]
  if (!s) return null
  var host = splitHost(camera.host, 80).host
  if (!host) return null
  var path = s.path.replace("{user}", encodeURIComponent(camera.user || "")).replace("{password}", encodeURIComponent(camera.password || ""))
  return {
    url: "http://" + host + (s.port ? ":" + s.port : "") + path,
    user: s.auth === "http" ? String(camera.user || "") : "",
    password: s.auth === "http" ? String(camera.password || "") : ""
  }
}
