# Local Camera And Active-Speaker Vision

Stackchan's first camera path is paired, local, host-assisted vision. It keeps face detection on
the owner's PC while the CoreS3 performs bounded capture and the firmware tracker owns attention
selection. The same path is available in the secret-free `stackchan_release_full` image; the
`stackchan_camera_probe` profile remains the token-enabled lab/OTA variant. This avoids an
Arduino-to-ESP-IDF framework migration during the release-stability gate.

## Data Boundary

- The camera probe exposes one 160x120 grayscale PGM frame at a time.
- The Stackchan enclosure mounts the CoreS3 camera upside down. The diagnostic profile applies
  sensor-level horizontal mirror plus vertical flip so host coordinates are upright and remain
  consistent with gaze/head tracking; `/debug` reports the sensor PID and both orientation results.
- Both frame fetch and target update require the same configured six-digit pairing code.
- The host accepts only a literal private or loopback HTTP robot address.
- Frames are held in memory for one detection step and are never written by the worker.
- The host returns at most four normalized `x`, `y`, `size`, and `confidence` boxes.
- The camera diagnostic reuses the wake task's existing interleaved ES7210 stereo samples.
  A bounded cross-correlation estimator converts inter-microphone sample delay into an
  azimuth/confidence hint, and `ActiveSpeakerTracker` combines that hint with face boxes. The
  host never receives microphone audio from this path.
- Display-only and servo-calibration images compile camera transport out. The full-online image
  exposes frame/target endpoints only after a per-device pairing code is configured.

This path performs face **detection**, not identity recognition. Enrollment, embeddings,
names, and retained images remain disabled until a separate opt-in privacy and deletion flow
passes review.

## Host Setup

The pinned Windows runtime is isolated from the voice and production bridge environments:

```powershell
py -3.12 -m venv C:\stackchan_vision_venv
C:\stackchan_vision_venv\Scripts\python.exe -m pip install -r bridge\requirements-vision.txt
cd bridge
C:\stackchan_vision_venv\Scripts\python.exe -m unittest test_vision_service -v
```

The local worker loads OpenCV Zoo's hash-pinned YuNet ONNX face detector lazily. YuNet is
more robust than the earlier frontal Haar cascade for side positions and uneven room light.
The production bridge does not import OpenCV and does not gain a new dependency. The worker
verifies the model SHA-256 before use; model source and MIT license provenance are recorded in
`bridge/models/README.md`.

## Supervised Physical Run

### Eye-Safe Lighting

YuNet does not require a bright lamp aimed at the operator. Use ordinary diffuse room light or
indirect reflected light, keep lamps out of the operator's direct line of sight, and avoid staring
into a phone light, work light, or exposed high-output LED. Do not increase illumination merely to
force a detector lock; first move within 2-4 feet, face the camera, reduce backlighting, and let the
camera exposure settle. Pause the run immediately for eye discomfort, afterimages, headache, or
visual strain. Resume only after the operator feels recovered, with softer lighting and a short
motion-off acquisition check before any servo test.

1. Stop motion and confirm servo rail and torque are off.
2. Use `stackchan_release_full` for a public serial install or `stackchan_camera_probe` for a
   private token-enabled OTA lab image, only after the shorter integration check passes.
3. Set a temporary digits-only pairing code. The serial bench path accepts
   `pairing code 123456`. For an OTA-only diagnostic build, set the private build
   environment variable `STACKCHAN_PAIRING_SHORT_CODE` to a new six-digit code before
   building `stackchan_camera_probe`; remove it before rebuilding production firmware.
   Never commit or archive the temporary code.
4. Start the worker from the repository root:

```powershell
C:\stackchan_vision_venv\Scripts\python.exe bridge\vision_service.py `
  --robot-url http://192.168.1.238:8789 `
  --pairing-code-file output\private\camera-pairing-code.txt `
  --interval-seconds 1 --duration-seconds 180
```

Prefer `--pairing-code-file` so the temporary digits never appear in the Windows process command
line or captured shell logs. The file must contain exactly six ASCII digits, with an optional
trailing newline, and must remain under the private output area. `--pairing-code` remains available
for disposable manual labs but must not be used in release evidence.

5. First prove camera acquire/loss/reacquire and pupil tracking with motion disabled. Speak once
   from the physical left and once from the physical right; verify
   `sr_wake_stereo_direction_lag_samples`, `camera_sound_azimuth_norm`, and
   `camera_sound_direction_updates` move in opposite directions. If physical sign is reversed,
   rebuild only the camera profile with `STACKCHAN_CAMERA_AUDIO_DIRECTION_INVERT=1`.
6. Only with a present operator, clear body, and fresh servo-risk confirmation may the normal
   motion coordinator be enabled for bounded look-toward-speaker validation.
   From the repository root, use the strict supervised runner after the worker reports a stable
   face lock:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\camera_follow_wake_validation.ps1 `
  -OperatorPresent -BodyClear -ConfirmServoRisk
```

   Say `Hey Stackchan` once, then ask `What is your name?` once when the runner prints
   `CAMERA FOLLOW ACTIVE`. It records half-second evidence, requires incremental microphone
   capture and camera gaze output to coexist, and always calls `/motion-stop` in cleanup.
   After the run, record the operator's visual verdict without editing JSON by hand:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools\complete_camera_follow_wake_validation.ps1 `
  -EvidenceRoot <evidence-root> -VisualVerdict pass `
  -OperatorNotes "Following visibly continued while the microphone captured."
```

   The completion tool cannot convert failed telemetry into a pass and refuses evidence without
   verified motion-stop, full incremental capture, bridge-turn, source-commit, and firmware pins.
7. Run the camera soak with both `-RequireCameraCapture` and
   `-RequireCameraHostVision`. The latter requires authenticated frame requests and target
   updates to advance with zero new host-frame or pairing failures.
8. Stop motion, clear the temporary pairing code with `pairing clear`, and reflash the
   production candidate. The diagnostic image is never promoted directly.

The physical pass still needs visible evidence that a real human face is acquired and that
sound-aware selection chooses the current speaker. Advancing counters alone cannot prove the
behavior looks correct.

## Current Physical Evidence (2026-07-11)

The physical GC0308 initializes on its first attempt with sensor PID `155`. The host worker has
completed hundreds of authenticated frame fetches and target updates without pairing or frame
errors, and YuNet has repeatedly acquired a real face across center, left, right, loss, and
reacquisition positions. Captures remain ephemeral 160x120 grayscale frames. The face task stays
near 20 FPS while the worker is active.

A 50-second supervised horizontal run at
`output\hardware-evidence\final-integration\camera-follow-anti-windup-supervised-20260711-184445`
passed all electrical and telemetry gates, and the operator reported that horizontal following
looked correct, though slow. A later pitch-stability run passed the same strict gates but failed
the visual behavior gate. Its trace showed a `21.159 s` motion-output suppression: bridge voice
state was treated as audio load, the power coordinator removed the servo rail, and camera targets
continued while the body could not move. That is an observed policy conflict, not a detector or
voltage failure.

The corrected power handoff keeps low-duty camera following available during microphone capture,
listening, and thinking; only real speaker playback plus its bounded cooldown preempts motion.
While a face lock is active, camera attention owns the servo pose instead of mixing in autonomous
body drift. The first handoff run proved that microphone capture retained the rail and torque, but
also showed that the old 96-chunk dedicated capture loop blocked the intent task for about 4.8
seconds and stopped camera gaze updates. Capture is now incremental: one chunk is serviced per
intent cycle while camera events, gaze, RGB, and character state continue to advance. Debug exposes
the incremental active flag, attempted/submitted chunks, service calls, and maximum service time.

Native logic passes `239/239`, the complete bridge/vision suite passes `205/205`, and the installed
private OTA candidate SHA-256 is
`890ae99a55ca89bae3694d60287359d9f2a21814d1ad1b15e99a1e98e6df8ac2`. Final visual
camera-follow through wake, listening, and reply remains pending. The latest attempt correctly held
motion off because the local worker had no fresh face lock; it must not be counted as a behavioral
pass or failure. The focused wake/follow runner is covered by a 24-point static safety contract,
and the complete PowerShell release/evidence suite passes `49/49` with the camera validator,
visual-review guard, and consumer-promotion contract included.

Do not claim multi-person active-speaker selection yet. Single-person visual following is the
current gate; stereo direction remains noisy and requires a separate multi-person acceptance run.
