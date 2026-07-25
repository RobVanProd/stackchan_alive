import unittest
from unittest.mock import patch

from bridge.initiative_policy import InitiativeConfig, InitiativePolicy


TEN_MINUTES = 10 * 60 * 1000


class InitiativePolicyTests(unittest.TestCase):
    def policy(self) -> InitiativePolicy:
        return InitiativePolicy(
            InitiativeConfig(
                enabled=True,
                min_interval_ms=TEN_MINUTES,
                curiosity_decay_per_minute=0.0,
                reply_grace_ms=1_000,
                ignored_backoff_ms=60_000,
                failed_attempt_backoff_ms=2_000,
            ),
            now_ms=0,
        )

    def decide(self, policy: InitiativePolicy, now_ms: int, **overrides):
        values = {
            "now_ms": now_ms,
            "local_hour": 12,
            "night_start_hour": 21,
            "morning_start_hour": 6,
            "robot_mode": "idle",
            "session_active": False,
            "turn_busy": False,
            "safety_clear": True,
        }
        values.update(overrides)
        return policy.decide(**values)

    def test_arrival_requires_presence_and_hard_rate_floor(self) -> None:
        policy = self.policy()
        self.assertEqual(
            "arrival",
            policy.observe_presence(True, face_count=1, now_ms=TEN_MINUTES - 1),
        )
        self.assertIsNone(self.decide(policy, TEN_MINUTES - 1))

        decision = self.decide(policy, TEN_MINUTES)

        self.assertIsNotNone(decision)
        self.assertEqual("arrival", decision.reason)
        self.assertIn("question", decision.prompt)

    def test_session_busy_safety_and_night_each_suppress_speech(self) -> None:
        for override in (
            {"session_active": True},
            {"turn_busy": True},
            {"safety_clear": False},
            {"robot_mode": "speaking"},
            {"local_hour": 23},
            {"local_hour": 4},
        ):
            with self.subTest(override=override):
                policy = self.policy()
                policy.observe_presence(True, face_count=1, now_ms=TEN_MINUTES - 1)
                self.assertIsNone(self.decide(policy, TEN_MINUTES, **override))

    def test_return_and_ephemeral_new_face_raise_curiosity(self) -> None:
        policy = self.policy()
        policy.observe_presence(True, face_count=1, now_ms=1)
        policy.observe_presence(False, face_count=0, now_ms=10)
        self.assertEqual("return", policy.observe_presence(True, face_count=1, now_ms=130_010))
        self.assertEqual("new_face", policy.observe_presence(True, face_count=2, now_ms=130_020))
        policy.observe_presence(True, face_count=2, now_ms=TEN_MINUTES)
        self.assertEqual("new_face", self.decide(policy, TEN_MINUTES).reason)

    def test_two_ignored_openers_trigger_long_backoff(self) -> None:
        policy = self.policy()
        policy.observe_presence(True, face_count=1, now_ms=TEN_MINUTES - 1)
        first = self.decide(policy, TEN_MINUTES)
        self.assertIsNotNone(first)
        policy.note_spoken(now_ms=TEN_MINUTES)
        policy.observe_scene_changes(
            ("objects_changed", "lighting_changed"),
            now_ms=TEN_MINUTES + 1,
        )

        second_at = 2 * TEN_MINUTES
        policy.observe_presence(True, face_count=1, now_ms=second_at)
        second = self.decide(policy, second_at)
        self.assertIsNotNone(second)
        policy.note_spoken(now_ms=second_at)
        policy.observe_scene_changes(
            ("objects_changed", "lighting_changed"),
            now_ms=second_at + 1,
        )

        policy.observe_presence(True, face_count=1, now_ms=3 * TEN_MINUTES)
        self.assertIsNone(self.decide(policy, 3 * TEN_MINUTES))
        status = policy.status(now_ms=3 * TEN_MINUTES)
        self.assertEqual(2, status["ignoredOpeners"])
        self.assertGreater(status["backoffRemainingSeconds"], 0)

    def test_user_activity_clears_ignored_count(self) -> None:
        policy = self.policy()
        policy.observe_presence(True, face_count=1, now_ms=TEN_MINUTES - 1)
        self.assertIsNotNone(self.decide(policy, TEN_MINUTES))
        policy.note_spoken(now_ms=TEN_MINUTES)
        policy.note_user_activity(now_ms=TEN_MINUTES + 100)

        status = policy.status(now_ms=TEN_MINUTES + 100)

        self.assertFalse(status["pendingReply"])
        self.assertEqual(0, status["ignoredOpeners"])

    def test_failed_generation_releases_reservation_with_short_retry_backoff(self) -> None:
        policy = self.policy()
        policy.observe_presence(True, face_count=1, now_ms=TEN_MINUTES - 1)
        self.assertIsNotNone(self.decide(policy, TEN_MINUTES))
        policy.note_attempt_failed(now_ms=TEN_MINUTES)
        self.assertIsNone(self.decide(policy, TEN_MINUTES + 1_999))
        self.assertIsNotNone(self.decide(policy, TEN_MINUTES + 2_000))

    def test_floor_cannot_be_configured_below_ten_minutes(self) -> None:
        with self.assertRaises(ValueError):
            InitiativeConfig(min_interval_ms=TEN_MINUTES - 1)

    def test_enabling_from_dashboard_resets_accumulated_curiosity(self) -> None:
        policy = InitiativePolicy(
            InitiativeConfig(enabled=False, curiosity_decay_per_minute=0.0),
            now_ms=0,
        )
        policy.observe_presence(True, face_count=1, now_ms=1)
        with patch("bridge.initiative_policy.time.time", return_value=1_000.0):
            policy.set_enabled(True)

        status = policy.status(now_ms=1_000_000)

        self.assertEqual(0.0, status["curiosityScore"])
        self.assertIsNone(self.decide(policy, 1_000_000))

    def test_stale_presence_never_authorizes_speech(self) -> None:
        policy = self.policy()
        policy.observe_presence(True, face_count=1, now_ms=TEN_MINUTES - 31_000)

        self.assertIsNone(self.decide(policy, TEN_MINUTES))
        self.assertFalse(policy.status(now_ms=TEN_MINUTES)["presenceFresh"])


if __name__ == "__main__":
    unittest.main()
