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

// encodeURIComponent throws on an unpaired surrogate; such text is written
// with U+FFFD instead so a bad record can't break the bindings that show it.
function enc(text) {
  try { return encodeURIComponent(text) } catch (e) {}
  var out = ""
  text = String(text)
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF && text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) { out += text.charAt(i) + text.charAt(i + 1); i++ }
    else out += (c >= 0xD800 && c <= 0xDFFF) ? "\ufffd" : text.charAt(i)
  }
  return encodeURIComponent(out)
}

function credentials(user, password) {
  if (!user) return ""
  return enc(user) + (password ? ":" + enc(password) : "") + "@"
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
  var url = streamUrl(masked, "main")
  var shown = unquote(url)             // a stray % in the address stays as typed
  return shown === null ? url : shown
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
// Pictures are asked for over HTTPS. Plain HTTP is only a fallback for
// "http" brands, and there the helper answers digest challenges only, so a
// login never crosses the network readable: "query" brands get no HTTP
// fallback at all.
var snapshots = {
  reolink:   { path: "/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=omacam&user={user}&password={password}", auth: "query" },
  hikvision: { path: "/ISAPI/Streaming/channels/101/picture", auth: "http" },
  ezviz:     { path: "/ISAPI/Streaming/channels/101/picture", auth: "http" },
  dahua:     { path: "/cgi-bin/snapshot.cgi?channel=1", auth: "http" },
  dlink:     { path: "/image/jpeg.cgi", auth: "http" },
  axis:      { path: "/axis-cgi/jpg/image.cgi", auth: "http" },
  foscam:    { path: "/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr={user}&pwd={password}", auth: "query" }
}

// { url, plainUrl, user, password } for the snapshot helper, or null when the
// brand has no snapshot. plainUrl is "" when the login must not go over HTTP.
function snapshotRequest(camera) {
  if (!camera || camera.brand === "custom") return null
  var s = snapshots[camera.brand]
  if (!s) return null
  var host = splitHost(camera.host, 80).host
  if (!host) return null
  if (host.indexOf(":") !== -1) host = "[" + host + "]"
  var path = s.path.replace("{user}", enc(camera.user || "")).replace("{password}", enc(camera.password || ""))
  var http = s.auth === "http"
  return {
    url: "https://" + host + path,
    plainUrl: http ? "http://" + host + path : "",
    user: http ? String(camera.user || "") : "",
    password: http ? String(camera.password || "") : ""
  }
}

// --- sharing and validation ---------------------------------------------------
// { brand id: number of stream layouts }: the brand list share.py checks
// against, so Brands.js stays the one place that defines brands.
function brandTable() {
  var table = {}
  for (var i = 0; i < presets.length; i++) table[presets[i].id] = presets[i].streams.length
  return table
}

var HOST_RE = /^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?)(?::([0-9]{1,5}))?$/
var URL_RE = /^(rtsp|http):\/\/([^\/?#]*)([\s\S]*)$/i

function codePoints(text) {
  var n = 0
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF) i++
    n++
  }
  return n
}

// First `count` code points of text.
function firstCodePoints(text, count) {
  var n = 0
  for (var i = 0; i < text.length; i++) {
    if (n === count) return text.slice(0, i)
    var c = text.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF) i++
    n++
  }
  return text
}

// Not valid UTF-16 (an unpaired surrogate)?
function lonelySurrogate(text) {
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF) {
      var d = text.charCodeAt(i + 1)
      if (!(d >= 0xDC00 && d <= 0xDFFF)) return true
      i++
    } else if (c >= 0xDC00 && c <= 0xDFFF) return true
  }
  return false
}

function hasControl(text) { return /[\u0000-\u001f\u007f-\u009f]/.test(text) }

// Name as it is stored: controls and bidi marks removed, whitespace collapsed.
function cleanName(raw) {
  return String(raw)
    .replace(/[\t\n\r\f\v]/g, " ")
    .replace(/[\u0000-\u0008\u000e-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(/[ \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000\ufeff]+/g, " ")
    .replace(/^ | $/g, "")
}

// Dotted quad as Python's ipaddress reads it: four plain decimal numbers, no leading zeros.
function validIPv4(text) {
  var parts = text.split(".")
  if (parts.length !== 4) return false
  for (var i = 0; i < 4; i++) {
    if (!/^[0-9]{1,3}$/.test(parts[i]) || (parts[i].length > 1 && parts[i].charAt(0) === "0") || Number(parts[i]) > 255) return false
  }
  return true
}

// An IPv6 address (the text between the brackets), same rules as share.py.
function validIPv6(text) {
  var parts = text.split(":")
  if (parts.length < 3) return false
  if (parts[parts.length - 1].indexOf(".") !== -1) {
    if (!validIPv4(parts.pop())) return false
    parts.push("0", "0")
  }
  if (parts.length > 9) return false
  var skip = -1
  for (var i = 1; i < parts.length - 1; i++) {
    if (parts[i] === "") { if (skip !== -1) return false; skip = i }
  }
  var hi, lo
  if (skip !== -1) {
    hi = skip
    lo = parts.length - skip - 1
    if (parts[0] === "") { hi--; if (hi) return false }
    if (parts[parts.length - 1] === "") { lo--; if (lo) return false }
    if (8 - (hi + lo) < 1) return false
  } else {
    if (parts.length !== 8 || parts[0] === "" || parts[7] === "") return false
    hi = 8
    lo = 0
  }
  for (var a = 0; a < hi; a++) if (!/^[0-9A-Fa-f]{1,4}$/.test(parts[a])) return false
  for (var b = parts.length - lo; b < parts.length; b++) if (!/^[0-9A-Fa-f]{1,4}$/.test(parts[b])) return false
  return true
}

function validHost(value) {
  var m = HOST_RE.exec(value)
  if (!m) return false
  if (m[2] !== undefined && !(Number(m[2]) >= 1 && Number(m[2]) <= 65535)) return false
  return m[1].charAt(0) !== "[" || validIPv6(m[1].slice(1, -1))
}

// Percent-decoding the way share.py does it: an escape that isn't two hex
// digits stays as typed; escapes that don't make valid UTF-8 -> null.
function unquote(text) {
  try { return decodeURIComponent(text.replace(/%(?![0-9A-Fa-f]{2})/g, "%25")) } catch (e) { return null }
}

function isBrand(id) {
  if (typeof id !== "string") return false
  for (var i = 0; i < presets.length; i++) if (presets[i].id === id) return true
  return false
}

// The address as the add/edit form takes it: what was pasted with its scheme
// and path removed (splitHost's reading), "host" or "host:port".
function formHost(value) {
  return String(value === undefined || value === null ? "" : value).trim().replace(/^[a-z]+:\/\//i, "").replace(/\/.*$/, "").trim()
}

// The one check for camera records from outside: a share (strict, the default)
// and the add/edit form ({ form: true }): there a pasted scheme and path are
// removed from the address, any host name the player accepts is fine (only
// whitespace, control characters, shell characters, quotes, backslash and @
// are refused), a custom URL may use any scheme, and a long name is cut to 64.
// Brand-specific fields are the only ones read: a preset's `url` and a custom
// camera's `host` are ignored (and dropped).
// -> { ok, record, error }; record is the cleaned camera, without an id.
// Cameras already in cameras.json are never run through this on load.
function checkCamera(rec, options) {
  var form = !!(options && options.form)
  function fail(message) { return { ok: false, record: null, error: message } }
  if (rec === null || typeof rec !== "object" || rec instanceof Array) return fail("Not a camera.")

  var s = {}
  var keys = ["name", "brand", "user", "password"]
  var brandId = rec.brand
  if (brandId === "custom") keys.push("url")
  else keys.push("host")
  for (var i = 0; i < keys.length; i++) {
    var v = rec[keys[i]]
    if (v === undefined || v === null) v = ""
    if (typeof v !== "string") return fail("Invalid " + keys[i] + ".")
    if (lonelySurrogate(v)) return fail("The " + keys[i] + " has characters that can't be saved.")
    s[keys[i]] = v
  }
  var name = cleanName(s.name)
  if (name === "" || (!form && codePoints(s.name) > 512)) return fail("Give the camera a name.")
  if (codePoints(name) > 64) {
    if (!form) return fail("The name is too long (64 characters at most).")
    name = firstCodePoints(name, 64).replace(/ $/, "")
  }
  if (!isBrand(s.brand)) return fail("Unknown camera brand.")
  var brand = s.brand

  var variant = rec.variant === undefined ? 0 : rec.variant
  var variants = Math.max(variantCount(brand), 1)
  if (typeof variant !== "number" || Math.floor(variant) !== variant || variant < 0 || variant >= variants) return fail("Invalid stream layout.")
  var enabled = rec.enabled === undefined ? true : rec.enabled
  if (typeof enabled !== "boolean") return fail("Invalid enabled flag.")

  var user = s.user, password = s.password
  var host = "", url = ""
  if (brand === "custom") {
    url = form ? s.url.trim() : s.url
    if (url === "") return fail("Enter the stream URL.")
    if (codePoints(url) > 2048) return fail("The stream URL is too long.")
    if (/[\u0000- \u007f-\u009f]/.test(url)) return fail("The stream URL can't contain spaces or control characters.")
    if (!form) {
      if (/[^!-~]|\\/.test(url)) return fail("The stream URL has characters that aren't allowed.")
      var m = URL_RE.exec(url)
      if (!m) return fail("The stream URL must start with rtsp:// or http://.")
      var authority = m[2], userinfo = null
      var at = authority.lastIndexOf("@")
      if (at >= 0) { userinfo = authority.slice(0, at); authority = authority.slice(at + 1) }
      if (authority === "" || !validHost(authority)) return fail("The stream URL needs a valid host and port.")
      if (userinfo !== null && user === "" && password === "") {
        var colon = userinfo.indexOf(":")
        user = unquote(colon < 0 ? userinfo : userinfo.slice(0, colon))
        password = colon < 0 ? "" : unquote(userinfo.slice(colon + 1))
        if (user === null || password === null) return fail("The login in the stream URL isn't valid.")
      }
      url = m[1].toLowerCase() + "://" + authority + m[3]     // never keeps userinfo
    }
  } else if (form) {
    host = formHost(s.host)
    if (host === "") return fail("Enter the camera's IP address.")
    if (codePoints(host) > 255) return fail("The address is too long.")
    if (/[\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff;$`|&<>(){}"'\\@]/.test(host) || host.charAt(0) === "-") {
      return fail("The address can't contain spaces or characters like ; $ | & < > ( ) { } quotes or @.")
    }
  } else {
    host = s.host
    if (host === "") return fail("Enter the camera's IP address.")
    if (!validHost(host)) return fail("The address can only be an IP address or host name, like 192.168.1.42 or cam.local:554.")
  }

  if (codePoints(user) > 128) return fail("The username is too long.")
  if (codePoints(password) > 256) return fail("The password is too long.")
  if (lonelySurrogate(user) || lonelySurrogate(password)) return fail("The login has characters that can't be saved.")
  if (hasControl(user) || hasControl(password)) return fail("The username and password can't contain control characters.")
  if (user.indexOf('"') !== -1) return fail("The username can't contain a double quote.")

  return { ok: true, error: "", record: { name: name, brand: brand, host: host, url: url, user: user, password: password, variant: variant, enabled: enabled } }
}

// Which camera a record is, for spotting one that's already added: brand, host
// (lower case, its default port dropped), address without a login, layout.
function identity(camera) {
  if (!camera) return ""
  var brand = String(camera.brand || "")
  if (brand === "custom") {
    var m = /^([a-z][a-z0-9+.-]*):\/\/(?:[^@\/?#]*@)?([^\/?#]*)([\s\S]*)$/i.exec(String(camera.url || "").trim())
    if (!m) return ["custom", String(camera.url || "").trim(), 0].join("|")
    var scheme = m[1].toLowerCase()
    var hp = splitHost(m[2], scheme === "http" ? 80 : 554)
    var dflt = scheme === "http" ? 80 : 554
    return ["custom", scheme + "://" + hp.host.toLowerCase() + (hp.port === dflt ? "" : ":" + hp.port) + m[3], 0].join("|")
  }
  var l = layout(camera)
  var parts = splitHost(camera.host, l ? l.port : 554)
  return [brand, parts.host.toLowerCase() + (parts.port === (l ? l.port : 554) ? "" : ":" + parts.port), "", Number(camera.variant) || 0].join("|")
}
