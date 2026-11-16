.pragma library

// Everything about how OmaCam behaves, as written to
// ~/.config/omacam/config.json on first run. The file is read on top of these
// defaults, so anything missing or misspelled falls back to the value here.
//
// Keys are names like "f", "F", "Escape", "Return", "BackSpace", "Left",
// "Space", "F5", optionally with modifiers: "Ctrl+q", "Shift+Tab", "Alt+m".
// A single letter matches what the key types, so "f" and "F" differ.
var DEFAULTS = {
  version: 1,
  connection: {
    alwaysConnected: false,       // keep every camera streaming, no time limit
    keepConnectedSeconds: 180,    // otherwise, keep streaming this long after closing
    warmOnHoverSeconds: 15,       // start streaming while the pointer rests on the bar icon
    keepFullQualitySeconds: 30,   // full-quality stream stays this long after leaving a big view
    retrySeconds: 15,             // wait between attempts for a camera that failed
    statusCheckSeconds: 60,       // how often the bar checks which cameras answer
    lowLatency: true              // smallest delay; false buffers a little for unsteady networks
  },
  sound: {
    closeAfterMutedSeconds: 20    // muted audio stream disconnects after this long
  },
  bar: {
    showCount: true,              // "5" (or "4/5" when one is offline) next to the icon
    leftClick: "dropdown",        // dropdown · wall · manage · fullscreen · none
    middleClick: "wall",
    rightClick: "manage"
  },
  dropdown: {
    columns: 2,
    showNumbers: true,            // number badges on the first nine tiles
    click: "enlarge",             // enlarge · fullscreen · pin · none
    doubleClick: "fullscreen"
  },
  fullscreen: {
    fill: false,                  // true crops the picture to fill the screen
    showStrip: true               // camera strip at the bottom
  },
  wall: {
    columns: 0,                   // 0 picks by camera count
    click: "fullscreen",          // fullscreen · enlarge · pin · none
    fill: false
  },
  pinned: {
    width: 360,                   // width of a newly pinned player
    snapDistance: 28              // snaps to a screen edge within this many pixels
  },
  keys: {
    cameraNumbers: true,          // 1-9 (and the numpad) open the camera at that position
    dropdown: {
      up: ["Up", "k"],
      down: ["Down", "j"],
      left: ["Left", "h"],
      right: ["Right", "l"],
      open: ["Return", "Enter"],
      fullscreen: ["f", "F"],
      wall: ["a", "w"],
      add: ["n"],
      manage: ["m"],
      nextPanel: ["Tab"],
      previousPanel: ["Shift+Tab"],
      close: ["Escape"]
    },
    enlarged: {
      previous: ["Left", "h"],
      next: ["Right", "l"],
      fullscreen: ["f", "F"],
      sound: ["m"],
      pin: ["p"],
      edit: ["e"],
      wall: ["a", "w"],
      add: ["n"],
      back: ["Escape"]
    },
    fullscreen: {
      previous: ["Left"],
      next: ["Right", "l"],
      toggleStrip: ["h"],
      sound: ["m"],
      pin: ["p"],
      wall: ["a", "g"],
      back: ["BackSpace", "f"],
      close: ["Escape", "q"]
    },
    wall: {
      up: ["Up", "k"],
      down: ["Down", "j"],
      left: ["Left", "h"],
      right: ["Right", "l"],
      open: ["Return", "Enter", "f"],
      pin: ["p"],
      back: ["BackSpace"],
      close: ["Escape", "q"]
    }
  }
}

function isObject(v) { return v !== null && typeof v === "object" && !(v instanceof Array) }

// Defaults with the user's values on top. Wrong types are ignored so one typo
// can't break the rest; key lists may be a single string or a list.
function merge(base, over) {
  if (!isObject(over)) return base
  var out = {}
  for (var k in base) {
    var b = base[k], o = over[k]
    if (o === undefined || o === null) out[k] = b
    else if (isObject(b)) out[k] = merge(b, o)
    else if (b instanceof Array) out[k] = typeof o === "string" ? [o] : (o instanceof Array ? o.filter(function(x) { return typeof x === "string" }) : b)
    else out[k] = typeof o === typeof b ? o : b
  }
  return out
}

// --- sanitizing settings that come from outside (a share) -----------------------
// Allowed range of every number, and allowed values of every word setting.
var LIMITS = {
  "connection.keepConnectedSeconds": [0, 3600], "connection.warmOnHoverSeconds": [0, 3600],
  "connection.keepFullQualitySeconds": [0, 3600], "connection.retrySeconds": [1, 3600],
  "connection.statusCheckSeconds": [5, 3600], "sound.closeAfterMutedSeconds": [0, 3600],
  "dropdown.columns": [1, 6], "wall.columns": [0, 12], "pinned.width": [160, 1920], "pinned.snapDistance": [0, 200]
}
var CHOICES = {
  "bar.leftClick": ["dropdown", "wall", "manage", "fullscreen", "none"],
  "bar.middleClick": ["dropdown", "wall", "manage", "fullscreen", "none"],
  "bar.rightClick": ["dropdown", "wall", "manage", "fullscreen", "none"],
  "dropdown.click": ["enlarge", "fullscreen", "pin", "none"], "dropdown.doubleClick": ["enlarge", "fullscreen", "pin", "none"],
  "wall.click": ["fullscreen", "enlarge", "pin", "none"]
}
var KEY_MODIFIERS = ["ctrl", "control", "shift", "alt", "super", "meta"]

function ownValue(obj, key) {
  return isObject(obj) && Object.prototype.hasOwnProperty.call(obj, key) ? obj[key] : undefined
}

// A key spec `matches` can act on: optional modifiers, then one character or
// a name from NAMED ("Ctrl+q", "Shift+Tab", "F5", "Ctrl++").
function validKey(spec) {
  var mods, key
  if (spec === "+") { mods = []; key = "+" }
  else if (spec.slice(-2) === "++") { mods = spec.slice(0, -2).split("+"); key = "+" }
  else { mods = spec.split("+"); key = mods.pop() }
  for (var i = 0; i < mods.length; i++) if (KEY_MODIFIERS.indexOf(mods[i].toLowerCase()) === -1) return false
  if (key.length === 1) return !/[\u0000-\u0020\u007f-\u00a0\u2028\u2029]/.test(key)
  return Object.prototype.hasOwnProperty.call(NAMED, key.toLowerCase())
}

function validKeys(list) {
  if (typeof list === "string") list = [list]
  if (!(list instanceof Array) || list.length === 0 || list.length > 8) return null
  for (var i = 0; i < list.length; i++) {
    if (typeof list[i] !== "string" || list[i].length > 32 || !validKey(list[i])) return null
  }
  return list.slice()
}

// Settings from a share, reduced to what OmaCam understands: only keys in
// DEFAULTS are looked at (never the input's own), values keep the type of the
// default, numbers are clamped, words must be ones the code acts on, key lists
// must be well formed and are never left empty. Anything unusable keeps
// `current` (the settings in use; DEFAULTS when omitted). Always a complete
// settings object.
function sanitize(input, current) {
  return sanitizeNode(DEFAULTS, input, isObject(current) ? current : DEFAULTS, "")
}

function sanitizeNode(base, input, current, path) {
  var out = {}
  for (var k in base) {
    var def = base[k]
    var here = path ? path + "." + k : k
    var fallback = ownValue(current, k)
    if (fallback === undefined) fallback = def
    var v = ownValue(input, k)
    if (isObject(def)) {
      out[k] = sanitizeNode(def, v, isObject(fallback) ? fallback : def, here)
    } else if (def instanceof Array) {
      out[k] = validKeys(v) || validKeys(fallback) || def.slice()
    } else if (typeof def === "number") {
      var range = LIMITS[here]
      if (range && typeof v === "number" && isFinite(v)) out[k] = Math.max(range[0], Math.min(range[1], Math.round(v)))
      else out[k] = k === "version" ? def : (typeof fallback === "number" ? fallback : def)
    } else if (typeof def === "boolean") {
      out[k] = typeof v === "boolean" ? v : (typeof fallback === "boolean" ? fallback : def)
    } else if (typeof def === "string") {
      var choices = CHOICES[here]
      out[k] = typeof v === "string" && choices && choices.indexOf(v) !== -1 ? v : (typeof fallback === "string" ? fallback : def)
    } else {
      out[k] = def
    }
  }
  return out
}

function get(obj, path) {
  var parts = path.split(".")
  for (var i = 0; i < parts.length && obj !== undefined; i++) obj = obj[parts[i]]
  return obj
}

// Copy of `obj` with `path` set to `value`.
function withValue(obj, path, value) {
  var parts = path.split(".")
  var root = JSON.parse(JSON.stringify(isObject(obj) ? obj : {}))
  var o = root
  for (var i = 0; i < parts.length - 1; i++) {
    if (!isObject(o[parts[i]])) o[parts[i]] = {}
    o = o[parts[i]]
  }
  o[parts[parts.length - 1]] = value
  return root
}

// --- keys ---------------------------------------------------------------------
var SHIFT = 0x02000000, CTRL = 0x04000000, ALT = 0x08000000, META = 0x10000000
var MODS = SHIFT | CTRL | ALT | META

var NAMED = {
  escape: 0x01000000, esc: 0x01000000, tab: 0x01000001, backtab: 0x01000002,
  backspace: 0x01000003, return: 0x01000004, enter: 0x01000005, insert: 0x01000006,
  delete: 0x01000007, home: 0x01000010, end: 0x01000011, left: 0x01000012,
  up: 0x01000013, right: 0x01000014, down: 0x01000015, pageup: 0x01000016,
  pagedown: 0x01000017, space: 0x20
}
for (var f = 1; f <= 12; f++) NAMED["f" + f] = 0x01000030 + f - 1

var LABELS = {
  escape: "esc", esc: "esc", return: "\u{F0311}", enter: "\u{F0311}", backspace: "⌫", delete: "del",
  left: "←", right: "→", up: "↑", down: "↓", tab: "tab", space: "space",
  pageup: "pgup", pagedown: "pgdn", home: "home", end: "end"
}

function parse(spec) {
  var parts = String(spec).split("+")
  var key = parts.pop()
  if (key === "" && parts.length > 0) { parts.pop(); key = "+" }   // "Ctrl++"
  var mods = 0
  for (var i = 0; i < parts.length; i++) {
    var m = parts[i].toLowerCase()
    if (m === "shift") mods |= SHIFT
    else if (m === "ctrl" || m === "control") mods |= CTRL
    else if (m === "alt") mods |= ALT
    else if (m === "super" || m === "meta") mods |= META
  }
  return { key: key, mods: mods }
}

function matches(spec, event) {
  var p = parse(spec)
  var held = event.modifiers & MODS
  if (p.key.length === 1) {
    // A typed character: Shift is part of the character itself.
    if ((p.mods & ~SHIFT) === 0) return event.text === p.key && (held & ~SHIFT) === 0
    return event.key === p.key.toUpperCase().charCodeAt(0) && held === p.mods
  }
  var code = NAMED[p.key.toLowerCase()]
  if (code === undefined) return false
  // Qt reports Shift+Tab as Backtab.
  if (code === NAMED.tab && (p.mods & SHIFT) && event.key === NAMED.backtab) return (held & ~SHIFT) === (p.mods & ~SHIFT)
  return event.key === code && held === p.mods
}

// The first action in `map` ({ action: [keys] }) that the key event triggers.
function action(map, event) {
  for (var name in map) {
    var keys = map[name]
    for (var i = 0; i < keys.length; i++) if (matches(keys[i], event)) return name
  }
  return ""
}

// Short label for hints, e.g. "esc", "⌫", "f", "ctrl+q"; "" when unbound.
function label(keys) {
  if (!keys || keys.length === 0) return ""
  var p = parse(keys[0])
  var name = p.key.length === 1 ? p.key : (LABELS[p.key.toLowerCase()] || p.key.toLowerCase())
  var pre = (p.mods & CTRL ? "ctrl+" : "") + (p.mods & ALT ? "alt+" : "") + (p.mods & META ? "super+" : "") + (p.mods & SHIFT && p.key.length > 1 ? "shift+" : "")
  return pre + name
}

// One chip for the four movement keys: the default arrows become a single
// four-way glyph (nf-md-arrow_all) instead of four glyphs crammed together;
// custom keys such as "hjkl" are shown as typed.
function moveLabel(left, up, down, right) {
  var s = label(left) + label(up) + label(down) + label(right)
  return s === "←↑↓→" ? "\u{F0041}" : s
}

// "←→" style label for a pair of actions.
function pairLabel(a, b) {
  var x = label(a), y = label(b)
  return x && y ? (x.length === 1 && y.length === 1 ? x + y : x + " " + y) : x || y
}

// Pretty JSON with key lists on one line: "close": ["Escape", "q"].
function format(obj) {
  return JSON.stringify(obj, null, 2).replace(/\[\s*\n\s*((?:"(?:[^"\\]|\\.)*",?\s*)+)\]/g, function(m, inner) {
    return "[" + inner.trim().split(/,\s*\n\s*/).join(", ") + "]"
  }) + "\n"
}
