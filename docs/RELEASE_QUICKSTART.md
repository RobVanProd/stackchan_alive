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

Run the combined pre-arrival proxy report:

```powershell
.\tools\run_prearrival_sim_check.cmd
```

It writes `output/prearrival-sim/latest/PREARRIVAL_SIM_CHECK.md/json` plus nested
`hardware-sim/`, `lan-smoke/`, and `engine-probe/` reports. A passing report means the
virtual CoreS3/LAN/audio proxy and socket-level bridge proxy are still healthy; it does not
replace device evidence.
After a real model runner command is configured, add `-RunModelBenchmark` to include
`model-benchmark/MODEL_BENCHMARK.md/json` and the `model-benchmark-candidate` gate in the
same pre-arrival report.

Check that the companion source/package still carries the v1 plan, protocol fixture
provenance, Android/desktop modules, CI hooks, and pending hardware gates:

```powershell
.\tools\check_companion_v1_readiness.cmd
```

The expected source-ready state is `source-ready-pending-hardware`; physical robot,
target-phone, C8 distribution, and production voice-source gates remain pending until
their real evidence is captured.

Capture companion release evidence after APK or desktop package artifacts exist:

```powershell
.\tools\export_companion_release_evidence.cmd
```

Before a signed C8 distribution is promoted, rerun it with `-RequireArtifacts` so missing
APK or desktop package hashes block the release evidence.

Run the socket-level LAN bridge smoke report:

```powershell
.\tools\run_lan_smoke.cmd
```

It writes `output/lan-smoke/latest/LAN_SMOKE.md/json` and verifies the local WebSocket
handshake, deterministic text turn, fake mic upload, fake STT/TTS path, PCM16 binary
downlink, and visible `thinking-latency` timing without requiring hardware.

Check whether this host has local model/STT/TTS engines configured:

```powershell
.\tools\run_engine_probe.cmd -Json
```

Re-run with `-RunModelSmoke` after exporting a real runner command. The probe is setup
evidence only; full brain selection still requires a non-dry-run model benchmark.

Validate the bundled Character OS persona packs:

```powershell
.\tools\verify_persona_pack.cmd --Json
.\tools\verify_persona_pack.cmd glow --Json
```

Run the batch model benchmark after the runner command is configured:

```powershell
python bridge/model_benchmark.py --profile gemma4-e2b-gguf --require-runner --json
```

The report writes `output/model-benchmark/latest/MODEL_BENCHMARK.md/json` with
`summary.candidate_gate`, per-profile blockers, `ready_profiles`, and
`recommended_profile`. A default brain candidate requires the full prompt suite, configured
runner rows, 95 percent pass rate, median latency at or below 2.5 s, and at least 5
approximate tokens per second.

Run the Character Lock red-team gate:

```powershell
.\tools\run_character_red_team.cmd -Json
.\tools\run_character_red_team.cmd -RequireRunner -Json
```

The first command regenerates dry-run corpus evidence. The second command is the real B7
gate after a local model runner is configured; it must report `summary.gate.ready == true`
before the model is treated as in-character.

Check the mobile LiteRT-LM runner contract:

```powershell
.\tools\run_litert_lm_smoke.cmd -Json
```

This writes `output/litert-lm-smoke/latest/LITERT_LM_SMOKE.md/json` and verifies the wrapper
contract without claiming real model speed.

Check the Play Store evidence verifier contract before relying on it for the internal
testing upload:

```powershell
.\tools\test_android_play_store_evidence_contract.cmd
```

This proves the placeholder Play evidence template is rejected and a complete internal
testing packet with hosted privacy URL, Play signing, install status, and all four required
screenshots reports `play-internal-testing-ready`.

After the individual Android phone and robot gates are collected, create the aggregate
Android v1 evidence bundle:

```powershell
.\tools\check_android_v1_evidence_bundle.cmd -EvidenceRoot output\android-v1-evidence\latest -WriteTemplate
```

Copy the individual checker JSON outputs into `reports\`, fill
`ANDROID_V1_EVIDENCE_BUNDLE.json` and `ANDROID_V1_REVIEW.md`, then run:

```powershell
.\tools\check_android_v1_evidence_bundle.cmd -EvidenceRoot output\android-v1-evidence\latest -RequireReady -Json
```

It must report `android-v1-evidence-ready` before treating the Android companion as
release-ready. The aggregate checker also verifies that the Android hardware evidence checker
reports, target-phone APK install report, and Play Store evidence-check JSON match the
`ANDROID_V1_EVIDENCE_BUNDLE.json` source commit.

After the Android phone has captured a push-to-talk turn against a connected robot, run the
speech evidence gate:

```powershell
.\tools\check_android_speech_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -LogcatPath <android_speech_logcat.txt> -RobotLogPath <robot_speech_serial.log> -ReviewPath <ANDROID_SPEECH_REVIEW.md> -RequireReady -Json
```

It must report `android-speech-ready` before Android push-to-talk/STT is considered
validated for v1.

After the Android phone has exercised protected settings writes and manual brain
claim/release against a connected robot, run the controls evidence gate:

```powershell
.\tools\check_android_controls_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -RobotLogPath <robot_controls_serial.log> -ReviewPath <ANDROID_CONTROLS_REVIEW.md> -RequireReady -Json
```

It must report `android-controls-ready` before Android settings/handoff controls are
considered validated for v1.

After the Android setup flow has paired a physical robot through QR/short-code entry, run
the pairing evidence gate:

```powershell
.\tools\check_android_pairing_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -RobotLogPath <robot_pairing_serial.log> -PairingMediaPath <android_pairing_setup.jpg> -ReviewPath <ANDROID_PAIRING_REVIEW.md> -RequireReady -Json
```

It must report `android-pairing-ready` before Android QR/short-code pairing is considered
validated for v1.

After the Android setup flow has provisioned the robot Wi-Fi bridge target and the robot has
been power-cycled and cleared once, run the Wi-Fi evidence gate:

```powershell
.\tools\check_android_wifi_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -RobotLogPath <robot_wifi_serial.log> -ReviewPath <ANDROID_WIFI_REVIEW.md> -RequireReady -Json
```

It must report `android-wifi-ready` before Android-assisted Wi-Fi provisioning is considered
validated for v1.

After the Android phone has downloaded, checksum-verified, loaded, ejected, reloaded, and
used Gemma-4-E2B for a real LiteRT turn, run the real-device evidence gate:

```powershell
.\tools\check_android_gemma_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -LogcatPath <android_gemma_logcat.txt> -ReviewPath <ANDROID_GEMMA_REVIEW.md> -RequireReady -Json
```

It must report `android-gemma-real-device-ready` before Mobile Brain Mode is considered
validated for v1.

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
.\RUN_BRIDGE_REPLAY.cmd
.\RUN_SIM_HARDWARE_COMPARE.cmd
```

If the Android phone is the companion bridge host, also run these from the evidence packet:

Build the Android companion APK from the source checkout before this step:

```powershell
.\tools\check_android_toolchain.cmd
cd companion
.\gradlew.bat :app-android:assembleRelease
```

The toolchain check verifies `JAVA_HOME`/`java.exe`, Android SDK root, `platform-tools`/`adb.exe`,
and SDK Platform 36 before Gradle starts.

Then pass the resulting `companion\app-android\build\outputs\apk\release\app-android-release.apk`
path into the evidence packet installer:

```powershell
.\RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk> -SourceCommit <git-commit>
.\RUN_ANDROID_UDP_BEACON_PROBE.cmd
.\RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge
.\RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge
.\RUN_ANDROID_LOGCAT_CAPTURE.cmd
```

Only run `RUN_ANDROID_LOGCAT_CAPTURE.cmd` when the Android bridge service stops, crashes,
loses foreground status, or fails during screen-off soak. It writes the filtered adb
excerpt under `android/logcat/` so the failure has packet-level evidence.

The Android helpers write packet-local probe evidence under `android\udp-beacon-probe\` and `android\companion-probe\`,
and screen-off soak evidence under `android\screen-off-soak\`.
`RUN_ANDROID_APK_INSTALL.cmd` writes install evidence, including the APK source commit,
under `android\apk-install\`.

After the screen-off soak finishes, run the source checkout checker against the packet or
repo output:

```powershell
.\tools\check_android_screen_off_soak_evidence.cmd -SoakJsonPath <android_companion_soak.json> -SoakMarkdownPath <ANDROID_COMPANION_SOAK.md> -ReviewPath <ANDROID_SCREEN_OFF_SOAK_REVIEW.md> -RequireReady -Json
```

It must report `android-screen-off-soak-ready` before the Android bridge soak gate is
closed.
After the robot connects through the phone, capture the Android dashboard connected state
showing robot identity, firmware/version signal, last bridge frame, active brain owner,
and foreground service state.
For first Wi-Fi setup, enter the Android-generated
`wifi set ssid "<network-name>" pass "<network-password>" url "ws://phone-lan-ip:8765/bridge"`
command on the robot and verify password redaction plus persisted store telemetry. If the
robot already has Wi-Fi credentials, enter `pair ticket <stackchan://pair?...>` or the raw
`stackchan://pair?...` Android QR payload instead; that ticket carries only the pairing code
and bridge target.

For desktop PC Brain distribution, prepare a managed Python runtime payload on each target
desktop platform before packaging installers:

```powershell
.\tools\prepare_desktop_python_runtime.cmd -SourcePython <python.exe-or-python3> -RuntimeRoot output\desktop-python-runtime\<platform> -SourceName "python-3.12.x-<platform>" -Force
.\tools\check_desktop_python_runtime_payload.ps1 -RuntimeRoot output\desktop-python-runtime\<platform> -Json
```

Before trusting the managed-runtime gate, run its contract test:

```powershell
.\tools\test_desktop_python_runtime_payload_contract.cmd
```

Then pass that root into desktop packaging with
`-Pstackchan.desktop.pythonRuntimeRoot=<path>` or
`STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT=<path>`. A platform runtime only validates the
matching platform installer; Windows, macOS, and Linux require separate native payloads.

For PC Brain Mode lab bring-up, start the local brain bridge and selected voice TTS path:

```powershell
.\tools\start_pc_brain.cmd -Background -StopExisting
.\tools\run_pc_brain_probe.cmd --url ws://127.0.0.1:8765/bridge
```

Point the robot at `ws://<pc-lan-ip>:8765/bridge` with `tools\flash_wifi_bridge.cmd` or the
runtime `wifi set ... url "ws://<pc-lan-ip>:8765/bridge"` command, then collect deployment
evidence:

```powershell
.\tools\collect_pc_brain_deploy_evidence.cmd -DeviceHost <robot-lan-ip> -RunTests
.\tools\check_pc_brain_deploy_evidence.cmd -EvidenceJsonPath output\pc-brain\<deploy-dir>\PC_BRAIN_DEPLOY_EVIDENCE.json -EvidenceMarkdownPath output\pc-brain\<deploy-dir>\PC_BRAIN_DEPLOY_EVIDENCE.md -RequireTests -RequireReady -Json
```

This writes `PC_BRAIN_DEPLOY_EVIDENCE.json/md` plus copied PC logs and robot debug JSON. It
is lab proof for the current machine only when the checker reports `pc-brain-deploy-ready`.
Connectivity-only packets are not enough; the evidence must show at least one completed
audio downlink and speaker playback path with zero bridge/playback errors. Managed desktop
Python runtime payload evidence is still required before desktop distribution is considered
self-contained.

After a passing deploy packet, leave the PC brain and robot connected and run the quiet-soak
gate:

```powershell
.\tools\run_pc_brain_quiet_soak.cmd -DeviceHost <robot-lan-ip> -DurationSeconds 600 -IntervalSeconds 30
.\tools\check_pc_brain_quiet_soak_evidence.cmd -SoakJsonPath output\pc-brain\<soak-dir>\PC_BRAIN_QUIET_SOAK.json -SoakMarkdownPath output\pc-brain\<soak-dir>\PC_BRAIN_QUIET_SOAK.md -RequireReady -Json
```

It must report `pc-brain-quiet-soak-ready`, proving the bridge stays connected/ready for
the full quiet window without parse/timeouts/playback errors or unexpected audio streams.

Assemble the final desktop/PC Brain aggregate packet after the three platform runtime
payload reports, package hashes, C6 evidence, deploy evidence, quiet-soak evidence, and
production voice-source readiness are captured:

```powershell
.\tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -WriteTemplate
.\tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -RequireReady -Json
```

The checker must report `desktop-v1-evidence-ready` before treating desktop installers as
v1 release-ready. The `DESKTOP_V1_REVIEW.md` source commit must match
`DESKTOP_V1_EVIDENCE_BUNDLE.json.sourceCommit`, and the production voice-source readiness
report must carry that same `sourceCommit`.

After Android v1, desktop v1, hardware, Play, production voice-source, release package,
GitHub Actions, and rollout evidence are all ready for the same commit, assemble the final
Companion v1 aggregate packet:

```powershell
.\tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot output\companion-v1-evidence\latest -WriteTemplate
.\tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot output\companion-v1-evidence\latest -RequireReady -Json
```

The checker must report `companion-v1-evidence-ready` before calling the companion v1
release fully vetted. It also verifies that release evidence, GitHub Actions status, and
rollout status all match the bundle source commit and release version, and that production
voice-source readiness plus the Android/Desktop v1 bundle checks were generated for the same
source commit.

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

`RUN_SIM_HARDWARE_COMPARE.cmd` writes `SIM_HARDWARE_COMPARE.md/json`. Use it after
`RUN_HARDWARE_SIM_BASELINE.cmd` and the display/speech/bridge logs exist to compare the
physical serial markers against the no-hardware virtual Stackchan baseline. This is a
diagnostic aid only; a passing comparison does not replace photos, speaker recordings, servo
calibration, soak, or strict hardware evidence verification.

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
