import base64
import hashlib
import json
import socket
import threading
import unittest

from android_companion_probe import build_report, parse_bridge_url

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class AndroidCompanionProbeTest(unittest.TestCase):
    def test_parse_requires_ws_bridge_url(self):
        url = parse_bridge_url("ws://192.168.1.42:8765/bridge")

        self.assertEqual("192.168.1.42", url.host)
        self.assertEqual(8765, url.port)
        self.assertEqual("/bridge", url.path)

    def test_probe_accepts_android_endpoint_hello(self):
        frame = {
            "type": "endpoint_hello",
            "protocol": "stackchan.bridge.v1",
            "endpoint_id": "android-companion-test",
            "endpoint_name": "Stackchan Android Companion",
            "endpoint_kind": "android",
            "app_version": "0.1.0",
            "priority": 60,
            "supports_binary_audio": True,
            "capabilities": ["settings", "diagnostics", "brain_owner"],
        }
        with endpoint_hello_server(frame) as url:
            report = build_report(url, timeout=2.0, require_android=True)

        self.assertEqual("pass", report["status"])
        self.assertEqual("android-companion-test", report["endpoint_hello"]["endpoint_id"])
        self.assertEqual([], report["issues"])

    def test_probe_rejects_non_android_endpoint_by_default(self):
        frame = {
            "type": "endpoint_hello",
            "protocol": "stackchan.bridge.v1",
            "endpoint_id": "pc-companion-test",
            "endpoint_kind": "pc",
            "capabilities": ["settings", "diagnostics"],
        }
        with endpoint_hello_server(frame) as url:
            report = build_report(url, timeout=2.0, require_android=True)

        self.assertEqual("fail", report["status"])
        self.assertIn("expected endpoint_kind android", report["issues"][0])


class endpoint_hello_server:
    def __init__(self, frame):
        self.frame = frame
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.port = 0

    def __enter__(self):
        self.thread.start()
        if not self.ready.wait(timeout=5):
            raise RuntimeError("test endpoint_hello server did not start")
        return f"ws://127.0.0.1:{self.port}/bridge"

    def __exit__(self, exc_type, exc, tb):
        self.thread.join(timeout=5)

    def _run(self):
        with socket.create_server(("127.0.0.1", 0), reuse_port=False) as server:
            self.port = int(server.getsockname()[1])
            self.ready.set()
            conn, _ = server.accept()
            with conn:
                headers = self._read_handshake(conn)
                accept = websocket_accept(headers["sec-websocket-key"])
                conn.sendall(
                    (
                        "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n"
                        "\r\n"
                    ).encode("ascii")
                )
                conn.sendall(encode_server_text(json.dumps(self.frame).encode("utf-8")))

    @staticmethod
    def _read_handshake(conn):
        data = bytearray()
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                raise RuntimeError("client closed before handshake")
            data.extend(chunk)
        headers = {}
        for line in data.decode("iso-8859-1").split("\r\n")[1:]:
            if not line:
                break
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        if "sec-websocket-key" not in headers:
            raise RuntimeError("client handshake missing Sec-WebSocket-Key")
        return headers


def websocket_accept(key):
    digest = hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def encode_server_text(payload):
    first = 0x80 | 0x1
    if len(payload) < 126:
        return bytes([first, len(payload)]) + payload
    if len(payload) <= 65535:
        return bytes([first, 126]) + len(payload).to_bytes(2, "big") + payload
    raise ValueError("test payload too large")


if __name__ == "__main__":
    unittest.main()
