# OmaCam share helper: passphrase-encrypted camera sharing.
#
# One request per process: one JSON line on stdin, one JSON line on stdout.
# Passphrases and camera logins only ever travel over those two pipes (never
# argv, environment, temp files or logs); nothing is written to stderr.
#
# Format (version 1): "-----BEGIN OMACAM SHARE-----", base64 of
#   HEADER(40) || CIPHERTEXT || TAG(16), "-----END OMACAM SHARE-----"
# HEADER = b"OMACAM\x00\x01" || kdf 0x01 (scrypt) || log2N || r || p
#          || salt(16) || nonce(12)
# key = scrypt(NFC passphrase, salt, N=2**17, r=8, p=1), cipher = AES-256-GCM
# (system libcrypto through ctypes) with the header as associated data.
# The plaintext is JSON padded with spaces to a multiple of 512 bytes.
#
# Requests: {"op": "passphrase" | "find" | "copy" | "export" | "open", ...}
# Answers:  {"ok": true, ...} or {"ok": false, "error": "<code>"}; an answer
# to a failed request never carries any of the request's data.

import os
import sys

# Before anything that can fail: nothing may reach stderr, and a crash must
# not leave a core dump holding a passphrase. (Only when run as the helper;
# the tests import this file for its functions.)
if __name__ == "__main__":
    try:
        os.dup2(os.open(os.devnull, os.O_WRONLY), 2)
    except Exception:
        pass
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except Exception:
        pass
    os.umask(0o077)

import base64
import binascii
import ctypes
import ctypes.util
import datetime
import hashlib
import ipaddress
import json
import re
import secrets
import stat
import subprocess
import threading
import unicodedata
from urllib.parse import unquote

MAGIC = b"OMACAM\x00\x01"
HEADER_LEN = 40
TAG_LEN = 16
BEGIN = "-----BEGIN OMACAM SHARE-----"
END = "-----END OMACAM SHARE-----"
MAX_SHARE = 1024 * 1024          # share file / clipboard text
MAX_REQUEST = 4 * 1024 * 1024
MAX_CAMERAS = 100
MAX_SETTINGS = 64 * 1024
MAX_SETTINGS_DEPTH = 4
MIN_PASSPHRASE = 12
EXPORT_LOG2N = 17
IMPORT_LOG2N = range(15, 18)     # 2**18 would not fit in the 256 MiB memory cap
SCRYPT_MAXMEM = 256 * 1024 * 1024
PAD = 512
ALPHABET = "abcdefghjkmnpqrstuvwxyz023456789"   # no i l o 1: 32 symbols, 5 bits each


class Invalid(Exception):
    def __init__(self, code, **extra):
        Exception.__init__(self, code)
        self.code = code
        self.extra = extra


# --- AES-256-GCM through libcrypto ----------------------------------------------
EVP_CTRL_AEAD_SET_IVLEN = 0x9
EVP_CTRL_AEAD_GET_TAG = 0x10
EVP_CTRL_AEAD_SET_TAG = 0x11
_lib = None


def _load():
    global _lib
    if _lib is not None:
        return _lib
    # The libcrypto hashlib already uses first, then well-known names.
    candidates = []
    try:
        import _hashlib
        candidates.append(_hashlib.__file__)
    except Exception:
        pass
    candidates += ["libcrypto.so.3", "libcrypto.so.4", "libcrypto.so.1.1", ctypes.util.find_library("crypto")]
    lib = None
    for name in candidates:
        if not name:
            continue
        try:
            found = ctypes.CDLL(name)
            found.EVP_aes_256_gcm
            found.EVP_CIPHER_CTX_new
            lib = found
            break
        except (OSError, AttributeError):
            continue
    if lib is None:
        raise Invalid("crypto_unavailable")
    vp, ci, cvp = ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int)

    def sig(name, res, *args):
        fn = getattr(lib, name)
        fn.restype = res
        fn.argtypes = list(args)

    # restype c_void_p for pointers: the default c_int truncates them.
    sig("EVP_aes_256_gcm", vp)
    sig("EVP_CIPHER_CTX_new", vp)
    sig("EVP_CIPHER_CTX_free", None, vp)
    for kind in ("Encrypt", "Decrypt"):
        sig("EVP_%sInit_ex" % kind, ci, vp, vp, vp, vp, vp)
        sig("EVP_%sUpdate" % kind, ci, vp, vp, cvp, vp, ci)
        sig("EVP_%sFinal_ex" % kind, ci, vp, vp, cvp)
    sig("EVP_CIPHER_CTX_ctrl", ci, vp, ci, ci, vp)
    _lib = lib
    return lib


def _ok(rc):
    if rc != 1:
        raise Invalid("internal")


def _buf(data):
    return ctypes.c_char_p(bytes(data))


def gcm_encrypt(key, nonce, aad, plaintext):
    if len(key) != 32 or len(nonce) != 12:
        raise Invalid("internal")
    lib = _load()
    ctx = lib.EVP_CIPHER_CTX_new()
    if not ctx:
        raise Invalid("internal")
    try:
        n = ctypes.c_int(0)
        _ok(lib.EVP_EncryptInit_ex(ctx, lib.EVP_aes_256_gcm(), None, None, None))
        _ok(lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, None))
        _ok(lib.EVP_EncryptInit_ex(ctx, None, None, _buf(key), _buf(nonce)))
        _ok(lib.EVP_EncryptUpdate(ctx, None, ctypes.byref(n), _buf(aad), len(aad)))
        out = ctypes.create_string_buffer(len(plaintext) + 16)
        _ok(lib.EVP_EncryptUpdate(ctx, out, ctypes.byref(n), _buf(plaintext), len(plaintext)))
        total = n.value
        fin = ctypes.create_string_buffer(16)
        _ok(lib.EVP_EncryptFinal_ex(ctx, fin, ctypes.byref(n)))
        total += n.value
        tag = ctypes.create_string_buffer(TAG_LEN)
        _ok(lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, TAG_LEN, tag))
        return out.raw[:total] + tag.raw
    finally:
        lib.EVP_CIPHER_CTX_free(ctx)


def gcm_decrypt(key, nonce, aad, blob):
    if len(key) != 32 or len(nonce) != 12 or len(blob) < TAG_LEN:
        raise Invalid("internal")
    lib = _load()
    ct, tag = blob[:-TAG_LEN], blob[-TAG_LEN:]
    ctx = lib.EVP_CIPHER_CTX_new()
    if not ctx:
        raise Invalid("internal")
    try:
        n = ctypes.c_int(0)
        _ok(lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_gcm(), None, None, None))
        _ok(lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, None))
        _ok(lib.EVP_DecryptInit_ex(ctx, None, None, _buf(key), _buf(nonce)))
        _ok(lib.EVP_DecryptUpdate(ctx, None, ctypes.byref(n), _buf(aad), len(aad)))
        out = ctypes.create_string_buffer(len(ct) + 16)
        _ok(lib.EVP_DecryptUpdate(ctx, out, ctypes.byref(n), _buf(ct), len(ct)))
        total = n.value
        tagbuf = ctypes.create_string_buffer(tag, TAG_LEN)
        _ok(lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, TAG_LEN, tagbuf))
        fin = ctypes.create_string_buffer(16)
        if lib.EVP_DecryptFinal_ex(ctx, fin, ctypes.byref(n)) != 1:
            raise Invalid("bad_passphrase_or_corrupt")
        total += n.value
        return out.raw[:total]      # only after the tag verified
    finally:
        lib.EVP_CIPHER_CTX_free(ctx)


def derive_key(passphrase, salt, log2n):
    try:
        return hashlib.scrypt(passphrase, salt=salt, n=1 << log2n, r=8, p=1, dklen=32, maxmem=SCRYPT_MAXMEM)
    except (ValueError, AttributeError, MemoryError):
        raise Invalid("crypto_unavailable")


# --- validation (kept in step with checkCamera in Brands.js) ----------------------
HOST_RE = re.compile(r"(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?)(?::([0-9]{1,5}))?")
CTRL_RE = re.compile("[\x00-\x1f\x7f-\x9f]")
NAME_DROP_RE = re.compile("[\x00-\x08\x0e-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]")
NAME_SPACE_RE = re.compile("[ \t\n\r\f\v\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000\ufeff]+")
URL_RE = re.compile(r"(rtsp|http)://([^/?#]*)(.*)", re.I | re.S)
CRED_PARAMS = frozenset(["user", "usr", "username", "login", "pwd", "pass", "passwd", "password", "token", "auth"])
ISO_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
LOCAL_SUFFIXES = (".local", ".lan", ".home.arpa", ".internal")
LAN_NETWORKS = tuple(ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"))
NUMERIC_HOST_RE = re.compile(r"(0[xX][0-9a-fA-F]+|[0-9]+)(\.(0[xX][0-9a-fA-F]+|[0-9]+))*")


def bad(code="invalid_content"):
    raise Invalid(code)


def utf8_ok(text):
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        bad()


def text_field(rec, key, cap):
    value = rec.get(key, "")
    if value is None:
        value = ""                  # a missing and a null field are the same
    if not isinstance(value, str) or len(value) > cap:
        bad()
    utf8_ok(value)
    return value


def clean_name(raw):
    if len(raw) > 512:
        bad()
    text = re.sub("[\t\n\r\f\v]", " ", raw)
    text = NAME_DROP_RE.sub("", text)
    text = NAME_SPACE_RE.sub(" ", text).strip()
    if not 1 <= len(text) <= 64:
        bad()
    return text


def check_host(value):
    m = HOST_RE.fullmatch(value)
    if not m:
        bad()
    if m.group(2) is not None and not 1 <= int(m.group(2)) <= 65535:
        bad()
    if m.group(1).startswith("["):
        try:
            ipaddress.IPv6Address(m.group(1)[1:-1])
        except ValueError:
            bad()
    return m.group(1)


def check_login(user, password):
    if len(user) > 128 or len(password) > 256 or CTRL_RE.search(user) or CTRL_RE.search(password) or '"' in user:
        bad()


def split_url(url):
    """(scheme, userinfo|None, hostport, rest) of an rtsp:// or http:// address."""
    if not 1 <= len(url) <= 2048 or re.search("[\x00-\x20\x7f-\U0010ffff\\\\]", url):
        bad()
    m = URL_RE.fullmatch(url)
    if not m:
        bad()
    authority = m.group(2)
    userinfo = None
    if "@" in authority:
        userinfo, authority = authority.rsplit("@", 1)
    check_host(authority)
    return m.group(1).lower(), userinfo, authority, m.group(3)


def strip_query_credentials(url):
    q = url.find("?")
    if q < 0:
        return url
    rest, frag = url[q + 1:], ""
    h = rest.find("#")
    if h >= 0:
        rest, frag = rest[:h], rest[h:]
    kept = []
    for part in rest.split("&"):
        try:
            name = unquote(part.split("=", 1)[0], errors="strict").lower()
        except UnicodeDecodeError:
            name = ""
        if name not in CRED_PARAMS:
            kept.append(part)
    return url[:q] + ("?" + "&".join(kept) if kept else "") + frag


def host_of(rec):
    hostport = rec["host"]
    if rec["brand"] == "custom":
        hostport = URL_RE.fullmatch(rec["url"]).group(2).rsplit("@", 1)[-1]
    return HOST_RE.fullmatch(hostport).group(1)


def scope_of(rec):
    """Where the camera's address points: "local" (a private home or office
    network), "loopback" (this computer), "linklocal" (169.254/16, fe80::/10)
    or "public" (anything else, including names that aren't plainly local)."""
    host = host_of(rec)
    if host.startswith("["):
        host = host[1:-1]
    host = host.rstrip(".").lower()
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None
    if ip is not None:
        mapped = getattr(ip, "ipv4_mapped", None)
        if mapped is not None:
            ip = mapped
        if ip.is_loopback or ip.is_unspecified:
            return "loopback"
        if ip.is_link_local:
            return "linklocal"
        return "local" if any(ip in net for net in LAN_NETWORKS if net.version == ip.version) else "public"
    if NUMERIC_HOST_RE.fullmatch(host):
        return "public"            # 2130706433, 0x7f.1: inet_aton forms, not names
    if host == "localhost" or host.endswith(".localhost"):
        return "loopback"
    if "." not in host or host.endswith(LOCAL_SUFFIXES):
        return "local"
    return "public"


def check_camera(rec, brands, logins):
    """A camera from a share, or about to go into one, in canonical form.
    Raises Invalid. With logins=False every login is removed."""
    if not isinstance(rec, dict):
        bad()
    name = clean_name(text_field(rec, "name", 512))
    brand = rec.get("brand")
    if not isinstance(brand, str) or brand not in brands:
        bad()
    variant = rec.get("variant", 0)
    if isinstance(variant, bool) or not isinstance(variant, int) or not 0 <= variant < max(brands[brand], 1):
        bad()
    enabled = rec.get("enabled", True)
    if not isinstance(enabled, bool):
        bad()
    user = text_field(rec, "user", 128)
    password = text_field(rec, "password", 256)
    check_login(user, password)
    if brand == "custom":
        host = ""                       # a custom camera's host field is ignored
        url = text_field(rec, "url", 2048)
        scheme, userinfo, hostport, rest = split_url(url)
        if userinfo is not None and user == "" and password == "":
            name_part, _, pass_part = userinfo.partition(":")
            try:
                user, password = unquote(name_part, errors="strict"), unquote(pass_part, errors="strict")
            except UnicodeDecodeError:
                bad()
            utf8_ok(user)
            utf8_ok(password)
            check_login(user, password)
        url = scheme + "://" + hostport + rest      # never keeps userinfo
        if not logins:
            url = strip_query_credentials(url)
    else:
        url = ""                        # a preset's url field is ignored
        host = text_field(rec, "host", 255)
        check_host(host)
    if not logins:
        user = password = ""
    out = {"name": name, "brand": brand, "host": host, "url": url, "user": user, "password": password,
           "variant": variant, "enabled": enabled}
    host_of(out)       # a camera must have an address that classifies
    return out


def bound_settings(value):
    if value is None:
        return None
    if not isinstance(value, dict):
        bad()

    def depth(node):
        if isinstance(node, dict):
            return 1 + max([depth(v) for v in node.values()] or [0])
        if isinstance(node, list):
            return 1 + max([depth(v) for v in node] or [0])
        return 0

    try:
        size = len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    except (UnicodeEncodeError, ValueError, RecursionError):
        bad()
    if size > MAX_SETTINGS or depth(value) > MAX_SETTINGS_DEPTH:
        bad()
    return value


def no_constants(name):
    raise ValueError(name)       # NaN, Infinity, -Infinity


def parse_json(data):
    try:
        return json.loads(data, parse_constant=no_constants)
    except (ValueError, RecursionError):
        bad()


def get_brands(req):
    brands = req.get("brands")
    if not isinstance(brands, dict) or not 1 <= len(brands) <= 64:
        raise Invalid("bad_request")
    for key, count in brands.items():
        if not isinstance(key, str) or isinstance(count, bool) or not isinstance(count, int) or not 0 <= count <= 64:
            raise Invalid("bad_request")
    return brands


def get_passphrase(req, minimum):
    value = req.get("passphrase")
    if not isinstance(value, str) or len(value) > 1024:
        raise Invalid("bad_request")
    try:
        value = unicodedata.normalize("NFC", value)
        raw = value.encode("utf-8")
    except UnicodeEncodeError:
        raise Invalid("bad_request")
    if len(value) < minimum:
        raise Invalid("weak_passphrase")
    return raw


# --- sources and destinations -----------------------------------------------------
def absolute(path):
    if not isinstance(path, str) or path == "" or len(path) > 4096 or "\x00" in path:
        raise Invalid("invalid_path")
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        raise Invalid("invalid_path")
    return path


def read_limited(fd, limit):
    chunks, total = [], 0
    while total <= limit:
        chunk = os.read(fd, min(65536, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def read_file(path):
    path = absolute(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOCTTY)
    except FileNotFoundError:
        raise Invalid("not_found")
    except OSError:
        raise Invalid("cannot_read")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Invalid("not_a_file")
        if info.st_size > MAX_SHARE:
            raise Invalid("too_large")
        data = read_limited(fd, MAX_SHARE)
    except OSError:
        raise Invalid("cannot_read")
    finally:
        os.close(fd)
    if len(data) > MAX_SHARE:
        raise Invalid("too_large")
    return data


def read_clipboard():
    try:
        proc = subprocess.Popen(["wl-paste", "--no-newline", "--type", "text"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True,
                                start_new_session=True)
    except OSError:
        raise Invalid("clipboard_unavailable")

    def kill():
        try:
            os.killpg(proc.pid, 9)
        except OSError:
            pass

    timer = threading.Timer(5, kill)
    timer.start()
    try:
        data = proc.stdout.read(MAX_SHARE + 1)
    finally:
        timer.cancel()
        kill()
        proc.stdout.close()
        proc.wait()
    if len(data) > MAX_SHARE:
        raise Invalid("too_large")
    return data


def write_clipboard(text, sensitive):
    cmd = ["wl-copy"] + (["--sensitive"] if sensitive else [])
    try:
        # Output goes to /dev/null: wl-copy leaves a server behind that would
        # otherwise keep this helper's stdout pipe open.
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                close_fds=True, start_new_session=True)
    except OSError:
        raise Invalid("clipboard_unavailable")
    try:
        proc.stdin.write(text.encode("utf-8"))
        proc.stdin.close()
        code = proc.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        proc.kill()
        raise Invalid("clipboard_unavailable")
    if code != 0:
        raise Invalid("clipboard_unavailable")


def write_new_file(path, text):
    """Creates path (never overwrites), mode 600. Returns the path used."""
    path = absolute(path)
    folder, base = os.path.split(path)
    if base in ("", ".", ".."):
        raise Invalid("invalid_path")
    if not os.path.isdir(folder):
        folder = os.path.expanduser("~")
        path = os.path.join(folder, base)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(path, flags, 0o600)
    except FileExistsError:
        raise Invalid("exists")
    except OSError:
        raise Invalid("cannot_write")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(text.encode("ascii"))
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise Invalid("cannot_write")
    return path


# --- armor ------------------------------------------------------------------------
def armor(blob):
    body = base64.b64encode(blob).decode("ascii")
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return BEGIN + "\n" + "\n".join(lines) + "\n" + END + "\n"


def unarmor(text):
    start = text.find(BEGIN)
    if start < 0:
        raise Invalid("not_a_share")
    stop = text.find(END, start + len(BEGIN))
    if stop < 0:
        raise Invalid("not_a_share")
    body = "".join(text[start + len(BEGIN):stop].split())
    try:
        return base64.b64decode(body, validate=True)
    except (binascii.Error, ValueError):
        raise Invalid("not_a_share")


# --- operations -------------------------------------------------------------------
def op_passphrase(req):
    groups = ["".join(secrets.choice(ALPHABET) for _ in range(4)) for _ in range(5)]
    return {"passphrase": "-".join(groups)}


def op_copy(req):
    text = req.get("text")
    if req.get("sensitive") is not True or not isinstance(text, str) or not 1 <= len(text) <= 4096:
        raise Invalid("bad_request")
    write_clipboard(text, True)
    return {}


def op_find(req):
    home = os.path.expanduser("~")
    found = []
    for folder in (os.path.join(home, "Downloads"), home):
        try:
            with os.scandir(folder) as entries:
                for entry in entries:
                    if not entry.name.endswith(".omacam") or len(entry.name) > 255:
                        continue
                    try:
                        if not entry.is_file(follow_symlinks=False):
                            continue
                        info = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if info.st_size <= MAX_SHARE:
                        found.append({"path": os.path.join(folder, entry.name), "name": entry.name, "mtime": int(info.st_mtime)})
        except OSError:
            continue
    found.sort(key=lambda item: item["mtime"], reverse=True)
    return {"files": found[:3]}


def op_export(req):
    brands = get_brands(req)
    raw_pass = get_passphrase(req, MIN_PASSPHRASE)
    cameras_in = req.get("cameras")
    include = req.get("includeLogins")
    if not isinstance(cameras_in, list) or not isinstance(include, bool):
        raise Invalid("bad_request")
    if not 1 <= len(cameras_in) <= MAX_CAMERAS:
        raise Invalid("no_cameras" if not cameras_in else "too_many")
    settings = bound_settings(req.get("settings"))
    app = req.get("app")
    if not isinstance(app, str) or not re.fullmatch(r"[0-9A-Za-z.+-]{1,32}", app):
        app = "unknown"
    dest = req.get("dest")
    if not isinstance(dest, dict):
        raise Invalid("bad_request")
    cameras = []
    for index, rec in enumerate(cameras_in):
        try:
            cameras.append(check_camera(rec, brands, include))
        except Invalid:
            raise Invalid("invalid_camera", index=index)
    body = {
        "format": "omacam-share",
        "version": 1,
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "app": app,
        "includesLogins": include,
        "cameras": cameras,
        "settings": settings,
    }
    plain = json.dumps(body, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    plain += b" " * (-len(plain) % PAD)
    salt, nonce = os.urandom(16), os.urandom(12)
    header = MAGIC + bytes([1, EXPORT_LOG2N, 8, 1]) + salt + nonce
    blob = header + gcm_encrypt(derive_key(raw_pass, salt, EXPORT_LOG2N), nonce, header, plain)
    text = armor(blob)
    if len(text) > MAX_SHARE:
        raise Invalid("too_large")
    out = {"count": len(cameras)}
    if "file" in dest:
        out["path"] = write_new_file(dest["file"], text)
    elif dest.get("clipboard") is True:
        write_clipboard(text, False)
    else:
        raise Invalid("bad_request")
    return out


def op_open(req):
    brands = get_brands(req)
    raw_pass = get_passphrase(req, 1)
    source = req.get("source")
    if not isinstance(source, dict):
        raise Invalid("bad_request")
    if "file" in source:
        data = read_file(source["file"])
    elif source.get("clipboard") is True:
        data = read_clipboard()
    else:
        raise Invalid("bad_request")
    blob = unarmor(data.decode("utf-8", errors="replace"))
    if len(blob) < HEADER_LEN + TAG_LEN or blob[:7] != MAGIC[:7]:
        raise Invalid("not_a_share")
    header = blob[:HEADER_LEN]
    if header[7] != 1 or header[8] != 1:
        raise Invalid("unsupported")
    log2n, r, p = header[9], header[10], header[11]
    if log2n not in IMPORT_LOG2N or r != 8 or p != 1:
        raise Invalid("unsupported")
    salt, nonce = header[12:28], header[28:40]
    plain = gcm_decrypt(derive_key(raw_pass, salt, log2n), nonce, header, blob[HEADER_LEN:])
    try:
        doc = parse_json(plain.decode("utf-8"))
    except UnicodeDecodeError:
        bad()
    if not isinstance(doc, dict) or doc.get("format") != "omacam-share":
        bad()
    version = doc.get("version")
    if isinstance(version, bool) or not isinstance(version, int):
        bad()
    if version > 1:
        raise Invalid("unsupported")
    if version < 1:
        bad()
    created = doc.get("created")
    if not isinstance(created, str) or not ISO_RE.fullmatch(created):
        bad()
    try:
        datetime.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        bad()
    logins = doc.get("includesLogins")
    cameras_in = doc.get("cameras")
    if not isinstance(logins, bool) or not isinstance(cameras_in, list) or not 1 <= len(cameras_in) <= MAX_CAMERAS:
        bad()
    settings = bound_settings(doc.get("settings"))
    cameras = []
    for rec in cameras_in:
        cam = check_camera(rec, brands, logins)
        cam["scope"] = scope_of(cam)
        cameras.append(cam)
    return {"created": created, "includesLogins": logins, "cameras": cameras, "settings": settings}


OPS = {"passphrase": op_passphrase, "find": op_find, "copy": op_copy, "export": op_export, "open": op_open}


def main():
    line = sys.stdin.buffer.readline(MAX_REQUEST + 1)
    if len(line) > MAX_REQUEST:
        raise Invalid("too_large")
    try:
        req = parse_json(line.decode("utf-8"))
    except (UnicodeDecodeError, Invalid):
        raise Invalid("bad_request")
    if not isinstance(req, dict) or req.get("op") not in OPS:
        raise Invalid("bad_request")
    result = OPS[req["op"]](req)
    result["ok"] = True
    return result


def answer(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=True) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        answer(main())
    except Invalid as e:
        answer(dict(e.extra, ok=False, error=e.code))
    except RecursionError:
        answer({"ok": False, "error": "invalid_content"})
    except BaseException:
        try:
            answer({"ok": False, "error": "internal"})
        except BaseException:
            pass
        os._exit(1)
