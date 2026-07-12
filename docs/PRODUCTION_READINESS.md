# Production Readiness

Current status (2026-07-12): the integrated physical release candidate passed exact-image
no-motion, actuator, voice, camera, body-sensor, OTA, and formal one-hour acceptance gates, then
completed more than five hours of extended all-feature operation without a strict hardware bad
state. The repository owner accepted that evidence and waived the remaining eight-hour duration.
The Apache-2.0 release includes the active production RVC model and index.

## Proven Now

- Firmware builds for `m5stack-cores3`.
- Display-only and servo-calibration firmware variants are separate PlatformIO environments.
- Runtime dependency pins are declared in `platformio.ini`; release packages record resolved transitive versions.
- Release packages include dependency provenance, a machine-readable dependency lock, copied build inputs, and a dependency audit that flags duplicate resolved package names or upstream Git requirements that were not directly pinned by this project.
- Release packages preserve installed third-party license, licence, copying, notice, and package-metadata files under `third_party_licenses/`, publish a portable SHA-256 index, and include `THIRD_PARTY_NOTICES.md`. Package verification checks every indexed file and the required pioarduino, Arduino-ESP32, direct-library, nested M5GFX, and YuNet evidence.
- The project source and public release package are licensed under Apache-2.0; the root
  `LICENSE` is included in the release ZIP and declared by the release manifest.
- Release packages can be verified locally before publication, and published release assets can be re-audited after upload.
- Release packages include flash, verification, and hardware evidence-capture helpers.
- Hardware evidence packets include a media importer that validates phone photos/videos/audio and records SHA256 hashes in `media_manifest.json`.
- Release packages include a binary flasher that writes the exact packaged display-only or servo-calibration firmware.
- Release packages include a manual GitHub publish helper that verifies the uploaded ZIP when GitHub Actions cannot run.
- Published release assets can be audited against the local package by size, SHA256 digest, and downloaded-ZIP verification.
- A local release handoff page can serve the ZIP, preview image, expression sheet, and preview video, with optional Cloudflare tunnel exposure.
- Hardware evidence packets can be verified before release promotion, including proof that the tested ZIP was copied and package-verified.
- Consumer promotion is guarded by `tools/verify_consumer_promotion.ps1`, which composes package
  verification, hardware evidence verification, GitHub Actions status, production voice-source
  provenance, an owner-selected project license, operator-approved camera wake/follow evidence,
  complete touch/IMU evidence, and a formally verified integrated soak. Camera, body, and soak
  reports must pin the same installed firmware SHA-256 and the clean matching source commit.
- Synthetic diagnostic evidence packets can be generated to self-test the verifier, and are rejected by default unless `-AllowSyntheticEvidence` is explicit.
- Hardware evidence verification rejects completed observation records that report reset loops, missing face display, missing dry-run servo log, missing firmware boot/heartbeat serial markers, missing runtime health telemetry, heat/brownout, short soak duration, failed power-cycle recovery, invalid calibration ranges, placeholder-only media evidence, header-only media files, or implausibly small media files.
- No-hardware preflight checks can validate toolchain availability, dependency pins, flash-helper safety gates, local-share evidence capture, speech-envelope sidecar generation/dry streaming, preview media, hardware evidence verifier gates, tests, builds, and an optional release ZIP before device flashing.
- A no-hardware virtual Stackchan simulator checks bridge frame ordering, LAN text turns, fake mic PCM upload through fake STT, speech-envelope handoff, fake WAV TTS normalization to PCM16 downlink, PCM16 speaker handoff telemetry, servo safety stop/resume and clipping behavior, and timeout failure behavior before the physical unit arrives.
- Release package verification rejects direct Git dependencies without refs and resolved Git dependencies without SHA evidence.
- Release packaging refuses dirty source worktrees by default.
- GitHub Actions workflows are configured for firmware and release checks, but account billing/spending-limit status and hosted-runner allocation must allow jobs to start before they can be used as rollout evidence. Promotion evidence requires both required workflows, `Firmware` and `Release`, to be observed for the matching commit; one green workflow is not enough if the other is missing.
- The exact active RVC files are tracked by SHA-256, distributed through Git LFS, and copied into
  the release package. `tools/verify_tracked_rvc_assets.ps1` enforces their byte counts and hashes.
- The LiteRT-LM/mobile brain path has a wrapper contract, but real LiteRT-LM runner speed, memory, and Character Lock compliance are not proven until a configured runner benchmark passes.
- Native host tests execute mood, spring, and expression logic without hardware.
- Motion and face tasks read the same latest frame snapshot.
- Servo output is disabled by default until hardware calibration.
- Servo-enabled flashing requires an explicit `-ConfirmServoRisk` operator acknowledgment.
- Display rendering uses the M5 display backend, not a stub.
- Preview media can be generated without hardware.
- The exact installed paired firmware passed a formally checked one-hour actuator acceptance with
  every poll and motion sample good, no reset, timeout, power, camera, or peripheral fault, and a
  verified motion stop. The exact SHA-256 and evidence root are recorded in
  `FIRST_DEPLOY_STATUS.md`.
- Physical wake, Whisper/Gemma/RVC reply transport, complete speaker playback, synchronized mouth
  motion, bounded camera following, power-coordinated servos, RGB behavior, touch, IMU interaction,
  and LAN OTA rollback/confirmation have all been exercised on the real robot.
- Deterministic trusted facts and explicit memory operations answer local time/date/name and
  approved remembered facts without depending on Gemma to choose a tool. Generic conversation is
  not silently promoted into durable memory.
- Unambiguous yes/no replies produce seed-varied procedural nod or head-shake gestures while
  preserving the single-writer actuator boundary.

## Post-Release Follow-Up

- Continue longer-duration community and lab runs as regression evidence; the owner waived the
  remaining duration of the interrupted launch run for this release.
- Audit downloaded release assets against the published SHA-256 sidecars.
- PC/mobile owner failover and target-store distribution evidence for whichever companion targets
  are presented as consumer-ready. These do not block the current PC-hosted public release.
- Real LiteRT-LM/mobile runner speed and memory behavior.
- Proximity behavior is not implemented and must not be advertised.

## Consumer Rollout Gate

Do not call this consumer-ready until all of these are evidenced for the release commit:

1. Exact source commit, installed firmware SHA-256, packaged binaries, and physical evidence agree.
2. Display, wake, microphone, bridge, brain, voice conversion, complete speaker playback, mouth
   motion, servos, camera following, RGB, touch, and IMU gates pass on the integrated candidate.
3. Power-cycle, OTA confirmation/rollback, actuator stop, power, thermal, and display recovery
   evidence pass without unsupported root-cause claims.
4. The formally checked one-hour actuator acceptance passes and the owner records the accepted
   extended-run evidence for the release.
5. The tested release ZIP is independently extracted and verified, with a matching
   `logs/package_verify.log`, manifest commit, and published-asset SHA-256.
6. Bundled production voice files match the recorded release hashes.
7. Required companion target, owner-failover, privacy, and store/distribution evidence is complete
   for every platform advertised as consumer-ready.
8. `tools/verify_consumer_promotion.ps1` passes for the exact release package and evidence packet.

The repository is a physically validated public release candidate; individual assembled robots
still require their own calibration and hardware safety checks.
