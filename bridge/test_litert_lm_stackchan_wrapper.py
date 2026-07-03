import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from character_harness import build_prompt
from litert_lm_stackchan_wrapper import (
    COMMAND_ENV,
    LiteRtWrapperError,
    extract_first_json_object,
    normalize_character_json,
    run_wrapper,
)


class LiteRtLmStackchanWrapperTests(unittest.TestCase):
    def test_extract_first_json_object_ignores_logs_and_braces_in_strings(self):
        text = 'log {not json}\n{"spoken_text":"Brace { safe }","mode":"happy","earcon":"happy","emotion":{"arousal":0.1,"valence":0.2},"memory_write":{},"memory_forget":[]}\ndone'

        extracted = extract_first_json_object(text)

        self.assertIn('"spoken_text"', extracted)
        self.assertIn('"Brace { safe }"', extracted)

    def test_normalize_character_json_rejects_invalid_output(self):
        with self.assertRaises(LiteRtWrapperError):
            normalize_character_json('{"spoken_text":"I am alive.","mode":"happy","earcon":"happy","emotion":{},"memory_write":{},"memory_forget":[]}')

    def test_run_wrapper_uses_configured_command_and_prints_character_json(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_litert.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "prompt = sys.stdin.read()",
                        "assert 'Stackchan' in prompt",
                        "print('LiteRT log: ready')",
                        "print(json.dumps({",
                        "  'spoken_text': 'Mobile brain path online.',",
                        "  'mode': 'think',",
                        "  'earcon': 'think',",
                        "  'emotion': {'arousal': 0.1, 'valence': 0.1},",
                        "  'memory_write': {},",
                        "  'memory_forget': []",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            prompt = build_prompt({"name": "greeting", "user": "Hello", "expect": "valid JSON"})

            result = run_wrapper(prompt, command=command, timeout_ms=5000)

        decoded = json.loads(result.response_json)
        self.assertEqual("Mobile brain path online.", decoded["spoken_text"])
        self.assertEqual("think", decoded["mode"])
        self.assertEqual("cli", result.command_source)
        self.assertGreater(result.elapsed_ms, 0)

    def test_cli_outputs_only_normalized_character_json_by_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_litert.py"
            script.write_text(
                "import json, sys\n"
                "sys.stdin.read()\n"
                "print(json.dumps({'spoken_text':'Ready.','mode':'happy','earcon':'confirm',"
                "'emotion':{'arousal':0,'valence':0.2},'memory_write':{},'memory_forget':[]}))\n",
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'

            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("litert_lm_stackchan_wrapper.py")),
                    "--command",
                    command,
                ],
                input="Stackchan prompt",
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("Ready.", json.loads(completed.stdout)["spoken_text"])

    def test_env_command_is_used_when_cli_command_is_empty(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_litert_env.py"
            script.write_text(
                "import json, sys\n"
                "sys.stdin.read()\n"
                "print(json.dumps({'spoken_text':'Env path ready.','mode':'happy','earcon':'confirm',"
                "'emotion':{'arousal':0,'valence':0.2},'memory_write':{},'memory_forget':[]}))\n",
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            with patch.dict(os.environ, {COMMAND_ENV: command}, clear=False):
                result = run_wrapper("prompt", timeout_ms=5000)

        self.assertEqual(f"env:{COMMAND_ENV}", result.command_source)
        self.assertEqual("Env path ready.", json.loads(result.response_json)["spoken_text"])


if __name__ == "__main__":
    unittest.main()
