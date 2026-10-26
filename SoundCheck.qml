import QtQuick
import Quickshell.Io

// Does a camera actually send sound? Many cameras announce an audio track but
// never fill it (mic off or missing), so count real audio packets for a few
// seconds instead of trusting the stream description.
Item {
  id: root
  visible: false

  property bool running: proc.running
  property string _out: ""

  signal finished(bool hasSound)

  function check(url) {
    if (!url || proc.running) return
    _out = ""
    proc.command = [
      "timeout", "-k", "2", "9",
      "ffprobe", "-v", "error",
      "-rtsp_transport", "tcp",
      "-timeout", "5000000",
      "-select_streams", "a:0",
      "-show_entries", "packet=pts_time",
      "-read_intervals", "%+4",
      "-of", "csv=p=0",
      url
    ]
    proc.running = true
  }

  function cancel() { proc.running = false }

  Process {
    id: proc
    stdout: StdioCollector { id: out; waitForEnd: true; onStreamFinished: root._out = text }
    onExited: {
      var lines = String(out.text || root._out || "").split("\n").filter(function(l) { return l.trim() !== "" })
      root.finished(lines.length >= 5)
    }
  }
}
