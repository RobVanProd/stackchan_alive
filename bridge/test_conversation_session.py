import unittest

from bridge.conversation_session import ConversationConfig, ConversationPhase, ConversationSession


class ConversationSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.session = ConversationSession(
            ConversationConfig(reply_window_ms=1_000, acoustic_tail_ms=200, cooldown_ms=100, max_turns=2)
        )

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

    def test_invalid_config_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            ConversationConfig(reply_window_ms=0)
        with self.assertRaises(ValueError):
            ConversationConfig(max_turns=0)


if __name__ == "__main__":
    unittest.main()
