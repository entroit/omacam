import QtQuick
import Quickshell.Io
import "Brands.js" as Brands
import "Shared.js" as Shared

// Asks cameras for a single JPEG over HTTP (a fraction of a second, versus
// seconds for the first live picture), so views open with a fresh picture
// while video connects. Nothing is written anywhere: the picture comes back
// as a data URL and only lives in memory. Logins reach the helper through
// stdin, so they never show up in the process list.
Item {
  id: root
  visible: false

  property var _queued: null
  property int _queuedAge: 0
  property string _input: ""

  // Fetch for these camera records, skipping ones with a recent picture.
  function fetch(cams, maxAgeMs) {
    if (proc.running) { _queued = cams; _queuedAge = maxAgeMs || 0; return }
    var jobs = []
    var now = Date.now()
    for (var i = 0; i < cams.length; i++) {
      var c = cams[i]
      var have = Shared.snapshots[c.id]
      if (have && now - have.time < (maxAgeMs || 20000)) continue
      var req = Brands.snapshotRequest(c)
      if (req) jobs.push({ id: c.id, url: req.url, user: req.user, password: req.password })
    }
    if (jobs.length === 0) return
    _input = JSON.stringify(jobs) + "\n"
    proc.running = true
  }

  Process {
    id: proc
    stdinEnabled: true
    command: ["python3", "-I", "-c", `
import base64, json, ssl, sys, threading, urllib.request

jobs = json.loads(sys.stdin.readline())
lock = threading.Lock()
insecure = ssl.create_default_context()
insecure.check_hostname = False
insecure.verify_mode = ssl.CERT_NONE   # cameras use self-signed certificates

def get(url, user, password):
    handlers = [urllib.request.HTTPSHandler(context=insecure)]
    if user:
        pw = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        pw.add_password(None, url, user, password)
        handlers += [urllib.request.HTTPBasicAuthHandler(pw), urllib.request.HTTPDigestAuthHandler(pw)]
    with urllib.request.build_opener(*handlers).open(url, timeout=4) as r:
        if r.status == 200 and r.headers.get_content_type().startswith("image/"):
            return r.headers.get_content_type(), r.read(4_000_000)
    return None

def run(job):
    url = job["url"]
    # Some cameras redirect HTTP to their HTTPS home page, dropping the path.
    for attempt in (url, url.replace("http://", "https://", 1)):
        try:
            got = get(attempt, job["user"], job["password"])
        except Exception:
            got = None
        if got:
            kind, data = got
            line = job["id"] + " data:" + kind + ";base64," + base64.b64encode(data).decode()
            with lock:
                print(line, flush=True)
            return

threads = [threading.Thread(target=run, args=(j,)) for j in jobs]
for t in threads: t.start()
for t in threads: t.join()
`]
    onStarted: { write(root._input); root._input = "" }
    stdout: SplitParser {
      onRead: function(line) {
        var cut = String(line).indexOf(" ")
        if (cut > 0) Shared.keepSnapshotData(line.slice(0, cut), line.slice(cut + 1))
      }
    }
    onExited: if (root._queued) { var q = root._queued; root._queued = null; root.fetch(q, root._queuedAge) }
  }
}
