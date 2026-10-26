import QtQuick
import Quickshell.Io

// Asks ffprobe about a stream: used by "Test connection" and to tell a wrong
// password apart from an unreachable camera when playback fails (Qt only
// reports a generic "could not open" error).
//
// result: { ok, kind: "ok" | "auth" | "path" | "offline" | "error",
//           width, height, fps, codec, message }
Item {
  id: root
  visible: false

  property bool running: proc.running
  property var result: null
  property string _url: ""

  signal finished(var result)

  function probe(url) {
    if (!url) {
      finish({ ok: false, kind: "error", message: "No stream address" })
      return
    }
    if (proc.running) proc.running = false
    _url = url
    result = null
    proc.command = [
      "timeout", "-k", "2", "9",
      "ffprobe", "-v", "error",
      "-rtsp_transport", "tcp",
      "-timeout", "5000000",
      "-select_streams", "v:0",
      "-show_entries", "stream=codec_name,width,height,avg_frame_rate",
      "-of", "json",
      url
    ]
    proc.running = true
  }

  function cancel() {
    proc.running = false
  }

  function classify(exitCode, stdout, stderr) {
    var err = String(stderr || "")
    if (exitCode === 0) {
      try {
        var data = JSON.parse(stdout)
        var s = data.streams && data.streams[0]
        if (s) {
          var fps = 0
          var parts = String(s.avg_frame_rate || "0/1").split("/")
          if (Number(parts[1]) > 0) fps = Math.round(Number(parts[0]) / Number(parts[1]))
          return { ok: true, kind: "ok", width: s.width || 0, height: s.height || 0, fps: fps, codec: String(s.codec_name || "").toUpperCase(), message: "" }
        }
      } catch (e) {}
      return { ok: false, kind: "error", message: "Connected, but no video stream found" }
    }
    if (/401|unauthori[sz]ed|authori[sz]ation failed/i.test(err)) return { ok: false, kind: "auth", message: "Wrong username or password" }
    if (/404|not found|method describe failed/i.test(err)) return { ok: false, kind: "path", message: "Camera answered, but the stream address is wrong" }
    if (exitCode === 124 || /timed out|refused|no route|unreachable|network is down|name or service/i.test(err)) return { ok: false, kind: "offline", message: "No response from the camera" }
    return { ok: false, kind: "error", message: "The camera didn't send video at this address" }
  }

  function finish(r) {
    result = r
    finished(r)
  }

  property string _stdout: ""
  property string _stderr: ""

  Process {
    id: proc
    onStarted: { root._stdout = ""; root._stderr = "" }
    stdout: StdioCollector { id: out; waitForEnd: true; onStreamFinished: root._stdout = text }
    stderr: StdioCollector { id: err; waitForEnd: true; onStreamFinished: root._stderr = text }
    onExited: function(exitCode) {
      root.finish(root.classify(exitCode, out.text || root._stdout, err.text || root._stderr))
    }
  }
}
