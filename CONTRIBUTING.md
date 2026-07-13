# Contributing To Stackchan: Alive

Thank you for helping build Stackchan: Alive. This project controls physical hardware and handles
microphone, camera, memory, network, and actuator state, so evidence and safety are part of the
implementation rather than release paperwork added later.

## Before You Start

1. Read [AGENTS.md](AGENTS.md) for ownership boundaries, safety invariants, and verification.
2. Read [docs/FIRST_DEPLOY_STATUS.md](docs/FIRST_DEPLOY_STATUS.md) before changing current runtime
   behavior; it is the authoritative physical-evidence record.
3. Use [docs/ARRIVAL_DAY_RUNBOOK.md](docs/ARRIVAL_DAY_RUNBOOK.md) for hardware work and
   [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) for promotion claims.
4. Report security or privacy defects through [SECURITY.md](SECURITY.md), not a public issue.
5. Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) in project spaces.

Open a focused issue before a large architectural change. Small bug fixes and documentation
corrections can go directly to a focused pull request.

## Change Rules

- Keep firmware deterministic and bounded. Sensors, bridge text, and model output never write
  servos or power rails directly.
- Preserve the procedural face and its 50 ms display-frame gate.
- Keep continuous two-way conversation in the documented post-release v2 scope unless a future
  release explicitly adopts it.
- Do not weaken power, thermal, wake, privacy, pairing, OTA, camera-authentication, memory, motion,
  or evidence gates to make a test pass.
- Separate observed facts from hypotheses, especially for resets, black screens, and power events.
- Keep unrelated refactors out of a behavior change.

## Private Material

Never commit or attach real Wi-Fi credentials, pairing codes, OTA tokens, private firmware,
recovery archives, camera frames, raw microphone recordings, local memory files, additional voice
weights or indexes, converted private voice samples, signing keys, or generated evidence containing
those values. Use placeholders in documentation and synthetic fixtures in tests.

The public release includes the hash-pinned Stackchan Spark production RVC model and index.
Bring-your-own-model (BYOM) is also supported for personal characters. Do not replace or add
tracked voice models in an ordinary pull request. Any submitted recording or derived voice asset
must be original and redistributable;
do not submit cloned character voices, actor recordings, soundboards, or unclear-source assets.

If a secret reaches Git history, stop sharing it, rotate it, and report it privately. Deleting the
working-tree file is not sufficient.

## Verification Tiers

Use the smallest tier that fully covers the change, and report the exact commands. These tiers make
feedback fast; they do not transfer evidence between firmware binaries or weaken release gates.

### Tier 0: Documentation Only

Check links, commands, and `git diff --check`. No firmware build is required when executable code,
configuration, protocol fixtures, generated assets, and package contracts are untouched.

### Tier 1: Contributor Fast Lane

For host logic, persona data, deterministic firmware logic, and protocol changes, run:

```powershell
pio test -e native_logic
python -m unittest discover -s bridge -p "test_*.py"
python bridge/hardware_simulator.py --out-dir output/hardware-sim/contributor --json
python bridge/lan_smoke.py --out-dir output/lan-smoke/contributor --json
```

### Tier 2: Embedded Or Package Surface

Add `pio run -e stackchan_release_full` for `src/`, `platformio.ini`, generated firmware assets, or
embedded dependency changes. Add the specific package, persona, companion, OTA, camera,
body-sensor, or evidence-contract test whenever that surface changes.

### Tier 3: Physical Behavior

Use the short no-motion and supervised actuator sequence from `ARRIVAL_DAY_RUNBOOK.md`. This tier is
required for claims about real sensors, speaker behavior, camera following, wake, power, display
timing, or motion; it is not required merely to open a focused pull request.

### Tier 4: Promotion

Only a release candidate needs exact-image qualification, the formal soak checker, package audit,
and consumer-promotion composition in `RELEASE_PROCESS.md`. A short smoke or contributor fast-lane
pass never becomes release evidence.

Install `bridge/requirements-vision.txt` or use an isolated vision runtime before treating the
YuNet/OpenCV test as failed. Include commands, results, and remaining risk in the pull request.

## Physical Hardware Evidence

- Start with motion disabled. Servo testing requires an operator, a clear body, a stable surface,
  and explicit risk confirmation.
- Bind evidence to the exact firmware SHA-256 and clean source commit that produced it.
- On a real bad state, stop motion and preserve the first available debug snapshot. Do not reboot,
  reflash, discard, or relabel failed evidence automatically.
- A build, simulator, or short smoke does not prove long-term physical stability.
- Never transfer a passing result from another firmware image.

Private lab evidence belongs under ignored `output/` paths. Public pull requests should contain
only sanitized summaries, deterministic fixtures, and the code or documentation needed to verify
the claim.

## Pull Requests

Describe the problem, the ownership boundary touched, user-visible behavior, tests run, and any
remaining risk. Link exact evidence when physical behavior changes. Update the relevant guide when
a command, gate, configuration field, or public workflow changes.

Contributions are accepted under the repository's [Apache License 2.0](LICENSE).
