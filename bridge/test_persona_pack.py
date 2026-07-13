import tempfile
import unittest
import shutil
import json
from pathlib import Path

from persona_pack import (
    DEFAULT_PERSONA_ID,
    PersonaPackError,
    build_persona_index,
    load_and_validate_persona_pack,
    load_persona_pack,
    normalize_persona_id,
    persona_pack_sha256,
    packaged_prompt_asset_manifest,
    repo_root,
    scaffold_persona_pack,
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

    def test_bundled_persona_index_is_deterministic_and_explicit_about_runtime(self):
        first = build_persona_index()
        second = build_persona_index()

        self.assertEqual(first, second)
        self.assertEqual("stackchan.persona-index.v1", first["schema"])
        self.assertEqual(2, first["pack_count"])
        self.assertEqual(2, first["valid_count"])
        self.assertEqual(0, first["invalid_count"])
        self.assertEqual(["glow", "spark"], [entry["id"] for entry in first["packs"]])
        for entry in first["packs"]:
            self.assertEqual(64, len(entry["sha256"]))
            self.assertFalse(Path(entry["path"]).is_absolute())
            self.assertTrue(entry["capabilities"]["bridge_load_time"])
            self.assertTrue(entry["capabilities"]["firmware_build_time"])
            self.assertTrue(entry["capabilities"]["bridge_runtime_hot_swap"])
            self.assertFalse(entry["capabilities"]["runtime_hot_swap"])

    def test_checked_in_persona_index_matches_bundled_packs(self):
        checked_in = json.loads((repo_root() / "data" / "persona_index.json").read_text(encoding="utf-8"))
        self.assertEqual(build_persona_index(), checked_in)

    def test_persona_index_preserves_invalid_pack_without_activating_it(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bad = root / "personas" / "bad"
            bad.mkdir(parents=True)
            (bad / "pack.yaml").write_text("schema: wrong\nid: bad\n", encoding="utf-8")

            index = build_persona_index(root)

        self.assertEqual(1, index["pack_count"])
        self.assertEqual(0, index["valid_count"])
        self.assertFalse(index["packs"][0]["valid"])
        self.assertFalse(index["packs"][0]["capabilities"]["bridge_load_time"])

    def test_persona_pack_required_files_cannot_escape_pack_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            pack_root = root / "personas" / "escape"
            pack_root.mkdir(parents=True)
            (root / "outside.yaml").write_text("schema: test\n", encoding="utf-8")
            (pack_root / "pack.yaml").write_text(
                "\n".join(
                    [
                        "schema: stackchan.persona-pack.v1",
                        "id: escape",
                        "files:",
                        "  character: ../../outside.yaml",
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(PersonaPackError, "escapes pack root"):
                load_persona_pack("escape", root=root)

    def test_persona_pack_digest_changes_with_pack_content(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "a.txt").write_text("one", encoding="utf-8")
            before = persona_pack_sha256(root)
            (root / "a.txt").write_text("two", encoding="utf-8")
            after = persona_pack_sha256(root)
        self.assertNotEqual(before, after)

    def test_normalize_persona_id_keeps_build_friendly_slug(self):
        self.assertEqual("my-test-bot", normalize_persona_id(" My Test Bot "))
        self.assertEqual("spark-v2", normalize_persona_id("Spark__V2"))

        with self.assertRaises(PersonaPackError):
            normalize_persona_id("!!!")

    def test_scaffold_persona_pack_copies_template_and_validates(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            temp_personas = temp_root / "personas"
            temp_data = temp_root / "data"
            temp_personas.mkdir()
            temp_data.mkdir()
            shutil.copytree(repo_root() / "personas" / "spark", temp_personas / "spark")
            shutil.copy(repo_root() / "data" / "voice_source_provenance.yaml", temp_data / "voice_source_provenance.yaml")

            pack = scaffold_persona_pack("test-bot", display_name="Stackchan Test Bot", author="Unit Test", root=temp_root)

            self.assertEqual("test-bot", pack.pack_id)
            self.assertEqual("Stackchan Test Bot", pack.display_name)
            self.assertIn("You are Stackchan Test Bot", pack.prompt_template)
            self.assertEqual("Unit Test", pack.manifest["author"])
            self.assertEqual("stackchan_test_bot", pack.voice["profile_id"])
            self.assertEqual([], validate_pack(pack))

    def test_scaffold_persona_pack_requires_non_placeholder_author(self):
        for author in (None, "", "  ", "TODO", "TBD", "Your Name", "Your Handle", "unknown", "unspecified"):
            with self.subTest(author=author):
                with self.assertRaisesRegex(PersonaPackError, "author"):
                    scaffold_persona_pack("test-bot", author=author)

    def test_packaged_prompt_asset_manifest_deduplicates_runtime_assets(self):
        pack = load_and_validate_persona_pack(DEFAULT_PERSONA_ID)
        manifest = packaged_prompt_asset_manifest(pack)

        self.assertEqual("stackchan.persona-prompt-assets.v1", manifest["schema"])
        self.assertEqual("spark", manifest["persona"])
        self.assertEqual(12, manifest["prompt_count"])
        self.assertEqual(3, manifest["asset_count"])
        sidecars = {asset["sidecar_path"] for asset in manifest["assets"]}
        self.assertIn("media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json", sidecars)
        self.assertIn("media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json", sidecars)
        self.assertIn("media/voice/sidecars/stackchan_spark_safety.speech_envelope.json", sidecars)

    def test_validator_requires_voice_provenance_for_packaged_prompts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            temp_personas = temp_root / "personas"
            temp_personas.mkdir()
            shutil.copytree(repo_root() / "personas" / "spark", temp_personas / "spark")
            pack_yaml = temp_personas / "spark" / "pack.yaml"
            pack_yaml.write_text(
                "\n".join(
                    line for line in pack_yaml.read_text(encoding="utf-8").splitlines()
                    if "voice_policy:" not in line
                )
                + "\n",
                encoding="utf-8",
            )

            pack = load_persona_pack("spark", root=temp_root)
            issues = validate_pack(pack)

        self.assertIn("voice_provenance_policy_missing", issues)

    def test_validator_checks_voice_provenance_schema_and_attestations(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            temp_personas = temp_root / "personas"
            temp_personas.mkdir()
            shutil.copytree(repo_root() / "personas" / "spark", temp_personas / "spark")
            policy = temp_root / "voice_policy.yaml"
            policy.write_text(
                "\n".join(
                    [
                        "schema: wrong.schema",
                        "forbidden_sources_attested:",
                        "  - soundboard clips",
                        "required_rollout_evidence:",
                        "  - licensed_or_owned_production_voice_source",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            pack_yaml = temp_personas / "spark" / "pack.yaml"
            pack_yaml.write_text(
                pack_yaml.read_text(encoding="utf-8").replace(
                    "../../data/voice_source_provenance.yaml",
                    "../../voice_policy.yaml",
                ),
                encoding="utf-8",
            )

            pack = load_persona_pack("spark", root=temp_root)
            issues = validate_pack(pack)

        self.assertIn("voice_provenance_schema_invalid", issues)
        self.assertIn("voice_provenance_forbidden_attestation_missing:named character or actor voice clones", issues)
        self.assertIn("voice_provenance_forbidden_attestation_missing:copyrighted movie quotes or catchphrases", issues)
        self.assertIn("voice_provenance_rollout_evidence_missing:completed_voice_source_provenance_template", issues)
        self.assertIn("voice_provenance_rollout_gate_missing", issues)

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
