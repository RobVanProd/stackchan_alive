# Stackchan Hardware Feature Roadmap

This roadmap records the bounded integration path used after the full-system firmware passed its
60-minute wall-powered servo acceptance and was archived as a stable lead. Hardware producers were
then added one at a time so face, wake, bridge, voice, power, and motion stayed independently
recoverable. The status paragraphs distinguish current implementation from remaining promotion
evidence; the numbered design bullets remain useful when adapting the software to another unit.

Current status (2026-07-12): Gates 0-5 shipped in the Apache-2.0 `v0.2.0` release identified in
`FIRST_DEPLOY_STATUS.md`. The exact release image passed formal no-motion, short actuator, and
one-hour all-feature actuator qualifications; the one-hour result was `76/76` after `3601 s` with
`706/706` good polls and zero reset, motion-timeout, power, camera, or terminal IMU failures. The
owner accepted the subsequent interaction-aware run after more than five hours and explicitly
waived the remaining duration for `v0.2.0`; it is release evidence, not a formal eight-hour pass.

Wake, full reply audio, synchronized mouth motion, power-coordinated servos, flowing RGB, touch,
pickup/orientation events, authenticated camera capture, YuNet face acquisition, and bounded
horizontal following have all been exercised on the reference robot. The host bridge also carries
a bounded allowlisted embodiment snapshot for Gemma. Remaining evidence is deliberately narrower:
the ordered body-zone/gesture promotion report, the operator-approved wake/follow camera report,
multi-person active-speaker selection and production voice hash tracking. Phase 6 recognition
and calibrated proximity behavior remain future work. Post-release `main` now contains a bounded
LTR-553 raw proximity/ambient-light adapter, but it is not physically calibrated or promoted as a
presence feature. The public Apache-2.0 package excludes private pairing material and includes the
owner-authorized active production voice model and index.

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

Implementation status: telemetry is present for body RGB/touch, IMU, camera capture, bridge,
display, audio, motion, power, heap, and reset state. The current exact image kept RGB, touch, IMU,
and camera capture/host vision ready throughout its formal one-hour all-feature actuator pass with
zero terminal peripheral failures. A dedicated ordered body-sensor report remains a separate
consumer-promotion artifact; its absence does not mean the integrated hardware has not run. The
post-release LTR-553 adapter adds raw proximity and ALS channel values, saturation, readiness,
retry, recovery, and failure accounting. It builds successfully but remains unflashed and its
near/far thresholds are disabled until desk measurements establish a defensible calibration.

- Add capability telemetry for the expected body and CoreS3 devices using the official
  StackChan BSP/M5Unified paths where compatible with this firmware.
- Verify the base bus and expected Si12T touch, RGB control, and INA226 devices without
  enabling animations or motion.
- Verify IMU, magnetometer, camera, proximity/light, and microphone availability.
- Record probe success, errors, queue depth, sample time, and task stack/heap in `/debug`.
- Acceptance: 30-minute passive soak with no display, wake, bridge, audio, heap, power,
  or temperature regression.

### Phase 2: IMU And Pickup Awareness

Implementation status: a 25 Hz M5Unified IMU adapter calibrates stationary gravity and publishes
bounded pickup, putdown, tilt, and shake events. Atomic M5Unified snapshots use yielding bounded
retry backoff, isolated exhaustion accounting, and terminal failure only after three consecutive
exhausted windows. Recent meaningful servo commands activate a self-motion filter; ordinary servo
motion cannot become a handling event, while an extreme impact can still request a safety hold.
The exact one-hour pass recorded zero read exhaustions and terminal failures, and real external
handling events have been detected. The ordered pickup/tilt/putdown/shake promotion report remains
pending.

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

Implementation status: the installed exact candidate includes direct bounded drivers for the Si12T
and body controller, front/middle/back tap, hold, release, and swipe interpretation, and a 12-LED
foundation renderer for mode, mood, speech envelope, touch, and microphone acknowledgement.
Writes are change-only and capped at 20 Hz; normal channel brightness is capped at 52/255 and
protected-mode brightness at 14/255. Mode and emotional base colors crossfade independently
from the responsive breathing, speech, touch, and wake overlays. Native coverage bounds every
ordinary character-mode transition to a maximum 16-channel step per 50 ms frame; error/safety
response remains intentionally faster. The operator accepted the flowing RGB transitions, and the
exact one-hour integrated pass kept RGB and touch ready with zero terminal I/O failure. Durable
front/middle/back and tap/hold/forward-swipe/backward-swipe counters plus the last decoded zone,
gesture, and timestamp make the physical mapping gate independently auditable. The dedicated
ordered zone/gesture report is still required for consumer promotion.

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

Implementation status: the current exact image configures the GC0308 at QVGA RGB565 with
one PSRAM frame buffer and reuses the managed internal SCCB bus without releasing PMIC/audio
devices. A paired diagnostic endpoint downsamples one frame to 160x120 grayscale. The local
Windows worker detects up to four faces with OpenCV and returns only normalized boxes to the
native-tested active-speaker tracker. Frames are not persisted. Physical initialization and capture
timing are proven, and hash-pinned YuNet has physically acquired a real face across center, left,
right, loss, and reacquisition positions. A supervised horizontal follow was visually accepted as
correct but slow. Camera capture and host vision remained ready during the exact one-hour
all-feature actuator pass; the corrected eight-hour run keeps a `300000 us` single-frame ceiling,
zero new capture/authentication failures, and advancing paired frames/target updates strict. The
dedicated operator camera report remains pending. See `LOCAL_VISION.md`.

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

Implementation status: bounded multi-face selection, microphone-azimuth matching, smoothing,
target-switch resistance, confidence decay, and reply-time target hold are implemented and
native-tested. The earlier generic audio adapter was mono and therefore could not provide physical
azimuth. The current image reuses the wake task's true interleaved ES7210 stereo capture and
estimates a bounded direction from cross-channel sample delay. Physical single-person face
acquisition and horizontal servo following are proven. The audio power handoff preserves low-duty
tracking during microphone capture, and dedicated wake capture is incremental so the intent task
continues camera/gaze work while listening. A consistent operator-approved full wake/listen/reply
follow report and multi-person active-speaker selection remain unpassed; the unattended soak proves
service continuity and timing, not that behavioral gate.

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

Implementation status: identity recognition and fused-presence behavior are planned only. The
current release detects and tracks faces but does not identify people or enroll identities. A
post-release telemetry-only LTR-553 driver exists, but it does not yet emit presence behavior or
claim calibrated ambient lux. Do not advertise recognition or proximity behavior as a current
feature until physical calibration and qualification are complete.

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

## Optional 64 GB microSD

The installed 64 GB card is optional capacity, never a boot or safety dependency. Intended
uses are bounded diagnostic bundles, explicitly requested camera enrollment assets, cached
voice/model assets, and owner-triggered backups. The normal memory store remains host-side and
must continue working when the card is absent.

M5Stack documents a 16 GB maximum for the CoreS3 microSD slot. The installed 64 GB SDXC card is
therefore outside the supported hardware envelope and remains optional/experimental even if the
board can initialize it. The current ESP32-S3 FatFs build also has exFAT disabled, so an accepted
card must be FAT32. Provisioning is destructive and must use a separate guarded formatter, not a
normal runtime command:

1. Probe the physical card without writing, print its card class, and require a reported capacity
   in the 58-70 GB range.
2. Print card type, sector count, capacity, and the exact erase confirmation phrase.
3. Require an operator confirmation that the old movies may be erased.
4. Invoke the board-local FatFs format path, remount, and verify the persistent readiness marker
   with a write/read test.
5. Reflash the validated release firmware and confirm it boots normally with and without the
   card. Do not make wake, face, bridge, voice, memory, or safety behavior depend on this
   unsupported-capacity card.

Never store continuous raw audio, unattended camera history, credentials, Wi-Fi secrets, or
unbounded conversation transcripts on the card. Face recognition, if enabled later, stores the
minimum owner-approved enrollment representation and provides list/delete controls.

The guarded build is `stackchan_sd_provisioner`. It refuses to build unless
`STACKCHAN_SD_FORMAT_BUILD_TOKEN=ERASE_STACKCHAN_64GB_MOVIES` is explicitly set, then still
refuses at runtime unless the card capacity is in range and the serial console receives
`FORMAT STACKCHAN 64GB ERASE MOVIES` within 60 seconds. A successful run writes and reads
`/STACKCHAN_SD_READY.txt`. This image must never be distributed as normal robot firmware.
The initial card-class/capacity output is a non-destructive checkpoint; formatting is not attempted
until the exact phrase is received.

## Live Embodiment For The Brain

The robot's existing bridge heartbeat now carries a compact state packet for mode, emotional
energy, power source, battery/charge state, motion, speaker activity, pickup/orientation, touch,
camera availability/target freshness, and temperature. `RobotEmbodimentState` accepts only
typed allowlisted fields, converts them to bounded descriptive lines, and expires the snapshot
after 15 seconds. Unknown heartbeat text cannot enter the model prompt. The prompt labels this
section as telemetry data, keeps it separate from user text, and asks Gemma to use it only when
relevant rather than reciting diagnostics unprompted.

This is sensory context, not authority. Gemma cannot use the snapshot to enable motion, camera,
power rails, recording, or memory writes. Firmware safety coordinators remain authoritative.
Physical acceptance requires a real heartbeat reaching the production bridge and a supervised
conversation that correctly reflects a changed state such as pickup, charging, or camera
availability without inventing unavailable senses.

Post-release source also implements a read-only embodied-energy layer. Valid battery percentage
enters `low` at 20% and `critical` at 10%; recovery requires 25% and 15% respectively so a noisy
reading cannot flap the character. Valid charging plus external power takes priority as
`charging`; invalid telemetry is `unknown`. The state smoothly biases fatigue, arousal, valence,
and focus before face/motion composition, but it never forces Sleep mode and has no path into
charging, rail, servo, speaker, thermal, or power-floor policy. `/debug` exposes state, transition
and entry counters, interpreted battery percentage, source flags, and the active fatigue/arousal
biases. The bridge heartbeat carries only the allowlisted state label to the expiring Gemma
embodiment context. This source has native and public-build qualification only until the exact
image is installed and physically observed through charge/discharge transitions.

## Supervised Candidate Sequence

1. Verify the exact installed firmware SHA/source binding and OTA confirmation with servos stopped,
   then capture `/debug`. Do not rebuild or substitute another image mid-sequence.
2. Confirm `body_rgb_ready`, `body_touch_ready`, `imu_ready`, `imu_calibrated`,
   `camera_capture_ready`, and paired host-vision readiness in the same integrated image.
3. Validate the two-tone wake cue and RGB microphone pulse without speaking or moving.
4. Exercise front, middle, and back tap/hold/swipe while recording raw zone telemetry.
5. With motion stopped, validate pickup, tilt, putdown, and shake safety hold.
6. With body clear and servo risk confirmed, enable motion and prove ordinary animation does
   not create IMU handling events.
7. Prove authenticated real-frame capture and YuNet target advancement with motion off, then run a
   separately authorized bounded horizontal-follow check under diffuse light.
8. Run wake/listen/reply, mouth, mood, RGB, touch, camera, and motion together; enforce the 50 ms
   display, 68 C temperature, VBUS/PMIC, bridge, timeout, camera, and reset gates.
9. Run the exact image through the one-hour actuator acceptance and 28,800-second all-feature soak,
   then verify motion, servo rail, and torque are stopped.

Capture the focused touch/IMU gate with `tools\body_sensor_validation.ps1`. Use a new evidence
root and capture the required steps in the exact order printed by each command: baseline while
untouched and resting; front/middle/back taps; front hold; forward/backward swipes; then pickup,
tilt, putdown, and shake. Motion, servo rail, and torque must remain off throughout. For example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\body_sensor_validation.ps1 `
  -Mode Capture -Step baseline `
  -EvidenceRoot output\hardware-evidence\final-integration\body-sensor-validation-<timestamp>
```

Repeat with the next printed `-Step` after performing exactly one requested physical action, then
run `-Mode Check -Json`. The formal report requires the named zone/gesture and IMU counters to
advance between adjacent captures, requires pickup/putdown state transitions, rejects peripheral
I/O failures, and enforces connected bridge/network, the 50 ms display gate, 68 C temperature
gate, 4.4 V VBUS floor, and motion/rail/torque off for every snapshot.

The production soak must pass `-RequireFinalIntegration`. That profile requires PMIC schema
`axp2101-v2`, valid untruncated `/debug` JSON, RGB/touch/IMU compiled and ready for every good
poll, calibrated IMU, advancing RGB/touch/IMU counters, zero new peripheral I/O failures, zero
unexpected terminal IMU failures, plus camera capture and authenticated host vision in the same
release candidate. Interaction-aware runs may explicitly allow accounted external handling events;
that does not allow read failure or sustained exhaustion. `-RequireFinalIntegration` therefore
implies both `-RequireCameraCapture` and `-RequireCameraHostVision`: camera frames and paired target
updates must advance with zero new capture or authentication failures. The current exact-image
characterization uses a `300000 us` maximum single capture after one healthy observed frame reached
`268122 us`; this is separate from the unchanged `50000 us` display-frame limit. Camera-only
profiles remain available for short diagnostic isolation runs.

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
