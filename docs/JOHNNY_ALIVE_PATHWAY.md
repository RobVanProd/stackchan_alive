# Johnny Alive Pathway

Source roadmap: `origin/claude/interactive-features-roadmap-mmj5u4:docs/johnnyalive_pathway.md`.

This document now describes the post-`v0.2.0` hardware baseline. The source roadmap branch is a
historical planning reference only; do not merge it over current firmware, bridge, safety, voice,
or release code.

## North Star

Stackchan Alive is a local-first character OS for a small desk companion that notices, reacts,
listens, thinks, remembers appropriate facts, and answers in character. Fast deterministic
reflexes belong on the robot. Speech, Gemma, research, and privacy-filtered memory belong on the
host. The model never owns actuator, power, pairing, or OTA authority.

Active latency targets:

- reflex face response under 150 ms
- orient to a salient person or sound under 400 ms
- wake acknowledgement under 500 ms
- visible response to a completed utterance under 300 ms
- first audible LAN reply under 3 seconds on the warm local path
- complete TTS/RVC rendering faster than real time with zero truncation

## Release Baseline

`v0.2.0` is the public Apache-2.0 release from commit
`996b7e4b2de0c529a0f0e508891dec33598bf935`. The package includes guarded autonomous motion in the
full firmware and the exact production DirectML RVC model/index. The reference robot evidence and
the owner's release decision are recorded in `FIRST_DEPLOY_STATUS.md`; evidence from another
firmware SHA or assembled unit is not interchangeable.

Working on real hardware:

- smooth procedural face, expression state, RGB choreography, and synchronized speech mouth
- on-device wake phrase and wake-gated microphone capture
- local Whisper to Gemma 4 to DirectML RVC speech over the LAN bridge
- touch, pickup/orientation IMU behavior, power coordination, thermal limits, and forensic counters
- paired camera capture, host YuNet face detection, and face-follow motion
- rollback-safe LAN OTA and local-first recovery behavior
- privacy-filtered durable memory, trusted local facts, bounded local research, and two persona packs

## Visitor Test

| Step | Current result | Remaining work |
|---|---|---|
| 1. Stackchan notices a visitor before they speak. | Partial. Camera presence and face boxes exist, but there is no always-available near-field presence input. | Bring up the confirmed LTR-553 proximity/ambient-light sensor and route presence through bounded reflex events. |
| 2. The visitor greets it and has a conversation. | Pass for wake-gated turns on the reference robot. | Add the conversation-v2 reply window, echo guard, barge-in, and session-only recent turns. |
| 3. Stackchan moves naturally while listening and replying. | Pass for coordinated face, RGB, mouth, and guarded servos. | Tighten active-speaker orientation and perceived-latency choreography. |
| 4. The visitor picks it up and Stackchan knows. | Pass through real IMU pickup/orientation events with forensic accounting. | Add an embodied energy response without weakening power or motion safety. |
| 5. Stackchan notices departure, searches, and sighs. | Not implemented. | Add person-loss confidence, bounded search choreography, and a local sigh/settle response. |

## Phase Status

| Phase | Status after `v0.2.0` | Next evidence or work |
|---|---|---|
| P1 Ambient life | Working on hardware: procedural face, blink/saccade/breathing, mode transitions, RGB flow, reduced motion, and guarded autonomous body motion. | Continue character-motion tuning without exceeding the strict 50 ms display gate. |
| P2 Physical senses | Touch, RGB, and IMU pickup/orientation are implemented and exercised on hardware. | Implement LTR-553 proximity and ambient-light input; keep microSD optional. |
| P3 Sound awareness | Dual-mic capture and on-device wake work on hardware. | Add evidence-backed sound-direction estimation and fuse it with camera confidence. |
| P4 Wake/commands | On-device wake, acknowledgement cues, bounded capture, bridge uplink, and local fallback are working. | Conversation v2 must preserve wake-gated entry and deterministic close conditions. |
| P5 Sight | Paired camera frames, host YuNet detection, and face-follow movement work on the reference robot. | Improve tracking speed, active-speaker selection, and person-loss choreography. |
| P6 Voice | Production DirectML RVC, complete speaker playback, mouth sync, and phrase streaming work on hardware. | Instrument end-to-end stage timing and add interruption-safe barge-in. |
| P7 Brain bridge | Real Wi-Fi bridge, Whisper, Gemma 4, local research, trusted facts, privacy-filtered memory, production voice, and recovery tooling are integrated. | Improve memory retrieval relevance and expose typed live robot state to the character prompt. |
| P8 Continuity | Started: durable filtered facts, persona packs, robot embodiment telemetry, and camera continuity exist. | Conversation sessions, persona hot-swap, person loss, energy state, and community pack discovery. |

## Sequenced Post-Release Work

1. Conversation v2 and barge-in.
   - One onboard wake opens one typed conversation lease.
   - Confirmed playback completion plus an acoustic tail opens a bounded reply window.
   - At most one follow-up may be pending; no hidden transcript backlog.
   - Exit phrase, silence, bridge loss, safety state, owner loss, or turn limit closes the session.
   - A conversation lease never grants or refreshes actuator motion.

2. LTR-553 proximity and ambient light.
   - Add a deterministic I2C adapter, readiness/failure telemetry, and native tests.
   - Use proximity for fast presence reflexes and ambient light for display/RGB adaptation.
   - Do not infer identity from proximity and do not make it a boot dependency.

3. Perceived latency and person awareness.
   - Record wake, capture end, STT, model, research, TTS first audio, playback start, and completion.
   - Begin face/RGB/body acknowledgement within 300 ms while deeper work continues.
   - Fuse camera and sound confidence, then add bounded search-and-sigh behavior after person loss.

4. Embodied energy and platform work.
   - Map honest PMIC/battery state into sleepy/charging/ready character state.
   - Add runtime persona hot-swap, a community pack index, OTA stable/beta channels, and a linear
     first-30-minutes quickstart.

## Evidence Rules

- Keep observed facts separate from hypotheses, especially for black screens, resets, voltage,
  thermal behavior, and network probe timeouts.
- Preserve the exact firmware SHA for every physical qualification.
- Use fast contributor gates for ordinary host/persona changes: native tests, bridge tests,
  simulator, and short smoke. Reserve full exact-image physical soak gates for release promotion.
- Never turn an isolated HTTP timeout into a robot failure when live debug recovers and the bridge
  socket remains established.

## Non-Negotiables

- No direct actuator writes from sensors, the bridge, or Gemma.
- No hardcoded secrets or raw private recordings in release artifacts.
- No audio leaves the device outside a wake or active reply-window lease.
- No persistent raw transcript history by default.
- No proximity, camera, microSD, network, or model dependency may freeze the local face.
- No display change may weaken the strict 50 ms frame gate.
