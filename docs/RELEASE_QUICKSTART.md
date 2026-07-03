# Stackchan: Alive Release Quickstart

Use this from an extracted release package when the device arrives.

## Before Connecting Hardware

1. Install Python, PlatformIO, and GitHub CLI if this machine will verify or publish releases.
2. Confirm the body is clear and the servos are not mechanically blocked.
3. Keep the first run display-only. Servo calibration is a separate, supervised step.

Run the no-hardware virtual Stackchan proxy while the physical unit is unavailable:

```powershell
.\tools\run_hardware_simulation.cmd
```

## Remote Review Link

From an extracted release package:

```powershell
.\tools\share_release.cmd -CloudflareTunnel -DownloadCloudflared
```

This serves the release ZIP, ZIP SHA256 sidecar, preview image, expression sheet, video, quickstart, release notes, readiness report, and checksums. It downloads a local `cloudflared.exe` under `output\tools` only when `cloudflared` is not already installed.
Use `-OpenLocal` when you want the helper to open the host-only local page automatically after it proves the server is answering.
The public URL is saved as `output\share\<version>\PUBLIC_URL.txt` when a tunnel exists. Local-only shares are also valid for same-machine or LAN review: after `verify_share_release.cmd`, the evidence packet records the verified URL in `share\VERIFIED_URL.txt`. The share folder includes `OPEN_LOCAL_SHARE.cmd` for opening the host-only local page plus `STOP_SHARING.cmd` to stop the local server and tunnel.
After `share_release.cmd -NoServe`, use `.\tools\verify_share_release.cmd -Version <version> -Offline` to check the static folder and ZIP hash without starting a server. Offline mode writes `share_static_verification_report.json` with an `offline-static:` URL marker; it does not replace the HTTP verifier when you need hosted-media evidence.
Before sending the URL, verify the handoff page and public assets:

```powershell
.\tools\verify_share_release.cmd -RequirePublicUrl
```

For a local or LAN handoff, omit `-RequirePublicUrl`; the verifier will pin the local/LAN URL that actually passed the HTTP checks.

If old local share servers are occupying ports, run:

```powershell
.\tools\stop_share.cmd -All
```

The cleanup command only stops processes recorded under `output\share` that still look like Stackchan share servers.

From a source checkout, pass the release version:

```powershell
.\tools\share_release.cmd -Version <version> -CloudflareTunnel -DownloadCloudflared
```

If Cloudflare DNS or tunnel startup is unreliable and the reviewer is on the same network, use a LAN share instead:

```powershell
.\tools\share_release.cmd -Version <version> -Lan
```

Open the first printed same-network URL on the other device. The loopback URL is for the machine running the share command.
If the first same-network URL fails, run `output\share\<version>\OPEN_LOCAL_SHARE.cmd` on the Windows host first. Then open `output\share\<version>\LAN_TROUBLESHOOTING.md` and check `share_probe_report.json`. Prefer candidates that are not virtual/VPN adapters and have a default gateway; allow the Python server through Windows Firewall for private networks if host-side probes pass but another device still cannot connect.

## Prepare The Arrival Packet

From inside the extracted release folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Replace `COM3`, `Your Name`, and `STACKCHAN-001` with the device serial port, operator name, and physical device identifier.

This command verifies the package, dry-runs the display-only flash command, and creates an evidence packet under `output\hardware-evidence\`.

If a verified share exists under `output\share\<version>\`, the evidence packet copies `HOSTED_MEDIA_REFERENCE.md`, `share\VERIFIED_URL.txt`, and the share verification reports automatically. To pin a specific hosted media reference, pass `-ShareRoot output\share\<version>`.

## First Device Commands

Open the newest evidence packet folder and run:

```powershell
.\RUN_PACKAGE_VERIFY.cmd
.\RUN_DISPLAY_ONLY.cmd
.\RUN_SPEECH_MOUTH_DEMO.cmd
.\RUN_SPEAK_ALL_INTENTS.cmd
```

Open `BENCH_STATUS.md` in the evidence packet for the current next action, then `NEXT_STEPS.md` for the short bench run order and hard stops. The longer `README.md` remains the detailed reference.

Only after display-only firmware boots cleanly and the body is on a clear surface, run:

```powershell
.\RUN_SERVO_CALIBRATION.cmd
```

The servo command includes `-ConfirmServoRisk` because it can move the physical body.

During bring-up, run:

```powershell
.\RUN_PROGRESS_CHECK.cmd
.\RUN_ROLLOUT_STATUS.cmd
```

This refreshes `BENCH_STATUS.md/json` and lists missing observation fields, logs, serial markers, media evidence, calibration updates, and unchecked gates before the final promotion verifier.
The rollout status command also writes `ROLLOUT_STATUS.md/json`, combining the evidence progress result with the package, GitHub Actions status, hosted media reference, and voice-source gate.

Import photos, videos, and speaker recordings through the packet helper so the files are validated and hashed:

```powershell
.\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg
.\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav
```

Use `-Type Audio` for phone videos of the speaker so `.mp4` or `.mov` recordings land under `audio\` instead of `photos\`.

The evidence packet also includes `RVC_LEAD_AUDITION.md`, `reference_audio\`, and `RUN_PLAY_LEAD_VOICE.cmd`. Use that playback helper for the target speaker check so the recording is tied to the selected `RVC Bright Robot` lead audition and its exact pitch/index/RMS/protect settings.

For speech-reactive mouth bench tests from an actual WAV, generate a 50 Hz sidecar and stream it over serial:

```powershell
.\tools\generate_speech_envelope_sidecar.cmd -InputWav media\voice\rvc\stackchan_rvc_bright_robot.wav -OutputJson output\bright_robot.speech_envelope.json
.\tools\verify_speech_envelope_sidecar.cmd -Path output\bright_robot.speech_envelope.json
.\tools\send_speech_mouth_demo.cmd -Port COM3 -SidecarPath output\bright_robot.speech_envelope.json
```

Inside a generated evidence packet, `RUN_SPEECH_MOUTH_DEMO.cmd` does this automatically for the copied lead RVC audition and writes the generated sidecar under `speech/`. Run `RUN_SPEAK_ALL_INTENTS.cmd` next to capture `logs/speak_all_intents_serial.log` with every packaged speech intent, earcon, and `[audio_out]` handoff.

The packet copies `VOICE_SOURCE_STATUS.md/json` and `RVC_VOICE_BASE_STATUS.md/json` from the verified release package. Review those reports before promotion; they should stay blocked until the production voice source and RVC rights gates are explicitly cleared.

Before promotion review, complete the audio evidence record generated in the packet:

```powershell
notepad .\AUDIO_REVIEW.md
```

Save at least one real-device speaker recording under `audio\`. The strict verifier accepts `.wav`, `.mp3`, `.m4a`, `.aac`, `.mp4`, `.mov`, or `.webm`, but generated source WAVs alone do not count as target-speaker evidence.

Before consumer promotion, review the generated voice-source status report:

```powershell
notepad .\VOICE_SOURCE_STATUS.md
notepad .\RVC_VOICE_BASE_STATUS.md
```

That report must move from `blocked-pending-production-voice-source` to production-ready before a non-prerelease rollout.

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

That final gate also requires successful GitHub Actions status and completed production voice-source provenance. If GitHub Actions is still blocked by account billing, spending limits, or pre-runner allocation, treat the release as hardware-validated locally but not consumer-promoted until the account issue is resolved or a completed `docs\CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json` copy is passed with `-ExternalAccountCiExceptionPath`. The checked-in template and generated drafts are deliberately unapproved: approval fields are `TBD` and every proof boolean is `false`. Use `.\tools\new_ci_account_block_exception.cmd -ActionsStatusPath output\release\<version>\github_actions_status.json -OutPath output\ci-exceptions\<version>\CI_ACCOUNT_BLOCK_EXCEPTION_DRAFT.json` to draft the pinned exception from the observed CI report, then fill the approval fields and flip each proof boolean only after that gate passes.

Hardware validation is still required before promoting this prerelease to a consumer rollout.
