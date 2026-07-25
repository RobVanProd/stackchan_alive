#!/usr/bin/env python3
"""In-memory PCM client for a loopback whisper.cpp server."""

from __future__ import annotations

from dataclasses import dataclass
import argparse
import io
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import wave

try:
    from .stt_normalization import normalize_stackchan_terms
except ImportError:
    from stt_normalization import normalize_stackchan_terms


DEFAULT_WHISPER_SERVER_URL = "http://127.0.0.1:5061"
MAX_PCM_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024


class WhisperServerError(RuntimeError):
    """Raised when the local whisper.cpp service cannot produce a transcript."""


@dataclass(frozen=True)
class WhisperServerResult:
    transcript: str
    raw_transcript: str = ""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_loopback_url(value: str) -> str:
    parsed = urllib.parse.urlparse(str(value).strip())
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "::1"}
        or parsed.username
        or parsed.password
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("whisper.cpp server URL must be loopback-only HTTP")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("whisper.cpp server URL has an invalid port") from exc
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("whisper.cpp server URL has an invalid port")
    return str(value).rstrip("/")


def pcm_to_wav(pcm: bytes, sample_rate: int) -> bytes:
    audio = bytes(pcm)
    if not audio or len(audio) > MAX_PCM_BYTES or len(audio) % 2:
        raise ValueError("PCM must contain bounded signed 16-bit mono samples")
    rate = max(8_000, min(48_000, int(sample_rate or 16_000)))
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(audio)
    return output.getvalue()


def _multipart_body(wav_data: bytes) -> tuple[bytes, str]:
    boundary = f"stackchan-{secrets.token_hex(12)}"
    parts = [
        (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="file"; filename="utterance.wav"\r\n'
            "Content-Type: audio/wav\r\n\r\n"
        ).encode("ascii")
        + wav_data
        + b"\r\n",
        (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="response_format"\r\n\r\n'
            "json\r\n"
        ).encode("ascii"),
        (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="temperature"\r\n\r\n'
            "0\r\n"
        ).encode("ascii"),
        f"--{boundary}--\r\n".encode("ascii"),
    ]
    return b"".join(parts), boundary


def transcribe_pcm_via_server(
    pcm: bytes,
    sample_rate: int,
    *,
    server_url: str = DEFAULT_WHISPER_SERVER_URL,
    timeout_ms: int = 15_000,
) -> WhisperServerResult:
    endpoint = validate_loopback_url(server_url) + "/inference"
    body, boundary = _multipart_body(pcm_to_wav(pcm, sample_rate))
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Accept": "application/json",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Cache-Control": "no-store",
        },
        method="POST",
    )
    try:
        opener = urllib.request.build_opener(_RejectRedirects())
        with opener.open(request, timeout=max(1, int(timeout_ms)) / 1000.0) as response:
            response_data = response.read(MAX_RESPONSE_BYTES + 1)
            if len(response_data) > MAX_RESPONSE_BYTES:
                raise WhisperServerError(
                    "local whisper.cpp server response exceeded the size limit"
                )
            payload = json.loads(response_data.decode("utf-8"))
    except (
        OSError,
        urllib.error.URLError,
        UnicodeDecodeError,
        json.JSONDecodeError,
    ) as exc:
        raise WhisperServerError("local whisper.cpp server request failed") from exc
    if not isinstance(payload, dict):
        raise WhisperServerError("local whisper.cpp server returned a non-object")
    raw_transcript = " ".join(str(payload.get("text", "")).split())[:500]
    if not raw_transcript:
        raise WhisperServerError("local whisper.cpp server produced no transcript")
    transcript = normalize_stackchan_terms(raw_transcript)
    return WhisperServerResult(
        transcript=transcript,
        raw_transcript=raw_transcript,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--server-url",
        default=os.environ.get("STACKCHAN_STT_SERVER_URL", DEFAULT_WHISPER_SERVER_URL),
    )
    parser.add_argument(
        "--sample-rate",
        type=int,
        default=int(os.environ.get("STACKCHAN_AUDIO_SAMPLE_RATE", "16000")),
    )
    parser.add_argument("--timeout-ms", type=int, default=15_000)
    args = parser.parse_args()
    try:
        result = transcribe_pcm_via_server(
            sys.stdin.buffer.read(MAX_PCM_BYTES + 1),
            args.sample_rate,
            server_url=args.server_url,
            timeout_ms=args.timeout_ms,
        )
    except (ValueError, WhisperServerError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    payload = {
        "transcript": result.transcript,
        "engine": "whisper.cpp-server",
    }
    if result.raw_transcript != result.transcript:
        payload["raw_transcript"] = result.raw_transcript
        payload["transcript_normalized"] = True
    print(json.dumps(payload, separators=(",", ":"), ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
