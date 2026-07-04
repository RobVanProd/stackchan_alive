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
- Push-to-talk remains intentionally disabled until microphone capture, permission copy,
  and STT handling are implemented and tested.
- G2 real Mobile Brain Mode is still open. The current text-turn and audio-turn path uses
  deterministic fake output, not Android STT, LiteRT-LM, or Android TTS.
- G3 settings, diagnostics, persona selection, and manual brain handoff UI remain open.
  Android now has a first field diagnostics export/share path, but full user-facing
  diagnostics screens are not complete.
- G4 decorative controls are improved but not fully closed. Unsupported controls are
  disabled, and the remaining fake telemetry must continue to be labeled or replaced.
- G5 pairing enforcement is partially closed. Android and desktop no longer treat a raw
  WebSocket connection as a connected robot session: app text turns, audio writes, settings
  writes, Talk enablement, wake-lock promotion, and setup-complete UI now require the robot
  `hello` handshake first. Android also exposes the intermediate "robot socket detected,
  waiting for hello" state in setup, notification detail, and diagnostics export. Full
  QR/short-code trust establishment and hardware proof still remain blocking before public
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

1. Finish G1 with push-to-talk capture and transcript handling.
2. Add G3 user-facing settings, diagnostics, and persona screens over the existing protocol.
3. Finish G5 with QR/short-code trust establishment and real hardware pairing evidence.
4. Exercise G8 Android diagnostics export on hardware and attach support-reviewed evidence.
5. Coordinate G6 runtime Wi-Fi provisioning with firmware.
