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

This serves the release ZIP, preview image, video, quickstart, release notes, and checksums. It downloads a local `cloudflared.exe` under `output\tools` only when `cloudflared` is not already installed.

From a source checkout, pass the release version:

```powershell
.\tools\share_release.cmd -Version <version> -CloudflareTunnel -DownloadCloudflared
```

## Prepare The Arrival Packet

From inside the extracted release folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3
```

Replace `COM3` with the device serial port.

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

## Promotion Evidence

Before calling the release consumer-ready, save:

- Display-only serial log.
- Servo-calibration serial log.
- 30-minute soak log.
- Photos or video of the display and motion behavior.
- Calibration changes in `data\calibration.yaml`.

Then run:

```powershell
.\RUN_EVIDENCE_VERIFY.cmd
```

Hardware validation is still required before promoting this prerelease to a consumer rollout.
