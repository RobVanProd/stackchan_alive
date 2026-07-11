# Local Camera And Active-Speaker Vision

Stackchan's first camera path is an isolated diagnostic profile, not part of the production
firmware. It keeps face detection on the owner's PC while the CoreS3 performs bounded capture
and the existing firmware tracker owns attention selection. This avoids an Arduino-to-ESP-IDF
framework migration during the release-stability gate.

## Data Boundary

- The camera probe exposes one 160x120 grayscale PGM frame at a time.
- Both frame fetch and target update require the same configured six-digit pairing code.
- The host accepts only a literal private or loopback HTTP robot address.
- Frames are held in memory for one detection step and are never written by the worker.
- The host returns at most four normalized `x`, `y`, `size`, and `confidence` boxes.
- The firmware combines those boxes with local sound direction through
  `ActiveSpeakerTracker`; the host never receives microphone audio from this path.
- The production image compiles both camera capture and the host-vision HTTP endpoints out.

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

OpenCV's frontal-face cascade is loaded lazily. The production bridge does not import OpenCV
and does not gain a new dependency.

## Supervised Physical Run

1. Stop motion and confirm servo rail and torque are off.
2. Flash `stackchan_camera_probe` only after the production candidate has passed its shorter
   integration check.
3. Over the serial bench path set a temporary digits-only pairing code, for example
   `pairing code 123456`. Use a new code for each evidence run.
4. Start the worker from the repository root:

```powershell
C:\stackchan_vision_venv\Scripts\python.exe bridge\vision_service.py `
  --robot-url http://192.168.1.238:8789 `
  --pairing-code 123456 --interval-seconds 1 --duration-seconds 180
```

5. First prove camera acquire/loss/reacquire and pupil tracking with motion disabled.
6. Only with a present operator, clear body, and fresh servo-risk confirmation may the normal
   motion coordinator be enabled for bounded look-toward-speaker validation.
7. Run the camera soak with both `-RequireCameraCapture` and
   `-RequireCameraHostVision`. The latter requires authenticated frame requests and target
   updates to advance with zero new host-frame or pairing failures.
8. Stop motion, clear the temporary pairing code with `pairing clear`, and reflash the
   production candidate. The diagnostic image is never promoted directly.

The physical pass still needs visible evidence that a real human face is acquired and that
sound-aware selection chooses the current speaker. Advancing counters alone cannot prove the
behavior looks correct.
