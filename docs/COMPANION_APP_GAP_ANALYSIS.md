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
- G4 decorative controls are improved but not fully closed. Unsupported controls are
  disabled, and the remaining fake telemetry must continue to be labeled or replaced.
- G5 pairing enforcement is still open and remains blocking before public distribution.
- G6 first-run Wi-Fi provisioning is still open. Current setup assumes the robot can
  already reach the phone or desktop bridge.
- G7 Play submission remains pending on upload signing, developer verification, privacy
  policy URL, data-safety answers, foreground-service declaration evidence, screenshots,
  and closed testing.
- G8 Android field diagnostics export remains open.
- G9 desktop Python runtime packaging/detection remains open.

## Next Attack Order

1. Finish G1 with push-to-talk capture and transcript handling.
2. Add G3 user-facing settings, diagnostics, and persona screens over the existing protocol.
3. Enforce G5 pairing before any public Play distribution.
4. Add G8 Android diagnostics export so closed testers can share local evidence.
5. Coordinate G6 runtime Wi-Fi provisioning with firmware.
