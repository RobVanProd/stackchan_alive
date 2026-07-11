# Stackchan Hardware Feature Roadmap

This roadmap starts only after the current full-system firmware passes its 60-minute
wall-powered servo acceptance run and is archived as the stable lead. New hardware is
then added one bounded producer at a time so face, wake, bridge, voice, power, and motion
remain independently recoverable.

Current status (2026-07-10): Gate 0 passed with the accepted power-coordinated 60-minute lead.
The release-forensics/Voice V2 diagnostic build subsequently passed short motion-off, servo,
complete streamed-audio, five-second conversation, and audio-driven mouth tests. The next
candidate now compiles body RGB/touch and IMU into the release profile, with bounded telemetry,
power-aware RGB, servo-self-motion filtering, and pickup/shake safety holds. Native firmware
logic is 218/218, the release image builds at 50.7% RAM and 41.2% flash, and the camera-capture
probe builds at 54.1% RAM and 42.2% flash. The host OpenCV worker passes 4/4 tests and its
cascade loads on the isolated Windows runtime. These are software results, not physical acceptance.
Camera capture, real-face detection, active-speaker tracking, touch-zone orientation, IMU thresholds,
and all combined behavior remain unproven until the supervised sequence below passes.

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
display, audio, motion, power, heap, and reset state. Physical inventory is pending.

- Add capability telemetry for the expected body and CoreS3 devices using the official
  StackChan BSP/M5Unified paths where compatible with this firmware.
- Verify the base bus and expected Si12T touch, RGB control, and INA226 devices without
  enabling animations or motion.
- Verify IMU, magnetometer, camera, proximity/light, and microphone availability.
- Record probe success, errors, queue depth, sample time, and task stack/heap in `/debug`.
- Acceptance: 30-minute passive soak with no display, wake, bridge, audio, heap, power,
  or temperature regression.

### Phase 2: IMU And Pickup Awareness

Implementation status: a 25 Hz M5Unified IMU adapter now calibrates stationary gravity and
publishes bounded pickup, putdown, tilt, and shake events. Recent meaningful servo commands
activate a self-motion filter; ordinary servo motion cannot become a handling event, while an
extreme impact can still request a safety hold. Threshold calibration and false-positive
evidence are pending.

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

Implementation status: the candidate includes direct bounded drivers for the Si12T and body
controller, front/middle/back tap, hold, release, and swipe interpretation, and a 12-LED
foundation renderer for mode, mood, speech envelope, touch, and microphone acknowledgement.
Writes are change-only and capped at 20 Hz; normal channel brightness is capped at 52/255 and
protected-mode brightness at 14/255. Physical zone mapping and power evidence are pending.

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

Implementation status: the isolated camera profile configures the GC0308 at QVGA RGB565 with
one PSRAM frame buffer and reuses the managed internal SCCB bus without releasing PMIC/audio
devices. A paired diagnostic endpoint downsamples one frame to 160x120 grayscale. The local
Windows worker detects up to four faces with OpenCV and returns only normalized boxes to the
native-tested active-speaker tracker. Frames are not persisted. Physical initialization,
real-face behavior, capture timing, and combined load remain pending. See `LOCAL_VISION.md`.

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
native-tested. They receive real sound-direction events today, but need a real face-box producer
before camera-guided physical tracking exists.

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

## Supervised Candidate Sequence

1. Flash the release candidate with servos initially stopped and capture `/debug`.
2. Confirm `body_rgb_ready`, `body_touch_ready`, `imu_ready`, and `imu_calibrated`, with camera
   still disabled in the production image.
3. Validate the two-tone wake cue and RGB microphone pulse without speaking or moving.
4. Exercise front, middle, and back tap/hold/swipe while recording raw zone telemetry.
5. With motion stopped, validate pickup, tilt, putdown, and shake safety hold.
6. With body clear and servo risk confirmed, enable motion and prove ordinary animation does
   not create IMU handling events.
7. Run voice, mouth, mood, RGB, touch, and motion together; enforce the existing 50 ms display,
   68 C temperature, VBUS/PMIC, bridge, timeout, and reset gates.
8. Only after that candidate passes, flash the camera probe, set a temporary six-digit pairing
   code, and run the local vision worker. Prove capture with motion off before a separately
   authorized active-speaker motion check. Do not promote the diagnostic image directly.

The production soak must pass `-RequireFinalIntegration`. That profile requires PMIC schema
`axp2101-v2`, valid untruncated `/debug` JSON, RGB/touch/IMU compiled and ready for every good
poll, calibrated IMU, advancing RGB/touch/IMU counters, zero new peripheral I/O failures, zero
unexpected IMU events, and camera disabled in the production image. The separate capture image
must pass `-RequireCameraCapture`; it requires the camera ready/active, advancing real frame
captures, zero new capture failures, and maximum capture time at or below 250 ms. The actual
host loop additionally passes `-RequireCameraHostVision`, requiring paired frame requests and
target updates to advance with zero new host-frame or authentication failures.

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
