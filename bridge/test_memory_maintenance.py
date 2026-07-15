import json
import tempfile
import unittest
from pathlib import Path

from bridge_memory import MEMORY_SCHEMA, load_bridge_memory
from memory_maintenance import audit_or_repair


class MemoryMaintenanceTests(unittest.TestCase):
    def test_dry_run_reports_corruption_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "memory.json"
            original = {
                "preferred_name": "happy",
                "recent_topics": ["voice", ["bridge"]],
                "physical_context": [["greeting"], "low_battery", "1"],
                "turns_seen": 113,
            }
            path.write_text(json.dumps(original), encoding="utf-8")

            report = audit_or_repair(path, apply=False)

            self.assertEqual("repair-available", report["status"])
            self.assertTrue(report["changed"])
            self.assertEqual(original, json.loads(path.read_text(encoding="utf-8")))
            self.assertEqual([], list(path.parent.glob("memory.backup-*.json")))

    def test_apply_backs_up_and_writes_sanitized_v4(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "memory.json"
            path.write_text(
                json.dumps(
                    {
                        "preferred_name": "happy",
                        "recent_topics": ["voice", ["bridge"]],
                        "physical_context": [["greeting"], "low_battery", "1"],
                        "turns_seen": 113,
                    }
                ),
                encoding="utf-8",
            )

            report = audit_or_repair(path, apply=True)
            repaired = json.loads(path.read_text(encoding="utf-8"))

            self.assertEqual("repaired", report["status"])
            self.assertTrue(Path(str(report["backup_file"])).is_file())
            self.assertEqual(MEMORY_SCHEMA, repaired["schema"])
            self.assertEqual("", repaired["preferred_name"])
            self.assertEqual(["voice"], repaired["recent_topics"])
            self.assertEqual([], repaired["physical_context"])
            self.assertEqual([], repaired["episodes"])
            self.assertEqual([], repaired["open_loops"])

            clean_report = audit_or_repair(path, apply=False)
            self.assertEqual("clean", clean_report["status"])
            self.assertFalse(clean_report["changed"])

    def test_malformed_json_does_not_prevent_bridge_startup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "memory.json"
            path.write_text("{not-json", encoding="utf-8")

            memory = load_bridge_memory(path)
            report = audit_or_repair(path, apply=False)

            self.assertEqual("", memory.preferred_name)
            self.assertEqual("JSONDecodeError", report["parse_error"])
            self.assertEqual("repair-available", report["status"])


if __name__ == "__main__":
    unittest.main()
