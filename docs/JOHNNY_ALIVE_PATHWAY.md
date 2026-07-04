# Johnny Alive Pathway

Source roadmap: `origin/claude/interactive-features-roadmap-mmj5u4:docs/johnnyalive_pathway.md`.

This is the current `main`-branch execution path. The source roadmap branch is older than
`main`, so it is used as a planning reference only. Do not merge that branch directly into
implementation branches without checking for regressions against current firmware, bridge,
voice, evidence, and release tooling.

## North Star

Stackchan: Alive is the character OS layer for Stackchan hardware. It should make a small
tabletop robot feel like it notices, reacts, listens, thinks, and answers in character. The
core rule is layered aliveness: fast reflexes first, deeper understanding later, and no
frozen dead states.

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
| P7 Brain bridge | Firmware bridge parser, native-tested WebSocket frame adapter, native-tested trusted-endpoint owner registry, deterministic host bridge, memory store, privacy model, model guide, character harness, character red-team dry-run harness, model-response bridge path, local runner wrapper, LiteRT-LM wrapper contract, model benchmark harness, engine readiness probe, LAN service scaffold, LAN bridge smoke report, bounded binary PCM upload, local STT command adapter, local TTS mouth-timing adapter with WAV-to-PCM16 normalization, binary TTS audio downlink scaffold, decoded PCM16 speaker handoff, firmware downlink telemetry, no-hardware virtual Stackchan simulator with a pre-arrival device-shell rehearsal, and combined pre-arrival simulation check exist. | Add production firmware Wi-Fi/TCP task, nonvolatile endpoint persistence, and live PC/mobile handoff evidence; run a real Gemma 4 E2B GGUF/LiteRT-LM benchmark report, run the red-team suite with a configured real runner, select/measure real STT/TTS engines, and collect real-device speaker evidence. |
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
   - `bridge/litert_lm_contract_smoke.py` and `tools/run_litert_lm_smoke.cmd` verify the
     two-layer mobile runner contract before a real LiteRT-LM engine is installed.
   - `bridge/engine_probe.py` checks local model, STT, and TTS command readiness and writes
     `engine_probe.json` plus `ENGINE_PROBE.md`. An `unconfigured` report is a setup finding,
     not model speed evidence.
   - `bridge/model_benchmark.py` runs the prompt suite across profiles and writes
     `model_benchmark.json` plus `MODEL_BENCHMARK.md`.
   - The benchmark report now writes `summary.candidate_gate`, including per-profile
     blockers, `ready_profiles`, and `recommended_profile`, so the fastest small model is a
     recorded decision rather than a manual read of raw rows.
   - Next: install/run the selected Gemma 4 E2B target on the host, re-run the engine probe
     with `--run-model-smoke`, and record a non-dry-run benchmark with speed and Character
     Lock pass evidence.

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
   - `bridge/lan_smoke.py` and `tools/run_lan_smoke.cmd` write `LAN_SMOKE.md/json` by
     exercising the actual local TCP/WebSocket handshake, a transcript-backed text turn, a
     fake mic PCM upload, fake STT/TTS, and a PCM16 binary downlink sequence with
     deterministic engines. This is the LAN bridge smoke report gate for PRs before the
     unit arrives.
   - A configured local TTS command can receive response text on stdin and replace the
     deterministic mouth beats with returned TTS metadata.
   - If the TTS command returns `audio_b64`, the TTS adapter canonicalizes playable PCM
     payloads to `pcm16`, decodes valid uncompressed WAV payloads to signed 16-bit mono PCM,
     and the LAN service sends stream metadata plus binary WebSocket chunks. Firmware parses
     the stream metadata, copies the current chunk into a bounded `BridgeClient` buffer
     exposed through bridge outputs, feeds it to the downlink consumer, and accounts chunk
     payloads for telemetry.
   - The downlink consumer can now hand accepted decoded PCM16 chunks to the M5 speaker sink
     when speaker hardware is enabled. Unsupported formats are still transported and counted,
     but they do not claim firmware speaker playback.
   - Selecting/measuring real STT/TTS engines and collecting real-device speaker evidence
     remain the next P7 bridge gates.
   - Do not move real-time face or motion ownership off firmware.

4. Dynamic TTS sidecar path.
   - Bridge streams response text plus TTS-derived envelope/viseme timing.
   - Firmware keeps using the existing mouth-envelope path.
   - Binary audio transport to firmware has a LAN scaffold; generated audio can travel as
     chunks and firmware keeps the current accepted chunk payload available to the output
     handler/downlink consumer. The host TTS adapter decodes valid uncompressed WAV payloads
     to PCM16 for playback. Decoded PCM16 chunks can be submitted to the M5 speaker sink when
     hardware speaker output is enabled; unsupported formats are still accounted but not
     played.
   - Voice-source provenance remains blocking for any consumer-ready build.

5. Virtual hardware proxy.
   - `bridge/hardware_simulator.py` consumes reference, LAN, and binary audio-downlink
     bridge frames and produces firmware-like serial logs plus JSON telemetry.
   - The default simulator run includes `conversation-rehearsal`, which drives virtual wake
     input through the LAN bridge path, checks first-audio latency against the 2.5 s budget,
     verifies mouth frames, and returns to `Ready`.
   - It also includes `conversation-tts-downlink`, which uses a fake WAV-producing local TTS
     command to verify bridge-side WAV-to-PCM16 normalization, binary downlink framing,
     virtual M5 speaker handoff counters, mouth activity, and return to `Ready`.
   - It also includes `conversation-audio-loop`, which uploads bounded fake mic PCM, runs a
     fake local STT command, exercises the Character Lock/model response path, generates fake
     WAV TTS, normalizes it to PCM16 downlink audio, checks virtual speaker counters, and
     returns to `Ready`.
   - The LAN smoke report includes `thinking-latency`, which sends `thinking` immediately on
     `utterance_end`, delays fake TTS, and records per-frame timing so visible thinking is
     proven before slow spoken output finishes.
   - The default simulator run also includes `arrival-rehearsal`, which models virtual
     CoreS3 display ticks, label persistence, tap/hold/BtnA/BtnB/BtnC input mapping, motion
     safety toggles, PCM16 speaker handoff counters, mouth-display activity, and power-cycle
     recovery before the physical unit arrives.
   - It also includes `bridge-kill-recovery`, which aborts an in-flight TTS stream after a
     bridge error, emits one offline fallback prompt, reconnects, speaks a recovery turn, and
     returns to `Ready` without a timeout or parse failure.
   - The `audio-downlink` and `arrival-rehearsal` scenarios now exercise the 4096-byte
     firmware chunk limit with a synthetic decoded PCM16 5000-byte downlink split into
     4096-byte and 904-byte chunks.
   - Simulator JSON and serial-like `[runtime]` logs now include firmware-mirrored
     `bridge_downlink_*` and `bridge_downlink_playback_*` counters, giving arrival-day
     hardware runs a direct no-hardware baseline for downlink streams, completions, chunks,
     bytes, unsupported playback formats, and errors.
   - The `audio-downlink-unsupported` scenario proves a non-PCM16 container is transported
     and accounted without claiming virtual speaker playback.
   - Native firmware tests now enforce the same recovery contract: bridge `error` and
     timeout paths clear open audio-stream state before accepting the next bridge session.
   - `offline-command-fallback` keeps the virtual bridge disconnected while CoreS3 input and
     P4-style command-map events still request packaged prompts, animate the mouth/display,
     and return to idle.
   - `tools/run_hardware_simulation.cmd` writes repeatable reports under
     `output/hardware-sim/`.
   - Evidence packets include `RUN_HARDWARE_SIM_BASELINE.cmd`, which writes the same
     no-hardware proxy report under `simulation/hardware-sim/latest/` for pre-arrival
     comparison without satisfying hardware evidence gates.
   - Evidence packets also include `RUN_SIM_HARDWARE_COMPARE.cmd`, which writes
     `SIM_HARDWARE_COMPARE.md/json` after real display, speech-mouth, speak-all, and bridge
     replay logs exist. It compares serial markers and bridge counters against the simulator
     baseline as an advisory diagnostic, not as promotion evidence.
   - `tools/run_prearrival_sim_check.cmd` writes `PREARRIVAL_SIM_CHECK.md/json` so the
     fastest pre-arrival proxy combines virtual hardware status, LAN bridge smoke report,
     and engine-readiness status.
   - Add `-RunModelBenchmark` after a real runner command is configured to include the full
     model benchmark candidate gate inside the same pre-arrival report.
   - GitHub Actions runs the bridge tests, engine readiness probe, LAN bridge smoke report,
     simulator, and pre-arrival check in the `bridge-tests` job, then uploads engine-probe,
     lan-bridge-smoke, hardware-simulation, and prearrival-simulation-check artifacts for
     each PR/push.
   - This catches bridge ordering, conversation timing, LAN visible-thinking latency, LAN
     STT/TTS audio-loop ordering, LAN TTS downlink, timeout, mouth-frame, input-mapping,
     offline command fallback,
     reboot-recovery, bridge-kill recovery, and binary stream regressions before the physical
     device arrives. It does not
     replace real display, speaker, mic, camera, touch, IMU,
     servo, heat, power, or soak evidence.
   - Hardware-level simulator options remain secondary: Wokwi can run ESP32-S3 / M5Stack
     CoreS3-style Arduino or ESP-IDF sketches, and Espressif QEMU can help with low-level
     ESP-IDF CPU/memory/peripheral debugging, but neither currently replaces this repo's
     maintained virtual Stackchan proxy for the full bridge/display/audio/servo evidence
     path.

6. End-to-end demo gate.
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
