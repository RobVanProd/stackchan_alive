# Stackchan Privacy Model

This document defines the privacy boundary for the P7 bridge work. It separates what exists now from the future LAN bridge path so the firmware, release package, and hardware evidence all point at the same rules.

## Current State

- The firmware is a real-time character runtime. It owns display animation, local modes, motion status, servo safety, packaged prompts, and bridge telemetry.
- The current P7 reference bridge and LAN service are deterministic and local by default. The LAN service can accept wake-gated binary PCM frames for bridge-loop testing, pass one-turn raw PCM to an operator-configured local STT command, pass response text to an operator-configured local TTS command for mouth timing, and downlink optional TTS audio bytes over the same LAN WebSocket session. It does not call a cloud speech service, call an LLM, or persist raw audio.
- The production RVC model and index are public release assets. Raw microphone recordings and
  generated conversation audio remain local and are not committed.
- There are no hardcoded secrets in the firmware or reference bridge. Any future bridge credential belongs in host configuration outside the firmware image and outside release artifacts.

## Audio Boundary

Audio leaves the device only after wake-word gated activation and only through the configured bridge transport. Until that gate is passed, microphone input is local-processing by default and should be used only for wake, reflex, or status decisions.

The intended production flow is:

1. Local wake-word or explicit user action opens a short conversation window.
2. The device sends audio or envelope data to the bridge over a local/LAN-first connection.
3. The bridge performs STT, LLM, TTS, and any memory lookup.
4. The device receives `stackchan.bridge.v1` response events and returns to local-only behavior after the response ends or times out.

The current LAN service implements the beginning of that flow: bounded PCM upload after
`utterance_start`, upload telemetry, an optional local STT command adapter, an optional local
TTS metadata adapter for mouth timing, optional binary TTS audio downlink, explicit transcript
fields on `utterance_end` for deterministic tests, and raw-audio clearing at the end of the
turn. Audio-only turns return `stt_not_implemented` unless an STT command is configured.
Firmware mic capture remains compiled off by default. When it is explicitly enabled, captured
PCM windows may feed the bridge uplink only while a turn is already active. `BridgeWakeGate`
owns the firmware-side activation window: wake events can open/renew a short upload turn, but
ordinary microphone reflexes do not open that turn by themselves.

If Wi-Fi or the bridge is unavailable, Stackchan must degrade offline. On-device commands, local expressions, safety behavior, and packaged prompts still work. A missing bridge must not create a dead state.

## Camera And Microphone Producers

Camera and microphone producers are local-processing by default. They may feed local reflexes, presence signals, status checks, or bridge state, but raw camera or microphone streams must not be sent to a remote service by firmware code.

The isolated camera diagnostic is a documented host-side exception within the same local
trust boundary. It serves one 160x120 grayscale frame at a time only to a paired private-LAN
client, the worker keeps the frame in memory for one OpenCV detection step, and it returns at
most four normalized face boxes. It does not store frames, forward them to the LLM or a cloud
service, or perform identity recognition. The endpoints are compiled out of production
firmware. See `LOCAL_VISION.md`.

If a future bridge feature needs remote analysis, it must be implemented as an explicit host-side bridge feature with user configuration, release documentation, and evidence showing when data leaves the device.

## Bridge Ownership

The bridge owns host-side STT, LLM, TTS, memory, and persona composition. The firmware owns modes, animation, motion, safety, timeout recovery, and serial-visible telemetry.

The bridge memory store is one bounded, atomically replaced local JSON file. Schema v4 contains:

- `preferred_name`
- `recent_topics`
- `physical_context`
- `turns_seen`
- approved durable facts and expiring recent context
- up to 30 sanitized session episodes
- up to 6 sanitized one-shot open loops
- aggregate rejection, distillation-drop, and durable-eviction counters

Every episode and open loop passes the existing denylist at creation, load, and prompt assembly.
Medical/health and relationship callbacks are impossible by design; there is no exception. Web
evidence never creates episodes or loops. Conversation lease turns remain in memory only and are
erased at close. The default session-close episode is derived from eligible topic labels and a
turn count, not raw dialogue.

Optional episode distillation is default-off because it changes that lease-erasure boundary. When
the owner explicitly enables it, at most four local lease turns are sent to the configured local
Ollama model after session close; the transport rejects non-loopback endpoints, and only a strict,
fully sanitized summary may persist. Any invalid field drops the whole result. No distillation data
is sent to a cloud service by this feature.

The bridge does not perform biometric identification or persist private audio. The LAN service may
keep raw PCM in a bounded buffer only during one active utterance; it clears that buffer at
`utterance_end` or `cancel`. STT receives that turn on stdin. TTS receives response text and may
return timing plus local audio bytes. Operators should avoid transcript/audio logging except for
explicit evidence collection. Generated audio remains session-local unless evidence collection is
enabled.

## Evidence Requirements

Release and hardware evidence should prove the privacy boundary, not just describe it. Useful evidence includes:

- Wake-word gated activation before bridge audio handoff.
- Offline behavior when bridge or Wi-Fi is disabled.
- No hardcoded secrets in firmware, bridge source, or packaged release artifacts.
- Serial counters for `bridge_messages`, `bridge_outputs`, `bridge_parse_errors`, `bridge_audio_streams`, `bridge_audio_stream_bytes`, `bridge_audio_stream_bytes_received`, `bridge_audio_stream_chunks`, `bridge_audio_stream_errors`, `bridge_uplink_enabled`, `bridge_uplink_active`, `bridge_uplink_gate_blocks`, `bridge_uplink_queue_failures`, `bridge_wake_gate_open`, `bridge_wake_gate_turn_active`, `bridge_wake_gate_opens`, `bridge_wake_gate_completed`, `bridge_downlink_streams`, `bridge_downlink_chunks`, `bridge_downlink_bytes`, `bridge_downlink_errors`, `bridge_downlink_playback_starts`, `bridge_downlink_playback_chunks`, `bridge_downlink_playback_bytes`, `bridge_downlink_playback_unsupported`, `bridge_downlink_playback_errors`, and `bridge_timeouts`.
- Timeout recovery that clears `bridge_active` and returns the face to local behavior.
- Voice-source status showing the exact public production RVC hashes while raw microphone recordings and generated conversation audio remain local.
- Camera evidence showing paired requests, zero authentication failures, no frame persistence,
  bounded face-box output, and camera/host-vision endpoints absent from the production image.

## User Controls

The user must be able to run Stackchan without the bridge, disable Wi-Fi, clear bridge memory, and use packaged local prompts. A consumer-ready bridge must also document where host-side logs, temporary audio, generated TTS, and memory files are stored.

