# Hardware Simulation

`Stackchan: Alive` is a character OS for Stackchan hardware. Until the physical unit is on
the bench, the closest useful proxy is a deterministic virtual device that exercises the
same bridge protocol order the firmware consumes plus a small CoreS3 device shell.

Run the no-hardware simulator from the repo root:

```powershell
.\tools\run_hardware_simulation.cmd
```

By default it writes:

- `output/hardware-sim/latest/hardware_simulation.json`
- `output/hardware-sim/latest/HARDWARE_SIMULATION.md`
- one serial-like log per scenario

GitHub Actions also runs the bridge test suite and this simulator on every PR/push through
the `bridge-tests` job, then uploads `output/hardware-sim/latest/` as the
`hardware-simulation` artifact.

The simulator currently checks:

- deterministic reference bridge frames from `bridge/reference_bridge.py`
- LAN text turn output from `bridge/lan_service.py`
- a full no-hardware conversation rehearsal: virtual wake input, utterance-end marker,
  LAN bridge response, visible thinking, mouth/lip-sync frames, latency budget, and return to
  `Ready`
- binary TTS audio downlink framing: `audio_stream_start`, binary chunks, `audio_stream_end`,
  including 4096-byte chunk-limit enforcement and byte/chunk accounting
- firmware-mirrored `bridge_downlink_*` counters for the audio downlink consumer, written to
  JSON and to the serial-like `[runtime]` line so simulator output can be compared directly
  with arrival-day firmware serial logs
- firmware-mirrored `bridge_downlink_playback_*` counters for decoded PCM16 streams, proving
  the virtual speaker handoff separately from the transport counters
- firmware-like bridge states, face mode handoff, speech-envelope frames, audio byte counts,
  recoverable bridge-error handling, and timeout handling
- an offline command fallback: no bridge session, CoreS3 wake input, P4-style commands,
  packaged prompt requests, mouth/display activity, and no bridge dependency
- a virtual CoreS3 shell: boot/display readiness, 30 fps display ticks, persistent label
  drawing, CoreS3 tap/hold/BtnA/BtnB/BtnC input mapping, motion safety toggles, speaker
  stream submission counters, mouth-display activity during speech, and a power-cycle
  recovery rehearsal

The default run includes `reference`, `lan-text`, `conversation-rehearsal`, `audio-downlink`,
`audio-downlink-unsupported`, `arrival-rehearsal`, `bridge-kill-recovery`, and
`offline-command-fallback`.
The `conversation-rehearsal` scenario is the no-hardware P7 demo proxy: a virtual wake input
starts a turn, the simulator marks utterance end, the LAN bridge emits `listening`,
`thinking`, `response_start`, `audio`, and `response_end`, and the virtual device checks that
first audio arrives within the 2.5 s LAN budget before returning to `Ready`.
The `arrival-rehearsal` scenario is the best no-hardware proxy before the unit arrives: it
pushes virtual button/touch events, shakes/puts down the robot through the safety path,
streams a synthetic decoded PCM16 5000-byte TTS payload as 4096-byte and 904-byte downlink
chunks, verifies `bridge_downlink_streams`, `bridge_downlink_completed`,
`bridge_downlink_chunks`, `bridge_downlink_bytes`, `bridge_downlink_playback_starts`,
`bridge_downlink_playback_chunks`, `bridge_downlink_playback_bytes`, mouth/display activity,
then power-cycles and expects the virtual bridge to return to `Ready`.

The `bridge-kill-recovery` scenario simulates a LAN bridge dropping mid-response while a
binary TTS stream is open. The virtual device must abort that stream, emit one offline
fallback prompt, accept a new `hello`, speak a recovery turn, and end back in `Ready` with no
parse errors or timeout. Native firmware tests also assert that bridge `error` and timeout
paths clear open stream state before the next session.

The `offline-command-fallback` scenario keeps the bridge disconnected and verifies that local
button/command-map behavior can still request packaged speech, animate the mouth/display, and
return to idle without any LAN session.

It intentionally does not claim real LCD, speaker, microphone, camera, capacitive touch, IMU,
servo, heat, battery, USB power, Wi-Fi, or soak behavior. Those remain real hardware gates in
`docs/PRODUCTION_READINESS.md` and the arrival-day evidence packet.

To run only one scenario:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario audio-downlink
```

To verify unsupported container formats still transport but do not claim speaker playback:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario audio-downlink-unsupported -Json
```

To run the pre-arrival device-shell rehearsal:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario arrival-rehearsal -Json
```

To run the conversation rehearsal:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario conversation-rehearsal -Json
```

To run the bridge-kill recovery rehearsal:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario bridge-kill-recovery -Json
```

To run the offline command fallback rehearsal:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario offline-command-fallback -Json
```

To inspect a failure-mode scenario:

```powershell
python bridge/hardware_simulator.py --scenario timeout --json
```

The timeout scenario is expected to fail because it proves the virtual device reports the same
kind of bridge-timeout failure the firmware should surface instead of freezing.
