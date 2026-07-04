import json
import socket
import threading
import time
import unittest

from android_udp_beacon_probe import build_report, validate_beacon


class AndroidUdpBeaconProbeTest(unittest.TestCase):
    def test_validate_accepts_android_beacon(self):
        issues = validate_beacon(sample_beacon(), True, 8765, "android-companion-test")

        self.assertEqual([], issues)

    def test_validate_rejects_wrong_kind_and_port(self):
        beacon = sample_beacon(endpoint_kind="pc", port=9000)

        issues = validate_beacon(beacon, True, 8765, "")

        self.assertTrue(any("endpoint_kind android" in issue for issue in issues))
        self.assertTrue(any("expected bridge port 8765" in issue for issue in issues))

    def test_probe_listens_for_one_beacon(self):
        port = free_udp_port()
        sender = threading.Thread(target=send_beacon_after_delay, args=(port, sample_beacon(), 0.05), daemon=True)
        sender.start()

        report = build_report(
            bind_host="127.0.0.1",
            port=port,
            timeout=2.0,
            require_android=True,
            expected_bridge_port=8765,
            expected_endpoint_id="android-companion-test",
        )

        sender.join(timeout=2)
        self.assertEqual("pass", report["status"])
        self.assertEqual("android-companion-test", report["beacon"]["endpoint_id"])
        self.assertEqual("127.0.0.1", report["source_host"])


def sample_beacon(endpoint_kind="android", port=8765):
    return {
        "type": "stackchan_bridge_beacon",
        "protocol": "stackchan.bridge.v1",
        "endpoint_id": "android-companion-test",
        "endpoint_name": "Stackchan Android Companion",
        "endpoint_kind": endpoint_kind,
        "port": port,
        "capabilities": ["settings", "diagnostics", "brain_owner"],
    }


def free_udp_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def send_beacon_after_delay(port, beacon, delay):
    time.sleep(delay)
    payload = json.dumps(beacon).encode("utf-8")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(payload, ("127.0.0.1", port))


if __name__ == "__main__":
    unittest.main()
