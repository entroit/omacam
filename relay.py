# OmaCam stream relay.
#
# The video player logs every address it opens, so an address with a login
# in it (rtsp://user:password@camera/...) ends up in the shell's log. Players
# open rtsp://127.0.0.1:<port>/<token>/<id> here instead, and this relay
# connects to the camera and answers its login challenge itself. Logins
# arrive on stdin and only live in memory.
#
# stdin:  one JSON object per line: {"id": "s1", "url": "rtsp://u:p@host/path"}
#         ({"id": "s1"} with no url forgets it). Closing stdin stops the relay.
# stdout: "ready <port> <token>" once listening.
#
# Only 127.0.0.1 can connect, every address needs the random token of this
# run, and only addresses handed over on stdin are ever contacted.
#
# RTSP is relayed over TCP: a player asking for UDP gets "461 Unsupported
# transport" and asks again for TCP. HTTP (MJPEG cameras) is one request whose
# answer is passed through.

import base64, hashlib, json, os, re, secrets, socket, sys, threading, time
from urllib.parse import urlsplit, unquote

TOKEN = secrets.token_hex(16)
MAX_HEAD = 64 * 1024
MAX_BODY = 1024 * 1024

routes = {}
routes_cv = threading.Condition()


def read_routes():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
            rid = str(msg["id"])
        except Exception:
            continue
        with routes_cv:
            if msg.get("url"):
                routes[rid] = str(msg["url"])
            else:
                routes.pop(rid, None)
            routes_cv.notify_all()
    os._exit(0)


def route(rid):
    # A player may connect a moment before its address arrives.
    deadline = time.monotonic() + 3
    with routes_cv:
        while rid not in routes:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            routes_cv.wait(left)
        return routes[rid]


class Upstream:
    def __init__(self, url):
        u = urlsplit(url)
        self.scheme = u.scheme.lower()
        self.user = unquote(u.username or "")
        self.password = unquote(u.password or "")
        self.host = u.hostname or ""
        self.port = u.port or (554 if self.scheme == "rtsp" else 80)
        hp = "[%s]" % self.host if ":" in self.host else self.host
        self.hostport = "%s:%d" % (hp, self.port)
        self.path = (u.path or "/") + ("?" + u.query if u.query else "")
        self.base = "%s://%s%s" % (self.scheme, self.hostport, self.path)
        self.auth = None
        self.nc = 0

    def connect(self):
        s = socket.create_connection((self.host, self.port), timeout=5)
        s.settimeout(None)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        return s

    # --- login ----------------------------------------------------------------
    def challenge(self, values):
        best = None
        for v in values:
            scheme, _, rest = v.strip().partition(" ")
            params = {m.group(1).lower(): m.group(3) if m.group(3) is not None else m.group(4)
                      for m in re.finditer(r'(\w+)\s*=\s*("([^"]*)"|([^,\s]*))', rest)}
            if scheme.lower() == "digest":
                best = ("digest", params)
                break
            if scheme.lower() == "basic" and best is None:
                best = ("basic", params)
        if best is None or not self.user:
            return False
        self.auth = best
        self.nc = 0
        return True

    def authorization(self, method, uri):
        if not self.auth:
            return None
        kind, p = self.auth
        if kind == "basic":
            return "Basic " + base64.b64encode((self.user + ":" + self.password).encode()).decode()
        algo = p.get("algorithm", "MD5")
        h = (lambda s: hashlib.sha256(s.encode()).hexdigest()) if algo.upper().startswith("SHA-256") \
            else (lambda s: hashlib.md5(s.encode()).hexdigest())
        realm, nonce = p.get("realm", ""), p.get("nonce", "")
        ha1 = h("%s:%s:%s" % (self.user, realm, self.password))
        ha2 = h("%s:%s" % (method, uri))
        fields = 'username="%s", realm="%s", nonce="%s", uri="%s"' % (self.user, realm, nonce, uri)
        qop = p.get("qop", "")
        if "auth" in [q.strip() for q in qop.split(",")]:
            self.nc += 1
            nc, cnonce = "%08x" % self.nc, secrets.token_hex(8)
            resp = h("%s:%s:%s:%s:auth:%s" % (ha1, nonce, nc, cnonce, ha2))
            fields += ', qop=auth, nc=%s, cnonce="%s"' % (nc, cnonce)
        else:
            resp = h("%s:%s:%s" % (ha1, nonce, ha2))
        fields += ', response="%s"' % resp
        if "opaque" in p:
            fields += ', opaque="%s"' % p["opaque"]
        if "algorithm" in p:
            fields += ", algorithm=%s" % algo
        return "Digest " + fields


class Reader:
    """Reads RTSP/HTTP messages and RTSP interleaved ($) frames."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()

    def fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError
        self.buf += chunk

    def frames(self):
        """Complete $ frames at the front of the buffer, as one bytes run."""
        i, n = 0, len(self.buf)
        while i + 4 <= n and self.buf[i] == 0x24:
            size = 4 + int.from_bytes(self.buf[i + 2:i + 4], "big")
            if i + size > n:
                break
            i += size
        out = bytes(self.buf[:i])
        del self.buf[:i]
        return out

    def message(self):
        """(head lines, body) of the next message, or None if a frame is next."""
        while True:
            if self.buf[:1] == b"$":
                return None
            end = self.buf.find(b"\r\n\r\n")
            if end >= 0:
                break
            if len(self.buf) > MAX_HEAD:
                raise EOFError
            self.fill()
        head = bytes(self.buf[:end]).decode("latin-1")
        del self.buf[:end + 4]
        lines = head.split("\r\n")
        length = int(header(lines, "content-length") or 0)
        if length < 0 or length > MAX_BODY:
            raise EOFError
        while len(self.buf) < length:
            self.fill()
        body = bytes(self.buf[:length])
        del self.buf[:length]
        return lines, body


def header(lines, name):
    for l in lines[1:]:
        k, _, v = l.partition(":")
        if k.strip().lower() == name:
            return v.strip()
    return None


def headers_all(lines, name):
    return [l.partition(":")[2].strip() for l in lines[1:] if l.partition(":")[0].strip().lower() == name]


def without(lines, *names):
    return [lines[0]] + [l for l in lines[1:] if l.partition(":")[0].strip().lower() not in names]


def pack(lines, body=b""):
    lines = without(lines, "content-length")
    if body:
        lines.append("Content-Length: %d" % len(body))
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body


class Session:
    def __init__(self, client, port):
        self.client = client
        self.port = port
        self.up = None
        self.upsock = None
        self.lock = threading.Lock()
        self.pending = {}
        self.cseq = 0
        self.local = ""

    def close(self):
        for s in (self.client, self.upsock):
            if s:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                s.close()

    def reply(self, code, text, cseq=None):
        lines = ["RTSP/1.0 %d %s" % (code, text)]
        if cseq:
            lines.append("CSeq: " + cseq)
        self.client.sendall(pack(lines))

    # Our address <-> the camera's, in everything the two sides tell each other.
    def to_camera(self, url):
        if url == "*":
            return url
        rest = url[len(self.local):]
        if rest.startswith("/~"):
            return "rtsp://" + self.up.host_raw + rest[2:]
        return self.up.base + rest

    def to_player(self, text):
        text = text.replace(self.up.base, self.local)
        return self.host_re.sub(lambda m: self.local + "/~" + (m.group(1) or ""), text)

    def open(self, url):
        """Check the token, find the camera; returns the request path's route."""
        m = re.match(r"^[a-z]+://[^/]+/([0-9a-f]{32})/([A-Za-z0-9_-]+)", url)
        if not m or not secrets.compare_digest(m.group(1), TOKEN):
            return False
        target = route(m.group(2))
        if not target:
            return False
        self.up = Upstream(target)
        h = self.up.host
        self.up.host_raw = "[%s]" % h if ":" in h else h
        self.local = "rtsp://127.0.0.1:%d/%s/%s" % (self.port, TOKEN, m.group(2))
        host = re.escape(self.up.host_raw)
        self.host_re = re.compile(r"rtsp://" + host + r"(:\d+)?(?![\w.-])", re.I)
        return True

    # --- RTSP -----------------------------------------------------------------
    def send_up(self, entry):
        self.cseq += 1
        method, url, lines, body = entry["method"], entry["url"], entry["lines"], entry["body"]
        out = ["%s %s RTSP/1.0" % (method, url), "CSeq: %d" % self.cseq] + \
              [l for l in without(lines, "cseq", "authorization", "content-length")[1:]]
        auth = self.up.authorization(method, url)
        if auth:
            out.append("Authorization: " + auth)
        self.pending[self.cseq] = entry
        with self.lock:
            self.upsock.sendall(pack(out, body))

    def rtsp(self, reader, first):
        lines, body = first
        while True:
            if lines is None:
                frames = reader.frames()
                if frames:
                    with self.lock:
                        self.upsock.sendall(frames)
                    continue
                reader.fill()
                got = reader.message()
                lines, body = got if got else (None, b"")
                continue
            method, url, _ = (lines[0].split(" ") + ["", ""])[:3]
            cseq = header(lines, "cseq")
            if self.up is None:
                if not self.open(url):
                    self.reply(404, "Not Found", cseq)
                    return
                self.upsock = self.up.connect()
                threading.Thread(target=self.from_camera, daemon=True).start()
            elif url != "*" and not url.startswith(self.local):
                self.reply(404, "Not Found", cseq)
                return
            transport = header(lines, "transport") or ""
            if method == "SETUP" and "/TCP" not in transport.upper():
                self.reply(461, "Unsupported Transport", cseq)
            else:
                self.send_up({"method": method, "url": self.to_camera(url), "lines": lines,
                              "body": body, "cseq": cseq, "retried": False})
            got = reader.message()
            lines, body = got if got else (None, b"")

    def from_camera(self):
        reader = Reader(self.upsock)
        try:
            while True:
                frames = reader.frames()
                if frames:
                    self.client.sendall(frames)
                    continue
                if not reader.buf:
                    reader.fill()
                    continue
                got = reader.message()
                if got is None:
                    reader.fill()
                    continue
                lines, body = got
                if not lines[0].startswith("RTSP/"):
                    continue            # requests from the camera: not needed
                code = int((lines[0].split(" ") + ["0", "0"])[1] or 0)
                entry = self.pending.pop(int(header(lines, "cseq") or -1), None)
                if entry is None:
                    continue
                if code == 401 and not entry["retried"] and self.up.challenge(headers_all(lines, "www-authenticate")):
                    entry["retried"] = True
                    self.send_up(entry)
                    continue
                out = [lines[0]]
                if entry["cseq"]:
                    out.append("CSeq: " + entry["cseq"])
                for l in without(lines, "cseq", "www-authenticate")[1:]:
                    out.append(self.to_player(l))
                ctype = (header(lines, "content-type") or "").lower()
                if body and "sdp" in ctype:
                    body = self.to_player(body.decode("latin-1")).encode("latin-1")
                self.client.sendall(pack(out, body))
        except (OSError, EOFError, ValueError):
            pass
        finally:
            self.close()

    # --- HTTP -----------------------------------------------------------------
    def http(self, lines):
        method, url, _ = (lines[0].split(" ") + ["", ""])[:3]
        if method != "GET" or not self.open("http://x" + url) or self.up.scheme != "http":
            self.client.sendall(b"HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            return
        auth = None
        for attempt in range(2):
            self.upsock = self.up.connect()
            req = ["GET %s HTTP/1.1" % self.up.path, "Host: " + self.up.hostport,
                   "User-Agent: OmaCam", "Accept: */*", "Connection: close"]
            if auth:
                req.append("Authorization: " + auth)
            self.upsock.sendall(pack(req))
            reader = Reader(self.upsock)
            got = None
            while got is None:
                reader.fill()
                end = reader.buf.find(b"\r\n\r\n")
                if end >= 0:
                    got = bytes(reader.buf[:end]).decode("latin-1").split("\r\n")
                elif len(reader.buf) > MAX_HEAD:
                    return
            code = int((got[0].split(" ") + ["0", "0"])[1] or 0)
            # Over plain HTTP only digest is answered: basic would put the
            # password on the network readable.
            if code == 401 and attempt == 0 and self.up.challenge(
                    [v for v in headers_all(got, "www-authenticate") if v.lower().startswith("digest")]):
                auth = self.up.authorization("GET", self.up.path)
                self.upsock.close()
                continue
            self.client.sendall(bytes(reader.buf))
            while True:
                chunk = self.upsock.recv(65536)
                if not chunk:
                    return
                self.client.sendall(chunk)

    def run(self):
        try:
            reader = Reader(self.client)
            got = reader.message()
            if got is None:
                return
            lines, body = got
            if lines[0].endswith("RTSP/1.0"):
                self.rtsp(reader, (lines, body))
            elif " HTTP/1." in lines[0]:
                self.http(lines)
        except (OSError, EOFError, ValueError):
            pass
        finally:
            self.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(64)
    port = srv.getsockname()[1]
    threading.Thread(target=read_routes, daemon=True).start()
    print("ready %d %s" % (port, TOKEN), flush=True)
    while True:
        client, _ = srv.accept()
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=Session(client, port).run, daemon=True).start()


main()
