# Stackchan First Deploy Status

Status timestamp: 2026-07-12 07:26 America/New_York

## Current Lead: Power-Coordinated Full-Online Accepted Lead

This supersedes the older recovery-only status below. The current physical lead is the
full-online CoreS3 firmware with smooth face, bot-local wake, Whisper STT uplink,
Gemma 4 PC brain, warm PC-side RVC voice conversion, M5 speaker downlink, and servo
support compiled with motion disabled at boot.

### Corrected PMIC And Bridge-Port Candidate (2026-07-12)

- The apparent bridge regression in the first 4.60 V VINDPM builds is now explained by direct
  binary evidence. Those private builds embedded the PC host but omitted
  `STACKCHAN_BRIDGE_PORT`; the legacy firmware default was `8788` while every production PC and
  companion bridge listens on `8765`. Archived ELF rodata contains little-endian `0x2254`
  (`8788`), matching the repeated five-second TCP `EINPROGRESS` timeouts. Restoring the old image
  or loading the persisted NVS record on `8765` connected on the first attempt under unchanged
  host conditions. This finding explains that diagnostic bridge failure only; it does not claim
  to explain the historical full-power-off events.
- Source commit `5e2b115a5e1154cdfab8ce4b705a4a2a97480511` changes all firmware bridge
  defaults to the canonical `8765`, makes a host-only PlatformIO build explicitly select `8765`,
  validates the TCP port range, and exposes `network_config_source` plus
  `network_bridge_port` in `/debug` and soak evidence. Regression coverage passes `245/245`
  native tests, five PlatformIO hook tests, the architecture verifier, the soak evidence
  contract, and the warm-soak wrapper contract.
- The first corrected-port image, SHA256
  `1649537EF829C8B5068A20D94383B453698EBB1C95BB2831E64745822684D216`, passed its short power and
  actuator gates. Its one-hour run at
  `output\pc-brain\pmic-port-fix-servo-60min-20260712-064307` stopped after `154 s` only because
  the old acceptance rule treated every IMU event as fatal. Preserved forensics classify the
  event as `shaken`, `self_motion=true`; there was no reset, power, bridge, display, motion-session,
  camera, or actuator-safety failure. Do not present this as a failed robot or firmware run.
- Source commit `fd07b62a81460f9066f67bc6955f57f1e3b8971a` separates self-motion IMU events from external
  events, records last-event timing/forensics, permits accounted self-motion during actuator
  acceptance, and increases the bounded read path to five attempts. Terminal IMU read failures
  and external events remain strict failures.
- The installed superseding private image is SHA256
  `4F7B02616E8CC42C3066F732A4E899717129049AFE95051F996C600FB7E02BF2`, archived at
  `output\private\firmware-candidates\pmic-port-imu-accounting-fd07b62a-20260712-065503`. It uses
  persisted NVS network configuration on port `8765`, VINDPM target/readback `4600 mV`, the same
  `1500 mA` input limit, and boots with motion disabled.
- The exact image passed the 180-second no-motion qualification at
  `output\pc-brain\imu-accounting-nomotion-3min-20260712-065626` with `36/36` good polls and a
  formal `71/71` result. It then passed the 300-second actuator qualification at
  `output\pc-brain\imu-accounting-servo-5min-20260712-070001` with `59/59` good polls, every motion
  sample unsuppressed, VBUS floor `4973 mV`, maximum frame `29618 us`, no terminal/external IMU
  event, and a formal `70/70` result.
- The exact-image one-hour actuator acceptance is active at
  `output\pc-brain\imu-accounting-servo-60min-20260712-070606`. It must pass its terminal summary
  and formal checker before the same image advances to the eight-hour continuation or release lead.

### Release Acceptance Camera-Transport Finding (2026-07-12)

- The exact installed private candidate at source commit
  `dae9065bb08cd0ca50f49b29e2d0cbcff0f9b882`, firmware SHA256
  `28172C6BF20BDCB14803DBC93B6FB477456877DBE5D5893D3E8F0FAE3BFB2AD3`, ran the strict
  actuator-enabled final-integration soak at
  `output\pc-brain\release-acceptance-final-servo-60min-20260712-022700` for `1287 s`.
  All `252/252` polls succeeded. Motion was sampled on every poll, no motion-session timeout
  occurred, VBUS stayed at or above `4815 mV`, maximum chip temperature was `67.5 C`, maximum
  display frame time was `37450 us`, and there was no reset, PMIC protective/VBUS-loss event,
  hard-floor event, camera capture failure, camera authentication failure, or IMU event above the
  run baseline.
- The runner stopped because the aggregate `camera_host_frame_failures` counter advanced once.
  Adjacent records show camera requests, captures, and target updates continued. Source-path
  inspection shows this exact counter combination represents an interrupted HTTP PGM response
  write: `camera_capture_failures` stayed zero, while the response body did not finish before the
  bounded write loop ended. That can occur on client disconnect or the three-second write deadline;
  the evidence does not distinguish between them and
  does not support classifying the event as a robot freeze, blackout, camera failure, or power
  failure. The runner verified motion-stop, and a post-stop snapshot is preserved as
  `post-stop-forensics.json` in the evidence root.
- The candidate worktree now separates host capture failures from response-write transport
  failures, records attempts/successes/failures/current and maximum streak, retries one host vision
  transport miss after `50 ms`, and keeps true capture/authentication failures fail-fast. The soak
  gate permits only a bounded recovered response-write rate: at most `20` failures, no more than
  `0.1%` after `100` attempts, and never a streak above one. This work passes `243/243` native
  tests, `218/218` bridge tests, the soak evidence contract, PowerShell parse checks, and the full
  private camera firmware build at `56.5%` RAM and `42.9%` flash. It is not the installed lead
  until committed, archived, OTA-confirmed, and qualified against its own SHA256.

### Integrated Soak And IMU Hardening Checkpoint (2026-07-12)

- The clean prerelease package at source commit
  `70ae35bfdd9af0923ed81210eda825fa2c7ea220` is
  `output\release\stackchan_alive_prerelease-70ae35bf.zip`, SHA256
  `D7761C3CA1EE2B6C5795089DA0C0F7B49F12651762279CB9BC3E2AD4BB039CA5`.
  A fresh independent extraction verification passed when invoked with package version
  `prerelease-70ae35bf`. This verifies the archive contract; it does not close the physical
  release gates.
- A strict no-motion full-firmware integration run at
  `output\pc-brain\full-firmware-integrated-nomotion-2hr-20260712-002132` stopped after `88 s`.
  All `18/18` endpoint polls succeeded, but `imu_read_failures` advanced from `1` to `2` after
  roughly `282700` successful IMU samples, correctly tripping the zero-new-I/O-failures gate.
  This was not the historical blackout signature: the robot remained online, bridge/network and
  camera host vision stayed ready, motion/rail/torque stayed off, VBUS remained `4886-4928 mV`,
  maximum chip temperature was `65.5 C`, maximum display frame time was `40998 us`, and there was
  no reset, PMIC event, camera failure, or hard-floor entry.
- A full-duration characterization rerun is active at
  `output\pc-brain\full-firmware-integrated-characterization-2hr-20260712-002656`. It preserves
  the same strict summary gates but does not abort on one isolated peripheral counter increase,
  allowing the actual miss rate and all other subsystems to be measured over two hours. Serious
  readiness, power, display, camera, bridge, or network loss remains monitor-stop territory.
- Source checkpoint `2cbf59eaa65287be78bfe5d53291d0ba9bbfb87f` adds one bounded retry for only the
  failed IMU accel/gyro read, plus separate retry and recovery counters. A hard failure is counted
  only when that retry also fails. The retry path is capped at two attempts with a `250 us` pause,
  so it cannot turn an I2C fault into an unbounded intent-loop stall. Native logic passes `239/239`,
  the soak evidence contract passes, and the real `stackchan_release_full` embedded build succeeds
  at `54.4%` RAM and `42.4%` flash. This source candidate is built but not flashed or physically
  accepted yet.

### Final Integration Checkpoint (2026-07-11)

- Clean prerelease source checkpoint `c3b06e6cb0d73afc34db7338418a1a0de6341a09`
  passes native logic `239/239`, bridge/vision `205/205`, both production and camera-probe
  firmware builds, and PowerShell/Python syntax checks. The clean full package
  `output\release\stackchan_alive_prerelease-c3b06e6c.zip` is `42,743,713` bytes with SHA256
  `F1399E75E1CE649F23C8A7C473BC94DB243DB79C77FC5FD4E40F4F430C596C66`; an independent
  extraction verifier ended in `Release package verified`. It remains a diagnostic prerelease,
  not a consumer release, until the physical and owner-decision gates below pass.
- After fetching the current remote, `origin/main` remained the exact merge base. The companion
  branch was `145` commits ahead and `0` behind main, so final integration remains eligible for a
  fast-forward merge. No push or merge has been performed.
- A clean commit-pinned touch/IMU baseline was captured at
  `output\hardware-evidence\final-integration\body-sensor-validation-20260711-225025`. Touch and
  IMU were ready/calibrated with motion, servo rail, and torque off. The interactive touch-zone,
  gesture, pickup, tilt, putdown, and shake steps remain pending.
- Physical camera validation is paused after the operator experienced eye strain from an overly
  bright test light. Future acquisition uses diffuse room or reflected light only, never a bright
  source aimed at the operator. Eye discomfort ends the run immediately; release timing never
  overrides that rule.
- The production bridge now injects the existing bounded, privacy-filtered
  `BridgeMemory.context_lines()` into both normal Gemma turns and research-evidence second passes;
  live embodiment remains a separate trusted telemetry channel. The model benchmark now rejects a
  spoken forget acknowledgment without a real `memory_forget` key and uses a concrete identity
  question instead of an underspecified placeholder. Real warm Gemma passes `6/6` at `1211.31 ms`
  median and `9.2` approximate tokens/s, answers `I am Stackchan Spark.`, and emits
  `project.bracket_color` for the stored-key forget case. The real-model Character Lock red team
  passes `25/25`, and the complete bridge/vision suite passes `209/209`.
- The live robot is running the OTA-confirmed incremental microphone-capture camera candidate,
  firmware SHA256 `890AE99A55CA89BAE3694D60287359D9F2A21814D1AD1B15E99A1E98E6DF8AC2`.
  Its build evidence is
  `output\hardware-evidence\final-integration\camera-follow-incremental-capture-candidate-20260711-203030`
  and OTA evidence is
  `output\hardware-evidence\final-integration\camera-follow-incremental-capture-ota-20260711-203030`.
  At the latest check bridge/network were ready, motion/rail/torque were off, VBUS was `4934 mV`,
  no hard-floor or PMIC VBUS-loss event had occurred, and the display window maximum was `33333 us`.
- A verified private rollback archive of that installed lead is stored at
  `output\private\firmware-leads\camera-follow-incremental-capture-20260711-203030-archived-20260711-211938.zip`,
  archive SHA256 `2F6891E401C4C7652DB9E991C790D8250F8394BEC5A410776A96131D21F564DE`.
  It contains the firmware binary, OTA evidence, and source snapshot but no plaintext secret files.
  The diagnostic binary is token-enabled, so the archive is private recovery material and must
  never be included in a public package or Git release.
- Camera capture and detection are physically proven. The oriented GC0308 initializes on its first
  attempt; authenticated host requests and target updates advance without capture/authentication
  failures; and hash-pinned YuNet has acquired a real face across center, left, right, loss, and
  reacquisition positions. A 50-second supervised horizontal follow at
  `output\hardware-evidence\final-integration\camera-follow-anti-windup-supervised-20260711-184445`
  passed electrical/telemetry gates and was visually accepted as correct but slow.
- Full wake/listen following is not yet accepted. The failed run at
  `output\hardware-evidence\final-integration\camera-follow-full-stack-supervised-20260711-200935`
  proved that the wake cue's eight-second audio cooldown was removing the servo rail during
  microphone capture even though speaker playback was quiet. `MotionAudioPreemptionGate` now clears
  only that stale wake-cue tail when listening begins; real downlink playback and its cooldown still
  preempt motion. The follow-up run at
  `output\hardware-evidence\final-integration\camera-follow-mic-handoff-supervised-20260711-202512`
  proved the power handoff (`audio_preempt=false`, rail/torque retained) but exposed a second issue:
  the 4.8-second dedicated capture loop blocked the intent task and froze camera gaze output.
- Dedicated wake capture is now an incremental one-chunk-per-intent-cycle state machine, so camera
  event polling, gaze, RGB, and character updates can continue through listening. Debug counters
  expose active state, attempted/submitted chunks, service calls, and maximum service time. Native
  logic passes `239/239`; the complete bridge/vision suite passes `205/205`; both camera and
  production embedded builds pass. Final visual wake/listen/reply following remains pending because
  the latest supervised attempt correctly refused to enable servos without a fresh face lock.
- Release packaging now builds the legacy and pioarduino profiles sequentially with isolated cores,
  snapshots each firmware before the framework switch, preserves 360 installed third-party
  license/notice/metadata files with a portable SHA-256 index, and runs the complete verifier against
  the exact ZIP before returning success. The diagnostic self-verification rehearsal
  `postbuild-self-verify-smoke-20260711-214315` produced ZIP SHA256
  `F702130F8424220B1D1EA8AB5E288F3161C60FC4F0EEF27E1406428965B48D9A`; its persisted verifier log
  ends in `Release package verified`. All `49/49` PowerShell release/evidence contracts pass,
  including the 24-point camera wake/follow safety contract, visual-review completion guard, and
  unified consumer-promotion contract. This
  rehearsal is not the final release package because physical evidence, owner license choice, and
  production voice provenance remain open.
- A superseding `-SkipBuild` packaging rehearsal after adding the camera/body-sensor validators,
  visual-review guard, unified promotion contract, final integrated soak runner/checker, and the
  production DirectML wrapper produced
  `stackchan_alive_post-production-soak-gates-smoke-20260711-222909.zip`, SHA256
  `90D98F90CF2F055D8A3FA9D31180DEBBD78E1AA889153749A6549BD7FC09FB7F`
  (`42,746,302` bytes). Its persisted verifier log ends in `Release package verified`. It is
  diagnostic rehearsal evidence, not the final release.
- The final promotion gate now requires a clean matching source commit, one installed firmware
  SHA-256 across operator-approved camera evidence, complete touch/IMU evidence, and the formally
  verified integrated soak. `-RequireFinalIntegration` now includes camera capture and paired host
  vision instead of rejecting camera-enabled production firmware. The gate also requires an
  owner-selected project license and production voice provenance, both still open decisions.
- The final-soak launcher now targets the accepted DirectML worker on local port `5059` and reuses
  the existing production bridge. It refuses dirty source, non-loopback worker URLs, missing power,
  display, network, or socket gates, and missing advancing paired vision before motion. It forces
  and verifies motion off at preflight and performs verified stop cleanup on every post-enable
  failure. The retired warm ROCm path remains an explicit rollback only.
- The body RGB flow was visually accepted by the operator after mode/mood crossfades were added.
  Touch and IMU telemetry were physically exercised for touch, pickup, putdown, shake, and tilt;
  final zone-label orientation and combined-soak acceptance remain open.
- The exact-name voice turn before the camera diagnostic passed end to end:
  `What is your name?` -> `I am Stackchan.`, first audio `2072.38 ms`, total turn `4039.92 ms`,
  one complete phrase, and no truncation. After production restore, a fresh wake/name turn is
  still required. The failed physical attempt had healthy microphone reads with zero drops but
  never opened the wake gate: maximum model probability was only 17 against cutoff 200, with
  zero captures/uplinks/playbacks. The temporary archived image then remained pinned at maximum
  probability 1 despite healthy microphone reads and ordinary audio peaks. Historical accepted
  evidence from the same model reached probability 255 and completed wake turns at comparable
  audio peaks, weakening threshold, gain, and channel-selection explanations. Source now makes
  `/wake-reset` reset recurrent inference state as well as counters and zero-initializes both
  TFLite arenas with `heap_caps_calloc` before constructing the streaming model. It verifies every
  byte before use, fails closed on an initialization violation, and exposes
  `sr_wake_mww_arenas_zero_initialized` in `/debug`. This is a strong, directly testable cause
  hypothesis, not yet a claimed root cause. The superseding uninstalled OTA-capable candidate is
  archived at
  `output\hardware-evidence\final-integration\wake-zero-init-verified-ota-candidate-20260711-160828`,
  SHA256 `298CDD4A07476B33CB75F07C4CF4162E539D64B972B75F4384A9DC7E934E0CC1`;
  serial recovery and a fresh physical wake/name turn are required for confirmation.
  A controlled PC-speaker replay adds a second, independent caveat: the exact stored wake fixture
  reaches probability 255 when processed by the host with the embedded C frontend and the actual
  TFLite model, but three short robot-microphone snapshots from a live replay reached only 9 when
  processed through that same host path. Whisper heard only room noise in two snapshots and a
  distorted phrase in one. That evidence keeps robot acoustics, playback geometry, and microphone
  capture quality in scope alongside recurrent-state initialization. After serial recovery, the
  acceptance test must verify the zero-initialized-arena invariant and compare one correctly timed
  robot-mic capture against the model before any threshold, gain, or channel change.
  `tools\flash_archived_app.ps1` now pins this exact app hash and resets OTA selection to `app0`
  while preserving NVS and the partition table. Its dry run passed, and a deliberately incorrect
  expected hash was rejected. The shared UTF-8 process runner now also throws on a nonzero native
  child exit code, preventing failed PlatformIO or esptool runs from appearing successful.
- Host memory is now `stackchan.bridge-memory.v3`. The v2 store was backed up and atomically
  migrated; stale model-authored `low_battery` context was removed. Character output may write
  only approved `user.*` and `project.*` memory. Typed `robot.*` context is reserved for trusted,
  expiring runtime telemetry. The full bridge suite passes `202/202` with this boundary.
- The real Gemma 4 character red team passes `25/25` with zero validation failures at
  `output\character-red-team\memory-v3-gemma-20260711-143532`. A silent proof using the live
  robot heartbeat correctly answered, `Yes I am on external power. I cannot see you because my
  vision is not active.`, made no memory write, and completed in `1202.29 ms` at approximately
  `13.31 tokens/s`; evidence is under
  `output\character-red-team\live-embodiment-20260711-143644`.
- Companion-v1 source readiness reports `111` passed, `0` failed, and `14` explicitly pending
  hardware/store/distribution gates at
  `output\release\final-readiness-20260711-144200`. The live DirectML worker remains ready on
  `5059`; its last conversion took `0.3824 s` for `1.66 s` of audio, and the current robot remains
  bridge/network ready with motion, rail, and torque off.
- A no-motion final-integration run at
  `output\pc-brain\final-integration-passive-30min-20260711-144503` stopped after 211 seconds on
  one new terminal body-RGB I2C write failure. This was not a robot blackout: all 42 polls were
  good, bridge/network and RVC remained ready, the board VBUS floor was 5.002 V, maximum chip
  temperature was 65.5 C, maximum display frame time was 42,454 us, and no reset, PMIC event,
  motion, servo rail, or torque occurred. The RGB adapter subsequently recovered. A source
  candidate now retries one failed RGB transaction immediately and distinguishes retry/recovery
  from terminal failure; it also adds independently auditable touch-zone and gesture counters.
  Native logic passes 229/229 and the production build succeeds at 53.0% RAM and 41.8% flash.
  The uninstalled candidate is archived at
  `output\hardware-evidence\final-integration\rgb-i2c-retry-candidate-20260711-145737`, SHA256
  `03DEC9FF3CEA1F91427A45876365A81F731E17D276D6FDB3506775714EA03A61`.
- Current-lead reproducibility now checks the live DirectML worker on `5059`, the actual Python
  LAN bridge process, bounded passive-watch failure ratio, and the longest clean soak instead of
  stale hard-coded July 8/9 runtime assumptions. Its live result is `22` passed, `0` failed, and
  `1` pending. The sole pending check is the required 28,800-second final soak; the longest clean
  evidence currently selected is the 7,203-second no-motion lock-safe run. Report:
  `output\current-lead\current-lead-reproducibility-latest\CURRENT_LEAD_REPRODUCIBILITY.json`.
- Merge-readiness inspection confirms `origin/main` is already an ancestor of the working branch
  (`0` commits needed from main, `144` branch commits ahead), so no upstream reconciliation is
  currently pending. A content scan of all 742 tracked files found no occurrence of either private
  OTA or camera-pairing secret. The final integration worktree remains intentionally uncommitted
  until wake recovery, camera/touch/IMU hardware gates, and the final soak pass.
- Release voice conversion is now explicitly BYOM and local-only. Model weights, indexes,
  converted RVC audio, and RVC audition pages were removed from the public tree and release asset
  contract, while restricted review material was preserved under `output\private`. The public
  warm current-lead ZIP was sanitized to 89 required entries with zero restricted payloads,
  SHA256 `CE06204F4F28CB819818AE9840EFA40A369A74AA4455C669D00D3A0C1DC2B4E3`. A real diagnostic
  release ZIP was built and verified from extraction with the new archive guard.

- Robot IP: `192.168.1.238`
- PC bridge host: `192.168.1.240`
- PC bridge port/path: `8765` / `/bridge`
- Firmware debug endpoint: `http://192.168.1.238:8789/debug`
- Historical accepted evidence (superseded by the temporary diagnostic install): the authenticated
  LAN OTA baseline was physically installed in both `app0` and `app1` with
  firmware SHA256 `465DC560663DD3D0559AA9F986D1C46CEEE2DE5D2640309D9EDED1E485D15F1D`.
  Both slots independently completed a continuous 30-second runtime-health window and reached
  `phase=confirmed`; bootloader rollback is enabled and software-only rollback is false. The
  accepted image is 2,733,760 bytes with 608,576 bytes of OTA-slot headroom. Native logic passes
  225/225 and architecture verification passes.
- The first OTA trial intentionally exposed two integration defects before acceptance: Arduino's
  weak startup hook auto-confirmed the image before application health, and the health gate treated
  the external PC bridge session as device health. The corrected firmware defers confirmation with
  `verifyRollbackLater()`, makes rollback one-shot, persists rejection masks, requires Wi-Fi but not
  the host bridge, and keeps the stricter 50 ms visual gate in the release soak rather than the
  boot-alive check. A rejected trial returned safely from `app1` to `app0`; the corrected image then
  confirmed on both slots. Evidence is under
  `output\hardware-evidence\final-integration\ota-app1-confirmation-20260711` and
  `output\hardware-evidence\final-integration\ota-app0-confirmation-20260711`.
- Historical accepted wake evidence showed the required order: detection, RGB commit,
  microphone pause, tone, speaker-to-mic handoff, then capture. The physical check recorded 3/3
  detections, tones, captures, and completed downlinks with zero ordering violations or truncation.
  The last turn committed RGB in 1 ms, started the 176 ms cue after 218 ms, and began capture 9 ms
  after cue completion.
- Production and isolated camera diagnostic images compile; the paired camera path serves ephemeral
  160x120 grayscale frames locally and returns bounded face boxes to the active-speaker tracker.
  The zero-initialized-wake camera follow-on is archived at
  `output\hardware-evidence\final-integration\camera-probe-zero-init-candidate-20260711-161206`,
  SHA256 `A8E3B5BFFF879CA7629A95B411937345ADA85B40F3EE87CE62A7ECB19C5529AC`.
  It builds at 56.4% RAM and 42.7% flash with motion disabled at boot and is queued only after the
  production recovery image passes its wake/name gate.
  Physical camera and camera-guided servo tracking remain the next supervised hardware gate. No
  camera pass or final combined soak is claimed yet.
- The installed 64 GB microSD is authorized for erasure at the next USB session, but exceeds
  M5Stack's documented 16 GB maximum and is optional/experimental. The destructive formatter
  remains separately build- and runtime-gated; card type/capacity must be shown before the exact
  erase phrase is accepted, then production firmware must be restored.
- Current running image is the archived production rollback on `app1`, SHA256
  `875FE2DE5FB93BECEF6C72C08C1951326439CDCAE299528970C28D43CF115CFB`. `app0` retains the
  isolated camera diagnostic for the next supervised real-face test; do not promote that slot.
- Firmware guardrails: motion disabled at boot; one Power Coordinator owns servo/speaker power policy; the servo rail is off outside a granted motion window; audio, thermal, and supply protection preempt motion; VBUS has a 4400 mV unconditional floor; 4400-4550 mV motion requires fresh INA226 evidence that the external source is charging the body battery by at least 50 mA; motion resumes at 4700 mV; motion/audio sessions preemptively reduce battery charging to 125 mA and retain that rate for 30 seconds after load removal; rejected PMIC samples never enter policy; PMIC VBUS presence/loss transitions are counted; speaker power is off while idle; the face task runs above motion bookkeeping on their shared core.
- Current exact firmware lead directory:
  `output\firmware-leads\ota-wake-confirmed-20260711-115537`
- Current accepted archive:
  `output\firmware-leads\ota-wake-confirmed-20260711-115537.zip`, SHA256
  `AA574A733DA952EA7D6F08CF8DB99642CB7449024BB83E4BB3601B93E4775335`
- Current firmware SHA256: `465DC560663DD3D0559AA9F986D1C46CEEE2DE5D2640309D9EDED1E485D15F1D`
- The lead directory includes all flash images, the ELF/map, source archive at commit
  `7519C3B8977BC37B29EFAB163C64A440D4011DC4`, hashes, USB-install logs, and both independent
  OTA-slot confirmation records. The older 60-minute accepted power-coordinator archive remains
  preserved as historical stability evidence.
- Current PC STT: `python bridge\whisper_cpp_stt.py`
- Current PC TTS/RVC: `python bridge\rvc_production_tts_client.py`, phrase-streamed through
  DirectML with a bounded clear local fallback.
- Current production RVC worker: `bridge\rvc_directml_worker_service.py` at
  `http://127.0.0.1:5059`. The unused warm ROCm worker on `5055` was stopped after promotion
  to free GPU memory; its launcher remains the rollback path.
- RVC runtime: `C:\stackchan_rocm_venv` with PyTorch `2.9.1+rocm7.2.1` and `rvc-python==0.1.5`
- RVC model cache: `output\voice_sources\stackchan_rvc_base\model\model.pth`
- RVC index cache: `output\voice_sources\stackchan_rvc_base\model\model.index`
- RVC settings: worker device `cuda:0`, f0 method `pm`, pitch `2`, index rate `0.62`, RMS mix `0.72`, protect `0.28`
- RVC output: `pcm16`, 16 kHz, max payload `65536` bytes
- Current acceleration status: warm ROCm worker validated on AMD Radeon RX 7800 XT; first warm-up conversion was about 29 s, subsequent conversion was about 3 s
- Voice V2 DirectML is physically validated. Lab conversion with the accepted `pm` method and full `0.62` index took `0.43-0.63 s`, median rendering realtime factor was `0.22`, and the complete TTS + RVC client took `1.01-1.18 s`. The physical warm-API run at `output\pc-brain\voice-v2-warm-api-supervised-20260710-205818` passed `22/22`: four turns, eight of eight phrases complete, `567040` host bytes exactly matched `567040` robot bytes in 142 chunks, zero truncation/playback errors/forced stops, worst conversation first audio `3492.31 ms`, and worst post-text voice first audio `1047.52 ms`. The production bridge and worker were restored afterward.
- DirectML was promoted to the live bridge at
  `output\pc-brain\directml-production-start-20260711-003533`. Runtime verification passed
  30/30 with bridge PID `8292`, worker schema ready, phrase streaming enabled, speaker downlink
  enabled, robot bridge/network ready, and motion/rail/torque off. A silent host-only production
  synthesis completed in `1.33 s` for `3.94 s` of audio, used DirectML rather than fallback, and
  reported zero truncation. The corrupted legacy memory was backed up and sanitized to bounded
  v2 before promotion; no preferred name was retained because none came from explicit user
  naming language.
- After stopping the unused warm ROCm process, DirectML `5059` and bridge `8765` remained
  healthy. Robot `/debug` remained network/bridge ready with motion, rail, and torque off,
  display maximum `29139 us`, VBUS `5024 mV`, and chip temperature `60.5 C`.
- Gemma's live runner now uses Ollama's warm loopback HTTP API with JSON output, thinking disabled, bounded context/output, and an indefinite model keep-alive; the CLI remains a fallback. The same 352-token prompt dropped from about `13.69 s` through `ollama run` to about `1.02 s` through the API, roughly 112 generated tokens/s. The bridge now passes the actual STT transcript into `local_runner.py`; prompt cases no longer replace what the user said.
- The production Character Lock now has a deterministic final-output guard for hierarchy terms,
  sensitive-memory requests, contractions, assistant-speak, and stacked exclamation marks. The
  exact Ollama production wrapper passed all `25/25` live-model adversarial cases at
  `output\character-red-team\release-cc4346a1` at source commit `cc4346a1`. The five-case conversational
  benchmark also passed `5/5` with median model-call latency `1125.77 ms` and median approximate
  output speed `8.96 tokens/s`; evidence is
  `output\model-benchmark\release-cc4346a1`.
- Streamed speech mouth movement is restored. `bridge\lan_service.py` aggregates the existing TTS/RVC beat envelope over each PCM chunk and emits one mouth frame immediately before that chunk. The supervised mouth run at `output\pc-brain\voice-v2-mouth-supervised-20260710-210803` passed `22/22`, reconciled `97920` bytes in 25 chunks, had zero playback errors or forced stops, reached first audio in `3531.68 ms` conversation / `1079.51 ms` post-text, and received the operator's visual confirmation that the mouth moved while Stackchan spoke.
- The corrected wall-powered no-motion debug-latency baseline passed for `7203 s` at `output\pc-brain\wall-nomotion-debug-latency-4s-locksafe-2hr-20260710-120614`: `3376/3379` successful four-second probes, three isolated curl `28` timeouts at 607.6, 3323.7, and 4962.3 seconds, failure ratio `0.000888`, maximum streak one, and the established bridge socket present in all 3379 records. Motion, servo rail, and torque stayed off; live VBUS was `5014-5054 mV`, no hard-floor event occurred, maximum temperature was `58.5 C`, maximum face frame was `44707 us`, and minimum free heap was `113456`. Verified motion-stop cleanup passed, and the corrected formal no-motion checker passed `37/37`. Comparison evidence is `probe-comparison.json` in that root. This supports transient `/debug` HTTP service latency independent of servo motion; it does not identify the internal cause of each delayed response or explain the historical blackouts.
- Blackout diagnosis status: motor overload is not an established universal cause. Confirmed outages occurred with and without motion, motion-enabled runs also passed for 52 and 60 minutes, and failure times do not cluster at a common board uptime or the ESP32 `micros()` wrap. The application contains no deliberate power-off/deep-sleep call. At 15:43 on 2026-07-10, the accepted production firmware was live after about 8.3 hours with motion/rail/torque off, bridge ready, VBUS `5025 mV`, no PMIC VBUS-loss or hard-floor event, and face frame max `29377 us`. Historical full-off events and isolated HTTP latency events must remain separate findings.
- Flashed release-forensics diagnostic lead: environment `stackchan_release_forensics` extends Voice V2 and captures the AXP2101's boot-latched and runtime IRQ status for VBUS/battery transitions, power-key events, temperature/overvoltage protection, BATFET/LDO overcurrent, and watchdog expiry. It owns PMIC IRQ polling so `M5.update()` cannot clear power-key evidence first, verifies IRQ-enable registers by direct write/readback, snapshots voltage/load/audio/motion/temperature/heap context, and exposes it in `/debug`. Raw status bits that are not enabled in the selected diagnostic mask, such as routine `gauge_new_soc`, are cleared and recorded separately rather than incrementing the strict event counter. Native tests pass `198/198`; the candidate is `157364` static RAM bytes / `2674911` program bytes, and firmware SHA256 is `32472084CABBFDA57A72B0A9B81D0709F3B3D37EF4410C20756DA6C45607AF24`. Direct esptool flashing verified all four written regions.
- Physical forensics qualification passed in stages. PC no-motion passed 120 seconds after informational IRQ filtering. Wall no-motion passed 56/56 polls with VBUS `4874-4909 mV`. The clean wall-only software reboot started at a `4912 mV` floor with no PMIC boot event. The 60-second servo qualification passed 29/29 polls. The six-minute servo/session-refresh run at `output\pc-brain\release-forensics-wall-servo-6min-20260710-203435` passed 71/71 polls, 100% motion and unsuppressed samples, two scheduled refreshes, zero timeouts, VBUS floor `4846 mV`, maximum chip temperature `59.5 C`, maximum display frame `45216 us`, zero new hard-floor/runtime/protective events, and verified motion/rail/torque shutdown. Its formal checker passed `42/42`.
- Current release-forensics archive: `output\firmware-candidates\forensics-validated-20260710-204449.zip`, archive SHA256 `48FF8AFB40906E4CD14E2A8373486FD81DE115656B46AA5A96A50657A0D203BD`, candidate firmware SHA256 `32472084CABBFDA57A72B0A9B81D0709F3B3D37EF4410C20756DA6C45607AF24`, bundled accepted rollback SHA256 `3C40D5A0F006B67D175ED963133E90F889AE600D5C1F0F419E06FE7B99786C10`. The verified ZIP contains 143 entries: exact flash images, source/procedure, direct-flash proof, and all staged physical evidence. This supersedes the pre-filter `155352` archive, but remains a diagnostic lead rather than a final accepted release.
- The first post-flash capture showed an undated boot-latched `batfet_overcurrent` bit together with setup-related insertion/charge bits. After clearing the PMIC baseline and reflashing the filtered candidate, the same flash procedure did not reproduce that bit. This weakens a flash-artifact explanation but does not tie the old latched bit to any particular historical blackout; root cause remains unknown until an untouched post-failure capture identifies it.
- Forensics tooling: `tools\capture_first_post_return_power_forensics.ps1` waits for the first post-recovery `/debug`, preserves the untouched boot mask/reset reason, and safe-stops unexpected motion. The soak runner and formal checker now support `-RequirePowerForensics`, persist each PMIC field, baseline counters after setup cable changes, and reject unarmed capture, new runtime/protective events, or PMIC read/clear failures. Procedure and interpretation matrix: `docs\POWER_BLACKOUT_FORENSICS.md`. The next blackout must be recovered without unplugging or changing the cable so the PMIC evidence is not contaminated.
- A 2026-07-10 live read observed one AXP2101 `battery_overvoltage` runtime IRQ, but Stackchan remained online on the same software-reset boot beyond 11,081,507 ms with bridge/network ready, motion/rail/torque off, VBUS `5033 mV`, battery `4099 mV`, and recorded battery maximum `4198 mV`. This is a real protective-event clue, not blackout attribution. The installed v1 telemetry had already allowed a later `vbus_insert` event to overwrite its event-time context. The unflashed `axp2101-v2` candidate now preserves independent latest-general, latest-protective, and latest-battery-overvoltage contexts; native regression coverage proves a later VBUS insertion cannot erase the protective snapshot.
- Previous pre-ROCm lead archive: `output\current-lead\stackchan-full-online-rvc-lead-20260708-014917.zip`
- Current warm-ROCm handoff archive: `output\current-lead\stackchan-full-online-warm-rocm-lead-20260708-101400.zip`
- Flashed motion timing candidate archive: `output\current-lead\stackchan-motion-timing-fix-candidate-20260708-101400.zip`
- Current hardened VBUS-guard lead archive: `output\current-lead\stackchan-vbus-guard-hardened-lead-20260709-121107.zip`
- Power-source A/B observation: motherboard USB through the BASE port measured about 4.13-4.35 V while body-current telemetry showed `battery_to_system`; the dedicated 5 V / 3 A wall source through the same port measured about 4.66-4.98 V while telemetry showed `system_to_battery`. This establishes different source behavior, not a universal cause for every historical dropout.
- Power telemetry hardening rejected four impossible `16372 mV` PMIC VBUS samples. The accepted historical maximum stayed near 4.9 V and rejected values were not admitted to motion policy.
- Power Coordinator supervised servo qualification passed for 60 seconds: 30/30 polls, servo IDs yaw=1/pitch=2, no attach or ping failures, no motion timeout, minimum VBUS `4817 mV`, maximum display frame `45432 us`, maximum chip temperature `61.5 C`, body current stayed `-200.0` to `-143.3 mA` (`system_to_battery`), bridge/network stayed ready, and post-stop rail/torque were both off.
- The supervised 50-minute promotion soak at `output\pc-brain\full-system-soak-power-coordinator-wall-servo-50min-20260709-212456` was safe-stopped at `1015 s` after the first observed `motion_session_timeouts=1`. Before the stop it had 201/201 successful polls, zero endpoint failures, four accepted motion refresh requests, zero refresh transport failures, bridge/socket/wake/mic/speaker/RVC ready throughout, VBUS above the strict floor, healthy face timing, and no reset. The stop left motion request/grant, servo rail, and torque off while the robot stayed online.
- This run identified a specific control bug: `/motion-resume` reasserted `gMotionRequested=true`, but `MotionTask` only called `ActuationEngine::setEnabled(true)` when the engine was disabled. Repeated refreshes therefore did not renew `enabledAtMs`; the unchanged 15-minute session failsafe expired and the following refresh re-enabled motion. This finding is direct source-and-telemetry evidence and is separate from the unresolved historical reachability dropouts.
- Session-refresh fix candidate archive: `output\firmware-leads\power-coordinator-session-refresh-fix-20260709-214555.zip`, firmware SHA256 `20CDAF0AAC4D93A293DF4F7D4C70940D2D2505D15BB3FF67FA4A655FDADE1F07`, archive SHA256 `B52B79C6C334ACC527B3B2B19273E3C864827E1601F462DC1E4FDB53E91760C3`. It adds explicit active-session renewal plus `motion_session_refreshes` / `motion_session_refreshed_at_ms` telemetry. Native tests pass 191/191, including proof that renewal extends the deadline and that the original failsafe still expires without another renewal; the full firmware build passes.
- The session-refresh candidate was direct-flashed on `COM4`; esptool verified every written image hash. Post-flash debug exposed the new renewal counters with zero refreshes/timeouts, motion request/grant off, servo rail/torque off, wake ready, face frame about 31 ms, and bridge/network ready after clearing stale PC listener sockets. Computer USB measured about 4366 mV with positive body current, so the coordinator correctly remained `protected`. At that post-flash checkpoint no servo movement had been attempted on this candidate.
- First session-renewal boundary attempt `output\pc-brain\session-refresh-boundary-wall-servo-17min-20260709-222201` was safe-stopped at 159 seconds before the first renewal. The board-reported accepted VBUS floor reached `4396 mV`, below the strict `4400 mV` hard floor; sampled poll VBUS stayed at or above `4451 mV`. The coordinator had already removed servo rail/torque for duty rest and entered `protected/power_load_shed`; unsafe rail-without-grant and torque-without-rail samples were both zero. All 32 endpoint polls, bridge/socket/network/wake/mic/speaker/RVC checks passed, session timeouts were zero, maximum temperature was 60.5 C, and maximum face frame was 48987 us. The accepted sub-floor minimum occurred while the servo rail was off, so this evidence does not attribute that specific dip to active servo draw. Formal checker correctly reported not ready.
- Controlled idle input comparison `output\pc-brain\diagnose-power-input-ab-20260709\comparison.json` used the same firmware and no actuator/speaker load. PC input held VBUS at `4247-4259 mV` while the body battery discharged `200.0-216.7 mA`; the 5 V / 3 A wall input held `4925-4954 mV` while the body battery charged `187.0-202.2 mA`. This proves the PC source is unsuitable for full-system operation, while only characterizing the wall source at idle.
- The evidence-backed coordinator revision preemptively selects the AXP2101-supported 125 mA charge limit for motion/audio/protection and holds it for 30 seconds after load removal. The first movement attempt proved the power policy but was safe-stopped at 11 seconds because equal-priority face and motion tasks produced a `52558 us` display window. Motion task priority was then reduced from 3 to 2 while face remained 3; native tests passed `192/192`, the full build passed, and direct esptool flashing verified every region hash.
- Verified boundary run `output\pc-brain\power-coordinator-priority2-wall-servo-6min-20260709-231534` passed 360 seconds with `169/169` polls, zero failed polls, two duty-rest transitions, `motionSampleRatio=0.9763`, zero session timeouts, two successful motion refresh transports, no PMIC input loss, no rail/torque invariant violations, live VBUS floor `4676 mV`, maximum face frame `40938 us`, maximum temperature `60.5 C`, bridge/network/wake/mic/speaker ready throughout, and RVC ready `12/12`. The formal checker passed `33/33`. The post-stop handoff then passed `45/45` polls: charging returned from 125 to 700 mA with VBUS `4908-4976 mV`, no PMIC loss, and rail/torque off.
- Final 60-minute acceptance `output\pc-brain\power-coordinator-priority2-wall-servo-60min-20260709-232808` passed `3601 s` and crossed the prior roughly 51-minute failure boundary: `707/707` polls, no failed polls, `motionSampleRatio=0.9972`, all 705 motion samples unsuppressed, 137 duty-rest samples, zero output/thermal/power suppression samples, zero session timeouts, 12 successful refreshes, no rail/torque invariant violations, live VBUS floor `4817 mV`, maximum face frame `42922 us`, maximum temperature `60.5 C`, and bridge/network/wake/mic/speaker/RVC ready throughout. The formal checker passed `33/33`. Post-stop evidence passed `45/45`: motion/rail/torque remained off, charge current stayed at 700 mA, VBUS stayed `4912-4956 mV`, and the PMIC-loss counter did not change. The strict display hard stop remains `50000 us`. This firmware is the accepted lead; the next longer run is a resilience soak, not a replacement for this completed gate.
- The preauthorized eight-hour resilience run `output\pc-brain\power-coordinator-priority2-wall-servo-resilience-8hr-20260710-003342` was safe-stopped at `4569 s`, not passed. All `897/897` polls succeeded, bridge/RVC stayed ready, maximum face frame was `43146 us`, maximum temperature was `59.5 C`, and motion timeouts stayed zero. The current-run live VBUS floor reached `4406 mV`; the firmware's accepted boot minimum advanced from `4676 mV` to `4398 mV`, below the `4400 mV` hard floor. The deepest polled event occurred during duty rest with servo rail/torque and speaker power off, body INA226 current reporting `system_to_battery`, PMIC VBUS still present, and no PMIC-loss transition or reset. Motion was stopped, the runner process was terminated so it could not renew motion, and post-stop debug remained healthy with motion/request/rail/torque off, VBUS about `5047 mV`, 700 mA charging, and bridge/network ready. This proves a current-run low-floor event; it does not yet distinguish an upstream power-path transient from a plausible PMIC ADC/I2C measurement transient or explain every historical blackout.
- Unflashed diagnostic candidate: `output\firmware-leads\power-floor-event-instrumentation-candidate-20260710-020829.zip`, firmware SHA256 `DC7B8358EEE7817BEE850B08077E4A9C5C3FA8780D7DB5F1F0E679F95B785F7F`, archive SHA256 `FE62C045E00FF330B78602A3A51898E115F02FB1330A072D64750202033339C6`. Native tests pass `194/194` and the full embedded build passes. It captures body INA226 bus voltage/power, counts and confirms hard-floor entries, snapshots load context, and makes the soak runner baseline the counter and fail fast on any increment. It is not flashed and does not supersede the accepted `3C40...C10` lead.
- Late-night soak status: warm ROCm worker and PC bridge remained healthy, but the physical robot dropped off the bridge socket and stopped answering ping/debug after the servo-soak attempts. Do not treat the overnight servo soak as complete.
- Passive no-motion overnight watch: `output\pc-brain\warm-rocm-passive-overnight-watch-20260708-025548` started with `MotionRefreshSeconds=0`; it records robot/socket recovery but does not activate servos.
- Motion timing candidate fix: source and firmware build now use `millis()` consistently for motion session/output timing instead of comparing `millis()` state to `micros()/1000`. This fixes a likely post-uptime `/motion-resume` immediate-timeout failure after `micros()` wraps. The candidate was flashed on 2026-07-08 with direct esptool hash verification after the PlatformIO wrapper hung on upload output.
- Strict servo soak `output\pc-brain\full-system-soak-warm-rocm-servo-clean-20260708-103059` was stopped after the robot stopped answering ping/debug. Finalized failure summary reports `durationSeconds=335`, `records=12`, `failedPolls=3`, `maxConsecutiveFailedPolls=3`, `motionRefreshFailures=4`, and `abortReason=robot_offline_ping_debug_com_unavailable`, so this run does not close the overnight gate.
- 2026-07-08 remote recovery status: a human side-button reset brought the robot back online. A two-minute no-motion recovery soak passed at `output\pc-brain\quiet-recovery-after-reset-20260708-134502`, and passive watch `output\pc-brain\robot-passive-watch-20260708-135547` is running with ping/debug/bridge/COM checks only.
- Remote/self-recovery firmware is now flashed on `stackchan_wake_mww_uplink_servos_m5_voiceout`. `src\main.cpp` has guarded `/recover` and `/reboot` debug endpoints plus a conservative Wi-Fi/bridge recovery supervisor; `src\io\BridgeWiFiProvisioner.cpp` was adjusted for the current Arduino Wi-Fi API. The lead env was rebuilt with Arduino ESP32 `3.3.6` and direct-flashed with esptool hash verification.
- Recovery firmware lead archive: `output\current-lead\stackchan-recovery-firmware-lead-20260708-142700.zip` SHA256 `1AD1ABA9D05C16C67148E5721F8DC1EF4C1281E580D7E304A3B5F51C95E9F45D`.
- Current face-priority/debug-task lead: `stackchan_wake_mww_uplink_servos_m5_voiceout` was rebuilt and direct-flashed on 2026-07-08 with esptool hash verification. The face task now runs at the lead priority while the debug/recovery HTTP service is also polled from the intent/network task, so raising face priority does not strand `/debug`, `/recover`, or `/motion-*` behind the low-priority Arduino loop.
- Reset-instrumented lead update: the same environment was rebuilt and direct-flashed again on 2026-07-08 at 17:26 with `/debug` fields `uptime_ms`, `boot_count`, `reset_reason`, and `reset_reason_code`. Post-flash live debug reported `bridge_state=ready`, `network_state=connected`, `motion_enabled=false`, `display_window_fps=20.00`, and `display_window_max_frame_us=30327`.
- Post-flash no-motion soak passed at `output\pc-brain\quiet-soak-2026-07-08T19-12-39Z`: 120 s, 7/7 debug polls, `bridge_state=ready`, no bridge/audio errors.
- Strict 10-minute full-system servo soak passed at `output\pc-brain\full-system-soak-face-priority-debugtask-reducedrefresh-10min-20260708-153622`: `status=pass`, 20/20 polls, 0 failed polls, motion sample ratio 1.0, 2/2 motion refreshes, 0 motion refresh failures, all bridge/socket/wake/mic/speaker/RVC samples ready, `maxFrameUs=39767`, and `maxSlowFrames=32`.
- Formal checker passed for that reduced-refresh soak: `tools\check_full_system_soak_evidence.cmd -SummaryJsonPath output\pc-brain\full-system-soak-face-priority-debugtask-reducedrefresh-10min-20260708-153622\summary.json -MinDurationSeconds 600 -RequireReady -Json` reported `full-system-soak-ready` with 31 passed, 0 failed, 0 pending.
- The first 8-hour attempt after the 10-minute pass failed early at `output\pc-brain\full-system-soak-face-priority-debugtask-overnight-8hr-20260708-155604`: `status=fail`, duration about 1299 s, 42/44 polls OK, two consecutive `/debug` timeouts, bridge/worker healthy before the dropout, motion refreshes 4/4, `maxFrameUs=39439`, and the robot temporarily vanished from ping/debug/bridge/COM before later returning. This looked like a board reset/dropout, not face-rendering starvation; the reset-instrumented firmware was flashed afterward to identify the next occurrence.
- Reset-instrumented 45-minute diagnostic full-system servo soak passed at `output\pc-brain\full-system-soak-warm-rocm-servo-20260708-172959`: `status=pass`, 2700 s, 90/90 polls, 0 failed polls, motion sample ratio 1.0, 9/9 motion refreshes, 0 motion refresh failures, all bridge/socket/wake/mic/speaker/RVC samples ready, `maxFrameUs=46776`, `maxSlowFrames=42`, and `maxMotionSessionTimeouts=0`. Formal checker with `-MinDurationSeconds 2700 -RequireReady` reported `full-system-soak-ready` with 31 passed, 0 failed, 0 pending. Live post-run debug still reported `boot_count=1`, `bridge_state=ready`, `network_state=connected`, and motion was manually stopped.
- Reset-instrumented 8-hour full-system servo soak launched at `output\pc-brain\full-system-soak-warm-rocm-servo-20260708-181644` with `-DurationSeconds 28800 -PollSeconds 30 -MotionRefreshSeconds 300 -MotionRefreshInitialDelaySeconds 150`. Thread heartbeat monitor `stackchan-8hr-soak-monitor` checks this evidence path during the overnight window.
- That 8-hour attempt failed early at 3047 s: `status=fail`, 99/102 polls OK, `failedPolls=3`, `maxConsecutiveFailedPolls=2`, `abortReason=consecutive_failed_poll_limit_exceeded`, `motionRefreshes=10`, `motionRefreshFailures=0`, `maxFrameUs=40175`, and `maxMotionSessionTimeouts=0`. The robot then stopped answering ping/debug, COM4 disappeared, and the bridge socket timed out. After physical reset, `/debug` returned `reset_reason="poweron"` / `reset_reason_code=1`, `boot_count=1`, motion disabled at boot, face at 20 FPS, and COM4 present. The PC bridge had stale sockets after the reset and was restarted; the robot then returned to `network_state=connected`, `bridge_state=ready`.
- Servo duty-rest candidate test `output\pc-brain\full-system-soak-warm-rocm-servo-20260708-195407` failed much earlier than the 50-minute target: `status=fail`, `durationSeconds=276`, 8/10 polls OK, `failedPolls=2`, `maxConsecutiveFailedPolls=2`, `abortReason=consecutive_failed_poll_limit_exceeded`, `motionRefreshes=1`, `motionRefreshFailures=0`, `maxFrameUs=44003`, and `maxMotionSessionTimeouts=0`. Last good poll at 210.7 s still had `network=connected`, `bridge=ready`, `motion=true`, `motion_last_reason=enabled`, `motion_duty_rest_entries=0`, and socket present; then debug timed out, ping failed, COM4 disappeared, and only the bridge listener remained. A more conservative servo profile is built but not yet flashed: `STACKCHAN_SERVO_OUTPUT_PERIOD_MS=500`, `STACKCHAN_SERVO_IDLE_SCALE=0.15f`, `STACKCHAN_MOTION_DUTY_ACTIVE_MS=120000`, `STACKCHAN_MOTION_DUTY_REST_MS=30000`, `STACKCHAN_SERVO_RELEASE_ON_STOP=1`.
- Audio-load-shed isolation run `output\pc-brain\full-system-soak-audio-load-shed-isolation-20260708-222813` reached 1123 s of a planned 1200 s, then failed with `status=fail`, `failedPolls=3`, `maxConsecutiveFailedPolls=2`, and `abortReason=consecutive_failed_poll_limit_exceeded`. The useful evidence is that audio shedding did fire during real wake/playback activity: `maxMotionOutputSuppressEntries=9`, `maxMotionOutputSuppressTotalMs=115130`, `maxMotionDutyRestEntries=7`, `maxMotionSessionTimeouts=0`, `maxFrameUs=43928`. The bridge log then showed the robot forcibly closed the socket after another utterance window. Treat this as a board power/thermal/dropout suspect, not a face-rendering failure.
- Current flashed diagnostic firmware adds chip-temperature telemetry and a thermal servo output shed on top of audio-load shed. `/debug` now exposes `heap_free`, `heap_min_free`, `chip_temp_c`, `chip_temp_max_c`, `chip_temp_samples`, `motion_thermal_suppressed`, `motion_thermal_suppress_entries`, `motion_thermal_load_shed_c`, and `motion_thermal_resume_c`. Active thresholds are 70 C shed / 64 C resume.
- Current thermal-guard firmware archive: `output\firmware-leads\thermal-guard-20260708-231938`, firmware SHA256 `93D89B2F5E8AEF3B2EABB035A7AD1BDC7CBD084295CEA1F2B65FA23EB8186B88`. It was direct-flashed with esptool UTF-8 output forced after the PlatformIO wrapper hit a Windows progress-output encoding failure; esptool verified hashes. Post-flash `/debug` showed motion disabled, bridge ready after reconnect, face about 20 FPS, chip temp around 58.5-59.5 C, and thermal shed idle.
- Thermal-guard guarded 10-minute rerun `output\pc-brain\full-system-soak-thermal-guard-servo-10min-20260708-233216` failed at 245 s: `status=fail`, `failedPolls=2`, `maxConsecutiveFailedPolls=2`, `abortReason=consecutive_failed_poll_limit_exceeded`, `motionSampleRatio=0.9783`, `maxMotionSessionTimeouts=0`, `maxChipTempC=60.5`, `maxFrameUs=43336`, and `motionThermalSuppressSamples=0`. The last good window was bridge `thinking`; soon after, `/debug` timed out and the robot returned with `reset_reason="poweron"` / `reset_reason_code=1`. This does not implicate heat or face rendering; it points at a board power/dropout around mixed servo plus bridge-busy load.
- Current flashed bridge-busy load-shed firmware archive: `output\firmware-leads\bridge-busy-load-shed-20260708-234556`, firmware SHA256 `19668F12D1A2CA8B2B5B6B20F8994139787348ECBBB9D0E7AA7D18B9E44E1A9E`. This candidate keeps the audio-load and thermal sheds, and also releases servo output while the bridge is `listening`, `thinking`, `responding`, or has pending bridge outputs, with the same 8 s cooldown. Build passed, native logic tests passed `187/187`, direct flash verified hashes, and post-flash `/debug` showed motion disabled, bridge ready after PC bridge restart, face about 20 FPS, and chip temp around 57.5-58.5 C. It still needs a fresh supervised servo soak.
- First bridge-busy load-shed 10-minute monitor `output\pc-brain\full-system-soak-bridge-busy-shed-servo-10min-20260708-235542` reached the full 600 s with `okPolls=118`, `failedPolls=0`, `motionSampleRatio=1.0`, `maxMotionSessionTimeouts=0`, `maxChipTempC=60.5`, `maxFrameUs=47288`, `motionThermalSuppressSamples=0`, `motionOutputSuppressSamples=19`, and `maxMotionOutputSuppressTotalMs=96018`. The old checker marked it fail only because `mic_ready=false` during bridge `listening`/`responding`; live debug showed matching audio pause/resume counters, so the soak harness/checker now treats those intentional mic pauses as allowed.
- Official bridge-busy load-shed 10-minute steady monitor `output\pc-brain\full-system-soak-bridge-busy-shed-servo-official-10min-20260709-001050` passed: `status=pass`, `durationSeconds=600`, `okPolls=119`, `failedPolls=0`, `motionSampleRatio=1.0`, `maxMotionSessionTimeouts=0`, `maxChipTempC=60.5`, `maxFrameUs=43945`, `motionThermalSuppressSamples=0`, `rvcWorkerReadySamples=10/10`, and the harness stopped motion at the end. Formal checker passed with `full-system-soak-ready`, 31 passed, 0 failed, 0 pending. This official pass did not include a new voice turn; the preceding `235542` run is the bridge-busy voice-turn evidence.
- Official bridge-busy load-shed 50-minute supervised soak `output\pc-brain\full-system-soak-bridge-busy-shed-servo-50min-20260709-070029` passed: `status=pass`, `durationSeconds=3000`, `okPolls=296`, `failedPolls=1`, `maxConsecutiveFailedPolls=1`, `motionSampleRatio=1.0`, `maxMotionSessionTimeouts=0`, `maxChipTempC=60.5`, `maxFrameUs=39350`, `motionThermalSuppressSamples=0`, `motionOutputSuppressSamples=20`, `maxMotionOutputSuppressEntries=4`, `maxMotionOutputSuppressTotalMs=320637`, `motionRefreshes=5`, `motionRefreshFailures=0`, and RVC worker ready `50/50`. It included fresh bridge-busy/voice activity (`bridge_state=thinking`, `bridge_uplink_turns` increased, playback starts increased), and the servo output shed was active during that overlap. Formal checker passed with `full-system-soak-ready`, 31 passed, 0 failed, 0 pending. Post-run `/debug` showed bridge ready, motion off, face smooth at 20 FPS, and chip temp 60.5 C.
- Overnight bridge-busy load-shed 8-hour attempt `output\pc-brain\full-system-soak-bridge-busy-shed-servo-overnight-8hr-20260709-080743` failed at 3070 s: `status=fail`, `okPolls=101`, `failedPolls=2`, `maxConsecutiveFailedPolls=2`, `abortReason=consecutive_failed_poll_limit_exceeded`, `motionSampleRatio=1.0`, `motionRefreshes=5`, `motionRefreshFailures=0`, `maxMotionSessionTimeouts=0`, `maxChipTempC=61.5`, and `maxFrameUs=43098`. The last good poll at 3005.2 s still had network connected, bridge ready, wake/mic/speaker/RVC ready, motion enabled, and socket remote `192.168.1.238`; the next two `/debug` polls timed out and the bridge later logged `client_disconnect=192.168.1.238:62250 reason="socket:timed out"`. This evidence proves a repeated reachability dropout only; it does not prove the root cause is power, brownout, heat, Wi-Fi, USB, firmware panic, or task starvation.
- Instrumentation candidate archive: `output\firmware-leads\evidence-instrumented-power-usb-20260709-093022`, firmware SHA256 `160DE85017C6792808582C8A02EB20FDA813689B433E858C533D58F51DCDE315`. This is not a claimed stability fix. It adds `/debug` and serial telemetry for CoreS3 PMU VBUS voltage, battery voltage, battery level, charging state, min/max rail readings, and PMU read failures, and updates the soak harness to preserve those fields plus host COM-port presence in `polls.json`, `progress.json`, and `summary.json`.
- Instrumented power run `output\pc-brain\full-system-soak-instrumented-power-usb-servo-70min-20260709-105111` was safe-stopped before a dropout after servo motion pulled the board's reported VBUS minimum to `4395 mV`; after `/motion-stop`, VBUS recovered to about `4616 mV` while debug/bridge/COM stayed reachable. This supports an observed servo-load voltage-sag risk. It still does not prove every previous reachability dropout was a power or brownout event.
- First VBUS-guard firmware archive: `output\firmware-leads\vbus-guard-20260709-111916`, firmware SHA256 `FC1FA4E60C1C20EC36826E74A166E716B1D0D51A11FA5CC8FED7DF3565DED695`. This candidate kept the face-priority/debug-task, recovery, bridge-busy/audio, thermal, and PMU telemetry work, and added servo output load-shed when PMU VBUS was at or below `4450 mV`, resuming at or above `4600 mV`.
- VBUS-guard 20-minute supervised servo validation passed at `output\pc-brain\full-system-soak-vbus-guard-servo-20min-20260709-112209`: `status=pass`, `durationSeconds=1200`, `okPolls=234`, `failedPolls=0`, `motionSampleRatio=1.0`, `motionRefreshes=4`, `motionRefreshFailures=0`, `maxMotionSessionTimeouts=0`, `maxFrameUs=45130`, `maxChipTempC=59.5`, RVC worker ready `20/20`, and the strict checker reported `full-system-soak-ready` with 31 passed, 0 failed, 0 pending. The guard cycled 5 times (`motionPowerSuppressSamples=102`, `maxMotionPowerSuppressEntries=5`), the lowest on-device VBUS minimum was `4410 mV`, and the robot stayed reachable with face/bridge/wake/mic/speaker healthy.
- First VBUS-guard 50-minute attempt `output\pc-brain\full-system-soak-vbus-guard-servo-50min-20260709-120011` was intentionally safe-stopped at about 393 s after `/debug` reported `power_vbus_min_mv=4395`. The robot was still reachable, bridge/network were ready, face timing was healthy, and `/motion-stop` recovered live VBUS to about `4640 mV`; snapshot: `output\pc-brain\full-system-soak-vbus-guard-servo-50min-20260709-120011\vbus_floor_safe_stop_20260709-120732.json`.
- Current flashed hardened VBUS-guard firmware archive: `output\firmware-leads\vbus-guard-hardened-20260709-121107.zip`, firmware SHA256 `9E8459C242DBBDC817D3A979AA8B56EE39DE24D1566D7B8D141391967387DD66`. Current lead handoff archive: `output\current-lead\stackchan-vbus-guard-hardened-lead-20260709-121107.zip`, SHA256 `47388A1A0A88580EC3DF1B64BE9E908795A10E434EB357E05FA4CA368750CBC7`. This hardening uses 100 ms PMU sampling, sheds servo output at or below `4550 mV`, resumes only at or above `4700 mV`, and holds each power-shed state for at least `20000 ms`.
- Hardened VBUS-guard 20-minute supervised servo validation passed at `output\pc-brain\full-system-soak-vbus-guard-hardened-servo-20min-20260709-121456`: `status=pass`, `durationSeconds=1200`, `okPolls=235`, `failedPolls=0`, `motionSampleRatio=1.0`, `motionRefreshes=4`, `motionRefreshFailures=0`, `maxMotionSessionTimeouts=0`, `maxFrameUs=44608`, `maxChipTempC=59.5`, RVC worker ready `20/20`, `motionPowerSuppressSamples=234`, `maxMotionPowerSuppressEntries=2`, lowest sampled VBUS `4506 mV`, lowest on-device reported VBUS minimum `4498 mV`, and the strict checker reported `full-system-soak-ready` with 31 passed, 0 failed, 0 pending.
- Hardened VBUS-guard 50-minute attempt `output\pc-brain\full-system-soak-vbus-guard-hardened-servo-50min-20260709-124531` was safe-stopped at `524 s` by the external VBUS watcher after the board-reported VBUS floor reached `4397 mV`. The robot stayed online: `okPolls=53`, `failedPolls=0`, bridge/socket/network ready, COM4 present, `maxFrameUs=30468`, `maxMotionSessionTimeouts=0`, motion stopped cleanly, and post-stop debug remained reachable at `output\pc-brain\full-system-soak-vbus-guard-hardened-servo-50min-20260709-124531\vbus_floor_safe_stop_post_debug_20260709-125656.json`. A wake/audio turn also occurred during the run (`bridge_uplink_turns=1`, `bridge_downlink_playback_starts=1`), so this captured a mixed-load low-VBUS event rather than a face-rendering or bridge-starvation failure.
- No-servo power isolation `output\pc-brain\no-servo-power-isolation-10min-20260709-130429` failed fast at `71 s` with `abortReason=power_vbus_sample_floor_exceeded`, `records=8`, `failedPolls=0`, live sampled `minPowerVbusMv=4396`, motion disabled throughout, bridge/network ready, and face still about 20 FPS. This proves the current bench power condition can dip below the hard floor even without servo motion. Do not launch another powered soak on this source/cable path until the power path is changed.
- Wall-supply no-servo isolation `output\pc-brain\no-servo-power-isolation-wall-5v3a-10min-20260709-172502` passed the full `600 s` on a dedicated 5 V / 3 A adapter: `status=pass`, `records=60`, `okPolls=59`, one isolated HTTP timeout with the bridge socket still present, sampled VBUS `4860-4959 mV`, board-reported minimum `4797 mV`, charging active, battery rising to 87%, `maxChipTempC=62.5`, `maxFrameUs=38604`, bridge/network/wake/mic/speaker/RVC ready for every successful poll, and motion disabled throughout. The no-motion evidence checker profile passed `33/33` checks.
- Soak tooling update after the safe stop: `tools\run_full_system_soak_http_motion.ps1` and `tools\check_full_system_soak_evidence.ps1` now support a minimum unsuppressed-motion sample ratio and a minimum board-reported VBUS floor. The checker also has an explicit `-NoMotionProfile` so intentional power-isolation runs require zero motion instead of being misclassified by the full-servo profile. `tools\start_warm_rocm_full_system_soak.ps1` defaults servo soaks to `MinMotionUnsuppressedSampleRatio=0.50` and `MinPowerVbusReportedMv=4400`, so future passes cannot count a mostly power-suppressed motion session as a real servo soak.
- Current face-priority/debug-task archive: `output\current-lead\stackchan-face-priority-debugtask-lead-20260708-155000.zip` SHA256 `E0614A3C70EFCF90878B831ABDCE17ED3A70D36988A07ECC9B4B440EDD6EA701`. Manifest: `output\current-lead\stackchan-face-priority-debugtask-lead-20260708-155000-manifest.json`.
- Reset-telemetry diagnostic lead archive: `output\current-lead\stackchan-reset-telemetry-debugtask-lead-20260708-172630.zip` SHA256 `47DEFD33510EBC3F1B9C8581B0F4021F5BFDC404A44D437BAF56D2C316BFB28A`. Manifest: `output\current-lead\stackchan-reset-telemetry-debugtask-lead-20260708-172630-manifest.json`.
- Soak cadence lesson: `/motion-resume` every 20 s is unnecessarily chatty for this board runtime. The servo session timeout is 900000 ms, so the current lead uses reduced refresh cadence for soak work, for example `-MotionRefreshSeconds 300 -MotionRefreshInitialDelaySeconds 150`, which proves refresh without adding debug HTTP contention.
- `/recover` validation: request returned `debug_recovery_accepted=true`, scheduled recovery after the response, refreshed Wi-Fi/bridge, and the robot returned to `bridge_state=ready` with `recovery_wifi_restarts=1`.
- Strict servo-soak tooling: `tools\start_warm_rocm_full_system_soak.ps1` now requires the new motion telemetry by default, retries `/motion-resume` during preflight to handle actuator warm-up, staggers the monitor's first motion refresh away from the debug poll, and `tools\run_full_system_soak_http_motion.ps1` writes incremental `polls.json` plus a pass/fail `summary.json` with strict gates for motion, bridge socket, wake/mic readiness, speaker enablement, RVC worker health, motion timeouts, face frame time, and sustained debug dropouts. The strict runner now supports fail-fast aborts for missed-poll or motion-refresh breaches so a doomed servo soak does not continue overnight.
- Strict servo-soak checker: `tools\check_full_system_soak_evidence.ps1` validates the final `summary.json` and reports `full-system-soak-ready` only when the full overnight evidence meets the motion, face timing, bridge, wake, mic, speaker, RVC, and dropout gates.
- Supervised recovery wrapper: `tools\start_motion_timing_candidate_recovery_soak.cmd` ties together the motion timing candidate flash, `/debug` recovery, new motion telemetry verification, bridge socket check, and strict warm ROCm servo soak launch. It refuses servo-enabled recovery without `-OperatorPresent -BodyClear -ConfirmServoRisk`; dry-run and contract tests pass.
- Direct warm soak launcher guard: `tools\start_warm_rocm_full_system_soak.ps1` now also refuses to call `/motion-resume` unless `-OperatorPresent -BodyClear -ConfirmServoRisk` are explicit, so bypassing the recovery wrapper does not bypass the servo safety gate.
- Host bridge reconnect fix: `bridge\lan_service.py` now sends a `hello` frame immediately after the WebSocket handshake. The live robot reconnected to the restarted PC bridge and recovered to `bridge_state=ready` with the face still at `20.00` FPS.
- Current lead reproducibility checker: `tools\check_current_lead_reproducibility.cmd` verifies the warm ROCm archive, motion timing candidate archive, docs, live ROCm worker, live bridge process, passive no-motion watcher, and strict soak status. Latest live result after the stopped `103059` run: `current-lead-reproducibility-failed`; the failed check is the strict soak summary status. Relaunch only after the robot is physically recovered and the operator reconfirms body clear / servo risk.

Validated live on 2026-07-08:

- User said the wake phrase and asked the robot its name.
- Whisper heard `What is your name?`.
- The bridge identity path answered `I am Stackchan.`
- `bridge\rvc_tts.py` generated real RVC audio, not a canned selected sample.
- The robot spoke `I am Stackchan`; user confirmed it was perfect.
- Robot debug after the RVC turns reported `bridge_state=ready`, `display_window_fps=20.00`,
  `bridge_downlink_playback_errors=0`, and `speaker_stream_play_raw_failed=0`.
- Warm ROCm worker/client validation produced a second local conversion in about 3 s, and the live bridge was restarted with `python bridge\rvc_tts_client.py`.
- Servo-soak attempts at `output\pc-brain\full-system-soak-warm-rocm-overnight-20260708-022528*` showed the face still sampling at `20.00` FPS with no slow frames, but motion auto-disabled and later would not re-enable. The last no-motion soak sample timed out against the debug endpoint, and the bridge later logged `client_disconnect=192.168.1.238:65364 reason="socket:timed out"`.
- Code audit found that `ActuationEngine` stored `enabledAtMs_` from `millis()` but compared it against `nowUs / 1000` from `micros()`. Because `micros()` wraps after about 71 minutes, a long-running robot could accept `/motion-resume` and then immediately time out motion in the motion task. The candidate fix adds motion debug telemetry for actuator readiness, last reason, request counts, stop calls, and session timeout count.

Open before calling the full system final:

- The robot was physically recovered after the failed `103059` run. The recovery/debug-task firmware is now flashed, `/recover` has been verified, the reduced-refresh 10-minute full-system servo soak passed, and reset-reason telemetry is now present in `/debug`. Use `/recover` as the first remote refresh path while `/debug` is reachable; use physical reset only when Wi-Fi/debug/USB are all unavailable.
- The reset-instrumented 45-minute diagnostic full-system servo soak passed. The remaining gate before calling the full system final is an overnight full-system soak with face, wake, bridge, speaker, warm RVC, and servos enabled using reduced motion refresh cadence. If a dropout repeats, capture the first post-return `/debug` values for `boot_count` and `reset_reason`.
- Do not promote `output\pc-brain\full-system-soak-warm-rocm-servo-20260708-215656`. It failed after 577 s with `status=fail`, `abortReason=consecutive_failed_poll_limit_exceeded`, 18 good polls, 2 failed polls, 3 servo duty-rest cycles, `maxFrameUs=44049`, `maxSlowFrames=30`, no motion timeouts, and no motion refresh failures. The operator physically turned the robot back on after the screen went off.
- The `215656` failure did not implicate the face renderer directly; display timing stayed under the 50 ms promotion gate. The failure appeared when wake/audio uplink/downlink activity overlapped active servo motion. Treat this as a combined servo + voice/audio load failure until a guarded retest proves otherwise.
- The currently flashed post-failure candidate adds broader bridge-load motion output shedding: servo output remains logically enabled for soak accounting, but physical servo output is released while wake-gate/audio uplink/downlink/speaker playback is active, while the bridge is `listening`/`thinking`/`responding`, while bridge outputs are pending, and for an 8 s cooldown afterward. It also reports chip temperature and releases servo output if internal chip temp reaches 70 C, resuming only after it falls to 64 C.
- The bridge-busy load-shed candidate built successfully, direct flash verified hashes, the soak evidence contract passed, native logic tests passed `187/187`, the official 10-minute steady monitor passed the strict checker, and the official 50-minute supervised soak passed with fresh bridge-busy/voice overlap. The later PMU instrumentation showed servo-load VBUS sag, the first VBUS guard caught another `4395 mV` floor before dropout, and the hardened VBUS guard caught a `4397 mV` floor while the robot remained reachable. The motherboard USB power paths then dipped to `4396 mV` with motion off, while the dedicated 5 V / 3 A wall supply passed a 10-minute no-motion isolation with a `4860 mV` sampled floor. This supports the motherboard USB power path as the immediate blocker without claiming that every historical dropout had the same cause. The next gate is a real unsuppressed 50-minute guarded servo soak on the wall supply.
- The servo soak is not complete until `summary.json` reports `status="pass"`, `issues=[]`, `motionSampleRatio >= 0.95`, `rvcWorkerReadySamples == rvcWorkerPolls`, max display frame time stays at or below `50000` us, no motion session timeout is observed, no sustained debug dropout is observed, and `tools\check_full_system_soak_evidence.ps1 -SummaryJsonPath <summary.json> -RequireReady -Json` reports `full-system-soak-ready`.
- Keep the archived lead zips as restore points: pre-ROCm CPU RVC, warm-ROCm RVC, and the flashed motion timing candidate.

## Current Live Configuration

- Robot IP: `192.168.1.238`
- PC bridge host: `192.168.1.240`
- PC bridge port/path: `8765` / `/bridge`
- Firmware debug endpoint: `http://192.168.1.238:8789/debug`
- PC brain listener PID observed live after reset-telemetry flash: `4608`
- Selected voice: `stackchan-rvc-warm-rocm`
- Current PC brain STT: `python bridge\whisper_cpp_stt.py` with local whisper.cpp `ggml-base.en.bin`
- Firmware speaker volume: `115`
- Current flashed firmware environment: `stackchan_wake_mww_uplink_servos_m5_voiceout`
- Current flashed feature flags: Wi-Fi bridge on, speaker on, MWW wake/uplink candidate code present, servo hardware compiled in but motion disabled at boot, audio/bridge-busy servo output shed enabled, chip-temperature telemetry enabled, thermal servo output shed enabled at 70 C / 64 C, PMU VBUS telemetry enabled, hardened VBUS servo output shed enabled at 4550 mV / 4700 mV with 100 ms sampling and 20000 ms minimum suppression hold
- Rejected bot-local wake environment: `stackchan_wake_sr_probe` (physically tested, wake detected, rejected for face performance, rolled back)
- Next bot-local wake candidate environment: `stackchan_wifi_asr_unit` (ASR-over-UART offload, build-passing, not flashed)
- Current robot-mic/uplink validation status: gated, not physically validated after servo bring-up
- Rollback firmware environment: `stackchan_wifi`

## Recovery Decision

The robot was restored to the smooth face/bridge-only baseline after the bad full-online attempt. Treat this as the known-good physical baseline.

Do not jump directly from this baseline to motor-enabled full-online firmware. The safer sequence is:

1. Keep `stackchan_wifi` as the rollback target and known-good bridge-only baseline.
2. Do not keep or repeat `stackchan_wake_sr_probe` as-is. It uses ESP-SR WakeNet on the robot and detected `Hi Stack Chan`, but it regressed display frames to about `85-102 ms`.
3. Use `stackchan_wifi_asr_unit` as the next bot-local wake candidate only after an offline ASR UART module is present. This keeps recognition off the CoreS3 face runtime.
4. Treat robot-mic/uplink validation as the next supervised voice step only after the guarded servo path remains stable. The successful servo session does not validate live mic/STT.
5. Do not tune mic sensitivity on the robot without a rollback plan, quiet-soak window, and operator watching the face.
6. Keep the PC bridge wake-phrase guard enabled before any audio turn reaches the model/TTS path.
7. Only after visual face stability and voice-gate behavior are confirmed on staged firmware, consider `stackchan_full_online`.
8. Flash `stackchan_full_online` only through the guarded wrapper with operator present, body clear, and explicit servo-risk confirmation. Do not remove the successful servo guardrails from `stackchan_wake_mww_uplink_servos`: motion disabled at boot, servo attach fail-closed, write rate limiting, and session auto-stop.

## Validated After Recovery

- User visually confirmed the face is smooth after unplug/reboot.
- `stackchan_wifi` was reflashed on `COM4` and reconnected from stored Wi-Fi provisioning.
- Live debug reports `network_state=connected`, `bridge_state=ready`, and `network_error=""`.
- PC brain runtime check passed after rollback: `pc-brain-runtime-ready`, 25 passed, 0 failed, 0 pending.
- Native firmware logic tests passed after the voice-gate changes: 182/182.
- Known-good bridge-only firmware build passed: `platformio run -e stackchan_wifi`.
- Staged mic/uplink firmware build passed: `platformio run -e stackchan_wifi_uplink`.
- Guarded full-online firmware build passed: `platformio run -e stackchan_full_online`, build-only and not flashed.
- PC brain transcript wake gate is disabled for bot-local wake mode; the robot wake detector authorizes audio turns before upload.
- PC brain now rejects empty audio utterances before invoking the model/TTS path.
- Local whisper.cpp STT is installed under `output\local-tools\whisper.cpp` and passed a generated-speech smoke test.
- PC brain engine preflight passed with Whisper STT, real runner smoke, and selected voice TTS.
- Live PC brain was restarted with `python bridge\whisper_cpp_stt.py`; runtime check passed with 25 passed, 0 failed, 0 pending.
- Earlier staged mic/uplink work proved the low mic activation tone path and a 120-second quiet soak before the speech-start change.
- Speech-start wake gating remains code/build candidate behavior for `stackchan_wifi_uplink`, but it is not physically validated.
- A sensitivity trial with higher mic gain/lower saliency thresholds false-triggered repeated activation tones and empty turns; the robot was immediately rolled back to `stackchan_wifi`.
- Current live debug after rollback reports `network_state=connected`, `bridge_state=ready`, `network_error=""`, and `audio_stream_active=false`.
- Current live debug after rollback reports zero audio streams started, zero downlink streams, zero bridge parse errors, zero bridge timeouts, zero playback errors, and `speaker_tone_ok=0`.
- `stackchan_full_online` remains build/preflight-only in this recovery track. It has not been flashed or physically validated after the rollback.
- Full-online no-upload preflight passed: `full-online-preflight-ready-to-flash`, 5 passed, 0 failed, 1 expected pending live gate.
- Full-online flash readiness passed as a machine preflight: `full-online-flash-ready`, 25 passed, 0 failed, 1 expected pending live gate.
- Supervised full-online flash wrapper dry-run passed: `full-online-supervised-flash-dry-run-ready`.
- Bot-local wake research selected ESP-SR WakeNet/AFE for CoreS3, using the `Hi Stack Chan` model path.
- Isolated bot-local wake firmware build passed: `platformio run -e stackchan_wake_sr_probe`.
- `stackchan_wake_sr_probe` flashed successfully on `COM4`; `srmodels.bin` also flashed successfully to the model partition.
- Bot-local wake detection worked: runtime reported SR ready and `[sr_wake] event=wake_word applied=1`.
- Bot-local wake probe failed the visual-performance gate: quiet display telemetry dropped to about `11.6-11.8 fps` with `85-102 ms` frames.
- The robot was immediately rolled back to `stackchan_wifi`.
- Native firmware logic tests passed after the bot-local wake/ASR parser changes: 185/185.
- Known-good bridge-only firmware still builds after the ASR parser was added: `platformio run -e stackchan_wifi`.
- ASR-offload bot-local wake candidate builds: `platformio run -e stackchan_wifi_asr_unit`.
- Guarded servo firmware builds and is physically flashed: `stackchan_wake_mww_uplink_servos`.
- Servo attach is proven on the physical M5StackChan body with CoreS3 host `RX=GPIO7`, `TX=GPIO6`; serial attach reported `ping_x=1 ping_y=2`.
- Controlled supervised motion was visually confirmed by the operator: movement looked clean, the body area was clear, the face stayed smooth, and screen FPS looked good.
- Servo motion auto-stopped after the guarded session timeout; follow-up status reported `motion_enabled=0`.
- Post-motion display telemetry returned to a smooth baseline around `frame_ms_avg=25.7 ms`, `frame_ms_max=28.0-28.4 ms`, and `slow_frames=0`.

## Current Evidence

- Power-cycle/reconnect note: `output/hardware-evidence/first-live-bridge/POWER_CYCLE_RECONNECT_20260707.md`
- Full-online preflight: `output/pc-brain/full-online-preflight-latest/FULL_ONLINE_PREFLIGHT.md`
- Flash readiness: `output/pc-brain/full-online-flash-readiness-latest/FULL_ONLINE_FLASH_READINESS.md`
- Supervised flash dry-run: `output/pc-brain/full-online-supervised-flash-latest/FULL_ONLINE_SUPERVISED_FLASH.md`
- Mic tone proof: `output/hardware-evidence/first-live-bridge/wifi-uplink-mic-tone-20260707/mic_activation_tone_serial.log`
- Post-tone recovery turn: `output/hardware-evidence/first-live-bridge/wifi-uplink-recover-ready-20260707/recover_ready_text_turn_serial.log`
- Tone-enabled staged quiet soak: `output/pc-brain/quiet-soak-wifi-uplink-tone-20260707/PC_BRAIN_QUIET_SOAK.md`
- Speech wake gate attempt and rollback note: `output/hardware-evidence/first-live-bridge/SPEECH_WAKE_GATE_20260707.md`
- Whisper STT bring-up: `output/hardware-evidence/first-live-bridge/WHISPER_STT_20260707.md`
- Bot-local wake probe plan: `docs/BOT_LOCAL_WAKE_SR_PROBE.md`
- Bot-local wake probe result: `output/hardware-evidence/bot-local-wake-sr/20260707-013728/BOT_LOCAL_WAKE_SR_RESULT.md`
- Bot-local wake architecture decision: `docs/BOT_LOCAL_WAKE_ARCHITECTURE.md`
- Guarded servo validation note: `output/hardware-evidence/first-live-bridge/SERVO_GUARDED_VALIDATION_20260707.md`
- Motion timing recovery wrapper and contract: `tools\start_motion_timing_candidate_recovery_soak.cmd` and `tools\test_motion_timing_candidate_recovery_soak_contract.ps1`
- Hardened VBUS-guard firmware archive: `output\firmware-leads\vbus-guard-hardened-20260709-121107.zip`
- Current hardened VBUS-guard lead archive: `output\current-lead\stackchan-vbus-guard-hardened-lead-20260709-121107.zip`
- Hardened VBUS-guard 20-minute full-system servo validation: `output\pc-brain\full-system-soak-vbus-guard-hardened-servo-20min-20260709-121456\summary.json`
- Current lead reproducibility report: `output\current-lead\current-lead-reproducibility-latest\CURRENT_LEAD_REPRODUCIBILITY.md`

## Still Open

- Do not treat `Hey Stackchan` as validated on the current live robot yet; the successful session validated guarded servo motion and face stability, not a live robot-mic/STT turn.
- The first bot-local wake probe listened for `Hi Stack Chan`, not `Hey Stackchan`.
- Do not use `stackchan_wake_sr_probe` as the next physical step; it proved wake but failed face performance.
- Use the lower-impact ASR UART offload architecture before another physical wake attempt.
- Do not flash `stackchan_wifi_asr_unit` until the ASR hardware is wired, the wake phrase/command ID is configured, and rollback to `stackchan_wifi` is ready.
- Continue with Whisper as the default PC STT path. Windows Speech remains fallback only.
- Re-enter robot-mic/uplink validation only for a supervised, short, measured voice-gate session with rollback ready.
- If the face flickers, false-triggers, or bridge responsiveness regresses, roll back to `stackchan_wifi`.
- Full-online promotion remains gated. The Power Coordinator passed its 60-second supervised servo qualification on the dedicated 5 V / 3 A wall supply, but it still needs a real 50-minute full-system servo soak, then an overnight guarded soak and the full validation checker. Keep historical dropout causes recorded as unknown unless a future evidence packet directly identifies one.
- Do not call the robot full-online validated until `tools\check_full_online_validation.cmd -EvidenceRoot output\pc-brain\full-online-validation-latest -RequireReady -Json` passes after supervised physical observations.
- Capture/import real device media for the smooth face and target-speaker audio review.
