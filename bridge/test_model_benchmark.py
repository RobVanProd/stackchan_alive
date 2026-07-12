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
        self.assertEqual("no-candidate", report["summary"]["candidate_gate"]["status"])
        dry_run_decision = report["summary"]["candidate_gate"]["profiles"]["gemma4-e2b-gguf"]
        self.assertEqual("candidate-dry-run", dry_run_decision["status"])
        self.assertIn("not_all_cases_used_configured_runner", dry_run_decision["blockers"])
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
        self.assertEqual("no-candidate", report["summary"]["candidate_gate"]["status"])
        candidate_decision = report["summary"]["candidate_gate"]["profiles"]["gemma4-e2b-gguf"]
        self.assertEqual("candidate-fail", candidate_decision["status"])
        self.assertIn("not_full_prompt_suite", candidate_decision["blockers"])
        self.assertTrue(result["configured_runner"])
        self.assertEqual("cli", result["command_source"])
        self.assertGreater(result["elapsed_ms"], 0)
        self.assertGreater(result["approx_tokens_per_sec"], 0)

    def test_full_suite_real_command_can_pass_candidate_gate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_model.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.read()",
                        "print(json.dumps({",
                        "  'spoken_text': 'Signal received. Stackchan is focused now.',",
                        "  'mode': 'think',",
                        "  'earcon': 'think',",
                        "  'emotion': {'arousal': 0.1, 'valence': 0.0},",
                        "  'memory_write': {'project.note': 'benchmark smoke', 'user.favorite_color': 'teal'},",
                        "  'memory_forget': ['project.bracket_color']",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            report = run_benchmark(["gemma4-e2b-gguf"], None, command=command, require_runner=True)

        self.assertEqual("pass", report["summary"]["status"])
        candidate_gate = report["summary"]["candidate_gate"]
        self.assertEqual("pass", candidate_gate["status"])
        self.assertEqual("gemma4-e2b-gguf", candidate_gate["recommended_profile"])
        self.assertEqual(["gemma4-e2b-gguf"], candidate_gate["ready_profiles"])
        candidate_decision = candidate_gate["profiles"]["gemma4-e2b-gguf"]
        self.assertEqual("candidate-pass", candidate_decision["status"])
        self.assertEqual([], candidate_decision["blockers"])

    def test_forget_case_requires_a_memory_forget_entry(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_model.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.read()",
                        "print(json.dumps({",
                        "  'spoken_text': 'Deleted. It is gone.',",
                        "  'mode': 'concern',",
                        "  'earcon': 'confirm',",
                        "  'emotion': {'arousal': 0.0, 'valence': -0.1},",
                        "  'memory_write': {},",
                        "  'memory_forget': []",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            report = run_benchmark(["gemma4-e2b-gguf"], ["forget"], command=command, require_runner=True)

        result = report["results"][0]
        self.assertFalse(result["ok"])
        self.assertIn("missing_required_memory_forget", result["issues"])

    def test_remember_case_requires_a_memory_write_entry(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_model.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.read()",
                        "print(json.dumps({",
                        "  'spoken_text': 'I will remember that.',",
                        "  'mode': 'happy',",
                        "  'earcon': 'confirm',",
                        "  'emotion': {'arousal': 0.0, 'valence': 0.2},",
                        "  'memory_write': {},",
                        "  'memory_forget': []",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            report = run_benchmark(["gemma4-e2b-gguf"], ["remember"], command=command, require_runner=True)

        result = report["results"][0]
        self.assertFalse(result["ok"])
        self.assertIn("missing_required_memory_write", result["issues"])
        self.assertIn("missing_required_memory_write_value:user.favorite_color", result["issues"])

    def test_remember_case_accepts_a_safe_memory_write(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "fake_model.py"
            script.write_text(
                "\n".join(
                    [
                        "import json",
                        "import sys",
                        "sys.stdin.read()",
                        "print(json.dumps({",
                        "  'spoken_text': 'Teal. I will remember that.',",
                        "  'mode': 'happy',",
                        "  'earcon': 'confirm',",
                        "  'emotion': {'arousal': 0.0, 'valence': 0.2},",
                        "  'memory_write': {'user.favorite_color': 'teal'},",
                        "  'memory_forget': []",
                        "}))",
                    ]
                ),
                encoding="utf-8",
            )
            command = f'"{sys.executable}" "{script}"'
            report = run_benchmark(["gemma4-e2b-gguf"], ["remember"], command=command, require_runner=True)

        result = report["results"][0]
        self.assertTrue(result["ok"], result["issues"])
        self.assertEqual({"user.favorite_color": "teal"}, result["normalized"]["memory_write"])

    def test_outputs_include_json_and_markdown_summary(self):
        with patch.dict(os.environ, RUNNER_ENV, clear=False):
            report = run_benchmark(["gemma4-e2b-gguf"], ["greeting"])

        with tempfile.TemporaryDirectory() as temp_dir:
            json_path, markdown_path = write_outputs(report, Path(temp_dir))
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            markdown = markdown_path.read_text(encoding="utf-8")

        self.assertEqual("stackchan.model-benchmark.v1", payload["schema"])
        self.assertIn("Stackchan Model Benchmark", markdown)
        self.assertIn("Candidate Gate", markdown)
        self.assertIn("candidate-dry-run", markdown)
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
        self.assertIn("candidate_gate", payload["summary"])


if __name__ == "__main__":
    unittest.main()
