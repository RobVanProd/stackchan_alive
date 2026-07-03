# Stackchan Bridge Protocol

Protocol: `stackchan.bridge.v1`

The bridge is the P7 boundary between the real-time firmware and a LAN companion service. The firmware owns wake/listen/think/speak choreography, face, motion, earcons, and safety. The bridge owns STT, LLM text generation, memory, and dynamic TTS rendering.

Control frames are newline-delimited UTF-8 JSON. Audio upload/download frames will be binary WebSocket frames in a later PR; this first firmware slice only defines the typed control messages and a deterministic parser.

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

Example response:

```json
{"type":"thinking","seq":41}
{"type":"response_start","seq":41,"intent":"happy","arousal":0.62,"valence":0.72,"text":"Hello. I am awake and looking."}
{"type":"audio","seq":41,"env":0.58,"viseme":"ee","duration_ms":20}
{"type":"response_end","seq":41}
```

## Runtime Rules

- Wake-word gating happens before audio leaves the device.
- Firmware must never block face, motion, or intent tasks while waiting for bridge traffic.
- Any `error`, disconnect, or timeout returns to the offline matrix: on-device commands and packaged prompts still work.
- Dynamic voice assets remain subject to `docs/VOICE_PERSONALITY.md` and production voice-source provenance.
