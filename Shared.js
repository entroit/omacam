.pragma library

// State shared by every camera picture in the shell (one copy per engine,
// whichever bar, popup or window a feed lives in).

// Latest still picture per camera (a JPEG fetched from the camera, as a data
// URL), shown while a new view connects so it doesn't open black. Only kept
// in memory, one per camera, replaced on the next fetch.
var snapshots = ({})

// Cameras whose low-res stream doesn't work; their tiles use the main stream.
var subBroken = ({})

// Where each pinned player was last left: { px, py, w, aspect } per camera id.
var pip = ({})

// Full-stream resolution per camera ("2304×1296"), once seen.
var mainResolution = ({})

// Whether a camera really sends sound: true / false, missing = not checked.
var sound = ({})

function snapshotUrl(id) {
  var s = id ? snapshots[id] : null
  return s ? s.url : ""
}

function keepSnapshotData(id, dataUrl) {
  if (id && dataUrl) snapshots[id] = { url: dataUrl, time: Date.now() }
}
