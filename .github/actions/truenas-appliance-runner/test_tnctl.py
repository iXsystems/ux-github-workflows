"""tnctl against a fake installer, middleware and QMP: python3
test_tnctl.py. Standard library only, like tnctl."""

import base64
import hashlib
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(__file__))
import tnctl  # noqa: E402


class FakeServer:
    """A websocket server answering JSON-RPC from handlers[method]."""

    def __init__(self, handlers):
        self.handlers = handlers
        self.calls = []
        self.paths = []
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen()
        self.url = f"ws://127.0.0.1:{self.sock.getsockname()[1]}"
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        f = conn.makefile("rb")
        request = f.readline().decode()
        self.paths.append(request.split()[1])
        key = ""
        while (line := f.readline().decode().strip()):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1((key + tnctl.GUID).encode()).digest()).decode()
        conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     f"Sec-WebSocket-Accept: {accept}\r\n\r\n".encode())

        def send(obj, opcode=1):
            payload = json.dumps(obj).encode() if opcode == 1 else obj
            n = len(payload)
            head = bytes([0x80 | opcode])
            head += bytes([n]) if n < 126 else (bytes([126]) + struct.pack("!H", n) if n < 1 << 16 else bytes([127]) + struct.pack("!Q", n))
            conn.sendall(head + payload)

        def read():
            b0, b1 = f.read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", f.read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", f.read(8))[0]
            mask = f.read(4)
            return b0 & 0x0F, bytes(b ^ mask[i % 4] for i, b in enumerate(f.read(n)))

        try:
            while True:
                opcode, payload = read()
                if opcode == 0x8:
                    return
                if opcode != 1:
                    continue
                msg = json.loads(payload)
                self.calls.append((msg["method"], msg.get("params", [])))
                # A ping before every answer: the client must pong and go on.
                send(b"hi", opcode=0x9)
                result = self.handlers[msg["method"]](*msg.get("params", []), notify=lambda m, p: send({"jsonrpc": "2.0", "method": m, "params": p}))
                if isinstance(result, tnctl.RPCError):
                    send({"jsonrpc": "2.0", "id": msg["id"], "error": result.error})
                else:
                    send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        except (OSError, ValueError):
            return
        finally:
            conn.close()

    def close(self):
        self.sock.close()


def args(**kw):
    return SimpleNamespace(timeout=10, **kw)


class TestTnctl(unittest.TestCase):
    def test_install(self):
        notes = []

        def install(opts, notify):
            notify("installation_progress", [{"progress": 0.5, "message": "half"}])
            notes.append(opts)
            return None

        srv = FakeServer({
            "is_adopted": lambda notify: False,
            "list_disks": lambda notify: [{"name": "vda"}, {"name": "vdb"}],
            "adopt": lambda notify: None,
            "install": install,
        })
        self.addCleanup(srv.close)
        tnctl.cmd_install(args(url=srv.url, disk=""))
        self.assertEqual(srv.paths, ["/ws"])
        self.assertEqual(notes, [{"disks": ["vda"], "set_pmbr": True, "authentication": None}])

    def test_wait_until_ready(self):
        ready = iter([False, False, True])
        srv = FakeServer({
            "auth.login_ex": lambda creds, notify: {"response_type": "SUCCESS" if creds["password"] == "pw" else "AUTH_ERR"},
            "system.ready": lambda notify: next(ready),
            # Bigger than one short frame length can say, and than two.
            "system.info": lambda notify: {"blob": "x" * 70000},
        })
        self.addCleanup(srv.close)
        tnctl.cmd_wait(args(url=srv.url, user="truenas_admin", password="pw"))
        self.assertEqual([m for m, _ in srv.calls], ["auth.login_ex", "system.ready", "system.ready", "system.ready"])
        self.assertEqual(srv.paths, ["/api/current"])
        c = tnctl.login(srv.url, "truenas_admin", "pw")
        self.assertEqual(len(c.call("system.info")["blob"]), 70000)
        c.close()
        with self.assertRaises(tnctl.RPCError):
            tnctl.login(srv.url, "truenas_admin", "wrong")

    def test_errors_and_jobs(self):
        states = iter(["RUNNING", "SUCCESS"])
        srv = FakeServer({
            "auth.login_ex": lambda creds, notify: {"response_type": "SUCCESS"},
            "user.query": lambda *a, notify: {"id": 1} if len(a) > 1 else [{"id": 1}],
            "user.update": lambda *a, notify: tnctl.RPCError("user.update", {"code": 22, "message": "nope"}),
            "service.update": lambda *a, notify: None,
            "service.control": lambda *a, notify: 42,
            "core.get_jobs": lambda *a, notify: [{"id": 42, "state": next(states), "result": True}],
        })
        self.addCleanup(srv.close)
        with self.assertRaises(tnctl.RPCError):
            tnctl.cmd_rotate(args(url=srv.url, user="truenas_admin", password="pw", new="new"))
        c = tnctl.login(srv.url, "u", "p")
        self.assertTrue(c.job("service.control", "START", "ssh"))
        c.close()

    def test_qmp(self):
        path = os.path.join(tempfile.mkdtemp(), "qmp")
        srv = socket.socket(socket.AF_UNIX)
        srv.bind(path)
        srv.listen()
        seen = []

        def serve():
            # One connection per call, as tnctl makes them.
            while True:
                try:
                    conn, _ = srv.accept()
                except OSError:
                    return
                f = conn.makefile("rwb")
                f.write(b'{"QMP": {"version": {}}}\n')
                f.flush()
                for line in f:
                    msg = json.loads(line)
                    seen.append(msg)
                    f.write(b'{"event": "STOP"}\n')
                    out = {"return": {}}
                    if msg["execute"] == "human-monitor-command":
                        out = {"return": "Error: no snapshot" if "nope" in msg["arguments"]["command-line"] else ""}
                    f.write(json.dumps(out).encode() + b"\n")
                    f.flush()
                conn.close()

        threading.Thread(target=serve, daemon=True).start()
        self.addCleanup(srv.close)
        self.assertEqual(tnctl.qmp(path, "human-monitor-command", {"command-line": "savevm fresh-install"}), "")
        self.assertEqual([m["execute"] for m in seen], ["qmp_capabilities", "human-monitor-command"])
        # HMP reports its own failures as text: cmd_hmp has to turn one into
        # a non-zero exit, or revert would take a missing snapshot as done.
        tnctl.cmd_hmp(args(socket=path, line="savevm fresh-install"))
        with self.assertRaises(SystemExit) as e:
            tnctl.cmd_hmp(args(socket=path, line="loadvm nope"))
        self.assertEqual(e.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
