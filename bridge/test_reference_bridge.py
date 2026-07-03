import json
import unittest

from reference_bridge import BridgeTurn, PROTOCOL, bridge_frames, render_bench, render_jsonl


class ReferenceBridgeTests(unittest.TestCase):
    def test_frames_follow_firmware_protocol_order(self):
        frames = list(bridge_frames(BridgeTurn(session="unit", seq=42)))
        self.assertEqual("hello", frames[0]["type"])
        self.assertEqual(PROTOCOL, frames[0]["protocol"])
        self.assertEqual("thinking", frames[2]["type"])
        self.assertEqual("response_start", frames[3]["type"])
        self.assertEqual("audio", frames[4]["type"])
        self.assertEqual("response_end", frames[-1]["type"])
        self.assertTrue(any(frame["type"] == "audio" and frame["final"] for frame in frames))

    def test_jsonl_is_parseable(self):
        text = render_jsonl(bridge_frames(BridgeTurn(seq=5, text="short line")))
        decoded = [json.loads(line) for line in text.splitlines()]
        self.assertEqual("response_start", decoded[3]["type"])
        self.assertEqual("short line", decoded[3]["text"])

    def test_bench_render_matches_serial_bridge_commands(self):
        text = render_bench(bridge_frames(BridgeTurn(session="bench", seq=7)))
        self.assertIn("bridge hello bench", text)
        self.assertIn("bridge thinking 7", text)
        self.assertIn("bridge response happy 7 Hello. I am Stackchan, and I am awake.", text)
        self.assertIn("bridge audio 0.72 ee 80", text)
        self.assertIn("bridge audio 0.12 neutral 60 final", text)
        self.assertTrue(text.endswith("status"))


if __name__ == "__main__":
    unittest.main()
