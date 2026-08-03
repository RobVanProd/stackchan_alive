# Stackchan Alive Agent Guide

This repository controls physical hardware. Read the current evidence before changing code, and
keep observed facts separate from hypotheses.

## Start Here

1. `docs/FIRST_DEPLOY_STATUS.md`: authoritative current hardware and release evidence.
2. `docs/ARRIVAL_DAY_RUNBOOK.md`: exact bring-up, qualification, soak, and recovery commands.
3. `docs/POWER_BLACKOUT_FORENSICS.md`: required evidence language for resets, black screens,
   voltage events, and unknown stops.
4. `docs/PRODUCTION_READINESS.md` and `docs/RELEASE_PROCESS.md`: promotion and release gates.
5. `docs/BRIDGE_PROTOCOL.md`, `docs/BRAIN_MODEL.md`, and `docs/CHARACTER_LOCK.md`: firmware/host
   contract, Gemma runtime, memory, tools, and persona policy.

If you are the agent working on the host bridge and brain, start with
[docs/BRIDGE_AI_HANDOFF.md](docs/BRIDGE_AI_HANDOFF.md). It is the current work list for
back-and-forth conversation, unprompted speech, curiosity, and room vision, and it says which
parts are already built.

Feature-specific entry points:

- Face engine: `docs/CUSTOMIZING_THE_FACE.md`
- Voice and DirectML RVC: `docs/VOICE_V2_DIRECTML.md`
- Camera and active-speaker tracking: `docs/LOCAL_VISION.md`
- IMU, touch, RGB, camera, and recognition roadmap: `docs/HARDWARE_FEATURE_ROADMAP.md`
- LTR-553 passive proximity calibration: `docs/LTR553_CALIBRATION.md`
- OTA: `docs/LAN_OTA.md`
- Post-release natural conversation: `docs/CONVERSATION_V2_ROADMAP.md`

## Ownership Boundaries

- `src/`: deterministic CoreS3 firmware. It owns face timing, wake, hardware I/O, power
  coordination, actuator safety, and bounded protocol parsing.
- `bridge/`: host brain. It owns STT, Gemma inference, trusted local facts, privacy-filtered
  memory, local-first web research, TTS/RVC, and bridge framing.
- `personas/` and generated `data/`: character packs and generated expression/voice assets.
- `tools/`: build, flash, OTA, evidence, soak, release, and validation commands.
- `output/`: local evidence and private candidates. It is ignored except for explicitly tracked
  fixtures. Never commit pairing codes, OTA tokens, Wi-Fi credentials, private voice models,
  raw microphone recordings, or camera frames.

The model never owns actuator or power authority. Host text and tool results become bounded
protocol metadata; firmware coordinators remain authoritative.

## Non-Negotiable Invariants

- Preserve the smooth procedural face and the strict 50 ms display-frame gate.
- Never infer a power, brownout, thermal, USB, or board root cause without matching telemetry.
- Any real bad state during motion requires `/motion-stop`, runner termination so it cannot
  refresh motion, and a post-stop `/debug` snapshot when reachable.
- Do not reboot, reflash, restart, or discard failed evidence automatically.
- Treat isolated HTTP probe timeouts separately from a robot freeze when live debug recovers and
  the bridge socket remains established.
- Do not weaken wake-gated audio, memory privacy, pairing, OTA health, power, thermal, motion
  session, camera-auth, or display gates to obtain a passing soak.
- Do not make the optional microSD card a boot, safety, wake, face, bridge, or memory dependency.

## Verification

Run the narrow tests for the code touched, then the relevant broad gates:

```powershell
pio test -e native_logic
python -m unittest discover -s bridge -p "test_*.py"
python bridge/trusted_facts_smoke.py --memory-file output/pc-brain/latest/memory.json --json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test_firmware_reproducible_build_contract.ps1
pio run -e stackchan_release_full
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test_full_system_soak_evidence_contract.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test_current_lead_reproducibility_contract.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test_archive_current_lead_contract.ps1
```

Use `tools/check_full_system_soak_evidence.ps1` for completed hardware runs. A build or short
smoke does not prove long-term physical stability. The exact installed binary must pass its own
qualification and soak; do not transfer evidence from a different SHA-256.
The trusted-facts smoke must remain silent (`modelInvocations: 0`, `audioPlayed: false`) and must
not print stored fact values; it proves routing and privacy shape, not conversational voice output.
Live soak JSON uses same-directory atomic replacement. A concurrent Windows reader may receive a
brief sharing violation during the swap, so monitoring code must retry read/parse failures for a
short bounded interval. Never classify one unreadable `progress.json` or `polls.json` snapshot as a
robot failure; use repeated endpoint, process, bridge-socket, and runtime evidence.
`stackchan_release_full` is the secret-free public build. Per-device `stackchan_camera_probe` or
`stackchan_release_forensics` builds require explicit private OTA/pairing configuration and must
never be substituted into a public package or GitHub release asset.
Firmware reproducibility is narrowly scoped to the same clean Git commit, operating system,
dependency/toolchain bytes, canonical recorded PlatformIO configuration, and no listed ambient
build overrides. The hook maps lexical/resolved project and core paths to stable prefixes. Every
Arduino firmware environment must inherit exactly one `platformio_reproducible_build.py` pre-hook;
`native_logic` must inherit none.
Release packages must use two distinct short detached build roots, isolated empty per-cycle build
caches, exact cycle-B dependency snapshots, and a separate clean commit-pinned source worktree for
all tracked package inputs. Dependency evidence must select the exact verbose-resolved platform and
only resolved shared-core packages. Failed logs are moved to private evidence while the complete
failed detached worktree remains attached for inspection. The trusted checkout verifier must never
execute package-contained code, repository-local Git hooks, or fsmonitor configuration.
A `diagnostic-*` package is inspection-only: its firmware and dependency identity are unbound, it
must not be flashed/published or used as evidence, and `-AllowDirtyPackage` never grants that authority.
Matching rebuild hashes prove build determinism only. They do not transfer physical qualification,
soak, stability, or safety evidence between different SHA-256 binaries.

## Change Discipline

- Keep the production worker and currently running soak undisturbed while editing host-side code.
- Archive exact candidate binaries and hashes under ignored `output/private/` before OTA.
- Qualify firmware changes with native tests, embedded build, short no-motion, then supervised
  actuator evidence before starting the long soak.
- Update `FIRST_DEPLOY_STATUS.md` and `ARRIVAL_DAY_RUNBOOK.md` only with completed evidence.
- Keep future work explicitly scoped. Continuous two-way conversation is post-release v2; it
  must not silently expand the v1 release candidate.
