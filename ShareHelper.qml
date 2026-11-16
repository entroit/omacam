import QtQuick
import Quickshell.Io

// Runs share.py (encrypting, decrypting and checking camera shares). One
// request line goes in through stdin and one answer comes back on stdout, so
// passphrases and logins never appear in a command line, the environment or a
// log. Requests run one after the other; nothing is printed to the console.
//
//   helper.run({ op: "passphrase" }, function(answer) { ... })
//
// answer is { ok: true, ... } or { ok: false, error: "<code>" } (see share.py).
Item {
  id: root
  visible: false

  readonly property bool busy: proc.running || _queue.length > 0

  property var _queue: []          // [{ line, callback }]
  property string _input: ""
  property var _callback: null
  property string _out: ""
  property bool _exited: false
  property bool _drained: false
  property bool _timedOut: false

  function run(request, callback) {
    _queue = _queue.concat([{ line: JSON.stringify(request) + "\n", callback: callback }])
    _next()
  }

  // Drop everything queued and forget the request in flight (callbacks never fire).
  function cancelAll() {
    _queue = []
    _callback = null
    _input = ""
    _out = ""
    if (proc.running) proc.running = false
  }

  function _next() {
    if (proc.running || _queue.length === 0) return
    var job = _queue[0]
    _queue = _queue.slice(1)
    _input = job.line
    _callback = job.callback
    _out = ""
    _exited = false
    _drained = false
    _timedOut = false
    proc.running = true
  }

  function _finish() {
    if (!_exited || !_drained) return
    var callback = _callback
    var answer = { ok: false, error: _timedOut ? "timeout" : "internal" }
    var parsed = null
    if (!_timedOut) {
      try { parsed = JSON.parse(_out) } catch (e) {}
      if (parsed !== null && typeof parsed === "object") answer = parsed
    }
    _callback = null
    _out = ""
    try {
      if (callback) callback(answer)
    } finally {
      _next()          // a callback that throws must not stall the queue
    }
  }

  // A hard limit on the whole request.
  Timer {
    interval: 30000
    running: proc.running
    onTriggered: { root._timedOut = true; root._input = ""; proc.running = false }
  }

  Process {
    id: proc
    stdinEnabled: true
    command: ["python3", "-I", decodeURIComponent(Qt.resolvedUrl("share.py").toString().replace(/^file:\/\//, ""))]
    onStarted: { write(root._input); root._input = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root._out = text; root._drained = true; root._finish() }
    }
    // Attached so the pipe is drained; the helper never writes to it.
    stderr: StdioCollector { waitForEnd: true }
    // _input is normally cleared right after it is written; a process that
    // never started or was killed first must not leave a passphrase behind.
    onExited: { root._input = ""; root._exited = true; root._finish() }
  }

  Component.onDestruction: cancelAll()
}
