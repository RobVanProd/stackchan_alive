# LTR-553 Proximity Calibration

The post-release firmware contains a telemetry-first LTR-553 proximity and ambient-light adapter.
Presence behavior remains disabled while both thresholds are zero. Do not choose thresholds by eye
from one reading and do not advertise visitor detection until the exact robot produces separated,
repeatable far/near evidence.

This procedure is passive. It does not enable motion, modify firmware, or write configuration.

## Capture Far

Leave the intended detection area empty and keep lighting representative of the desk location:

```powershell
python bridge\ltr553_calibration.py capture `
  --label far `
  --duration-seconds 30 `
  --output output\ltr553\far.json
```

The tool polls `/debug`, accepts only ready, unsaturated, in-range samples with no active read
failure, and records rejection reasons. Move neither Stackchan nor reflective objects during one
capture.

## Capture Near

Place a person or representative target at the intended trigger position. Keep the pose stable for
the first capture, then repeat at the edges of the desired detection area rather than selecting the
single strongest reading:

```powershell
python bridge\ltr553_calibration.py capture `
  --label near `
  --duration-seconds 30 `
  --output output\ltr553\near.json
```

The LTR-553 is a proximity sensor, not a camera or identity sensor. If it does not separate the
intended visitor distance from the empty desk, preserve that observed limitation and leave the
feature disabled.

## Analyze

```powershell
python bridge\ltr553_calibration.py analyze `
  --far output\ltr553\far.json `
  --near output\ltr553\near.json `
  --output output\ltr553\calibration.json
```

A ready report requires at least 30 accepted samples per label, no read-failure growth, no
saturation among accepted samples, and a robust near p10 minus far p90 margin of at least 16 raw
counts. The suggested exit threshold is one-third into that robust gap and the enter threshold is
two-thirds into it, so `enter > exit` and ordinary edge noise does not chatter presence state.

The report emits suggested `STACKCHAN_LTR553_NEAR_ENTER_THRESHOLD` and
`STACKCHAN_LTR553_NEAR_EXIT_THRESHOLD` build defines. It deliberately sets
`automatic_firmware_change: false`. Review captures from multiple lighting/target conditions before
placing values in a candidate environment.

## Qualification

After selecting thresholds:

1. Build and archive the exact candidate; do not transfer evidence from another SHA-256.
2. Run a no-motion approach/departure test and verify two-sample entry, four-sample exit, no
   chattering, and immediate face recovery when the sensor is absent or not ready.
3. Run the 30-minute passive all-system soak from the hardware roadmap.
4. Only then connect the bounded `UserNear` event to visitor-notice choreography. It never grants
   identity, memory, camera, tool, power, or actuator authority.
