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
| 1. Stackchan notices a visitor before they speak. | Partial. Camera presence and face boxes exist. Post-release `main` can read raw LTR-553 proximity/light telemetry, but presence behavior is deliberately disabled. | Measure the physical sensor, set hysteretic thresholds, and qualify the bounded reflex without making it a boot dependency. |
| 2. The visitor greets it and has a conversation. | Pass for wake-gated turns on the reference robot. Post-release source includes an opt-in reply-window command, voice-activity-ended follow-up capture, four-turn session-only context, and concurrent host cancellation of Gemma/TTS. | Qualify that exact image on hardware, then add onboard over-speaker detection and echo rejection. |
| 3. Stackchan moves naturally while listening and replying. | Pass for coordinated face, RGB, mouth, and guarded servos. | Tighten active-speaker orientation and perceived-latency choreography. |
| 4. The visitor picks it up and Stackchan knows. | Pass through real IMU pickup/orientation events with forensic accounting. Post-release source also shapes character energy from validated battery/charge state without power authority. | Physically qualify the exact energy-aware image across charging and battery thresholds. |
| 5. Stackchan notices departure, searches, and sighs. | Implemented in post-release source as a bounded hold, two-sided search, procedural visual/body sigh, settle, and immediate reacquisition cancel path. | Qualify the exact image with real camera loss/reacquisition and tune timing from observed behavior. |

## Phase Status

| Phase | Status after `v0.2.0` | Next evidence or work |
|---|---|---|
| P1 Ambient life | Working on hardware: procedural face, blink/saccade/breathing, mode transitions, RGB flow, reduced motion, and guarded autonomous body motion. | Continue character-motion tuning without exceeding the strict 50 ms display gate. |
| P2 Physical senses | Touch, RGB, and IMU pickup/orientation are exercised on hardware. A telemetry-first LTR-553 adapter, failure accounting, and native tests are implemented after `v0.2.0`. | Flash and measure raw proximity/light values, calibrate presence hysteresis, and keep microSD optional. |
| P3 Sound awareness | Dual-mic capture and on-device wake work on hardware. | Add evidence-backed sound-direction estimation and fuse it with camera confidence. |
| P4 Wake/commands | On-device wake, acknowledgement cues, bounded capture, bridge uplink, and local fallback are working. Opt-in Conversation v2 has a tested host-to-firmware reply window plus source-level speech endpointing with expiry, disconnect cancellation, and maximum-duration fallback. | Physically qualify the opt-in path while preserving wake-gated entry and deterministic close conditions. |
| P5 Sight | Paired camera frames, host YuNet detection, and face-follow movement work on the reference robot. Post-release source adds deterministic person-loss phase telemetry and bounded search/sigh/settle choreography. | Physically qualify departure/reacquisition, then improve tracking speed and active-speaker selection. |
| P6 Voice | Production DirectML RVC, complete speaker playback, mouth sync, phrase streaming, normalized per-stage latency evidence, source-level voice-activity-ended follow-up capture, and host/companion cancellation work. | Physically tune endpoint thresholds, then qualify onboard over-speaker barge-in and echo rejection. |
| P7 Brain bridge | Real Wi-Fi bridge, Whisper, Gemma 4, local research, trusted facts, privacy-filtered memory, production voice, and recovery tooling are integrated. | Improve memory retrieval relevance and expose typed live robot state to the character prompt. |
| P8 Continuity | Started: durable filtered facts, persona packs, a hash-pinned local community pack index, runtime bridge persona selection, robot embodiment telemetry, camera continuity, source-level person-loss choreography, and hysteretic embodied-energy state exist. | Conversation qualification and coherent firmware asset hot-swap. |

## Sequenced Post-Release Work

1. Conversation v2 and barge-in.
   - One onboard wake opens one typed conversation lease.
   - Confirmed playback completion plus an acoustic tail opens a bounded reply window.
   - At most one follow-up may be pending; no hidden transcript backlog.
   - Exit phrase, silence, bridge loss, safety state, owner loss, or turn limit closes the session.
   - A conversation lease never grants or refreshes actuator motion.
   - Done in post-release source: authoritative speaker-drain evidence produces a bounded firmware
     reply-window command; parser limits, wrap-safe scheduling, expiry, and bridge-loss cancellation
     are covered by native and host tests.
   - Done in post-release source: completed turns enter a four-turn, non-persistent session ring
     only after authoritative playback completion; reply capture ends after sustained speech and
     trailing silence, with the old 4.8-second maximum as fallback.
   - Done in post-release source: the LAN reader remains responsive during Gemma/TTS; explicit
     cancel and companion barge-in terminate the process tree, drop unsent audio, and leave
     cancelled model memory/session history uncommitted.
   - Next: exact-image hardware qualification plus onboard overlap detection, speaker cancellation,
     and echo rejection so a person can interrupt the physical robot while it is talking.

2. LTR-553 proximity and ambient light.
   - Done in post-release source: deterministic I2C adapter, readiness/failure telemetry, raw
     proximity/ALS accounting, and native tests.
   - Done in post-release source: a passive calibration CLI captures labeled far/near `/debug`
     samples, rejects unhealthy/saturated evidence, and emits non-writing hysteresis suggestions
     only when robust distributions separate.
   - Next: collect physical desk measurements with `LTR553_CALIBRATION.md` before enabling
     hysteretic proximity reflexes or calibrated display/RGB adaptation.
   - Do not infer identity from proximity and do not make it a boot dependency.

3. Perceived latency and person awareness.
   - Record wake, capture end, STT, model, research, TTS first audio, playback start, and completion.
   - Begin face/RGB/body acknowledgement within 300 ms while deeper work continues.
   - Done in post-release source: camera loss enters observable hold/search/sigh/settle phases,
     freezes internal motion targets when actuator output is unavailable, and cancels immediately
     on face reacquisition.
   - Next: qualify it on hardware and fuse sound confidence into the search direction.

4. Embodied energy and platform work.
   - Done in post-release source: map validated battery percentage and charging/external-power
     state into hysteretic `unknown`/`ready`/`charging`/`low`/`critical` character energy, share
     only the allowlisted label with Gemma, and keep all power/safety authority out of the model.
   - Next: physically qualify charge/discharge threshold transitions on the exact image.
   - Done in post-release source: deterministic validation-backed local community pack index with
     content hashes, Apache-2.0 metadata, invalid-pack quarantine, and explicit capability flags.
   - Done in post-release source: validated bridge persona selection works at startup and between
     turns, rejects path-like/invalid IDs and active-turn races, and clears cross-character session
     context. Embedded face/earcon/prompt assets remain truthfully build-time.
   - Done in post-release source: OTA stable/beta manifests bind each enabled channel to an exact
     version, source commit, HTTPS URL, byte count, and SHA-256; the LAN uploader can require a
     matching local artifact without adding automatic download or flashing.
   - Next: coherent firmware asset hot-swap and publishing the first permanent channel manifest.
     The linear first-30-minutes quickstart is already present in `RELEASE_QUICKSTART.md`.

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
