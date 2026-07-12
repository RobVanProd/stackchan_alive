# Stackchan Arrival-Day Runbook

Use this when the physical Stackchan device arrives. Keep this release as a device-ready prerelease until every evidence gate below is complete.

## 0. Bench Setup

- Clear the work area around the body and servos.
- Keep display-only firmware first; do not start servo calibration first.
- Use a stable USB-C power source.
- Have a camera ready for display, speaker, and motion evidence.
- Use diffuse room light for face detection. Never aim a bright lamp, phone light, work light, or
  exposed high-output LED into the operator's eyes. Stop immediately for discomfort or afterimages;
  camera validation can wait.
- Know the serial port, for example `COM3`.

Current lab note (2026-07-11): the live robot is running the OTA-confirmed incremental-capture
camera candidate, firmware SHA256
`890AE99A55CA89BAE3694D60287359D9F2A21814D1AD1B15E99A1E98E6DF8AC2`. Its private rollback
archive is recorded in `docs\FIRST_DEPLOY_STATUS.md`. Confirm
`sr_wake_mww_arenas_zero_initialized=true` in `/debug`, call `/wake-reset` once only when a fresh
wake check is required, capture one correctly timed wake phrase,
and compare the on-device probability with the host-model result before changing cutoff, gain, or
microphone channel. Keep motion off during this check.

Routine continuation does **not** require another flash: the current camera candidate is already
installed and OTA-confirmed. The earlier `wake-zero-init-verified` and
`camera-stereo-speaker-follow` images are historical diagnostic checkpoints, not the current lead.
If recovery is genuinely required, use the exact current private rollback archive recorded in
`docs\FIRST_DEPLOY_STATUS.md`; never rebuild a private recovery image from an unreviewed worktree.
The guarded archived-app flasher verifies its manifest, byte count, and SHA256 while preserving
NVS/Wi-Fi. Motion remains disabled at boot.

Current release-acceptance note (2026-07-12): the installed private image is source commit
`dae9065bb08cd0ca50f49b29e2d0cbcff0f9b882`, firmware SHA256
`28172C6BF20BDCB14803DBC93B6FB477456877DBE5D5893D3E8F0FAE3BFB2AD3`. Its latest strict
actuator run stopped after `1287 s` on one incomplete camera HTTP response write, with `252/252`
successful robot polls and no reset, power, thermal, display, motion-session, capture,
authentication, or IMU gate failure. Do not diagnose that event as a blackout or camera failure.
The exact facts and evidence root are recorded at the top of `docs\FIRST_DEPLOY_STATUS.md`.
The superseding uninstalled candidate adds separate camera capture/response-write telemetry and
one bounded host retry; it must pass its own no-motion and actuator qualifications before a long
soak.

When physical testing resumes, first validate a real face under diffuse light with motion off,
then follow `docs\LOCAL_VISION.md` for the bounded wake/listen follow run. Confirm opposite bounded
left/right direction telemetry before fresh servo clearance. If board orientation reverses the
direction sign, change only the camera-profile direction setting; never swap face coordinates or
change the production wake channel.

### Optional 64 GB microSD

The installed 64 GB card is optional and exceeds M5Stack's documented 16 GB CoreS3 limit.
Do not make boot, wake, face, memory, or safety behavior depend on it. During the next explicit
computer-connected session, first identify the card and report its detected type and capacity
without writing to it. Only proceed if the operator then enters the exact runtime phrase
`FORMAT STACKCHAN 64GB ERASE MOVIES` and the isolated formatter was built with
`STACKCHAN_SD_FORMAT_BUILD_TOKEN=ERASE_STACKCHAN_64GB_MOVIES`. After the write/read smoke test,
restore production firmware before any other device validation. Full rationale and recovery
steps are in `docs/HARDWARE_FEATURE_ROADMAP.md` under **Optional 64 GB microSD**.

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

If the Android companion is the bridge host, install the lab-signed release APK on the
phone, open Stackchan Companion, allow notifications when prompted on Android 13 or newer,
and allow the app to ignore battery optimizations if prompted for screen-off bench testing.
Build the APK from the source checkout with `.\tools\check_android_toolchain.cmd` and then
`cd companion; .\gradlew.bat :app-android:assembleRelease`. The default lab release output
path is `companion\app-android\build\outputs\apk\release\app-android-release.apk`.
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
For firmware that still needs robot Wi-Fi credentials, use the serial console after the
phone bridge is ready:

```text
wifi set ssid "<network-name>" pass "<network-password>" url "ws://phone-lan-ip:8765/bridge"
```

The firmware should log `[wifi] persisted=1`, `store_has_record=1`, `enabled=1`,
`ssid_set=1`, the expected host/port/path, and then the Android dashboard should advance
after the robot `hello`. The log must not echo the password. Power-cycle once and confirm
the stored bridge record reloads before treating Wi-Fi setup as ready. Send `wifi clear`
before returning the robot to build-time bridge settings.
After Wi-Fi provisioning is exercised, capture robot serial output showing `[wifi]`,
`persisted=1`, `store_has_record=1`, `enabled=1`, `ssid_set=1`,
`bridge_wifi_store_loads`, `bridge_wifi_store_has_record=1`, `wifi clear`, and
`store_has_record=0`, then run
`tools\check_android_wifi_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -RobotLogPath <robot_wifi_serial.log> -ReviewPath <ANDROID_WIFI_REVIEW.md> -RequireReady -Json` and attach the JSON plus `ANDROID_WIFI_REVIEW.md`.
If the robot already has Wi-Fi credentials, enter the Android QR payload as
`pair ticket <stackchan://pair?...>` or the raw `stackchan://pair?...` payload instead.
That ticket carries the pairing code and bridge target only; it must not contain or print a
Wi-Fi password.
After QR/short-code pairing is exercised, capture Android setup media and robot serial output
showing `pairing_code_mismatch`, `stackchan://pair?`, `bridge_url_applied`,
`endpoint_hello_result`, and `trusted_endpoints_result`, then run
`tools\check_android_pairing_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -RobotLogPath <robot_pairing_serial.log> -PairingMediaPath <android_pairing_setup.jpg> -ReviewPath <ANDROID_PAIRING_REVIEW.md> -RequireReady -Json` and attach the JSON plus `ANDROID_PAIRING_REVIEW.md`.
After the robot connects, capture the Android dashboard connected state. The screenshot
must show the robot identity, firmware/version signal, last bridge frame, active brain owner,
and foreground service state so the phone-hosted bridge path is reviewable without the device
in hand.
For the full Android phone/LAN validation pass, use `docs/ANDROID_COMPANION_TEST_PLAN.md`
and attach its evidence to the packet.
After a push-to-talk turn succeeds on the target phone, capture Android logcat and robot
serial output, then run `tools\check_android_speech_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -LogcatPath <android_speech_logcat.txt> -RobotLogPath <robot_speech_serial.log> -ReviewPath <ANDROID_SPEECH_REVIEW.md> -RequireReady -Json` and attach the JSON plus `ANDROID_SPEECH_REVIEW.md`.
After protected settings and manual brain handoff are exercised, capture the robot control
log containing the pre-hello `robot_hello_required` gate plus `settings_set`,
`settings_result`, `claim_brain`, `release_brain`, and `owner_status`, then run
`tools\check_android_controls_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -RobotLogPath <robot_controls_serial.log> -ReviewPath <ANDROID_CONTROLS_REVIEW.md> -RequireReady -Json` and attach the JSON plus `ANDROID_CONTROLS_REVIEW.md`.
After Gemma-4-E2B is downloaded, checksum-verified, loaded, ejected, reloaded, and used for
a real phone text turn, run `tools\check_android_gemma_evidence.cmd -DiagnosticsExportPath <shared-ANDROID_DIAGNOSTICS_EXPORT.json> -LogcatPath <android_gemma_logcat.txt> -ReviewPath <ANDROID_GEMMA_REVIEW.md> -RequireReady -Json` and attach the JSON plus `ANDROID_GEMMA_REVIEW.md`.
Before asking the robot to connect manually, run
`RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge` from the evidence
packet to verify the Android endpoint handshake and save the report under
`android/companion-probe/`.
After the robot connects through the phone and the connected dashboard screenshot is
captured, run `RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge` with
the phone screen off. It saves the strict 10-minute heartbeat soak report under
`android/screen-off-soak/`.
Then run `tools\check_android_screen_off_soak_evidence.cmd -SoakJsonPath <android_companion_soak.json> -SoakMarkdownPath <ANDROID_COMPANION_SOAK.md> -ReviewPath <ANDROID_SCREEN_OFF_SOAK_REVIEW.md> -RequireReady -Json` from the source checkout or release tools directory. It must report `android-screen-off-soak-ready` before the Android screen-off bridge soak gate is closed.
If mDNS discovery is unreliable, run `tools/run_android_udp_beacon_probe.cmd` from another
machine on the same LAN, or `RUN_ANDROID_UDP_BEACON_PROBE.cmd` from the evidence packet,
to capture the Android UDP discovery beacon under `android/udp-beacon-probe/`.
If the Android service stops, crashes, loses foreground status, or fails during screen-off
soak, connect adb and run `RUN_ANDROID_LOGCAT_CAPTURE.cmd` from the evidence packet
immediately. It saves the filtered service excerpt under `android/logcat/` for review.
When assembling the final Android v1 evidence bundle, keep the Android hardware evidence
checker reports, APK install report, and Play Store evidence-check JSON from the same source
commit recorded in `ANDROID_V1_EVIDENCE_BUNDLE.json`. The aggregate gate fails if those
commits do not match.

Before treating desktop PC Brain installers as self-contained, prepare and validate the
managed Python runtime payload on each desktop platform:

```powershell
.\tools\prepare_desktop_python_runtime.cmd -SourcePython <python.exe-or-python3> -RuntimeRoot output\desktop-python-runtime\<platform> -SourceName "python-3.12.x-<platform>" -Force
.\tools\check_desktop_python_runtime_payload.ps1 -RuntimeRoot output\desktop-python-runtime\<platform> -Json
```

Package desktop builds with `-Pstackchan.desktop.pythonRuntimeRoot=<path>` or
`STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT=<path>`, then attach the generated
`stackchan-python-runtime.json` and checker output to the release evidence.

For PC Brain Mode lab bring-up from the source checkout, start the local bridge with the
selected voice path:

```powershell
.\tools\start_pc_brain.cmd -Background -StopExisting -EnableAudioDownlink -SelectedVoiceStartBytes 65536 -DownlinkBinaryFrameDelayMs 20
.\tools\run_pc_brain_probe.cmd --url ws://127.0.0.1:8765/bridge
```

On Windows, `tools\start_pc_brain.cmd` now defaults to the repo-local
`python bridge\whisper_cpp_stt.py` adapter. Run `tools\setup_whisper_cpp.cmd` once before
starting the brain on a fresh machine. The older `bridge\windows_speech_stt.py` System.Speech
adapter is kept only as a fallback.

Before flashing the full-online mic build, run the no-hardware PC engine preflight:

```powershell
.\tools\run_full_online_preflight.cmd -DeviceHost 192.168.1.238 -Port COM4 -Json
.\tools\check_full_online_flash_readiness.cmd -PreflightPath output\pc-brain\full-online-preflight-latest\FULL_ONLINE_PREFLIGHT.json -ValidationRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Json
```

After the face-flicker recovery, use a staged firmware sequence instead of jumping straight
from bridge-only to motor-enabled full-online firmware. Keep `stackchan_wifi` as the
known-good rollback build.

The first physical wake layer tested after rollback was `stackchan_wake_sr_probe`: ESP-SR
WakeNet ran on the robot and listened for `Hi Stack Chan`, while servos, speaker, bridge mic
capture, and bridge audio uplink stayed disabled.

Result: wake detection worked, but the build failed the face-performance gate. Quiet display
telemetry regressed to about `85-102 ms` per frame, roughly `11.6-11.8 fps`, so the robot was
rolled back to `stackchan_wifi`. Do not repeat this same physical step as the next wake
attempt. See `docs/BOT_LOCAL_WAKE_SR_PROBE.md` and
`output/hardware-evidence/bot-local-wake-sr/20260707-013728/BOT_LOCAL_WAKE_SR_RESULT.md`.

Reference build command:

```powershell
pio run -e stackchan_wake_sr_probe
```

Historical flash command used during the rejected probe:

```powershell
pio run -e stackchan_wake_sr_probe -t upload --upload-port COM4
```

Expected serial markers were `[sr_wake] ready=1`, `sr_wake_record_ok` increasing, and
`[sr_wake] event=wake_word applied=1` after saying `Hi Stack Chan`. Those markers appeared,
but the face-performance gate failed.

The next bot-local wake route is the ASR UART offload candidate, not another internal
ESP-SR attempt. See `docs/BOT_LOCAL_WAKE_ARCHITECTURE.md`.

Build-only candidate:

```powershell
pio run -e stackchan_wifi_asr_unit
```

Use this only after an offline ASR module is available and configured. The expected ASR unit
response format is:

```text
AA 55 <wake-command-id> 55 AA
```

For the first hardware discovery build, `STACKCHAN_ASR_WAKE_COMMAND_ID=0` accepts any valid
ASR frame as wake. For a real operating build, set the wake command ID explicitly or keep the
ASR unit firmware scoped to wake-only responses. Configure the ASR phrase to match how the
operator actually calls the robot, for example `Hey Stackchan`, and optionally add
`Hi Stack Chan` for factory-phrase compatibility.

Do not flash `stackchan_wifi_asr_unit` until the UART wiring is confirmed and an operator is
watching the face. The current candidate defaults to CoreS3 host RX `GPIO18`, TX `GPIO17`,
UART `115200 8N1`; confirm cable orientation against the ASR module TX/RX labels before
uploading.

Expected ASR wake markers:

```text
[asr_wake] ready=1 type=uart baud=115200 rx=18 tx=17 wake_command_id=0
[wake] source=asr_unit_uart event=wake_word applied=1 count=1 command_id=<id> at_ms=<ms>
```

Acceptance criteria are stricter than wake detection alone: the face must stay as smooth as
`stackchan_wifi`, the bridge/debug endpoint must remain responsive, and ASR telemetry
(`asr_wake_frames`, `asr_wake_events`) must increment only when the ASR module sends valid
frames. If flicker or frame-time regression appears, roll back immediately to
`stackchan_wifi`.

After bot-local wake is proven, the next voice transport layer is `stackchan_wifi_uplink`:
Wi-Fi bridge, speaker, mic capture, and bridge audio uplink are enabled, but servos remain
disabled and the mic poll interval is throttled for first bring-up. Flash it only while
watching the face, then verify the debug endpoint and quiet-soak before considering
motor-enabled firmware:

```powershell
.\tools\flash_device.cmd -Environment stackchan_wifi_uplink -Port COM4
.\tools\check_pc_brain_runtime.cmd -DeviceHost 192.168.1.238 -Json
.\tools\run_pc_brain_quiet_soak.cmd -DeviceHost 192.168.1.238 -DurationSeconds 300 -IntervalSeconds 30
```

If the display flickers, the face degrades, or the bridge stops responding, roll back to
`stackchan_wifi` before changing anything else:

```powershell
.\tools\flash_device.cmd -Environment stackchan_wifi -Port COM4
```

It builds `stackchan_full_online`, dry-runs the servo-risk-gated upload command, generates a
local Windows TTS sample, feeds the raw PCM through the configured STT adapter, runs the model
smoke, renders the selected voice TTS into the same 65,536-byte payload shape used for the
first speaker deploy, confirms the live listener process is using the selected voice, STT
command, runner command, chunk/delay settings, clean logs, and checks the current robot debug
endpoint. This does not replace the physical robot mic test; it proves the PC brain and source
tree are ready before the firmware starts sending mic audio.
The flash-readiness checker then proves the staged validation folder, live PC brain, selected
voice/STT/runner setup, robot debug endpoint, speaker volume, and dry-run upload command are
ready for the supervised physical flash. It still does not upload firmware or open serial.
For a one-command status summary, run:

```powershell
.\tools\check_stackchan_full_online_status.cmd -Json
```

It reports whether Stackchan is ready for supervised flashing, pending physical validation
after a successful flash, or fully physically validated. By default, it also fails stale
flash-readiness reports older than 120 minutes. Before the upload, rerun
`check_full_online_flash_readiness.cmd` if the status no longer says
`stackchan-full-online-ready-for-supervised-flash`; after the upload, expect
`stackchan-full-online-pending-validation` until the supervised mic and servo checks pass.
It also writes `output\pc-brain\full-online-status-latest\STACKCHAN_FULL_ONLINE_OPERATOR_BRIEF.md`;
open that brief before touching the physical unit.
For the supervised flash itself, prefer the guarded wrapper:

```powershell
.\tools\flash_full_online_when_ready.cmd -ReadinessJsonPath output\pc-brain\full-online-flash-readiness-latest\FULL_ONLINE_FLASH_READINESS.json -OperatorPresent -BodyClear -ConfirmServoRisk
```

Run the same command with `-DryRun` first if anything has changed since the latest readiness
report. The wrapper refuses to flash unless readiness is green, the readiness report is fresh
within the 120-minute default window, and all three safety confirmations are explicit.

After flashing `stackchan_full_online`, collect the first full-online validation evidence in
one folder, for example `output\pc-brain\full-online-validation-latest`:

```powershell
.\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Prepare -CaptureRuntime -CaptureLiveGate -Check -Json
```

Before the first supervised physical pass, run the physical-session readiness check. It
does not trigger voice or servo motion; it only confirms the live debug state, staged
validation evidence, body-clear attestation, generated next actions, and expected USB serial
port visibility:

```powershell
.\tools\check_full_online_physical_session_readiness.cmd -DeviceHost 192.168.1.238 -Port COM4 -Json
```

When Rob is ready for the observed session, prefer the guarded resume wrapper. It reruns
readiness first, then starts the guided physical session only when operator-present,
body-clear, and servo-risk confirmations are explicit:

```powershell
.\tools\resume_full_online_physical_validation_when_ready.cmd -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk
```

Use `hello stackchan` as the suggested robot-mic prompt for the voice-in pass unless Rob
intentionally chooses another phrase and records that exact phrase in the review.

After the observations are known, the same guarded wrapper can complete the review fields in
one pass by adding `-CompleteReview` and the observed prompt/transcript/motion details:

```powershell
.\tools\resume_full_online_physical_validation_when_ready.cmd -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk -CompleteReview -Operator "Rob" -ExactSpokenPrompt "<what you said to the robot>" -ObservedTranscript "<what STT heard>" -ServoMotionObserved "<what moved, and that it stopped>" -SafeStopCommand "motion stop" -ConfirmMicUplink -ConfirmStt -ConfirmSelectedVoice -ConfirmVoiceMatch -ConfirmServoControlled -ConfirmSafeStop -ConfirmNoServoRisk -ConfirmNoAudioRisk
```

The guarded wrapper calls the guided session wrapper. It captures the
before/after debug snapshots for voice and servo validation, can run debug-only logging, and
keeps the USB serial port free for a separate monitor or emergency stop:

```powershell
.\tools\start_full_online_physical_validation_session.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -ConfirmServoRisk -LoggerDebugOnly -SuggestedVoicePrompt "hello stackchan"
```

Keep the emergency stop helper ready in another terminal before any controlled motion:

```powershell
.\tools\send_stackchan_serial_command.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -Port COM4 -Command "motion stop" -OperatorPresent -Json
```

The guided session walks through the physical evidence that cannot be proven before the
flash:

- Save the before-voice debug snapshot:

```powershell
.\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureVoiceBefore -Check -Json
```

- Perform one supervised robot-mic voice turn. Suggested phrase: `hello stackchan`.
- After the response, preserve `output\pc-brain\latest\turns.jsonl`; the latest line should corroborate the STT transcript, selected voice, and response audio payload for this turn.
- Save the after-voice debug snapshot and confirm uplink bytes/chunks/turns increased, STT produced a transcript, and the selected voice returned through the robot speaker:

```powershell
.\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureVoiceAfter -Check -Json
```

- Save the before-servo debug snapshot:

```powershell
.\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureServoBefore -Check -Json
```

- Perform controlled servo motion and `motion stop` or safe stop, then save the after-servo debug snapshot:

```powershell
.\tools\collect_full_online_validation_evidence.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -CaptureServoAfter -Check -Json
```

If the run needs a full serial log, use the heavier logger in a second terminal. It captures
`FULL_ONLINE_DEBUG_POLL.jsonl`, `FULL_ONLINE_VALIDATION_LOGGING.json`, and
`full_online_serial.log`. It refuses to open the USB serial port unless the operator is
present and the body is clear. It also leaves serial DTR/RTS disabled by default to avoid
an avoidable reset during passive capture:

```powershell
.\tools\start_full_online_validation_logging.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -DeviceHost 192.168.1.238 -Port COM4 -OperatorPresent -BodyClear -DurationSeconds 900 -Json
```

Fill in the operator review with the helper instead of hand-editing the proof file:

```powershell
.\tools\complete_full_online_review.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -ConfirmMicUplink -ConfirmStt -ObservedTranscript "<what configured STT heard>" -ConfirmSelectedVoice -ConfirmVoiceMatch -ConfirmServoControlled -ConfirmNoServoRisk -ConfirmNoAudioRisk
```

Close the gate only when the strict checker passes:

```powershell
.\tools\check_full_online_validation.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -RequireReady -Json
```

The checker must report `full-online-validation-ready` before the firmware is considered
fully online. Until then, the display and voice-out path may be excellent, but mic voice-in
and servo validation remain open.
The collector also writes `FULL_ONLINE_NEXT_ACTIONS.md` in the same evidence folder; use it
as the current resume point if the physical validation session is paused.

For the first CoreS3 lab deploy on the private lab Wi-Fi, the calibrated speaker/output settings were:

- firmware speaker volume: `150`
- M5 speaker magnification: `16`
- selected voice: `stackchan-rvc-bright-robot`
- selected voice gain: `0.30`
- selected voice start offset: `65536` bytes
- selected voice max payload: `65536` bytes
- downlink audio chunk size: `4096` bytes
- downlink binary frame delay: `80` ms

Current 2026-07-08 lead voice path:

- live adapter: `python bridge\rvc_tts_client.py`
- warm worker: `python bridge\rvc_worker_service.py`
- base TTS: Windows System.Speech WAV rendered on the PC
- conversion: `rvc-python==0.1.5` in `C:\stackchan_rocm_venv`
- acceleration: PyTorch `2.9.1+rocm7.2.1` on AMD Radeon RX 7800 XT
- model: `output\voice_sources\stackchan_rvc_base\model\model.pth`
- index: `output\voice_sources\stackchan_rvc_base\model\model.index`
- settings: worker device `cuda:0`, f0 `pm`, pitch `2`, index rate `0.62`, RMS mix `0.72`, protect `0.28`
- robot payload: `pcm16`, 16 kHz, capped at `65536` bytes
- validated phrase: `What is your name?` -> `I am Stackchan.`
- pre-ROCm lead archive: `output\current-lead\stackchan-full-online-rvc-lead-20260708-014917.zip`
- warm-ROCm handoff archive: `output\current-lead\stackchan-full-online-warm-rocm-lead-20260708-101400.zip`
- flashed motion timing candidate archive: `output\current-lead\stackchan-motion-timing-fix-candidate-20260708-101400.zip`

Start the current warm ROCm RVC worker and live bridge from the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_rvc_worker.ps1 -StopExisting -Background -Device cuda:0 -Method pm -Port 5055
$env:STACKCHAN_RVC_WORKER_URL = "http://127.0.0.1:5055"
$env:STACKCHAN_RVC_WORKER_TIMEOUT_SECONDS = "90"
$env:STACKCHAN_RVC_MAX_AUDIO_BYTES = "65536"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_pc_brain.ps1 -StopExisting -Background -EnableAudioDownlink -TtsCommand "python bridge\rvc_tts_client.py" -TtsVoice "stackchan-rvc-warm-rocm" -DownlinkBinaryFrameDelayMs 80
```

Voice V2 DirectML has passed lab, wire, and supervised physical validation. The physical warm
API run completed four turns with all `567040` host bytes matched by the robot, no truncation,
playback errors, or forced stops, worst conversation first audio `3492.31 ms`, and worst
post-text voice first audio `1047.52 ms`. The separate speech-mouth run matched all `97920`
bytes in 25 chunks and the operator visually confirmed mouth movement. Exact procedure and
evidence are in [`VOICE_V2_DIRECTML.md`](VOICE_V2_DIRECTML.md). The supervised scripts restore
the normal port `5055` worker and production bridge after capture.

The accepted rollback firmware still has a `65536`-byte whole-response ceiling. The currently
flashed `stackchan_release_forensics` build includes Voice V2's three stable `4096`-byte speaker
buffers and reports `speaker_stream_chunked=1`. The bridge emits one mouth envelope/viseme frame
before each matching PCM chunk. Repeat tests remain guarded: the start script rejects old
firmware or unsafe actuator state, and the checker fails any forced stop, playback error,
incomplete phrase, or host/robot byte mismatch. Keep
`stackchan_wake_mww_uplink_servos_m5_voiceout` as the firmware rollback target.

The LAN bridge sends a `hello` frame immediately after the WebSocket handshake. This is
required for firmware to leave `connecting` and report `bridge_state=ready` after reconnects.

After the user confirms the body is clear and the robot has been power-cycled or side-button
recovered, start the warm ROCm servo-enabled soak with the fail-fast wrapper. Use a reduced
motion refresh cadence; the firmware's supervised motion session timeout is 900000 ms, so
refreshing every 20 seconds is unnecessary and can create debug HTTP contention during long
soaks.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_warm_rocm_full_system_soak.ps1 -OperatorPresent -BodyClear -ConfirmServoRisk -SkipWorkerRestart -SkipBridgeRestart -NoSerial -DurationSeconds 28800 -PollSeconds 30 -MotionRefreshSeconds 300 -MotionRefreshInitialDelaySeconds 150
```

The wrapper writes `preflight.json` before launching the long soak. It retries
`/motion-resume` during preflight so a one-shot actuator warm-up miss does not abort the run.
It must stop before starting the soak if `/debug` is unreachable or if the retry window still
does not make `motion_enabled=true`. By default, it also requires the motion timing candidate telemetry
fields; use `-AllowLegacyMotionTelemetry` only for an intentional old-firmware diagnostic run.
The launched soak writes `summary.json` with strict pass/fail gates. A completed full-system
servo soak must report:

- `status`: `pass`
- `issues`: empty
- `motionSampleRatio`: at least `0.95`
- `failedPolls`: at most `3`, with no more than `1` missed poll in a row
- `rvcWorkerReadySamples`: equal to `rvcWorkerPolls`
- `maxMotionSessionTimeouts`: `0` or `null`
- `maxFrameUs`: at most `50000`
- bridge socket, bridge healthy state (`ready`, `listening`, `thinking`, or `responding`),
  wake, mic, and speaker ready samples present for every successful poll

After the soak ends, run the strict evidence checker:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check_full_system_soak_evidence.ps1 -SummaryJsonPath <soak-evidence-root>\summary.json -RequireReady -Json
```

It must report `full-system-soak-ready` before the servo-enabled full-online soak gate is
closed.

The 2026-07-08 late-night attempt did not close the overnight gate: the worker and bridge
stayed healthy, but motion auto-disabled, later would not re-enable, and the robot eventually
dropped off ping/debug and the bridge socket.

If the robot is still running firmware from before the motion timing fix, flash the built
candidate only with the body clear and the user watching. The fix keeps motion session timing
on `millis()` instead of mixing `millis()` state with `micros()/1000`, which can immediately
timeout `/motion-resume` after `micros()` wraps. Candidate archive:
`output\current-lead\stackchan-motion-timing-fix-candidate-20260708-101400.zip`.

2026-07-08 update: the candidate was flashed with direct esptool hash verification after the
PlatformIO upload wrapper hung. The strict soak at
`output\pc-brain\full-system-soak-warm-rocm-servo-clean-20260708-103059` was stopped after
the robot stopped answering ping/debug and COM4 was unavailable. Finalized failure summary
reports `durationSeconds=335`, `records=12`, `failedPolls=3`,
`maxConsecutiveFailedPolls=3`, `motionRefreshFailures=4`, and
`abortReason=robot_offline_ping_debug_com_unavailable`, so this run does not close the
overnight gate. Recover the robot physically and reconfirm `-OperatorPresent -BodyClear
-ConfirmServoRisk` before launching another servo-enabled soak.

2026-07-08 remote recovery lead: after a human side-button reset, the robot recovered to
ping/debug/COM4 and passed the no-motion recovery soak at
`output\pc-brain\quiet-recovery-after-reset-20260708-134502`. The lead firmware
`stackchan_wake_mww_uplink_servos_m5_voiceout` now adds LAN debug endpoints `/recover` and
`/reboot`, recovery telemetry in `/debug`, and a conservative Wi-Fi/bridge supervisor that
restarts the network path before scheduling a board reboot. It was direct-flashed with esptool
hash verification and archived at
`output\current-lead\stackchan-recovery-firmware-lead-20260708-142700.zip`.

Remote refresh validation passed: `/recover` returned `debug_recovery_accepted=true`,
scheduled recovery after the HTTP response, refreshed Wi-Fi/bridge, and returned to
`bridge_state=ready` with `recovery_wifi_restarts=1`. The post-flash no-motion soak at
`output\pc-brain\quiet-post-recovery-firmware-20260708-142405` passed the evidence checker.

2026-07-08 face-priority/debug-task lead: the same environment was rebuilt and direct-flashed
after moving debug/recovery HTTP servicing into the intent/network task while keeping the face
task at the lead priority. A post-flash quiet soak passed at
`output\pc-brain\quiet-soak-2026-07-08T19-12-39Z`. The strict reduced-refresh full-system
servo soak passed at
`output\pc-brain\full-system-soak-face-priority-debugtask-reducedrefresh-10min-20260708-153622`
with 20/20 polls, 0 failed polls, `maxFrameUs=39767`, 2 successful motion refreshes, and
`full-system-soak-ready` from `tools\check_full_system_soak_evidence.cmd -MinDurationSeconds 600 -RequireReady`.
This lead is archived at
`output\current-lead\stackchan-face-priority-debugtask-lead-20260708-155000.zip`
with SHA256 `E0614A3C70EFCF90878B831ABDCE17ED3A70D36988A07ECC9B4B440EDD6EA701`.

2026-07-08 reset-instrumented update: after the first 8-hour full-system attempt failed
early at about 1299 seconds with two consecutive `/debug` timeouts and temporary loss of
ping/debug/bridge/COM, the same lead environment was rebuilt and direct-flashed with boot
diagnostics in `/debug`: `uptime_ms`, `boot_count`, `reset_reason`, and
`reset_reason_code`. The post-flash live state returned to `bridge_state=ready`,
`network_state=connected`, `motion_enabled=false`, and smooth 20 FPS face timing. Run a
shorter reset-instrumented diagnostic full-system servo soak before treating another
overnight attempt as a final validation.

That reset-instrumented diagnostic soak passed at
`output\pc-brain\full-system-soak-warm-rocm-servo-20260708-172959`: 2700 s, 90/90 polls,
0 failed polls, 9/9 motion refreshes, 0 motion refresh failures, `maxFrameUs=46776`,
`maxSlowFrames=42`, `maxMotionSessionTimeouts=0`, all bridge/socket/wake/mic/speaker/RVC
samples ready, and `full-system-soak-ready` from
`tools\check_full_system_soak_evidence.ps1 -MinDurationSeconds 2700 -RequireReady`. Motion
was manually stopped after the run, and live debug still reported `boot_count=1`. The next
validation gate is the overnight-length full-system soak, not another short diagnostic.

The reset-instrumented 8-hour full-system soak was launched at
`output\pc-brain\full-system-soak-warm-rocm-servo-20260708-181644` with 30 s debug polls,
300 s motion refreshes, and 150 s initial motion-refresh delay. Thread heartbeat monitor
`stackchan-8hr-soak-monitor` is attached to this evidence path during the overnight window.

This 8-hour attempt failed early at 3047 s with three failed debug polls and two consecutive
timeouts. The summary still showed the face and motion path were healthy before the loss:
`maxFrameUs=40175`, `motionRefreshes=10`, `motionRefreshFailures=0`, and
`maxMotionSessionTimeouts=0`. After the dropout, ping/debug failed, COM4 disappeared, and
the bridge socket timed out. A physical reset brought the board back with
`reset_reason="poweron"` / `reset_reason_code=1`, `boot_count=1`, motion disabled at boot,
and smooth 20 FPS face timing. Because the reset was physical, this reset reason confirms the
recovery event, not the original failure cause. Restart the PC bridge after this failure mode
to clear stale sockets; the robot should then return to `network_state=connected` and
`bridge_state=ready`.

A later servo duty-rest candidate at
`output\pc-brain\full-system-soak-warm-rocm-servo-20260708-195407` did not reach the new
50-minute threshold. It failed at 276 s with two consecutive debug timeouts:
`status=fail`, `failedPolls=2`, `maxConsecutiveFailedPolls=2`,
`abortReason=consecutive_failed_poll_limit_exceeded`, `motionRefreshes=1`,
`motionRefreshFailures=0`, `maxFrameUs=44003`, and `maxMotionSessionTimeouts=0`. The last
good poll at 210.7 s still showed `network=connected`, `bridge=ready`, `motion=true`, no
duty-rest entries yet, and the bridge socket present; afterward ping/debug failed, COM4
disappeared, and only the bridge listener remained. Do not promote that duty-rest candidate.
A more conservative profile has been built but is pending physical recovery and flash:
500 ms servo write period, 15% idle body scale, 120 s active servo windows, 30 s torque rests,
and torque release on stop/rest.

The audio-load-shed isolation run at
`output\pc-brain\full-system-soak-audio-load-shed-isolation-20260708-222813` proved the audio
guard fired during real wake/playback activity, but still failed before the 20-minute target:
1123 s of 1200 s, `failedPolls=3`, `maxConsecutiveFailedPolls=2`,
`abortReason=consecutive_failed_poll_limit_exceeded`, `maxMotionOutputSuppressEntries=9`,
`maxMotionOutputSuppressTotalMs=115130`, `maxMotionDutyRestEntries=7`,
`maxMotionSessionTimeouts=0`, and `maxFrameUs=43928`. After another utterance window the bridge
log showed the robot forcibly closed the socket. Treat this as a board power/thermal/dropout
suspect, not a face-renderer failure.

The thermal-guard firmware archived at
`output\firmware-leads\thermal-guard-20260708-231938` was flashed and showed bridge ready,
motion disabled, face about 20 FPS, chip temp around 58.5-59.5 C, and no thermal shed. Its
guarded 10-minute rerun at
`output\pc-brain\full-system-soak-thermal-guard-servo-10min-20260708-233216` failed at 245 s:
`failedPolls=2`, `maxConsecutiveFailedPolls=2`,
`abortReason=consecutive_failed_poll_limit_exceeded`, `maxChipTempC=60.5`, `maxFrameUs=43336`,
`maxMotionSessionTimeouts=0`, and no thermal suppression. The last good window had bridge
`thinking`; the robot then timed out and returned with `reset_reason=poweron`. Treat this as
mixed servo plus bridge-busy reachability-dropout evidence, not proof of power loss, heat, or
face rendering failure.

Current post-failure firmware is archived at
`output\firmware-leads\bridge-busy-load-shed-20260708-234556` and is flashed on the robot. It
keeps the audio-load and thermal sheds, and also releases servo output while the bridge is
`listening`, `thinking`, `responding`, or has pending bridge outputs, with the same 8 s cooldown.
Build passed, native logic tests passed `187/187`, direct flash verified hashes, and post-flash
watch showed bridge ready after PC bridge restart, motion disabled, face about 20 FPS, and chip
temp around 57.5-58.5 C. The next supervised servo/audio soak must capture `chip_temp_c`,
`chip_temp_max_c`, `motion_thermal_suppressed`, `motion_thermal_suppress_entries`, and the
output suppression counters.

The first bridge-busy 10-minute monitor at
`output\pc-brain\full-system-soak-bridge-busy-shed-servo-10min-20260708-235542` reached 600 s
with no failed polls, no reset, no thermal shed, no motion timeout, `maxChipTempC=60.5`,
`maxFrameUs=47288`, and 96 s of output suppression during the real bridge turn. The old checker
reported fail only because `mic_ready=false` during intentional bridge `listening`/`responding`
audio-pause windows; the soak harness/checker now allows those expected mic pauses.

The official follow-up steady monitor at
`output\pc-brain\full-system-soak-bridge-busy-shed-servo-official-10min-20260709-001050`
passed: 600 s, `okPolls=119`, `failedPolls=0`, `motionSampleRatio=1.0`,
`maxMotionSessionTimeouts=0`, `maxChipTempC=60.5`, `maxFrameUs=43945`, no thermal suppression,
RVC worker ready `10/10`, and `full-system-soak-ready` from the strict checker. That official
pass did not include a new voice turn; use the preceding `235542` run as the bridge-busy
voice-turn proof, or run a longer/voice-included official soak before final promotion.

The longer supervised bridge-busy soak at
`output\pc-brain\full-system-soak-bridge-busy-shed-servo-50min-20260709-070029` passed: 3000 s,
`okPolls=296`, one isolated failed poll, no consecutive failure beyond the strict gate,
`motionSampleRatio=1.0`, `maxMotionSessionTimeouts=0`, `maxChipTempC=60.5`, `maxFrameUs=39350`,
no thermal suppression, five successful motion refreshes, RVC worker ready `50/50`, and
`full-system-soak-ready` from the strict checker. It included fresh bridge-busy/voice overlap,
and the servo output shed was active during that overlap. Post-run debug showed bridge ready,
motion off, face smooth, and chip temp 60.5 C. At that point the next gate was an
overnight-length full-system soak.

The overnight bridge-busy soak at
`output\pc-brain\full-system-soak-bridge-busy-shed-servo-overnight-8hr-20260709-080743`
failed at 3070 s with `status=fail`, `okPolls=101`, `failedPolls=2`,
`maxConsecutiveFailedPolls=2`, `abortReason=consecutive_failed_poll_limit_exceeded`,
`motionSampleRatio=1.0`, `motionRefreshes=5`, `motionRefreshFailures=0`,
`maxMotionSessionTimeouts=0`, `maxChipTempC=61.5`, and `maxFrameUs=43098`. The last good poll
at 3005.2 s still showed network connected, bridge ready, wake/mic/speaker/RVC ready, motion
enabled, and socket remote `192.168.1.238`; the next two `/debug` polls timed out, and the PC
bridge later logged `client_disconnect=192.168.1.238:62250 reason="socket:timed out"`. Treat
this only as a repeated reachability-dropout signature. Do not document it as proven power loss,
brownout, heat, Wi-Fi failure, USB failure, firmware panic, or task starvation until an
instrumented run captures evidence for one of those causes.

The 2026-07-09 evidence/instrumentation build was archived at
`output\firmware-leads\evidence-instrumented-power-usb-20260709-093022` with firmware SHA256
`160DE85017C6792808582C8A02EB20FDA813689B433E858C533D58F51DCDE315`. It added `/debug` and
serial telemetry for CoreS3 PMU VBUS voltage, battery voltage, battery level, charging state,
min/max rail readings, and PMU read failures. The soak harness records those fields plus host
COM-port presence into `polls.json`, `progress.json`, and `summary.json`.

The first PMU-instrumented servo investigation at
`output\pc-brain\full-system-soak-instrumented-power-usb-servo-70min-20260709-105111` did not
prove the root cause of the earlier dropouts, but it did capture a useful fact: servo motion
pulled the board-reported VBUS minimum to `4395 mV`, then VBUS recovered to about `4616 mV`
after `/motion-stop` while ping/debug/bridge/COM remained available.

The first VBUS-guard candidate was archived at
`output\firmware-leads\vbus-guard-20260709-111916.zip` with firmware SHA256
`FC1FA4E60C1C20EC36826E74A166E716B1D0D51A11FA5CC8FED7DF3565DED695`. It kept the
face-priority/debug-task, recovery, bridge-busy/audio, thermal, and PMU telemetry work, and
added servo output load-shed when PMU VBUS was at or below `4450 mV`, resuming only at or above
`4600 mV`.

The first supervised VBUS-guard validation passed at
`output\pc-brain\full-system-soak-vbus-guard-servo-20min-20260709-112209`: `status=pass`,
`durationSeconds=1200`, `okPolls=234`, `failedPolls=0`, `motionSampleRatio=1.0`,
`motionRefreshes=4`, `motionRefreshFailures=0`, `maxMotionSessionTimeouts=0`,
`maxFrameUs=45130`, `maxChipTempC=59.5`, and RVC worker ready `20/20`. The strict checker
reported `full-system-soak-ready` with 31 passed, 0 failed, 0 pending. During the run the VBUS
guard cycled 5 times, `motionPowerSuppressSamples=102`, the lowest on-device VBUS minimum was
`4410 mV`, and the robot stayed reachable with face/bridge/wake/mic/speaker healthy.

The first VBUS-guard 50-minute attempt at
`output\pc-brain\full-system-soak-vbus-guard-servo-50min-20260709-120011` was intentionally
safe-stopped at about 393 s after `/debug` reported `power_vbus_min_mv=4395`. The robot was
still reachable, bridge/network were ready, face timing was healthy, and `/motion-stop`
recovered live VBUS to about `4640 mV`. Snapshot:
`output\pc-brain\full-system-soak-vbus-guard-servo-50min-20260709-120011\vbus_floor_safe_stop_20260709-120732.json`.

The current hardened VBUS-guard candidate is archived at
`output\firmware-leads\vbus-guard-hardened-20260709-121107.zip` with firmware SHA256
`9E8459C242DBBDC817D3A979AA8B56EE39DE24D1566D7B8D141391967387DD66`. The matching current-lead
handoff archive is `output\current-lead\stackchan-vbus-guard-hardened-lead-20260709-121107.zip`
with SHA256 `47388A1A0A88580EC3DF1B64BE9E908795A10E434EB357E05FA4CA368750CBC7`. This candidate
uses 100 ms PMU sampling, sheds servo output at or below `4550 mV`, resumes only at or above
`4700 mV`, and holds each power-shed state for at least `20000 ms`.

The hardened VBUS-guard validation passed at
`output\pc-brain\full-system-soak-vbus-guard-hardened-servo-20min-20260709-121456`:
`status=pass`, `durationSeconds=1200`, `okPolls=235`, `failedPolls=0`, `motionSampleRatio=1.0`,
`motionRefreshes=4`, `motionRefreshFailures=0`, `maxMotionSessionTimeouts=0`,
`maxFrameUs=44608`, `maxChipTempC=59.5`, RVC worker ready `20/20`,
`motionPowerSuppressSamples=234`, `maxMotionPowerSuppressEntries=2`, lowest sampled VBUS
`4506 mV`, and lowest on-device reported VBUS minimum `4498 mV`. The strict checker reported
`full-system-soak-ready` with 31 passed, 0 failed, 0 pending.

The hardened VBUS-guard 50-minute attempt at
`output\pc-brain\full-system-soak-vbus-guard-hardened-servo-50min-20260709-124531` was
safe-stopped at `524 s` by an external VBUS watcher after the board-reported VBUS floor reached
`4397 mV`. The robot did not drop: `okPolls=53`, `failedPolls=0`, bridge/socket/network ready,
COM4 present, `maxFrameUs=30468`, `maxMotionSessionTimeouts=0`, and post-stop debug remained
reachable at
`output\pc-brain\full-system-soak-vbus-guard-hardened-servo-50min-20260709-124531\vbus_floor_safe_stop_post_debug_20260709-125656.json`.
A wake/audio turn also occurred during this run (`bridge_uplink_turns=1`,
`bridge_downlink_playback_starts=1`), so record this as a mixed-load low-VBUS capture, not a
face-rendering failure or bridge-starvation failure.

The immediate no-servo power isolation at
`output\pc-brain\no-servo-power-isolation-10min-20260709-130429` failed at `71 s` with
`abortReason=power_vbus_sample_floor_exceeded`, `records=8`, `failedPolls=0`, live sampled
`minPowerVbusMv=4396`, motion disabled throughout, bridge/network ready, and face still around
20 FPS. This proves the current bench power condition can dip below the hard floor even without
servo motion. Treat the current source/cable path as not cleared for additional powered soak
work.

After moving Stackchan to a dedicated 5 V / 3 A wall adapter, the replacement no-servo isolation
at `output\pc-brain\no-servo-power-isolation-wall-5v3a-10min-20260709-172502` passed the full
`600 s`: `status=pass`, `okPolls=59/60`, one isolated HTTP timeout while the bridge socket stayed
present, sampled VBUS `4860-4959 mV`, board-reported minimum `4797 mV`, charging active,
`maxChipTempC=62.5`, `maxFrameUs=38604`, and all bridge/network/wake/mic/speaker/RVC readiness
samples healthy. Motion remained disabled. The checker now has `-NoMotionProfile`; the formal
isolation check passed `33/33` checks. Treat this as clearance to attempt the supervised
50-minute servo gate on the same wall supply, not as final servo or overnight validation.

The later two-hour no-motion latency baseline at
`output\pc-brain\wall-nomotion-debug-latency-4s-locksafe-2hr-20260710-120614` completed `7203 s`
and passed the corrected formal checker `37/37`. It recorded three isolated curl `28` timeouts
in 3379 probes (`0.0888%`, maximum streak one), separated by 2716.1 and 1638.6 seconds. The
bridge socket was present in every record and during every miss; motion/rail/torque stayed off,
VBUS remained `5014-5054 mV`, hard-floor events stayed zero, maximum temperature was `58.5 C`,
maximum frame time was `44707 us`, and minimum free heap was `113456`. Compare this with the
old two-second probe's `21/988` misses (`2.13%`, maximum streak three) and the first four-second
run's `3/1261` misses (`0.238%`, maximum streak one) before a host file-lock collision ended that
runner. Treat an isolated short `/debug` timeout with a still-established bridge as debug-service
latency, not as proof that the robot froze. Repeated live-debug loss or actual socket/network
loss remains a strict stop condition. The comparison and formal check are preserved beside the
passing summary as `probe-comparison.json` and `formal-check.json`.

After that safe stop, the soak tooling was tightened: the servo soak runner/checker now supports
a minimum unsuppressed-motion sample ratio and a minimum board-reported VBUS floor. The warm ROCm
servo soak launcher defaults to `MinMotionUnsuppressedSampleRatio=0.50` and
`MinPowerVbusReportedMv=4400`, so future passes cannot count a mostly power-suppressed session
as a real servo-motion pass.

Prefer the supervised recovery wrapper so the flash, post-reboot debug check, motion telemetry
check, bridge socket check, and strict warm ROCm servo soak launch stay in one evidence folder.
Run it as a dry-run first:

```powershell
.\tools\start_motion_timing_candidate_recovery_soak.cmd -OperatorPresent -BodyClear -ConfirmServoRisk -FlashCandidate -DryRun -Json
```

With Rob present, the body clear, and rollback power/control in reach, rerun without
`-DryRun`:

```powershell
.\tools\start_motion_timing_candidate_recovery_soak.cmd -OperatorPresent -BodyClear -ConfirmServoRisk -FlashCandidate -NoSerial -Json
```

If the motion timing candidate is already flashed, omit `-FlashCandidate`. The wrapper still
must refuse to start servo motion if `/debug` is unreachable, the bridge socket is absent, the
new motion telemetry is missing, `chip_temp_c`/thermal guard fields are absent, or the preflight
`/motion-resume` retry window does not make `motion_enabled=true`. For the hardened VBUS-guard
lead, also confirm `/debug` reports `motion_power_load_shed_mv=4550`,
`motion_power_resume_mv=4700`, `motion_power_min_suppress_ms=20000`, and live PMU fields before
starting a long soak.
Before and after the supervised recovery attempt, run the current-lead reproducibility checker:

```powershell
.\tools\check_current_lead_reproducibility.cmd -Json
```

Before the soak is complete it should report `current-lead-reproducible-pending-soak` with
zero failed checks. After a successful overnight run, rerun it with the completed
`summary.json`; the status must become `current-lead-reproducible-ready` before this lead is
treated as final:

```powershell
.\tools\check_current_lead_reproducibility.cmd -SoakSummaryPath <soak-evidence-root>\summary.json -RequireReady -Json
```
After flashing, check `/debug` for:

- `uptime_ms`
- `boot_count`
- `reset_reason`
- `reset_reason_code`
- `motion_actuator_ready`
- `motion_last_reason`
- `motion_enable_requests`
- `motion_session_timeouts`
- `motion_stop_calls`

The one-shot CPU RVC path remains the known-good fallback:

```powershell
$env:STACKCHAN_RVC_TIMEOUT_SECONDS = "300"
$env:STACKCHAN_RVC_DEVICE = "cpu:0"
$env:STACKCHAN_RVC_F0_METHOD = "harvest"
$env:STACKCHAN_RVC_MAX_AUDIO_BYTES = "65536"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_pc_brain.ps1 -StopExisting -Background -EnableAudioDownlink -TtsCommand "python bridge\rvc_tts.py" -TtsVoice "stackchan-rvc-live" -DownlinkBinaryFrameDelayMs 80
```

One-shot ROCm was slower for short responses because the process paid GPU/runtime startup
every turn. The warm worker keeps the model loaded: the first `pm` conversion warmed in about
29 s and the next local conversion completed in about 3 s.

When the robot is already attached to the PC bridge, `run_pc_brain_probe` may time out because
the current source-side LAN service accepts the active robot session. In that case, validate the
robot-routed text turn over serial instead:

```text
bridge turn please confirm the first deploy voice path is online in one short sentence
```

Expected markers are `[bridge_text_turn] result=accepted`, `thinking`, `response_start`,
`audio_stream_start`, 16 `audio_stream_chunk` records for a 65536-byte PCM16 stream,
`audio_stream_end`, mouth `audio` frames, and `response_end`. Opening the USB serial port can
reset the CoreS3 on some Windows setups; if that happens after a successful turn, restart the PC
brain with `-StopExisting` and confirm the debug endpoint returns `network_state=connected` and
`bridge_state=ready`.

After the robot has Wi-Fi credentials and can reach the PC, flash or provision the Wi-Fi
bridge target with `tools\flash_wifi_bridge.cmd` or the runtime `wifi set ... url
"ws://<pc-lan-ip>:8765/bridge"` command. Once the robot connects and plays the downlink
audio stream, run:

```powershell
.\tools\collect_pc_brain_deploy_evidence.cmd -DeviceHost <robot-lan-ip> -RunTests
.\tools\check_pc_brain_deploy_evidence.cmd -EvidenceJsonPath output\pc-brain\<deploy-dir>\PC_BRAIN_DEPLOY_EVIDENCE.json -EvidenceMarkdownPath output\pc-brain\<deploy-dir>\PC_BRAIN_DEPLOY_EVIDENCE.md -RequireTests -RequireReady -Json
```

The collector writes `PC_BRAIN_DEPLOY_EVIDENCE.json/md`, copies PC brain logs, and pulls
`stackchan.bridge-debug.v1` from the robot debug endpoint. The checker must report
`pc-brain-deploy-ready`; a packet that only proves bridge connectivity is not sufficient.
This proves the lab PC brain path on the current machine; it does not close the managed
desktop Python runtime payload gate.

If the deploy packet passes, leave the PC brain bridge online and run the quiet soak:

```powershell
.\tools\run_pc_brain_quiet_soak.cmd -DeviceHost <robot-lan-ip> -DurationSeconds 600 -IntervalSeconds 30
.\tools\check_pc_brain_quiet_soak_evidence.cmd -SoakJsonPath output\pc-brain\<soak-dir>\PC_BRAIN_QUIET_SOAK.json -SoakMarkdownPath output\pc-brain\<soak-dir>\PC_BRAIN_QUIET_SOAK.md -RequireReady -Json
```

The checker must report `pc-brain-quiet-soak-ready` before using PC Brain lab evidence for
release promotion notes.

After desktop package hashes, all three managed runtime payload checks, C6 evidence,
deploy audio evidence, quiet-soak evidence, production voice-source readiness, and the
human review are collected, assemble the aggregate desktop v1 packet:

```powershell
.\tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -WriteTemplate
.\tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -RequireReady -Json
```

It must report `desktop-v1-evidence-ready` before desktop PC Brain installers are treated
as v1 release-ready. Record the same full source commit in `DESKTOP_V1_REVIEW.md` and
`DESKTOP_V1_EVIDENCE_BUNDLE.json`; the aggregate desktop gate fails if those commits differ.

After both platform bundles pass and the release package, GitHub Actions, rollout status,
hardware evidence, Play internal testing, and production voice-source gates all refer to the
same release candidate, assemble the final Companion v1 packet:

```powershell
.\tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot output\companion-v1-evidence\latest -WriteTemplate
.\tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot output\companion-v1-evidence\latest -RequireReady -Json
```

It must report `companion-v1-evidence-ready` before v1 is called fully vetted.
If any release, CI, or rollout report was generated for a different commit or version, the
aggregate gate fails and the affected report must be regenerated for the final candidate.

Import the display photo or video into the packet:

```powershell
.\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg
```

Optional speech-mouth sidecar check from the extracted release folder:

```powershell
.\tools\generate_speech_envelope_sidecar.cmd -InputWav output\voice_auditions\rvc_base\final\stackchan_rvc_bright_robot.wav -OutputJson output\bright_robot.speech_envelope.json
.\tools\verify_speech_envelope_sidecar.cmd -Path output\bright_robot.speech_envelope.json
.\tools\send_speech_mouth_demo.cmd -Port COM3 -SidecarPath output\bright_robot.speech_envelope.json
```

Release evidence packets use the project-owned Stackchan Spark sample or built-in fallback pattern. An operator may generate a mouth-envelope check from an authorized local RVC model under `output/voice_auditions/`, but model files and converted RVC audio are never copied into the package.
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

Current Stackchan Alive lab note: do not treat the servo + voice/audio path as validated from the
`20260708-215656`, `20260708-222813`, `20260708-233216`, or `20260709-080743` runs. These runs
share a reachability-dropout signature, but the evidence does not prove power loss, brownout,
heat, Wi-Fi failure, USB failure, firmware panic, or task starvation. The PMU-instrumented run
then captured servo-load VBUS sag, the first VBUS guard caught another `4395 mV` floor before
dropout, and the hardened VBUS-guard firmware passed a 20-minute protected servo validation.
The next promotion candidate must continue to capture `power_vbus_mv` /
`power_vbus_min_mv` / `power_battery_mv` / `power_charging_state` alongside `chip_temp_c` /
`chip_temp_max_c`, preserve host COM-port presence per poll, show whether
`motion_power_suppressed` and `motion_thermal_suppressed` trip. Because the hardened 50-minute
attempt safely caught a `4397 mV` floor while the robot stayed reachable, and the follow-up
no-servo isolation caught a live `4396 mV` sample with motion off, do not launch another powered
soak from either motherboard USB path. The dedicated 5 V / 3 A wall source subsequently passed
the 10-minute no-motion gate with a `4860 mV` sampled floor and `4797 mV` board-reported floor.
Keep that exact power path in place, then repeat a real unsuppressed 50-minute hardened guarded
servo soak plus an overnight guarded soak before the full system can be called final.

The current promotion candidate is now the Power Coordinator lead at
`output\firmware-leads\power-coordinator-charge-backed-20260709-212029`, firmware SHA256
`6CC6E32348919ED795392618554F27D58FABD5AB538435FE4D4D07EE0E115300`. It centralizes servo and
speaker power policy, keeps both rails off when idle, rejects impossible PMIC samples, and only
permits motion below the 4550 mV soft floor when VBUS remains above the unconditional 4400 mV
floor and fresh INA226 current proves the external source is charging the body battery. Its
supervised 60-second servo qualification passed 30/30 polls with minimum VBUS 4817 mV, maximum
display frame 45432 us, maximum temperature 61.5 C, no attach/ping/session failures, and
post-stop servo rail and torque off. This is the prerequisite pass, not the 50-minute promotion
gate. Continue to report historical dropouts as unexplained unless a captured reset or runtime
record directly identifies their cause.

The first 50-minute Power Coordinator promotion attempt was safe-stopped at 1015 seconds for one
motion session timeout despite four successful `/motion-resume` transports. Evidence and source
inspection showed that a repeated resume updated the requested boolean but did not renew the
ActuationEngine deadline while it was already enabled. Candidate
`output\firmware-leads\power-coordinator-session-refresh-fix-20260709-214555` adds explicit
session renewal and renewal telemetry while preserving the 15-minute no-renewal failsafe. It
passes 191/191 native tests and a full build. It was subsequently direct-flashed with esptool hash
verification and returned online with motion/rail/torque off and the new counters present. Move
back to the dedicated 5 V / 3 A BASE supply, obtain fresh operator/body/servo-risk confirmation,
and pass a short renewal-boundary check before another 50-minute promotion soak.

The first renewal-boundary attempt at
`output\pc-brain\session-refresh-boundary-wall-servo-17min-20260709-222201` stopped before its
first renewal because the board's accepted VBUS minimum reached 4396 mV, below the strict 4400 mV
hard floor. The sampled 5-second polls bottomed at 4451 mV. The coordinator had already removed
servo rail and torque for duty rest and then entered protected power shedding; no unsafe rail or
torque state was observed. Bridge, network, face, wake, audio readiness, and temperature remained
healthy. Do not call the renewal fix physically validated from this run, and do not attribute the
sub-floor dip to active servo draw because the rail was off when it was recorded.

The accepted lead is archived at
`output\firmware-leads\power-coordinator-priority2-accepted-60min-20260710-003026.zip` with
firmware SHA256 `3C40D5A0F006B67D175ED963133E90F889AE600D5C1F0F419E06FE7B99786C10`
and archive SHA256 `3C87F9EDE0B32FB6C0A6E92EE20BC7B5F64F6F4EA78254E5179A0AD203348C99`. It uses the dedicated
5 V / 3 A BASE input for runtime, reduces AXP2101 charging to 125 mA before motion/audio load,
holds that rate through duty rest and for 30 seconds after the session, counts PMIC VBUS loss
transitions, and runs motion bookkeeping one task-priority level below the face.

Its short supervised boundary evidence is
`output\pc-brain\power-coordinator-priority2-wall-servo-6min-20260709-231534`: 360 seconds,
169/169 successful polls, two duty-rest transitions, no power suppression, no PMIC input loss,
no motion timeout, no unsafe rail/torque state, live VBUS floor 4676 mV, maximum display frame
40938 us, maximum temperature 60.5 C, and bridge/network/wake/mic/speaker/RVC ready throughout.
The formal checker passed 33/33. Post-stop charging returned from 125 to 700 mA without a sag;
VBUS stayed 4908-4976 mV while rail and torque remained off. This was the prerequisite boundary
pass.

Final acceptance evidence is
`output\pc-brain\power-coordinator-priority2-wall-servo-60min-20260709-232808`: 3601 seconds,
707/707 successful polls, no failed polls, motion sample and unsuppressed-motion ratios both
0.9972, 137 duty-rest samples, no output/thermal/power suppression samples, no motion timeout,
12 successful refreshes, no unsafe rail/torque state, live VBUS floor 4817 mV, maximum display
frame 42922 us, maximum temperature 60.5 C, and bridge/network/wake/mic/speaker/RVC ready
throughout. It crossed the prior roughly 51-minute failure boundary and the formal checker
passed 33/33. The 45-sample post-stop record kept motion/rail/torque off, restored 700 mA
charging, held VBUS at 4912-4956 mV, and recorded no new PMIC loss. Keep
`MaxDisplayFrameUs=50000`; any longer run is a resilience soak using the same or stricter gates.

The first eight-hour resilience attempt using that accepted lead was intentionally safe-stopped
at 4569 seconds. Evidence root:
`output\pc-brain\power-coordinator-priority2-wall-servo-resilience-8hr-20260710-003342`.
All 897 polls succeeded, bridge/RVC stayed ready, face timing and temperature remained healthy,
and there was no motion timeout or reset. Live sampled VBUS reached 4406 mV and the firmware's
accepted boot minimum advanced to 4398 mV, below the 4400 mV hard floor. The deepest polled
event occurred while the servo rail, torque, and speaker were off; body current indicated
charging and PMIC VBUS remained present. Stop and preserve this as a low-floor event without
claiming whether it was an upstream supply/contact transient or a plausible PMIC ADC/I2C
measurement transient. The old runner omitted body INA226 bus voltage, so that distinction is
not available from this run.

Candidate `output\firmware-leads\power-floor-event-instrumentation-candidate-20260710-020829.zip`
adds the missing discriminator and run-relative gate: body bus voltage/power in every record,
hard-floor sample/entry/confirmation counters, an immediate PMIC confirmation read, event-time
load snapshots, and fail-fast on a hard-floor entry-count increment. Candidate firmware SHA256
is `DC7B8358EEE7817BEE850B08077E4A9C5C3FA8780D7DB5F1F0E679F95B785F7F`; archive SHA256 is
`FE62C045E00FF330B78602A3A51898E115F02FB1330A072D64750202033339C6`. Native tests pass 194/194
and the full build passes. It is not flashed. Keep the accepted 60-minute lead on the robot until
an operator reviews this event and explicitly clears a diagnostic flash; validate the new fields
with motion off before another supervised servo run.

### PMIC Blackout Forensics Gate

Historical full-off events remain unexplained. They have occurred with motion on and off, while
motion-enabled runs have also passed for 52 and 60 minutes. Do not describe the release blocker
as a proven servo overload, PC-USB problem, wall-supply problem, thermal shutdown, or firmware
panic until a direct record supports that claim. A corrected two-hour no-motion run also proved
that isolated `/debug` timeouts can occur while the bridge socket and robot remain healthy.

The `stackchan_release_forensics` environment captures AXP2101 IRQ status at the earliest
post-`M5.begin()` point and throughout runtime. It records VBUS/battery transitions, power-key
events, SOC/temperature/overvoltage protections, BATFET/LDO overcurrent, and watchdog expiry,
plus event-time voltage, load, speaker, motion, temperature, and heap context. Disabled
informational raw bits are cleared and tracked separately from strict selected events. This build
is currently flashed and has passed short wall-powered motion-off and servo qualification, but the
accepted rollback remains unchanged and the diagnostic build is not yet a final accepted release.

Current verified archive:
`output\firmware-candidates\forensics-validated-20260710-204449.zip`, SHA256
`48FF8AFB40906E4CD14E2A8373486FD81DE115656B46AA5A96A50657A0D203BD`. The exact candidate
firmware SHA256 is `32472084CABBFDA57A72B0A9B81D0709F3B3D37EF4410C20756DA6C45607AF24`;
the bundled accepted rollback is `3C40D5A0F006B67D175ED963133E90F889AE600D5C1F0F419E06FE7B99786C10`.
The six-minute servo evidence at
`output\pc-brain\release-forensics-wall-servo-6min-20260710-203435` passed 71/71 polls and the
formal checker passed 42/42, with no new PMIC, protective, VBUS-loss, or hard-floor event.

Flash only with the body clear and explicit servo-risk confirmation:

```powershell
.\tools\flash_device.ps1 -Environment stackchan_release_forensics -Port COM4 -ConfirmServoRisk
```

Before enabling motion, require `/debug` fields `power_forensics_enabled=true`,
`power_forensics_irq_enable_succeeded=true`, and `power_forensics_boot_status_valid=true`.
The first post-flash boot is a baseline. After switching to the 5 V / 3 A BASE supply, begin the
soak only after the setup VBUS transition has been sampled and baselined. Pass
`-RequirePowerForensics` to `tools\start_warm_rocm_full_system_soak.ps1`.

For the final integrated production candidate, start the paired local vision worker and confirm
authenticated target updates are advancing, then pass `-RequireFinalIntegration`. This switch now
includes camera capture and host vision alongside RGB, touch, and IMU. Start with a short supervised
run before the long release soak:

```powershell
.\tools\start_production_full_system_soak.ps1 `
  -DurationSeconds 900 `
  -PollSeconds 5 `
  -OperatorPresent -BodyClear -ConfirmServoRisk
```

This production wrapper requires the already-running DirectML worker on `127.0.0.1:5059` and the
existing production bridge; it will not restart the retired warm ROCm path. The underlying strict
wrapper verifies motion-off, power/display/network/socket gates, advancing authenticated vision,
and a stable face before enabling servos. Final integration also requires a clean pinned Git commit;
commit the reviewed release candidate before starting the soak so every evidence artifact can be
tied to the exact source and installed firmware SHA-256.

After completion, formally verify the same profile:

```powershell
.\tools\check_full_system_soak_evidence.ps1 `
  -SummaryJsonPath <evidence-root>\summary.json `
  -MinDurationSeconds 900 `
  -RequirePowerForensics `
  -RequireFinalIntegration `
  -RequireReady -Json
```

For camera-only fault isolation, the separate diagnostic camera profile remains available. Stop the
production run cleanly before flashing it. Configure a temporary six-digit pairing code, start the
local worker from `docs\LOCAL_VISION.md`, run without motion refresh, and require both sensor and
host-loop progress:

```powershell
.\tools\run_full_system_soak_http_motion.ps1 `
  -EvidenceRoot output\pc-brain\camera-capture-probe-2min `
  -DurationSeconds 120 -PollSeconds 5 -MotionRefreshSeconds 0 -NoSerial `
  -RequireBridgeSocket -RequireWakeReady -RequireMicReady -RequireSpeakerReady `
  -RequirePowerCoordinator -RequirePowerForensics -RequirePmicVbusStable `
  -RequireNoNewHardFloorEvents -RequireCameraCapture -RequireCameraHostVision `
  -MaxCameraCaptureUs 250000 `
  -MaxAllowedChipTempC 68 -MinPowerVbusMv 4400 -MinPowerVbusReportedMv 4400 `
  -MaxDisplayFrameUs 50000 -FailFastOnStrictBreach
```

Verify that probe with `-NoMotionProfile -RequireCameraCapture -RequireCameraHostVision`.
Visible human-face acquire/loss/reacquire and sound-aware speaker selection remain required;
counters cannot substitute for operator observation. Clear the diagnostic profile's temporary
pairing code and reflash the integrated production candidate afterward; the isolated camera probe
cannot be promoted directly.

For the bounded wake/listen/follow gate, first start the paired vision worker and wait for a stable
face lock. With a present operator, clear body, and fresh servo-risk confirmation, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\camera_follow_wake_validation.ps1 `
  -OperatorPresent -BodyClear -ConfirmServoRisk
```

When it prints `CAMERA FOLLOW ACTIVE`, say `Hey Stackchan` once and ask `What is your name?`
once. Accept only when the summary reports `telemetry_pass_pending_visual`, the operator confirms
visible following continued during microphone capture, and `motionStopVerified` is true. A missing
face lock is `not started`, not a behavioral pass or failure.

### Confirmed LAN OTA Baseline (2026-07-11)

Authenticated LAN OTA is installed and confirmed on both `app0` and `app1`; the exact image is
SHA256 `465DC560663DD3D0559AA9F986D1C46CEEE2DE5D2640309D9EDED1E485D15F1D`.
The device reports bootloader rollback enabled and software-only rollback false. Each slot passed
the 30-second runtime-health window with motion, servo rail, and torque off. Use
`docs\LAN_OTA.md` and the private build token; never expose port 8790 outside the trusted LAN.

Later final-integration testing intentionally placed the oriented camera diagnostic on `app0` and
restored the archived production image on `app1`. The current production SHA256 is
`875FE2DE5FB93BECEF6C72C08C1951326439CDCAE299528970C28D43CF115CFB`; restore evidence is
`output\hardware-evidence\final-integration\production-voice-restore-20260711-141611`. Do not
assume both slots contain production during this supervised camera phase. The camera slot is
diagnostic-only and must be replaced before release promotion.

The live host memory store was also migrated from `stackchan.bridge-memory.v2` to v3 with an atomic
backup. v3 drops legacy model-authored robot-state residue, permits character memory only in
approved `user.*` and `project.*` namespaces, and reserves expiring `robot.*` context for typed
runtime telemetry. This prevents stale remembered state from contradicting the current heartbeat.

On Windows, set `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` for serial PlatformIO uploads. Without
that setting, PlatformIO's output reader can fail on esptool's Unicode progress bar while the child
writer remains alive. This is a host-output failure, not robot power or serial evidence.

OTA boot health requires the runtime, face task, firmware tasks, Wi-Fi association, power, and heap.
It intentionally does not require the external PC bridge session. Early boot masks may include
display, task, and Wi-Fi warm-up; confirmation requires the last failure mask to remain zero for 30
continuous seconds. The formal release soak still enforces the stricter 50 ms display gate.

If Stackchan fully turns off, do not unplug or swap the cable. Start:

```powershell
.\tools\capture_first_post_return_power_forensics.ps1 `
  -EvidenceRoot output\pc-brain\power-forensics-next-blackout
```

Then press the side button once. The listener preserves the first post-return reset reason and
PMIC boot event before any other request and safe-stops unexpected motion. Interpret the result
using `docs\POWER_BLACKOUT_FORENSICS.md`. A `poweron` reset with no retained PMIC event remains
unknown; it is not evidence that power was healthy. Do not run another blind overnight soak.

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
