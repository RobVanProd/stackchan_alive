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
- binary TTS audio downlink framing: `audio_stream_start`, binary chunks, `audio_stream_end`,
  including byte/chunk accounting before firmware speaker playback is wired
- firmware-like bridge states, face mode handoff, speech-envelope frames, audio byte counts, and timeout handling
- a virtual CoreS3 shell: boot/display readiness, 30 fps display ticks, persistent label
  drawing, CoreS3 tap/hold/BtnA/BtnB/BtnC input mapping, motion safety toggles, speaker
  stream submission counters, mouth-display activity during speech, and a power-cycle
  recovery rehearsal

The default run includes `reference`, `lan-text`, `audio-downlink`, and `arrival-rehearsal`.
The `arrival-rehearsal` scenario is the best no-hardware proxy before the unit arrives: it
pushes virtual button/touch events, shakes/puts down the robot through the safety path,
streams a tiny synthetic TTS payload, verifies mouth/display activity, then power-cycles and
expects the virtual bridge to return to `Ready`.

It intentionally does not claim real LCD, speaker, microphone, camera, capacitive touch, IMU,
servo, heat, battery, USB power, Wi-Fi, or soak behavior. Those remain real hardware gates in
`docs/PRODUCTION_READINESS.md` and the arrival-day evidence packet.

To run only one scenario:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario audio-downlink
```

To run the pre-arrival device-shell rehearsal:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario arrival-rehearsal -Json
```

To inspect a failure-mode scenario:

```powershell
python bridge/hardware_simulator.py --scenario timeout --json
```

The timeout scenario is expected to fail because it proves the virtual device reports the same
kind of bridge-timeout failure the firmware should surface instead of freezing.
