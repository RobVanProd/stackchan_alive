# Stackchan: Alive Android Companion Spec

Status: draft architecture contract for the Android companion app and the next bridge PRs.

Stackchan: Alive is a Character OS for Stackchan. The Android companion should make the
robot easier to run, not split it into a separate product. It is a bridge peer, a mobile
brain option, and a settings surface for the same local-first robot.

## Goals

- Support two brain paths without reflashing or editing firmware settings:
  - **PC Brain Mode**: a Mac, Windows, or Linux host runs `bridge/lan_service.py` plus local
    STT, model, TTS, RVC, and larger-context memory.
  - **Mobile Brain Mode**: the Android app acts as the bridge endpoint and runs or brokers
    the mobile STT/model/TTS stack, including the LiteRT-LM profile when available.
- Let the robot remember multiple trusted endpoints, then connect to whichever healthy
  endpoint is available.
- Allow seamless PC-to-mobile and mobile-to-PC handoff with one active brain owner at a time.
- Expose bot settings, persona selection, diagnostics, and voice audition controls from the
  app without bypassing firmware safety gates.
- Keep the creator path simple: persona work remains
  `copy personas/spark -> rename -> edit YAML -> validate -> build/run`.

## Non-Goals

- No cloud account requirement.
- No hosted LLM dependency.
- No firmware safety override from the app.
- No raw audio persistence by default.
- No consumer-ready claim until real hardware and production voice evidence are collected.

## Operating Modes

### PC Brain Mode

PC Brain Mode is the high-quality path.

- Endpoint kind: `pc`.
- Typical host: Mac Mini, desktop, or laptop on the same LAN.
- Runtime owner: Python bridge service.
- Expected strengths: larger context, faster local model options, RVC/TTS processing, easier
  development logs, richer storage for host-side memory.
- Current repo seam: `bridge/lan_service.py`, `bridge/local_runner.py`,
  `bridge/model_benchmark.py`, `bridge/character_red_team.py`.

The Android app should still be able to connect in this mode as a control/settings observer.
It can show the active PC endpoint, request status, edit safe settings, audition voice
profiles, and ask the robot to forget an endpoint.

### Mobile Brain Mode

Mobile Brain Mode is the portable path.

- Endpoint kind: `android`.
- Typical host: the Android companion app as a foreground service.
- Runtime owner: Android bridge service plus mobile STT/model/TTS adapters.
- Expected strengths: no PC required, lower active memory pressure, portable setup, direct
  phone microphone/speaker test harnesses when explicitly enabled.
- Current repo seam: LiteRT-LM contract in `bridge/litert_lm_stackchan_wrapper.py` and
  `docs/BRAIN_MODEL.md`.

The first Android implementation may use deterministic fake engines while it proves the
bridge connection, settings round trip, handoff, and LiteRT-LM wrapper contract. Real model
speed is not accepted until it passes the same Character Lock benchmark and red-team gates as
the PC path.

## Multi-Endpoint Model

The robot should maintain a small trusted endpoint registry in nonvolatile config:

```json
{
  "trusted_endpoints": [
    {
      "endpoint_id": "pc-studio-01",
      "endpoint_name": "Studio PC",
      "endpoint_kind": "pc",
      "public_key_fingerprint": "sha256:...",
      "priority": 80,
      "auto_connect": true,
      "capabilities": ["stt", "llm", "tts", "rvc", "settings", "audio_downlink"],
      "last_seen_ms": 1720000000000
    },
    {
      "endpoint_id": "phone-rob-01",
      "endpoint_name": "Rob's Phone",
      "endpoint_kind": "android",
      "public_key_fingerprint": "sha256:...",
      "priority": 60,
      "auto_connect": true,
      "capabilities": ["stt", "llm", "tts", "settings", "persona_select"],
      "last_seen_ms": 1720000000000
    }
  ]
}
```

The firmware does not need an unlimited device database. Eight trusted endpoints is enough
for a robot, a development machine, a phone, and a few test peers.

## Owner Semantics

Only one endpoint may own the conversational brain at a time. Other connected endpoints may
remain attached as observers for status, diagnostics, and allowed settings writes.

Terms:

- **active brain owner**: the endpoint allowed to receive wake-gated audio, run STT/model/TTS,
  stream dynamic audio, and write bridge memory through the validated Character Lock path.
- **observer**: a trusted endpoint allowed to read status and write safe settings, but not
  receive user audio or own the speech turn.
- **handoff**: a controlled change of active brain owner without changing firmware settings.

Default arbitration:

1. Explicit user selection wins.
2. Current healthy active brain owner stays active.
3. If the owner heartbeat expires, promote the highest-priority healthy endpoint.
4. If priorities tie, use most recently successful endpoint.
5. If no endpoint is healthy, degrade offline with packaged prompts and local commands.

Health is measured by heartbeat and by bridge turn completion. A brain owner that times out
or disconnects during a response must release any open audio stream, emit the existing
recoverable error path, and let offline fallback work.

## Discovery And Pairing

Recommended discovery layers:

- mDNS: advertise `_stackchan-bridge._tcp.local` for bridge endpoints and
  `_stackchan-device._tcp.local` for robots.
- UDP beacon fallback for networks where mDNS is unreliable.
- BLE provisioning as an optional first-run path for Wi-Fi credentials and endpoint bootstrap.
- Manual IP entry for bench and recovery.

Pairing should use a short code or QR code shown on the CoreS3 display or in the serial bench
log. Pairing creates a trust entry with `endpoint_id`, endpoint name, endpoint kind,
fingerprint, and capability set.

## Protocol Extension

Keep `stackchan.bridge.v1` as the protocol family. Extend the existing JSON control channel
instead of introducing a second transport.

The existing `hello` remains valid. New clients should include endpoint fields:

```json
{
  "type": "hello",
  "protocol": "stackchan.bridge.v1",
  "device_id": "stackchan-001",
  "device_name": "Stackchan Alive",
  "firmware_version": "dev",
  "sample_rate": 16000,
  "capabilities": ["wake_gate", "pcm16_upload", "pcm16_downlink", "settings"],
  "trusted_endpoint_count": 2,
  "active_brain_owner": "pc-studio-01"
}
```

Endpoint hello:

```json
{
  "type": "endpoint_hello",
  "protocol": "stackchan.bridge.v1",
  "endpoint_id": "phone-rob-01",
  "endpoint_name": "Rob's Phone",
  "endpoint_kind": "android",
  "app_version": "0.1.0",
  "priority": 60,
  "supports_binary_audio": true,
  "capabilities": [
    "stt",
    "llm",
    "tts",
    "settings",
    "persona_select",
    "model_profiles",
    "diagnostics"
  ]
}
```

Owner messages:

```json
{"type":"claim_brain","endpoint_id":"phone-rob-01","reason":"user_selected"}
{"type":"release_brain","endpoint_id":"phone-rob-01","reason":"handoff_to_pc"}
{"type":"owner_status","active_brain_owner":"phone-rob-01","owner_kind":"android","state":"healthy"}
```

Settings messages:

```json
{"type":"settings_get","domains":["persona","voice","motion","display","bridge","privacy"]}
{"type":"settings_snapshot","version":12,"settings":{"persona":{"active":"spark"}}}
{"type":"settings_set","version":12,"settings":{"display":{"reduced_motion":true}}}
{"type":"settings_result","ok":true,"version":13}
```

Endpoint registry messages:

```json
{"type":"trusted_endpoints"}
{"type":"trusted_endpoints_result","endpoints":[{"endpoint_id":"pc-studio-01","endpoint_kind":"pc"}]}
{"type":"forget_endpoint","endpoint_id":"phone-rob-01"}
{"type":"forget_endpoint_result","endpoint_id":"phone-rob-01","ok":true}
```

Diagnostics messages:

```json
{"type":"diagnostics_request","domains":["bridge","audio","model","firmware","battery"]}
{"type":"diagnostics_snapshot","bridge":{"state":"ready","timeouts":0},"audio":{"sample_rate":16000}}
{"type":"capability_update","endpoint_id":"phone-rob-01","capabilities":["settings","llm","tts"]}
```

The exact field casing should remain lower_snake_case to match the existing Python bridge and
firmware style.

## Settings Surface

The app should expose these domains through the same `settings_get` / `settings_set` path:

- Persona: active persona id, installed persona packs, persona validation status.
- Voice: active voice profile, TTS style, audition phrase, volume, review-only/provenance
  status.
- Display: brightness, reduced motion, preview/demo mode.
- Motion: servo enable state, calibration status, safe-stop state, center offsets. The app may
  request safe calibration workflows, but it must not bypass explicit servo arming.
- Bridge: preferred mode policy (`auto`, `pc_preferred`, `mobile_preferred`, `offline_only`),
  active owner, trusted endpoints, heartbeat status.
- Privacy: wake-gate status, memory reset, raw-audio retention policy, export logs toggle.
- Model: selected model profile, runner status, benchmark/red-team evidence paths.
- Diagnostics: bridge timeouts, audio stream counters, model latency, battery/power if
  available, firmware version, app version.

Foundation-locked settings:

- Wake-gated audio must stay enforced once a microphone exists.
- Servo movement must still require firmware-side arming and safety limits.
- Memory writes and forgets must still pass the Character Lock validator.
- Review-only RVC or voice assets must not be presented as production-approved.

## Android App Surfaces

Minimum screens:

- Devices: discovered robots and endpoints, active brain owner, connect/disconnect, forget
  device.
- Pairing: QR/short-code/manual IP flow, trust fingerprint confirmation.
- Brain: PC Brain Mode vs Mobile Brain Mode, active owner, model profile, runner status,
  handoff button.
- Persona: active persona pack, installed packs, validation result, creator instructions link.
- Voice: audition phrase, voice profile, volume, TTS/RVC status, provenance warning.
- Settings: display, motion-safe controls, bridge policy, privacy/memory reset.
- Diagnostics: logs, heartbeat state, audio stream counters, model latency, export evidence.

Android service boundaries:

- Foreground bridge service: maintains WebSocket connection and heartbeats when the phone is
  active brain owner.
- Engine adapters: STT, LiteRT-LM/model, TTS/RVC. These can start as interfaces backed by
  deterministic fakes.
- Repository/store: trusted robot list, trusted endpoint list, app settings, and capability
  cache.
- Protocol module: Kotlin data classes and JSON fixtures that mirror this document.

## Handoff Flows

PC to mobile:

1. Phone connects as observer.
2. Phone shows current active owner: `pc-studio-01`.
3. User taps "Use phone brain".
4. Phone sends `claim_brain`.
5. Robot sends `owner_status` with `phone-rob-01`.
6. PC receives owner change and stops sending brain-owned frames.
7. Next wake-gated turn goes to the phone.

Mobile to PC:

1. PC endpoint is discovered or already connected.
2. User selects "Use PC brain" or policy prefers PC when healthy.
3. Phone sends `release_brain` or robot promotes the PC after claim arbitration.
4. Robot emits `owner_status`.
5. Phone remains observer for settings and diagnostics.

Owner loss:

1. Heartbeat expires or connection closes.
2. Firmware aborts open binary audio stream if one exists.
3. Firmware emits the existing recoverable bridge error path.
4. Arbitration promotes another healthy trusted endpoint.
5. If none exists, packaged prompts and offline commands continue.

Forget device:

1. App sends `forget_endpoint` for an endpoint id.
2. Robot removes trust, disables auto-connect, and clears cached endpoint metadata.
3. If the forgotten endpoint is active brain owner, the owner is released first.
4. The endpoint cannot reconnect as trusted until paired again.

## Security And Privacy

- Local network first. No cloud relay by default.
- Pairing must establish endpoint trust before audio or settings writes are accepted.
- Prefer TLS, Noise-style session keys, or another authenticated local session once firmware
  resource budget is known.
- Raw wake-gated audio may be streamed only to the active brain owner.
- Raw audio is cleared after each turn by default.
- Memory remains host-side or endpoint-side and must be resettable from the app.
- App logs should redact transcripts by default; evidence export can include transcripts only
  when the user explicitly opts in.
- `forget_endpoint` must purge trust and cached metadata on both app and robot where possible.

## Mobile Architect Deliverables

The Android architect should produce:

- Kotlin protocol data classes for every message in this spec.
- A mock robot server and mock bridge endpoint for local tests.
- A foreground service that can hold an active WebSocket bridge session.
- Device discovery stubs for mDNS, UDP beacon fallback, manual IP, and optional BLE bootstrap.
- Settings repository and UI flows for `settings_get`, `settings_set`, and
  `forget_endpoint`.
- Handoff tests for PC-to-mobile, mobile-to-PC, owner timeout, and observer-only mode.
- A LiteRT-LM adapter seam that can run deterministic fake output first, then a real mobile
  model once installed.
- Exportable diagnostics JSON that can be attached to Stackchan release evidence later.

## Acceptance Gates

The Android companion path is ready to integrate with firmware when:

- PC Brain Mode and Mobile Brain Mode both pass a shared protocol smoke test.
- A simulated robot can hand off PC -> mobile -> PC without changing firmware settings.
- `forget_endpoint` prevents automatic reconnect until the endpoint is paired again.
- `settings_get` and `settings_set` round trip, including version conflict handling.
- Safety-locked settings cannot be changed from the app.
- Offline fallback still works with no active brain owner.
- Mobile model mode passes the same Character Lock red-team and benchmark gates as the PC
  model path before it is called a real brain candidate.

