import io
import json
import os
import unittest
from unittest.mock import patch

import ollama_stackchan_runner as runner


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class OllamaStackchanRunnerTests(unittest.TestCase):
    def test_api_uses_warm_json_generation_with_bounded_output(self):
        response = {
            "response": json.dumps(
                {
                    "spoken_text": "Systems look healthy.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.1},
                    "memory_write": {},
                    "memory_forget": [],
                }
            )
        }
        with patch("ollama_stackchan_runner.urllib.request.urlopen", return_value=FakeResponse(response)) as urlopen:
            result = runner.run_api("prompt", "gemma4:test")

        request = urlopen.call_args.args[0]
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual("gemma4:test", payload["model"])
        self.assertFalse(payload["stream"])
        self.assertEqual("json", payload["format"])
        self.assertFalse(payload["think"])
        self.assertEqual(-1, payload["keep_alive"])
        self.assertEqual(160, payload["options"]["num_predict"])
        self.assertIn("Systems look healthy.", result)

    def test_default_transport_falls_back_to_cli_when_api_is_unavailable(self):
        normalized = {
            "spoken_text": "Fallback active.",
            "mode": "concern",
            "earcon": "none",
            "emotion": {"arousal": 0.0, "valence": 0.0},
            "memory_write": {},
            "memory_forget": [],
        }
        with (
            patch.dict(os.environ, {"STACKCHAN_OLLAMA_TRANSPORT": "api-with-cli-fallback"}, clear=False),
            patch("ollama_stackchan_runner.run_api", side_effect=OSError("offline")),
            patch("ollama_stackchan_runner.run_cli", return_value=json.dumps(normalized)) as run_cli,
            patch("sys.stdin", io.StringIO("prompt")),
            patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            exit_code = runner.main()

        self.assertEqual(0, exit_code)
        self.assertEqual("Fallback active.", json.loads(stdout.getvalue())["spoken_text"])
        run_cli.assert_called_once()


if __name__ == "__main__":
    unittest.main()
