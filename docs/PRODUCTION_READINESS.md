# Production Readiness

Current status: Stackchan: Alive character OS scaffold is device-ready, not hardware-certified.

## Proven Now

- Firmware builds for `m5stack-cores3`.
- Display-only and servo-calibration firmware variants are separate PlatformIO environments.
- Runtime dependency pins are declared in `platformio.ini`; release packages record resolved transitive versions.
- Release packages include dependency provenance, a machine-readable dependency lock, copied build inputs, and a dependency audit that flags duplicate resolved package names or upstream Git requirements that were not directly pinned by this project.
- Release packages preserve installed third-party license, licence, copying, notice, and package-metadata files under `third_party_licenses/`, publish a portable SHA-256 index, and include `THIRD_PARTY_NOTICES.md`. Package verification checks every indexed file and the required pioarduino, Arduino-ESP32, direct-library, nested M5GFX, and YuNet evidence.
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
- Production voice-source provenance is explicitly tracked; current generated WAVs are review samples until `data/voice_source_provenance.yaml` is completed with licensed or owned source evidence.
- `tools/check_voice_source_readiness.cmd -Json` audits the active production voice-source gate without mutating release artifacts; it should remain `pending-production-voice-source` until the licensed/owned source, consent/license evidence, template attestations, and target-speaker evidence are complete. Production-ready voice provenance must include a top-level `source_commit` that matches the checker report `sourceCommit`; `tools/test_voice_source_readiness_contract.cmd` covers pending, complete, stale, missing-commit, and unresolved-RVC cases. Final desktop and companion v1 evidence bundles compare report `sourceCommit` fields to the reviewed bundle commit, including source readiness, PC Brain deploy/quiet-soak lab evidence, and voice approval evidence, so stale platform, lab, or voice evidence cannot close release readiness.
- Release packages include `VOICE_SOURCE_STATUS.md` and `voice_source_status.json`, which summarize the blocked production-voice gates from the provenance YAML and template.
- The LiteRT-LM/mobile brain path has a wrapper contract, but real LiteRT-LM runner speed, memory, and Character Lock compliance are not proven until a configured runner benchmark passes.
- Native host tests execute mood, spring, and expression logic without hardware.
- Motion and face tasks read the same latest frame snapshot.
- Servo output is disabled by default until hardware calibration.
- Servo-enabled flashing requires an explicit `-ConfirmServoRisk` operator acknowledgment.
- Display rendering uses the M5 display backend, not a stub.
- Preview media can be generated without hardware.

## Not Proven Until Device Arrives

- Actual yaw mode and feedback behavior.
- Servo pin mapping on the specific body revision.
- Mechanical limits under load.
- Long-running thermal and power behavior.
- Physical acceptance of body RGB/touch, IMU, and paired camera/host vision in one integrated
  release candidate. The camera-only profile remains diagnostic. Proximity is not implemented.
- Real LiteRT-LM/mobile runner speed and memory behavior.

## Consumer Rollout Gate

Do not call this consumer-ready until the physical device passes:

1. Display-only flash and 10-minute idle run.
2. Servo-enabled supervised motion test.
3. Yaw classification and calibration.
4. 30-minute mixed idle/listen/speak soak.
5. Recovery test after USB power cycle.
6. Documented firmware version and calibration values.
7. Hardware evidence packet with the tested release ZIP and successful `logs/package_verify.log`.
8. Completed production voice-source provenance and real-device speaker evidence.
9. `tools/verify_consumer_promotion.ps1` passes for the release package and evidence packet.

Until those are done, this repository is production-shaped and test-ready, but not field-proven.
