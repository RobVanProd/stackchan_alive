# Stackchan: Alive - A Character OS for Stackchan

Stackchan: Alive is a character OS for a Stackchan-style tabletop robot on M5Stack CoreS3 /
ESP32-S3-class hardware. The goal is a small robot that feels awake: it blinks, breathes,
looks around, reacts to events, speaks with synchronized mouth motion, and eventually holds
short in-character conversations through a local companion bridge.

The face, motion, speech cues, and bridge protocol are all generated procedurally. There are
no face sprite sheets or character-image assets in the runtime.

![Stackchan: Alive preview](docs/media/stackchan_alive_preview.png)

![Stackchan: Alive system overview](docs/media/diagrams/01-system-overview.png)

## Project Status

Status as of July 12, 2026: **integrated physical release candidate under exact-image
acceptance; not yet consumer-ready**.

What is working in the repository now:

- Smooth procedural face runtime with authored expressions, blink, saccade, breathing, gaze life,
  speech-reactive mouth motion, and a strict display-frame gate.
- On-device wake phrase, microphone capture, wake/listen cues, local Wi-Fi bridge, Whisper STT,
  Gemma 4 Character Lock, accelerated DirectML RVC voice, chunked speaker transport, and complete
  mouth-synchronized replies.
- Power-coordinated servo motion, ambient character movement, bounded camera following, and
  seed-varied procedural nod/shake gestures for unambiguous yes/no replies.
- Paired local camera capture and YuNet face detection plus instrumented body RGB, touch, IMU,
  battery, PMIC, thermal, display, audio, network, and actuator state.
- Confirmed OTA updates with candidate health confirmation and automatic rollback.
- Versioned, bounded, privacy-filtered host memory with atomic persistence, relevant fact recall,
  explicit forgetting, and deterministic local time/date/time-zone/name answers that do not rely
  on Gemma choosing a tool.
- Real-model benchmark and red-team gates, Spark and Glow persona packs, face/persona creator
  guides, native and host tests, exact-binary soak evidence, private recovery archives, and
  secret-free public packaging checks.
- PC and Android companion contracts for local brain ownership, endpoint handoff, settings, and
  trusted-endpoint removal. Continuous two-way conversation remains an explicitly post-release
  v2 feature.

What is still gated:

- The exact paired candidate passed its formal one-hour actuator acceptance. Its interaction-aware
  eight-hour all-feature actuator soak is active; it must finish and pass the formal checker before
  that long-duration gate is claimed. Evidence from another firmware SHA-256 cannot substitute.
- The secret-free public build and BYOM release package have passed independent verification. A
  final package is regenerated after the terminal documentation commit. Private paired firmware,
  credentials, OTA material, camera pairing data, and local RVC models are never public assets.
- PC/mobile owner failover and final consumer rollout evidence remain required for the companion
  distribution path.
- Production voice-source provenance and a project license selected by the repository owner remain
  explicit distribution gates.
- Final promotion requires the release package audit, current-lead reproducibility check, tagged
  asset verification, and updated terminal evidence documents.

Start with [AGENTS.md](AGENTS.md) when using a coding agent. The authoritative current evidence is
in [docs/FIRST_DEPLOY_STATUS.md](docs/FIRST_DEPLOY_STATUS.md), the exact hardware workflow is in
[docs/ARRIVAL_DAY_RUNBOOK.md](docs/ARRIVAL_DAY_RUNBOOK.md), and promotion gates are in
[docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md). See
[docs/JOHNNY_ALIVE_PATHWAY.md](docs/JOHNNY_ALIVE_PATHWAY.md) for the live roadmap and
[docs/CONVERSATION_V2_ROADMAP.md](docs/CONVERSATION_V2_ROADMAP.md) for the deliberately
post-release natural-conversation plan.

## What This Is

Stackchan: Alive is primarily a real-time character OS:

- `persona/`: emotion, intent, speech planning, command mapping, and frame snapshots.
- `face/`: expression mapping, layered animation, and procedural rendering.
- `motion/`: spring dynamics, actuator ownership, and safety limits.
- `io/`: display, audio, bridge, camera, sensor, speech, and servo adapters.
- `bridge/`: host-side reference bridge, character harness, and memory scaffold.
- `personas/`: swappable Character OS persona packs. `personas/spark` is the active reference pack; `personas/glow` is the quieter second pack used to prove the seam.
- `tools/`: preview, hardware simulation, packaging, release, hardware-evidence, and verification helpers.

Only the motion task writes servos. Higher-level code publishes events and `RobotFrame`
snapshots; new sensors and bridge code must not touch actuators directly.

![Firmware task architecture](docs/media/diagrams/02-firmware-task-architecture.png)

The persona engine turns sensor, bridge, and speech state into the `RobotFrame` snapshots
consumed by face and motion tasks.

![Persona engine](docs/media/diagrams/03-persona-engine.png)

The initial procedural runtime design source is in
[docs/stackchan_procedural_runtime_design.pdf](docs/stackchan_procedural_runtime_design.pdf).

## Roadmap

The current roadmap is the "Johnny Alive" path:

1. Ambient life: breathing, gaze life, micro-expressions, circadian/ambient context.
2. Physical senses: touch, proximity, pickup, shake, putdown, tilt.
3. Hearing: sound saliency, VAD, sound direction, orient reflex.
4. Wake/commands: offline wake word and fixed command grammar.
5. Sight: face detection, gaze tracking, eye contact, search behavior.
6. Voice: local prompts, earcons, synchronized mouth motion, speaker evidence.
7. Brain bridge: local/LAN STT/LLM/TTS loop with character-locked responses.
8. Continuity: longer-term familiarity and character polish.

Most phases already have deterministic firmware or bench-test scaffolding. Hardware adapters
and evidence are being filled in behind those boundaries.

## Voice And Character

The intended voice is an original "Stackchan Spark" robot voice: bright, curious, slightly
electronic, and clear on a small speaker. Johnny 5 is only a creative reference for optimistic
classic robot energy; this project must not clone, quote, or train from named character
voices, actors, soundboards, or non-consented sources.

Useful docs:

- [docs/VOICE_PERSONALITY.md](docs/VOICE_PERSONALITY.md): voice target, personality rules, and source guardrails.
- [docs/CHARACTER_LOCK.md](docs/CHARACTER_LOCK.md): P7 bridge persona, response schema, and memory rules.
- [docs/PERSONA_PACKS.md](docs/PERSONA_PACKS.md): swappable persona-pack format and migration plan.
- [docs/CREATING_PERSONAS.md](docs/CREATING_PERSONAS.md): copy-edit-validate-build tutorial for creating a new Character OS persona.
- [docs/CUSTOMIZING_THE_FACE.md](docs/CUSTOMIZING_THE_FACE.md): tune persona expressions or create a deeper procedural face skin without breaking the display runtime.
- [docs/BRAIN_MODEL.md](docs/BRAIN_MODEL.md): Gemma 4 E2B / LiteRT-LM model target and harness gate.
- [docs/ANDROID_COMPANION_SPEC.md](docs/ANDROID_COMPANION_SPEC.md): PC/mobile brain modes, bridge handoff, trusted endpoints, and app settings contract.
- [docs/COMPANION_CROSS_PLATFORM_PLAN.md](docs/COMPANION_CROSS_PLATFORM_PLAN.md): KMP companion build, desktop/Android distribution, and C0-C8 evidence gates.

Prototype voice auditions:

- Stackchan Spark samples: `docs/media/voice/VOICE_AUDITION.html`
- Optional local RVC policy: `media/voice/rvc/README.md`
- Open an operator-generated RVC page with `tools/open_voice_audition.cmd -Rvc`
- Open a combined page with `tools/open_voice_audition.cmd -All` after generating authorized local RVC samples

RVC is bring-your-own-model and local-only. No model, index, converted sample, or RVC audition
page is distributed; `media/voice/rvc` contains policy only and generated output stays under
the ignored `output/voice_auditions/` tree.

## Privacy Boundary

The default bridge path is deterministic and local. It does not persist audio, call a cloud
speech service, or call a hosted LLM. The LAN scaffold can accept bounded wake-gated PCM
frames for local STT testing, then clears the raw audio at `utterance_end` or `cancel`.

The intended production bridge is wake-gated: audio may leave the device only after local
wake-word or explicit activation, and bridge memory stays host-side and resettable. If Wi-Fi
or the bridge is unavailable, Stackchan must keep local expressions, safety behavior, packaged
prompts, and offline commands working.

The Android companion is specified as a local bridge peer, not a cloud service. It should be
able to observe a PC-hosted brain, become the active mobile brain owner, hand off ownership
without changing firmware settings, and forget trusted endpoints from the app.

![Brain bridge conversation flow](docs/media/diagrams/06-brain-bridge-protocol.png)

See [docs/PRIVACY.md](docs/PRIVACY.md).

## Quick Start

Install PlatformIO, then build the display-only firmware:

```powershell
pio run -e stackchan
```

Build the servo-calibration firmware only after reading the bring-up guide:

```powershell
pio run -e stackchan_servo_calibration
```

Run host/native tests and embedded compile checks:

```powershell
pio test -e native_logic
pio test -e stackchan --without-uploading --without-testing
```

![I/O abstraction build environments](docs/media/diagrams/08-io-abstraction-builds.png)

Run the no-hardware preflight before flashing or packaging:

```powershell
.\tools\run_device_preflight.cmd
```

Validate the bundled Character OS persona packs:

```powershell
.\tools\verify_persona_pack.cmd --Json
.\tools\verify_persona_pack.cmd glow --Json
```

Create a new persona from Spark, then edit the copied YAML:

```powershell
.\tools\create_persona_pack.cmd nova -Name "Stackchan Nova" -Author "Your Name"
.\tools\verify_persona_pack.cmd nova --Json
```

The full creator path is in [docs/CREATING_PERSONAS.md](docs/CREATING_PERSONAS.md).
The face-specific path, including YAML controls, procedural geometry, visemes, previews, and
frame-time gates, is in [docs/CUSTOMIZING_THE_FACE.md](docs/CUSTOMIZING_THE_FACE.md).

Run the Character Lock red-team dry run:

```powershell
.\tools\run_character_red_team.cmd -Json
```

After a real local model runner is configured, add `-RequireRunner` so this becomes a real
B7 gate instead of deterministic harness evidence.

Run the virtual hardware proxy while the physical unit is unavailable:

```powershell
.\tools\run_hardware_simulation.cmd
```

The default simulation includes a pre-arrival device-shell rehearsal plus a fake
mic/STT/model/TTS/speaker loop for bridge ordering, virtual CoreS3 inputs, display frame
ticks, conversation timing, mouth/speaker stream counters, servo safety stop/resume and
clipping checks, power-cycle recovery, and bridge-kill recovery. It is still not a
substitute for real hardware evidence.

Run the combined pre-arrival proxy report:

```powershell
.\tools\run_prearrival_sim_check.cmd
```

It writes `output/prearrival-sim/latest/PREARRIVAL_SIM_CHECK.md` and the matching JSON.
This is the quickest "does the simulated hardware path still work?" check before the unit
arrives. The report now includes nested `hardware-sim/`, `lan-smoke/`, and `engine-probe/`
outputs. Unconfigured local model/STT/TTS commands are reported as setup work, not as a
simulator or LAN smoke failure.
Add `-RunModelBenchmark` after a real runner is configured when you want the same report to
include `model-benchmark/MODEL_BENCHMARK.md/json` and the `summary.candidate_gate` brain
selection status.

Run the socket-level bridge proxy:

```powershell
.\tools\run_lan_smoke.cmd
```

It writes `output/lan-smoke/latest/LAN_SMOKE.md` and matching JSON for the local WebSocket
handshake, bridge frame order, fake audio upload, fake STT/TTS, binary downlink path, and
immediate visible `thinking` timing while a delayed response is still running.
The firmware-side frame adapter, LAN session loop, and Wi-Fi bridge provisioning hook are
tested separately in `pio test -e native_logic`; the remaining device work is configuring
real credentials/bridge host and collecting live CoreS3 handoff evidence.

Check local model/STT/TTS engine readiness:

```powershell
.\tools\run_engine_probe.cmd -Json
.\tools\run_litert_lm_smoke.cmd -Json
```

The probe writes `output/engine-probe/latest/engine_probe.json` and
`output/engine-probe/latest/ENGINE_PROBE.md`. It reports `unconfigured` until real model,
STT, and TTS commands are installed or exported.
The LiteRT smoke writes `output/litert-lm-smoke/latest/LITERT_LM_SMOKE.md/json` and checks
the mobile runner wrapper contract without claiming real model speed.

Run the batch brain benchmark after a real model runner is configured:

```powershell
python bridge/model_benchmark.py --profile gemma4-e2b-gguf --require-runner --json
```

The report writes `summary.candidate_gate` with blockers, `ready_profiles`, and
`recommended_profile`. A dry run is still useful harness evidence, but it is not a selected
brain candidate.

If native host tests cannot find `gcc` / `g++`, run:

```powershell
.\tools\check_native_toolchain.cmd
```

## Preview Media

The same procedural face runtime drives firmware rendering and host-side preview artifacts.

![Procedural face runtime](docs/media/diagrams/04-face-runtime.png)

Generate the hardware-free preview image, GIF, MP4, expression sheet, and speech preview:

```powershell
python -m pip install -r requirements-preview.txt
python tools/render_preview.py
```

Outputs are written to `docs/media/`.

## Release And Evidence Flow

Create a verified prerelease package:

```powershell
.\tools\package_release.cmd -Version <version>
.\tools\verify_release_package.cmd -Version <version> -ZipPath output\release\stackchan_alive_<version>.zip
```

Share the package locally or through a tunnel:

```powershell
.\tools\share_release.cmd -Version <version> -OpenLocal
.\tools\share_release.cmd -Version <version> -Lan
.\tools\share_release.cmd -Version <version> -CloudflareTunnel -DownloadCloudflared
```

Publish a verified prerelease manually when hosted Actions cannot run:

```powershell
.\tools\publish_release.cmd -Version <version> -CreateTag -PushCurrentBranch -PushTag
.\tools\audit_published_release.cmd -Version <version>
```

Start a hardware evidence packet when the device is connected:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Evidence packets include `RUN_HARDWARE_SIM_BASELINE.cmd` for the pre-arrival virtual
Stackchan proxy and `RUN_SIM_HARDWARE_COMPARE.cmd` for an advisory comparison after real
display, speech, and bridge replay logs are captured.

Verify completed evidence before promotion:

```powershell
.\tools\verify_hardware_evidence.cmd -EvidenceRoot output\hardware-evidence\<packet-folder>
.\tools\verify_consumer_promotion.cmd -PackageZip output\release\stackchan_alive_<version>.zip -EvidenceRoot output\hardware-evidence\<packet-folder>
```

Release details live in [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md). Arrival-day
operator instructions live in [docs/DEVICE_BRINGUP.md](docs/DEVICE_BRINGUP.md) and
[docs/ARRIVAL_DAY_RUNBOOK.md](docs/ARRIVAL_DAY_RUNBOOK.md).

## Safety

- Servos are disabled in the default display-only build.
- Servo calibration is a separate environment and requires explicit `-ConfirmServoRisk` in the release flash helper.
- Motion commands flow through the existing motion-control queue and safety limits.
- Do not promote a release as consumer-ready until the hardware evidence and production voice-source gates pass.

![Motion system servo safety](docs/media/diagrams/05-motion-servo-safety.png)

## Use And Contributions

This repository is now public for development visibility. Treat Stackchan: Alive as prerelease robotics
software: expect hardware-specific tuning, evidence gates, and safety review before real-world
use.

No project license file is declared yet. Until one is added, do not assume redistribution or
commercial-use rights beyond normal public repository viewing and contribution discussion.
Keep PRs small, testable, and aligned with the roadmap in
[docs/JOHNNY_ALIVE_PATHWAY.md](docs/JOHNNY_ALIVE_PATHWAY.md).
