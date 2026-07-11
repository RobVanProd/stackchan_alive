# Stackchan Hardware Feature Roadmap

This roadmap starts only after the current full-system firmware passes its 60-minute
wall-powered servo acceptance run and is archived as the stable lead. New hardware is
then added one bounded producer at a time so face, wake, bridge, voice, power, and motion
remain independently recoverable.

Current status (2026-07-10): Gate 0 passed with the accepted power-coordinated 60-minute lead.
The release-forensics/Voice V2 diagnostic build subsequently passed short motion-off, servo,
complete streamed-audio, five-second conversation, and audio-driven mouth tests. The remaining
firmware work begins at Phase 1 below; camera, IMU, touch, RGB, active-speaker tracking, and face
recognition are intentionally not folded into the release candidate all at once.

## Confirmed Hardware

M5Stack's product documentation and StackChan BSP confirm the following hardware in this
unit:

| Location | Hardware | Intended Alive behavior |
|---|---|---|
| StackChan body | Three-zone Si12T touch panel | Pet/tap/hold interactions and explicit attention |
| StackChan body | Two rows totaling 12 RGB LEDs | Quiet state, listening, thinking, speaking, and fault cues |
| CoreS3 | BMI270 accelerometer/gyroscope plus BMM150 magnetometer | Pickup, putdown, shake, tilt, and orientation |
| CoreS3 | GC0308 640x480 camera | Face detection, person tracking, and opt-in recognition |
| CoreS3 | Dual microphones through ES7210 | Wake, voice activity, and sound-direction estimates |
| CoreS3 | LTR-553 proximity and ambient-light sensor | Near-person and room-light context |
| StackChan body | IR transmit/receive and NFC | Later interaction expansion; not on the first integration path |

Official references:

- <https://docs.m5stack.com/en/guide/hobby_kit/stackchan>
- <https://docs.m5stack.com/en/base/StackChan_Body>
- <https://github.com/m5stack/StackChan-BSP>
- <https://github.com/m5stack/StackChan>

## Architectural Rules

1. Sensors publish bounded events; they never write servos, draw the face, or control
   power directly.
2. `PowerCoordinator` remains the authority for servo rail, speaker, camera, RGB, and
   other optional loads. Every peripheral must have an explicit idle/off state.
3. The face task keeps its current priority and frame budget. Sensor work must yield,
   be rate-limited, and use queues with fixed capacity.
4. Motion continues through the existing intent, safety, rate-limit, session, thermal,
   and power gates. Tracking cannot bypass calibrated servo limits.
5. Raw camera frames stay local by default. Identity recognition is opt-in, enrolled by
   the owner, and stores the minimum necessary representation. No unattended raw-image
   archive is part of the design.
6. Each phase must pass independently before the next peripheral is enabled in the lead
   firmware. A combined feature cannot be used to excuse a regression in a lower layer.

## Integration Order

### Gate 0: Freeze The Stable Runtime

- Pass the strict 60-minute wall-powered full-system servo soak.
- Preserve firmware binary, ELF, source/config snapshot, SHA256, formal checker output,
  and post-stop charge-handoff evidence.
- Keep the display hard stop at 50,000 us, temperature limit at 68 C, and existing VBUS,
  PMIC, bridge, audio, and motion invariants.

Result: passed. The accepted rollback is
`output\firmware-leads\power-coordinator-priority2-accepted-60min-20260710-003026.zip`; the
currently flashed diagnostic candidate and its staged physical evidence are archived separately
under `output\firmware-candidates\forensics-validated-20260710-204449.zip`.

### Phase 1: Passive Hardware Inventory

- Add capability telemetry for the expected body and CoreS3 devices using the official
  StackChan BSP/M5Unified paths where compatible with this firmware.
- Verify the base bus and expected Si12T touch, RGB control, and INA226 devices without
  enabling animations or motion.
- Verify IMU, magnetometer, camera, proximity/light, and microphone availability.
- Record probe success, errors, queue depth, sample time, and task stack/heap in `/debug`.
- Acceptance: 30-minute passive soak with no display, wake, bridge, audio, heap, power,
  or temperature regression.

### Phase 2: IMU And Pickup Awareness

- Sample the IMU in a low-priority, bounded sensor task and calibrate stationary bias.
- Produce `pickup`, `putdown`, `tilt`, `shake`, and orientation events through the existing
  `SensorAdapter`/intent boundary.
- Make shake and unsafe pickup states request the existing motion safety hold. They do
  not write servo torque directly.
- Use hysteresis and minimum dwell times so vibration from the servos or speaker does not
  create repeated false pickup events.
- Acceptance: orientation and pickup video evidence, false-trigger test during speech
  and servo movement, then a 60-minute combined soak.

### Phase 3: Body Touch And RGB Feedback

- Map the three physical touch zones to named events after observing the actual body
  orientation; do not guess left/right labels in code.
- Support tap, hold, and release with debounce and stuck-touch recovery.
- Add a small RGB state renderer for `idle`, `listening`, `thinking`, `speaking`, and
  `fault`. Changes are event-driven and rate-limited; no high-rate animation loop.
- RGB brightness is capped and load-shed by `PowerCoordinator` during marginal input,
  speech startup, servo movement, or thermal protection.
- Acceptance: all touch zones, cue visibility, power telemetry under worst-case RGB,
  and a 60-minute touch/RGB/voice/motion soak.

### Phase 4: Camera Face Detection

- Begin at low resolution and a conservative 5-10 FPS with fixed PSRAM frame buffers.
- Detect face boxes locally and publish only bounded `x`, `y`, `size`, `confidence`, and
  timestamp data to the existing `CameraAdapter` and `GazeTracker` path.
- Face presence must first move only the pupils. Servo tracking remains disabled until
  camera timing, heap, and power are stable.
- Add stale-frame timeout, frame-drop counters, capture/detection timing, PSRAM telemetry,
  and a clean camera-off recovery path.
- Acceptance: face acquire/loss/reacquire evidence, no raw-frame retention, no display
  frame over 50 ms, and a 60-minute camera-on soak.

### Phase 5: Look Toward The Speaker

- Estimate sound direction from the dual microphones on-device and publish a bounded
  azimuth/confidence event. Validate the actual microphone geometry before assigning
  left/right signs.
- Use sound direction to choose an area of interest; use the camera to select a face in
  that area. Audio alone may request a small orienting glance, never an unlimited turn.
- The tracker uses deadbands, acceleration limits, confidence decay, and target-switch
  hysteresis so Stackchan does not hunt or snap between people.
- The motion coordinator remains the only servo writer and may decline orientation when
  power, temperature, session, body-safety, or calibration gates are not satisfied.
- Acceptance target: audible wake cue under 500 ms, initial orient under 400 ms when safe,
  stable active-speaker selection, and no motion during a safety hold.

### Phase 6: Opt-In Face Recognition And Fused Presence

- Separate face detection (someone is present) from recognition (an enrolled person).
- Run identity matching on the PC brain first unless measured CoreS3 evidence shows an
  on-device model fits without harming the real-time firmware. Detection and tracking
  must continue safely when the PC brain is unavailable.
- Enrollment requires an explicit owner action. Store embeddings/identity metadata rather
  than a continuous image history, provide list/forget controls, and define retention in
  `PRIVACY.md` before enabling the feature.
- Fuse face track, sound direction, wake state, proximity, and recent interaction into one
  attention target with confidence and expiry. Identity never grants actuator authority.
- Acceptance: enrolled/unknown distinction, delete-and-retest evidence, multi-person
  active-speaker tests, bridge-loss fallback, and an overnight combined soak.

## Evidence Required Per Phase

Every phase must preserve:

- exact firmware SHA256 and source/config snapshot;
- native tests plus the full embedded build;
- pre-run and post-run `/debug` snapshots;
- display frame timing, heap/PSRAM, task stack, chip temperature, VBUS/PMIC, bridge,
  audio, motion, and new-peripheral counters;
- automatic safe-stop behavior for any motion-enabled run;
- a focused functional recording and a strict soak summary.

The final experience is one fused attention loop: local wake acknowledges immediately,
sound direction suggests where to look, camera tracking finds the person, the existing
motion coordinator turns safely, the face maintains eye contact, touch and pickup produce
fast reflexes, and the PC brain supplies deeper conversation and opt-in identity memory.
The robot remains alive locally if any higher layer is absent.
