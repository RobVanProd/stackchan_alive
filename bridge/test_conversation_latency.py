import unittest

from bridge.conversation_latency import build_conversation_latency_record


class ConversationLatencyTests(unittest.TestCase):
    def test_complete_local_turn_reports_all_release_gates(self) -> None:
        result = build_conversation_latency_record(
            audio_summary={"audio_capture_elapsed_ms": 1220.5},
            stt_summary={"stt_elapsed_ms": 410.25},
            brain_summary={"runner_elapsed_ms": 720.0, "research_runner_elapsed_ms": 180.0},
            tts_summary={
                "tts_first_audio_ms": 1450.0,
                "tts_elapsed_ms": 640.0,
                "tts_duration_ms": 1600,
                "tts_audio_payload_bytes": 51200,
                "tts_audio_truncated": False,
                "tts_stream_complete": True,
            },
            response_text_ready_ms=1130.0,
            turn_total_ms=2810.0,
            host_reaction_ms=42.5,
        )

        self.assertEqual("stackchan.conversation-latency.v1", result["latency_schema"])
        self.assertEqual(1220.5, result["latency_capture_ms"])
        self.assertEqual(410.25, result["latency_stt_ms"])
        self.assertEqual(900.0, result["latency_brain_ms"])
        self.assertEqual(42.5, result["latency_host_reaction_ms"])
        self.assertTrue(result["latency_gate_host_reaction_under_300"])
        self.assertEqual(0.4, result["latency_tts_render_rtf"])
        self.assertTrue(result["latency_gate_first_audio_under_3000"])
        self.assertTrue(result["latency_gate_render_faster_than_realtime"])
        self.assertTrue(result["latency_gate_zero_truncation"])

    def test_slow_truncated_turn_fails_each_measured_gate(self) -> None:
        result = build_conversation_latency_record(
            audio_summary={},
            stt_summary={},
            brain_summary={"runner_elapsed_ms": 3500.0},
            tts_summary={
                "tts_first_audio_ms": 3200.0,
                "tts_elapsed_ms": 2400.0,
                "tts_duration_ms": 1200,
                "tts_audio_payload_bytes": 16,
                "tts_audio_truncated": True,
                "tts_stream_complete": False,
            },
            response_text_ready_ms=2700.0,
            turn_total_ms=5600.0,
            host_reaction_ms=330.0,
        )

        self.assertFalse(result["latency_gate_first_audio_under_3000"])
        self.assertFalse(result["latency_gate_host_reaction_under_300"])
        self.assertFalse(result["latency_gate_render_faster_than_realtime"])
        self.assertFalse(result["latency_gate_zero_truncation"])

    def test_missing_audio_does_not_invent_audio_gates(self) -> None:
        result = build_conversation_latency_record(
            audio_summary={},
            stt_summary={},
            brain_summary={},
            tts_summary={},
            response_text_ready_ms=20.0,
            turn_total_ms=25.0,
        )

        self.assertNotIn("latency_first_audio_ms", result)
        self.assertNotIn("latency_host_reaction_ms", result)
        self.assertNotIn("latency_gate_host_reaction_under_300", result)
        self.assertNotIn("latency_gate_first_audio_under_3000", result)
        self.assertNotIn("latency_gate_render_faster_than_realtime", result)
        self.assertNotIn("latency_gate_zero_truncation", result)


if __name__ == "__main__":
    unittest.main()
