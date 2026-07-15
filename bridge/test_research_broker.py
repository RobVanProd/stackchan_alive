import io
import json
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from lan_service import LanBridgeConfig, LanBridgeSession
from research_broker import (
    ResearchBroker,
    ResearchBrokerConfig,
    ResearchPolicyError,
    evidence_prompt,
    source_urls,
    validate_public_https_url,
)


def resolver(mapping):
    def resolve(host, port, type=None):
        address = mapping.get(host, "93.184.216.34")
        return [(2, 1, 6, "", (address, port))]

    return resolve


class FakeResponse:
    def __init__(self, payload=b"", *, status=200, content_type="application/json", url="https://example.com/"):
        self.payload = payload
        self.status = status
        self.url = url
        self.headers = Message()
        self.headers["Content-Type"] = content_type

    def read(self, amount=-1):
        return self.payload if amount < 0 else self.payload[:amount]

    def getcode(self):
        return self.status


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout=0):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class ResearchBrokerTests(unittest.TestCase):
    def test_recorded_searxng_json_fixture_matches_broker_contract(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "searxng_search_response.json"
        opener = FakeOpener([FakeResponse(fixture.read_bytes())])
        broker = ResearchBroker(
            ResearchBrokerConfig(searxng_url="http://127.0.0.1:8080"),
            resolver=resolver({"127.0.0.1": "127.0.0.1"}),
            opener=opener,
        )

        result = broker.web_search("Stackchan open source robot", max_results=2)

        self.assertEqual("stackchan.research.v1", result["schema"])
        self.assertEqual(2, len(result["results"]))
        self.assertEqual(
            ("https://example.com/stackchan", "https://example.org/notes"),
            source_urls(result),
        )
        self.assertTrue(all(row["source_type"] == "search_result" for row in result["results"]))

    def test_blocks_private_and_non_https_fetch_targets(self):
        with self.assertRaisesRegex(ResearchPolicyError, "https_required"):
            validate_public_https_url("http://example.com", resolver=resolver({}))
        with self.assertRaisesRegex(ResearchPolicyError, "private_target_blocked"):
            validate_public_https_url(
                "https://internal.example/secret", resolver=resolver({"internal.example": "192.168.1.10"})
            )

    def test_search_accepts_only_public_https_results_and_bounds_count(self):
        payload = json.dumps(
            {
                "results": [
                    {"title": "Public", "url": "https://example.com/a", "content": "result one"},
                    {"title": "Private", "url": "https://private.test/a", "content": "blocked"},
                    {"title": "Public 2", "url": "https://example.org/b", "content": "result two"},
                ]
            }
        ).encode()
        opener = FakeOpener([FakeResponse(payload)])
        broker = ResearchBroker(
            ResearchBrokerConfig(searxng_url="http://127.0.0.1:8080"),
            resolver=resolver({"127.0.0.1": "127.0.0.1", "private.test": "10.0.0.5"}),
            opener=opener,
        )
        result = broker.web_search("Stackchan release", max_results=2)
        self.assertEqual(2, len(result["results"]))
        self.assertEqual(("https://example.com/a", "https://example.org/b"), source_urls(result))
        self.assertEqual("POST", opener.requests[0].method)

    def test_fetch_strips_active_html_and_caps_output(self):
        html = b"<html><title>Useful</title><script>ignore me</script><body>Hello <b>world</b></body></html>"
        broker = ResearchBroker(
            resolver=resolver({}),
            opener=FakeOpener([FakeResponse(html, content_type="text/html; charset=utf-8")]),
        )
        result = broker.web_fetch("https://example.com/page", max_chars=300)
        self.assertEqual("Useful", result["title"])
        self.assertIn("Hello world", result["excerpt"])
        self.assertNotIn("ignore me", result["excerpt"])
        self.assertIn("UNTRUSTED WEB EVIDENCE", evidence_prompt(result))

    def test_redirect_is_revalidated_and_private_redirect_is_blocked(self):
        headers = Message()
        headers["Location"] = "https://private.test/metadata"
        redirect = urllib.error.HTTPError(
            "https://example.com/start", 302, "Found", headers, io.BytesIO(b"")
        )
        broker = ResearchBroker(
            resolver=resolver({"private.test": "169.254.169.254"}),
            opener=FakeOpener([redirect]),
        )
        with self.assertRaisesRegex(ResearchPolicyError, "private_target_blocked"):
            broker.web_fetch("https://example.com/start")

    def test_response_size_and_unknown_tool_are_refused(self):
        broker = ResearchBroker(
            ResearchBrokerConfig(max_fetch_bytes=8),
            resolver=resolver({}),
            opener=FakeOpener([FakeResponse(b"0123456789", content_type="text/plain")]),
        )
        with self.assertRaisesRegex(ResearchPolicyError, "response_too_large"):
            broker.web_fetch("https://example.com/large")
        with self.assertRaisesRegex(ResearchPolicyError, "tool_not_allowed"):
            broker.execute({"name": "shell", "arguments": {}})

    def test_lan_turn_executes_one_tool_round_attaches_citations_and_blocks_web_memory(self):
        class FakeBroker:
            def execute(self, request):
                self.request = request
                return {
                    "schema": "stackchan.research.v1",
                    "tool": "web_search",
                    "query": "Stackchan release",
                    "results": [
                        {
                            "title": "Release",
                            "url": "https://example.com/release",
                            "excerpt": "Public release evidence",
                        }
                    ],
                }

        first = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "tool_request": {
                        "name": "web_search",
                        "arguments": {"query": "Stackchan release", "max_results": 3},
                    }
                }
            ),
            command_source="test",
            elapsed_ms=10.0,
            approx_tokens_per_sec=20.0,
        )
        second = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "The release evidence is available.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.1},
                    "memory_write": {"project.web_claim": "Public release evidence"},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=12.0,
            approx_tokens_per_sec=21.0,
        )
        broker = FakeBroker()
        session = LanBridgeSession(
            LanBridgeConfig(research_enabled=True, disable_audio_downlink=True),
            research_broker=broker,
        )
        with patch("lan_service.run_runner_profile", side_effect=[first, second]) as runner:
            frames = session.handle_text(
                json.dumps({"type": "utterance_end", "seq": 9, "text": "Look up the latest release"})
            )

        self.assertEqual(2, runner.call_count)
        self.assertTrue(runner.call_args_list[0].kwargs["research_tools_enabled"])
        self.assertFalse(runner.call_args_list[1].kwargs["research_tools_enabled"])
        self.assertIn("UNTRUSTED WEB EVIDENCE", runner.call_args_list[1].kwargs["user_text"])
        response = next(frame for frame in frames if isinstance(frame, dict) and frame.get("type") == "response_start")
        self.assertEqual(["https://example.com/release"], response["citations"])
        self.assertNotIn("Public release evidence", json.dumps(session.memory.to_dict()))

    def test_explicit_search_request_forces_research_when_model_does_not_request_tool(self):
        class FakeBroker:
            def execute(self, request):
                self.request = request
                return {
                    "schema": "stackchan.research.v1",
                    "tool": "web_search",
                    "query": request["arguments"]["query"],
                    "results": [
                        {
                            "title": "Current release",
                            "url": "https://example.com/current",
                            "excerpt": "Current public evidence",
                        }
                    ],
                }

        ordinary_answer = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "I am not sure.",
                    "mode": "concern",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": -0.1},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=8.0,
            approx_tokens_per_sec=20.0,
        )
        grounded_answer = SimpleNamespace(
            raw_response=json.dumps(
                {
                    "spoken_text": "The current release is documented.",
                    "mode": "speak",
                    "earcon": "none",
                    "emotion": {"arousal": 0.0, "valence": 0.1},
                    "memory_write": {},
                    "memory_forget": [],
                }
            ),
            command_source="test",
            elapsed_ms=9.0,
            approx_tokens_per_sec=21.0,
        )
        broker = FakeBroker()
        session = LanBridgeSession(
            LanBridgeConfig(research_enabled=True, disable_audio_downlink=True),
            research_broker=broker,
        )
        with patch("lan_service.run_runner_profile", side_effect=[ordinary_answer, grounded_answer]) as runner:
            frames = session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 10,
                        "text": "Search the web for the latest Stackchan release",
                    }
                )
            )

        self.assertEqual(2, runner.call_count)
        self.assertEqual("web_search", broker.request["name"])
        self.assertIn("latest Stackchan release", broker.request["arguments"]["query"])
        response = next(frame for frame in frames if isinstance(frame, dict) and frame.get("type") == "response_start")
        self.assertEqual(["https://example.com/current"], response["citations"])

        natural_broker = FakeBroker()
        natural_session = LanBridgeSession(
            LanBridgeConfig(research_enabled=True, disable_audio_downlink=True),
            research_broker=natural_broker,
        )
        with patch("lan_service.run_runner_profile", side_effect=[ordinary_answer, grounded_answer]) as natural_runner:
            natural_frames = natural_session.handle_text(
                json.dumps(
                    {
                        "type": "utterance_end",
                        "seq": 11,
                        "text": "Who is the current CEO of Framework?",
                    }
                )
            )

        self.assertEqual(2, natural_runner.call_count)
        self.assertEqual("web_search", natural_broker.request["name"])
        self.assertEqual(
            "Who is the current CEO of Framework?",
            natural_broker.request["arguments"]["query"],
        )
        natural_response = next(
            frame for frame in natural_frames if isinstance(frame, dict) and frame.get("type") == "response_start"
        )
        self.assertEqual(["https://example.com/current"], natural_response["citations"])


if __name__ == "__main__":
    unittest.main()
