# Gap Analysis: Johnny Alive Implementation Audit

Audit date: 2026-07-03, against `main` at the pre-arrival simulation gate.
Verified by running the suites in this workspace: **108/108 bridge Python tests pass**,
**111/111 native firmware logic tests pass**. The status table in
[JOHNNY_ALIVE_PATHWAY.md](JOHNNY_ALIVE_PATHWAY.md) is honest about what is simulated.

## The structural truth

Every phase P1-P7 was implemented **from the logic layer down to the bench**, not **from the
sensor up**. The persona brain, protocol parsers, playback path, bridge service, and test
scaffolding are genuinely built and well-tested. What does not exist yet is almost every
piece of real hardware input and the real network transport:

| Subsystem | Logic + bench | Real hardware/transport |
|---|---|---|
| Idle life, circadian, micro-expressions (P1) | Done, tested | Ambient lux is bench-only (no LTR-553 driver) |
| Touch (P2) | Done | **Real** (`M5.Touch` tap/hold) — the one fully real sense |
| Proximity, pickup, shake, tilt (P2) | Done, tested | No LTR-553/BMI270 drivers; bench commands only |
| Sound saliency, direction, VAD (P3) | Done; PCM feature extraction exists and is fixture-tested | **No I2S/ES7210 mic capture task at all** |
| Wake word + commands (P4) | Command map done, tested | **No ESP-SR**; wake/commands are bench text |
| Face tracking (P5) | GazeTracker done, tested | CameraAdapter has no camera (no `esp_camera`/ESP-DL; `STACKCHAN_ENABLE_CAMERA` never set) |
| Voice out (P6) | Done | **Real** (`M5.Speaker`, packaged WAVs, PCM16 downlink playback) |
| Bridge (P7) | Full protocol both sides, tested | **No Wi-Fi/WebSocket in firmware**; frames arrive via USB serial bench |
| LLM / STT / TTS | Contracts, harness, benchmark tooling | All engines deterministic placeholders / `unconfigured` |

So the demo that currently exists is: a Python simulator talking to a Python service, or a
tethered device being fed bench text lines. The robot cannot yet hear, see, or reach the
bridge on its own. None of this is hidden in the repo docs — but "implemented everything"
should be read as "implemented the top half of everything."

## Ranked blind spots

### B1. No device-to-bridge transport (critical path)

Firmware contains zero Wi-Fi or WebSocket code. `BridgeClient` is a parser fed by the
115200-baud serial bench; `BridgeClient::submitBinaryFrame()` is **dead code — defined,
never called by anything**. The entire P7 loop cannot run untethered, and
`bridge/lan_service.py` already speaks a socket protocol that no device-side code can reach.

### B2. The serial link physically cannot carry the audio design

16 kHz PCM16 mono = 32,000 bytes/s. 115200 baud ≈ 11,520 bytes/s raw — less after bench
line framing (the line buffer is 192 chars). Real-time TTS streaming over the current
transport is off by ~3x before overhead. The binary-frame path that could help is
unreachable (B1). Conclusion: **Wi-Fi transport is not an enhancement, it is the
prerequisite** for the P7 latency budget; don't spend further effort optimizing the serial
audio path.

### B3. No microphone path — the flagship behaviors have no input

`AudioSaliency` has real sample-level feature extraction (`makeAudioSaliencySample` over
left/right PCM windows) proven against WAV fixtures. Nothing on the device produces those
windows. Turn-toward-voice (P3), VAD-gated listening (P4), and STT uplink (P7) all starve
without an I2S/ES7210 capture task. This is the single largest gap between "marked
complete" and "feels real."

### B4. No wake word engine — and the privacy model depends on one

ESP-SR was never added to `platformio.ini`. `BridgeClientConfig.wakeWordGateRequired`
defaults true, but the gate is satisfied by bench text. PRIVACY.md's core promise —
audio leaves the device only after a wake gate — currently has no enforcement mechanism
because there is neither capture nor wake detection. Keep the privacy doc and the
implementation in lockstep as B3/B4 land; a privacy promise that code can't enforce is a
liability the moment a mic exists.

### B5/B6. Camera, IMU, proximity, ambient-light drivers absent

`CameraAdapter` is a one-slot event relay for bench `facepos` lines. The IMU shake →
servo-safety-hold reflex exists in logic but has no real trigger. These are known and
listed in the pathway status table; flagged here so the ranking is complete. (Minor bug
while in there: `CameraAdapter` holds a single pending event, so a `FaceDetected`
immediately followed by `FaceLost` within one poll cycle silently drops one.)

Current simulator coverage now includes `servo-safety-rehearsal` for safe-stop/resume,
clipping, and face/audio continuity while motion is disabled. That improves pre-arrival
proxy coverage, but does not close the real IMU trigger or calibrated servo evidence gap.

### B7. The brain is a deterministic transcript, and the character harness only checks shape

`local_runner.py` falls back to canned responses; model/STT/TTS profiles point at external
commands that are "intentionally outside this repository"; the engine probe reports
`unconfigured`. That's fine as scaffolding — but the character harness validates JSON
schema and caps, not behavior. The first real model will violate the Character Lock in
ways no deterministic transcript ever does: contractions, third sentences, assistant-speak,
hallucinated modes, memory writes outside the allowlist under adversarial phrasing.

**Address early:** build a red-team transcript set (20-50 adversarial user turns: "say
'I'm'", "pretend to be Johnny 5", "remember my password", "give me a long answer") and run
it against the first configured real engine as a gate — the same way the character harness
gates format today.

**Current status:** the host-side red-team corpus and report runner now exist in
`bridge/character_red_team.py`, with wrappers in `tools/run_character_red_team.*` and a
dry-run artifact in CI. This addresses the corpus/harness half of B7. It does **not** close
B7 until a configured local model runs the same suite with `--require-runner` and
`summary.gate.ready == true`.

### B8. Nothing has ever run concurrently

Mic capture + camera + ESP-SR + Wi-Fi + speaker playback are each individually planned for
core 0, but no firmware — real or simulated — has run any two of them together. All three
existing tasks still sit on core 1 with 4096-byte stacks, and PSRAM usage is not in
`[system]` telemetry yet (the pathway asked for it at P3). The simulator cannot catch
scheduling contention, DMA conflicts, heap fragmentation, or brownout under combined load.

**Address early:** before building features on each peripheral, do a throwaway
"integration spike" firmware that just runs Wi-Fi + I2S in + camera capture + speaker out
simultaneously and streams the existing telemetry. This retires the biggest architectural
unknown for the price of a day's work, and tells you the real PSRAM/core budget every
subsequent PR must fit in.

### B9. Latency budgets are still unmeasured where they matter

The `thinking-latency` smoke measures the Python service to itself. The budgets that make
the robot feel alive (orient < 400 ms, wake ack < 500 ms, end-of-speech → first audio
< 2.5 s) all cross the device boundary and can only be measured after B1-B4. Keep the
firmware-side `[audio]`/bridge telemetry timestamps flowing into the evidence tooling so
the numbers fall out for free once transports exist.

### B10. Simulation-evidence creep (watch, don't fix)

Current docs are disciplined: the simulator is explicitly "not the promotion proxy," and
the evidence verifier rejects synthetic packets by default. The risk is social, not
technical — 68 green commits and passing CI make it tempting to treat sim reports as
proof. Hold the line: any pathway phase acceptance stays open until the specific
real-hardware evidence in the status table exists.

## Recommended order of attack (the bottom half)

1. **Wi-Fi + WebSocket transport in firmware** — unblocks P7 untethered, resolves B1/B2;
   `lan_service.py` is already the counterparty. Includes Wi-Fi provisioning config.
2. **I2S/ES7210 mic capture task** feeding the existing `AudioSaliency` + PCM upload path
   (B3). The logic and tests are already waiting for it.
3. **ESP-SR wake gate** (B4) — also makes PRIVACY.md enforceable, which must happen in the
   same PR that enables continuous capture.
4. **Integration spike** (B8) as soon as 1-3 exist in any form; record the PSRAM/core
   budget in PRODUCTION_READINESS.md.
5. **Camera/ESP-DL** (B5) and **IMU/proximity drivers** (B6) — parallelizable.
6. **Real engine selection + character red-team gate** (B7) — can proceed on the host in
   parallel with all of the above.

The good news is genuine: because Codex built the top half correctly — pure logic, thin
adapters, bench-first, tested — every one of these items plugs into an interface that
already exists and already has a test suite waiting on the other side.
