import json
import unittest

from reference_bridge import (
    BridgeMemory,
    BridgeTurn,
    PROTOCOL,
    bridge_frames,
    build_persona_prompt,
    plan_turn,
    render_bench,
    render_jsonl,
)


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

    def test_persona_prompt_uses_memory_without_clone_markers(self):
        memory = BridgeMemory(preferred_name="Rob", recent_topics=("voice",), physical_context=("room is dark",))
        prompt = build_persona_prompt(memory)
        self.assertIn("Stackchan Spark", prompt)
        self.assertIn("preferred_name: Rob", prompt)
        self.assertIn("recent_topics: voice", prompt)
        self.assertIn("physical_context: room is dark", prompt)
        self.assertNotIn("Johnny", prompt)
        self.assertNotIn("Short Circuit", prompt)
        self.assertNotIn("Number 5", prompt)

    def test_memory_extracts_name_topics_and_physical_context(self):
        memory = BridgeMemory().remember_user_text("My name is Rob and I picked you up to check the servo voice.")
        self.assertEqual("Rob", memory.preferred_name)
        self.assertIn("servos", memory.recent_topics)
        self.assertIn("voice", memory.recent_topics)
        self.assertIn("user picked Stackchan up", memory.physical_context)
        self.assertEqual(1, memory.turns_seen)

    def test_plan_turn_couples_memory_to_response(self):
        memory = BridgeMemory(preferred_name="Rob")
        turn = plan_turn("I picked you up", memory, seq=12)
        self.assertEqual(12, turn.seq)
        self.assertEqual("happy", turn.intent)
        self.assertIn("Hello Rob.", turn.text)
        self.assertIn("You picked me up", turn.text)


if __name__ == "__main__":
    unittest.main()
