# Device Bring-Up

Use this when the Stack-chan hardware arrives.

## Preflight

1. Confirm battery is charged or USB-C power is stable.
2. Keep the body clear; do not force the yaw or pitch axes while powered.
3. Start an evidence packet for the release under test from the source checkout:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

This copies the release ZIP into the packet and writes `logs/package_verify.log`, which is required for promotion.
It also creates `BENCH_STATUS.md/json`, `NEXT_STEPS.md`, plus runnable `RUN_DISPLAY_ONLY.cmd`, `RUN_SPEECH_MOUTH_DEMO.cmd`, `RUN_SPEAK_ALL_INTENTS.cmd`, `RUN_SERVO_CALIBRATION.cmd`, `RUN_SOAK_MONITOR.cmd`, `RUN_PACKAGE_VERIFY.cmd`, `RUN_PROGRESS_CHECK.cmd`, and `RUN_EVIDENCE_VERIFY.cmd` files in the evidence packet.
Open `BENCH_STATUS.md` first for the current next action, then `NEXT_STEPS.md` for the full bench run order and hard stops before servo motion, audio review, and consumer promotion.

Use this one-step preparation helper instead when you want package verification, display-flash dry-run, and evidence packet creation together:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

If you only have the extracted release ZIP, run the same helper from inside the extracted folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

4. Check the exact release-binary flash command without touching the device:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -DryRun -Monitor -Port COM3
```

5. Flash the display-only binary from the verified release package first:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor -Port COM3
```

Expected result: the CoreS3 display shows the procedural face and serial logs include dry-run servo mode.
Display telemetry should print about every 5 seconds with `frame_ms_avg`, `frame_ms_max`, `fps_window`, `frame_budget_us=33333`, and `slow_frames`.
Face animator telemetry should also print about every 5 seconds with `[face]`, `blink_count`, `saccade_count`, `gesture_active`, `speech_active`, and `speech_env`.
Speech cue telemetry should print `[speech]` lines with `seq`, `intent`, `earcon`, `earcon_delay_ms`, and `text` whenever the persona emits a new cue. The speech output adapter should then print `[speech_audio]` with `source=packaged_prompt`, `prompt_id`, `prompt_wav`, `prompt_sidecar`, `earcon_samples`, `earcon_peak`, and `earcon_checksum` so the P6 prompt/earcon handoff is visible. The audio-output boundary should also print `[audio_out]` with `seq`, `source`, `prompt_id`, `wav`, `sidecar`, `earcon_samples`, `sidecar_frames`, `sidecar_frame_ms`, `playback_ms`, `hw_ready`, `hw_playing`, `hw_starts`, and `duck_on_barge_in`. The display mouth is driven by the packaged sidecar timing while the M5 speaker plays the generated firmware WAV asset; if a `UserSpeaking` event arrives during playback, `AudioOut` ducks the mouth/audio envelope so barge-in is visible and audible. Packaged prompt sidecars live under `media/voice/sidecars/` in the release packet and are generated from the Stackchan Spark WAV prompts during packaging.
Heartbeat telemetry should include `[system]`, `heap_free`, `heap_min`, and task stack high-water marks for loop, motion, face, and intent tasks. Runtime status should include `[runtime]`, `motion_enabled`, `demo_enabled`, `reduced_motion`, `speech_active`, `speech_env`, `camera_ready`, `camera_hw`, `camera_active`, `camera_events`, `speech_adapter_ready`, `speech_adapter_hw`, `speech_cues`, `speech_earcons`, `audio_out_ready`, `audio_out_hw`, `audio_out_hw_ready`, `audio_out_core0`, `audio_out_requests`, `audio_out_playing`, `audio_out_frames`, `audio_out_ducks`, `audio_out_hw_frames`, `audio_out_hw_drops`, `bridge_ready`, `bridge_state`, `bridge_messages`, `bridge_outputs`, `bridge_parse_errors`, and `bridge_timeouts`. Camera hardware capture is compiled off by default until the GC0308/ESP-DL producer is enabled; the P5 camera adapter still owns the same `FaceDetected`/`FaceLost` event boundary used by the `facepos` bench commands. P7 bridge status uses the same runtime line so bench transcripts can prove the serial bridge parser is connected, message/output counters are moving, malformed bridge messages increment `bridge_parse_errors`, and stalled bridge sessions increment `bridge_timeouts`.

The firmware also accepts deterministic serial bench controls at `115200` baud. Send one command per line to force a mode/event and verify face transitions plus `[speech]` cue telemetry without waiting for the random demo scheduler:

```text
mode listen
mode think
mode speak
mode idle
event touch
event response
event speech_end
touch cheek
touch forehead
touch 0.25 -0.60 0.75
proximity 0.85
pickup 0.80
shake 1.0
putdown
tilt x=0.40 y=-0.20 z=0.90
sound dir=-45 level=0.70
noise level=0.90
command 1
command wake_up
command look_at_me
command stop_moving
command how_do_you_feel
facepos x=-0.50 y=0.25 s=0.70
facepos 0.40 -0.20 0.60
facelost
speech 0.8 ah
speech 0.5 oh
speech 0.7 ee 900
speech clear
speak <boot|idle|attend|listen|think|speak|react|happy|concern|sleep|error|safety>
ambient 12 22
ambient lux 700 hour 10
time 22
circadian hour 7
status
help
```

An optional strength value in `[0.0, 1.0]` may follow mode/event commands, for example `mode listen 0.75`. Physical-sense commands simulate the P2 hardware events before touch/proximity/IMU adapters are connected: `touch cheek`, `touch forehead`, `touch <x> <y> [strength]`, `proximity <strength>`, `pickup [strength]`, `shake [strength]`, `putdown`, and `tilt <x> <y> <z>`. `shake` also logs `motion_enabled=0` and uses the existing motion-control queue as a safety hold; `putdown` logs `motion_enabled=1` as the bench auto-resume. Audio-awareness commands simulate the first P3 microphone outputs before ES7210 capture is connected: `sound dir=<deg> level=<strength>` publishes a directional voice/sound event with normalized azimuth in `payload_x`, and `noise level=<strength>` publishes a loud-noise startle event. Accepted audio-awareness commands also log `[audio] event=... detect_ms=... frame_ms=... latency_ms=... level=... azimuth_deg=...` after the event becomes a published frame, which is the same latency contract the future mic task will feed. P4 command-map bench commands use `command <1-5|go_to_sleep|wake_up|look_at_me|stop_moving|how_do_you_feel>` and mirror the future ESP-SR MultiNet phrase IDs in `data/commands.yaml`; each accepted command carries an immediate speech cue and logs `cue_intent=... cue_earcon=...`, while `command stop_moving` also uses the existing motion-control queue and logs `motion_enabled=0`. P5 vision bench commands use `facepos x=<..> y=<..> s=<..>` or `facepos <x> <y> <size>` to publish a face-position payload before camera bring-up, and `facelost` to exercise the short last-seen search behavior. Speech commands use `speech <envelope> <ah|oh|ee|neutral> [duration_ms]`; the duration defaults to 600 ms and is clamped to 50-2000 ms. Direct packaged speech commands use `speak <boot|idle|attend|listen|think|speak|react|happy|concern|sleep|error|safety>` and log `command=speak_intent`, `cue_intent=...`, `cue_earcon=...`, followed by `[speech]`, `[speech_audio]`, and `[audio_out]` telemetry when the prompt handoff is accepted. P7 bridge bench commands drive the same `BridgeClient` parser used by the future LAN bridge: `bridge hello`, `bridge thinking [seq]`, `bridge response <intent> [seq] <short text>`, `bridge audio <env> <ah|oh|ee|neutral> [duration_ms] [final]`, `bridge end [seq]`, and `bridge error <code>` log `[bridge]` telemetry and route into the normal event, speech cue, and mouth-envelope paths. Ambient commands use `ambient <lux> <hour>` or `ambient lux <lux> hour <0-23>` to simulate light/RTC context before the physical sensor path is connected. Low lux at night increases fatigue and lowers arousal; bright daytime light makes Stackchan a little more alert. Time commands use `time <0-23>` or `circadian hour <0-23>` to simulate RTC-only circadian drift; evening/night hours bias drowsy/yawn behavior and morning hours gently recover fatigue. Send `status`, `telemetry`, or `health` to print immediate `[heartbeat]`, `[system]`, and `[runtime]` telemetry without waiting for the periodic heartbeat. Send `help` or `?` to print the command summary on serial. Each accepted command logs `[control] command=... mode=... event=... strength=... payload_x=... payload_y=... payload_z=... ambient_lux=... hour=... circadian_hour=... cue_intent=... cue_earcon=... bridge_line=... at_ms=...` when those fields apply and holds off demo events briefly so the commanded state remains observable. For long deterministic checks, send `demo off` to stop random demo events and `demo on` or `demo resume` to restart them.

The same bench path also listens to CoreS3 inputs: screen tap = React/UserTouched, screen hold = Listen/UserNear, BtnA = Listen, BtnB = Think, and BtnC = Speak. These input events log the same `[control]` telemetry as serial commands.

To quickly exercise the speech-reactive mouth path after display-only firmware is running, use the host helper:

```powershell
.\tools\send_speech_mouth_demo.cmd -Port COM3
```

To drive that same mouth path from an actual WAV envelope, generate a sidecar and stream it:

```powershell
.\tools\generate_speech_envelope_sidecar.cmd -InputWav output\voice_auditions\rvc_base\final\stackchan_rvc_bright_robot.wav -OutputJson output\speech\bright_robot.speech_envelope.json
.\tools\verify_speech_envelope_sidecar.cmd -Path output\speech\bright_robot.speech_envelope.json
.\tools\send_speech_mouth_demo.cmd -Port COM3 -SidecarPath output\speech\bright_robot.speech_envelope.json
```

The generated evidence packet also includes required `RUN_SPEECH_MOUTH_DEMO.cmd` evidence, which captures streamed envelope commands and any immediate device readback to `logs\speech_mouth_demo_serial.log`. Run `RUN_SPEAK_ALL_INTENTS.cmd` next to capture `logs\speak_all_intents_serial.log` with every packaged intent, earcon, and `[audio_out]` handoff.

To exercise the P7 bridge bench route, run:

```powershell
.\tools\send_bridge_replay_demo.cmd -Port COM3
```

Inside a generated evidence packet, `RUN_BRIDGE_REPLAY.cmd` captures the same deterministic bridge transcript to `logs\bridge_replay_serial.log`. This checks `[bridge]`, `[speech]`, mouth-envelope, and runtime bridge counter telemetry without needing the LAN companion service yet.

For review streams or long bench recordings where the face should be calmer in the background, set `STACKCHAN_REDUCED_MOTION=1` in the active PlatformIO environment. The firmware logs `[face] reduced_motion=1` at startup and keeps blink/saccade/breathing behavior active with reduced amplitude.

You can also toggle this at runtime from the serial monitor without reflashing:

```text
reduced on
reduced off
motion reduced on
motion reduced off
motion stop
motion resume
demo off
demo on
safe stop
safe resume
```

The reduced-motion command logs `[control] command=reduced_motion_on reduced_motion=1` or `[control] command=reduced_motion_off reduced_motion=0`, then the face task applies the change and logs the new `[face] reduced_motion=` state.
These runtime command lines count as display bench-control telemetry in the evidence checks, but they do not replace the required photo, video, speaker audio, or strict hardware logs.

If the device needs to be calmed quickly, send `safe stop` or `panic`. This combined command stops motion writes, disables random demo events, enables reduced motion, and clears the speech-mouth envelope in one serial line. Send `safe resume` or `restore` after the bench is clear to resume motion, resume demo events, clear reduced motion, and clear any held speech-mouth envelope.

During supervised servo tests, send `motion stop`, `servo off`, or `halt` to call the actuator stop hook and suppress further motion writes. Send `motion resume` or `servos on` only after the body is clear and you are ready to continue. The firmware logs `[motion] enabled=0` or `[motion] enabled=1` when the motion task applies the command.

## Servo Enable Gate

Servos are disabled by default in `platformio.ini`:

```ini
-D STACKCHAN_ENABLE_SERVOS=0
-D STACKCHAN_ENABLE_SPEAKER=1
```

Use the default display-only environment first:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -Monitor -Port COM3
```

Check the servo upload command without touching the device:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware servo_calibration -ConfirmServoRisk -DryRun -Monitor -Port COM3
```

Only use the servo calibration environment after the display-only build runs and the body is on a clear surface:

The servo-calibration firmware keeps `STACKCHAN_ENABLE_SPEAKER=0` so calibration and motion-risk checks do not produce speaker output. The display-only firmware keeps speaker output enabled and should report `audio_out_hw_ready=1` if the M5 speaker path initializes.

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware servo_calibration -ConfirmServoRisk -Monitor -Port COM3
```

For development builds from source, use `tools/flash_device.cmd`; for release evidence, use `tools/flash_release_firmware.cmd` so the tested device matches the verified package.

The initial hardware mapping assumes CoreS3 M5 SCS servos on pins `1` and `2`, matching the upstream `stackchan-arduino` default for CoreS3. If the hardware behaves differently, stop and update `StackChanServoAdapter` before further testing.

Save serial logs, photos, and calibration notes into the evidence packet created during preflight.
When using the generated `RUN_*.cmd` files, display, servo, and soak serial output is written directly under the packet's `logs/` folder.
Run `RUN_PROGRESS_CHECK.cmd` during testing to refresh `BENCH_STATUS.md/json` and list missing fields, logs, serial markers, checklist items, media evidence, and calibration placeholders before the strict promotion verifier is run.
If the packet is handed to someone else, send `BENCH_STATUS.md`, `NEXT_STEPS.md`, and `ROLLOUT_STATUS.md` together so they can see the next action and the current gate state without reading every packet file.

## First Hardware Tests

1. Watch serial output for boot, display, and servo messages.
2. Confirm pitch moves gently around center.
3. Confirm yaw behavior before trusting absolute yaw.
4. If yaw rotates continuously or hunts, set yaw mode to disabled in the motion target path and continue with display plus pitch only.
5. If motion looks unsafe, send `motion stop` or `halt` immediately before touching the device.
6. Run for 10 minutes and watch for resets, task stalls, jitter, heat, repeated nonzero `slow_frames` in display telemetry, a flat `[face]` line that never increments `blink_count` or `saccade_count`, or steadily falling `heap_min` / stack high-water margins.

## Rollout Criteria

- `pio run` succeeds from a clean checkout.
- Display-only firmware runs without resets.
- Servo-enabled firmware passes a supervised 10-minute burn-in.
- Yaw mode is classified as angle, velocity, or disabled.
- Calibration values are written to `data/calibration.yaml`.
- No high-level intent code writes directly to servos or display.
