import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from model_benchmark import run_benchmark, write_outputs

RUNNER_ENV = {
    "STACKCHAN_GEMMA4_E2B_GGUF_COMMAND": "",
    "STACKCHAN_GEMMA4_E2B_LITERT_COMMAND": "",
    "STACKCHAN_GEMMA4_E4B_GGUF_COMMAND": "",
    "STACKCHAN_MODEL_COMMAND": "",
}


class ModelBenchmarkTests(unittest.TestCase):
    def test_deterministic_benchmark_marks_dry_run_without_runner(self):
        with patch.dict(os.environ, RUNNER_ENV, clear=False):
            report = run_benchmark(["gemma4-e2b-gguf", "gemma4-e2b-litert-lm"], ["greeting", "picked_up"])

        self.assertEqual("stackchan.model-benchmark.v1", report["schema"])
        self.assertEqual("dry-run-no-runner-configured", report["summary"]["status"])
        self.assertEqual(4, report["summary"]["total_cases"])
        self.assertEqual(4, report["summary"]["ok_cases"])
        self.assertEqual(0, report["summary"]["configured_runner_cases"])
        self.assertEqual("dry-run", report["summary"]["profiles"]["gemma4-e2b-gguf"]["status"])
        self.assertEqual("deterministic_fallback", report["results"][0]["command_source"])

    def test_real_command_result_records_speed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_model.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.read()",
                        "print(json.dumps({",
                        "  'spoken_text': 'Signal received. I am thinking now.',",
                        "  'mode': 'think',",
                        "  'earcon': 'think',",
                        "  'emotion': {'arousal': 0.1, 'valence': 0.0},",
                        "  'memory_write': {'project.note': 'benchmark smoke'},",
                        "  'memory_forget': []",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            report = run_benchmark(["gemma4-e2b-gguf"], ["greeting"], command=command, require_runner=True)

        result = report["results"][0]
        self.assertEqual("pass", report["summary"]["status"])
        self.assertTrue(result["configured_runner"])
        self.assertEqual("cli", result["command_source"])
        self.assertGreater(result["elapsed_ms"], 0)
        self.assertGreater(result["approx_tokens_per_sec"], 0)

    def test_outputs_include_json_and_markdown_summary(self):
        with patch.dict(os.environ, RUNNER_ENV, clear=False):
            report = run_benchmark(["gemma4-e2b-gguf"], ["greeting"])

        with tempfile.TemporaryDirectory() as temp_dir:
            json_path, markdown_path = write_outputs(report, Path(temp_dir))
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            markdown = markdown_path.read_text(encoding="utf-8")

        self.assertEqual("stackchan.model-benchmark.v1", payload["schema"])
        self.assertIn("Stackchan Model Benchmark", markdown)
        self.assertIn("gemma4-e2b-gguf", markdown)
        self.assertIn("deterministic_fallback", markdown)

    def test_cli_writes_report(self):
        script = Path(__file__).with_name("model_benchmark.py")
        with tempfile.TemporaryDirectory() as temp_dir:
            env = {**os.environ, **RUNNER_ENV}
            completed = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--profile",
                    "gemma4-e2b-gguf",
                    "--case",
                    "greeting",
                    "--out-dir",
                    temp_dir,
                    "--json",
                ],
                capture_output=True,
                text=True,
                check=False,
                env=env,
            )

            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertTrue((Path(temp_dir) / "model_benchmark.json").exists())
            self.assertTrue((Path(temp_dir) / "MODEL_BENCHMARK.md").exists())
            payload = json.loads(completed.stdout)

        self.assertEqual("dry-run-no-runner-configured", payload["summary"]["status"])


if __name__ == "__main__":
    unittest.main()
