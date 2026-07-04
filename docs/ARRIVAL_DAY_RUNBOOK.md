# Stackchan Arrival-Day Runbook

Use this when the physical Stackchan device arrives. Keep this release as a device-ready prerelease until every evidence gate below is complete.

## 0. Bench Setup

- Clear the work area around the body and servos.
- Keep display-only firmware first; do not start servo calibration first.
- Use a stable USB-C power source.
- Have a camera ready for display, speaker, and motion evidence.
- Know the serial port, for example `COM3`.

## 1. Create The Evidence Packet

From the extracted release folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Before plugging in hardware, open `companion/evidence/c6-evidence/EVIDENCE.md` from the same release folder. It should show the committed C6 desktop companion brain-supervision gate passing, including GUI-driven Python brain start, simulated turns, restart, and diagnostics export.

Open the newest folder under `output\hardware-evidence\`. Run every command below from that packet folder unless noted otherwise.

If you already ran `tools\share_release.cmd` and `tools\verify_share_release.cmd`, the packet also includes `HOSTED_MEDIA_REFERENCE.md`, `share\VERIFIED_URL.txt`, and `share/` copies of the verified local or Cloudflare share page reports. Use that verified page as the review reference for the expected image, video, face GIFs, and voice samples while collecting real-device evidence.

## 2. Verify Package And Flash Display-Only

```powershell
.\RUN_PACKAGE_VERIFY.cmd
.\RUN_HARDWARE_SIM_BASELINE.cmd
.\RUN_DISPLAY_ONLY.cmd
.\RUN_SPEECH_MOUTH_DEMO.cmd
.\RUN_SPEAK_ALL_INTENTS.cmd
.\RUN_BRIDGE_REPLAY.cmd
.\RUN_SIM_HARDWARE_COMPARE.cmd
```

Expected evidence:

- `logs/package_verify.log`
- `simulation/hardware-sim/latest/hardware_simulation.json` and `logs/hardware_simulation_baseline.log` if the no-hardware baseline was run before the unit arrived
- `HOSTED_MEDIA_REFERENCE.md` if a verified share was available
- display-only serial log
- `logs/speech_mouth_demo_serial.log` from the required speech-mouth demo helper
- `logs/speak_all_intents_serial.log` from the required packaged speech-intent helper
- `logs/bridge_replay_serial.log` from the deterministic P7 bridge replay helper
- `SIM_HARDWARE_COMPARE.md/json` from the advisory sim-vs-real serial marker comparison
- photo or video showing the procedural face
- observation note that servos stayed in dry-run mode
- `AUDIO_REVIEW.md` started with the sample you plan to play later

Hard stop if:

- the display is blank or corrupted
- the device resets repeatedly
- serial output has no boot marker
- any servo moves during display-only firmware

After the face is visible, send `status` in the serial monitor once. It should immediately print `[heartbeat]` plus `[system]` heap and task stack telemetry; save that line in the display-only serial log.

If the robot is not on the bench yet, run `RUN_HARDWARE_SIM_BASELINE.cmd` first. It captures
the no-hardware virtual Stackchan baseline, including the fake mic/STT/model/TTS/speaker
loop, under `simulation/hardware-sim/latest/` for later comparison. It is not hardware
evidence.

From the repo or release package, `tools/run_prearrival_sim_check.cmd` is the quick
pre-arrival proxy. It writes `PREARRIVAL_SIM_CHECK.md/json` with simulator status and
LAN smoke status plus engine-readiness status, making it clear what is already passing before
the unit is on the bench.

For the local bridge socket path specifically, `tools/run_lan_smoke.cmd` writes
`LAN_SMOKE.md/json` with the real WebSocket handshake, deterministic text turn, fake mic
upload, fake STT/TTS, and PCM16 binary downlink check.

If the Android companion is the bridge host, install the debug or release APK on the phone,
open Stackchan Companion, allow notifications when prompted on Android 13 or newer, and
allow the app to ignore battery optimizations if prompted for screen-off bench testing.
Build the debug APK from the source checkout with
`.\tools\check_android_toolchain.cmd` and then
`cd companion; .\gradlew.bat :app-android:assembleDebug` when a signed release APK has not
already been produced. The default debug output path is
`companion\app-android\build\outputs\apk\debug\app-android-debug.apk`.
The toolchain check verifies `JAVA_HOME`/`java.exe`, Android SDK root, `platform-tools`/`adb.exe`,
and SDK Platform 36 before Gradle starts.
Confirm the foreground notification reports the bridge as ready and advertised. The phone
advertises `_stackchan-bridge._tcp.local` with `endpoint_id`, `endpoint_kind`, `proto`, and
`capabilities` TXT metadata matching the desktop companion.
When installing with adb, run
`RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk> -SourceCommit <git-commit>` from the
evidence packet first. It installs the APK and records the APK SHA256, source commit,
installed version, device model, and package dump under `android/apk-install/`.
Android holds a multicast lock while advertising so same-network discovery survives common
Wi-Fi multicast filtering behavior. While a robot is connected, Android also holds a
session-scoped partial wake lock so the bridge CPU path stays awake with the screen off.
As an mDNS fallback, the phone broadcasts the same endpoint metadata as a UDP beacon to
port `8766` every few seconds.
If service discovery is unavailable on the LAN, manually point the robot bridge client at
the `ws://<phone-lan-ip>:8765/bridge` URL shown in the Android dashboard or foreground
notification.
After the robot connects, capture the Android dashboard connected state. The screenshot
must show the robot identity, firmware/version signal, last bridge frame, active brain
owner, and foreground service state so the phone-hosted bridge path is reviewable without
the device in hand.
For the full Android phone/LAN validation pass, use `docs/ANDROID_COMPANION_TEST_PLAN.md`
and attach its evidence to the packet.
Before asking the robot to connect manually, run
`RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge` from the evidence
packet to verify the Android endpoint handshake and save the report under
`android/companion-probe/`.
If mDNS discovery is unreliable, run `tools/run_android_udp_beacon_probe.cmd` from another
machine on the same LAN, or `RUN_ANDROID_UDP_BEACON_PROBE.cmd` from the evidence packet,
to capture the Android UDP discovery beacon under `android/udp-beacon-probe/`.
If the Android service stops, crashes, loses foreground status, or fails during screen-off
soak, connect adb and run `RUN_ANDROID_LOGCAT_CAPTURE.cmd` from the evidence packet
immediately. It saves the filtered service excerpt under `android/logcat/` for review.

Import the display photo or video into the packet:

```powershell
.\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg
```

Optional speech-mouth sidecar check from the extracted release folder:

```powershell
.\tools\generate_speech_envelope_sidecar.cmd -InputWav media\voice\rvc\stackchan_rvc_bright_robot.wav -OutputJson output\bright_robot.speech_envelope.json
.\tools\verify_speech_envelope_sidecar.cmd -Path output\bright_robot.speech_envelope.json
.\tools\send_speech_mouth_demo.cmd -Port COM3 -SidecarPath output\bright_robot.speech_envelope.json
```

Evidence packets created from a verified package wire `RUN_SPEECH_MOUTH_DEMO.cmd` to the copied lead audition automatically. It generates `speech/lead_voice.speech_envelope.json`, verifies it, then streams that envelope so the mouth check follows the selected RVC review voice instead of the built-in fallback pattern.
Run `RUN_SPEAK_ALL_INTENTS.cmd` after that helper while display-only firmware is still connected. It sends `speak <intent>` for every packaged speech intent and captures prompt, earcon, and `[audio_out]` handoff telemetry in `logs/speak_all_intents_serial.log`.

P7 bridge comparison: run `RUN_BRIDGE_REPLAY.cmd` while display-only firmware is connected.
It sends a deterministic bridge transcript and captures `[bridge-replay]`, `[bridge]`,
`[speech]`, mouth-envelope, and runtime bridge counter telemetry in
`logs/bridge_replay_serial.log`. Then run `RUN_SIM_HARDWARE_COMPARE.cmd` to write
`SIM_HARDWARE_COMPARE.md/json`. Pending means more logs are needed; pass means the captured
serial markers match the no-hardware proxy, not that hardware evidence gates are complete.

## 3. Supervised Servo Calibration

Only continue after display-only passes and the body is clear.

```powershell
.\RUN_SERVO_CALIBRATION.cmd
```

Expected evidence:

- servo-calibration serial log
- yaw classification: angle, velocity, or disabled
- pitch behavior note
- updated calibration notes if the physical center differs
- short video showing controlled motion

Hard stop if:

- yaw spins continuously
- pitch binds, chatters, or hits a mechanical limit
- any motion continues after the command stops
- the body tips, snags, or heats noticeably

If motion looks unsafe, send `motion stop` or `halt` in the serial monitor before touching the device. The serial log should show `[motion] enabled=0`.

## 4. Mixed-Mode Soak

```powershell
.\RUN_SOAK_MONITOR.cmd
```

Expected evidence:

- 30-minute soak log with heartbeat and `[system]` runtime health markers
- no repeated resets
- no task stalls
- face remains responsive
- `RVC_LEAD_AUDITION.md` reviewed so the exact lead sample and voice settings are known
- `RUN_PLAY_LEAD_VOICE.cmd` used as the playback aid when routing audio to the target speaker path
- `AUDIO_REVIEW.md` completed
- real-device speaker recording saved under `audio/`
- audio sample is intelligible through the device speaker
- no clipping, distortion, playback dropout, or excessive delay

The evidence packet copies the current lead RVC audition into `reference_audio/`. For this prerelease direction, the lead is `RVC Bright Robot` with pitch 2, index 0.62, RMS mix 0.72, and protect 0.28. This remains review-only voice evidence; production voice-source provenance is still required before consumer rollout.

The packet also copies `VOICE_SOURCE_STATUS.md/json` and `RVC_VOICE_BASE_STATUS.md/json` from the verified release package. Treat these as the authoritative voice gate reports during bring-up; they should remain blocked until a licensed or owned production voice source and RVC rights review are cleared.

Import the speaker recording into the packet. Use `-Type Audio` for phone videos of the speaker so `.mp4` or `.mov` files are stored under `audio/`:

```powershell
.\RUN_PLAY_LEAD_VOICE.cmd
.\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav
```

## 5. Progress Check Before Promotion

Open `BENCH_STATUS.md` in the evidence packet first. It gives the current next action and command. Then open `NEXT_STEPS.md` for the full run order covering package verification, optional simulation baseline, display, servo, soak, speaker recording, progress checks, rollout status, and promotion gates.

Run this repeatedly while collecting evidence:

```powershell
.\RUN_PROGRESS_CHECK.cmd
.\RUN_ROLLOUT_STATUS.cmd
```

`RUN_PROGRESS_CHECK.cmd` refreshes `BENCH_STATUS.md` and `BENCH_STATUS.json`. `RUN_ROLLOUT_STATUS.cmd` writes `ROLLOUT_STATUS.md` and `ROLLOUT_STATUS.json` into the packet. Use those files as the current handoff summary for package, hardware evidence, hosted media, GitHub Actions, and production voice-source gates.

Do not run the strict verifier until the progress check is clean or only lists intentionally deferred gates.

## 6. Strict Evidence Verification

```powershell
.\RUN_EVIDENCE_VERIFY.cmd
```

This must pass before calling the package hardware-validated.

## 7. Consumer Promotion Gate

Only after strict evidence verification passes:

```powershell
.\RUN_CONSUMER_PROMOTION_CHECK.cmd
```

This still requires:

- successful GitHub Actions status, unless an explicit `stackchan.ci-account-block-exception.v1` JSON account-block exception is recorded for the exact release commit
- completed production voice-source provenance
- completed `AUDIO_REVIEW.md` with real-device speaker evidence

## Current Release Limits

- Current hosted samples are review-only Stackchan Spark Synth samples.
- Production voice source remains pending.
- GitHub Actions may be externally blocked by account billing or spending-limit state.
- No consumer rollout until hardware evidence, production voice provenance, and CI/account state are resolved.
