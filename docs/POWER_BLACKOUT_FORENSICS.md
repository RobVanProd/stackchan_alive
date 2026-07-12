# Stackchan Power Blackout Forensics

Status: corrected PMIC input-policy candidate installed; short no-motion and actuator gates pass;
one-hour actuator qualification active.

## What The Evidence Says

The intermittent shutdown is a release blocker, but the current evidence does not identify one
root cause.

- Real outages have occurred with motion enabled and disabled.
- Motion-enabled runs have also passed for 52 and 60 minutes, so servo load alone is not a
  sufficient explanation.
- Failure times do not cluster at one board uptime and do not match the ESP32 `micros()` wrap.
- The application does not call the M5Unified power-off, shutdown, or deep-sleep APIs.
- At least one first boot after a physical recovery reported ESP reset reason `poweron`. That
  distinguishes a full power-domain restart from an ordinary software restart, but it does not
  identify why the power domain went away.
- The corrected two-hour no-motion baseline passed despite three isolated four-second `/debug`
  timeouts with the bridge socket still established. A short HTTP timeout is therefore not, by
  itself, evidence that the robot shut down.
- On 2026-07-10 the accepted firmware was still live after about 8.3 hours with motion, servo
  rail, and torque off; the bridge was ready, VBUS was 5.025 V, no PMIC VBUS-loss or hard-floor
  event had occurred, and the face window was about 29.4 ms.
- On 2026-07-12 a strict integrated run stopped after one additional terminal IMU read miss
  (`1 -> 2`) among roughly 282,700 successful samples. The robot remained online with stable
  power, display, camera, bridge, and network telemetry. This is a separate peripheral-I/O
  hardening finding and is not evidence for or against the historical full-off events.
- A later live sample on 2026-07-10 observed one AXP2101 `battery_overvoltage` runtime IRQ. At
  23:29 EDT the same boot remained online at 11,081,507 ms uptime with reset reason `software`,
  bridge/network ready, motion/rail/torque off, VBUS 5.033 V, battery 4.099 V, and battery maximum
  4.198 V. This proves the IRQ occurred during the boot; it does not prove it caused a blackout,
  because the robot did not reset or go offline. The older v1 telemetry allowed a later
  `vbus_insert` to overwrite the protective event's snapshot, so its exact event-time load and
  voltage context is unavailable.
- On 2026-07-12 the exact `e6b80f32` release candidate ran 2,702 seconds with 529/529 successful
  polls before the strict runner stopped it for a confirmed 4.397 V board-reported VBUS floor.
  The PMIC still reported VBUS present, and there was no reset, bridge/network loss, display or
  thermal breach, PMIC VBUS-loss transition, or protective IRQ. VBUS, battery voltage, and the
  independent body-bus measurement fell together. The coordinator removed servo rail and torque,
  but the rails continued falling for about 35 seconds before the hard-floor event. Several
  minutes after verified motion stop, VBUS had recovered to 4.882-4.921 V and the configured
  700 mA charge current was restored. This is a sustained correlated sag signature; it does not
  identify whether the source, cable, base, board, battery path, or load interaction is the cause.

The correct statement is: there are confirmed historical full-off events plus separate transient
HTTP latency events. Neither the motors, the PC USB source, the wall source, heat, nor firmware
task starvation has enough evidence to be named the universal cause.

## Current Input-Policy Experiment

The AXP2101 datasheet defines VINDPM at register `0x15` in 80 mV steps from 3.88 V to
5.08 V. Its documented default is 4.36 V. When VBUS reaches VINDPM, the charger reduces charge
current before the battery supplements the system load. That default is below this project's
4.40 V hard evidence floor, so it can react too late for the strict release gate.

The current paired candidate sets and verifies VINDPM at 4.60 V while leaving the documented
1.5 A input-current limit unchanged. This is intentionally conservative: it changes when charging
yields, not the maximum current requested from the external source. It also records PMIC voltage
regulation, input-current limiting, battery direction/supplement, configuration readback, and VSYS
voltage in every strict soak poll and hard-floor snapshot.

This is a testable mitigation, not a root-cause claim. The strict wrapper refuses motion unless
the 4.60 V readback and VSYS telemetry are valid, and it stops on any new PMIC input-policy read
failure. Qualification order is no-motion, short actuator, 60-minute actuator, then eight-hour
actuator only after each prior gate passes.

The first private PMIC builds appeared to break the bridge, but the PMIC change was not the cause.
Those builds embedded the bridge host without a port and therefore inherited the obsolete firmware
default `8788`; the real bridge listens on `8765`. Archived ELF rodata proves the compiled port,
and the resulting five-second TCP timeouts are reproduced in the saved diagnostics. An otherwise
equivalent image that loaded the persisted NVS target connected on its first attempt. Source commit
`5e2b115a5e1154cdfab8ce4b705a4a2a97480511` aligns every default with `8765` and records the
configuration source and port in `/debug`. Do not use this resolved bridge-build defect as an
explanation for any historical full-off event.

The first corrected-port image, SHA256
`1649537EF829C8B5068A20D94383B453698EBB1C95BB2831E64745822684D216`, passed formal no-motion and
short actuator gates. Its one-hour continuation stopped after `154 s` because the old checker
treated an IMU `shaken` event as fatal even though preserved telemetry classifies it as
`self_motion=true`. No reset, power, bridge, display, camera, motion-session, or actuator-safety
failure accompanied that stop.

The installed superseding image, source commit `fd07b62a81460f9066f67bc6955f57f1e3b8971a` and
SHA256 `4F7B02616E8CC42C3066F732A4E899717129049AFE95051F996C600FB7E02BF2`, separates self-motion from
external IMU events and retains terminal read failures as strict faults. It passed a formal
180-second no-motion gate (`71/71`) and formal 300-second actuator gate (`70/70`); the actuator run
had `59/59` good and unsuppressed motion samples, VBUS floor `4973 mV`, maximum display frame
`29618 us`, and no terminal/external IMU, battery-supplement, hard-floor, PMIC protective/VBUS-loss,
reset, network, camera, or peripheral failure. Its exact-image one-hour continuation is active at
`output\pc-brain\imu-accounting-servo-60min-20260712-070606`. These results prove the policy and
event accounting over the short gates; they do not yet prove long-term stability or identify the
universal cause of prior shutdowns.

## Instrumented Candidate

Environment: `stackchan_release_forensics`

This extends the opt-in Voice V2 streaming build and is currently flashed for diagnosis. The
accepted rollback `stackchan_wake_mww_uplink_servos_m5_voiceout` remains unchanged and archived.

The candidate captures AXP2101 IRQ status immediately after `M5.begin()` and before the normal
runtime can clear it. It then clears the baseline, writes the selected IRQ-enable registers
directly, reads them back, and owns runtime IRQ polling. Direct register verification is used
because the bundled M5Unified 0.2.17 AXP2101 helper combines successful boolean writes and then
tests for zero, which reverses its reported result.

Runtime classification uses `raw_status & selected_enable_mask`. Disabled informational raw bits,
including routine fuel-gauge SOC updates, are still cleared but are tracked in separate ignored
counters. They cannot fail the strict PMIC-event gate.

Captured causes include:

- VBUS removal or insertion
- battery removal or insertion
- power-key long/short press and edges
- low-SOC warning levels
- battery and charging temperature faults
- battery overvoltage and charger timer expiry
- AXP2101 die overtemperature
- BATFET or LDO overcurrent
- fuel-gauge or PMIC watchdog expiry

Every runtime event snapshots VBUS, battery voltage, PMIC presence, chip/PMIC temperature, body
bus/current, heap, motion request, servo rail/torque, and speaker-power state. `/debug` exposes the
boot mask, decoded primary event, counters, read/clear failures, and last-event context.

The next candidate upgrades this to the `axp2101-v2` schema and independently retains the latest
general event, latest protective event, and latest battery-overvoltage event. A later insertion or
removal event can no longer overwrite the protective snapshot. Native regression coverage proves
the retained battery-overvoltage context survives a subsequent VBUS insertion.

Build verification:

- native logic: `198/198`
- unchanged production: 144,964 RAM bytes; 2,656,923 flash bytes
- forensics candidate: 157,364 RAM bytes; 2,674,911 flash bytes
- both embedded builds: pass
- direct flash: all four regions hash-verified by esptool
- restorable archive: `output\firmware-candidates\forensics-validated-20260710-204449.zip`
- archive SHA256: `48FF8AFB40906E4CD14E2A8373486FD81DE115656B46AA5A96A50657A0D203BD`
- candidate firmware SHA256: `32472084CABBFDA57A72B0A9B81D0709F3B3D37EF4410C20756DA6C45607AF24`
- bundled accepted rollback SHA256: `3C40D5A0F006B67D175ED963133E90F889AE600D5C1F0F419E06FE7B99786C10`

Physical qualification on the dedicated 5 V / 3 A BASE supply passed a 120-second motion-off run,
a 60-second servo run, and a six-minute servo/session-refresh run. The six-minute run recorded
71/71 successful polls, a 4.846 V floor, 59.5 C maximum chip temperature, 45.216 ms maximum face
frame, zero new hard-floor/PMIC/protective events, zero motion timeouts, and verified actuator
shutdown. The formal checker passed 42/42. This proves the instrumentation can coexist with the
current stack over a short supervised window; it does not establish the historical blackout cause.

Hardware references: [M5Stack CoreS3](https://docs.m5stack.com/en/core/CoreS3),
[M5Stack StackChan guide](https://docs.m5stack.com/en/guide/hobby_kit/stackchan), and
[M5Unified AXP2101 interface](https://github.com/m5stack/M5Unified/blob/0.2.17/src/utility/power/AXP2101_Class.hpp).

## Interpretation

Use the first post-return `/debug`, not a later sample.

| ESP reset reason | PMIC boot event | Supported conclusion |
| --- | --- | --- |
| `poweron` | `batfet_overcurrent` / `ldo_overcurrent` | PMIC protection directly observed; correlate the saved load context and power path. |
| `poweron` | `die_overtemperature` | PMIC thermal protection directly observed. |
| `poweron` | `pmic_watchdog_expire` | PMIC watchdog event directly observed. |
| `poweron` | `vbus_remove` | Input-source removal was latched; this supports a source/contact interruption but does not prove why it occurred. |
| `poweron` | `battery_remove` | Battery-presence interruption was latched. |
| `poweron` | `power_key_long_press` | A long power-key event was latched; inspect physical/button conditions before attributing a firmware fault. |
| `brownout`, `panic`, or watchdog | any | Use the ESP reason plus PMIC mask; do not relabel it as a generic power failure. |
| `poweron` | `none` | No selected PMIC event was retained. Root cause remains unknown; this is not proof that power was healthy. |
| no reboot, bridge socket present | none | Treat as service latency or task/network investigation, not a confirmed shutdown. |

The first boot after flashing is only a baseline because its status bits may predate the candidate.
The next untouched blackout and recovery is the evidentiary boot.

The actual first post-flash baseline contained an undated `batfet_overcurrent` bit. After clearing
the baseline and reflashing, the same flash procedure did not reproduce it. Treat that as a clue,
not as attribution to a specific blackout or proof that flashing caused the event.

## Physical Protocol

1. Connect USB for flashing, keep the body clear, and run:

   ```powershell
   .\tools\flash_device.ps1 -Environment stackchan_release_forensics -Port COM4 -ConfirmServoRisk
   ```

2. Confirm `/debug` reports `power_forensics_enabled=true`,
   `power_forensics_irq_enable_succeeded=true`, and
   `power_forensics_boot_status_valid=true`. Motion, servo rail, and torque must be off.
3. Move to the known 5 V / 3 A BASE supply. Record the resulting VBUS event as setup activity;
   the soak runner baselines counters after this transition.
4. Run a short motion-off validation first. Then run the supervised servo soak with
   `-RequirePowerForensics` in addition to the existing operator/body/risk gates.
5. If the robot goes fully off, do not unplug or swap the power cable. Start the listener:

   ```powershell
   .\tools\capture_first_post_return_power_forensics.ps1 `
     -EvidenceRoot output\pc-brain\power-forensics-next-blackout
   ```

6. Recover with the side button once. The listener saves the first `/debug` before any other
   command. If motion unexpectedly returns enabled, it calls `/motion-stop` and preserves both
   pre-stop and post-stop snapshots.

The strict runner stores the PMIC fields in every poll, aborts on a new runtime event or PMIC I/O
failure, and the formal checker accepts `-RequirePowerForensics`. Do not launch another blind
overnight soak without this candidate armed.
