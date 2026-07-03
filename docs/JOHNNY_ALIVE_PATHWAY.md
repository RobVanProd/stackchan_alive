# Johnny Alive Pathway

Source roadmap: `origin/claude/interactive-features-roadmap-mmj5u4:docs/johnnyalive_pathway.md`.

This is the current `main`-branch execution path. The source roadmap branch is older than
`main`, so it is used as a planning reference only. Do not merge that branch directly into
implementation branches without checking for regressions against current firmware, bridge,
voice, evidence, and release tooling.

## North Star

Stackchan should feel like a small tabletop robot that notices, reacts, listens, thinks, and
answers in character. The core rule is layered aliveness: fast reflexes first, deeper
understanding later, and no frozen dead states.

Latency targets from the roadmap remain active:

- Reflex face response: under 150 ms.
- Orient to sound: under 400 ms.
- Wake acknowledgment: under 500 ms.
- End of user speech to first response audio on LAN: under 2.5 s, with visible thinking while waiting.

## Current Status

| Phase | Status on `main` | Next evidence or work |
|---|---|---|
| P1 Ambient life | Implemented in firmware/preview path with face animation artifacts and reduced-motion handling. | Real hardware idle evidence remains required before consumer promotion. |
| P2 Physical senses | Bench commands and emotion/safety responses exist for touch, proximity, pickup, shake, putdown, and tilt. | Real touch/proximity/IMU adapters and hardware video evidence. |
| P3 Sound awareness | Bench sound/noise events, saliency fixtures, and latency telemetry path exist. | Real ES7210 mic capture and on-device direction evidence. |
| P4 Wake/commands | Command-map grammar and bench command path exist. | ESP-SR WakeNet/MultiNet integration and wake-to-earcon latency evidence. |
| P5 Sight | Camera adapter boundary, face-position bench events, and gaze-tracker logic exist. | Real GC0308/ESP-DL face detection and tracking evidence. |
| P6 Voice | Packaged prompt playback, earcons, mouth envelope sidecars, RVC audition samples, and evidence tooling exist. | Production voice-source provenance and real speaker recordings. |
| P7 Brain bridge | Firmware bridge parser, deterministic host bridge, memory store, privacy model, model guide, character harness, model-response bridge path, local runner wrapper, LAN service scaffold, bounded binary PCM upload, local STT command adapter, local TTS mouth-timing adapter, and binary TTS audio downlink scaffold exist. | Measure a real Gemma 4 E2B GGUF/LiteRT-LM runner, select/measure real STT/TTS engines, then wire downlinked chunks into speaker playback. |
| P8 Continuity | Not started as a separate track. | Begins after P1-P7 have real device evidence. |

## Current P7 Sequence

P7 is the active software track because it can advance without waiting on device hardware.
Keep each item independently shippable and package-verified.

1. Model-response bridge path.
   - The reference bridge accepts Character Lock JSON from a local model or fixture.
   - The character harness validates and normalizes it.
   - Safe `memory_write` and `memory_forget` fields update the tiny bridge memory store.
   - The normalized `spoken_text` and `mode` render through `stackchan.bridge.v1`.

2. Local runner wrapper.
   - `bridge/local_runner.py` exposes the primary GGUF target, mobile LiteRT-LM target, and
     fallback E4B target through one prompt-suite wrapper.
   - Real runner commands can be supplied by CLI or environment variable and report elapsed
     milliseconds plus approximate tokens per second.
   - When no runner is configured, the wrapper emits deterministic valid Character Lock JSON
     so bridge demos and firmware bench replay remain repeatable.
   - Next: install/run the selected Gemma 4 E2B target on the host and record harness speed
     and character-lock pass evidence.

3. LAN bridge loop.
   - `bridge/lan_service.py` runs a local WebSocket service around the same frame schema.
   - It accepts control frames: `hello`, `utterance_start`, `utterance_end`, `heartbeat`, and
     `cancel`.
   - It accepts bounded binary PCM frames after `utterance_start`, reports upload telemetry,
     and clears raw PCM at `utterance_end`.
   - Audio-only turns can use a configured local STT command that receives raw signed 16-bit
     mono PCM on stdin and returns transcript text or JSON. If no STT command is configured,
     `utterance_end` still accepts explicit `text` or `transcript` for deterministic tests.
   - On transcript-backed or STT-backed `utterance_end`, the service runs the local runner
     wrapper, validates Character Lock JSON, applies host memory, and streams normalized
     `thinking`, `response_start`, `audio`, and `response_end` frames.
   - A configured local TTS command can receive response text on stdin and replace the
     deterministic mouth beats with returned TTS metadata.
   - If the TTS command returns `audio_b64`, the LAN service sends stream metadata plus binary
     WebSocket chunks. Firmware parses the stream metadata for telemetry.
   - Selecting/measuring real STT/TTS engines and wiring downlinked chunks into speaker
     playback remain the next P7 bridge gates.
   - Do not move real-time face or motion ownership off firmware.

4. Dynamic TTS sidecar path.
   - Bridge streams response text plus TTS-derived envelope/viseme timing.
   - Firmware keeps using the existing mouth-envelope path.
   - Binary audio transport to firmware has a LAN scaffold; generated audio can travel as
     chunks, but firmware speaker playback from those chunks is still future work.
   - Voice-source provenance remains blocking for any consumer-ready build.

5. End-to-end demo gate.
   - Wake or bench start, listen, visible thinking, in-character spoken response, lip-sync,
     graceful return to ambient life.
   - Bridge kill test proves in-character recovery with no freeze or reboot.

## Documentation Rules

- Keep this document updated when a roadmap phase changes status or the next PR changes.
- Keep `docs/BRAIN_MODEL.md` aligned with model targets and harness gates.
- Keep `docs/CHARACTER_LOCK.md` aligned with the validator and bridge response schema.
- Keep `docs/BRIDGE_PROTOCOL.md` aligned with firmware-accepted frame fields.
- Package and verify every new path document so extracted releases carry the same next steps.

## Non-Negotiables

- No direct actuator writes from sensors or bridge code. Everything flows through the existing event/frame path.
- No hardcoded network secrets.
- No audio leaves the device outside a wake-gated bridge session.
- No named character cloning, catchphrases, soundboard training, or unapproved RVC production use.
- No consumer-ready promotion until hardware evidence and production voice-source gates pass.
