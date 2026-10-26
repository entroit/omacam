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
    _input = url + "\n"
    proc.command = [
      "bash", "-c", 'IFS= read -r url; exec timeout -k 2 9 ffprobe "$@" -/i /dev/stdin < <(printf %s "$url")', "omacam-probe",
      "-v", "error",
      "-rtsp_transport", "tcp",
      "-timeout", "5000000",
      "-select_streams", "a:0",
      "-show_entries", "packet=pts_time",
      "-read_intervals", "%+4",
      "-of", "csv=p=0"
    ]
    proc.running = true
  }

  function cancel() { proc.running = false }

  // The address holds the camera login, so it goes in through stdin rather
  // than the command line, where other users could read it.
  property string _input: ""

  Process {
    id: proc
    stdinEnabled: true
    onStarted: { write(root._input); root._input = "" }
    stdout: StdioCollector { id: out; waitForEnd: true; onStreamFinished: root._out = text }
    onExited: {
      var lines = String(out.text || root._out || "").split("\n").filter(function(l) { return l.trim() !== "" })
      root.finished(lines.length >= 5)
    }
  }
}
