import QtQuick
import Quickshell.Io

// Keeps camera logins out of the shell's log. The video player logs every
// address it opens, so instead of rtsp://user:password@camera/... players get
// rtsp://127.0.0.1:<port>/<token>/<id> from relay.py, which connects to the
// camera and logs in itself. Logins reach it through stdin, as for the other
// helpers. Addresses without a login, and kinds the relay doesn't speak,
// are played directly.
Item {
  id: root
  visible: false

  property int port: 0
  property string token: ""
  readonly property bool ready: port > 0
  // Couldn't start several times in a row (no python3?).
  readonly property bool broken: _fails >= 3

  property var _ids: ({})      // stream key -> relay id
  property var _sent: ({})     // relay id -> address the relay knows
  property int _serial: 0
  property int _fails: 0

  function needed(url) {
    var m = String(url).match(/^(rtsp|http):\/\/([^\/?#]*)/i)
    return !!m && m[2].indexOf("@") !== -1
  }

  // Address to play for a stream: the camera's own when it carries no login,
  // otherwise the relay's. "" while the relay starts.
  function address(key, url) {
    if (!needed(url)) return url
    if (!ready) return ""
    var id = _ids[key]
    if (!id) { _serial += 1; id = "s" + _serial; _ids[key] = id }
    if (_sent[id] !== url) {
      _sent[id] = url
      proc.write(JSON.stringify({ id: id, url: url }) + "\n")
    }
    return url.replace(/^([a-z]+):\/\/.*$/i, "$1").toLowerCase() + "://127.0.0.1:" + port + "/" + token + "/" + id
  }

  Process {
    id: proc
    running: true
    stdinEnabled: true
    command: ["python3", "-I", decodeURIComponent(Qt.resolvedUrl("relay.py").toString().replace(/^file:\/\//, ""))]
    stdout: SplitParser {
      onRead: function(line) {
        var p = String(line).split(" ")
        if (p[0] === "ready" && p.length === 3) { root._fails = 0; root.token = p[2]; root.port = Number(p[1]) }
      }
    }
    onExited: {
      root.port = 0
      root.token = ""
      root._sent = ({})
      root._fails += 1
      restart.restart()
    }
  }

  Timer {
    id: restart
    interval: Math.min(30000, 1000 * Math.pow(2, root._fails))
    onTriggered: proc.running = true
  }
}
