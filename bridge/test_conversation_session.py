import unittest

from bridge.conversation_session import ConversationConfig, ConversationPhase, ConversationSession


class ConversationSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.session = ConversationSession(
            ConversationConfig(reply_window_ms=1_000, acoustic_tail_ms=200, cooldown_ms=100, max_turns=2)
        )

    def test_production_defaults_keep_a_patient_bounded_session(self) -> None:
        session = ConversationSession()
        self.assertEqual(10_000, session.current_reply_window_ms())
        self.assertEqual(24, session.config.max_turns)
        self.assertEqual(24, session.config.max_context_turns)
        self.assertEqual(160, session.config.max_context_chars)

        session.wake(0)
        now = 0
        for turn in range(1, 6):
            session.utterance_committed(now + 10, f"turn {turn}")
            self.assertEqual(10_000, session.current_reply_window_ms())
            session.response_started(now + 20)
            session.playback_completed(now + 30)
            now += 300
            self.assertEqual("reply_window_open", session.tick(now).reason)

    def test_production_session_keeps_all_played_turns_until_close(self) -> None:
        session = ConversationSession(
            ConversationConfig(reply_window_ms=1_000, acoustic_tail_ms=0, cooldown_ms=0)
        )
        session.wake(0)

        for index in range(10):
            now = index * 100
            session.utterance_committed(now + 10, f"subject detail {index}")
            session.response_started(now + 20)
            session.stage_turn(f"subject detail {index}", f"answer detail {index}")
            session.playback_completed(now + 30)
            session.tick(now + 30)

        lines = session.context_lines()
        self.assertEqual(20, len(lines))
        self.assertIn("subject detail 0", lines[0])
        self.assertIn("answer detail 9", lines[-1])

        session.cancel(1_100, "test_close")
        self.assertEqual((), session.context_lines())
        closed = session.take_closed_turns()
        self.assertEqual(10, len(closed))
        self.assertEqual(("subject detail 0", "answer detail 0"), closed[0])
        self.assertEqual((), session.take_closed_turns())

    def complete_response(self, start_ms: int = 100) -> None:
        self.session.utterance_committed(start_ms, "Tell me something")
        self.session.response_started(start_ms + 10)
        self.session.playback_completed(start_ms + 100)

    def test_wake_reply_tail_and_timeout_return_to_idle(self) -> None:
        transition = self.session.wake(0, "robot")
        self.assertEqual(ConversationPhase.ENGAGED, transition.phase)
        self.assertEqual(("session_started", "open_capture"), transition.actions)
        self.assertTrue(self.session.capture_open)

        self.complete_response()
        self.assertEqual(ConversationPhase.REPLY_WINDOW, self.session.phase)
        self.assertTrue(self.session.echo_guard)
        self.assertFalse(self.session.capture_open)

        self.assertEqual("no_change", self.session.tick(399).reason)
        opened = self.session.tick(400)
        self.assertEqual(("echo_guard_off", "open_capture"), opened.actions)
        self.assertTrue(self.session.capture_open)

        closing = self.session.tick(1_400)
        self.assertEqual("reply_timeout", closing.reason)
        self.assertEqual(ConversationPhase.COOLDOWN, self.session.phase)
        closed = self.session.tick(1_500)
        self.assertEqual(("close_capture", "session_closed"), closed.actions)
        self.assertEqual(ConversationPhase.IDLE, self.session.phase)

    def test_exit_phrase_closes_without_model_turn(self) -> None:
        self.session.wake(0)
        result = self.session.utterance_committed(50, "Goodbye Stackchan!")
        self.assertEqual("exit_phrase", result.reason)
        self.assertEqual(0, self.session.turns)
        self.assertEqual(ConversationPhase.COOLDOWN, self.session.phase)

    def test_barge_in_cancels_speech_and_reopens_capture(self) -> None:
        self.session.wake(0)
        self.session.utterance_committed(10, "First question")
        self.session.response_started(20)
        result = self.session.barge_in(30)
        self.assertEqual(("cancel_generation", "cancel_playback", "open_capture"), result.actions)
        self.assertEqual(ConversationPhase.ENGAGED, self.session.phase)
        self.assertTrue(self.session.capture_open)
        self.assertFalse(self.session.echo_guard)

    def test_turn_limit_closes_after_complete_playback(self) -> None:
        self.session.wake(0)
        self.complete_response(10)
        self.session.tick(310)
        self.session.utterance_committed(320, "Second question")
        self.session.response_started(330)
        result = self.session.playback_completed(400)
        self.assertEqual("turn_limit", result.reason)
        self.assertEqual(ConversationPhase.COOLDOWN, self.session.phase)
        self.assertFalse(self.session.capture_open)

    def test_bridge_loss_cancels_busy_work_and_returns_idle(self) -> None:
        self.session.wake(0)
        self.session.utterance_committed(10, "Question")
        result = self.session.bridge_lost()
        self.assertEqual(("close_capture", "cancel_generation", "session_closed"), result.actions)
        self.assertEqual(ConversationPhase.IDLE, self.session.phase)
        self.assertEqual("bridge_lost", result.reason)

    def test_recent_turn_context_commits_only_after_playback_and_is_bounded(self) -> None:
        session = ConversationSession(
            ConversationConfig(
                reply_window_ms=1_000,
                acoustic_tail_ms=0,
                cooldown_ms=0,
                max_turns=5,
                max_context_turns=2,
                max_context_chars=24,
            )
        )
        session.wake(0)

        for index in range(3):
            session.utterance_committed(index * 100 + 10, f"Question {index} with extra words")
            session.response_started(index * 100 + 20)
            session.stage_turn(
                f"Question {index} with extra words",
                f"Response {index} with extra words",
            )
            self.assertEqual(index if index < 2 else 2, len(session.context_lines()) // 2)
            session.playback_completed(index * 100 + 30)
            session.tick(index * 100 + 30)

        lines = session.context_lines()
        self.assertEqual(4, len(lines))
        self.assertFalse(any("Question 0" in line for line in lines))
        self.assertTrue(any("Question 1" in line for line in lines))
        self.assertTrue(any("Question 2" in line for line in lines))
        self.assertTrue(all(len(line.split(": ", 1)[-1]) <= 24 for line in lines))

        snapshot = session.snapshot(400)
        self.assertEqual(2, snapshot["conversation_context_turns"])
        self.assertNotIn("Question", str(snapshot))

        session.bridge_lost()
        self.assertEqual((), session.context_lines())

    def test_unplayed_staged_turn_is_not_archived_on_close(self) -> None:
        session = ConversationSession(
            ConversationConfig(reply_window_ms=1_000, acoustic_tail_ms=0, cooldown_ms=0)
        )
        session.wake(0)
        session.utterance_committed(10, "unfinished question")
        session.response_started(20)
        session.stage_turn("unfinished question", "response never completed")

        session.bridge_lost()

        self.assertEqual((), session.take_closed_turns())

    def test_turn_failure_and_cancel_close_through_cooldown(self) -> None:
        self.session.wake(0)
        self.session.utterance_committed(10, "Question")
        failed = self.session.turn_failed(20, "runner error")
        self.assertEqual("runner error", failed.reason)
        self.assertEqual(ConversationPhase.COOLDOWN, self.session.phase)
        self.session.tick(120)
        self.assertEqual(ConversationPhase.IDLE, self.session.phase)

        self.session.wake(200)
        cancelled = self.session.cancel(210, "owner cancelled")
        self.assertEqual("owner cancelled", cancelled.reason)
        self.assertEqual(ConversationPhase.COOLDOWN, self.session.phase)

    def test_snapshot_exposes_conversation_only_not_motion_authority(self) -> None:
        self.session.wake(100, "pc-brain")
        snapshot = self.session.snapshot(250)
        self.assertEqual("engaged", snapshot["conversation_state"])
        self.assertEqual("pc-brain", snapshot["conversation_owner"])
        self.assertEqual(850, snapshot["conversation_reply_window_remaining_ms"])
        self.assertFalse(any("motion" in key for key in snapshot))

    def test_followup_window_shortens_after_later_turns(self) -> None:
        session = ConversationSession(
            ConversationConfig(
                reply_window_ms=8_000,
                reply_window_min_ms=4_000,
                reply_window_step_ms=1_000,
                acoustic_tail_ms=0,
            )
        )
        session.wake(0)
        self.assertEqual(8_000, session.current_reply_window_ms())

        for turn in range(1, 7):
            session.utterance_committed(turn * 100, f"turn {turn}")
            session.response_started(turn * 100 + 10)
            session.playback_completed(turn * 100 + 20)
            expected = max(4_000, 8_000 - (turn - 1) * 1_000)
            self.assertEqual(expected, session.current_reply_window_ms())
            self.assertEqual(expected, session.snapshot(turn * 100 + 20)["conversation_reply_window_ms"])
            session.tick(turn * 100 + 20)

    def test_started_capture_gets_bounded_time_to_finish_after_short_window(self) -> None:
        session = ConversationSession(
            ConversationConfig(
                reply_window_ms=2_000,
                reply_window_min_ms=1_000,
                reply_window_step_ms=1_000,
                acoustic_tail_ms=0,
            )
        )
        session.wake(0)
        session.utterance_committed(10, "first")
        session.response_started(20)
        session.playback_completed(30)
        session.tick(30)
        session.utterance_committed(40, "second")
        session.response_started(50)
        session.playback_completed(60)
        session.tick(60)

        started = session.utterance_started(900)
        self.assertEqual("listening", started.reason)
        self.assertEqual("capture_in_progress", session.tick(1_060).reason)
        snapshot = session.snapshot(1_100)
        self.assertEqual(0, snapshot["conversation_reply_window_remaining_ms"])
        self.assertEqual(1_800, snapshot["conversation_capture_commit_remaining_ms"])

        committed = session.utterance_committed(2_000, "third")
        self.assertEqual(("close_capture", "begin_generation"), committed.actions)
        self.assertEqual(ConversationPhase.THINKING, session.phase)

    def test_invalid_config_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            ConversationConfig(reply_window_ms=0)
        with self.assertRaises(ValueError):
            ConversationConfig(reply_window_ms=30_001)
        with self.assertRaises(ValueError):
            ConversationConfig(reply_window_ms=4_000, reply_window_min_ms=5_000)
        with self.assertRaises(ValueError):
            ConversationConfig(reply_window_step_ms=-1)
        with self.assertRaises(ValueError):
            ConversationConfig(acoustic_tail_ms=2_001)
        with self.assertRaises(ValueError):
            ConversationConfig(max_turns=0)
        with self.assertRaises(ValueError):
            ConversationConfig(max_context_turns=0)


if __name__ == "__main__":
    unittest.main()
