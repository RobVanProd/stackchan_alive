import unittest

from bridge.conversation_latency_report import summarize_latency_records


class ConversationLatencyReportTests(unittest.TestCase):
    def test_report_aggregates_distributions_and_passes_complete_turns(self) -> None:
        records = [
            {
                "latency_schema": "stackchan.conversation-latency.v1",
                "latency_first_audio_ms": first_audio,
                "latency_text_ready_ms": 500 + index,
                "latency_turn_total_ms": 2000 + index,
                "latency_tts_render_rtf": 0.5,
                "latency_gate_first_audio_under_3000": True,
                "latency_gate_render_faster_than_realtime": True,
                "latency_gate_zero_truncation": True,
            }
            for index, first_audio in enumerate((900, 1100, 1500, 2200))
        ]

        report = summarize_latency_records(records)

        self.assertEqual("pass", report["status"])
        self.assertEqual(4, report["audio_turns"])
        self.assertEqual(1100, report["first_audio_ms"]["p50"])
        self.assertEqual(2200, report["first_audio_ms"]["p95"])
        self.assertEqual(0, report["gates"]["latency_gate_zero_truncation"]["failed"])

    def test_missing_or_failed_gate_is_not_ready(self) -> None:
        report = summarize_latency_records(
            [
                {
                    "latency_schema": "stackchan.conversation-latency.v1",
                    "latency_first_audio_ms": 3500,
                    "latency_gate_first_audio_under_3000": False,
                    "latency_gate_zero_truncation": True,
                }
            ]
        )

        self.assertEqual("not_ready", report["status"])
        self.assertEqual(1, report["gates"]["latency_gate_first_audio_under_3000"]["failed"])
        self.assertEqual(1, report["gates"]["latency_gate_render_faster_than_realtime"]["missing"])


if __name__ == "__main__":
    unittest.main()
