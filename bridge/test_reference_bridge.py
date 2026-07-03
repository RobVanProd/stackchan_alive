import json
import tempfile
import unittest
from pathlib import Path

from reference_bridge import (
    BridgeMemory,
    BridgeTurn,
    PROTOCOL,
    bridge_frames,
    build_persona_prompt,
    load_bridge_memory,
    plan_turn,
    render_bench,
    render_jsonl,
    reset_bridge_memory,
    save_bridge_memory,
    turn_from_character_response,
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

    def test_memory_store_round_trips_minimal_fields(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "memory.json"
            memory = BridgeMemory(preferred_name="Rob", recent_topics=("voice",), physical_context=("room is dark",), turns_seen=3)
            save_bridge_memory(path, memory)

            loaded = load_bridge_memory(path)
            self.assertEqual(memory, loaded)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(["voice"], data["recent_topics"])
            self.assertNotIn("audio", data)
            self.assertNotIn("transcript", data)

    def test_memory_store_reset_deletes_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "memory.json"
            save_bridge_memory(path, BridgeMemory(preferred_name="Rob"))
            reset = reset_bridge_memory(path)

            self.assertEqual(BridgeMemory(), reset)
            self.assertFalse(path.exists())

    def test_character_response_feeds_bridge_turn_and_memory(self):
        raw = json.dumps(
            {
                "spoken_text": "Looking at you now. Signal locked.",
                "mode": "attend",
                "earcon": "confirm",
                "emotion": {"arousal": 0.3, "valence": 0.2},
                "memory_write": {
                    "user.name": "Rob",
                    "project.note": "voice tuning",
                    "robot.physical_context": "room is dark",
                },
                "memory_forget": [],
            }
        )

        turn, memory, result = turn_from_character_response(raw, BridgeMemory(), session="model", seq=33)

        self.assertTrue(result.ok, result.issues)
        self.assertEqual("model", turn.session)
        self.assertEqual(33, turn.seq)
        self.assertEqual("attend", turn.intent)
        self.assertEqual("Looking at you now. Signal locked.", turn.text)
        self.assertEqual(0.8, turn.arousal)
        self.assertEqual(0.2, turn.valence)
        self.assertEqual("Rob", memory.preferred_name)
        self.assertIn("voice tuning", memory.recent_topics)
        self.assertIn("room is dark", memory.physical_context)

    def test_character_response_forget_wins_over_memory(self):
        raw = json.dumps(
            {
                "spoken_text": "Deleted. It is gone.",
                "mode": "concern",
                "earcon": "confirm",
                "emotion": {"arousal": 0.0, "valence": -0.1},
                "memory_write": {"project.note": "bracket color"},
                "memory_forget": ["user.name", "project."],
            }
        )
        starting = BridgeMemory(preferred_name="Rob", recent_topics=("voice",), physical_context=("room is dark",))

        turn, memory, result = turn_from_character_response(raw, starting, seq=44)

        self.assertTrue(result.ok, result.issues)
        self.assertEqual("concern", turn.intent)
        self.assertEqual("", memory.preferred_name)
        self.assertEqual((), memory.recent_topics)
        self.assertEqual(("room is dark",), memory.physical_context)

    def test_malformed_character_response_still_renders_fallback(self):
        turn, memory, result = turn_from_character_response("{not json", BridgeMemory(preferred_name="Rob"), seq=45)

        self.assertFalse(result.ok)
        self.assertIn("malformed_json", result.issues)
        self.assertEqual("concern", turn.intent)
        self.assertIn("lost my train", turn.text)
        self.assertEqual("Rob", memory.preferred_name)


if __name__ == "__main__":
    unittest.main()
