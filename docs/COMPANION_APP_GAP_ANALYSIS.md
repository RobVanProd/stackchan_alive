# Companion App Gap Analysis

Current branch: `codex/companion-v1-cross-platform-bundle`

This document carries forward the product gap audit from commit
`42879b8e7ccdeb3358b7ea31f1f9c74dcdf21f70` and records what is still missing on the
current v1 companion branch.

## Current Status

- G1 conversation surface is partially closed. The shared app now has a Talk panel on
  Android and desktop. Text turns are sent through the active `CompanionEndpointServer`
  session as `app_text_turn` response frames (`thinking`, `response_start`,
  `audio_stream_start`, binary audio chunks, `audio_stream_end`, `response_end`).
- Android push-to-talk now requests `RECORD_AUDIO`, uses Android `SpeechRecognizer` for
  transcript capture when available, and submits the final transcript through the existing
  robot-gated text-turn path. Target-phone STT behavior, denial/retry UX, and physical robot
  transcript evidence still need to be captured before G1 is complete.
- G2 real Mobile Brain Mode is still open. The current text-turn and audio-turn path uses
  deterministic fake output, not Android STT, LiteRT-LM, or Android TTS. Android and desktop
  now expose a Gemma-4-E2B LiteRT-LM model asset panel with working download/cache,
  load/eject, and settings entry points. The app now targets the LiteRT Community
  `gemma-4-E2B-it.litertlm` artifact and rejects partial/wrong-size files before Load.
  The remaining G2 gap is real-device download proof, LiteRT runtime inference wiring,
  benchmark evidence, and robot audio/TTS validation.
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
  `owner_status` responses update app state. Physical robot round-trip evidence is still
  required before G3 is complete.
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
  the normalized six-character code matches. Full QR flow, firmware UI entry, and hardware
  proof still remain blocking before public distribution.
- G6 first-run Wi-Fi provisioning is partially closed on the app side. The Android Nodes
  setup flow now starts with a Wi-Fi bootstrap step, reports whether the phone is currently
  on Wi-Fi, opens native Wi-Fi settings, and explains that firmware still needs Wi-Fi
  credentials or its pairing menu before it can reach the phone bridge URL. Robot-side
  credential entry/provisioning transport and hardware proof remain open.
- G7 Play submission remains pending on upload signing, developer verification, privacy
  policy URL, data-safety answers, foreground-service declaration evidence, screenshots,
  and closed testing.
- G8 Android field diagnostics export is partially closed. Android can now export
  `stackchan.android.diagnostics-export.v1` JSON from live bridge, robot, and trust state
  to `ANDROID_DIAGNOSTICS_EXPORT.json` and open the native share sheet. The export redacts
  the last text turn to a presence-only flag. Hardware-run capture and support review are
  still required before calling G8 complete.
- G9 desktop Python runtime detection is partially closed. The desktop supervisor now probes
  the configured Python command before PC Brain Mode starts, requires Python 3.10+, reports
  missing interpreters or missing `bridge/lan_service.py` in the Brain panel, and includes the
  command/version/script status in diagnostics and C6 rehearsal evidence. Packaging a managed
  Python runtime with desktop installers remains open.

## Next Attack Order

1. Finish G1 with hardware push-to-talk/STT validation and transcript evidence.
2. Finish G3 with protected robot settings writes and manual brain handoff on physical hardware.
3. Finish G5 with QR/short-code robot UI entry and real hardware pairing evidence.
4. Exercise G8 Android diagnostics export on hardware and attach support-reviewed evidence.
5. Validate Gemma-4-E2B model download/load/eject plus persona import/export on target devices.
6. Finish G6 with robot-side Wi-Fi credential entry/provisioning transport and hardware proof.
