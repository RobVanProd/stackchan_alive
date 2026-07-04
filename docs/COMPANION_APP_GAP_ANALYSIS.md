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
  deterministic fake output, not Android STT, LiteRT-LM, or Android TTS.
- G3 settings, diagnostics, persona selection, and manual brain handoff UI are partially
  closed. Android and desktop now expose user-facing settings, diagnostics, persona, and
  handoff status panels from the settings repository, diagnostics snapshot, and live bridge
  state. Writes, persona switching, and manual brain claim/release remain locked until
  robot round-trip evidence exists.
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
  mode, and saved-robot add/remove state after a robot `hello`. Full QR/short-code
  robot-side trust establishment and hardware proof still remain blocking before public
  distribution.
- G6 first-run Wi-Fi provisioning is still open. Current setup assumes the robot can
  already reach the phone or desktop bridge.
- G7 Play submission remains pending on upload signing, developer verification, privacy
  policy URL, data-safety answers, foreground-service declaration evidence, screenshots,
  and closed testing.
- G8 Android field diagnostics export is partially closed. Android can now export
  `stackchan.android.diagnostics-export.v1` JSON from live bridge, robot, and trust state
  to `ANDROID_DIAGNOSTICS_EXPORT.json` and open the native share sheet. The export redacts
  the last text turn to a presence-only flag. Hardware-run capture and support review are
  still required before calling G8 complete.
- G9 desktop Python runtime packaging/detection remains open.

## Next Attack Order

1. Finish G1 with hardware push-to-talk/STT validation and transcript evidence.
2. Finish G3 with settings writes, persona switching, and manual brain handoff round-trip evidence.
3. Finish G5 with QR/short-code robot-side trust establishment and real hardware pairing evidence.
4. Exercise G8 Android diagnostics export on hardware and attach support-reviewed evidence.
5. Coordinate G6 runtime Wi-Fi provisioning with firmware.
