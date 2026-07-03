# Hardware Simulation

`Stackchan: Alive` is a character OS for Stackchan hardware. Until the physical unit is on
the bench, the closest useful proxy is a deterministic virtual device that exercises the
same bridge protocol order the firmware consumes.

Run the no-hardware simulator from the repo root:

```powershell
.\tools\run_hardware_simulation.cmd
```

By default it writes:

- `output/hardware-sim/latest/hardware_simulation.json`
- `output/hardware-sim/latest/HARDWARE_SIMULATION.md`
- one serial-like log per scenario

The simulator currently checks:

- deterministic reference bridge frames from `bridge/reference_bridge.py`
- LAN text turn output from `bridge/lan_service.py`
- binary TTS audio downlink framing: `audio_stream_start`, binary chunks, `audio_stream_end`
- firmware-like bridge states, face mode handoff, speech-envelope frames, audio byte counts, and timeout handling

It intentionally does not claim display, speaker, microphone, camera, touch, IMU, servo, heat,
or power behavior. Those remain real hardware gates in `docs/PRODUCTION_READINESS.md` and the
arrival-day evidence packet.

To run only one scenario:

```powershell
.\tools\run_hardware_simulation.cmd -Scenario audio-downlink
```

To inspect a failure-mode scenario:

```powershell
python bridge/hardware_simulator.py --scenario timeout --json
```

The timeout scenario is expected to fail because it proves the virtual device reports the same
kind of bridge-timeout failure the firmware should surface instead of freezing.
