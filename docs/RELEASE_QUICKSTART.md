# Stackchan Alive Release Quickstart

Use this from an extracted release package when the device arrives.

## Before Connecting Hardware

1. Install Python, PlatformIO, and GitHub CLI if this machine will verify or publish releases.
2. Confirm the body is clear and the servos are not mechanically blocked.
3. Keep the first run display-only. Servo calibration is a separate, supervised step.

## Remote Review Link

From an extracted release package:

```powershell
.\tools\share_release.cmd -CloudflareTunnel -DownloadCloudflared
```

This serves the release ZIP, ZIP SHA256 sidecar, preview image, expression sheet, video, quickstart, release notes, readiness report, and checksums. It downloads a local `cloudflared.exe` under `output\tools` only when `cloudflared` is not already installed.
The public URL is also saved as `output\share\<version>\PUBLIC_URL.txt`, and the share folder includes `STOP_SHARING.cmd` to stop the local server and tunnel.
Before sending the URL, verify the handoff page and public assets:

```powershell
.\tools\verify_share_release.cmd -RequirePublicUrl
```

From a source checkout, pass the release version:

```powershell
.\tools\share_release.cmd -Version <version> -CloudflareTunnel -DownloadCloudflared
```

## Prepare The Arrival Packet

From inside the extracted release folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Replace `COM3`, `Your Name`, and `STACKCHAN-001` with the device serial port, operator name, and physical device identifier.

This command verifies the package, dry-runs the display-only flash command, and creates an evidence packet under `output\hardware-evidence\`.

## First Device Commands

Open the newest evidence packet folder and run:

```powershell
.\RUN_PACKAGE_VERIFY.cmd
.\RUN_DISPLAY_ONLY.cmd
```

Only after display-only firmware boots cleanly and the body is on a clear surface, run:

```powershell
.\RUN_SERVO_CALIBRATION.cmd
```

The servo command includes `-ConfirmServoRisk` because it can move the physical body.

During bring-up, run:

```powershell
.\RUN_PROGRESS_CHECK.cmd
```

This lists missing observation fields, logs, serial markers, media evidence, calibration updates, and unchecked gates before the final promotion verifier.

Import photos, videos, and speaker recordings through the packet helper so the files are validated and hashed:

```powershell
.\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg
.\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav
```

Use `-Type Audio` for phone videos of the speaker so `.mp4` or `.mov` recordings land under `audio\` instead of `photos\`.

Before promotion review, complete the audio evidence record generated in the packet:

```powershell
notepad .\AUDIO_REVIEW.md
```

Save at least one real-device speaker recording under `audio\`. The strict verifier accepts `.wav`, `.mp3`, `.m4a`, `.aac`, `.mp4`, `.mov`, or `.webm`, but generated source WAVs alone do not count as target-speaker evidence.

## Promotion Evidence

Before calling the release consumer-ready, save:

- Display-only serial log.
- Servo-calibration serial log.
- 30-minute soak log.
- Photos or video of the display and motion behavior.
- Completed `AUDIO_REVIEW.md`.
- Real-device speaker recording saved under `audio\`.
- Calibration changes in `data\calibration.yaml`.

Then run:

```powershell
.\RUN_EVIDENCE_VERIFY.cmd
```

After that passes, run the full consumer promotion gate:

```powershell
.\RUN_CONSUMER_PROMOTION_CHECK.cmd
```

That final gate also requires successful GitHub Actions status and completed production voice-source provenance. If GitHub Actions is still blocked by account billing or spending limits, treat the release as hardware-validated locally but not consumer-promoted until the account issue is resolved or an explicit exception is recorded.

Hardware validation is still required before promoting this prerelease to a consumer rollout.
