# Stackchan Privacy Model

This document defines the privacy boundary for the P7 bridge work. It separates what exists now from the future LAN bridge path so the firmware, release package, and hardware evidence all point at the same rules.

## Current State

- The firmware is a real-time character runtime. It owns display animation, local modes, motion status, servo safety, packaged prompts, and bridge telemetry.
- The current P7 reference bridge and LAN service are deterministic and local. The LAN service can accept wake-gated binary PCM frames for bridge-loop testing, but it does not call a cloud speech service, call an LLM, or persist raw audio.
- Packaged prompt playback and the current voice audition assets are local repository artifacts. Review-only RVC audition samples remain governed by `docs/VOICE_PERSONALITY.md` and the voice-source provenance gates before any consumer distribution.
- There are no hardcoded secrets in the firmware or reference bridge. Any future bridge credential belongs in host configuration outside the firmware image and outside release artifacts.

## Audio Boundary

Audio leaves the device only after wake-word gated activation and only through the configured bridge transport. Until that gate is passed, microphone input is local-processing by default and should be used only for wake, reflex, or status decisions.

The intended production flow is:

1. Local wake-word or explicit user action opens a short conversation window.
2. The device sends audio or envelope data to the bridge over a local/LAN-first connection.
3. The bridge performs STT, LLM, TTS, and any memory lookup.
4. The device receives `stackchan.bridge.v1` response events and returns to local-only behavior after the response ends or times out.

The current LAN service implements only the beginning of that flow: bounded PCM upload after
`utterance_start`, upload telemetry, explicit placeholder transcripts on `utterance_end`, and
raw-audio clearing at the end of the turn. Audio-only turns return `stt_not_implemented`
until a real STT adapter lands.

If Wi-Fi or the bridge is unavailable, Stackchan must degrade offline. On-device commands, local expressions, safety behavior, and packaged prompts still work. A missing bridge must not create a dead state.

## Camera And Microphone Producers

Camera and microphone producers are local-processing by default. They may feed local reflexes, presence signals, status checks, or bridge state, but raw camera or microphone streams must not be sent to a remote service by firmware code.

If a future bridge feature needs remote analysis, it must be implemented as an explicit host-side bridge feature with user configuration, release documentation, and evidence showing when data leaves the device.

## Bridge Ownership

The bridge owns host-side STT, LLM, TTS, memory, and persona composition. The firmware owns modes, animation, motion, safety, timeout recovery, and serial-visible telemetry.

The minimum bridge memory scaffold is intentionally small:

- `preferred_name`
- `recent_topics`
- `physical_context`
- `turns_seen`

The current scaffold does not perform biometric identification and does not persist private audio. The reference bridge can persist only the minimal fields above to a local JSON file when `--memory-file --save-memory` is explicitly used, and `--reset-memory` deletes that store before rendering. The LAN service may keep raw PCM in an in-memory bounded buffer only during one active utterance; that buffer is cleared at `utterance_end` or `cancel`.

## Evidence Requirements

Release and hardware evidence should prove the privacy boundary, not just describe it. Useful evidence includes:

- Wake-word gated activation before bridge audio handoff.
- Offline behavior when bridge or Wi-Fi is disabled.
- No hardcoded secrets in firmware, bridge source, or packaged release artifacts.
- Serial counters for `bridge_messages`, `bridge_outputs`, `bridge_parse_errors`, and `bridge_timeouts`.
- Timeout recovery that clears `bridge_active` and returns the face to local behavior.
- Voice-source status showing RVC review assets and production voice gates are still separated.

## User Controls

The user must be able to run Stackchan without the bridge, disable Wi-Fi, clear bridge memory, and use packaged local prompts. A consumer-ready bridge must also document where host-side logs, temporary audio, generated TTS, and memory files are stored.

