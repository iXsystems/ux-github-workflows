#!/usr/bin/env python3
"""tnctl: drive a TrueNAS appliance that runs under a local qemu.

Standard library only, so it runs on any runner with a python3: the
installer's and the middleware's JSON-RPC 2.0 over a websocket, and qemu's
QMP over a unix socket. appliance.sh calls it; the image build does too.

  tnctl.py install URL [--disk NAME]
      Drive the installer ISO at ws://.../ws: install to the first disk it
      lists (or NAME), with the admin left for setup-admin. Returns when the
      install is done; the caller powers the VM off and boots the disk.

  tnctl.py setup-admin URL USER PASSWORD [--timeout S]
      Once the installed system is up: create its admin. Only a system
      with no admin yet allows this, unauthenticated.

  tnctl.py wait URL USER PASSWORD [--timeout S] [--since EPOCH]
      Until USER can log in and system.ready is true; prints the seconds.
      With --since, a boot's: logs each milestone on the way in seconds
      since EPOCH (qemu's start): the port accepting connections, the API's
      websocket answering, the login accepted, system.ready, and when the
      guest's kernel started (from its uptime).

  tnctl.py tail-ts FILE OUT [--since EPOCH] [--pid PID]
      Copy the lines FILE grows by into OUT, each prefixed with the seconds
      since EPOCH, until PID exits: the serial console, timed.

  tnctl.py rotate URL USER PASSWORD NEW
  tnctl.py enable-ssh URL USER PASSWORD [--pubkey KEY]
      ssh for USER with its password, or with KEY and sudo without one.
  tnctl.py call URL USER PASSWORD METHOD [JSON-PARAMS...]
      One call as USER, its result as JSON on stdout.
  tnctl.py wait-verify URL USER PASSWORD [--timeout S]
      Until the first boot's truenas_verify baseline log exists: middleware
      writes it once, after system.ready, and anything changed before it
      would be reported as tampering from then on.

  tnctl.py qmp SOCKET COMMAND [JSON-ARGS]
  tnctl.py hmp SOCKET "savevm fresh-install"
      One QMP command, or a human monitor command through QMP.

URL is ws://host:port; the path (/ws for the installer, /api/current for
the middleware) is added here.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import struct
import sys
import time
import urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Closed(Exception):
    """The websocket is gone."""


class WebSocket:
    """A websocket client, enough for JSON-RPC: text messages, ping and
    pong, close. ws:// only: the appliance is reached through qemu's port
    forward on this machine."""

    def __init__(self, url, timeout=30):
        u = urllib.parse.urlsplit(url)
        if u.scheme != "ws":
            raise ValueError(f"{url}: only ws:// is supported")
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        path = (u.path or "/") + (f"?{u.query}" if u.query else "")
        self.sock.sendall(
            f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{u.port or 80}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise Closed(f"{url}: closed during the handshake")
            head += chunk
        head, self.buf = head.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        status = lines[0].split(" ", 2)
        if len(status) < 2 or status[1] != "101":
            raise Closed(f"{url}: {lines[0]}")
        headers = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}
        want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if headers.get("sec-websocket-accept") != want:
            raise Closed(f"{url}: bad Sec-WebSocket-Accept")

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send(self, opcode, payload):
        head = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 1 << 16:
            head += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, text):
        self._send(0x1, text.encode())

    def recv(self, timeout=None):
        self.sock.settimeout(timeout)
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise Closed("closed by the server")
            if opcode == 0x9:
                self._send(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if b0 & 0x80:
                return message.decode()

    def close(self):
        try:
            self._send(0x8, b"")
        except OSError:
            pass
        self.sock.close()


class RPCError(Exception):
    def __init__(self, method, error):
        super().__init__(f"{method}: {json.dumps(error)}")
        self.error = error


class RPC:
    """JSON-RPC 2.0 over a websocket; notifications go to on_notify."""

    def __init__(self, url, timeout=30, on_notify=None):
        self.ws = WebSocket(url, timeout)
        self.id = 0
        self.on_notify = on_notify or (lambda method, params: None)

    def call(self, method, *params, timeout=120):
        self.id += 1
        msg = {"jsonrpc": "2.0", "method": method, "id": self.id}
        if params:
            msg["params"] = list(params)
        self.ws.send(json.dumps(msg))
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"{method}: no answer in {timeout}s")
            data = json.loads(self.ws.recv(left))
            if data.get("id") == self.id:
                if "error" in data:
                    raise RPCError(method, data["error"])
                return data.get("result")
            if "method" in data:
                self.on_notify(data["method"], data.get("params"))

    def job(self, method, *params, timeout=600):
        """A middleware job: its id, then its result once it ends."""
        jid = self.call(method, *params)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            jobs = self.call("core.get_jobs", [["id", "=", jid]])
            if jobs and jobs[0]["state"] == "SUCCESS":
                return jobs[0]["result"]
            if jobs and jobs[0]["state"] in ("FAILED", "ABORTED"):
                raise RPCError(method, jobs[0].get("error"))
            time.sleep(1)
        raise TimeoutError(f"{method}: job {jid} not done in {timeout}s")

    def close(self):
        self.ws.close()


def log(*a):
    print("tnctl:", *a, file=sys.stderr, flush=True)


def api(url):
    return url.rstrip("/") + "/api/current"


def login(url, user, password, timeout=30):
    c = RPC(api(url), timeout)
    r = c.call("auth.login_ex", {"mechanism": "PASSWORD_PLAIN", "username": user, "password": password})
    if (r or {}).get("response_type") != "SUCCESS":
        c.close()
        raise RPCError("auth.login_ex", r)
    return c


def retry(what, timeout, fn, every=3):
    """fn() until it returns, for up to timeout seconds; its last error
    is the one raised."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            return fn()
        except (OSError, Closed, RPCError, TimeoutError, ValueError) as e:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"{what}: not in {timeout}s; last: {e}") from e
            time.sleep(every)


def cmd_install(a):
    def progress(method, params):
        if method == "installation_progress":
            p = (params or [{}])[0]
            try:
                pct = f"{float(p.get('progress', 0)) * 100:.0f}%"
            except (TypeError, ValueError):
                pct = "?"
            log("install", pct, p.get("message", ""))

    # nginx answers on 80 before the installer behind it does.
    c = retry("the installer", a.timeout, lambda: RPC(a.url.rstrip("/") + "/ws", 30, progress), every=5)
    try:
        if c.call("is_adopted"):
            raise SystemExit("the installer is adopted by another client already")
        disks = [d["name"] for d in c.call("list_disks") or []]
        log("installer sees disks", disks)
        disk = a.disk or (disks[0] if disks else None)
        if not disk:
            raise SystemExit("the installer sees no disk")
        c.call("adopt")
        log("installing to", disk)
        # authentication None: the admin is made after the first boot, by
        # setup-admin, as the web UI's first-run page would.
        c.call("install", {"disks": [disk], "set_pmbr": True, "authentication": None}, timeout=a.timeout)
        log("install done")
    finally:
        c.close()


def cmd_setup_admin(a):
    def setup():
        c = RPC(api(a.url), 30)
        try:
            c.call("user.setup_local_administrator", a.user, a.password, timeout=120)
        finally:
            c.close()

    retry("the middleware", a.timeout, setup, every=5)
    log("admin", a.user, "set up")


def cmd_wait(a):
    start = time.monotonic()
    t0 = a.since
    host, port = urllib.parse.urlsplit(a.url).hostname, urllib.parse.urlsplit(a.url).port or 80
    seen = set()

    def mark(what):
        if t0 is not None and what not in seen:
            seen.add(what)
            log(f"+{time.time() - t0:.1f}s {what}")

    def attempt():
        with socket.create_connection((host, port), timeout=2):
            pass
        mark(f"port {port} accepts connections")
        c = RPC(api(a.url), 30)
        try:
            mark("the API's websocket answers")
            r = c.call("auth.login_ex", {"mechanism": "PASSWORD_PLAIN", "username": a.user, "password": a.password})
            if (r or {}).get("response_type") != "SUCCESS":
                raise RPCError("auth.login_ex", r)
        except BaseException:
            c.close()
            raise
        mark("login accepted")
        return c

    c = retry("a login", a.timeout, attempt, every=1)

    def ready():
        if not c.call("system.ready"):
            raise ValueError("not ready yet")

    try:
        retry("system.ready", max(10, a.timeout - (time.monotonic() - start)), ready, every=1)
        mark("system.ready")
        if t0 is not None:
            try:
                uptime = float(c.call("system.info")["uptime_seconds"])
                log(f"+{time.time() - t0 - uptime:.1f}s the guest's kernel started (it has been up {uptime:.1f}s)")
            except (RPCError, KeyError, TypeError, ValueError) as e:
                log("no uptime from system.info:", e)
    finally:
        c.close()
    print(f"{time.monotonic() - start:.1f}")


ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\r")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def cmd_tail_ts(a):
    t0 = a.since if a.since is not None else time.time()
    while not os.path.exists(a.file):
        if a.pid and not alive(a.pid):
            return
        time.sleep(0.2)
    buf = b""
    with open(a.file, "rb") as f, open(a.out, "ab", buffering=0) as out:
        while True:
            data = f.read(65536)
            if not data:
                if a.pid and not alive(a.pid):
                    break
                time.sleep(0.2)
                continue
            buf += data
            *lines, buf = buf.split(b"\n")
            stamp = f"{time.time() - t0:7.1f} ".encode()
            for line in lines:
                line = ANSI.sub(b"", line).rstrip()
                if line:
                    out.write(stamp + line + b"\n")
        if buf.strip():
            out.write(f"{time.time() - t0:7.1f} ".encode() + ANSI.sub(b"", buf).rstrip() + b"\n")


def cmd_wait_verify(a):
    c = login(a.url, a.user, a.password)
    try:
        path = f"/var/log/audit/truenas_verify.{c.call('system.version')}.log"
        retry(path, a.timeout, lambda: c.call("filesystem.stat", path))
        log("truenas_verify baseline written:", path)
    finally:
        c.close()


def cmd_rotate(a):
    c = login(a.url, a.user, a.password)
    try:
        users = c.call("user.query", [["username", "=", a.user]])
        if not users:
            raise SystemExit(f"no user {a.user}")
        c.call("user.update", users[0]["id"], {"password": a.new})
    finally:
        c.close()


def cmd_enable_ssh(a):
    c = login(a.url, a.user, a.password)
    try:
        uid = c.call("user.query", [["username", "=", a.user]], {"get": True})["id"]
        if a.pubkey:
            # A key, and sudo without a password, for a script to log in
            # with and read what only root can.
            c.call("user.update", uid, {"sshpubkey": a.pubkey, "sudo_commands_nopasswd": ["ALL"]})
        else:
            c.call("user.update", uid, {"ssh_password_enabled": True})
        c.call("service.update", "ssh", {"enable": True})
        c.job("service.control", "START", "ssh", {"silent": False})
    finally:
        c.close()


def cmd_call(a):
    c = login(a.url, a.user, a.password)
    try:
        print(json.dumps(c.call(a.method, *[json.loads(p) for p in a.params], timeout=a.timeout), indent=2))
    finally:
        c.close()


def qmp(path, command, arguments=None, timeout=600):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(path)
    f = s.makefile("rwb")

    def read():
        while True:
            line = f.readline()
            if not line:
                raise Closed("qmp closed")
            msg = json.loads(line)
            if "event" not in msg:
                return msg

    def send(cmd, args=None):
        f.write(json.dumps({"execute": cmd, **({"arguments": args} if args else {})}).encode() + b"\n")
        f.flush()
        r = read()
        if "error" in r:
            raise RPCError(cmd, r["error"])
        return r.get("return")

    try:
        read()  # the greeting
        send("qmp_capabilities")
        return send(command, arguments)
    finally:
        s.close()


def cmd_qmp(a):
    r = qmp(a.socket, a.command, json.loads(a.args) if a.args else None)
    print(json.dumps(r, indent=2))


def cmd_hmp(a):
    out = qmp(a.socket, "human-monitor-command", {"command-line": a.line})
    # HMP reports its own errors as text, savevm and loadvm included.
    if out and out.strip():
        print(out.strip())
        if "rror" in out:
            raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def p(name, fn, *args, timeout=600):
        sp = sub.add_parser(name)
        for arg in args:
            sp.add_argument(arg)
        sp.add_argument("--timeout", type=int, default=timeout)
        sp.set_defaults(fn=fn)
        return sp

    p("install", cmd_install, "url", timeout=3600).add_argument("--disk", default="")
    p("setup-admin", cmd_setup_admin, "url", "user", "password")
    p("wait", cmd_wait, "url", "user", "password").add_argument("--since", type=float)
    tail = p("tail-ts", cmd_tail_ts, "file", "out")
    tail.add_argument("--since", type=float)
    tail.add_argument("--pid", type=int)
    p("wait-verify", cmd_wait_verify, "url", "user", "password", timeout=300)
    p("rotate", cmd_rotate, "url", "user", "password", "new")
    p("enable-ssh", cmd_enable_ssh, "url", "user", "password").add_argument("--pubkey", default="")
    p("call", cmd_call, "url", "user", "password", "method", timeout=120).add_argument("params", nargs="*")
    p("qmp", cmd_qmp, "socket", "command").add_argument("args", nargs="?")
    p("hmp", cmd_hmp, "socket", "line")
    a = ap.parse_args()
    try:
        a.fn(a)
    except (TimeoutError, RPCError, Closed, OSError) as e:
        raise SystemExit(f"tnctl {a.cmd}: {e}")


if __name__ == "__main__":
    main()
