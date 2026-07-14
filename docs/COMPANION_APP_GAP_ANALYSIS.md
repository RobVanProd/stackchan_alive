# Companion App Gap Analysis

Current branch: `codex/companion-v1-cross-platform-bundle`

This document carries forward the product gap audit from commit
`42879b8e7ccdeb3358b7ea31f1f9c74dcdf21f70` and records what is still missing on the
current v1 companion branch.

## Current Status

- The native all-platform CI rehearsal at source commit `d389307831398e02469cd3b2ade8c084ed136423`
  passed firmware, bridge, companion contracts, Android APK/AAB packaging and API 35 install/launch,
  Windows MSI, Linux DEB, macOS DMG, installer-derived managed-runtime identity, and aggregate
  companion release evidence. Source readiness is now `126 passed / 0 failed / 13 external gates
  pending`; a successful upload-signed tag and target-device/operator evidence are still required.
- G1 conversation surface is partially closed. The shared app now has a Talk panel on
  Android and desktop. Text turns are sent through the active `CompanionEndpointServer`
  session as `app_text_turn` response frames (`thinking`, `response_start`,
  `audio_stream_start`, binary audio chunks, `audio_stream_end`, `response_end`).
- Android push-to-talk now requests `RECORD_AUDIO`, uses Android `SpeechRecognizer` for
  transcript capture when available, and submits the final transcript through the existing
  robot-gated text-turn path. The Android UI now distinguishes speech recognizer unavailable,
  microphone permission required, and microphone permission denied states, and denial opens
  the Android app-settings retry path without submitting a transcript. Android now emits
  privacy-safe `StackchanSpeech` logcat markers for push-to-talk evidence without transcript
  content, and `tools/check_android_speech_evidence.ps1` validates the diagnostics export,
  logcat markers, robot response frames, support-review packet, and optional expected
  source-commit match. `tools/test_android_speech_evidence_contract.ps1` now covers complete
  speech evidence, missing robot response frames, transcript privacy leaks, and stale speech
  review commits. Target-phone STT behavior, robot response-frame capture, and
  `android-speech-ready` evidence still need to be captured before G1 is complete.
- G2 real Mobile Brain Mode is still open. The bridge text-turn and audio-turn path now
  runs through a `BrainTurnEngine` boundary with deterministic fake output as the default.
  Android now includes the pinned `com.google.ai.edge.litertlm:litertlm-android:0.13.1`
  dependency, GPU/CPU backend initialization code, and the optional native-library manifest
  entries recommended for LiteRT GPU loading. When the verified local Gemma asset is loaded,
  Android routes turns through that LiteRT adapter and falls back to an explicit
  `mobile_brain_litert_error` response if runtime initialization or generation fails on
  device; host tests still use the transparent staged engine so CI does not pretend to run
  the model. Android and desktop now expose a Gemma-4-E2B LiteRT-LM model asset panel with
  working download/cache, load/eject, and settings entry points. Load/eject are now explicitly
  described as staging or unstaging the verified asset, not as proof that real inference is
  active. The app now targets the LiteRT Community
  `gemma-4-E2B-it.litertlm` artifact and rejects partial/wrong-size files before Load.
  Load now verifies the pinned SHA-256 before marking the local asset staged, and Android
  diagnostics include the resulting `checksum_verified` state. The source tree now includes
  `tools/check_android_gemma_evidence.ps1` to gate the final phone evidence on the
  diagnostics export, real `mobile_brain_litert_turn` logcat, non-dry-run
  `gemma4-e2b-litert-lm` benchmark candidate evidence, eject/reload review, and robot
  audio/TTS review.
  The remaining G2 gap is real-device download proof, successful LiteRT runtime inference,
  captured benchmark evidence, and robot audio/TTS validation.
- G3 settings, diagnostics, persona selection, and manual brain handoff UI are partially
  closed. Android and desktop now expose user-facing settings, diagnostics, persona, and
  handoff status panels from the settings repository, diagnostics snapshot, and live bridge
  state. Safe local settings now save through the existing `settings_set` repository path,
  including persona switching, display reduced-motion, and diagnostics log-export preference.
  Android and desktop also support persona import/export through platform file pickers using
  validated `stackchan.persona-pack.v1` zip files. The shared bridge server now has a
  robot-hello-gated protected outbound control path for `settings_set`, `claim_brain`, and
  `release_brain`; Android submits protected settings writes after local save when a robot
  is connected, and Android/desktop manual brain claim/release buttons send real
  `claim_brain` / `release_brain` frames. Simulated robot tests prove `settings_result` and
  `owner_status` responses update app state. The source tree now includes
  `tools/check_android_controls_evidence.ps1` to gate the final phone evidence on a
  diagnostics export, robot-side `settings_set` / `settings_result` /
  `claim_brain` / `release_brain` / `owner_status` log markers, the pre-hello
  `robot_hello_required` safety gate, and a human review packet. The controls checker now
  supports source-commit-pinned strict evidence, and
  `tools/test_android_controls_evidence_contract.ps1` covers complete controls evidence,
  missing hello-gate proof, non-Android endpoint identity, and stale controls review commits.
  Physical robot round-trip evidence and `android-controls-ready` are still required before
  G3 is complete.
- G4 decorative controls are improved but not fully closed. Unsupported controls are
  disabled, shared UI defaults no longer show invented battery/temperature/firmware values,
  heartbeat is now an honest bridge status instead of a fake millisecond value, and audio
  visualization is labeled as a preview rather than live robot output. Physical screenshots
  still need to prove the connected-state UI only shows measured robot fields.
- G5 pairing enforcement is partially closed. Android and desktop no longer treat a raw
  WebSocket connection as a connected robot session: app text turns, audio writes, settings
  writes, Talk enablement, wake-lock promotion, and setup-complete UI now require the robot
  `hello` handshake first. Android also exposes the intermediate "robot socket detected,
  waiting for hello" state in setup, notification detail, and diagnostics export. Android now
  shows a phone-side pairing ticket with pairing code, fingerprint, bridge URL, discovery
  mode, a current next step, and saved-robot add/remove guidance after a robot `hello`. The
  bridge endpoint now sends that same short code in `endpoint_hello.pairing_code`, and
  firmware can be built with `STACKCHAN_PAIRING_SHORT_CODE` to reject endpoint trust unless
  the normalized six-character code matches. Firmware also exposes a native-tested
  `pairing code <ABC123>` / `pairing clear` serial control path for lab bring-up without
  reflashing. Android now renders a scannable `stackchan://pair` QR ticket for the same
  bridge URL, short code, phone fingerprint, and endpoint id shown in the manual flow.
  Firmware now accepts that same ticket payload over the bench/setup path as either
  `pair ticket <stackchan://pair?...>` or the raw payload, extracts the pairing code and
  percent-decoded bridge URL, and can retarget the bridge when robot Wi-Fi credentials are
  already configured. The source tree now includes
  `tools/check_android_pairing_evidence.ps1` to gate final pairing evidence on the Android
  diagnostics export, setup QR/code media, robot-side `pairing_code_mismatch`,
  `stackchan://pair?`, `bridge_url_applied`, `endpoint_hello_result`, and
  `trusted_endpoints_result` markers, plus a source-commit-pinned human review packet.
  `tools/test_android_pairing_evidence_contract.ps1` covers complete pairing evidence,
  missing wrong-code rejection proof, non-Android endpoint identity, and stale pairing
  review commits. Physical robot QR scanning/menu proof and `android-pairing-ready` still remain blocking before public
  distribution.
- G6 first-run Wi-Fi provisioning is partially closed. The Android Nodes setup flow now
  starts with a Wi-Fi bootstrap step, reports whether the phone is currently on Wi-Fi,
  opens native Wi-Fi settings, and explains that the robot must reach the phone bridge URL.
  When the phone bridge is running, Android now also shows a `Robot Wi-Fi setup` serial
  command template using the current bridge URL and placeholder network credentials so lab
  setup can proceed without hunting through docs.
  Firmware now has a native-tested serial path for persistent Wi-Fi/bridge provisioning:
  `wifi set ssid "<name>" pass "<password>" url "ws://host:port/bridge"`, equivalent host/port/path
  tokens, and `wifi clear`. The command preserves case-sensitive credentials in a
  `stackchan.bridge-wifi.v1` Preferences-backed store, loads the saved bridge target at boot,
  does not print the password, and restarts the bridge client without reflashing. The parser
  now accepts quoted SSID/password/URL values for normal network names with spaces, and the
  Windows lab helper `tools\provision_stackchan_wifi.cmd` emits the quoted serial command,
  prompts for the password when omitted, and redacts it from captured logs. A polished
  consumer robot-side menu/BLE provisioning flow plus hardware proof remain open. The source
  tree now includes `tools/check_android_wifi_evidence.ps1` to gate final Wi-Fi provisioning
  evidence on the Android diagnostics command template, robot-side `[wifi] persisted=1`,
  `store_has_record=1`, `ssid_set=1`, power-cycle `bridge_wifi_store_loads`,
  `bridge_wifi_store_has_record=1`, `wifi clear`, `store_has_record=0`, and password
  redaction review, with source-commit-pinned review matching.
  `tools/test_android_wifi_evidence_contract.ps1` covers complete Wi-Fi evidence, missing
  reload proof, robot-log password leakage, and stale Wi-Fi review commits. The
  `stackchan://pair` ticket intentionally carries only the bridge URL and pairing fields,
  not Wi-Fi credentials.
- G7 Play submission remains pending on upload-signing credentials, developer verification,
  verified deployment of the canonical privacy policy URL, screenshots, Play Console upload,
  and closed testing.
  Release tasks now fail closed when upload-key properties are absent; debug signing requires
  the explicit `stackchan.allowLabDebugReleaseSigning` Gradle property. The tag workflow consumes
  four `STACKCHAN_ANDROID_*` Actions secrets, builds both APK and AAB, and the release evidence
  gate requires the `upload-key` signing profile. The repository currently has no configured
  Actions secrets, so a public companion tag remains externally blocked until they are provisioned.
  Source-side Play prep now includes policy/data-safety declarations for
  `dev.stackchan.companion`, foreground-service `connectedDevice` justification,
  microphone/battery/network permission review, a dated Play-facing privacy policy derived
  from the core privacy boundary, the deployable `site/privacy/index.html` page, a Pages
  workflow, Android and desktop in-app links, and improved Play evidence packet templates.
  The Play
  evidence checker now requires a hosted HTTPS privacy-policy URL before marking internal
  testing evidence ready. The store asset packet now also defines a four-shot final-build
  screenshot plan covering pairing/setup, live dashboard, Brain/model controls, and
  persona/diagnostics support, and the Play evidence checker requires those screenshot IDs
  before marking internal-testing evidence ready. The checker also requires the packet to
  be explicitly marked `internal-testing-ready` with the Play Console release name, tester
  group, and UTC upload timestamp for the exact uploaded build. The Android v1 aggregate
  gate now rejects Play evidence whose uploaded `applicationId`, `versionName`, or
  `versionCode` does not match the target-phone APK install report. Those answers, hosted
  privacy URL deployment, release identity fields, and screenshots still must be verified
  against the exact uploaded build before submission.
- G8 Android field diagnostics export is partially closed. Android can now export
  `stackchan.android.diagnostics-export.v1` JSON from live bridge, robot, trust, saved-robot,
  and Gemma model state to `ANDROID_DIAGNOSTICS_EXPORT.json` and open the native share sheet.
  The export records installed package/version identity, the LiteRT-LM artifact path, bytes,
  loaded/downloaded flags, adapter runner status, success/failure intents needed for
  real-device Gemma sign-off, and the Wi-Fi provisioning command template with an explicit
  password-redacted flag. The export redacts the last text turn to a presence-only flag. The
  source tree now includes `tools/check_android_diagnostics_export_evidence.ps1` to validate
  the shared export, reject app identity drift against Gradle release config, and require the
  source-commit-pinned support-review packet. The diagnostics checker contract now rejects
  stale support-review commits. Gemma-specific runtime evidence is separated into
  `tools/check_android_gemma_evidence.ps1` so a staged model cannot be mistaken for a
  validated LiteRT run. Hardware-run capture, connected robot/session proof, Gemma loaded
  state, `android-gemma-real-device-ready`, and `Support decision: pass` review are still
  required before calling G8 complete.
- The Android screen-off bridge soak path is now source-gated. The existing soak helper
  samples the Android bridge during the strict 10-minute screen-off window, and
  `tools/check_android_screen_off_soak_evidence.ps1` validates the soak JSON, markdown
  summary, passing Android endpoint samples, zero failures, stable endpoint identity, and a
  source-commit-pinned human review packet before reporting `android-screen-off-soak-ready`.
  `tools/test_android_screen_off_soak_evidence_contract.ps1` covers complete soak evidence,
  short-duration rejection, unstable endpoint identity, and stale soak review commits.
- Android final-release evidence now has an aggregate source-side bundle gate:
  `tools/check_android_v1_evidence_bundle.ps1` consumes the target-phone APK install report,
  companion source readiness report, diagnostics, speech, controls, pairing, Wi-Fi, Gemma,
  screen-off soak, Play Store evidence-check JSON, connected-dashboard/hardware status, and
  a human `ANDROID_V1_REVIEW.md` before reporting `android-v1-evidence-ready`. The individual
  Android hardware evidence checkers now require a full reviewed source commit and the aggregate
  gate rejects any source readiness, hardware, target-phone APK install, or Play Store
  evidence report generated for a different source commit than the Android v1 bundle. It
  also rejects Play Store evidence whose uploaded package or version identity differs from
  the target-phone APK install report. It also requires explicit final-build dashboard media
  entries for the required phone screenshots, verifies those media files exist and match the
  bundle source commit, and requires a connected-dashboard human review decision before the
  Android bundle can pass. The Android v1 aggregate checker emits that same `sourceCommit`,
  plus the target-phone `applicationId`, `apkSha256`, `versionName`, `versionCode`, Play
  `releaseAabSha256`, Gemma benchmark summary, and dashboard media IDs, so the final
  Companion v1 gate can reject stale Android bundle evidence.
- Companion final-release evidence now has a top-level aggregate source-side bundle gate:
  `tools/check_companion_v1_evidence_bundle.ps1` consumes companion source readiness,
  companion release evidence, GitHub Actions status, rollout status, Android v1 bundle
  readiness, desktop v1 bundle readiness, production voice-source readiness, an attached
  release ZIP with a matching SHA-256, verified hardware evidence status, and a human
  `COMPANION_V1_REVIEW.md` before reporting `companion-v1-evidence-ready`. The gate also
  rejects mismatched commit or version evidence across source readiness, release, CI,
  rollout, Android v1, desktop v1, and production voice-source reports. It also rejects an
  Android app `versionName` that does not match the final release version, rejects an Android
  `applicationId` or `versionCode` that does not match the source Gradle release configuration,
  rejects stale Android v1 bundle reports that do not carry the required Gemma benchmark
  summary and dashboard media IDs,
  rejects an Android target-phone `apkSha256` that is not present as a release APK in
  companion release evidence,
  rejects an Android Play `releaseAabSha256` that is not present in companion release evidence,
  rejects desktop MSI/DMG/DEB hashes that are not present in companion release evidence,
  rejects release evidence that lacks hashed package core files from the extracted release
  package, and verifies that the rollout report's strict hardware evidence root and hardware
  metadata commit match the final bundle.
- C8 source-side release packaging is implemented. `release.yml` verifies that the tag matches
  every companion version source, builds upload-signed Android APK/AAB artifacts, creates managed
  Python payloads on native Windows/macOS/Linux runners, packages MSI/DMG/DEB artifacts, exports
  strict companion release evidence, and publishes stable artifact names with the firmware
  release. `tools/verify_published_release.ps1` now verifies those remote assets and evidence.
  A successful public tag run is still required before this can be called released. Automatic
  desktop updates and an Android in-app updater are not implemented; current distribution is
  manual GitHub Release installation, with Obtainium or Play as Android alternatives.
- G9 desktop Python runtime detection is partially closed. The desktop supervisor now probes
  the configured Python command before PC Brain Mode starts, requires Python 3.10+, reports
  missing interpreters or missing brain script in the Brain panel, and includes the
  command/version/script status in diagnostics and C6 rehearsal evidence. Desktop packaging now
  carries the required bridge Python modules as `brain/bridge/` app resources plus the bundled
  `spark` and `glow` persona packs, voice provenance YAML, and required source WAVs, extracts
  that repo-shaped subset for the supervisor, and searches `python-runtime` / `runtime/python`
  folders before falling back to system Python. The app now reports managed runtime payload
  presence in desktop diagnostics and C6 brain-supervisor evidence, and
  `tools/check_desktop_python_runtime_payload.ps1` validates the expected
  `stackchan-python-runtime.json` plus platform Python executable layout. Desktop packaging
  now accepts `-Pstackchan.desktop.pythonRuntimeRoot=<path>` or
  `STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT`, validates the payload before resource processing,
  and copies it into app resources as `python-runtime/`. The source tree now also includes
  `tools\prepare_desktop_python_runtime.ps1`, which can turn an installed Python 3.10+
  runtime into the expected payload folder, manifest, and deterministic payload hash before
  running the payload checker. The payload checker now rejects placeholder SHA-256 values,
  wrong-platform manifests, and stale manifest `pythonVersion` values, with
  `tools\test_desktop_python_runtime_payload_contract.ps1` covering those failure modes. It
  also emits the manifest platform, manifest/probed Python versions, runtime SHA-256, and
  runtime source into its JSON report.
  Each native tag leg now runs `tools\export_desktop_package_evidence.ps1` after packaging.
  That report records the MSI/DEB/DMG package SHA-256, recomputes the processed runtime SHA-256
  from Gradle resources, natively extracts the installer, and hashes `python-runtime/` directly
  from the packaged application JAR. It also proves the packaged runtime manifest, platform
  executable, and required bridge/provenance/voice resources. Strict companion release evidence
  requires exactly one ready Windows, Linux, and macOS report and matches every package hash,
  installer runtime hash, and payload summary. The published-release verifier repeats those
  package and installer-derived evidence checks before accepting the release.
  The source tree now also includes `tools\check_desktop_v1_evidence_bundle.ps1`, which
  aggregates the desktop package hashes, C6 supervisor/GUI evidence, Windows/macOS/Linux
  managed runtime payload checks, PC Brain deploy audio evidence, quiet-soak evidence,
  production voice-source readiness, and a human `DESKTOP_V1_REVIEW.md` before reporting
  `desktop-v1-evidence-ready`. The aggregate gate now rejects status-only or wrong-platform
  runtime payload reports by requiring Windows/macOS/Linux summaries with `platform`,
  `runtimeSha256`, `runtimeSource`, `pythonVersion`, and `probedPythonVersion`. The payload
  checker also rejects placeholder runtime sources before packaging. The review packet must record
  the same full source commit as `DESKTOP_V1_EVIDENCE_BUNDLE.json`, so a desktop human
  sign-off from a different build cannot close the aggregate gate. The companion
  source-readiness and production voice reports must also record that same source
  commit, so stale source or voice hash evidence cannot close the desktop bundle. The
  Desktop v1 aggregate checker emits that same `sourceCommit` so the final Companion v1 gate
  can reject stale desktop bundle evidence.
  Native CI jobs now prepare and embed the actual managed Python binary payload for each desktop
  platform. The Windows, Linux, and macOS package matrix passed installer-native extraction,
  packaged-runtime identity, managed-Python probing, required brain-resource checks, and exact
  package launch evidence. This closes the source/CI binary-payload gate. A tagged candidate must
  still produce its own hash-bound package reports, and the three exact tagged packages still need
  operator-workstation installation and human acceptance before the desktop aggregate gate can
  close.
- PC Brain live-deploy bring-up is now easier to exercise before the managed desktop runtime
  lands. Source/package tools can start the Python LAN bridge with an Ollama Character Lock
  runner and selected RVC voice sample TTS path, probe the WebSocket endpoint, flash/provision
  the Wi-Fi bridge target, and collect `stackchan.pc-brain-deploy-evidence.v1` from the robot
  debug endpoint. `tools\check_pc_brain_deploy_evidence.ps1` now requires a completed audio
  downlink and speaker playback path before reporting `pc-brain-deploy-ready`, so a
  connectivity-only robot session cannot accidentally close the lab deploy gate. The new
  `tools\run_pc_brain_quiet_soak.ps1` and `tools\check_pc_brain_quiet_soak_evidence.ps1`
  gate the post-deploy quiet window on a connected/ready bridge, stable robot debug samples,
  no parse/timeouts/playback errors, and no unexpected audio streams. The deploy and quiet-soak
  collectors now record the reviewed source commit, their checkers emit that `sourceCommit`,
  and the Desktop v1 aggregate gate rejects PC Brain lab evidence from a different commit.
  This is lab evidence for the current developer machine, not a substitute for the managed
  desktop Python runtime payload.
- The production DirectML RVC model and index are now published and hash-pinned. Companion
  evidence should report those hashes so a stale or substituted voice cannot be mistaken for
  the active Stackchan release voice.

## Next Attack Order

1. Provision the four `STACKCHAN_ANDROID_*` Actions secrets, back up the upload keystore, and
   run a prerelease tag to bind upload-signed APK/AAB plus native MSI/DEB/DMG managed-runtime
   evidence to the exact release tag.
2. Finish G1 with hardware push-to-talk/STT validation, then run `tools\check_android_speech_evidence.cmd -SourceCommit <git-commit> -RequireReady -Json`.
3. Finish G3 physical settings writes/manual brain handoff and G5 hardware pairing, then run the strict controls and pairing evidence checks.
4. Exercise G8 Android diagnostics, Gemma-4-E2B download/load/eject, the real `gemma4-e2b-litert-lm` benchmark, and one target-device LiteRT turn.
5. Finish G6 persistent robot Wi-Fi provisioning UX and hardware proof, then run `tools\check_android_wifi_evidence.cmd -SourceCommit <git-commit> -RequireReady -Json`.
6. Run the target-phone screen-off bridge soak and `tools\check_android_screen_off_soak_evidence.cmd -SourceCommit <git-commit> -RequireReady -Json`.
7. Assemble the Android v1 evidence bundle and run `tools\check_android_v1_evidence_bundle.cmd -RequireReady -Json`.
8. Exercise PC Brain Mode against the physical robot with `tools\start_pc_brain.cmd`, the deploy evidence collector, and the strict 600-second quiet soak.
9. Use the tag matrix's native managed-runtime reports to assemble the Desktop v1 evidence bundle and run `tools\check_desktop_v1_evidence_bundle.cmd -EvidenceRoot output\desktop-v1-evidence\latest -RequireReady -Json`.
10. Verify the prerelease with `tools\verify_published_release.cmd -Version <version>` and retain its exact-commit companion evidence.
11. Assemble the final Companion v1 evidence bundle and run `tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot output\companion-v1-evidence\latest -RequireReady -Json` before calling v1 release-ready.
