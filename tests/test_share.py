"""Tests for share.py, driven through its stdin/stdout protocol.

Run:  python3 -I tests/test_share.py     (or: python3 -I -m unittest discover -s tests -v)

Every camera, address and passphrase here is made up. The helper is started
the way the shell starts it (python3 -I share.py, one JSON line in, one out).
The clipboard tools are replaced by small fake scripts so the real clipboard
is never touched.
"""
import base64
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True      # importing share.py must not leave __pycache__ behind

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHARE = os.path.join(ROOT, "share.py")

PASS = "tango-uniform-1234"
SECRET_PASSWORD = "Zx9-synthetic-pw"
BRANDS = {"hikvision": 2, "dahua": 1, "reolink": 2, "tapo": 1, "dlink": 4, "ezviz": 1, "axis": 1,
          "uniview": 1, "foscam": 1, "custom": 0}


def slurp(path):
    with open(path) as f:
        return f.read()


def put(path, data="x", size=None):
    with open(path, "wb") as f:
        f.write(data.encode())
        if size:
            f.truncate(size)


def load_module():
    spec = importlib.util.spec_from_file_location("omacam_share", SHARE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)      # safe: the helper's main only runs as __main__
    return mod


M = load_module()


def run(req, env=None, timeout=60, raw=None):
    """-> (answer dict, raw stdout, raw stderr)"""
    data = raw if raw is not None else (json.dumps(req) + "\n").encode()
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([sys.executable, "-I", SHARE], input=data, capture_output=True, env=e, timeout=timeout)
    out = p.stdout.decode()
    return (json.loads(out) if out.strip() else None), out, p.stderr


def cam(**kw):
    c = {"name": "Front Door", "brand": "hikvision", "host": "192.168.1.42", "url": "", "user": "admin",
         "password": SECRET_PASSWORD, "variant": 0, "enabled": True}
    c.update(kw)
    return c


def export_req(path, cameras=None, **kw):
    r = {"op": "export", "passphrase": PASS, "cameras": cameras if cameras is not None else [cam()],
         "settings": None, "includeLogins": True, "app": "1.0.7", "brands": BRANDS, "dest": {"file": path}}
    r.update(kw)
    return r


def open_req(path, passphrase=PASS):
    return {"op": "open", "passphrase": passphrase, "source": {"file": path}, "brands": BRANDS}


_key_cache = {}


def make_share(doc, passphrase=PASS, log2n=17, raw_plain=None):
    """A share with arbitrary (even hostile) content, made with the helper's own crypto."""
    salt, nonce = b"s" * 16, b"n" * 12
    if (passphrase, log2n) not in _key_cache:
        _key_cache[(passphrase, log2n)] = M.derive_key(passphrase.encode(), salt, log2n)
    plain = raw_plain if raw_plain is not None else json.dumps(doc).encode("ascii")
    plain += b" " * (-len(plain) % 512)
    header = M.MAGIC + bytes([1, log2n, 8, 1]) + salt + nonce
    return M.armor(header + M.gcm_encrypt(_key_cache[(passphrase, log2n)], nonce, header, plain))


def good_doc(cameras=None, **kw):
    d = {"format": "omacam-share", "version": 1, "created": "2026-01-02T03:04:05Z", "app": "1.0.7",
         "includesLogins": True, "cameras": cameras if cameras is not None else [cam()], "settings": None}
    d.update(kw)
    return d


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.addCleanup(self.tmp.cleanup)

    def path(self, name="share.omacam"):
        return os.path.join(self.dir, name)

    def write(self, text, name="in.omacam"):
        p = self.path(name)
        with open(p, "w", newline="") as f:
            f.write(text)
        return p

    def export(self, **kw):
        p = kw.pop("path", None) or self.path()
        ans, out, err = run(export_req(p, **kw))
        self.assertEqual(err, b"")
        return ans, p

    def open_text(self, text, passphrase=PASS):
        ans, out, err = run(open_req(self.write(text), passphrase))
        self.assertEqual(err, b"")
        return ans

    def assertError(self, ans, code):
        self.assertIsNotNone(ans)
        self.assertFalse(ans["ok"], ans)
        self.assertEqual(ans["error"], code)


class RoundTrip(Base):
    def test_with_logins(self):
        cams = [cam(), cam(name="Garage", brand="custom", host="", url="rtsp://10.0.0.9:8554/live", user="u", password="p w"),
                cam(name="Off", enabled=False, brand="reolink", variant=1, host="cam.local:8554", user="", password="")]
        ans, p = self.export(cameras=cams)
        self.assertEqual(ans, {"count": 3, "path": p, "ok": True})
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)
        got, out, err = run(open_req(p))
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["includesLogins"], True)
        self.assertRegex(got["created"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertIsNone(got["settings"])
        for want, have in zip(cams, got["cameras"]):
            have = dict(have)
            self.assertIn(have.pop("scope"), ("local", "public"))
            self.assertEqual(have, want)

    def test_without_logins(self):
        ans, p = self.export(includeLogins=False)
        got, out, err = run(open_req(p))
        self.assertEqual(got["includesLogins"], False)
        self.assertEqual((got["cameras"][0]["user"], got["cameras"][0]["password"]), ("", ""))
        self.assertNotIn(SECRET_PASSWORD, slurp(p))

    def test_settings_round_trip(self):
        settings = {"version": 1, "dropdown": {"columns": 3}, "keys": {"dropdown": {"up": ["Up", "k"]}}}
        ans, p = self.export(settings=settings)
        got, out, err = run(open_req(p))
        self.assertEqual(got["settings"], settings)

    def test_format_and_padding(self):
        ans, p = self.export()
        text = slurp(p)
        self.assertTrue(text.startswith(M.BEGIN + "\n") and text.endswith(M.END + "\n"))
        self.assertTrue(all(len(l) <= 64 for l in text.splitlines()[1:-2]))
        blob = base64.b64decode("".join(text.splitlines()[1:-1]))
        self.assertEqual(blob[:8], b"OMACAM\x00\x01")
        self.assertEqual(list(blob[8:12]), [1, 17, 8, 1])      # scrypt N=2**17, r=8, p=1
        self.assertEqual((len(blob) - 40 - 16) % 512, 0)
        self.assertNotIn(b"Front Door", blob)

    def test_fresh_salt_and_nonce_every_time(self):
        blobs = []
        for i in range(2):
            ans, p = self.export(path=self.path("s%d" % i))
            blobs.append(base64.b64decode("".join(slurp(p).splitlines()[1:-1])))
        self.assertNotEqual(blobs[0][12:40], blobs[1][12:40])

    def test_passphrase_is_nfc_normalised(self):
        ans, p = self.export(passphrase="caf\u00e9-caf\u00e9-caf\u00e9")
        got, out, err = run(open_req(p, "cafe\u0301-cafe\u0301-cafe\u0301"))
        self.assertTrue(got["ok"], got)

    def test_known_answer_gcm(self):
        out = M.gcm_encrypt(bytes(32), bytes(12), b"", bytes(16))
        self.assertEqual(out.hex(), "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")


class Failures(Base):
    def setUp(self):
        super().setUp()
        self.cams = [cam()]
        ans, self.p = self.export(cameras=self.cams)
        self.text = slurp(self.p)
        self.blob = base64.b64decode("".join(self.text.splitlines()[1:-1]))

    def reopen(self, blob):
        return self.open_text(M.armor(blob))

    def test_wrong_passphrase(self):
        ans = self.open_text(self.text, "not the passphrase")
        self.assertError(ans, "bad_passphrase_or_corrupt")

    def test_every_tamper_class(self):
        # (offset, expected error): the header is authenticated, so anything not
        # rejected up front as unsupported shows up as the one generic error.
        generic = "bad_passphrase_or_corrupt"
        cases = [(0, "not_a_share"), (6, "not_a_share"), (7, "unsupported"), (8, "unsupported"), (9, generic),
                 (10, "unsupported"), (11, "unsupported"), (12, generic), (27, generic), (28, generic), (39, generic),
                 (40, generic), (100, generic), (len(self.blob) - 17, generic), (len(self.blob) - 16, generic),
                 (len(self.blob) - 1, generic)]
        for offset, code in cases:
            blob = bytearray(self.blob)
            blob[offset] ^= 0x01 if offset != 9 else 0x01   # 17 -> 16: still a legal cost, other key
            with self.subTest(offset=offset):
                self.assertError(self.reopen(bytes(blob)), code)

    def test_truncated_and_garbage(self):
        for name, blob in (("tag", self.blob[:-1]), ("half", self.blob[:len(self.blob) // 2]),
                           ("header only", self.blob[:40]), ("tiny", b"x" * 10)):
            with self.subTest(name):
                ans = self.reopen(blob)
                self.assertFalse(ans["ok"])
                self.assertIn(ans["error"], ("not_a_share", "bad_passphrase_or_corrupt"))
        self.assertError(self.open_text(""), "not_a_share")
        self.assertError(self.open_text("hello world, not a share\n"), "not_a_share")
        self.assertError(self.open_text(M.BEGIN + "\nAAAA\n"), "not_a_share")
        self.assertError(self.open_text(M.BEGIN + "\n!!!not base64!!!\n" + M.END + "\n"), "not_a_share")
        self.assertError(self.open_text(M.BEGIN + "\nAAA\n" + M.END + "\n"), "not_a_share")
        self.assertError(self.open_text("\x00\xff\xfe binary \x01" * 100), "not_a_share")

    def test_oversized_input(self):
        t = time.time()
        ans = self.open_text(M.BEGIN + "\n" + "A" * (1024 * 1024 + 10) + "\n" + M.END + "\n")
        self.assertError(ans, "too_large")
        self.assertLess(time.time() - t, 5)

    def test_oversized_request(self):
        t = time.time()
        ans, out, err = run(None, raw=b"x" * (5 * 1024 * 1024))
        self.assertError(ans, "too_large")
        self.assertLess(time.time() - t, 5)

    def test_armor_inside_chat_text_and_crlf(self):
        lines = self.text.splitlines()
        chat = "hey, here is the file!\r\n\r\n  " + "\r\n  ".join(lines) + "\r\n\r\nthe passphrase is in the other chat :)\r\n"
        got = self.open_text(chat)
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["cameras"][0]["name"], "Front Door")

    def test_bad_kdf_parameters(self):
        for log2n, r, p in ((14, 8, 1), (18, 8, 1), (31, 8, 1), (0, 8, 1), (17, 4, 1), (17, 8, 2), (17, 9, 1)):
            header = M.MAGIC + bytes([1, log2n, r, p]) + b"s" * 28
            blob = header + b"\x00" * 600
            t = time.time()
            with self.subTest(log2n=log2n, r=r, p=p):
                self.assertError(self.reopen(blob), "unsupported")
                self.assertLess(time.time() - t, 5)
        # every allowed cost works
        for log2n in (15, 16):
            got = self.open_text(make_share(good_doc(), log2n=log2n))
            self.assertTrue(got["ok"], got)

    def test_refuses_to_overwrite(self):
        before = slurp(self.p)
        ans, out, err = run(export_req(self.p, cameras=[cam(name="Other")]))
        self.assertError(ans, "exists")
        self.assertEqual(slurp(self.p), before)
        os.mkdir(self.path("adir"))
        ans, out, err = run(export_req(self.path("adir")))
        self.assertError(ans, "exists")

    def test_weak_passphrase(self):
        for weak in ("short", "x" * 11, ""):
            ans, out, err = run(export_req(self.path("w.omacam"), passphrase=weak))
            self.assertError(ans, "weak_passphrase")
        self.assertFalse(os.path.exists(self.path("w.omacam")))
        ans, out, err = run(export_req(self.path("w.omacam"), passphrase="x" * 12))
        self.assertTrue(ans["ok"])

    def test_missing_dir_falls_back_to_home(self):
        ans, out, err = run(export_req("~/does/not/exist/x.omacam"), env={"HOME": self.dir})
        self.assertTrue(ans["ok"], ans)
        self.assertEqual(ans["path"], os.path.join(self.dir, "x.omacam"))
        self.assertEqual(stat.S_IMODE(os.stat(ans["path"]).st_mode), 0o600)

    def test_relative_path_refused(self):
        ans, out, err = run(export_req("relative/x.omacam"))
        self.assertError(ans, "invalid_path")
        ans, out, err = run(open_req("relative/x.omacam"))
        self.assertError(ans, "invalid_path")

    def test_non_regular_sources_rejected_fast(self):
        fifo = self.path("fifo")
        os.mkfifo(fifo)
        for src, code in (("/dev/zero", "not_a_file"), ("/dev/null", "not_a_file"), (self.dir, "not_a_file"),
                          (fifo, "not_a_file"), (self.path("missing"), "not_found")):
            t = time.time()
            ans, out, err = run(open_req(src))
            with self.subTest(src=src):
                self.assertError(ans, code)
                self.assertLess(time.time() - t, 3)

    def test_big_file_refused(self):
        p = self.path("big")
        with open(p, "wb") as f:
            f.truncate(1024 * 1024 + 1)
        ans, out, err = run(open_req(p))
        self.assertError(ans, "too_large")

    def test_symlink_destination_refused(self):
        os.symlink(self.path("target"), self.path("link"))
        ans, out, err = run(export_req(self.path("link")))
        self.assertFalse(ans["ok"])
        self.assertFalse(os.path.exists(self.path("target")))

    def test_bad_requests(self):
        for req in ({}, {"op": "nope"}, {"op": "open"}, {"op": "export", "passphrase": PASS}, [1, 2], "x", {"op": "export", "passphrase": PASS, "brands": BRANDS, "cameras": [], "includeLogins": True, "dest": {"clipboard": True}}):
            ans, out, err = run(req)
            self.assertFalse(ans["ok"])
        ans, out, err = run(None, raw=b'{"op": "passphrase", "x": NaN}\n')
        self.assertError(ans, "bad_request")
        ans, out, err = run(None, raw=b"")
        self.assertError(ans, "bad_request")


class Hostile(Base):
    """Decryptable shares with hostile content (made with the right passphrase)."""

    def rejected(self, doc=None, code="invalid_content", **kw):
        raw = kw.pop("raw_plain", None)
        ans = self.open_text(make_share(doc, raw_plain=raw))
        self.assertError(ans, code)

    def test_bad_cameras(self):
        bad = {
            "brand constructor": cam(brand="constructor"),
            "brand __proto__": cam(brand="__proto__"),
            "brand unknown": cam(brand="nope"),
            "brand not str": cam(brand=5),
            "host injection": cam(host="a;b"),
            "host space": cam(host="a b"),
            "host newline": cam(host="a\nb"),
            "host empty": cam(host=""),
            "host url": cam(host="rtsp://a/b"),
            "host port 0": cam(host="a:0"),
            "host port 70000": cam(host="a:70000"),
            "host bad v6": cam(host="[zz::1]"),
            "custom file": cam(brand="custom", host="", url="file:///etc/passwd"),
            "custom https": cam(brand="custom", host="", url="https://a/b"),
            "custom rtsps": cam(brand="custom", host="", url="rtsps://a/b"),
            "custom no host": cam(brand="custom", host="", url="rtsp:///x"),
            "custom space": cam(brand="custom", host="", url="rtsp://a/x y"),
            "custom backslash": cam(brand="custom", host="", url="rtsp://a\\b/x"),
            "custom non-ascii": cam(brand="custom", host="", url="rtsp://a/\u00e9"),
            "custom control": cam(brand="custom", host="", url="rtsp://a/x\x01"),
            "custom port": cam(brand="custom", host="", url="rtsp://a:99999/x"),
            "custom too long": cam(brand="custom", host="", url="rtsp://a/" + "x" * 2100),
            "custom empty": cam(brand="custom", host="", url=""),
            "variant range": cam(variant=2),
            "variant negative": cam(variant=-1),
            "variant float": cam(variant=1.5),
            "variant bool": cam(variant=True),
            "variant custom 1": cam(brand="custom", host="", url="rtsp://a/x", variant=1),
            "enabled str": cam(enabled="yes"),
            "name empty": cam(name=""),
            "name only controls": cam(name="\x00\x01\u202e"),
            "name long": cam(name="x" * 65),
            "name not str": cam(name=5),
            "user quote": cam(user='ad"min'),
            "user control": cam(user="ad\nmin"),
            "user long": cam(user="u" * 129),
            "password control": cam(password="p\x00w"),
            "password long": cam(password="p" * 257),
            "lone surrogate": cam(name="Door\ud800"),
            "lone surrogate password": cam(password="\udc00"),
            "not a dict": "camera",
        }
        for name, c in bad.items():
            with self.subTest(name):
                self.rejected(good_doc(cameras=[c]))

    def test_nan_and_infinity(self):
        for const in ("NaN", "Infinity", "-Infinity"):
            plain = ('{"format":"omacam-share","version":1,"created":"2026-01-02T03:04:05Z","includesLogins":true,'
                     '"cameras":[{"name":"A","brand":"tapo","host":"h","variant":%s}],"settings":null}' % const).encode()
            with self.subTest(const):
                self.rejected(raw_plain=plain)

    def test_too_many_or_no_cameras(self):
        self.rejected(good_doc(cameras=[cam(name="c%d" % i) for i in range(101)]))
        self.rejected(good_doc(cameras=[]))
        got = self.open_text(make_share(good_doc(cameras=[cam(name="c%d" % i) for i in range(100)])))
        self.assertEqual(len(got["cameras"]), 100)

    def test_bad_envelope(self):
        for name, doc in {"format": good_doc(format="other"), "version str": good_doc(version="1"),
                          "version 0": good_doc(version=0), "version bool": good_doc(version=True),
                          "created junk": good_doc(created="yesterday"), "created date": good_doc(created="2026-13-45T25:61:61Z"),
                          "created tz": good_doc(created="2026-01-02T03:04:05+00:00"), "logins str": good_doc(includesLogins="yes"),
                          "cameras dict": good_doc(cameras={}), "settings list": good_doc(settings=[1]),
                          "settings deep": good_doc(settings={"a": {"b": {"c": {"d": {"e": 1}}}}}),
                          "settings big": good_doc(settings={"a": "x" * 70000})}.items():
            with self.subTest(name):
                self.rejected(doc)
        for raw in (b"[]", b"null", b"not json", b'{"a":' + b"[" * 5000):
            with self.subTest(raw[:10]):
                self.rejected(raw_plain=raw)

    def test_newer_versions_are_unsupported(self):
        self.rejected(good_doc(version=2), code="unsupported")
        blob = bytearray(base64.b64decode("".join(make_share(good_doc()).splitlines()[1:-1])))
        blob[7] = 2
        ans = self.open_text(M.armor(bytes(blob)))
        self.assertError(ans, "unsupported")

    def test_name_is_cleaned(self):
        c = cam(name="  Front\t\u2028Door\u202e \u2066x\u2069\x07  ")
        got = self.open_text(make_share(good_doc(cameras=[c])))
        self.assertEqual(got["cameras"][0]["name"], "Front Door x")

    def test_unknown_keys_and_id_dropped(self):
        c = cam(id="cam-1", extra="x", subUrl="rtsp://x/y")
        got = self.open_text(make_share(good_doc(cameras=[c], evil=1)))
        self.assertEqual(sorted(got["cameras"][0]), sorted(["name", "brand", "host", "url", "user", "password", "variant", "enabled", "scope"]))

    def test_userinfo_and_query_credentials(self):
        url = "rtsp://admin:s3%40cr3t@192.168.1.5/live?user=a&Password=b&channel=1&TOKEN=z&x=y#frag"
        # exported without logins: userinfo and credential parameters are gone
        ans, p = self.export(cameras=[cam(brand="custom", host="", url=url, user="", password="")], includeLogins=False)
        got, out, err = run(open_req(p))
        c = got["cameras"][0]
        self.assertEqual((c["url"], c["user"], c["password"]), ("rtsp://192.168.1.5/live?channel=1&x=y#frag", "", ""))
        # exported with logins and empty user/password: userinfo moves into them
        ans, p = self.export(cameras=[cam(brand="custom", host="", url=url, user="", password="")], path=self.path("b"))
        c = run(open_req(p))[0]["cameras"][0]
        self.assertEqual((c["url"], c["user"], c["password"]), ("rtsp://192.168.1.5/live?user=a&Password=b&channel=1&TOKEN=z&x=y#frag", "admin", "s3@cr3t"))
        # user and password already set: userinfo is dropped, they win
        ans, p = self.export(cameras=[cam(brand="custom", host="", url=url, user="me", password="pw")], path=self.path("c"))
        c = run(open_req(p))[0]["cameras"][0]
        self.assertEqual((c["url"].startswith("rtsp://192.168.1.5/live"), c["user"], c["password"]), (True, "me", "pw"))
        # a crafted share that claims no logins is blanked on the way in, whatever it holds
        got = self.open_text(make_share(good_doc(includesLogins=False, cameras=[cam(brand="custom", host="", url=url)])))
        c = got["cameras"][0]
        self.assertEqual((c["url"], c["user"], c["password"]), ("rtsp://192.168.1.5/live?channel=1&x=y#frag", "", ""))
        # userinfo that does not decode
        self.rejected(good_doc(cameras=[cam(brand="custom", host="", url="rtsp://a%ff:b@h/x", user="", password="")]))

    def test_preset_with_stale_url_and_custom_with_stale_host(self):
        got = self.open_text(make_share(good_doc(cameras=[cam(url="rtsp://junk"), cam(brand="custom", host="stale", url="rtsp://h/x")])))
        self.assertEqual(got["cameras"][0]["url"], "")
        self.assertEqual(got["cameras"][1]["host"], "")

    def test_scope_classification(self):
        # (the full table is in test_js.Scope; this goes through the real open path)
        expect = {"192.168.1.5": "local", "10.1.2.3": "local", "172.16.0.1": "local", "[fd00::1]": "local", "nas": "local", "cam.local": "local",
                  "[::ffff:192.168.1.5]": "local", "127.0.0.1": "loopback", "[::1]": "loopback", "localhost": "loopback",
                  "169.254.4.4": "linklocal", "[fe80::1]": "linklocal", "8.8.8.8": "public", "example.com": "public",
                  "100.64.1.1": "public", "2130706433": "public", "[::ffff:8.8.8.8]": "public"}
        cams = [cam(host=h, name="n%d" % i) for i, h in enumerate(expect)]
        cams += [cam(brand="custom", host="", url="rtsp://192.168.1.9/x", name="c1"), cam(brand="custom", host="", url="http://cam.example.com:8080/x", name="c2"),
                 cam(brand="custom", host="", url="rtsp://u:p@[fd00::5]:554/x", name="c3"), cam(brand="custom", host="", url="http://localhost/x", name="c4")]
        got = self.open_text(make_share(good_doc(cameras=cams)))
        self.assertTrue(got["ok"], got)
        scopes = [c["scope"] for c in got["cameras"]]
        self.assertEqual(scopes, list(expect.values()) + ["local", "public", "local", "loopback"])


class NoLeaks(Base):
    def test_failed_ops_reveal_nothing(self):
        secrets = (PASS, "other-wrong-passphrase", SECRET_PASSWORD, "Front Door")
        ans, p = self.export()
        text = slurp(p)
        results = []
        results.append(run(open_req(p, "other-wrong-passphrase")))
        results.append(run(open_req(self.write("junk"), PASS)))
        results.append(run(open_req(self.path("nope"), PASS)))
        results.append(run(export_req(p)))                                          # exists
        results.append(run(export_req(self.path("x"), passphrase="short")))          # weak
        results.append(run(export_req(self.path("y"), cameras=[cam(host="a;b")])))  # invalid camera
        results.append(run(open_req(p, PASS), env={"PATH": "/nonexistent"}))        # still fine: no clipboard needed
        for i, (ans, out, err) in enumerate(results[:-1]):
            with self.subTest(i):
                self.assertFalse(ans["ok"])
                self.assertEqual(set(ans) - {"index"}, {"ok", "error"})
                self.assertEqual(err, b"")
                for s in secrets:
                    self.assertNotIn(s, out)
        self.assertEqual(results[5][0].get("index"), 0)
        self.assertEqual(results[5][0]["error"], "invalid_camera")
        self.assertTrue(results[-1][0]["ok"])

    def test_nothing_on_stderr_even_when_it_crashes(self):
        for raw in (b"\xff\xfe\x00", b"{" * 100000, b'{"op":"open","passphrase":"x","brands":{"a":1},"source":{"file":"/etc/hostname"}}\n'):
            ans, out, err = run(None, raw=raw)
            self.assertEqual(err, b"")
            self.assertFalse(ans["ok"])


class Tools(Base):
    """passphrase, find, copy, and the clipboard paths with fake wl-copy / wl-paste."""

    def fakebin(self, copy_script=None, paste_script=None):
        d = self.path("bin")
        os.makedirs(d, exist_ok=True)
        for name, body in (("wl-copy", copy_script), ("wl-paste", paste_script)):
            if body is None:
                continue
            f = os.path.join(d, name)
            with open(f, "w") as h:
                h.write("#!/bin/sh\n" + body + "\n")
            os.chmod(f, 0o755)
        return {"PATH": d + ":/usr/bin:/bin"}

    def test_passphrase(self):
        seen = set()
        for _ in range(5):
            ans, out, err = run({"op": "passphrase"})
            self.assertTrue(ans["ok"])
            self.assertRegex(ans["passphrase"], r"^([a-z0-9]{4}-){4}[a-z0-9]{4}$")
            self.assertFalse(set(ans["passphrase"]) & set("ilo1"))
            seen.add(ans["passphrase"])
        self.assertEqual(len(seen), 5)

    def test_find(self):
        home = self.dir
        os.mkdir(os.path.join(home, "Downloads"))
        names = []
        for i, where in enumerate(["Downloads", "Downloads", ".", ".", "Downloads"]):
            p = os.path.normpath(os.path.join(home, where, "s%d.omacam" % i))
            put(p)
            os.utime(p, (1000 + i * 10, 1000 + i * 10))
            names.append(p)
        put(os.path.join(home, "other.txt"))
        os.symlink(names[0], os.path.join(home, "link.omacam"))
        os.mkdir(os.path.join(home, "dir.omacam"))
        put(os.path.join(home, "Downloads", "huge.omacam"), "", 2 * 1024 * 1024)
        os.makedirs(os.path.join(home, "deeper"))
        put(os.path.join(home, "deeper", "deep.omacam"))
        ans, out, err = run({"op": "find"}, env={"HOME": home})
        self.assertTrue(ans["ok"])
        self.assertEqual([f["path"] for f in ans["files"]], [names[4], names[3], names[2]])
        self.assertEqual(set(ans["files"][0]), {"path", "name", "mtime"})
        self.assertEqual(ans["files"][0]["mtime"], 1040)
        ans, out, err = run({"op": "find"}, env={"HOME": self.path("empty")})
        self.assertEqual(ans, {"files": [], "ok": True})

    def test_export_to_clipboard_and_open_from_clipboard(self):
        sink = self.path("clip")
        env = self.fakebin('echo "$@" > "%s.args"; cat > "%s"; (sleep 4 &) ; exit 0' % (sink, sink),
                           'echo "$@" > "%s.pargs"; cat "%s"' % (sink, sink))
        t = time.time()
        ans, out, err = run(export_req(None, dest={"clipboard": True}, cameras=[cam(name="Clip")]), env=env)
        self.assertEqual(ans, {"count": 1, "ok": True})
        self.assertLess(time.time() - t, 3.5, "must not wait for a background clipboard server")
        self.assertEqual(slurp(sink + ".args").strip(), "")          # not marked sensitive
        self.assertTrue(slurp(sink).startswith(M.BEGIN))
        req = {"op": "open", "passphrase": PASS, "source": {"clipboard": True}, "brands": BRANDS}
        got, out, err = run(req, env=env)
        self.assertTrue(got["ok"], got)
        self.assertEqual(got["cameras"][0]["name"], "Clip")
        self.assertEqual(slurp(sink + ".pargs").split(), ["--no-newline", "--type", "text"])

    def test_clipboard_problems(self):
        nothing = {"PATH": self.path("none")}
        req = {"op": "open", "passphrase": PASS, "source": {"clipboard": True}, "brands": BRANDS}
        self.assertError(run(req, env=nothing)[0], "clipboard_unavailable")
        self.assertError(run(export_req(None, dest={"clipboard": True}), env=nothing)[0], "clipboard_unavailable")
        failing = self.fakebin("cat >/dev/null; exit 1", "exit 1")
        self.assertError(run(export_req(None, dest={"clipboard": True}), env=failing)[0], "clipboard_unavailable")
        self.assertError(run(req, env=failing)[0], "not_a_share")
        huge = self.fakebin(None, "head -c 3000000 /dev/zero")
        self.assertError(run(req, env=huge)[0], "too_large")
        hang = self.fakebin(None, "sleep 30")
        t = time.time()
        self.assertError(run(req, env=hang, timeout=20)[0], "not_a_share")
        self.assertLess(time.time() - t, 10)

    def test_copy_passphrase_is_always_sensitive(self):
        sink = self.path("clip")
        env = self.fakebin('echo "$@" > "%s.args"; cat > "%s"' % (sink, sink))
        ans, out, err = run({"op": "copy", "text": "abcd-efgh", "sensitive": True}, env=env)
        self.assertEqual(ans, {"ok": True})
        self.assertEqual(slurp(sink + ".args").split(), ["--sensitive"])
        self.assertEqual(slurp(sink), "abcd-efgh")
        for req in ({"op": "copy", "text": "x"}, {"op": "copy", "text": "x", "sensitive": False}, {"op": "copy", "sensitive": True},
                    {"op": "copy", "text": "", "sensitive": True}, {"op": "copy", "text": "x" * 5000, "sensitive": True}):
            self.assertError(run(req, env=env)[0], "bad_request")
        # wl-copy without --sensitive support
        old = self.fakebin('for a in "$@"; do [ "$a" = "--sensitive" ] && exit 1; done; cat >/dev/null')
        self.assertError(run({"op": "copy", "text": "x", "sensitive": True}, env=old)[0], "clipboard_unavailable")


class BrandTable(unittest.TestCase):
    def test_matches_brands_js(self):
        text = slurp(os.path.join(ROOT, "Brands.js"))
        found = {}
        for m in re.finditer(r'\{ id: "(\w+)",[^\n]*?streams: \[(.*?)\] \}', text):
            found[m.group(1)] = len(re.findall(r"\b(?:rtsp|http)\(", m.group(2)))
        self.assertEqual(found, BRANDS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
