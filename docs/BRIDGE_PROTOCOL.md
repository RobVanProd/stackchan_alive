# Stackchan Bridge Protocol

Protocol: `stackchan.bridge.v1`

The bridge is the P7 boundary between the real-time firmware and a LAN companion service. The firmware owns wake/listen/think/speak choreography, face, motion, earcons, and safety. The bridge owns STT, LLM text generation, memory, and dynamic TTS rendering.

Control frames are newline-delimited UTF-8 JSON. Audio upload/download frames will be binary WebSocket frames in a later PR; this first firmware slice only defines the typed control messages and a deterministic parser.

For hardware bench replay before the LAN companion exists, run:

```powershell
.\tools\send_bridge_replay_demo.cmd -Port COM3
```

Use `-PrintOnly` to inspect the deterministic transcript without opening a serial port, or `-TranscriptPath path\to\bridge_transcript.txt` to replay a custom line-delimited command file. The helper writes `[bridge-replay]` send/readback lines and exercises `bridge hello`, `bridge listening`, `bridge thinking`, `bridge response`, streamed `bridge audio`, `bridge end`, and `status`.

The matching host-side reference lives in `bridge/reference_bridge.py`. It emits the same frames as newline-delimited JSON (`--format jsonl`) or firmware bench commands (`--format bench`) so the bridge protocol, serial replay helper, and firmware parser can be tested from one deterministic transcript. It also exposes the first deterministic persona prompt and local memory context (`--format prompt`, `--user-text`) that the future LAN STT/LLM/TTS service will replace behind the same frame schema.

For P7 model work, the host-side model does not send raw Character Lock JSON to the device.
The bridge validates that JSON with `bridge/character_harness.py`, applies safe memory
writes/forgets on the host, and then emits normalized `response_start` and `audio` frames.
Use `bridge/reference_bridge.py --model-response ...` to exercise that seam without a local
runner.

Use `bridge/local_runner.py` when a local GGUF or LiteRT-LM runner is available, or when a
deterministic runner fallback is enough for firmware/bench testing:

```powershell
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --json
python bridge/reference_bridge.py --format bench --runner-profile gemma4-e2b-gguf --runner-case greeting
```

The wrapper measures approximate tokens per second only when a real command is configured.
Without one, it emits a fixed valid Character Lock response so the firmware bridge path stays
repeatable.

The first LAN service scaffold lives at `bridge/lan_service.py`:

```powershell
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --runner-profile gemma4-e2b-gguf
```

This service is intentionally text-control only. It performs the WebSocket handshake, accepts
device-side JSON text frames, runs the same local runner/validator/memory path on
`utterance_end`, and streams normalized bridge JSON text frames back to the client. Binary
PCM upload and downloaded audio chunks are still future P7 work; binary frames currently
return `binary_audio_not_implemented` instead of blocking the session.

## Device To Bridge

- `hello`: device identity and protocol version.
- `utterance_start`: wake-gated user speech has started.
- `utterance_audio`: binary PCM frame follows on the audio channel.
- `utterance_end`: user speech ended; bridge should begin STT/LLM/TTS work.
- `cancel`: barge-in or local safety state interrupted playback.

Example:

```json
{"type":"hello","protocol":"stackchan.bridge.v1","device_id":"stackchan-001","sample_rate":16000}
```

## Bridge To Device

- `hello`: bridge accepted the session.
- `listening`: bridge is receiving user speech.
- `thinking`: bridge is processing; firmware emits `ThinkingStarted`.
- `response_start`: response metadata is ready; firmware emits `ResponseStarted`.
- `audio`: one mouth/audio timing frame. `env` is normalized `[0,1]`; `viseme` is `neutral`, `ah`, `oh`, or `ee`.
- `response_end`: bridge finished the response; firmware emits `ResponseEnded`.
- `heartbeat`: keepalive; no user-facing output.
- `error`: recoverable bridge failure; firmware emits `Error` and falls back to packaged prompts.
- Timeout: if a connecting/listening/thinking/responding session stops producing bridge traffic for the firmware timeout window, firmware emits the same recoverable `Error` path with `bridge_timeout`.

Example response:

```json
{"type":"thinking","seq":41}
{"type":"response_start","seq":41,"intent":"happy","arousal":0.62,"valence":0.72,"text":"Hello. I am awake and looking."}
{"type":"audio","seq":41,"env":0.58,"viseme":"ee","duration_ms":20}
{"type":"response_end","seq":41}
```

Accepted `intent` values match the `SpeechIntent`/Character Lock vocabulary:
`boot`, `idle`, `attend`, `listen`, `think`, `speak`, `react`, `happy`, `concern`,
`sleep`, `error`, and `safety`. Unknown values degrade to `speak` before any user-facing
output.

## Runtime Rules

- Wake-word gating happens before audio leaves the device.
- Firmware must never block face, motion, or intent tasks while waiting for bridge traffic.
- Any `error`, disconnect, or timeout returns to the offline matrix: on-device commands and packaged prompts still work. Runtime telemetry reports `bridge_timeouts` so evidence logs can prove the stalled-session recovery path ran.
- Dynamic voice assets remain subject to `docs/VOICE_PERSONALITY.md` and production voice-source provenance.
