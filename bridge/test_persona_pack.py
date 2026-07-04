import tempfile
import unittest
from pathlib import Path

from persona_pack import (
    DEFAULT_PERSONA_ID,
    PersonaPackError,
    load_and_validate_persona_pack,
    load_persona_pack,
    validate_pack,
)


class PersonaPackTests(unittest.TestCase):
    def test_spark_pack_loads_and_exposes_spoken_lines(self):
        pack = load_and_validate_persona_pack(DEFAULT_PERSONA_ID)

        self.assertEqual("spark", pack.pack_id)
        self.assertEqual("Stackchan Spark", pack.display_name)
        self.assertEqual("Hello. I am Stackchan, and I am awake.", pack.spoken_line("boot")["text"])
        self.assertEqual("safety", pack.spoken_line("safety")["earcon"])

    def test_spark_prompt_uses_template_slots_without_clone_markers(self):
        pack = load_and_validate_persona_pack(DEFAULT_PERSONA_ID)

        prompt = pack.render_prompt(memory_lines=("turns_seen: 2", "preferred_name: Rob"), context_markers=("case: greeting",))

        self.assertIn("You are Stackchan Spark", prompt)
        self.assertIn("Reply only as JSON", prompt)
        self.assertIn("preferred_name: Rob", prompt)
        self.assertIn("case: greeting", prompt)
        self.assertNotIn("Johnny", prompt)
        self.assertNotIn("Short Circuit", prompt)
        self.assertNotIn("Number 5", prompt)

    def test_glow_pack_loads_as_second_persona(self):
        pack = load_and_validate_persona_pack("glow")

        self.assertEqual("glow", pack.pack_id)
        self.assertEqual("Stackchan Glow", pack.display_name)
        self.assertEqual("Hello. Stackchan Glow is online. Quiet sensors ready.", pack.spoken_line("boot")["text"])
        self.assertEqual("safety", pack.spoken_line("safety")["earcon"])
        self.assertLess(pack.earcons["earcons"]["wake"]["base_hz"], 600)
        self.assertLess(pack.behavior["idle_life"]["breathing_hz"], 0.20)
        self.assertLess(pack.behavior["emotion_response"]["curiosity_arousal_delta"], 0.10)

    def test_glow_prompt_uses_template_slots_without_clone_markers(self):
        pack = load_and_validate_persona_pack("glow")

        prompt = pack.render_prompt(memory_lines=("turns_seen: 3", "project.topic: quiet mode"), context_markers=("case: soft greeting",))

        self.assertIn("You are Stackchan Glow", prompt)
        self.assertIn("Reply only as JSON", prompt)
        self.assertIn("project.topic: quiet mode", prompt)
        self.assertIn("case: soft greeting", prompt)
        self.assertNotIn("Johnny", prompt)
        self.assertNotIn("Short Circuit", prompt)
        self.assertNotIn("Number 5", prompt)

    def test_validator_rejects_loosened_caps_and_bad_safety_line(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "loose"
            root.mkdir()
            (root / "pack.yaml").write_text(
                "\n".join(
                    [
                        "schema: stackchan.persona-pack.v1",
                        "id: loose",
                        "name: Loose",
                        "files:",
                        "  character: character.yaml",
                        "  prompt: prompt.md",
                        "  behavior: behavior.yaml",
                        "  expressions: expressions.yaml",
                        "  earcons: earcons.yaml",
                        "  voice: voice.yaml",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            (root / "prompt.md").write_text("{{character_rules}}\n{{memory}}\n{{context_markers}}\n", encoding="utf-8")
            for name in ("behavior.yaml", "expressions.yaml", "earcons.yaml", "voice.yaml"):
                (root / name).write_text("schema: test\n", encoding="utf-8")
            (root / "character.yaml").write_text(
                "\n".join(
                    [
                        "schema: stackchan.persona-character.v1",
                        "display_name: Loose",
                        "speech_style:",
                        "  max_chars: 300",
                        "  max_sentences: 4",
                        "  contractions: allowed",
                        "memory:",
                        "  allowed_prefixes:",
                        "    - user.",
                        "    - world.",
                        "  denied_terms:",
                        "    - password",
                        "prompt_rules:",
                        "  - Reply only as JSON.",
                        "spoken_lines:",
                        "  boot:",
                        "    text: Boot.",
                        "    earcon: wake",
                        "  listen:",
                        "    text: Listen.",
                        "    earcon: confirm",
                        "  think:",
                        "    text: Think.",
                        "    earcon: think",
                        "  speak:",
                        "    text: Speak.",
                        "    earcon: confirm",
                        "  sleep:",
                        "    text: Sleep.",
                        "    earcon: sleep",
                        "  safety:",
                        "    text: Safety.",
                        "    earcon: confirm",
                        "  error:",
                        "    text: Error.",
                        "    earcon: error",
                        "  happy:",
                        "    text: Happy.",
                        "    earcon: happy",
                        "  concern:",
                        "    text: Concern.",
                        "    earcon: concern",
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            pack = load_persona_pack(root)
            issues = validate_pack(pack)

        self.assertIn("max_chars_loosened", issues)
        self.assertIn("max_sentences_loosened", issues)
        self.assertIn("contractions_not_forbidden", issues)
        self.assertIn("memory_prefixes_loosened", issues)
        self.assertIn("safety_line_must_use_safety_earcon", issues)
        self.assertIn("behavior_schema_invalid", issues)
        self.assertIn("behavior_idle_life_missing:breathing_hz", issues)
        self.assertIn("behavior_circadian_missing:evening_start_hour", issues)
        self.assertIn("behavior_emotion_response_missing:curiosity_arousal_delta", issues)
        self.assertIn("expressions_section_missing:neutral", issues)
        self.assertIn("expressions_think_missing:pupil_y", issues)
        self.assertIn("voice_packaged_prompt_missing:boot", issues)
        self.assertIn("voice_packaged_prompt_missing:safety", issues)

    def test_missing_pack_raises_clear_error(self):
        with self.assertRaises(PersonaPackError):
            load_persona_pack("does-not-exist")


if __name__ == "__main__":
    unittest.main()
