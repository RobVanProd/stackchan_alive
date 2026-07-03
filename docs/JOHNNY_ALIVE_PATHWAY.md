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
| P7 Brain bridge | Firmware bridge parser, deterministic host bridge, memory store, privacy model, model guide, and character harness exist. | Connect validated model output to bridge frames, then add local runner and LAN service loop. |
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
   - Add a small wrapper for the primary GGUF target and keep the LiteRT-LM profile visible.
   - Measure approximate tokens per second through the existing harness.
   - Keep the bridge deterministic when no runner is configured.

3. LAN bridge loop.
   - Add a local WebSocket service around the same frame schema.
   - Keep wake-gated audio upload, response timeout, and offline degradation explicit.
   - Do not move real-time face or motion ownership off firmware.

4. Dynamic TTS sidecar path.
   - Bridge streams response text plus audio/envelope/viseme timing.
   - Firmware keeps using the existing mouth-envelope path.
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
