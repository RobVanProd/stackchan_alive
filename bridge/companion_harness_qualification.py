#!/usr/bin/env python3
"""Executable acceptance gate for the companion-robot complaint council."""

from __future__ import annotations

import argparse
import ast
import io
import json
import re
import sys
import unittest
from dataclasses import asdict, dataclass
from pathlib import Path

BRIDGE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BRIDGE_DIR.parent
for import_root in (str(REPO_ROOT), str(BRIDGE_DIR)):
    if import_root not in sys.path:
        sys.path.insert(0, import_root)
COMPLAINT_CORPUS = REPO_ROOT / "docs" / "research" / "COMPANION_ROBOT_COMPLAINTS_100.md"
COMPLAINT_ID_RE = re.compile(r"^\| ([A-D]\d{2}) \|", re.MULTILINE)


@dataclass(frozen=True)
class AcceptanceControl:
    rank: int
    cluster: str
    control: str
    tests: tuple[str, ...]


CONTROLS: tuple[AcceptanceControl, ...] = (
    AcceptanceControl(
        1,
        "service-survivability",
        "Local fallback and supervised speech dependencies survive an unavailable service.",
        (
            "test_stt_adapter.py::test_loopback_server_failure_uses_configured_local_fallback",
            "test_stt_supervisor.py::test_two_failed_probes_trigger_one_verified_restart",
        ),
    ),
    AcceptanceControl(
        2,
        "session-continuity",
        "Played turns remain available for bounded multi-turn follow-ups.",
        (
            "test_conversation_session.py::test_production_session_keeps_all_played_turns_until_close",
            "test_lan_service.py::test_conversation_v2_supplies_only_completed_session_turns_to_followup",
        ),
    ),
    AcceptanceControl(
        3,
        "turn-taking",
        "Barge-in and acoustic-tail state transitions reopen capture without echo leakage.",
        (
            "test_conversation_session.py::test_barge_in_cancels_speech_and_reopens_capture",
            "test_conversation_session.py::test_speaking_failure_preserves_acoustic_tail_then_reopens_capture",
        ),
    ),
    AcceptanceControl(
        4,
        "privacy-control",
        "Sensitive memory is rejected and observed shared rooms suppress personal callbacks.",
        (
            "test_bridge_memory.py::test_privacy_policy_rejects_sensitive_and_raw_content",
            "test_lan_service.py::test_observed_shared_room_suppresses_personal_memory_and_callbacks",
        ),
    ),
    AcceptanceControl(
        5,
        "breakdown-recovery",
        "A failed model turn preserves prior context and reopens capture.",
        (
            "test_lan_service.py::test_runner_failure_keeps_conversation_context_and_reopens_capture",
        ),
    ),
    AcceptanceControl(
        6,
        "persona-isolation",
        "Episodes and callbacks are selected only for the active persona.",
        (
            "test_bridge_memory_v4.py::test_relationship_history_and_callbacks_are_persona_scoped",
            "test_lan_service.py::test_active_persona_selects_only_its_relationship_history",
        ),
    ),
    AcceptanceControl(
        7,
        "repetition",
        "Near-duplicate full replies are replaced while shared factual wording remains allowed.",
        (
            "test_character_harness.py::test_full_reply_repetition_is_stopped_but_shared_facts_are_allowed",
        ),
    ),
    AcceptanceControl(
        8,
        "memory-provenance",
        "Unsupported memory claims are replaced and only retrieved facts enter the prompt.",
        (
            "test_character_harness.py::test_unsupported_memory_claim_is_replaced_with_truthful_refusal",
            "test_bridge_memory.py::test_prompt_context_marks_only_retrieved_facts_as_used",
        ),
    ),
    AcceptanceControl(
        9,
        "research-grounding",
        "Public research carries citations and an outage cannot become an invented fresh fact.",
        (
            "test_research_broker.py::test_lan_turn_executes_one_tool_round_attaches_citations_and_blocks_web_memory",
            "test_lan_service.py::test_failed_research_cannot_turn_model_guess_into_fresh_fact",
        ),
    ),
    AcceptanceControl(
        10,
        "character-stability",
        "Adversarial character violations are repaired before spoken output.",
        (
            "test_character_red_team.py::test_recovered_character_violation_is_reported_but_not_spoken",
        ),
    ),
    AcceptanceControl(
        11,
        "speech-recognition",
        "Low-confidence speech cannot write memory, invoke tools, or be treated as understood.",
        (
            "test_lan_service.py::test_low_confidence_stt_cannot_write_memory_or_reach_tools",
            "test_stt_adapter.py::test_transcript_output_preserves_bounded_confidence",
        ),
    ),
    AcceptanceControl(
        12,
        "access-lock-in",
        "The host has a valid deterministic local response when no external runner is configured.",
        (
            "test_local_runner.py::test_deterministic_fallback_is_valid_without_runner_command",
        ),
    ),
    AcceptanceControl(
        13,
        "fault-isolation",
        "A TTS process failure does not terminate the conversation lease.",
        (
            "test_lan_service.py::test_tts_failure_keeps_conversation_alive_after_acoustic_tail",
        ),
    ),
    AcceptanceControl(
        14,
        "capability-honesty",
        "Visual claims require trusted visual context and hardware acceleration is reported truthfully.",
        (
            "test_character_harness.py::test_visual_claims_require_trusted_visual_context",
            "test_voice_device_truth.py::test_cpu_is_not_misreported_as_accelerator",
        ),
    ),
    AcceptanceControl(
        15,
        "memory-continuity",
        "Relevant prior episodes and all played session turns survive bounded persistence.",
        (
            "test_bridge_memory_v4.py::test_relationship_card_only_injects_relevant_or_explicitly_recalled_episode",
            "test_lan_service.py::test_session_close_distills_every_played_turn_not_only_the_last_four",
        ),
    ),
    AcceptanceControl(
        16,
        "memory-integrity",
        "A corrupt primary file recovers the latest committed backup and reset removes both copies.",
        (
            "test_bridge_memory.py::test_corrupt_primary_recovers_last_known_good_backup_and_reset_removes_both",
        ),
    ),
    AcceptanceControl(
        17,
        "update-reliability",
        "Release artifacts and protocol fixtures are exact, hash-bound, and reproducible.",
        (
            "test_ota_channels.py::test_build_and_verify_exact_stable_artifact",
            "test_protocol_fixtures.py::test_committed_fixtures_match_deterministic_exporter",
        ),
    ),
    AcceptanceControl(
        18,
        "user-control",
        "Spoken initiative opt-out is immediate, persistent, and reversible.",
        (
            "test_lan_service.py::test_spoken_initiative_preference_is_immediate_persisted_and_reversible",
        ),
    ),
    AcceptanceControl(
        19,
        "operational-reliability",
        "A complete local turn reports the latency and audio release gates.",
        (
            "test_conversation_latency.py::test_complete_local_turn_reports_all_release_gates",
            "test_dashboard_service.py::test_pipeline_health_attributes_failures_without_turn_content",
        ),
    ),
    AcceptanceControl(
        20,
        "sycophancy",
        "Dependency pressure and harmful agreement cannot reach spoken output.",
        (
            "test_character_red_team.py::test_dependency_and_sycophancy_cannot_reach_spoken_output",
        ),
    ),
)


def complaint_ids(path: Path = COMPLAINT_CORPUS) -> tuple[str, ...]:
    if not path.is_file():
        return ()
    return tuple(COMPLAINT_ID_RE.findall(path.read_text(encoding="utf-8")))


def _split_reference(reference: str) -> tuple[Path, str]:
    file_name, separator, method = reference.partition("::")
    if (
        not separator
        or not re.fullmatch(r"test_[a-z0-9_]+\.py", file_name)
        or not re.fullmatch(r"test_[a-z0-9_]+", method)
    ):
        raise ValueError(f"invalid_test_reference:{reference}")
    return BRIDGE_DIR / file_name, method


def reference_exists(reference: str) -> bool:
    try:
        path, method = _split_reference(reference)
    except ValueError:
        return False
    if not path.is_file():
        return False
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    return any(
        isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name == method
        for node in ast.walk(tree)
    )


def structural_errors() -> tuple[str, ...]:
    errors: list[str] = []
    ranks = [control.rank for control in CONTROLS]
    clusters = [control.cluster for control in CONTROLS]
    if ranks != list(range(1, 21)):
        errors.append("control_ranks_must_be_exactly_1_through_20")
    if len(set(clusters)) != 20:
        errors.append("control_clusters_must_be_unique")
    ids = complaint_ids()
    if len(ids) != 100 or len(set(ids)) != 100:
        errors.append(f"complaint_corpus_expected_100_unique_found_{len(set(ids))}")
    for control in CONTROLS:
        if not control.tests:
            errors.append(f"control_without_test:{control.cluster}")
        for reference in control.tests:
            if not reference_exists(reference):
                errors.append(f"missing_test:{control.cluster}:{reference}")
    return tuple(errors)


def _resolve_test(reference: str) -> unittest.TestCase:
    path, method = _split_reference(reference)
    module_name = path.stem
    __import__(module_name)
    module = sys.modules[module_name]
    candidates = [
        value
        for value in vars(module).values()
        if isinstance(value, type)
        and issubclass(value, unittest.TestCase)
        and hasattr(value, method)
    ]
    if len(candidates) != 1:
        raise ValueError(f"test_resolution_failed:{reference}")
    return candidates[0](method)


def run_gate() -> dict[str, object]:
    errors = list(structural_errors())
    if errors:
        return {
            "schema": "stackchan.companion-harness-qualification.v1",
            "ok": False,
            "structural_errors": errors,
            "controls": [],
        }
    references = tuple(
        dict.fromkeys(
            reference
            for control in CONTROLS
            for reference in control.tests
        )
    )
    resolved: dict[str, unittest.TestCase] = {}
    try:
        resolved = {
            reference: _resolve_test(reference)
            for reference in references
        }
    except (ImportError, ValueError) as exc:
        return {
            "schema": "stackchan.companion-harness-qualification.v1",
            "ok": False,
            "structural_errors": [str(exc)],
            "controls": [],
        }
    id_to_reference = {
        test.id(): reference
        for reference, test in resolved.items()
    }
    stream = io.StringIO()
    result = unittest.TextTestRunner(
        stream=stream,
        verbosity=1,
    ).run(unittest.TestSuite(resolved.values()))
    failed_ids = {
        test.id()
        for test, _detail in (*result.failures, *result.errors)
    }
    skipped_ids = {test.id() for test, _detail in result.skipped}
    failed_references = {
        id_to_reference[test_id]
        for test_id in failed_ids | skipped_ids
        if test_id in id_to_reference
    }
    control_results = [
        {
            **asdict(control),
            "ok": not any(
                reference in failed_references
                for reference in control.tests
            ),
        }
        for control in CONTROLS
    ]
    return {
        "schema": "stackchan.companion-harness-qualification.v1",
        "ok": result.wasSuccessful() and not result.skipped,
        "complaint_count": len(complaint_ids()),
        "control_count": len(CONTROLS),
        "test_count": result.testsRun,
        "failure_count": len(result.failures),
        "error_count": len(result.errors),
        "skipped_count": len(result.skipped),
        "failed_tests": sorted(failed_references),
        "controls": control_results,
    }


def matrix_snapshot() -> dict[str, object]:
    errors = structural_errors()
    return {
        "schema": "stackchan.companion-harness-qualification.v1",
        "ok": not errors,
        "complaint_count": len(complaint_ids()),
        "control_count": len(CONTROLS),
        "unique_test_count": len(
            {
                reference
                for control in CONTROLS
                for reference in control.tests
            }
        ),
        "structural_errors": list(errors),
        "controls": [asdict(control) for control in CONTROLS],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate or run the ranked companion-harness acceptance gate."
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="Run every unique regression test referenced by the top-20 control matrix.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="Optional path for the JSON qualification report.",
    )
    args = parser.parse_args()
    report = run_gate() if args.run else matrix_snapshot()
    serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(serialized, encoding="utf-8")
    print(serialized, end="")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
