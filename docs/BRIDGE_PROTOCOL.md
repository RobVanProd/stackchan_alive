# Stackchan Bridge Protocol

Protocol: `stackchan.bridge.v1`

The bridge is the P7 boundary between the real-time firmware and a LAN companion service. The firmware owns wake/listen/think/speak choreography, face, motion, earcons, and safety. The bridge owns STT, LLM text generation, memory, and dynamic TTS rendering.

Firmware bench replay uses newline-delimited UTF-8 JSON. The LAN bridge service uses
WebSocket text frames for control, binary WebSocket frames for uploaded PCM, and optional
binary WebSocket frames for downlinked TTS audio chunks. Current firmware has a native-tested
`BridgeWebSocketTransport` adapter that builds the upgrade request, encodes masked client
frames, decodes unmasked server text/binary frames, and routes those frames into
`BridgeClient`. Firmware also has a native-tested `BridgeEndpointRegistry` for the
multi-endpoint trust/health/active-owner rules and a native-tested `BridgeEndpointControl`
adapter that parses endpoint hello, endpoint heartbeat, `claim_brain`, `release_brain`,
`owner_status`, `trusted_endpoints`, `forget_endpoint`, and `capability_update` frames into
bounded JSON responses. Firmware also has a native-tested `BridgeEndpointStore` that
serializes trusted endpoints as `stackchan.bridge-endpoints.v1` JSON and an ESP32
Preferences backend for nonvolatile storage. The running CoreS3 firmware now initializes the
registry/store/control objects at boot, loads persisted trusted endpoints, attaches the
store to endpoint control, periodically updates endpoint health, exposes endpoint telemetry
on `[runtime]`, and can print endpoint-control responses over the serial bench path. It
still needs the production Wi-Fi/TCP task to feed these adapters, send their responses over
the network, and collect live PC/mobile handoff evidence. Once frames reach
`BridgeClient`, firmware parses downlink stream
metadata, copies each accepted chunk into a bounded buffer, exposes the current payload
through `BridgeClientOutput`, feeds that payload to the firmware downlink consumer for
checksum/telemetry validation, and still uses `audio` response frames for mouth/envelope
timing. When speaker hardware is enabled, the downlink consumer can hand accepted decoded
PCM16 chunks to the M5 speaker sink; WAV/RVC decoding is still a bridge-side responsibility
before downlink.

For hardware bench replay before the LAN companion exists, run:

```powershell
.\tools\send_bridge_replay_demo.cmd -Port COM3
```

Use `-PrintOnly` to inspect the deterministic transcript without opening a serial port, or `-TranscriptPath path\to\bridge_transcript.txt` to replay a custom line-delimited command file. The helper writes `[bridge-replay]` send/readback lines and exercises `bridge hello`, `bridge listening`, `bridge thinking`, `bridge response`, streamed `bridge audio`, `bridge end`, and `status`.

The matching host-side reference lives in `bridge/reference_bridge.py`. It emits the same frames as newline-delimited JSON (`--format jsonl`) or firmware bench commands (`--format bench`) so the bridge protocol, serial replay helper, and firmware parser can be tested from one deterministic transcript. It also exposes the first deterministic persona prompt and local memory context (`--format prompt`, `--user-text`) that the future LAN STT/LLM/TTS service will replace behind the same frame schema.

When hardware is unavailable, `tools/run_hardware_simulation.cmd` runs a virtual Stackchan
proxy over the same bridge frames and writes serial-like logs plus JSON telemetry for frame
ordering, conversation rehearsal, mouth timing, binary TTS audio stream accounting, timeout
checks, offline command fallback, and a pre-arrival device-shell rehearsal. The conversation
rehearsal runs virtual wake input through the LAN bridge output path, checks first-audio
latency against the 2.5 s budget, verifies mouth frames, and returns to `Ready`. The
`conversation-tts-downlink` scenario adds a fake WAV-producing local TTS command and proves the
host path decodes it to PCM16 before binary downlink and virtual speaker handoff. The
device-shell rehearsal covers virtual display ticks, label persistence, CoreS3
tap/hold/BtnA/BtnB/BtnC input mapping, motion safety toggles, PCM16 speaker handoff counters,
mouth-display activity, and power-cycle recovery. The servo-safety rehearsal separately
checks virtual servo attach, pitch/yaw and yaw-velocity clipping, safe-stop blocking, and
continued face/audio rendering while motion is held. The audio-downlink simulation also
mirrors `bridge_downlink_playback_*` telemetry, including the unsupported-format path. The
default simulation also includes
`bridge-kill-recovery`, which aborts an in-flight TTS stream after a bridge error, emits the
offline fallback prompt, reconnects, and proves the next response can return to `Ready`, plus
`offline-command-fallback`, which keeps the bridge disconnected while local commands still
trigger packaged prompts and mouth motion. It is still a proxy; real device media and soak
evidence remain separate gates.

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

This service performs the WebSocket handshake, accepts device-side JSON text frames, accepts
binary PCM frames after `utterance_start`, runs the same local runner/validator/memory path on
`utterance_end`, and streams normalized bridge JSON text frames back to the client. Audio-only
turns can use a configured local STT command:

The Android companion uses the same `stackchan.bridge.v1` family. The target architecture is
multi-endpoint: a PC bridge and an Android bridge may both be trusted, but only one endpoint
is the active brain owner allowed to receive wake-gated audio and dynamic response ownership.
Other trusted endpoints may remain connected as settings/diagnostics observers. The draft app
contract, including PC Brain Mode, Mobile Brain Mode, `claim_brain`, `release_brain`,
`settings_get`, `settings_set`, and `forget_endpoint`, lives in
[ANDROID_COMPANION_SPEC.md](ANDROID_COMPANION_SPEC.md).

The maintained socket-level smoke check is `tools/run_lan_smoke.cmd`:

```powershell
.\tools\run_lan_smoke.cmd
```

It writes `output/lan-smoke/latest/LAN_SMOKE.md/json`, starts a temporary local WebSocket
server, performs the real handshake, validates the text-turn frame order, sends fake mic
PCM through fake STT/TTS, checks `audio_stream_start`, binary chunks, and
`audio_stream_end` before `response_end`, measures the `thinking-latency` scenario, and
exercises `endpoint-controls` for PC/Android endpoint ownership, settings, diagnostics, and
trusted endpoint forgetting.
For LAN socket clients, `thinking` is emitted immediately on `utterance_end` before slow
STT/model/TTS work runs; the final response suppresses the duplicate `thinking` frame.

```powershell
$env:STACKCHAN_STT_COMMAND = "python path\to\local_stt.py"
python bridge/lan_service.py --stt-command "python path\to\local_stt.py"
```

The STT command receives raw signed 16-bit mono PCM on stdin with
`STACKCHAN_AUDIO_SAMPLE_RATE`, `STACKCHAN_AUDIO_FORMAT=s16le_mono`, and
`STACKCHAN_AUDIO_BYTES` in its environment. It must print plain transcript text or JSON with
`transcript`, `text`, or `spoken_text`. If no command is configured, audio-only turns return
`stt_not_implemented`; include `text` or `transcript` on `utterance_end` to test the runner
path while bypassing STT.

Response mouth timing can use a configured local TTS command:

```powershell
$env:STACKCHAN_TTS_COMMAND = "python path\to\local_tts.py"
python bridge/lan_service.py --tts-command "python path\to\local_tts.py" --tts-voice rvc-bright
```

The TTS command receives response text on stdin with `STACKCHAN_TTS_TEXT_BYTES`,
`STACKCHAN_TTS_VOICE`, and `STACKCHAN_TTS_OUTPUT=stackchan.tts-metadata.v1` in its
environment. It must print metadata JSON with either compact `beats` or
speech-envelope-sidecar-style `frames`. The service maps those beats into existing `audio`
frames. If the command includes `audio_b64`, the TTS adapter canonicalizes already-playable
`pcm16`, `s16le`, `raw16`, or `pcm_s16le` payloads to `pcm16` and decodes valid
uncompressed WAV payloads to signed 16-bit mono PCM before downlink. The service then sends
`audio_stream_start`, binary WebSocket chunks, and `audio_stream_end` around the same
response. Other formats are still transported and accounted but are not played by the
downlink sink.

## Device To Bridge

- `hello`: device identity and protocol version.
- `endpoint_hello`: companion/bridge endpoint identity, kind, priority, and capabilities.
- `claim_brain`: trusted endpoint requests active brain ownership.
- `release_brain`: active owner releases the brain; the bridge may promote another trusted endpoint.
- `owner_status`: request the current active brain owner state.
- `trusted_endpoints`: list trusted PC/mobile/dev endpoints.
- `forget_endpoint`: remove one trusted endpoint and require pairing before it reconnects as trusted.
- `settings_get`: read safe bot/bridge settings by domain.
- `settings_set`: write safe settings with version conflict detection; safety-locked settings are rejected.
- `diagnostics_request`: read bridge/model/audio diagnostics.
- `capability_update`: update capabilities for a trusted endpoint.
- `utterance_start`: wake-gated user speech has started.
- `utterance_audio`: optional development text frame with `pcm_b64`; normal LAN use sends binary PCM WebSocket frames after `utterance_start`.
- `utterance_end`: user speech ended; bridge should begin STT/LLM/TTS work. A `text` or `transcript` field bypasses STT and is useful for deterministic tests.
- `cancel`: barge-in or local safety state interrupted playback.

Example:

```json
{"type":"hello","protocol":"stackchan.bridge.v1","device_id":"stackchan-001","sample_rate":16000}
{"type":"utterance_start","seq":41,"sample_rate":16000}
<binary WebSocket frame: signed 16-bit mono PCM>
{"type":"utterance_end","seq":41,"transcript":"Hello Stackchan."}
```

## Bridge To Device

- `hello`: bridge accepted the session.
- `endpoint_hello_result`: endpoint trust/capability registration result.
- `owner_status`: active brain owner, owner kind, health state, and trusted endpoint count.
- `trusted_endpoints_result`: trusted endpoint registry snapshot.
- `forget_endpoint_result`: endpoint removal result.
- `settings_snapshot`: versioned safe settings snapshot.
- `settings_result`: safe settings write result or version/safety-lock rejection.
- `diagnostics_snapshot`: bridge/model/audio diagnostics.
- `capability_update_result`: updated endpoint capabilities.
- `listening`: bridge is receiving user speech.
- `thinking`: bridge is processing; firmware emits `ThinkingStarted`.
- `response_start`: response metadata is ready; firmware emits `ResponseStarted`.
- `audio_stream_start`: optional metadata for a following binary TTS audio downlink.
- Binary WebSocket frame: optional raw TTS audio chunk. Format is declared by the preceding
  `audio_stream_start` frame. Firmware accepts chunks up to 4096 bytes, copies the chunk
  payload into a `BridgeClient`-owned buffer, exposes `payloadBytes` and the current payload
  pointer on `BridgeClientOutput`, records chunk count, byte count, and a rolling checksum,
  then hands the payload to the downlink consumer. The downlink consumer validates payload
  pointer/length, records its own accepted bytes/chunks/checksum telemetry, rejects chunks
  without an active stream, and rejects mismatched totals at `audio_stream_end`. If
  `STACKCHAN_ENABLE_SPEAKER` is enabled and the stream format is decoded signed 16-bit mono
  PCM (`pcm16`, `s16le`, `raw16`, or `pcm_s16le`), accepted chunks are also submitted to the
  M5 speaker sink with separate `bridge_downlink_playback_*` runtime telemetry. Unsupported
  formats increment playback-unsupported telemetry but do not fail the validated stream.
- `audio_stream_end`: optional end marker for the TTS audio downlink.
- `audio`: one mouth/audio timing frame. `env` is normalized `[0,1]`; `viseme` is `neutral`, `ah`, `oh`, or `ee`. If a local TTS command is configured, these frames come from its returned beat metadata.
- `response_end`: bridge finished the response; firmware emits `ResponseEnded`.
- `heartbeat`: keepalive; no user-facing output.
- `error`: recoverable bridge failure; firmware aborts any open audio stream, emits `Error`,
  and falls back to packaged prompts.
- Timeout: if a connecting/listening/thinking/responding session stops producing bridge
  traffic for the firmware timeout window, firmware aborts any open audio stream and emits
  the same recoverable `Error` path with `bridge_timeout`.

Example response:

```json
{"type":"thinking","seq":41}
{"type":"response_start","seq":41,"intent":"happy","arousal":0.62,"valence":0.72,"text":"Hello. I am awake and looking."}
{"type":"audio_stream_start","seq":41,"format":"pcm16","sample_rate":22050,"audio_bytes":4096,"chunk_bytes":4096,"chunks":1}
<binary WebSocket frame: decoded signed 16-bit mono PCM>
{"type":"audio_stream_end","seq":41,"audio_bytes":4096,"chunks":1}
{"type":"audio","seq":41,"env":0.58,"viseme":"ee","duration_ms":20}
{"type":"response_end","seq":41}
```

Accepted `intent` values match the `SpeechIntent`/Character Lock vocabulary:
`boot`, `idle`, `attend`, `listen`, `think`, `speak`, `react`, `happy`, `concern`,
`sleep`, `error`, and `safety`. Unknown values degrade to `speak` before any user-facing
output.

## Runtime Rules

- Wake-word gating happens before audio leaves the device.
- In the multi-endpoint bridge model, wake-gated audio may stream only to the active brain
  owner. Handoff must release open streams cleanly before another endpoint claims ownership.
- Trusted endpoint forgetting must revoke auto-connect and require pairing again before that
  endpoint can own the brain or write settings.
- Firmware must never block face, motion, or intent tasks while waiting for bridge traffic.
- The bridge upload buffer is bounded and raw PCM is cleared at `utterance_end` or `cancel`.
  A configured local STT command may receive the one-turn PCM on stdin. Host memory may store
  summaries and validated memory fields, never raw audio.
- A configured local TTS command may receive response text on stdin and return mouth timing
  metadata plus optional `audio_b64`. The LAN service can downlink that audio as binary
  WebSocket chunks. The TTS adapter decodes valid uncompressed WAV payloads and canonicalizes
  playable raw PCM formats to signed 16-bit mono `pcm16` before downlink. Firmware records
  stream metadata, keeps the current payload bytes in a bounded `BridgeClient` buffer exposed
  through `BridgeClientOutput`, feeds those bytes to the firmware downlink consumer, accounts
  chunks, and can play decoded PCM16 downlink chunks through the M5 speaker sink when speaker
  hardware is enabled. The no-hardware simulator includes a `conversation-tts-downlink`
  scenario that exercises this path with a WAV-producing fake TTS command.
- Any `error`, disconnect, or timeout returns to the offline matrix: on-device commands and
  packaged prompts still work. Open binary audio streams are discarded during recovery, so
  stale stream metadata cannot block the next bridge session. Runtime telemetry reports
  `bridge_timeouts` so evidence logs can prove the stalled-session recovery path ran.
- Dynamic voice assets remain subject to `docs/VOICE_PERSONALITY.md` and production voice-source provenance.
