"""Tests that run the plugin's JavaScript (Brands.js, Config.js) with node, and
the shell script in Panel.qml.

Run:  python3 -I -m unittest discover -s tests -v

Dev-only: everything is skipped when `node` is not installed. Brands.js and
Config.js are QML `.pragma library` files; they are loaded here by dropping the
pragma line and evaluating the rest in a function scope. All data is made up.
"""
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True      # importing share.py must not leave __pycache__ behind

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import test_share as TS             # the loaded share.py module (M) and its helpers

NODE = shutil.which("node")
M = TS.M
BRANDS = TS.BRANDS

LOADER = r"""
const fs = require('fs')
function load(file, names) {
  const src = fs.readFileSync(file, 'utf8').replace(/^\.pragma library.*$/m, '')
  return new Function(src + '\nreturn {' + names.join(',') + '};')()
}
const Brands = load(process.argv[2], ['checkCamera', 'displayUrl', 'identity', 'streamUrl', 'hostLabel', 'credentials', 'snapshotRequest', 'splitHost', 'validHost', 'brandTable'])
const Config = load(process.argv[3], ['DEFAULTS', 'sanitize', 'merge', 'matches', 'validKeys'])
"""


def node(script, stdin=""):
    """Runs script (JS, with Brands and Config loaded) -> parsed JSON it prints."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "run.js")
        with open(path, "w") as f:
            f.write(LOADER + script)
        p = subprocess.run([NODE, path, os.path.join(ROOT, "Brands.js"), os.path.join(ROOT, "Config.js")],
                           input=stdin.encode(), capture_output=True, timeout=120)
    if p.returncode != 0:
        raise AssertionError("node failed: " + p.stderr.decode()[-2000:])
    return json.loads(p.stdout.decode())


def ccam(**kw):
    c = {"name": "Front Door", "brand": "hikvision", "host": "192.168.1.42", "url": "", "user": "admin",
         "password": "pw", "variant": 0, "enabled": True}
    c.update(kw)
    return c


def custom(url, **kw):
    return ccam(brand="custom", host="", url=url, **kw)


def corpus():
    """A few hundred hostile and edge-case camera records (deterministic)."""
    out = []
    hosts = ["192.168.1.42", "192.168.1.42:554", "cam.local", "cam.local:8554", "a", "A-b.c", "-a", "a-", "a.", ".a", "a..b",
             "a_b", "a b", " a", "a ", "a\n", "a\u00e9", "\u00e9", "rtsp://a", "a/b", "a;b", "a$b", "`a`", "a@b", "a:", ":80",
             "a:0", "a:1", "a:65535", "a:65536", "a:99999", "a:123456", "a:-1", "a:08", "x" * 253, "x" * 255, "x" * 256,
             "1.2.3.4", "1.2.3", "1.2.3.4.5", "01.2.3.4", "256.1.1.1", "0x7f.1", "2130706433", "localhost", "LOCALHOST.",
             "[::1]", "[::]", "[1.2.3.4]", "[]", "[", "]", "[::1", "::1]", "[::1]:80", "[::1]:0", "[::1]x", "[:::1]", "[1::2::3]",
             "[fe80::1]", "[FE80::AbCd]", "[fe80::1%eth0]", "[::ffff:1.2.3.4]", "[::ffff:1.2.3]", "[::ffff:01.2.3.4]",
             "[::ffff:256.1.1.1]", "[1:2:3:4:5:6:7:8]", "[1:2:3:4:5:6:7:8:9]", "[1:2:3:4:5:6:7]", "[1:2:3:4:5:6:7::]", "[::2:3:4:5:6:7:8]",
             "[1:2:3:4:5:6:1.2.3.4]", "[1:2:3:4:5:6:7:1.2.3.4]", "[12345::]", "[g::]", "[:1:2:3:4:5:6:7]", "[1:2:3:4:5:6:7:]",
             "[::1.2.3.4]", "[1.2.3.4::]", "[1::1.2.3.4]", "[::.]", "[:.]", "[..]", "[::1:]", "[:1::]"]
    for i, h in enumerate(hosts):
        out.append(ccam(host=h, name="h%d" % i))
    rnd = random.Random(20260116)
    # random IPv6-ish hosts: the two validators must agree on every one
    for i in range(160):
        n = rnd.choice([3, 4, 5, 7, 8, 9])
        pieces = [rnd.choice(["", "0", "1", "ff", "FFFF", "10000", "fe80", "g", "1.2.3.4", "01.1.1.1", "300.1.1.1"]) for _ in range(n)]
        out.append(ccam(host="[" + ":".join(pieces) + "]" + rnd.choice(["", "", ":554", ":0"]), name="v6-%d" % i))
    for i in range(60):
        text = "".join(rnd.choice("0123456789abcdefABCDEF:.") for _ in range(rnd.randint(1, 20)))
        out.append(ccam(host="[" + text + "]", name="r6-%d" % i))

    urls = ["rtsp://192.168.1.5/live", "RTSP://H/x", "http://h:8080/a?b=c#d", "https://h/x", "rtsps://h/x", "file:///etc/passwd",
            "rtsp:/h/x", "rtsp://", "rtsp:///x", "rtsp://h", "rtsp://h:/x", "rtsp://h:0/x", "rtsp://h:70000/x", "rtsp://[::1]:554/x",
            "rtsp://[1.2.3.4]/x", "rtsp://[::1/x", "rtsp://h/a b", "rtsp://h/a\tb", "rtsp://h/a\x00b", "rtsp://h/a\\b", "rtsp://h/\u00e9",
            "rtsp://h/\u2028", "rtsp://h/%zz", "rtsp://h/%", "rtsp://h/%41", "rtsp://h?x", "rtsp://h#x", "rtsp://h@/x", "rtsp://@h/x",
            "rtsp://a:b@h/x", "rtsp://a:b@c:d@h/x", "rtsp://a@b@h/x", "rtsp://:b@h/x", "rtsp://a:@h/x", "rtsp://a%40b:p%3Aq@h/x",
            "rtsp://a%zz:b@h/x", "rtsp://a:b%zz@h/x", "rtsp://a%:b@h/x", "rtsp://a:b%@h/x", "rtsp://a%ff:b@h/x", "rtsp://a:b%c3@h/x",
            "rtsp://%c3%a9:%e2%82%ac@h/x", "rtsp://%c3a:b@h/x", "rtsp://%%41:b@h/x", "rtsp://%00:b@h/x", "rtsp://a%22b:p@h/x",
            "rtsp://a:p%0a@h/x", "rtsp://a%C3%A9:b@h/x", "rtsp://%ed%a0%80:b@h/x", "rtsp://%f4%90%80%80:b@h/x", "rtsp://%c0%af:b@h/x",
            "rtsp://" + "u" * 200 + "@h/x", "rtsp://u:" + "p" * 300 + "@h/x", "rtsp://h/" + "x" * 2100, "rtsp://h/" + "x" * 2030,
            "rtsp://h/x?user=a&password=b", "rtsp://h/x?a=%zz&b", "http://user:pw@cam.local/video.mjpg", "rtsp://h/" + "\ud83d\ude00",
            "rtsp://h/\x7f", "rtsp://h/\u0085", "  rtsp://h/x", "rtsp://h/x  ", "rtsp://h/x\n", ""]
    for i, u in enumerate(urls):
        out.append(custom(u, name="u%d" % i, user="", password=""))
        out.append(custom(u, name="ul%d" % i, user="me", password="pw"))
        out.append(custom(u, name="ux%d" % i, user="", password="pw"))

    names = ["", " ", "\t", "A", "a" * 64, "a" * 65, "a" * 512, "a" * 513, " a ", "a  b", "a\tb", "a\nb", "a\u00a0b", "a\u3000b",
             "\u200ex", "x\u200f", "\u061cx", "a\u200eb", "\u202e", "\u2066a\u2069", "a\u2028b", "a\u2029b", "a\ufeffb", "\ufeff",
             "a\x00b", "a\x07b", "a\x1cb", "a\x1fb", "\x7fa", "a\x85b", "\x85", "a\u200bb", "\u200b", "\U0001f600" * 64, "\U0001f600" * 65,
             "\ud83d", "\ude00", "a\ud83db", "\u00e9" * 64, "e\u0301" * 33, "a\u180eb", "\u180e", "a\u2000b", "a\u200ab", "a\u200cb",
             "\u00a0", "\u1680", "\u205f", "x" * 63 + " ", "x" * 64 + " ", " " + "x" * 64, "x" * 63 + "\u200e" + "y"]
    for i, n in enumerate(names):
        out.append(ccam(name=n, host="h%d" % i))

    logins = [("", ""), ("a", ""), ("", "p"), ('a"b', "p"), ("a\nb", "p"), ("a", "p\nq"), ("u" * 128, "p"), ("u" * 129, "p"), ("a", "p" * 256),
              ("a", "p" * 257), ("\u00e9", "\u20ac"), ("\ud83d", "p"), ("a", "\ude00"), ("a\x7fb", "p"), ("a\x85", "p"), ("a\u2028", "p"),
              ("a", "p%zz"), ("a;b", "$(x)"), ("\U0001f600" * 128, "x"), ("\U0001f600" * 129, "x"), ("a b", "p q")]
    for i, (u, p) in enumerate(logins):
        out.append(ccam(name="l%d" % i, user=u, password=p))
        out.append(custom("rtsp://h/x", name="lc%d" % i, user=u, password=p))

    brands = list(BRANDS) + ["", "Custom", "CUSTOM", "constructor", "__proto__", "hasOwnProperty", "toString", " hikvision", None, 5, True, [], {}]
    for i, b in enumerate(brands):
        out.append(ccam(brand=b, name="b%d" % i, host="h", url="rtsp://h/x"))
        out.append(ccam(brand=b, name="bc%d" % i, host="", url="rtsp://h/x"))

    variants = [0, 1, 2, 3, 4, -1, 1.5, True, False, None, "0", "1", [], {}, 10 ** 9, -0.5]
    for i, v in enumerate(variants):
        for b in ("hikvision", "dlink", "custom", "tapo"):
            c = ccam(brand=b, name="va%d" % i, variant=v, url="rtsp://h/x" if b == "custom" else "", host="" if b == "custom" else "h")
            out.append(c)
    for i, e in enumerate([True, False, None, "true", 1, 0, [], {}]):
        out.append(ccam(name="e%d" % i, enabled=e))
    # a missing variant / enabled, extra keys, null fields
    c = ccam(name="missing"); del c["variant"]; del c["enabled"]; out.append(c)
    out.append(ccam(name="extra", id="x", subUrl="rtsp://y/z", evil={"a": 1}))
    for key in ("name", "host", "url", "user", "password"):
        for tag, value in (("null", None), ("num", 5), ("list", [])):
            c = ccam(); c[key] = value; c["name"] = tag + "-" + key if key != "name" else value; out.append(c)
        c = ccam(); del c[key]
        if key != "name":
            c["name"] = "gone-" + key
        out.append(c)
    # a preset keeps no url, a custom camera no host, whatever they hold
    for stale in ["rtsp://junk", "x" * 5000, "a b", 5, None, [], "\ud800", "x" * 2049]:
        out.append(ccam(name="stale-url", url=stale))
    for stale in ["stale", "x" * 300, "a b;c", 5, None, [], "\ud800", "[zz]"]:
        out.append(ccam(brand="custom", url="rtsp://h/x", name="stale-host", host=stale))
    # not cameras
    for v in ("camera", 5, None, [], [1], True):
        out.append(v)
    return out


class CrossLanguage(unittest.TestCase):
    @unittest.skipIf(NODE is None, "node is not installed")
    def test_share_py_and_brands_js_agree(self):
        cases = corpus()
        self.assertGreater(len(cases), 500)
        # json can't carry an integral float as a float, so this corpus has none
        text = json.dumps(cases, ensure_ascii=True)
        js = node("""
const cases = JSON.parse(fs.readFileSync(0, 'utf8'))
console.log(JSON.stringify(cases.map(c => { const r = Brands.checkCamera(c); return r.ok ? r.record : null })))
""", text)
        self.assertEqual(len(js), len(cases))
        accepted = 0
        for rec, got in zip(json.loads(text), js):
            try:
                want = M.check_camera(rec, BRANDS, True)
            except M.Invalid:
                want = None
            with self.subTest(rec=repr(rec)[:120]):
                self.assertEqual(got, want)
            accepted += want is not None
        self.assertGreater(accepted, 100)                  # the corpus isn't all rejects
        self.assertLess(accepted, len(cases) - 100)        # ...nor all accepts

    @unittest.skipIf(NODE is None, "node is not installed")
    def test_malformed_escapes_in_userinfo_stay_literal_in_both(self):
        for url, user, password in [("rtsp://a%zz:b%@h/x", "a%zz", "b%"), ("rtsp://%41:%%41@h/x", "A", "%A")]:
            got = M.check_camera(custom(url, user="", password=""), BRANDS, True)
            self.assertEqual((got["user"], got["password"]), (user, password))
            r = node("console.log(JSON.stringify(Brands.checkCamera(JSON.parse(fs.readFileSync(0, 'utf8')))))",
                     json.dumps(custom(url, user="", password="")))
            self.assertTrue(r["ok"], url)
            self.assertEqual((r["record"]["user"], r["record"]["password"]), (user, password))
        # a sequence that is not UTF-8 is refused by both
        self.assertRaises(M.Invalid, M.check_camera, custom("rtsp://a%ff:b@h/x", user="", password=""), BRANDS, True)
        self.assertFalse(node("console.log(JSON.stringify(Brands.checkCamera(JSON.parse(fs.readFileSync(0, 'utf8')))))",
                              json.dumps(custom("rtsp://a%ff:b@h/x", user="", password="")))["ok"])

    @unittest.skipIf(NODE is None, "node is not installed")
    def test_form_mode(self):
        cases = {
            "scheme and path stripped": (ccam(host="rtsp://cam.local:8554/stream1"), True, "cam.local:8554"),
            "http scheme": (ccam(host="HTTP://1.2.3.4/x?y=z"), True, "1.2.3.4"),
            "underscore": (ccam(host="cam_1.local"), True, "cam_1.local"),
            "trailing dot": (ccam(host="cam.local."), True, "cam.local."),
            "ipv6 with port": (ccam(host="[::1]:554"), True, "[::1]:554"),
            "spaces trimmed": (ccam(host="  1.2.3.4  "), True, "1.2.3.4"),
            "empty after strip": (ccam(host="rtsp://"), False, None),
            "inner space": (ccam(host="a b"), False, None),
            "newline": (ccam(host="a\nb"), False, None),
            "semicolon": (ccam(host="a;touch x"), False, None),
            "dollar": (ccam(host="$(x)"), False, None),
            "backtick": (ccam(host="`x`"), False, None),
            "pipe": (ccam(host="a|b"), False, None),
            "amp": (ccam(host="a&b"), False, None),
            "angle": (ccam(host="a<b"), False, None),
            "brace": (ccam(host="a{b}"), False, None),
            "quote": (ccam(host="a'b"), False, None),
            "dquote": (ccam(host='a"b'), False, None),
            "backslash": (ccam(host="a\\b"), False, None),
            "at": (ccam(host="u@h"), False, None),
            "leading dash": (ccam(host="-x"), False, None),
            "nbsp": (ccam(host="a\u00a0b"), False, None),
            "too long": (ccam(host="x" * 256), False, None),
            "user quote": (ccam(user='a"b'), False, None),
            "long name cut": (ccam(name="n" * 80), True, "192.168.1.42"),
            "preset ignores url": (ccam(url="x" * 5000), True, "192.168.1.42"),
        }
        names = list(cases)
        js = node("""
const cases = JSON.parse(fs.readFileSync(0, 'utf8'))
console.log(JSON.stringify(cases.map(c => Brands.checkCamera(c, { form: true }))))
""", json.dumps([cases[n][0] for n in names]))
        for n, r in zip(names, js):
            with self.subTest(n):
                self.assertEqual(r["ok"], cases[n][1], r)
                if r["ok"]:
                    self.assertEqual(r["record"]["host"], cases[n][2])
        long_name = js[names.index("long name cut")]["record"]["name"]
        self.assertEqual(long_name, "n" * 64)
        self.assertIn("double quote", js[names.index("user quote")]["error"])
        # the form's strict counterpart still refuses what the form lets through
        strict = node("console.log(JSON.stringify(Brands.checkCamera(JSON.parse(fs.readFileSync(0, 'utf8')))))",
                      json.dumps(ccam(host="rtsp://cam.local/x")))
        self.assertFalse(strict["ok"])


class ConfigSanitize(unittest.TestCase):
    def run_cases(self):
        return node(r"""
function shape(v) {
  if (Array.isArray(v)) return v.length > 0 && v.length <= 8 && v.every(x => typeof x === 'string') ? 'key list' : 'BAD LIST'

  if (v !== null && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).sort()) o[k] = shape(v[k]); return o }
  return typeof v
}
const D = Config.DEFAULTS
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const cases = {}
function run(name, input, current) { const out = Config.sanitize(input, current); cases[name] = { out, shapeOk: same(shape(out), shape(D)) } }

run('undefined', undefined)
run('null', null)
run('string', 'x')
run('array', [1, 2])
run('number', 5)
run('empty', {})
run('proto', JSON.parse('{"__proto__":{"polluted":1},"constructor":{"prototype":{"x":1}},"connection":{"__proto__":{"y":1},"retrySeconds":7}}'))
run('own constructor', { constructor: 1, hasOwnProperty: 2, toString: 3, connection: { constructor: 1, retrySeconds: 9 } })
run('unknown keys', { evil: 1, connection: { evil: true, retrySeconds: 8 }, keys: { evil: ['x'], dropdown: { evil: ['x'] } } })
run('wrong types', { version: 'x', connection: { alwaysConnected: 'yes', retrySeconds: '20', lowLatency: 1 }, bar: { leftClick: 5, showCount: null }, dropdown: 7, keys: 'x' })
run('nan inf', { connection: { retrySeconds: NaN, keepConnectedSeconds: Infinity, statusCheckSeconds: -Infinity, warmOnHoverSeconds: -0 }, dropdown: { columns: NaN }, pinned: { width: Infinity } })
run('clamps', { connection: { keepConnectedSeconds: 99999, retrySeconds: 0, statusCheckSeconds: 1, warmOnHoverSeconds: -5 }, dropdown: { columns: 99 }, wall: { columns: -3 }, pinned: { width: 5, snapDistance: 1e9 } })
run('rounds', { connection: { retrySeconds: 12.6 }, dropdown: { columns: 2.4 } })
run('version', { version: 99 })
run('enums', { bar: { leftClick: 'wall', middleClick: 'none', rightClick: 'bogus' }, dropdown: { click: 'pin', doubleClick: 'wall' }, wall: { click: 'enlarge' } })
run('enum proto', { bar: { leftClick: 'constructor', middleClick: '__proto__', rightClick: 'toString' } })
run('keys good', { keys: { dropdown: { up: ['w', 'Ctrl+q', 'Shift+Tab', 'F5', 'Ctrl++', '+', 'Escape'] }, wall: { close: 'q' } } })
run('keys dead names', { keys: { dropdown: { up: ['Foo'], down: ['Return', 'Bogus'], left: ['Ctrl+Nope'], right: ['constructor'], open: ['__proto__'] } } })
run('keys bad mods', { keys: { dropdown: { up: ['Foo+q'], down: ['Ctrl+'], left: ['++'], right: ['Ctrl+Shift+'], open: [''] } } })
run('keys too many', { keys: { dropdown: { up: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'] } } })
run('keys 8 ok', { keys: { dropdown: { up: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'] } } })
run('keys empty', { keys: { dropdown: { up: [], down: '', left: [''], right: null }, enlarged: { back: [] } } })
run('keys wrong types', { keys: { dropdown: { up: [1, 2], down: [['a']], left: { 0: 'a' }, right: 5 }, cameraNumbers: 'yes' } })
run('keys long', { keys: { dropdown: { up: ['x'.repeat(40)], down: ['Ctrl+Ctrl+Shift+Alt+Super+Meta+Return'] } } })
run('keys spaces', { keys: { dropdown: { up: [' '], down: ['a b'], left: ['\n'], right: ['Ctrl+ '] } } })
run('current kept', { connection: { retrySeconds: 'x', lowLatency: 'x' }, keys: { dropdown: { up: ['Nope'] } } }, { connection: { retrySeconds: 33, lowLatency: false }, keys: { dropdown: { up: ['z'] } } })
run('current bad too', { keys: { dropdown: { up: ['Nope'] } } }, { keys: { dropdown: { up: ['AlsoNope'] } } })
run('current wrong type', { connection: { retrySeconds: 'x' } }, { connection: 'zzz' })
run('deep', { keys: { dropdown: { up: ['a'] } }, a: { b: { c: {} } } })
run('defaults', D)
const frozen = JSON.stringify(D)
Config.sanitize({ connection: { retrySeconds: 3 } })
cases['defaults untouched'] = { out: JSON.stringify(D) === frozen }
cases['proto clean'] = { out: ({}).polluted === undefined && ({}).x === undefined && ({}).y === undefined }
const real = Config.sanitize(Config.merge(D, { keys: { dropdown: { up: ['Up'] } } }), D)
cases['defaults roundtrip'] = { out: same(Config.sanitize(D, D), D) }
console.log(JSON.stringify(cases))
""")

    @unittest.skipIf(NODE is None, "node is not installed")
    def test_shape_is_always_the_defaults(self):
        for name, r in self.run_cases().items():
            if "shapeOk" in r:
                with self.subTest(name):
                    self.assertTrue(r["shapeOk"], r["out"])

    @unittest.skipIf(NODE is None, "node is not installed")
    def test_values(self):
        c = {k: v["out"] for k, v in self.run_cases().items()}
        self.assertTrue(c["defaults untouched"])
        self.assertTrue(c["proto clean"])
        self.assertTrue(c["defaults roundtrip"])
        for name in ("undefined", "null", "string", "array", "number", "empty"):
            self.assertEqual(c[name], c["defaults"], name)
        self.assertEqual(c["proto"]["connection"]["retrySeconds"], 7)
        self.assertEqual(c["own constructor"]["connection"]["retrySeconds"], 9)
        self.assertEqual(c["unknown keys"]["connection"]["retrySeconds"], 8)
        self.assertNotIn("evil", c["unknown keys"])
        self.assertNotIn("evil", c["unknown keys"]["keys"])
        d = c["defaults"]
        w = c["wrong types"]
        self.assertEqual((w["version"], w["connection"], w["bar"], w["dropdown"], w["keys"]), (1, d["connection"], d["bar"], d["dropdown"], d["keys"]))
        n = c["nan inf"]
        self.assertEqual(n["connection"]["retrySeconds"], d["connection"]["retrySeconds"])
        self.assertEqual(n["connection"]["keepConnectedSeconds"], d["connection"]["keepConnectedSeconds"])
        self.assertEqual(n["connection"]["statusCheckSeconds"], d["connection"]["statusCheckSeconds"])
        self.assertEqual(n["dropdown"]["columns"], d["dropdown"]["columns"])
        self.assertEqual(n["pinned"]["width"], d["pinned"]["width"])
        self.assertEqual(n["connection"]["warmOnHoverSeconds"], 0)
        k = c["clamps"]
        self.assertEqual((k["connection"]["keepConnectedSeconds"], k["connection"]["retrySeconds"], k["connection"]["statusCheckSeconds"], k["connection"]["warmOnHoverSeconds"]), (3600, 1, 5, 0))
        self.assertEqual((k["dropdown"]["columns"], k["wall"]["columns"], k["pinned"]["width"], k["pinned"]["snapDistance"]), (6, 0, 160, 200))
        self.assertEqual((c["rounds"]["connection"]["retrySeconds"], c["rounds"]["dropdown"]["columns"]), (13, 2))
        self.assertEqual(c["version"]["version"], 1)
        e = c["enums"]
        self.assertEqual((e["bar"]["leftClick"], e["bar"]["middleClick"], e["bar"]["rightClick"]), ("wall", "none", d["bar"]["rightClick"]))
        self.assertEqual((e["dropdown"]["click"], e["dropdown"]["doubleClick"], e["wall"]["click"]), ("pin", d["dropdown"]["doubleClick"], "enlarge"))
        p = c["enum proto"]["bar"]
        self.assertEqual((p["leftClick"], p["middleClick"], p["rightClick"]), (d["bar"]["leftClick"], d["bar"]["middleClick"], d["bar"]["rightClick"]))
        g = c["keys good"]["keys"]
        self.assertEqual(g["dropdown"]["up"], ["w", "Ctrl+q", "Shift+Tab", "F5", "Ctrl++", "+", "Escape"])
        self.assertEqual(g["wall"]["close"], ["q"])
        for name in ("keys dead names", "keys bad mods", "keys too many", "keys empty", "keys wrong types", "keys long", "keys spaces"):
            for action, keys in c[name]["keys"]["dropdown"].items():
                self.assertEqual(keys, d["keys"]["dropdown"][action], (name, action))
        self.assertEqual(c["keys empty"]["keys"]["enlarged"]["back"], d["keys"]["enlarged"]["back"])
        self.assertEqual(c["keys 8 ok"]["keys"]["dropdown"]["up"], list("abcdefgh"))
        self.assertEqual(c["keys long"]["keys"]["dropdown"]["down"], d["keys"]["dropdown"]["down"])
        cur = c["current kept"]
        self.assertEqual((cur["connection"]["retrySeconds"], cur["connection"]["lowLatency"], cur["keys"]["dropdown"]["up"]), (33, False, ["z"]))
        self.assertEqual(c["current bad too"]["keys"]["dropdown"]["up"], d["keys"]["dropdown"]["up"])
        self.assertEqual(c["current wrong type"]["connection"], d["connection"])
        self.assertEqual(c["deep"]["keys"]["dropdown"]["up"], ["a"])
        self.assertNotIn("a", c["deep"])

    @unittest.skipIf(NODE is None, "node is not installed")
    def test_every_accepted_key_is_one_matches_understands(self):
        """The key lists sanitize lets through are exactly those Config.matches can act on."""
        specs = ["a", "Z", "1", "+", "é", "Ctrl+q", "ctrl+Q", "Control+q", "Shift+Tab", "Alt+Left", "Super+F5", "Meta+Return", "Ctrl++",
                 "Escape", "esc", "Tab", "BackTab", "BackSpace", "Return", "Enter", "Space", "Delete", "Home", "End", "PageUp", "PageDown",
                 "Insert", "F1", "f12", "F13", "F0", "Foo", "Ctrl+Foo", "Foo+q", "Ctrl+", "++", "", " ", "a b", "Ctrl+Shift+", "constructor",
                 "__proto__", "toString", "Ctrl+constructor", "Up", "up", "Down", "Left", "Right", "KP_Enter", "Ctrl+Alt+Shift+Super+q"]
        res = node("""
const specs = JSON.parse(fs.readFileSync(0, 'utf8'))
console.log(JSON.stringify(specs.map(s => {
  const kept = Config.validKeys([s]) !== null
  // does matches() know the key? try every named/char key it could mean
  return kept
})))
""", json.dumps(specs))
        accepted = {s for s, ok in zip(specs, res) if ok}
        for s in ("a", "Z", "+", "Ctrl+q", "Shift+Tab", "Ctrl++", "Escape", "F1", "f12", "Enter", "Space", "PageDown", "Super+F5", "Ctrl+Alt+Shift+Super+q"):
            self.assertIn(s, accepted)
        for s in ("F13", "F0", "Foo", "Ctrl+Foo", "Foo+q", "Ctrl+", "++", "", " ", "a b", "Ctrl+Shift+", "constructor", "__proto__",
                  "toString", "Ctrl+constructor", "KP_Enter"):
            self.assertNotIn(s, accepted)


class PanelScript(unittest.TestCase):
    """The reachability check in Panel.qml: host and port are only ever arguments."""

    def script(self):
        with open(os.path.join(ROOT, "Panel.qml")) as f:
            text = f.read()
        m = re.search(r'command = \["bash", "-c",\s*\n\s*\'((?:[^\'\\]|\\.)*)\',\s*\n\s*"omacam-reach"\]', text)
        self.assertIsNotNone(m, "the reachability command in Panel.qml moved")
        return m.group(1).replace("\\'", "'")

    def reach(self, entries):
        args = []
        for ident, host, port in entries:
            args += [ident, host, str(port)]
        p = subprocess.run(["bash", "-c", self.script(), "omacam-reach"] + args, capture_output=True, timeout=30, cwd=self.dir, stdin=subprocess.DEVNULL)
        return dict(line.split(" ") for line in p.stdout.decode().splitlines() if line.strip())

    def test_hostile_values_run_nothing_and_a_real_port_is_reachable(self):
        with tempfile.TemporaryDirectory() as self.dir:
            server = socket.socket()
            server.bind(("127.0.0.1", 0))
            server.listen(8)
            port = server.getsockname()[1]
            try:
                hostile = ["x;touch M", "$(touch M)", "`touch M`", "-x", "a|touch M", "a&&touch M", "a\ntouch M", "'; touch M; '", "\"; touch M; \"", "{touch,M}", "x>M"]
                entries = [("good", "127.0.0.1", port)]
                entries += [("h%d" % i, h, port) for i, h in enumerate(hostile)]
                entries += [("p%d" % i, "127.0.0.1", q) for i, q in enumerate(["1;touch M", "$(touch M)", "`touch M`", "-x", "80 ; touch M"])]
                entries += [("closed", "127.0.0.1", 1)]
                got = self.reach(entries)
            finally:
                server.close()
            self.assertEqual(os.listdir(self.dir), [], "a hostile value ran a command")
            self.assertEqual(got.get("good"), "1")
            self.assertEqual(got.get("closed"), "0")
            for ident, host, _ in entries[1:]:
                self.assertEqual(got.get(ident), "0", (ident, host))


class UrlHelpers(unittest.TestCase):
    @unittest.skipIf(NODE is None, "node is not installed")
    def test_display_url_and_identity_survive_malformed_percent(self):
        cams = [
            {"brand": "custom", "url": "rtsp://h.com/%zz", "user": "", "password": ""},
            {"brand": "custom", "url": "rtsp://h.com/%", "user": "a", "password": "p"},
            {"brand": "custom", "url": "rtsp://h.com/%e0%a4%a", "user": "", "password": ""},
            {"brand": "custom", "url": "rtsp://h.com/%41%", "user": "a%zz", "password": "100%"},
            {"brand": "custom", "url": "rtsp://a:b@h.com/%ff", "user": "", "password": ""},
            {"brand": "tapo", "host": "%zz", "user": "a%", "password": "%"},
            {"brand": "tapo", "host": "h", "user": "\ud800", "password": "\udc00x"},
            {"brand": "custom", "url": "", "user": "", "password": ""},
            {"brand": "nope", "host": "x", "user": "", "password": ""},
            {"brand": "custom", "url": None},
            {"brand": "custom"},
        ]
        res = node("""
const cams = JSON.parse(fs.readFileSync(0, 'utf8'))
console.log(JSON.stringify(cams.map(c => {
  const r = {}
  for (const f of ['displayUrl', 'identity', 'hostLabel', 'streamUrl']) { try { r[f] = String(Brands[f](c, 'main')) } catch (e) { r[f] = 'THROWS ' + e.name } }
  try { r.snap = JSON.stringify(Brands.snapshotRequest(c)) } catch (e) { r.snap = 'THROWS ' + e.name }
  return r
})))
""", json.dumps(cams))
        for cam, r in zip(cams, res):
            for field, value in r.items():
                self.assertFalse(value.startswith("THROWS"), (cam, field, value))
        self.assertEqual(res[0]["displayUrl"], "rtsp://h.com/%zz")
        self.assertEqual(res[1]["displayUrl"], "rtsp://a:•••@h.com/%")
        self.assertNotIn("p@", res[1]["displayUrl"])
        self.assertEqual(res[3]["displayUrl"], "rtsp://a%zz:•••@h.com/A%")
        self.assertNotIn("100%", res[3]["displayUrl"])
        self.assertTrue(res[2]["identity"].startswith("custom|rtsp://h.com"))
        self.assertTrue(res[4]["identity"].startswith("custom|rtsp://h.com"))
        self.assertNotIn("a:b", res[4]["identity"])       # no login in an identity
        self.assertIn("%EF%BF%BD", res[6]["streamUrl"])      # a lone surrogate becomes U+FFFD, not an exception


class Scope(unittest.TestCase):
    def scope(self, host, url=None):
        rec = ccam(host=host) if url is None else custom(url)
        return M.scope_of(M.check_camera(rec, BRANDS, True))

    def test_classes(self):
        cases = {
            "local": ["192.168.1.5", "10.1.2.3", "172.16.0.1", "172.31.255.255", "[fd00::1]", "[fc00::1]", "nas", "cam.local", "Cam.LAN",
                      "x.home.arpa", "printer.internal", "[::ffff:192.168.1.5]"],
            "loopback": ["127.0.0.1", "127.255.255.254", "[::1]", "localhost", "LOCALHOST", "foo.localhost", "0.0.0.0", "[::]",
                         "[::ffff:127.0.0.1]", "127.0.0.1:554", "[::1]:554"],
            "linklocal": ["169.254.4.4", "169.254.0.1", "[fe80::1]", "[febf::1]", "[::ffff:169.254.1.1]"],
            "public": ["8.8.8.8", "93.184.216.34", "example.com", "cam.example.org", "[2606:4700::1111]", "2130706433", "0x7f.1", "100.64.1.1",
                       "[::ffff:8.8.8.8]", "cam.local.example.com", "lan.com", "172.32.0.1", "172.15.255.255", "192.169.0.1", "11.0.0.1",
                       "[fec0::1]", "[2001:db8::1]", "224.0.0.1", "192.0.0.1", "0.1.2.3", "localhost.example.com", "mylocalhost.com"],
        }
        for want, hosts in cases.items():
            for h in hosts:
                with self.subTest(host=h):
                    self.assertEqual(self.scope(h), want)

    def test_custom_urls(self):
        self.assertEqual(self.scope(None, "rtsp://u:p@127.0.0.1:554/x"), "loopback")
        self.assertEqual(self.scope(None, "http://localhost:8080/x"), "loopback")
        self.assertEqual(self.scope(None, "rtsp://[fe80::1]/x"), "linklocal")
        self.assertEqual(self.scope(None, "rtsp://169.254.1.1/x"), "linklocal")
        self.assertEqual(self.scope(None, "rtsp://192.168.1.9/x"), "local")
        self.assertEqual(self.scope(None, "http://cam.example.com/x"), "public")
        self.assertEqual(self.scope(None, "rtsp://a:b@evil.example.com/192.168.1.1"), "public")


if __name__ == "__main__":
    unittest.main(verbosity=2)
