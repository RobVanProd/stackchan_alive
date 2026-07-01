# Stackchan

Procedural character runtime for Stack-chan on ESP32-S3/CoreS3-class hardware.

The initial design source is in [docs/stackchan_procedural_runtime_design.pdf](docs/stackchan_procedural_runtime_design.pdf).

## Shape

- `persona/`: emotion, intent, and frame snapshots.
- `motion/`: springs, blink/saccade timing, actuator ownership, and safety limits.
- `face/`: expression-to-geometry mapping and display rendering boundary.
- `io/`: board, servo, display, and sensor adapters.

Only the motion task writes servos. Higher-level code publishes `RobotFrame` snapshots through a single-slot FreeRTOS queue.

## Build

This project is set up for PlatformIO:

```powershell
pio run
```

PlatformIO is not installed in this environment yet.
